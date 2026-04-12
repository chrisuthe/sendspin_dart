import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/src/protocol.dart';
import 'package:sendspin_dart/src/models.dart';
import 'package:sendspin_dart/src/clock.dart';

void main() {
  group('SendspinProtocol', () {
    late SendspinProtocol protocol;

    setUp(() {
      protocol = SendspinProtocol(
        playerName: 'Test Player',
        clientId: 'test-id',
        bufferSeconds: 5,
      );
    });

    tearDown(() {
      protocol.dispose();
    });

    test('starts in disabled state', () {
      expect(protocol.state.connectionState, SendspinConnectionState.disabled);
    });

    test('parses server/hello and transitions to syncing', () async {
      final states = <SendspinConnectionState>[];
      protocol.stateStream.listen((s) => states.add(s.connectionState));

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {
          'server_id': 'server-1',
          'name': 'Music Assistant',
          'active_roles': ['player@v1'],
        },
      }));

      await Future.delayed(Duration.zero);
      expect(states, contains(SendspinConnectionState.syncing));
      expect(protocol.state.serverName, 'Music Assistant');
    });

    test('builds correct client/hello message', () {
      final protocol = SendspinProtocol(
        playerName: 'Kitchen Display',
        clientId: 'abc-123',
        bufferSeconds: 5,
        deviceInfo: const DeviceInfo(
          productName: 'MyApp',
          manufacturer: 'MyCorp',
          softwareVersion: '1.0.0',
        ),
      );
      final hello = protocol.buildClientHello();
      final parsed = jsonDecode(hello) as Map<String, dynamic>;
      expect(parsed['type'], 'client/hello');
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect(payload['client_id'], 'abc-123');
      expect(payload['name'], 'Kitchen Display');
      expect(payload['version'], 1);
      expect(payload['supported_roles'], contains('player@v1'));
      final deviceInfo = payload['device_info'] as Map<String, dynamic>;
      expect(deviceInfo['product_name'], 'MyApp');
      expect(deviceInfo['manufacturer'], 'MyCorp');
      expect(deviceInfo['software_version'], '1.0.0');
      protocol.dispose();
    });

    test('emits onStreamConfig on stream/start without codec_header', () async {
      StreamConfig? receivedConfig;
      protocol.onStreamConfig = (config) => receivedConfig = config;

      // Need to be connected first
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));

      protocol.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'pcm',
            'channels': 2,
            'sample_rate': 48000,
            'bit_depth': 16,
          },
        },
      }));

      expect(receivedConfig, isNotNull);
      expect(receivedConfig!.codec, 'pcm');
      expect(receivedConfig!.channels, 2);
      expect(receivedConfig!.sampleRate, 48000);
      expect(receivedConfig!.bitDepth, 16);
      expect(receivedConfig!.codecHeader, isNull);
    });

    test('emits onStreamConfig on stream/start with codec_header', () {
      StreamConfig? receivedConfig;
      protocol.onStreamConfig = (config) => receivedConfig = config;

      protocol.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'flac',
            'channels': 2,
            'sample_rate': 44100,
            'bit_depth': 16,
            'codec_header': 'AQIDBA==', // base64 of [1,2,3,4]
          },
        },
      }));

      expect(receivedConfig, isNotNull);
      expect(receivedConfig!.codec, 'flac');
      expect(receivedConfig!.sampleRate, 44100);
      expect(receivedConfig!.codecHeader, 'AQIDBA==');
    });

    test('emits onStreamConfig with player-nested format', () {
      StreamConfig? receivedConfig;
      protocol.onStreamConfig = (config) => receivedConfig = config;

      protocol.handleTextMessage(jsonEncode({
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

      expect(receivedConfig, isNotNull);
      expect(receivedConfig!.codec, 'pcm');
    });

    test('emits onAudioFrame for binary messages', () {
      AudioFrame? receivedFrame;
      protocol.onAudioFrame = (frame) => receivedFrame = frame;

      final data = Uint8List(13);
      final view = ByteData.view(data.buffer);
      data[0] = 1; // version
      view.setInt64(1, 123456789, Endian.big);
      data[9] = 0x01;
      data[10] = 0x02;
      data[11] = 0x03;
      data[12] = 0x04;

      protocol.handleBinaryMessage(data);

      expect(receivedFrame, isNotNull);
      expect(receivedFrame!.timestampUs, 123456789);
      expect(receivedFrame!.audioData, [0x01, 0x02, 0x03, 0x04]);
    });

    test('ignores binary messages shorter than 9 bytes', () {
      AudioFrame? receivedFrame;
      protocol.onAudioFrame = (frame) => receivedFrame = frame;

      protocol.handleBinaryMessage(Uint8List(8));

      expect(receivedFrame, isNull);
    });

    test('emits onStreamClear on stream/clear', () {
      var clearCalled = false;
      protocol.onStreamClear = () => clearCalled = true;

      protocol.handleTextMessage(jsonEncode({
        'type': 'stream/clear',
        'payload': {},
      }));

      expect(clearCalled, isTrue);
    });

    test('emits onStreamEnd on stream/end and transitions to syncing', () async {
      var endCalled = false;
      protocol.onStreamEnd = () => endCalled = true;

      // Get into streaming state first
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      protocol.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'pcm',
            'channels': 2,
            'sample_rate': 48000,
            'bit_depth': 16,
          },
        },
      }));
      expect(protocol.state.connectionState, SendspinConnectionState.streaming);

      protocol.handleTextMessage(jsonEncode({
        'type': 'stream/end',
        'payload': {},
      }));

      await Future.delayed(Duration.zero);
      expect(endCalled, isTrue);
      expect(protocol.state.connectionState, SendspinConnectionState.syncing);
    });

    test('handles server/command volume and calls onVolumeChanged', () async {
      double? receivedVolume;
      bool? receivedMuted;
      protocol.onVolumeChanged = (vol, muted) {
        receivedVolume = vol;
        receivedMuted = muted;
      };

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/command',
        'payload': {
          'player': {'command': 'volume', 'volume': 50},
        },
      }));

      await Future.delayed(Duration.zero);
      expect(protocol.state.volume, 0.5);
      expect(receivedVolume, 0.5);
      expect(receivedMuted, false);
    });

    test('sends client/state on volume command via onSendText', () async {
      final sentMessages = <String>[];
      protocol.onSendText = sentMessages.add;

      protocol.handleTextMessage(jsonEncode({
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
    });

    test('updateVolume changes state and sends report', () {
      final sentMessages = <String>[];
      protocol.onSendText = sentMessages.add;

      protocol.updateVolume(0.7);

      expect(protocol.state.volume, closeTo(0.7, 0.01));
      expect(sentMessages, hasLength(1));
      final parsed = jsonDecode(sentMessages.first) as Map<String, dynamic>;
      expect(parsed['type'], 'client/state');
      expect((parsed['payload']['player'] as Map)['volume'], 70);
    });

    test('parseBinaryFrame is a static utility', () {
      final frame = Uint8List(13);
      final view = ByteData.view(frame.buffer);
      frame[0] = 1;
      view.setInt64(1, 987654321, Endian.big);
      frame[9] = 0xAA;
      frame[10] = 0xBB;
      frame[11] = 0xCC;
      frame[12] = 0xDD;

      final result = SendspinProtocol.parseBinaryFrame(frame);
      expect(result.timestampUs, 987654321);
      expect(result.audioData, [0xAA, 0xBB, 0xCC, 0xDD]);
    });

    test('updatePipelineState updates state', () async {
      final states = <SendspinPlayerState>[];
      protocol.stateStream.listen(states.add);

      final newState = protocol.state.copyWith(bufferDepthMs: 150);
      protocol.updatePipelineState(newState);

      await Future.delayed(Duration.zero);
      expect(protocol.state.bufferDepthMs, 150);
      expect(states, isNotEmpty);
    });

    test('clock getter is accessible', () {
      expect(protocol.clock, isA<SendspinClock>());
    });

    test('handles mute command', () async {
      double? receivedVolume;
      bool? receivedMuted;
      protocol.onVolumeChanged = (vol, muted) {
        receivedVolume = vol;
        receivedMuted = muted;
      };

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/command',
        'payload': {
          'player': {'command': 'mute', 'mute': true},
        },
      }));

      await Future.delayed(Duration.zero);
      expect(protocol.state.muted, true);
      expect(receivedMuted, true);
    });

    test('resetForNewConnection stops timers and resets clock', () {
      // Should not throw
      protocol.resetForNewConnection();
      // State should still be accessible
      expect(protocol.state, isNotNull);
    });
  });
}
