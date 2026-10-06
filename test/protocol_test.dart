import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:sendspin_dart/src/protocol.dart';
import 'package:sendspin_dart/src/models.dart';
import 'package:sendspin_dart/src/clock.dart';

import 'support/connected.dart';
import 'test_identity.dart';

void main() {
  group('SendspinProtocol', () {
    late SendspinProtocol protocol;

    setUp(() {
      protocol = SendspinProtocol(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
    });

    tearDown(() {
      protocol.dispose();
    });

    test('starts in disabled state', () {
      expect(protocol.state.connectionState, SendspinConnectionState.disabled);
    });

    test('builds correct client/hello message', () {
      final protocol = SendspinProtocol(
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
      final hello = protocol.buildClientHello();
      final parsed = jsonDecode(hello) as Map<String, dynamic>;
      expect(parsed['type'], 'client/hello');
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect(payload.containsKey('client_id'), isFalse,
          reason: 'client_id travels in client/init');
      expect(payload.containsKey('version'), isFalse);
      expect(payload['name'], 'Kitchen Display');
      expect(payload['supported_roles'], contains('player@v1'));
      final deviceInfo = payload['device_info'] as Map<String, dynamic>;
      expect(deviceInfo['product_name'], 'MyApp');
      expect(deviceInfo['manufacturer'], 'MyCorp');
      expect(deviceInfo['software_version'], '1.0.0');
      protocol.dispose();
    });

    test('client/hello player@v1_support holds formats and buffer_capacity',
        () {
      // rc1 defines no supported_commands here; settable commands are
      // reported in client/state.
      final parsed =
          jsonDecode(protocol.buildClientHello()) as Map<String, dynamic>;
      final support =
          parsed['payload']['player@v1_support'] as Map<String, dynamic>;
      expect(support.keys.toSet(), {'supported_formats', 'buffer_capacity'});
    });

    test('emits onStreamConfig on stream/start without codec_header', () async {
      StreamConfig? receivedConfig;
      protocol.onStreamConfig = (config) => receivedConfig = config;

      // Need to be connected first
      serverSends(
          protocol,
          jsonEncode({
            'type': 'server/hello',
            'payload': {'name': 'MA'},
          }));

      serverSends(
          protocol,
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

      serverSends(
          protocol,
          jsonEncode({
            'type': 'stream/start',
            'payload': {
              'player': {
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

      serverSends(
          protocol,
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

      expect(receivedConfig, isNotNull);
      expect(receivedConfig!.codec, 'pcm');
    });

    test('emits onAudioFrame for binary messages', () {
      AudioFrame? receivedFrame;
      protocol.onAudioFrame = (frame) => receivedFrame = frame;

      final data = Uint8List(17);
      final view = ByteData.view(data.buffer);
      data[0] = 4; // message type: player audio chunk
      view.setInt64(1, 123456789, Endian.big);
      view.setUint32(9, 250000, Endian.big);
      data[13] = 0x01;
      data[14] = 0x02;
      data[15] = 0x03;
      data[16] = 0x04;

      serverSendsBinary(protocol, data);

      expect(receivedFrame, isNotNull);
      expect(receivedFrame!.timestampUs, 123456789);
      expect(receivedFrame!.sendAheadUs, 250000);
      expect(receivedFrame!.audioData, [0x01, 0x02, 0x03, 0x04]);
    });

    test('rejects audio chunks shorter than the 13-byte header', () {
      AudioFrame? receivedFrame;
      protocol.onAudioFrame = (frame) => receivedFrame = frame;

      final data = Uint8List(12);
      data[0] = 4;
      serverSendsBinary(protocol, data);

      expect(receivedFrame, isNull);
    });

    test('accepts an audio chunk that is exactly the 13-byte header', () {
      AudioFrame? receivedFrame;
      protocol.onAudioFrame = (frame) => receivedFrame = frame;

      final data = Uint8List(13);
      data[0] = 4;
      serverSendsBinary(protocol, data);

      expect(receivedFrame, isNotNull);
      expect(receivedFrame!.audioData, isEmpty);
    });

    test('emits onStreamClear on stream/clear', () {
      var clearCalled = false;
      protocol.onStreamClear = () => clearCalled = true;

      serverSends(
          protocol,
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
          protocol,
          jsonEncode({
            'type': 'stream/clear',
            'payload': {},
          }));

      expect(clearCalled, isTrue);
    });

    test('emits onStreamEnd on stream/end and transitions to syncing',
        () async {
      var endCalled = false;
      protocol.onStreamEnd = () => endCalled = true;

      // Get into streaming state first
      serverSends(
          protocol,
          jsonEncode({
            'type': 'server/hello',
            'payload': {'name': 'MA'},
          }));
      serverSends(
          protocol,
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
      expect(protocol.state.connectionState, SendspinConnectionState.streaming);

      serverSends(
          protocol,
          jsonEncode({
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

      serverSends(
          protocol,
          jsonEncode({
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
      captureSent(protocol, sentMessages);

      serverSends(
          protocol,
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
    });

    test('updateVolume changes state and sends report', () {
      final sentMessages = <String>[];
      captureSent(protocol, sentMessages);

      protocol.updateVolume(0.7);

      expect(protocol.state.volume, closeTo(0.7, 0.01));
      expect(sentMessages, hasLength(1));
      final parsed = jsonDecode(sentMessages.first) as Map<String, dynamic>;
      expect(parsed['type'], 'client/state');
      expect((parsed['payload']['player'] as Map)['volume'], 70);
    });

    test('parseBinaryFrame is a static utility', () {
      final frame = Uint8List(17);
      final view = ByteData.view(frame.buffer);
      frame[0] = 4;
      view.setInt64(1, 987654321, Endian.big);
      view.setUint32(9, 0xFFFFFFFF, Endian.big);
      frame[13] = 0xAA;
      frame[14] = 0xBB;
      frame[15] = 0xCC;
      frame[16] = 0xDD;

      final result = SendspinProtocol.parseBinaryFrame(frame);
      expect(result.timestampUs, 987654321);
      expect(result.sendAheadUs, 0xFFFFFFFF);
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

      serverSends(
          protocol,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {'command': 'mute', 'mute': true},
            },
          }));

      await Future.delayed(Duration.zero);
      expect(protocol.state.muted, true);
      expect(receivedMuted, true);
      expect(receivedVolume, 1.0);
    });

    test('handles set_static_delay command and invokes callback', () async {
      int? receivedDelay;
      protocol.onOutputDelayChanged = (d) => receivedDelay = d;

      serverSends(
          protocol,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {'command': 'set_output_delay', 'output_delay_ms': 250},
            },
          }));

      await Future.delayed(Duration.zero);
      expect(receivedDelay, 250);
      expect(protocol.outputDelayMs, 250);
      expect(protocol.state.outputDelayMs, 250);
    });

    test('clamps set_static_delay above max to 5000', () async {
      int? receivedDelay;
      protocol.onOutputDelayChanged = (d) => receivedDelay = d;

      serverSends(
          protocol,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {
                'command': 'set_output_delay',
                'output_delay_ms': 99999
              },
            },
          }));

      await Future.delayed(Duration.zero);
      expect(receivedDelay, 5000);
      expect(protocol.outputDelayMs, 5000);
    });

    test('clamps negative set_static_delay to 0', () async {
      int? receivedDelay;
      protocol.onOutputDelayChanged = (d) => receivedDelay = d;

      serverSends(
          protocol,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {
                'command': 'set_output_delay',
                'output_delay_ms': -100
              },
            },
          }));

      await Future.delayed(Duration.zero);
      expect(receivedDelay, 0);
      expect(protocol.outputDelayMs, 0);
    });

    test('outputDelayMs getter reflects latest value across updates', () {
      expect(protocol.outputDelayMs, 0);

      serverSends(
          protocol,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {'command': 'set_output_delay', 'output_delay_ms': 100},
            },
          }));
      expect(protocol.outputDelayMs, 100);

      serverSends(
          protocol,
          jsonEncode({
            'type': 'server/command',
            'payload': {
              'player': {'command': 'set_output_delay', 'output_delay_ms': 500},
            },
          }));
      expect(protocol.outputDelayMs, 500);
    });

    test('initialOutputDelayMs sets outputDelayMs at construction', () {
      final p = SendspinProtocol(
        playerName: 'Test',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        initialOutputDelayMs: 1500,
      );
      expect(p.outputDelayMs, 1500);
      p.dispose();
    });

    test('initialOutputDelayMs is reflected in buildClientState', () {
      final p = SendspinProtocol(
        playerName: 'Test',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        initialOutputDelayMs: 1500,
      );
      connect(p);
      final parsed = jsonDecode(p.buildClientState()) as Map<String, dynamic>;
      expect(
        (parsed['payload']['player'] as Map)['output_delay_ms'],
        1500,
      );
      p.dispose();
    });

    test('initialOutputDelayMs above max is clamped to 5000', () {
      final p = SendspinProtocol(
        playerName: 'Test',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        initialOutputDelayMs: 99999,
      );
      expect(p.outputDelayMs, 5000);
      p.dispose();
    });

    test('negative initialOutputDelayMs is clamped to 0', () {
      final p = SendspinProtocol(
        playerName: 'Test',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        initialOutputDelayMs: -50,
      );
      expect(p.outputDelayMs, 0);
      p.dispose();
    });

    test('buildClientGoodbye returns correct JSON for shutdown', () {
      final msg = protocol.buildClientGoodbye(SendspinGoodbyeReason.shutdown);
      final parsed = jsonDecode(msg) as Map<String, dynamic>;
      expect(parsed['type'], 'client/goodbye');
      expect((parsed['payload'] as Map)['reason'], 'shutdown');
    });

    test('buildClientGoodbye maps anotherServer to another_server', () {
      final msg =
          protocol.buildClientGoodbye(SendspinGoodbyeReason.anotherServer);
      final parsed = jsonDecode(msg) as Map<String, dynamic>;
      expect((parsed['payload'] as Map)['reason'], 'another_server');
    });

    test('buildClientGoodbye maps restart to restart', () {
      final msg = protocol.buildClientGoodbye(SendspinGoodbyeReason.restart);
      final parsed = jsonDecode(msg) as Map<String, dynamic>;
      expect((parsed['payload'] as Map)['reason'], 'restart');
    });

    test('buildClientGoodbye maps userRequest to user_request', () {
      final msg =
          protocol.buildClientGoodbye(SendspinGoodbyeReason.userRequest);
      final parsed = jsonDecode(msg) as Map<String, dynamic>;
      expect((parsed['payload'] as Map)['reason'], 'user_request');
    });

    test('sendGoodbye dispatches built JSON via onSendText', () {
      final sent = <String>[];
      captureSent(protocol, sent);
      protocol.sendGoodbye(SendspinGoodbyeReason.shutdown);
      expect(sent, hasLength(1));
      expect(
        sent.first,
        protocol.buildClientGoodbye(SendspinGoodbyeReason.shutdown),
      );
    });

    test('sendGoodbye with null onSendText does not throw', () {
      protocol.onSendText = null;
      expect(() => protocol.sendGoodbye(SendspinGoodbyeReason.userRequest),
          returnsNormally);
    });

    test('resetForNewConnection stops timers and resets clock', () {
      // Should not throw
      protocol.resetForNewConnection();
      // State should still be accessible
      expect(protocol.state, isNotNull);
    });

    test('clock sync starts on the first activation with one client/time', () {
      final server = connect(protocol, activate: false);
      expect(sentOfType(protocol, 'client/time'), isEmpty,
          reason: 'nothing may be sent before the first server/activate');

      activate(server, protocol);
      // One slot opens immediately; no second send until a reply or
      // timeout advances the burst.
      expect(sentOfType(protocol, 'client/time'), hasLength(1));
    });

    test(
        'incoming server/time advances the burst and triggers the next '
        'client/time', () async {
      final server = connect(protocol, activate: false);
      activate(server, protocol);
      expect(sentOfType(protocol, 'client/time'), hasLength(1));

      // Negative control: without a reply, no further client/time should
      // be sent (we are below the response timeout window).
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(sentOfType(protocol, 'client/time'), hasLength(1),
          reason: 'no spontaneous second send');

      // Feed a realistic NTP-style reply to slot 1.
      final nowUs = protocol.nowUs();
      serverSends(
          protocol,
          jsonEncode({
            'type': 'server/time',
            'payload': {
              'client_transmitted': nowUs - 1000,
              'server_received': nowUs - 500,
              'server_transmitted': nowUs - 400,
            },
          }));

      expect(sentOfType(protocol, 'client/time'), hasLength(2),
          reason: 'reply should advance the burst to the next slot');
    });

    test('nowUs is monotonic and not derived from wall clock', () {
      final t1 = protocol.nowUs();
      final t2 = protocol.nowUs();
      expect(t2, greaterThanOrEqualTo(t1));
      // Compare against wall-clock epoch microseconds: a Stopwatch-derived
      // source is many years smaller. Robust regardless of process uptime.
      const tenYearsUs = 10 * 365 * 24 * 60 * 60 * 1000 * 1000;
      final wall = DateTime.now().microsecondsSinceEpoch;
      expect(wall - t1, greaterThan(tenYearsUs),
          reason: 'monotonic source must not be wall-clock-derived');
    });

    test(
        'client/time payload uses the monotonic time source, '
        'not wall clock', () {
      final server = connect(protocol, activate: false);
      activate(server, protocol);
      // The first slot fires synchronously on activation.
      final payload = sentOfType(protocol, 'client/time').single['payload']
          as Map<String, dynamic>;
      final clientTransmitted = payload['client_transmitted'] as int;
      const tenYearsUs = 10 * 365 * 24 * 60 * 60 * 1000 * 1000;
      final wall = DateTime.now().microsecondsSinceEpoch;
      expect(wall - clientTransmitted, greaterThan(tenYearsUs),
          reason: 'client_transmitted must come from the Stopwatch, '
              'not DateTime.now()');
    });

    test('stopClockSync prevents further client/time sends', () async {
      final sent = <String>[];
      captureSent(protocol, sent);
      protocol.startClockSync();
      protocol.stopClockSync();
      sent.clear();

      // Even after a small delay any leftover timer should not fire.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final timeMessages =
          sent.where((m) => m.contains('"client/time"')).toList();
      expect(timeMessages, isEmpty);
    });

    Uint8List buildTypedFrame(int type, int timestampUs, List<int> payload) {
      final frame = Uint8List(13 + payload.length);
      frame[0] = type;
      ByteData.view(frame.buffer).setInt64(1, timestampUs, Endian.big);
      frame.setRange(13, frame.length, payload);
      return frame;
    }

    test('parseBinaryFrame extracts the type byte', () {
      final frame = buildTypedFrame(4, 111222333, [0xDE, 0xAD]);
      final parsed = SendspinProtocol.parseBinaryFrame(frame);
      expect(parsed.type, 4);
      expect(parsed.timestampUs, 111222333);
      expect(parsed.audioData, [0xDE, 0xAD]);
    });

    test('handleBinaryMessage emits onAudioFrame for player type 4', () {
      AudioFrame? received;
      protocol.onAudioFrame = (f) => received = f;
      serverSendsBinary(protocol, buildTypedFrame(4, 1, [0x01]));
      expect(received, isNotNull);
      expect(received!.type, 4);
    });

    test('handleBinaryMessage does not decode player IDs 5-7 as audio', () {
      AudioFrame? received;
      protocol.onAudioFrame = (f) => received = f;
      for (final id in [5, 6, 7]) {
        serverSendsBinary(protocol, buildTypedFrame(id, 1, [0x01]));
      }
      expect(received, isNull);
    });

    test('handleBinaryMessage drops artwork frame type 8', () {
      AudioFrame? received;
      protocol.onAudioFrame = (f) => received = f;
      serverSendsBinary(protocol, buildTypedFrame(8, 1, [0x01]));
      expect(received, isNull);
    });

    test('handleBinaryMessage drops reserved type 0', () {
      AudioFrame? received;
      protocol.onAudioFrame = (f) => received = f;
      serverSendsBinary(protocol, buildTypedFrame(0, 1, [0x01]));
      expect(received, isNull);
    });

    test('buildClientHello buffer_capacity uses 48k stereo 16-bit default', () {
      final p = SendspinProtocol(
        playerName: 'p',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      final parsed = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final support =
          (parsed['payload']['player@v1_support']) as Map<String, dynamic>;
      expect(support['buffer_capacity'], 5 * 48000 * 2 * 2);
      p.dispose();
    });

    test('buildClientHello buffer_capacity uses 24-bit with 3 bytes/sample',
        () {
      final p = SendspinProtocol(
        playerName: 'p',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        supportedFormats: const [
          AudioFormat(
              codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 24),
        ],
      );
      final parsed = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final support =
          (parsed['payload']['player@v1_support']) as Map<String, dynamic>;
      expect(support['buffer_capacity'], 5 * 48000 * 2 * 3);
      p.dispose();
    });

    test('buildClientHello buffer_capacity picks max of advertised formats',
        () {
      final p = SendspinProtocol(
        playerName: 'p',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 2,
        supportedFormats: const [
          AudioFormat(
              codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
          AudioFormat(
              codec: 'pcm', channels: 2, sampleRate: 96000, bitDepth: 24),
        ],
      );
      final parsed = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final support =
          (parsed['payload']['player@v1_support']) as Map<String, dynamic>;
      expect(support['buffer_capacity'], 2 * 96000 * 2 * 3);
      p.dispose();
    });

    test('group/update full payload sets state and invokes callback', () {
      SendspinGroupState? received;
      protocol.onGroupUpdate = (g) => received = g;

      serverSends(
          protocol,
          jsonEncode({
            'type': 'group/update',
            'payload': {
              'playback_state': 'playing',
              'group_id': 'g1',
              'group_name': 'Kitchen',
            },
          }));

      expect(protocol.state.groupState.playbackState,
          SendspinGroupPlaybackState.playing);
      expect(protocol.state.groupState.groupId, 'g1');
      expect(protocol.state.groupState.groupName, 'Kitchen');
      expect(received, isNotNull);
      expect(received!.groupId, 'g1');
      expect(received!.groupName, 'Kitchen');
    });

    test('group/update replaces the previous group state', () {
      serverSends(
          protocol,
          jsonEncode({
            'type': 'group/update',
            'payload': {
              'playback_state': 'playing',
              'group_id': 'g1',
              'group_name': 'Kitchen',
            },
          }));

      serverSends(
          protocol,
          jsonEncode({
            'type': 'group/update',
            'payload': {
              'playback_state': 'stopped',
              'group_id': 'g2',
              'group_name': 'Solo',
            },
          }));

      expect(protocol.state.groupState.playbackState,
          SendspinGroupPlaybackState.stopped);
      expect(protocol.state.groupState.groupId, 'g2');
      expect(protocol.state.groupState.groupName, 'Solo');
    });

    test('group/update with playback_state stopped', () {
      serverSends(
          protocol,
          jsonEncode({
            'type': 'group/update',
            'payload': {'playback_state': 'stopped'},
          }));
      expect(protocol.state.groupState.playbackState,
          SendspinGroupPlaybackState.stopped);
    });

    test('group/update with unknown playback_state falls back to unknown', () {
      serverSends(
          protocol,
          jsonEncode({
            'type': 'group/update',
            'payload': {'playback_state': 'bogus'},
          }));
      expect(protocol.state.groupState.playbackState,
          SendspinGroupPlaybackState.unknown);
    });
  });

  group('multi-role client/hello', () {
    test('default roles produces player@v1 only (backward compat)', () {
      final p = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      final parsed = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect(payload['supported_roles'], ['player@v1']);
      expect(payload.containsKey('player@v1_support'), isTrue);
      expect(payload.containsKey('controller@v1_support'), isFalse);
      expect(payload.containsKey('metadata@v1_support'), isFalse);
      expect(payload.containsKey('artwork@v1_support'), isFalse);
      p.dispose();
    });

    test('controller-only role omits player@v1_support', () {
      final p = SendspinProtocol(
        playerName: 'Remote',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      final parsed = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect(payload['supported_roles'], ['controller@v1']);
      expect(payload.containsKey('player@v1_support'), isFalse);
      p.dispose();
    });

    test('metadata-only role has no support block', () {
      final p = SendspinProtocol(
        playerName: 'Display',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.metadata},
      );
      final parsed = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect(payload['supported_roles'], ['metadata@v1']);
      expect(payload.containsKey('player@v1_support'), isFalse);
      expect(payload.containsKey('metadata@v1_support'), isFalse);
      p.dispose();
    });

    test('artwork role sends no support object in client/hello', () {
      // rc1 declares artwork channels in client/state, not client/hello.
      final p = SendspinProtocol(
        playerName: 'Display',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(
            source: 'album',
            format: 'jpeg',
            mediaWidth: 512,
            mediaHeight: 512,
          ),
        ],
      );
      final parsed = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect(payload['supported_roles'], ['artwork@v1']);
      expect(payload.containsKey('artwork@v1_support'), isFalse);
      p.dispose();
    });

    test('multi-role advertises all roles and correct support blocks', () {
      final p = SendspinProtocol(
        playerName: 'Full Client',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        roles: const {
          SendspinRole.player,
          SendspinRole.controller,
          SendspinRole.metadata,
          SendspinRole.artwork,
        },
        artworkChannels: const [
          ArtworkChannel(
            source: 'album',
            format: 'jpeg',
            mediaWidth: 300,
            mediaHeight: 300,
          ),
          ArtworkChannel(
            source: 'artist',
            format: 'png',
            mediaWidth: 128,
            mediaHeight: 128,
          ),
        ],
      );
      final parsed = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final payload = parsed['payload'] as Map<String, dynamic>;
      final roles = (payload['supported_roles'] as List).cast<String>();
      expect(
          roles,
          containsAll([
            'player@v1',
            'controller@v1',
            'metadata@v1',
            'artwork@v1',
          ]));
      expect(payload.containsKey('player@v1_support'), isTrue);
      expect(payload.containsKey('artwork@v1_support'), isFalse);
      expect(payload.containsKey('controller@v1_support'), isFalse);
      expect(payload.containsKey('metadata@v1_support'), isFalse);
      p.dispose();
    });

    test('artwork role without channels throws ArgumentError', () {
      expect(
        () => SendspinProtocol(
          playerName: 'P',
          identity: testIdentity,
          unpairedAccess: true,
          bufferSeconds: 0,
          roles: const {SendspinRole.artwork},
        ),
        throwsArgumentError,
      );
    });

    test('artwork role with empty channels throws ArgumentError', () {
      expect(
        () => SendspinProtocol(
          playerName: 'P',
          identity: testIdentity,
          unpairedAccess: true,
          bufferSeconds: 0,
          roles: const {SendspinRole.artwork},
          artworkChannels: const [],
        ),
        throwsArgumentError,
      );
    });

    test('artwork role with more than 4 channels throws ArgumentError', () {
      expect(
        () => SendspinProtocol(
          playerName: 'P',
          identity: testIdentity,
          unpairedAccess: true,
          bufferSeconds: 0,
          roles: const {SendspinRole.artwork},
          artworkChannels: const [
            ArtworkChannel(
                source: 'album',
                format: 'jpeg',
                mediaWidth: 100,
                mediaHeight: 100),
            ArtworkChannel(
                source: 'artist',
                format: 'jpeg',
                mediaWidth: 100,
                mediaHeight: 100),
            ArtworkChannel(
                source: 'none',
                format: 'jpeg',
                mediaWidth: 100,
                mediaHeight: 100),
            ArtworkChannel(
                source: 'album',
                format: 'png',
                mediaWidth: 100,
                mediaHeight: 100),
            ArtworkChannel(
                source: 'artist',
                format: 'png',
                mediaWidth: 100,
                mediaHeight: 100),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('server/state metadata', () {
    late SendspinProtocol p;
    setUp(() {
      p = SendspinProtocol(
          playerName: 'T',
          identity: testIdentity,
          unpairedAccess: true,
          bufferSeconds: 2,
          roles: const {
            SendspinRole.player,
            SendspinRole.metadata,
            SendspinRole.controller
          });
    });
    tearDown(() => p.dispose());

    void sendMetadata(Map<String, dynamic> metadata) {
      serverSends(
          p,
          jsonEncode({
            'type': 'server/state',
            'payload': {'metadata': metadata},
          }));
    }

    test('populates SendspinMetadata and invokes onMetadataUpdate', () {
      SendspinMetadata? received;
      p.onMetadataUpdate = (m) => received = m;
      sendMetadata({
        'timestamp': 0,
        'title': 'Song',
        'artist': 'Artist',
        'album_artist': 'AA',
        'album': 'Album',
        'artwork_url': 'http://x/y.png',
        'year': 2024,
        'track': 3,
        'progress': {
          'track_progress': 5000,
          'track_duration': 240000,
          'playback_speed': 1000,
        },
      });
      expect(received, isNotNull);
      expect(received!.title, 'Song');
      expect(received!.artist, 'Artist');
      expect(received!.albumArtist, 'AA');
      expect(received!.album, 'Album');
      expect(received!.artworkUrl, 'http://x/y.png');
      expect(received!.year, 2024);
      expect(received!.track, 3);
      expect(received!.progress!.trackProgress, 5000);
      expect(received!.progress!.trackDuration, 240000);
      expect(received!.progress!.playbackSpeed, 1000);
      expect(p.state.metadata, same(received));
    });

    test('timestamp and year coerce from num', () {
      sendMetadata({'timestamp': 0.0, 'year': 2024.0});
      expect(p.state.metadata!.timestamp, 0);
      expect(p.state.metadata!.year, 2024);
    });

    test('a later state replaces the previous one instead of merging', () {
      sendMetadata({
        'timestamp': 0,
        'title': 'Song',
        'artist': 'Artist',
        'artwork_url': 'http://x/y.png',
        'year': 2024,
      });
      sendMetadata({'timestamp': 1, 'title': 'Next'});

      final m = p.state.metadata!;
      expect(m.title, 'Next');
      expect(m.artist, isNull, reason: 'omitted fields are absent in rc1');
      expect(m.artworkUrl, isNull);
      expect(m.year, isNull);
    });

    test('omitting progress clears the position', () {
      sendMetadata({
        'timestamp': 0,
        'title': 'Song',
        'progress': {
          'track_progress': 5000,
          'track_duration': 240000,
          'playback_speed': 1000,
        },
      });
      sendMetadata({'timestamp': 1, 'title': 'Song'});
      expect(p.state.metadata!.progress, isNull);
      expect(p.currentTrackPositionMs, isNull);
    });

    test('a metadata object without a timestamp is ignored', () {
      sendMetadata({'timestamp': 0, 'title': 'Song'});
      var calls = 0;
      p.onMetadataUpdate = (_) => calls++;
      sendMetadata({'title': 'No timestamp'});
      expect(p.state.metadata!.title, 'Song');
      expect(calls, 0);
    });

    test('omitting the metadata object leaves the state unchanged', () {
      sendMetadata({'timestamp': 0, 'title': 'Song'});
      var calls = 0;
      p.onMetadataUpdate = (_) => calls++;
      serverSends(
          p,
          jsonEncode({
            'type': 'server/state',
            'payload': {
              'controller': {
                'supported_commands': ['play'],
                'volume': 10,
                'muted': false,
              },
            },
          }));
      expect(p.state.metadata!.title, 'Song');
      expect(calls, 0);
    });
  });

  group('server/state scheduled metadata', () {
    const startUs = 1000000;

    /// Runs [body] under fake time with a protocol whose local clock follows
    /// it. [skewUs] lets a test move the local clock relative to the timers.
    void withProtocol(
      void Function(FakeAsync async, SendspinProtocol p, _Skew skew) body, {
      bool synchronized = true,
    }) {
      fakeAsync((async) {
        final skew = _Skew();
        final p = SendspinProtocol(
          playerName: 'T',
          identity: testIdentity,
          unpairedAccess: true,
          bufferSeconds: 2,
          roles: const {
            SendspinRole.player,
            SendspinRole.metadata,
            SendspinRole.controller
          },
          now: () => startUs + async.elapsed.inMicroseconds + skew.us,
        );
        if (synchronized) {
          // server clock == local clock.
          p.clock.update(0, 100, 1);
          p.clock.update(0, 100, 2);
        }
        body(async, p, skew);
        p.dispose();
      });
    }

    void sendMetadata(SendspinProtocol p, Map<String, dynamic> metadata) {
      serverSends(
          p,
          jsonEncode({
            'type': 'server/state',
            'payload': {'metadata': metadata},
          }));
    }

    const ms = Duration(milliseconds: 1);

    test('a past or present timestamp applies immediately', () {
      withProtocol((async, p, _) {
        sendMetadata(p, {'timestamp': startUs, 'title': 'Now'});
        expect(p.state.metadata!.title, 'Now');
        expect(p.pendingMetadata, isNull);
      });
    });

    test('a future timestamp is held as the pending update', () {
      withProtocol((async, p, _) {
        sendMetadata(p, {'timestamp': startUs - 1, 'title': 'Current'});
        final applied = <String?>[];
        p.onMetadataUpdate = (m) => applied.add(m.title);

        sendMetadata(p, {'timestamp': startUs + 5000000, 'title': 'Next'});
        async.elapse(ms * 4999);

        expect(p.state.metadata!.title, 'Current');
        expect(p.pendingMetadata!.title, 'Next');
        expect(applied, isEmpty);
      });
    });

    test('the pending update is applied when its time is reached', () {
      withProtocol((async, p, _) {
        sendMetadata(p, {'timestamp': startUs - 1, 'title': 'Current'});
        final applied = <String?>[];
        p.onMetadataUpdate = (m) => applied.add(m.title);

        sendMetadata(p, {'timestamp': startUs + 20000, 'title': 'Next'});
        async.elapse(ms * 20);

        expect(p.state.metadata!.title, 'Next');
        expect(p.pendingMetadata, isNull);
        expect(applied, ['Next']);
      });
    });

    test('a newer future update replaces the held one', () {
      withProtocol((async, p, _) {
        sendMetadata(p, {'timestamp': startUs + 20000, 'title': 'First'});
        sendMetadata(p, {'timestamp': startUs + 30000, 'title': 'Second'});
        expect(p.pendingMetadata!.title, 'Second');

        async.elapse(ms * 25);
        expect(p.state.metadata, isNull, reason: 'First must not be applied');
        async.elapse(ms * 5);
        expect(p.state.metadata!.title, 'Second');
      });
    });

    test('an immediate update discards the held pending update', () {
      withProtocol((async, p, _) {
        sendMetadata(p, {'timestamp': startUs + 20000, 'title': 'Scheduled'});
        sendMetadata(p, {'timestamp': startUs, 'title': 'Cancelled it'});
        expect(p.pendingMetadata, isNull);

        async.elapse(ms * 50);
        expect(p.state.metadata!.title, 'Cancelled it');
      });
    });

    test('omitting metadata leaves the pending update in place', () {
      withProtocol((async, p, _) {
        sendMetadata(p, {'timestamp': startUs + 5000000, 'title': 'Next'});
        serverSends(
            p,
            jsonEncode({
              'type': 'server/state',
              'payload': <String, dynamic>{},
            }));
        expect(p.pendingMetadata!.title, 'Next');
      });
    });

    test('waits out the remainder if the local clock is behind the timer', () {
      withProtocol((async, p, skew) {
        sendMetadata(p, {'timestamp': startUs + 20000, 'title': 'Next'});
        // The local clock now reads 10 ms earlier than when the timer was
        // armed, so when the timer fires the update is still 10 ms away.
        skew.us = -10000;
        async.elapse(ms * 20);
        expect(p.state.metadata, isNull);
        expect(p.pendingMetadata!.title, 'Next');

        async.elapse(ms * 10);
        expect(p.state.metadata!.title, 'Next');
      });
    });

    test('applies immediately while the time filter has no samples', () {
      withProtocol((async, p, _) {
        // With no samples the filter cannot place a server timestamp at all.
        sendMetadata(p, {'timestamp': startUs + 3600000000, 'title': 'First'});
        expect(p.state.metadata!.title, 'First');
        expect(p.pendingMetadata, isNull);
      }, synchronized: false);
    });

    test('re-evaluates the pending update when the time filter moves', () {
      withProtocol((async, p, _) {
        // Answer every client/time with a server clock [offsetUs] ahead.
        var offsetUs = 0;
        final server = connect(p, activate: false);
        server.onJson = (msg) {
          if (msg['type'] != 'client/time') return;
          final t = (msg['payload'] as Map)['client_transmitted'] as int;
          // The burst driver is not re-entrant; answer after it returns.
          scheduleMicrotask(() => server.sendJson('server/time', {
                'client_transmitted': t,
                'server_received': t + offsetUs,
                'server_transmitted': t + offsetUs,
              }));
        };

        // First burst, started by the activation: the filter believes
        // server == local.
        activate(server, p);
        async.flushMicrotasks();
        expect(p.clock.sampleCount, 1);

        const hourUs = 3600000000;
        sendMetadata(p, {'timestamp': startUs + hourUs, 'title': 'Held'});
        expect(p.pendingMetadata!.title, 'Held');

        // Second burst, 10 s later: the server clock is really 2 h ahead, so
        // the held timestamp is in the past.
        offsetUs = 2 * hourUs;
        async.elapse(const Duration(seconds: 10));

        expect(p.clock.sampleCount, 2);
        expect(p.state.metadata!.title, 'Held');
        expect(p.pendingMetadata, isNull);
      }, synchronized: false);
    });

    test('resetForNewConnection discards state and pending update', () {
      withProtocol((async, p, _) {
        sendMetadata(p, {'timestamp': startUs, 'title': 'Current'});
        sendMetadata(p, {'timestamp': startUs + 20000, 'title': 'Next'});
        p.resetForNewConnection();
        expect(p.state.metadata, isNull);
        expect(p.pendingMetadata, isNull);

        async.elapse(ms * 50);
        expect(p.state.metadata, isNull);
      });
    });

    test('dispose drops the current state and the pending update', () {
      withProtocol((async, p, _) {
        sendMetadata(p, {'timestamp': startUs, 'title': 'Current'});
        sendMetadata(p, {'timestamp': startUs + 20000, 'title': 'Next'});
        p.dispose();
        expect(p.pendingMetadata, isNull);
        expect(p.currentTrackPositionMs, isNull);
        async.elapse(ms * 50);
        expect(p.state.metadata, isNull);
      });
    });

    test('the timestamp is translated through the time filter', () {
      withProtocol((async, p, _) {
        // server = client + 10 s, so a server timestamp 5 s ahead of the
        // local clock value is actually 5 s in the past.
        p.clock.update(10000000, 100, 1);
        p.clock.update(10000000, 100, 2);
        sendMetadata(p, {'timestamp': startUs + 5000000, 'title': 'Past'});
        expect(p.state.metadata!.title, 'Past');
        expect(p.pendingMetadata, isNull);
      }, synchronized: false);
    });

    Map<String, dynamic> progress(int position, int duration, int speed) => {
          'track_progress': position,
          'track_duration': duration,
          'playback_speed': speed,
        };

    test('position is extrapolated from the current state', () {
      withProtocol((async, p, _) {
        sendMetadata(p,
            {'timestamp': startUs, 'progress': progress(5000, 240000, 1000)});
        async.elapse(const Duration(seconds: 2));
        expect(p.currentTrackPositionMs, 7000);
      });
    });

    test('position honours playback speed and clamps to the duration', () {
      withProtocol((async, p, _) {
        sendMetadata(
            p, {'timestamp': startUs, 'progress': progress(5000, 8000, 2000)});
        async.elapse(const Duration(seconds: 1));
        expect(p.currentTrackPositionMs, 7000);
        async.elapse(const Duration(seconds: 1));
        expect(p.currentTrackPositionMs, 8000);
      });
    });

    test('position is unbounded when the duration is unknown', () {
      withProtocol((async, p, _) {
        sendMetadata(
            p, {'timestamp': startUs, 'progress': progress(5000, 0, 1000)});
        async.elapse(const Duration(seconds: 10));
        expect(p.currentTrackPositionMs, 15000);
      });
    });

    test('position never goes below zero', () {
      withProtocol((async, p, skew) {
        sendMetadata(p,
            {'timestamp': startUs, 'progress': progress(1000, 240000, 1000)});
        skew.us = -5000000;
        expect(p.currentTrackPositionMs, 0);
      });
    });

    test('position never extrapolates from the pending update', () {
      withProtocol((async, p, _) {
        sendMetadata(
            p, {'timestamp': startUs, 'progress': progress(5000, 240000, 0)});
        sendMetadata(p, {
          'timestamp': startUs + 5000000,
          'progress': progress(0, 100000, 1000),
        });
        async.elapse(const Duration(seconds: 1));
        expect(p.currentTrackPositionMs, 5000);
      });
    });
  });

  group('server/state controller', () {
    late SendspinProtocol p;
    setUp(() {
      p = SendspinProtocol(
          playerName: 'T',
          identity: testIdentity,
          unpairedAccess: true,
          bufferSeconds: 2,
          roles: const {
            SendspinRole.player,
            SendspinRole.metadata,
            SendspinRole.controller
          });
    });
    tearDown(() => p.dispose());

    test(
        'server/state with controller populates SendspinControllerInfo and invokes onControllerUpdate',
        () {
      SendspinControllerInfo? received;
      p.onControllerUpdate = (c) => received = c;
      serverSends(
          p,
          jsonEncode({
            'type': 'server/state',
            'payload': {
              'controller': {
                'supported_commands': ['play', 'pause', 'next'],
                'volume': 55,
                'muted': true,
              },
            },
          }));
      expect(received, isNotNull);
      expect(received!.supportedCommands, ['play', 'pause', 'next']);
      expect(received!.volume, 55);
      expect(received!.muted, true);
      expect(p.state.controller, same(received));
    });

    test(
        'server/state controller filters non-string entries from supported_commands',
        () {
      serverSends(
          p,
          jsonEncode({
            'type': 'server/state',
            'payload': {
              'controller': {
                'supported_commands': ['play', 42, null, 'pause'],
              },
            },
          }));
      expect(p.state.controller!.supportedCommands, ['play', 'pause']);
    });

    test(
        'server/state controller with missing volume defaults to 0 and muted defaults to false',
        () {
      serverSends(
          p,
          jsonEncode({
            'type': 'server/state',
            'payload': {
              'controller': {
                'supported_commands': ['play'],
              },
            },
          }));
      expect(p.state.controller!.volume, 0);
      expect(p.state.controller!.muted, false);
    });
  });

  group('server/state combined', () {
    late SendspinProtocol p;
    setUp(() {
      p = SendspinProtocol(
          playerName: 'T',
          identity: testIdentity,
          unpairedAccess: true,
          bufferSeconds: 2,
          roles: const {
            SendspinRole.player,
            SendspinRole.metadata,
            SendspinRole.controller
          });
    });
    tearDown(() => p.dispose());

    test('server/state with neither metadata nor controller is a no-op', () {
      var metaFired = 0;
      var ctrlFired = 0;
      p.onMetadataUpdate = (_) => metaFired++;
      p.onControllerUpdate = (_) => ctrlFired++;
      serverSends(
          p,
          jsonEncode({
            'type': 'server/state',
            'payload': <String, dynamic>{},
          }));
      expect(metaFired, 0);
      expect(ctrlFired, 0);
      expect(p.state.metadata, isNull);
      expect(p.state.controller, isNull);
    });

    test(
        'server/state with both metadata and controller invokes both callbacks',
        () {
      var metaFired = 0;
      var ctrlFired = 0;
      p.onMetadataUpdate = (_) => metaFired++;
      p.onControllerUpdate = (_) => ctrlFired++;
      serverSends(
          p,
          jsonEncode({
            'type': 'server/state',
            'payload': {
              'metadata': {'timestamp': 0, 'title': 'T'},
              'controller': {'volume': 10},
            },
          }));
      expect(metaFired, 1);
      expect(ctrlFired, 1);
      expect(p.state.metadata!.title, 'T');
      expect(p.state.controller!.volume, 10);
    });
  });

  group('SendspinGroupState', () {
    test('fresh SendspinPlayerState has empty default groupState', () {
      const s = SendspinPlayerState();
      expect(s.groupState.playbackState, isNull);
      expect(s.groupState.groupId, isNull);
      expect(s.groupState.groupName, isNull);
    });
  });

  group('controller commands', () {
    test('sendControllerCommand sends client/command with controller payload',
        () {
      final p = SendspinProtocol(
        playerName: 'Remote',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      captureSent(p, sent);

      p.sendControllerCommand('play');

      expect(sent, hasLength(1));
      final parsed = jsonDecode(sent.first) as Map<String, dynamic>;
      expect(parsed['type'], 'client/command');
      final controller =
          (parsed['payload'] as Map)['controller'] as Map<String, dynamic>;
      expect(controller['command'], 'play');
      expect(controller.containsKey('volume'), isFalse);
      expect(controller.containsKey('mute'), isFalse);
      p.dispose();
    });

    test('sendControllerVolume sends volume command with volume param', () {
      final p = SendspinProtocol(
        playerName: 'Remote',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      captureSent(p, sent);

      p.sendControllerVolume(75);

      expect(sent, hasLength(1));
      final parsed = jsonDecode(sent.first) as Map<String, dynamic>;
      final controller =
          (parsed['payload'] as Map)['controller'] as Map<String, dynamic>;
      expect(controller['command'], 'volume');
      expect(controller['volume'], 75);
      p.dispose();
    });

    test('sendControllerMute sends mute command with mute param', () {
      final p = SendspinProtocol(
        playerName: 'Remote',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      captureSent(p, sent);

      p.sendControllerMute(true);

      expect(sent, hasLength(1));
      final parsed = jsonDecode(sent.first) as Map<String, dynamic>;
      final controller =
          (parsed['payload'] as Map)['controller'] as Map<String, dynamic>;
      expect(controller['command'], 'mute');
      expect(controller['mute'], true);
      p.dispose();
    });

    test('sendControllerCommand throws StateError without controller role', () {
      final p = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        roles: const {SendspinRole.player},
      );
      expect(() => p.sendControllerCommand('play'), throwsStateError);
      p.dispose();
    });

    test('sendControllerVolume throws StateError without controller role', () {
      final p = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      expect(() => p.sendControllerVolume(50), throwsStateError);
      p.dispose();
    });

    test('sendControllerMute throws StateError without controller role', () {
      final p = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
      );
      expect(() => p.sendControllerMute(true), throwsStateError);
      p.dispose();
    });

    test('all spec commands can be sent', () {
      final p = SendspinProtocol(
        playerName: 'Remote',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      captureSent(p, sent);

      const commands = [
        'play',
        'pause',
        'stop',
        'next',
        'previous',
        'repeat_off',
        'repeat_one',
        'repeat_all',
        'shuffle',
        'unshuffle',
        'switch',
      ];
      for (final cmd in commands) {
        p.sendControllerCommand(cmd);
      }

      expect(sent, hasLength(commands.length));
      for (int i = 0; i < commands.length; i++) {
        final parsed = jsonDecode(sent[i]) as Map<String, dynamic>;
        final controller =
            (parsed['payload'] as Map)['controller'] as Map<String, dynamic>;
        expect(controller['command'], commands[i]);
      }
      p.dispose();
    });

    test('sendControllerVolume throws RangeError for out-of-range values', () {
      final p = SendspinProtocol(
        playerName: 'Remote',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      connect(p);
      expect(() => p.sendControllerVolume(-1), throwsRangeError);
      expect(() => p.sendControllerVolume(101), throwsRangeError);
      // Boundary values should work
      p.sendControllerVolume(0);
      p.sendControllerVolume(100);
      p.dispose();
    });
  });

  group('artwork binary frames', () {
    Uint8List buildTypedFrame(int type, int timestampUs, List<int> payload) {
      final frame = Uint8List(9 + payload.length);
      frame[0] = type;
      ByteData.view(frame.buffer).setInt64(1, timestampUs, Endian.big);
      frame.setRange(9, frame.length, payload);
      return frame;
    }

    test('artwork role receives artwork frames via onArtworkFrame', () {
      final p = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(
              source: 'album',
              format: 'jpeg',
              mediaWidth: 100,
              mediaHeight: 100),
        ],
      );
      ArtworkFrame? received;
      p.onArtworkFrame = (f) => received = f;

      serverSendsBinary(p, buildTypedFrame(8, 555000, [0xFF, 0xD8, 0xFF]));

      expect(received, isNotNull);
      expect(received!.channel, 0);
      expect(received!.timestampUs, 555000);
      expect(received!.imageData, [0xFF, 0xD8, 0xFF]);
      p.dispose();
    });

    test('artwork frame type 11 maps to channel 3', () {
      final p = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(
              source: 'album',
              format: 'jpeg',
              mediaWidth: 100,
              mediaHeight: 100),
          ArtworkChannel(
              source: 'artist',
              format: 'jpeg',
              mediaWidth: 100,
              mediaHeight: 100),
          ArtworkChannel(
              source: 'none',
              format: 'jpeg',
              mediaWidth: 100,
              mediaHeight: 100),
          ArtworkChannel(
              source: 'album',
              format: 'png',
              mediaWidth: 100,
              mediaHeight: 100),
        ],
      );
      ArtworkFrame? received;
      p.onArtworkFrame = (f) => received = f;

      serverSendsBinary(p, buildTypedFrame(11, 999, [0x01]));

      expect(received, isNotNull);
      expect(received!.channel, 3);
      p.dispose();
    });

    test('artwork frames are dropped when artwork role is not active', () {
      final p = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        roles: const {SendspinRole.player},
      );
      ArtworkFrame? received;
      p.onArtworkFrame = (f) => received = f;

      serverSendsBinary(p, buildTypedFrame(8, 1, [0x01]));

      expect(received, isNull);
      p.dispose();
    });

    test('player frames still work alongside artwork role', () {
      final p = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        roles: const {SendspinRole.player, SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(
              source: 'album',
              format: 'jpeg',
              mediaWidth: 100,
              mediaHeight: 100),
        ],
      );
      AudioFrame? audioReceived;
      ArtworkFrame? artworkReceived;
      p.onAudioFrame = (f) => audioReceived = f;
      p.onArtworkFrame = (f) => artworkReceived = f;

      // Audio chunks carry the 13-byte rc1 header (4 extra send_ahead bytes).
      serverSendsBinary(
          p, buildTypedFrame(4, 100, [0x00, 0x00, 0x00, 0x00, 0x01, 0x02]));
      serverSendsBinary(p, buildTypedFrame(8, 200, [0xFF, 0xD8]));

      expect(audioReceived, isNotNull);
      expect(audioReceived!.type, 4);
      expect(artworkReceived, isNotNull);
      expect(artworkReceived!.channel, 0);
      p.dispose();
    });

    test('player frames dropped when player role not active', () {
      final p = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      AudioFrame? received;
      p.onAudioFrame = (f) => received = f;

      serverSendsBinary(p, buildTypedFrame(4, 1, [0x01]));

      expect(received, isNull);
      p.dispose();
    });
  });
}

/// Mutable offset applied to a test's injected local clock.
class _Skew {
  int us = 0;
}
