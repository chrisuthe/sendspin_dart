import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

import 'support/connected.dart';
import 'test_identity.dart';

/// Helper: builds a stream/start JSON message.
String _streamStart({
  String codec = 'pcm',
  int channels = 2,
  int sampleRate = 48000,
  int bitDepth = 16,
  String? codecHeader,
}) {
  final format = <String, dynamic>{
    'codec': codec,
    'channels': channels,
    'sample_rate': sampleRate,
    'bit_depth': bitDepth,
  };
  if (codecHeader != null) format['codec_header'] = codecHeader;
  return jsonEncode({
    'type': 'stream/start',
    'payload': {'player': format},
  });
}

/// Helper: builds a server/hello JSON message.
String _serverHello({String name = 'TestServer'}) {
  return jsonEncode({
    'type': 'server/hello',
    'payload': {'name': name},
  });
}

/// Helper: builds a binary audio frame (version=1, big-endian int64 timestamp, PCM data).
Uint8List _binaryFrame(int timestampUs, Int16List pcmSamples) {
  final audioBytes = Uint8List.view(pcmSamples.buffer);
  final frame = Uint8List(13 + audioBytes.length);
  frame[0] = 4; // message type: player audio chunk
  final view = ByteData.view(frame.buffer);
  view.setInt64(1, timestampUs, Endian.big);
  frame.setRange(13, frame.length, audioBytes);
  return frame;
}

/// A fake codec for testing codecFactory.
class _FakeCodec implements SendspinCodec {
  bool decoded = false;
  bool wasReset = false;
  bool wasDisposed = false;

  @override
  Int16List decode(Uint8List encodedData) {
    decoded = true;
    // Treat raw bytes as 16-bit PCM.
    final sampleCount = encodedData.length ~/ 2;
    final samples = Int16List(sampleCount);
    final view = ByteData.view(encodedData.buffer, encodedData.offsetInBytes,
        encodedData.lengthInBytes);
    for (int i = 0; i < sampleCount; i++) {
      samples[i] = view.getInt16(i * 2, Endian.little);
    }
    return samples;
  }

  @override
  void reset() => wasReset = true;

  @override
  void dispose() => wasDisposed = true;
}

