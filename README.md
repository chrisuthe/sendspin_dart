# sendspin_dart

Pure Dart client library for the [Sendspin](https://sendspin-audio.com) synchronized multi-room audio protocol, as used by [Music Assistant](https://music-assistant.io).

It implements [Sendspin 1.0.0-rc1](https://github.com/Sendspin/spec/tree/1.0.0-rc1). rc1 is a wire break from earlier drafts: every connection is encrypted, so this version cannot talk to a pre-rc1 server, and versions up to 0.0.7 cannot talk to an rc1 server.

This is a **pure Dart** package with no Flutter dependency. It has no socket, no audio output and no mDNS of its own: the consumer supplies those.

## What it provides

| Class | Use it for |
|---|---|
| `SendspinPlayer` | A complete player: protocol, clock sync, decoding and a clock-scheduled jitter buffer. Most apps want this. |
| `SendspinProtocol` | The protocol alone, with no codec or buffer: visualizers, controllers, metadata displays, protocol inspectors. |
| `SendspinIdentity`, `SendspinIdentityStore` | The device's Curve25519 identity and where it is kept. |
| `SendspinPairing`, `SendspinPairingStore` | The device's pairing PSK and pairing records, and where they are kept. |
| `SendspinCodec` | Codec interface. PCM (16/24/32-bit) is built in; plug in FLAC or Opus through `codecFactory`. |
| `SendspinClock`, `SendspinBuffer`, `SendspinChannel`, `ArtworkReceiver` | The building blocks, exported for anyone assembling their own pipeline. |

Roles implemented: `player@v1`, `controller@v1`, `metadata@v1`, `artwork@v1`. Not implemented: `source@v1`, `visualizer@v1`, `color@v1`.

## Quick start

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:sendspin_dart/sendspin_dart.dart';

Future<void> main() async {
  // 1. Identity and pairing data persist across restarts. You implement the
  //    two store interfaces over whatever your platform offers for secrets.
  final identity = await SendspinIdentity.loadOrCreate(MyIdentityStore());
  final pairing = await SendspinPairing.load(MyPairingStore());

  final player = SendspinPlayer(
    playerName: 'Living Room',
    identity: identity,
    pairing: pairing,
    // Your decision: may a server this device is not paired with play to it?
    unpairedAccess: true,
    bufferSeconds: 5,
    additionalRoles: const {SendspinRole.metadata, SendspinRole.controller},
    // Persist the output delay yourself and hand it back here.
    initialOutputDelayMs: await loadOutputDelay(),
  );

  // 2. Wire the transport. Text is used only for the opening handshake;
  //    everything after it is an encrypted binary message.
  final ws = await WebSocket.connect('ws://192.168.1.100:8927/sendspin');
  player.onSendText = ws.add;
  player.onSendBinary = ws.add;
  player.onClose = (reason) => ws.close();
  ws.listen(
    (message) => message is String
        ? player.handleTextMessage(message)
        : player.handleBinaryMessage(Uint8List.fromList(message as List<int>)),
    onDone: player.resetForNewConnection,
  );

  // 3. React to the session.
  player.onStreamStart = (sampleRate, channels, bitDepth) {
    // (Re)configure your audio output. Can be called again from inside
    // pullSamples when the server changes format on a running stream.
  };
  player.onStreamStop = () {/* stop your audio output */};
  player.onVolumeChanged = (volume, muted) {/* apply to your output */};
  player.onOutputDelayChanged = saveOutputDelay;
  player.onMetadataUpdate = (metadata) => print(metadata.title);

  // 4. Open the connection.
  player.start();
}
```

In your audio callback, ask for the samples that are due:

```dart
// outputTimeUs: when the first of these samples leaves the audio port, on
// the player's clock. That is now, plus whatever is queued in your backend
// and device (for ALSA: snd_pcm_delay converted to microseconds).
final samples = player.pullSamples(
  frames * channels,
  outputTimeUs: player.nowUs() + backendDelayUs,
);
```

`example/sendspin_cli.dart` is a complete command-line player built this way, including file-backed stores.

## Playback timing

The player schedules every frame against the local clock: it translates the audio's server timestamp through the time filter, subtracts the output delay, and returns exactly the audio due at the `outputTimeUs` you pass. That is how it meets rc1's ±1 ms accuracy floor, and it is why `pullSamples` needs to know your output latency.

- `outputTimeUs` does not have to be smooth. It is followed by a loop that rejects callback scheduling noise and tracks your device's real sample rate. It does have to be unbiased. If your output path's latency genuinely changes (a different sink, a reconfigured device), call `resetOutputClock()` so the next value is taken as it is.
- On startup, after a seek, and after an underrun, playback snaps to position once: silence until the audio is due, or a dropped prefix if it is late.
- In steady state, drift is corrected by dropping or repeating single frames, at most 0.5% of the audio in any 150 ms.
- **Output delay** (`output_delay_ms`) is for delay *after* the audio port, such as an external amplifier. Delay before the port is what `outputTimeUs` covers. Do not put one in the other.
- `requiredLeadTimeMs` and `minBufferMs` tell the server how far ahead to send. They depend on your audio backend; set them in the constructor and adjust with `setTimingParameters`. The library raises the reported `min_buffer_ms` by itself when it measures network jitter above your value.
- Changing sample rate or channel count mid-stream costs a short gap. If your output cannot switch seamlessly, list a single rate in `supportedFormats` and the server resamples.

## Identity, pairing and unpaired access

- **Identity.** The `client_id` is the device's Curve25519 public key. `SendspinIdentity.loadOrCreate(store)` generates one on first run and reuses it afterwards. Losing the private key means servers see a new device.
- **Unpaired access.** `unpairedAccess: true` lets a server the device has never paired with play to it, once that server's operator approves the device. It is convenient and unauthenticated. With `false`, the device must be paired first. It can be changed at runtime.
- **Pairing.** The device has a pairing PSK. `player.pairingToken` returns it together with the public key as an `SP:0...` string; show that to the user as text or a QR code, and they enter it into the server. The server then pairs, both sides store a record, and later sessions with that server are authenticated. `onPaired` tells you when it happened.
- The code-based pairing methods (a 6-digit code on the device's display) are not implemented yet.

Store the identity key and the pairing data as secrets.

## Connections

The library is transport-agnostic and works for both ways rc1 connections are made:

- **Client-initiated:** discover `_sendspin-server._tcp.local.`, connect a WebSocket to the advertised address and `path`, call `start()`.
- **Server-initiated (recommended by the spec):** advertise `_sendspin._tcp.local.` with a `path` TXT record, accept the server's WebSocket, call `start()`.

Either way, call `resetForNewConnection()` before reusing a player for another socket.

With server-initiated connections several servers may connect. rc1 defines which one a client keeps ([multiple servers](https://github.com/Sendspin/spec/blob/1.0.0-rc1/connection.md#multiple-servers-server-initiated)). That decision spans connections, so it is the consumer's: run one `SendspinPlayer` per connection, compare `state.activities` after `onActivate`, and dismiss the loser with `sendGoodbye(SendspinGoodbyeReason.anotherServer)` followed by closing its socket yourself (`sendGoodbye` only sends the message), or with `rejectConcurrentPairing()`, which asks for the close through `onClose`. `state.serverId` identifies the server, for persisting the last one that played.

## Custom codecs

```dart
final player = SendspinPlayer(
  // ...
  supportedFormats: const [
    AudioFormat(codec: 'flac', channels: 2, sampleRate: 48000, bitDepth: 16),
    AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
  ],
  codecFactory: (codec, bitDepth, channels, sampleRate) =>
      codec == 'flac' ? MyFlacCodec(/* ... */) : null, // null: use built-in
);
```

A codec the factory cannot build is reported through `onStreamError`.

## Other roles

- **Metadata.** `onMetadataUpdate` fires when a state takes effect; a future-timestamped update is held as `pendingMetadata` until its time. `currentTrackPositionMs` extrapolates the position.
- **Controller.** `sendControllerCommand('next')`, `sendControllerVolume`, `sendControllerMute`, `sendControllerSeek`, `sendControllerSeekRelative`. A command must be in the server's current `supported_commands` (`canSendControllerCommand`), otherwise the call throws.
- **Artwork.** Declare channels with `artworkChannels`; `onArtworkFrame` delivers each complete image when it is due, and an empty one when the channel is cleared.
- **Availability.** If the device is taken over by something that will not yield to Sendspin, call `setAvailable(false)`; for an interruptible activity stay available and use `sendLeave()`.

## Upgrading from 0.0.x

See `CHANGELOG.md` for the full list. The changes every consumer has to make:

1. `clientId: '...'` becomes `identity:`; add `unpairedAccess:` and, to keep pairings, `pairing:`.
2. Replace `socket.add(player.buildClientHello())` with `player.start()`, and wire `onSendBinary` and `onClose`.
3. `pullSamples(count)` becomes `pullSamples(count, outputTimeUs: ...)`.
4. Static delay is now output delay: `initialOutputDelayMs`, `onOutputDelayChanged`, `outputDelayMs`.
5. `setPipelineError` is gone; `state.connectionReason` is replaced by `state.activities`.
6. Existing devices get a new `client_id`, so servers treat them as new players.

## License

MIT
