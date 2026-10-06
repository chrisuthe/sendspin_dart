import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

import 'support/connected.dart';
import 'test_identity.dart';

void main() {
  group('SendspinClient', () {
    test('starts in disabled state', () {
      final client = SendspinClient(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      expect(client.state.connectionState, SendspinConnectionState.disabled);
      client.dispose();
    });

    test('parses server/hello and transitions to syncing', () async {
      final client = SendspinClient(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      final states = <SendspinConnectionState>[];
      client.stateStream.listen((s) => states.add(s.connectionState));

      connect(client);

      await Future.delayed(Duration.zero);
      expect(states, contains(SendspinConnectionState.syncing));
      expect(client.state.serverName, 'TestServer');
      client.dispose();
    });

    test('parses stream/start and configures codec', () async {
      final client = SendspinClient(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      serverSends(
          client,
          jsonEncode({
            'type': 'server/hello',
            'payload': {
              'server_id': 'server-1',
              'name': 'MA',
              'active_roles': ['player@v1'],
            },
          }));
      serverSends(
          client,
          jsonEncode({
            'type': 'stream/start',
            'payload': {
              'player': {
                'codec': 'pcm',
                'channels': 2,
                'sample_rate': 48000,
                'bit_depth': 16,
              },
            },
          }));
      await Future.delayed(Duration.zero);
      expect(client.state.codec, 'pcm');
      expect(client.state.sampleRate, 48000);
      expect(client.state.channels, 2);
      client.dispose();
    });

    test('parses server/command for volume', () async {
      final client = SendspinClient(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      serverSends(
          client,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {'command': 'volume', 'volume': 50},
            },
          }));
      await Future.delayed(Duration.zero);
      expect(client.state.volume, 0.5);
      client.dispose();
    });

    test('parses server/command for mute', () async {
      final client = SendspinClient(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      serverSends(
          client,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {'command': 'mute', 'mute': true},
            },
          }));
      await Future.delayed(Duration.zero);
      expect(client.state.muted, true);
      client.dispose();
    });

    test('builds correct client/hello message with custom device info', () {
      final client = SendspinClient(
        playerName: 'Kitchen Display',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        deviceInfo: const DeviceInfo(
          productName: 'MyApp',
          manufacturer: 'MyCorp',
          softwareVersion: '1.0.0',
        ),
      );
      final hello = client.buildClientHello();
      final parsed = jsonDecode(hello) as Map<String, dynamic>;
      expect(parsed['type'], 'client/hello');
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect(payload.containsKey('client_id'), isFalse);
      expect(payload['name'], 'Kitchen Display');
      expect(payload['supported_roles'], contains('player@v1'));
      final deviceInfo = payload['device_info'] as Map<String, dynamic>;
      expect(deviceInfo['product_name'], 'MyApp');
      expect(deviceInfo['manufacturer'], 'MyCorp');
      expect(deviceInfo['software_version'], '1.0.0');
      client.dispose();
    });

    test('sends client/state immediately on volume command', () async {
      final client = SendspinClient(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      final sentMessages = <String>[];
      captureSent(client, sentMessages);

      serverSends(
          client,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {'command': 'volume', 'volume': 75},
            },
          }));

      await Future.delayed(Duration.zero);
      expect(sentMessages, hasLength(1));
      final parsed = jsonDecode(sentMessages.first) as Map<String, dynamic>;
      expect(parsed['type'], 'client/state');
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect((payload['player'] as Map)['volume'], 75);
      client.dispose();
    });

    test('sends client/state immediately on mute command', () async {
      final client = SendspinClient(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      final sentMessages = <String>[];
      captureSent(client, sentMessages);

      serverSends(
          client,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {'command': 'mute', 'mute': true},
            },
          }));

      await Future.delayed(Duration.zero);
      expect(sentMessages, hasLength(1));
      final parsed = jsonDecode(sentMessages.first) as Map<String, dynamic>;
      expect(parsed['type'], 'client/state');
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect((payload['player'] as Map)['muted'], true);
      client.dispose();
    });

    test('buildClientState always reports synchronized per spec', () {
      final client = SendspinClient(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      final state =
          jsonDecode(client.buildClientState()) as Map<String, dynamic>;
      expect(state['payload']['state'], 'synchronized');
      client.dispose();
    });

    test('starts state report timer on stream/start and stops on stream/end',
        () async {
      final client = SendspinClient(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      final sentMessages = <String>[];
      captureSent(client, sentMessages);

      serverSends(
          client,
          jsonEncode({
            'type': 'server/hello',
            'payload': {'name': 'MA'},
          }));
      sentMessages.clear();

      serverSends(
          client,
          jsonEncode({
            'type': 'stream/start',
            'payload': {
              'player': {
                'codec': 'pcm',
                'channels': 2,
                'sample_rate': 48000,
                'bit_depth': 16,
              },
            },
          }));

      serverSends(
          client,
          jsonEncode({
            'type': 'stream/end',
            'payload': {},
          }));

      client.dispose();
    });

    test('parseBinaryFrame extracts timestamp and data', () {
      final frame = Uint8List(17);
      final view = ByteData.view(frame.buffer);
      frame[0] = 4;
      view.setInt64(1, 123456789, Endian.big);
      frame[13] = 0x01;
      frame[14] = 0x02;
      frame[15] = 0x03;
      frame[16] = 0x04;
      final result = SendspinClient.parseBinaryFrame(frame);
      expect(result.timestampUs, 123456789);
      expect(result.audioData, [0x01, 0x02, 0x03, 0x04]);
    });
  });
}
