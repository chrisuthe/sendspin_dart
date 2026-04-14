# sendspin_dart

Pure Dart implementation of the [Sendspin](https://sendspin-audio.com) streaming audio protocol, designed for use with [Music Assistant](https://music-assistant.io).

## What is Sendspin?

Sendspin is a low-latency streaming audio protocol that enables synchronized multi-room audio playback. It uses WebSocket transport with NTP-style clock synchronization and a jitter buffer to deliver glitch-free audio across devices.

## What this package provides

- **`SendspinClient`** -- Protocol state machine handling the full Sendspin handshake, clock sync, and audio pipeline
- **`SendspinClock`** -- Kalman filter for NTP-style time synchronization between client and server
- **`SendspinBuffer`** -- Pull-based jitter buffer with sync corrections (deadband, micro-correction, re-anchor)
- **`SendspinCodec`** -- Abstract codec interface with built-in PCM decoder (16/24/32-bit)
- **`AudioSink`** -- Abstract interface for platform-specific audio output

This is a **pure Dart** package with no Flutter dependency. It can be used in Flutter apps, Dart CLI tools, or server-side Dart.

## Usage

```dart
import 'package:sendspin_dart/sendspin_dart.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() async {
  // Connect to a Sendspin server (e.g. Music Assistant)
  final ws = WebSocketChannel.connect(Uri.parse('ws://192.168.1.100:8765'));

  // Create the protocol client
  final client = SendspinClient(
    playerName: 'Living Room Speaker',
    clientId: 'my-unique-id',
    bufferSeconds: 5,
    deviceInfo: DeviceInfo(
      productName: 'MyApp',
      manufacturer: 'MyCorp',
      softwareVersion: '1.0.0',
    ),
  );

  // Wire up WebSocket I/O
  client.onSendText = (text) => ws.sink.add(text);

  client.onStreamStart = (sampleRate, channels, bitDepth) {
    // Initialize your AudioSink implementation here
    print('Stream started: ${sampleRate}Hz ${channels}ch ${bitDepth}bit');
  };

  client.onStreamStop = () {
    print('Stream stopped');
  };

  client.onVolumeChanged = (volume, muted) {
    // Apply volume to your AudioSink
  };

  // Listen for messages
  ws.stream.listen((message) {
    if (message is String) {
      client.handleTextMessage(message);
    } else if (message is List<int>) {
      client.handleBinaryMessage(Uint8List.fromList(message));
    }
  });

  // Send the handshake
  ws.sink.add(client.buildClientHello());

  // Pull decoded PCM samples in your audio callback
  // final samples = client.pullSamples(frameCount * channels);
}
```

## AudioSink interface

Implement `AudioSink` for your platform to handle actual audio output:

```dart
class MyAudioSink implements AudioSink {
  @override
  Future<void> initialize({
    required int sampleRate,
    required int channels,
    required int bitDepth,
  }) async {
    // Set up your audio output (WASAPI, PulseAudio, CoreAudio, etc.)
  }

  @override
  Future<void> writeSamples(Uint8List samples) async {
    // Send PCM data to the audio hardware
  }

  // ... implement start(), stop(), setVolume(), setMuted(), dispose()
}
```

## Custom codecs

The built-in codec factory only supports PCM. For FLAC or other codecs, provide a `codecFactory`:

```dart
final client = SendspinClient(
  playerName: 'My Player',
  clientId: 'id',
  bufferSeconds: 5,
  supportedFormats: [
    AudioFormat(codec: 'flac', channels: 2, sampleRate: 48000, bitDepth: 16),
    AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
  ],
  codecFactory: (codec, bitDepth, channels, sampleRate) {
    if (codec == 'flac') return MyFlacCodec(bitDepth: bitDepth, ...);
    return null; // fall back to built-in
  },
);
```

## Protocol flow

```
Client                          Server
  |                               |
  |--- client/hello ------------->|   Handshake with capabilities
  |<-- server/hello --------------|   Server accepts, assigns role
  |                               |
  |--- client/time -------------->|   Clock sync (burst of 5)
  |<-- server/time ---------------|   NTP-style round-trip
  |   (repeat every 2s)          |
  |                               |
  |--- client/state ------------->|   Report volume, sync state
  |                               |
  |<-- stream/start --------------|   Audio format negotiation
  |<-- [binary frames] -----------|   Timestamped audio data
  |<-- stream/clear --------------|   Flush buffer (e.g. seek)
  |<-- stream/end ----------------|   Playback stopped
  |                               |
  |<-- server/command ------------|   Volume/mute changes
  |--- client/state ------------->|   Acknowledge new state
```

## Discovery (mDNS)

The Sendspin spec recommends advertising players via mDNS on
`_sendspin._tcp.local.` (port 8928) and/or discovering servers on
`_sendspin-server._tcp.local.` (port 8927). This library does not ship
any mDNS implementation -- discovery is intentionally left to the consumer
app, since platform-appropriate mDNS stacks differ between Flutter,
CLI, and server-side Dart.

For Flutter apps, packages like `multicast_dns` or `nsd` work well. Once
you have a server URL, pass it to your WebSocket transport and feed
incoming messages through `SendspinClient.handleTextMessage` and
`handleBinaryMessage` as shown above.

## License

MIT
