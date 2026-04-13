import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

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

/// Helper: builds a stream/end JSON message.
String _streamEnd() => jsonEncode({'type': 'stream/end', 'payload': {}});

/// Helper: builds a stream/clear JSON message.
String _streamClear() => jsonEncode({'type': 'stream/clear', 'payload': {}});

/// Helper: builds a binary audio frame (version=1, big-endian int64 timestamp, PCM data).
Uint8List _binaryFrame(int timestampUs, Int16List pcmSamples) {
  final audioBytes = Uint8List.view(pcmSamples.buffer);
  final frame = Uint8List(9 + audioBytes.length);
  frame[0] = 1; // version
  final view = ByteData.view(frame.buffer);
  view.setInt64(1, timestampUs, Endian.big);
  frame.setRange(9, frame.length, audioBytes);
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
        clientId: 'test-id',
        bufferSeconds: 5,
      );
      // Swallow outgoing text messages.
      player.onSendText = (_) {};
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

      player.handleTextMessage(_serverHello());
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

      player.handleTextMessage(_serverHello());
      player.handleTextMessage(_streamStart(
        sampleRate: 44100,
        channels: 2,
        bitDepth: 16,
      ));

      expect(receivedSampleRate, 44100);
      expect(receivedChannels, 2);
      expect(receivedBitDepth, 16);
    });

    test('decodes binary frames and makes samples available via pullSamples',
        () {
      player.handleTextMessage(_serverHello());
      player.handleTextMessage(_streamStart(
        sampleRate: 48000,
        channels: 2,
        bitDepth: 16,
      ));

      // Send enough audio to exceed the 200ms startup buffer.
      // 48000 Hz * 2 channels * 0.25 seconds = 24000 samples.
      final pcm = Int16List(24000);
      for (int i = 0; i < pcm.length; i++) {
        pcm[i] = 1000; // non-zero so we can detect it
      }
      player.handleBinaryMessage(_binaryFrame(1000000, pcm));

      // Pull some samples — should be non-silent.
      final pulled = player.pullSamples(960);
      final hasNonZero = pulled.any((s) => s != 0);
      expect(hasNonZero, isTrue);
    });

    test('pullSamples returns silence when not streaming', () {
      final samples = player.pullSamples(960);
      expect(samples.length, 960);
      expect(samples.every((s) => s == 0), isTrue);
    });

    test('stream/end cleans up codec and buffer, calls onStreamStop', () {
      bool stopCalled = false;
      player.onStreamStop = () => stopCalled = true;

      player.handleTextMessage(_serverHello());
      player.handleTextMessage(_streamStart());
      player.handleTextMessage(_streamEnd());

      expect(stopCalled, isTrue);
      // After stream/end, pullSamples should return silence.
      final samples = player.pullSamples(960);
      expect(samples.every((s) => s == 0), isTrue);
    });

    test('stream/clear flushes buffer and resets codec', () {
      player.handleTextMessage(_serverHello());
      player.handleTextMessage(_streamStart());

      // Add some audio data.
      final pcm = Int16List(24000);
      for (int i = 0; i < pcm.length; i++) {
        pcm[i] = 500;
      }
      player.handleBinaryMessage(_binaryFrame(1000000, pcm));

      // Clear the stream.
      player.handleTextMessage(_streamClear());

      // Buffer should be flushed — pull returns silence until startup met again.
      final samples = player.pullSamples(960);
      expect(samples.every((s) => s == 0), isTrue);
    });

    test('accepts custom codecFactory', () {
      final fakeCodec = _FakeCodec();
      final customPlayer = SendspinPlayer(
        playerName: 'Custom',
        clientId: 'custom-id',
        bufferSeconds: 5,
        codecFactory: (codec, bitDepth, channels, sampleRate) => fakeCodec,
      );
      customPlayer.onSendText = (_) {};

      customPlayer.handleTextMessage(_serverHello());
      customPlayer.handleTextMessage(_streamStart());

      // Send a binary frame.
      final pcm = Int16List(24000);
      for (int i = 0; i < pcm.length; i++) pcm[i] = 42;
      customPlayer.handleBinaryMessage(_binaryFrame(1000000, pcm));

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
      expect(payload['client_id'], 'test-id');
      expect(payload['name'], 'Test Player');
    });

    test(
        'track switch (second stream/start while streaming) flushes existing buffer',
        () {
      player.handleTextMessage(_serverHello());
      player.handleTextMessage(_streamStart(sampleRate: 48000));

      // Add audio to the first stream.
      final pcm = Int16List(24000);
      for (int i = 0; i < pcm.length; i++) pcm[i] = 999;
      player.handleBinaryMessage(_binaryFrame(1000000, pcm));

      // Second stream/start (track switch).
      int startCallCount = 0;
      player.onStreamStart = (_, __, ___) => startCallCount++;
      player.handleTextMessage(_streamStart(sampleRate: 44100));

      expect(startCallCount, 1);

      // Buffer was flushed — pullSamples returns silence until new startup met.
      final samples = player.pullSamples(960);
      expect(samples.every((s) => s == 0), isTrue);
    });
  });
}
