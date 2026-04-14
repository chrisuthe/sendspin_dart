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

    test('server/hello with connection_reason playback', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA', 'connection_reason': 'playback'},
      }));
      expect(
          protocol.state.connectionReason, SendspinConnectionReason.playback);
    });

    test('server/hello with connection_reason discovery', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA', 'connection_reason': 'discovery'},
      }));
      expect(
          protocol.state.connectionReason, SendspinConnectionReason.discovery);
    });

    test('server/hello with no connection_reason defaults to unknown', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      expect(protocol.state.connectionReason, SendspinConnectionReason.unknown);
    });

    test('server/hello with bogus connection_reason falls back to unknown', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA', 'connection_reason': 'bogus'},
      }));
      expect(protocol.state.connectionReason, SendspinConnectionReason.unknown);
    });

    test('server/hello parses active_roles', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {
          'name': 'MA',
          'active_roles': ['player@v1'],
        },
      }));
      expect(protocol.state.activeRoles, ['player@v1']);
    });

    test('server/hello with no active_roles defaults to empty list', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      expect(protocol.state.activeRoles, <String>[]);
    });

    test('server/hello filters non-string entries from active_roles', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {
          'name': 'MA',
          'active_roles': ['player@v1', 42],
        },
      }));
      expect(protocol.state.activeRoles, ['player@v1']);
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
      data[0] = 4; // message type: player audio frame
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

    test('emits onStreamEnd on stream/end and transitions to syncing',
        () async {
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
      frame[0] = 4;
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
      expect(receivedVolume, 1.0);
    });

    test('handles set_static_delay command and invokes callback', () async {
      int? receivedDelay;
      protocol.onStaticDelayChanged = (d) => receivedDelay = d;

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/command',
        'payload': {
          'player': {'command': 'set_static_delay', 'static_delay_ms': 250},
        },
      }));

      await Future.delayed(Duration.zero);
      expect(receivedDelay, 250);
      expect(protocol.staticDelayMs, 250);
      expect(protocol.state.staticDelayMs, 250);
    });

    test('clamps set_static_delay above max to 5000', () async {
      int? receivedDelay;
      protocol.onStaticDelayChanged = (d) => receivedDelay = d;

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/command',
        'payload': {
          'player': {'command': 'set_static_delay', 'static_delay_ms': 99999},
        },
      }));

      await Future.delayed(Duration.zero);
      expect(receivedDelay, 5000);
      expect(protocol.staticDelayMs, 5000);
    });

    test('clamps negative set_static_delay to 0', () async {
      int? receivedDelay;
      protocol.onStaticDelayChanged = (d) => receivedDelay = d;

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/command',
        'payload': {
          'player': {'command': 'set_static_delay', 'static_delay_ms': -100},
        },
      }));

      await Future.delayed(Duration.zero);
      expect(receivedDelay, 0);
      expect(protocol.staticDelayMs, 0);
    });

    test('staticDelayMs getter reflects latest value across updates', () {
      expect(protocol.staticDelayMs, 0);

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/command',
        'payload': {
          'player': {'command': 'set_static_delay', 'static_delay_ms': 100},
        },
      }));
      expect(protocol.staticDelayMs, 100);

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/command',
        'payload': {
          'player': {'command': 'set_static_delay', 'static_delay_ms': 500},
        },
      }));
      expect(protocol.staticDelayMs, 500);
    });

    test('initialStaticDelayMs sets staticDelayMs at construction', () {
      final p = SendspinProtocol(
        playerName: 'Test',
        clientId: 'id',
        bufferSeconds: 5,
        initialStaticDelayMs: 1500,
      );
      expect(p.staticDelayMs, 1500);
      p.dispose();
    });

    test('initialStaticDelayMs is reflected in buildClientState', () {
      final p = SendspinProtocol(
        playerName: 'Test',
        clientId: 'id',
        bufferSeconds: 5,
        initialStaticDelayMs: 1500,
      );
      final parsed = jsonDecode(p.buildClientState()) as Map<String, dynamic>;
      expect(
        (parsed['payload']['player'] as Map)['static_delay_ms'],
        1500,
      );
      p.dispose();
    });

    test('initialStaticDelayMs above max is clamped to 5000', () {
      final p = SendspinProtocol(
        playerName: 'Test',
        clientId: 'id',
        bufferSeconds: 5,
        initialStaticDelayMs: 99999,
      );
      expect(p.staticDelayMs, 5000);
      p.dispose();
    });

    test('negative initialStaticDelayMs is clamped to 0', () {
      final p = SendspinProtocol(
        playerName: 'Test',
        clientId: 'id',
        bufferSeconds: 5,
        initialStaticDelayMs: -50,
      );
      expect(p.staticDelayMs, 0);
      p.dispose();
    });

    test('buildClientState defaults to synchronized', () {
      final parsed =
          jsonDecode(protocol.buildClientState()) as Map<String, dynamic>;
      expect(parsed['payload']['state'], 'synchronized');
    });

    test('setPipelineError(true) flips buildClientState to error', () {
      protocol.onSendText = (_) {};
      protocol.setPipelineError(true);
      final parsed =
          jsonDecode(protocol.buildClientState()) as Map<String, dynamic>;
      expect(parsed['payload']['state'], 'error');
    });

    test('setPipelineError(true) emits client/state via onSendText', () {
      final sent = <String>[];
      protocol.onSendText = sent.add;
      protocol.setPipelineError(true);
      expect(sent, hasLength(1));
      final parsed = jsonDecode(sent.first) as Map<String, dynamic>;
      expect(parsed['type'], 'client/state');
      expect(parsed['payload']['state'], 'error');
    });

    test('setPipelineError is idempotent when repeated', () {
      final sent = <String>[];
      protocol.onSendText = sent.add;
      protocol.setPipelineError(true);
      protocol.setPipelineError(true);
      expect(sent, hasLength(1));
    });

    test('setPipelineError(false) after error sends synchronized report', () {
      final sent = <String>[];
      protocol.onSendText = sent.add;
      protocol.setPipelineError(true);
      protocol.setPipelineError(false);
      expect(sent, hasLength(2));
      final recovered = jsonDecode(sent[1]) as Map<String, dynamic>;
      expect(recovered['payload']['state'], 'synchronized');
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
      protocol.onSendText = sent.add;
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

    Uint8List buildTypedFrame(int type, int timestampUs, List<int> payload) {
      final frame = Uint8List(9 + payload.length);
      frame[0] = type;
      ByteData.view(frame.buffer).setInt64(1, timestampUs, Endian.big);
      frame.setRange(9, frame.length, payload);
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
      protocol.handleBinaryMessage(buildTypedFrame(4, 1, [0x01]));
      expect(received, isNotNull);
      expect(received!.type, 4);
    });

    test('handleBinaryMessage emits onAudioFrame for player type 7', () {
      AudioFrame? received;
      protocol.onAudioFrame = (f) => received = f;
      protocol.handleBinaryMessage(buildTypedFrame(7, 1, [0x01]));
      expect(received, isNotNull);
      expect(received!.type, 7);
    });

    test('handleBinaryMessage drops artwork frame type 8', () {
      AudioFrame? received;
      protocol.onAudioFrame = (f) => received = f;
      protocol.handleBinaryMessage(buildTypedFrame(8, 1, [0x01]));
      expect(received, isNull);
    });

    test('handleBinaryMessage drops reserved type 0', () {
      AudioFrame? received;
      protocol.onAudioFrame = (f) => received = f;
      protocol.handleBinaryMessage(buildTypedFrame(0, 1, [0x01]));
      expect(received, isNull);
    });

    test('buildClientHello buffer_capacity uses 48k stereo 16-bit default', () {
      final p = SendspinProtocol(
        playerName: 'p',
        clientId: 'c',
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
        clientId: 'c',
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
        clientId: 'c',
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

      protocol.handleTextMessage(jsonEncode({
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

    test('group/update delta merges with existing state', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'group/update',
        'payload': {
          'playback_state': 'playing',
          'group_id': 'g1',
          'group_name': 'Kitchen',
        },
      }));

      protocol.handleTextMessage(jsonEncode({
        'type': 'group/update',
        'payload': {'playback_state': 'stopped'},
      }));

      expect(protocol.state.groupState.playbackState,
          SendspinGroupPlaybackState.stopped);
      expect(protocol.state.groupState.groupId, 'g1');
      expect(protocol.state.groupState.groupName, 'Kitchen');
    });

    test('group/update with playback_state stopped', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'group/update',
        'payload': {'playback_state': 'stopped'},
      }));
      expect(protocol.state.groupState.playbackState,
          SendspinGroupPlaybackState.stopped);
    });

    test('group/update with unknown playback_state falls back to unknown', () {
      protocol.handleTextMessage(jsonEncode({
        'type': 'group/update',
        'payload': {'playback_state': 'bogus'},
      }));
      expect(protocol.state.groupState.playbackState,
          SendspinGroupPlaybackState.unknown);
    });
  });

  group('server/state metadata', () {
    late SendspinProtocol p;
    setUp(() {
      p = SendspinProtocol(playerName: 'T', clientId: 'c', bufferSeconds: 2);
    });
    tearDown(() => p.dispose());

    test(
        'server/state with full metadata populates SendspinMetadata and invokes onMetadataUpdate',
        () {
      SendspinMetadata? received;
      p.onMetadataUpdate = (m) => received = m;
      p.handleTextMessage(jsonEncode({
        'type': 'server/state',
        'payload': {
          'metadata': {
            'timestamp': 123456789,
            'title': 'Song',
            'artist': 'Artist',
            'album_artist': 'AA',
            'album': 'Album',
            'artwork_url': 'http://x/y.png',
            'year': 2024,
            'track': 3,
            'repeat': 'one',
            'shuffle': true,
          },
        },
      }));
      expect(received, isNotNull);
      expect(received!.title, 'Song');
      expect(received!.artist, 'Artist');
      expect(received!.albumArtist, 'AA');
      expect(received!.album, 'Album');
      expect(received!.artworkUrl, 'http://x/y.png');
      expect(received!.year, 2024);
      expect(received!.track, 3);
      expect(received!.repeat, SendspinRepeatMode.one);
      expect(received!.shuffle, true);
      expect(p.state.metadata, same(received));
    });

    test(
        'server/state metadata with progress object populates SendspinMetadataProgress',
        () {
      p.handleTextMessage(jsonEncode({
        'type': 'server/state',
        'payload': {
          'metadata': {
            'progress': {
              'track_progress': 5000,
              'track_duration': 240000,
              'playback_speed': 1000,
            },
          },
        },
      }));
      final prog = p.state.metadata!.progress!;
      expect(prog.trackProgress, 5000);
      expect(prog.trackDuration, 240000);
      expect(prog.playbackSpeed, 1000);
    });

    test('server/state metadata with null title clears title', () {
      p.handleTextMessage(jsonEncode({
        'type': 'server/state',
        'payload': {
          'metadata': {'title': null, 'artist': 'A'},
        },
      }));
      expect(p.state.metadata!.title, isNull);
      expect(p.state.metadata!.artist, 'A');
    });

    test('server/state metadata repeat "all" parses correctly', () {
      p.handleTextMessage(jsonEncode({
        'type': 'server/state',
        'payload': {
          'metadata': {'repeat': 'all'},
        },
      }));
      expect(p.state.metadata!.repeat, SendspinRepeatMode.all);
    });

    test('server/state metadata repeat null becomes unknown', () {
      p.handleTextMessage(jsonEncode({
        'type': 'server/state',
        'payload': {
          'metadata': {'repeat': null},
        },
      }));
      expect(p.state.metadata!.repeat, SendspinRepeatMode.unknown);
    });

    test('server/state metadata with no progress object leaves progress null',
        () {
      p.handleTextMessage(jsonEncode({
        'type': 'server/state',
        'payload': {
          'metadata': {'title': 'X'},
        },
      }));
      expect(p.state.metadata!.progress, isNull);
    });

    test('server/state metadata timestamp and year coerce from num', () {
      p.handleTextMessage(jsonEncode({
        'type': 'server/state',
        'payload': {
          'metadata': {'timestamp': 1234.0, 'year': 2023.0, 'track': 2.0},
        },
      }));
      expect(p.state.metadata!.timestamp, 1234);
      expect(p.state.metadata!.year, 2023);
      expect(p.state.metadata!.track, 2);
    });
  });

  group('server/state controller', () {
    late SendspinProtocol p;
    setUp(() {
      p = SendspinProtocol(playerName: 'T', clientId: 'c', bufferSeconds: 2);
    });
    tearDown(() => p.dispose());

    test(
        'server/state with controller populates SendspinControllerInfo and invokes onControllerUpdate',
        () {
      SendspinControllerInfo? received;
      p.onControllerUpdate = (c) => received = c;
      p.handleTextMessage(jsonEncode({
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
      p.handleTextMessage(jsonEncode({
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
      p.handleTextMessage(jsonEncode({
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
      p = SendspinProtocol(playerName: 'T', clientId: 'c', bufferSeconds: 2);
    });
    tearDown(() => p.dispose());

    test('server/state with neither metadata nor controller is a no-op', () {
      var metaFired = 0;
      var ctrlFired = 0;
      p.onMetadataUpdate = (_) => metaFired++;
      p.onControllerUpdate = (_) => ctrlFired++;
      p.handleTextMessage(jsonEncode({
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
      p.handleTextMessage(jsonEncode({
        'type': 'server/state',
        'payload': {
          'metadata': {'title': 'T'},
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
    test('mergeDelta preserves fields not present in delta', () {
      const base = SendspinGroupState(
        playbackState: SendspinGroupPlaybackState.playing,
        groupId: 'g1',
        groupName: 'Kitchen',
      );
      final merged =
          base.mergeDelta(const SendspinGroupState(groupName: 'Living Room'));
      expect(merged.playbackState, SendspinGroupPlaybackState.playing);
      expect(merged.groupId, 'g1');
      expect(merged.groupName, 'Living Room');
    });

    test('fresh SendspinPlayerState has empty default groupState', () {
      const s = SendspinPlayerState();
      expect(s.groupState.playbackState, isNull);
      expect(s.groupState.groupId, isNull);
      expect(s.groupState.groupName, isNull);
    });
  });
}