void main() {
  group('SendspinPlayer', () {
    late SendspinPlayer player;

    setUp(() {
      player = SendspinPlayer(
        playerName: 'Test Player',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.metadata, SendspinRole.controller},
      );
      // Swallow outgoing text messages.
    });

    tearDown(() {
      player.dispose();
    });

    test('starts in disabled state', () {
      expect(player.state.connectionState, SendspinConnectionState.disabled);
    });

    test('delegates handleTextMessage to protocol (server/hello -> syncing)',
        () async {
      final states = <SendspinConnectionState>[];
      player.stateStream.listen((s) => states.add(s.connectionState));

      serverSends(player, _serverHello());
      await Future.delayed(Duration.zero);

      expect(states, contains(SendspinConnectionState.syncing));
      expect(player.state.connectionState, SendspinConnectionState.syncing);
    });

    test('calls onStreamStart with format after stream/start', () async {
      int? receivedSampleRate;
      int? receivedChannels;
      int? receivedBitDepth;
      player.onStreamStart = (sr, ch, bd) {
        receivedSampleRate = sr;
        receivedChannels = ch;
        receivedBitDepth = bd;
      };

      serverSends(player, _serverHello());
      serverSends(
          player,
          _streamStart(
            sampleRate: 44100,
            channels: 2,
            bitDepth: 16,
          ));

      expect(receivedSampleRate, 44100);
      expect(receivedChannels, 2);
      expect(receivedBitDepth, 16);
    });

    test('accepts custom codecFactory', () {
      final fakeCodec = _FakeCodec();
      final customPlayer = SendspinPlayer(
        playerName: 'Custom',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        codecFactory: (codec, bitDepth, channels, sampleRate) => fakeCodec,
      );

      serverSends(customPlayer, _serverHello());
      serverSends(customPlayer, _streamStart());

      // Send a binary frame.
      final pcm = Int16List(24000);
      for (int i = 0; i < pcm.length; i++) pcm[i] = 42;
      serverSendsBinary(customPlayer, _binaryFrame(1000000, pcm));

      expect(fakeCodec.decoded, isTrue);
      customPlayer.dispose();
    });

    test('exposes protocol for direct access', () {
      expect(player.protocol, isA<SendspinProtocol>());
      expect(player.protocol.playerName, 'Test Player');
    });

    test('delegates buildClientHello to protocol', () {
      final hello = player.buildClientHello();
      final parsed = jsonDecode(hello) as Map<String, dynamic>;
      expect(parsed['type'], 'client/hello');
      final payload = parsed['payload'] as Map<String, dynamic>;
      expect(payload.containsKey('client_id'), isFalse);
      expect(payload['name'], 'Test Player');
    });

    test('initialOutputDelayMs is exposed via outputDelayMs getter', () {
      final p = SendspinPlayer(
        playerName: 'Test',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        initialOutputDelayMs: 800,
      );
      expect(p.outputDelayMs, 800);
      p.dispose();
    });

    test('buildClientGoodbye forwards to protocol', () {
      final msg = player.buildClientGoodbye(SendspinGoodbyeReason.restart);
      final parsed = jsonDecode(msg) as Map<String, dynamic>;
      expect(parsed['type'], 'client/goodbye');
      expect((parsed['payload'] as Map)['reason'], 'restart');
    });

    test('sendGoodbye dispatches via wired onSendText', () {
      final sent = <String>[];
      captureSent(player, sent);
      player.sendGoodbye(SendspinGoodbyeReason.userRequest);
      expect(sent, hasLength(1));
      expect(sent.first, contains('"reason":"user_request"'));
    });

    test('onMetadataUpdate fires when server/state with metadata is handled',
        () {
      SendspinMetadata? received;
      player.onMetadataUpdate = (m) => received = m;
      serverSends(
          player,
          jsonEncode({
            'type': 'server/state',
            'payload': {
              'metadata': {'timestamp': 0, 'title': 'Song', 'artist': 'A'},
            },
          }));
      expect(received, isNotNull);
      expect(received!.title, 'Song');
      expect(received!.artist, 'A');
      expect(player.state.metadata!.title, 'Song');
    });

    test(
        'onControllerUpdate fires when server/state with controller is handled',
        () {
      SendspinControllerInfo? received;
      player.onControllerUpdate = (c) => received = c;
      serverSends(
          player,
          jsonEncode({
            'type': 'server/state',
            'payload': {
              'controller': {
                'supported_commands': ['play'],
                'volume': 30,
                'muted': false,
              },
            },
          }));
      expect(received, isNotNull);
      expect(received!.volume, 30);
      expect(player.state.controller!.supportedCommands, ['play']);
    });

    test('onGroupUpdate fires when group/update message is handled', () {
      SendspinGroupState? received;
      player.onGroupUpdate = (g) => received = g;

      serverSends(
          player,
          jsonEncode({
            'type': 'group/update',
            'payload': {
              'playback_state': 'playing',
              'group_id': 'g1',
              'group_name': 'Kitchen',
            },
          }));

      expect(received, isNotNull);
      expect(received!.playbackState, SendspinGroupPlaybackState.playing);
      expect(received!.groupId, 'g1');
      expect(received!.groupName, 'Kitchen');
    });

    test('additionalRoles are passed through to protocol', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller, SendspinRole.metadata},
      );
      expect(
          p.protocol.roles,
          containsAll([
            SendspinRole.player,
            SendspinRole.controller,
            SendspinRole.metadata,
          ]));
      p.dispose();
    });

    test('player role is always included even if not in additionalRoles', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller},
      );
      expect(p.protocol.roles, contains(SendspinRole.player));
      p.dispose();
    });

    test('artwork additionalRole with channels is passed to protocol', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(
            source: 'album',
            format: 'jpeg',
            mediaWidth: 300,
            mediaHeight: 300,
          ),
        ],
      );
      expect(p.protocol.roles, contains(SendspinRole.artwork));

      final hello = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final payload = hello['payload'] as Map<String, dynamic>;
      expect(payload['supported_roles'], contains('artwork@v1'));
      p.dispose();
    });

    test('sendControllerCommand delegates to protocol', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      captureSent(p, sent);

      p.sendControllerCommand('pause');

      expect(sent, hasLength(1));
      final parsed = jsonDecode(sent.first) as Map<String, dynamic>;
      expect(parsed['type'], 'client/command');
      final controller =
          (parsed['payload'] as Map)['controller'] as Map<String, dynamic>;
      expect(controller['command'], 'pause');
      p.dispose();
    });

    test('sendControllerVolume delegates to protocol', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      captureSent(p, sent);

      p.sendControllerVolume(60);

      expect(sent, hasLength(1));
      final parsed = jsonDecode(sent.first) as Map<String, dynamic>;
      final controller =
          (parsed['payload'] as Map)['controller'] as Map<String, dynamic>;
      expect(controller['command'], 'volume');
      expect(controller['volume'], 60);
      p.dispose();
    });

    test('sendControllerMute delegates to protocol', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      captureSent(p, sent);

      p.sendControllerMute(false);

      expect(sent, hasLength(1));
      final parsed = jsonDecode(sent.first) as Map<String, dynamic>;
      final controller =
          (parsed['payload'] as Map)['controller'] as Map<String, dynamic>;
      expect(controller['command'], 'mute');
      expect(controller['mute'], false);
      p.dispose();
    });

    test('onArtworkFrame callback fires via player delegation', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        identity: testIdentity,
        unpairedAccess: true,
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(
            source: 'album',
            format: 'jpeg',
            mediaWidth: 100,
            mediaHeight: 100,
          ),
        ],
      );

      ArtworkFrame? received;
      p.onArtworkFrame = (f) => received = f;

      final frame = Uint8List(12);
      frame[0] = 8; // artwork type
      ByteData.view(frame.buffer).setInt64(1, 777, Endian.big);
      frame[9] = 0xFF;
      frame[10] = 0xD8;
      frame[11] = 0xFF;
      serverSendsBinary(p, frame);

      expect(received, isNotNull);
      expect(received!.channel, 0);
      expect(received!.timestampUs, 777);
      p.dispose();
    });
  });
}
