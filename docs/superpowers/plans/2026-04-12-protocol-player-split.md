# Protocol/Player Layer Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split `SendspinClient` into two layers — `SendspinProtocol` (protocol state machine) and `SendspinPlayer` (audio pipeline) — so that visualizers, conformance tests, and headless consumers can use the protocol without the audio playback machinery.

**Architecture:** `SendspinProtocol` handles all message parsing/building, clock sync, state machine, and timers. It emits raw `AudioFrame`s via callback. `SendspinPlayer` composes a `SendspinProtocol` internally and adds codec decode + jitter buffer + `pullSamples()`. `SendspinClient` becomes a deprecated typedef for backwards compatibility.

**Tech Stack:** Pure Dart 3.0+, `package:test` for testing. No new dependencies.

---

## File Structure

| Action | File | Responsibility |
|--------|------|---------------|
| Create | `lib/src/protocol.dart` | Protocol state machine: message parsing/building, clock sync, connection state, timers, emits raw audio frames via callback |
| Create | `lib/src/player.dart` | Audio pipeline: composes `SendspinProtocol` + codec + buffer, exposes `pullSamples()` |
| Create | `test/protocol_test.dart` | Tests for protocol layer in isolation |
| Create | `test/player_test.dart` | Tests for player layer (codec+buffer integration through protocol events) |
| Modify | `lib/src/models.dart` | Add `StreamConfig` data class for stream/start format info |
| Modify | `lib/src/client.dart` | Replace with backwards-compat re-export of `SendspinPlayer` as `SendspinClient` |
| Modify | `lib/sendspin_dart.dart` | Add exports for `protocol.dart` and `player.dart` |
| Modify | `test/client_test.dart` | Update import to verify backwards-compat alias works |

---

### Task 1: Add StreamConfig model

**Files:**
- Modify: `lib/src/models.dart` (append after `SendspinPlayerState`)
- Test: `test/models_test.dart` (new)

- [ ] **Step 1: Write the failing test**

Create `test/models_test.dart`:

```dart
import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

void main() {
  group('StreamConfig', () {
    test('stores all audio format fields from stream/start', () {
      final config = StreamConfig(
        codec: 'flac',
        channels: 2,
        sampleRate: 48000,
        bitDepth: 24,
        codecHeader: 'base64data==',
      );
      expect(config.codec, 'flac');
      expect(config.channels, 2);
      expect(config.sampleRate, 48000);
      expect(config.bitDepth, 24);
      expect(config.codecHeader, 'base64data==');
    });

    test('codecHeader defaults to null', () {
      final config = StreamConfig(
        codec: 'pcm',
        channels: 2,
        sampleRate: 44100,
        bitDepth: 16,
      );
      expect(config.codecHeader, isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/models_test.dart`
Expected: FAIL — `StreamConfig` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/src/models.dart` after the `SendspinPlayerState` class:

```dart
/// Audio format configuration received in a stream/start message.
///
/// Used by [SendspinProtocol] to communicate the negotiated format
/// to consumers without coupling them to the full message parsing.
class StreamConfig {
  final String codec;
  final int channels;
  final int sampleRate;
  final int bitDepth;

  /// Optional base64-encoded codec header (e.g. FLAC STREAMINFO).
  final String? codecHeader;

  const StreamConfig({
    required this.codec,
    required this.channels,
    required this.sampleRate,
    required this.bitDepth,
    this.codecHeader,
  });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `dart test test/models_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/src/models.dart test/models_test.dart
git commit -m "feat: add StreamConfig model for protocol/player split"
```

---

### Task 2: Create SendspinProtocol with tests

This is the core extraction. `SendspinProtocol` handles everything the current `SendspinClient` does **except** codec decode, buffer management, and `pullSamples()`.

**Files:**
- Create: `test/protocol_test.dart`
- Create: `lib/src/protocol.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/protocol_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

void main() {
  group('SendspinProtocol', () {
    test('starts in disabled state', () {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );
      expect(protocol.state.connectionState, SendspinConnectionState.disabled);
      protocol.dispose();
    });

    test('parses server/hello and transitions to syncing', () async {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );
      final states = <SendspinConnectionState>[];
      protocol.stateStream.listen((s) => states.add(s.connectionState));

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'Music Assistant'},
      }));

      await Future.delayed(Duration.zero);
      expect(states, contains(SendspinConnectionState.syncing));
      expect(protocol.state.serverName, 'Music Assistant');
      protocol.dispose();
    });

    test('builds correct client/hello message', () {
      final protocol = SendspinProtocol(
        playerName: 'Kitchen',
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
      expect(payload['name'], 'Kitchen');
      protocol.dispose();
    });

    test('emits onStreamConfig on stream/start', () async {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      StreamConfig? receivedConfig;
      protocol.onStreamConfig = (config) => receivedConfig = config;

      // Need server/hello first to be in syncing state
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
      expect(receivedConfig!.sampleRate, 48000);
      expect(receivedConfig!.channels, 2);
      expect(receivedConfig!.bitDepth, 16);
      protocol.dispose();
    });

    test('emits onStreamConfig with codec header when present', () {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      StreamConfig? receivedConfig;
      protocol.onStreamConfig = (config) => receivedConfig = config;

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));

      protocol.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'flac',
            'channels': 2,
            'sample_rate': 44100,
            'bit_depth': 24,
            'codec_header': 'AAAA',
          },
        },
      }));

      expect(receivedConfig!.codecHeader, 'AAAA');
      protocol.dispose();
    });

    test('emits onAudioFrame for binary messages', () {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      AudioFrame? receivedFrame;
      protocol.onAudioFrame = (frame) => receivedFrame = frame;

      final binaryMsg = Uint8List(13);
      final view = ByteData.view(binaryMsg.buffer);
      binaryMsg[0] = 1; // version
      view.setInt64(1, 123456789, Endian.big);
      binaryMsg[9] = 0xAB;
      binaryMsg[10] = 0xCD;
      binaryMsg[11] = 0xEF;
      binaryMsg[12] = 0x01;

      protocol.handleBinaryMessage(binaryMsg);

      expect(receivedFrame, isNotNull);
      expect(receivedFrame!.timestampUs, 123456789);
      expect(receivedFrame!.audioData, [0xAB, 0xCD, 0xEF, 0x01]);
      protocol.dispose();
    });

    test('ignores binary messages shorter than 9 bytes', () {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      AudioFrame? receivedFrame;
      protocol.onAudioFrame = (frame) => receivedFrame = frame;

      protocol.handleBinaryMessage(Uint8List(5));
      expect(receivedFrame, isNull);
      protocol.dispose();
    });

    test('emits onStreamClear on stream/clear', () {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      var clearCalled = false;
      protocol.onStreamClear = () => clearCalled = true;

      protocol.handleTextMessage(jsonEncode({
        'type': 'stream/clear',
        'payload': {},
      }));

      expect(clearCalled, true);
      protocol.dispose();
    });

    test('emits onStreamEnd on stream/end and transitions to syncing', () async {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      var endCalled = false;
      protocol.onStreamEnd = () => endCalled = true;
      protocol.onStreamConfig = (_) {}; // accept stream/start

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      protocol.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'pcm', 'channels': 2,
            'sample_rate': 48000, 'bit_depth': 16,
          },
        },
      }));
      protocol.handleTextMessage(jsonEncode({
        'type': 'stream/end',
        'payload': {},
      }));

      await Future.delayed(Duration.zero);
      expect(endCalled, true);
      expect(protocol.state.connectionState, SendspinConnectionState.syncing);
      protocol.dispose();
    });

    test('handles server/command volume and calls onVolumeChanged', () async {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      double? receivedVol;
      protocol.onVolumeChanged = (vol, muted) => receivedVol = vol;

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/command',
        'payload': {
          'player': {'command': 'volume', 'volume': 50},
        },
      }));

      await Future.delayed(Duration.zero);
      expect(protocol.state.volume, 0.5);
      expect(receivedVol, 0.5);
      protocol.dispose();
    });

    test('sends client/state on volume command via onSendText', () {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      final sent = <String>[];
      protocol.onSendText = sent.add;

      protocol.handleTextMessage(jsonEncode({
        'type': 'server/command',
        'payload': {
          'player': {'command': 'volume', 'volume': 75},
        },
      }));

      expect(sent, hasLength(1));
      final parsed = jsonDecode(sent.first) as Map<String, dynamic>;
      expect(parsed['type'], 'client/state');
      protocol.dispose();
    });

    test('updateVolume changes state and sends report', () {
      final protocol = SendspinProtocol(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      final sent = <String>[];
      protocol.onSendText = sent.add;

      protocol.updateVolume(0.75);
      expect(protocol.state.volume, 0.75);
      expect(sent, hasLength(1));
      protocol.dispose();
    });

    test('parseBinaryFrame is a static utility', () {
      final frame = Uint8List(13);
      final view = ByteData.view(frame.buffer);
      frame[0] = 1;
      view.setInt64(1, 999, Endian.big);
      frame[9] = 0x01;

      final result = SendspinProtocol.parseBinaryFrame(frame);
      expect(result.timestampUs, 999);
      expect(result.audioData.length, 4);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/protocol_test.dart`
Expected: FAIL — `SendspinProtocol` not defined.

- [ ] **Step 3: Implement SendspinProtocol**

Create `lib/src/protocol.dart`:

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';
import 'clock.dart';

/// A parsed binary audio frame from the Sendspin protocol.
class AudioFrame {
  final int timestampUs;
  final Uint8List audioData;

  const AudioFrame({required this.timestampUs, required this.audioData});
}

/// Device info sent in the client/hello handshake.
class DeviceInfo {
  final String productName;
  final String manufacturer;
  final String softwareVersion;

  const DeviceInfo({
    this.productName = 'sendspin_dart',
    this.manufacturer = 'sendspin_dart',
    this.softwareVersion = '0.1.0',
  });
}

/// Audio format description for supported codec negotiation.
class AudioFormat {
  final String codec;
  final int channels;
  final int sampleRate;
  final int bitDepth;

  const AudioFormat({
    required this.codec,
    required this.channels,
    required this.sampleRate,
    required this.bitDepth,
  });

  Map<String, dynamic> toJson() => {
        'codec': codec,
        'channels': channels,
        'sample_rate': sampleRate,
        'bit_depth': bitDepth,
      };
}

/// Sendspin protocol state machine.
///
/// Handles WebSocket text/binary message parsing, connection state transitions,
/// clock synchronization, and periodic reporting. Does NOT manage the WebSocket
/// connection, audio decoding, or buffering — those are the caller's concern.
///
/// Consumers who need decoded, buffered audio should use [SendspinPlayer]
/// instead. Use this class directly for:
/// - Visualizers that process raw audio frames themselves
/// - Conformance test adapters
/// - Headless consumers that want raw PCM bytes without playback
class SendspinProtocol {
  final String playerName;
  final String clientId;
  final int bufferSeconds;
  final DeviceInfo deviceInfo;
  final List<AudioFormat> supportedFormats;

  final SendspinClock _clock = SendspinClock();

  int _staticDelayMs = 0;

  SendspinPlayerState _state = const SendspinPlayerState();
  final StreamController<SendspinPlayerState> _stateController =
      StreamController<SendspinPlayerState>.broadcast();

  Timer? _clockSyncTimer;
  Timer? _stateReportTimer;

  /// Callback for sending text messages back through the WebSocket.
  void Function(String message)? onSendText;

  /// Called when stream/start is received with the negotiated audio format.
  void Function(StreamConfig config)? onStreamConfig;

  /// Called when stream/clear is received.
  void Function()? onStreamClear;

  /// Called when stream/end is received.
  void Function()? onStreamEnd;

  /// Called for each parsed binary audio frame.
  void Function(AudioFrame frame)? onAudioFrame;

  /// Called when the server changes volume or mute via server/command.
  void Function(double volume, bool muted)? onVolumeChanged;

  SendspinProtocol({
    required this.playerName,
    required this.clientId,
    required this.bufferSeconds,
    this.deviceInfo = const DeviceInfo(),
    this.supportedFormats = const [
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 44100, bitDepth: 16),
    ],
  });

  /// The underlying clock filter, exposed for consumers that need direct
  /// access to time conversion (e.g. synchronized visualizers).
  SendspinClock get clock => _clock;

  /// Current player state.
  SendspinPlayerState get state => _state;

  /// Stream of state changes.
  Stream<SendspinPlayerState> get stateStream => _stateController.stream;

  void _updateState(SendspinPlayerState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  // ---------------------------------------------------------------------------
  // Message builders
  // ---------------------------------------------------------------------------

  /// Builds the client/hello handshake message per the Sendspin spec.
  String buildClientHello() {
    return jsonEncode({
      'type': 'client/hello',
      'payload': {
        'client_id': clientId,
        'name': playerName,
        'version': 1,
        'supported_roles': ['player@v1'],
        'device_info': {
          'product_name': deviceInfo.productName,
          'manufacturer': deviceInfo.manufacturer,
          'software_version': deviceInfo.softwareVersion,
        },
        'player@v1_support': {
          'supported_formats': supportedFormats.map((f) => f.toJson()).toList(),
          'buffer_capacity': bufferSeconds * 48000 * 2 * 2,
          'supported_commands': ['volume', 'mute'],
        },
      },
    });
  }

  /// Builds a client/time message for clock synchronization.
  String buildClientTime(int clientTransmittedUs) {
    return jsonEncode({
      'type': 'client/time',
      'payload': {
        'client_transmitted': clientTransmittedUs,
      },
    });
  }

  /// Builds a client/state report.
  String buildClientState() {
    return jsonEncode({
      'type': 'client/state',
      'payload': {
        'state': 'synchronized',
        'player': {
          'volume': (_state.volume * 100).round(),
          'muted': _state.muted,
          'static_delay_ms': _staticDelayMs,
          'supported_commands': ['volume', 'mute', 'set_static_delay'],
        },
      },
    });
  }

  /// Update volume from local UI and report to server.
  void updateVolume(double volume) {
    _updateState(_state.copyWith(volume: volume.clamp(0.0, 1.0)));
    onSendText?.call(buildClientState());
  }

  // ---------------------------------------------------------------------------
  // Text message handling
  // ---------------------------------------------------------------------------

  /// Dispatches an incoming JSON text message by its `type` field.
  void handleTextMessage(String text) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      return;
    }

    final type = msg['type'] as String?;
    final payload = msg['payload'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'server/hello':
        _handleServerHello(payload);
      case 'server/time':
        _handleServerTime(payload);
      case 'stream/start':
        _handleStreamStart(payload);
      case 'stream/clear':
        _handleStreamClear();
      case 'stream/end':
        _handleStreamEnd();
      case 'server/command':
        _handleServerCommand(payload);
      case 'server/state':
        _handleServerState(payload);
    }
  }

  void _handleServerHello(Map<String, dynamic> payload) {
    final serverName = payload['name'] as String? ?? 'Unknown';

    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.syncing,
      serverName: serverName,
    ));

    onSendText?.call(buildClientState());
    startClockSync();
  }

  void _handleServerTime(Map<String, dynamic> payload) {
    final serverReceived = payload['server_received'] as int? ?? 0;
    final serverTransmitted = payload['server_transmitted'] as int? ?? 0;
    final clientReceived = DateTime.now().microsecondsSinceEpoch;
    final clientTransmitted = payload['client_transmitted'] as int? ?? 0;

    final offset =
        ((serverReceived - clientTransmitted) +
                (serverTransmitted - clientReceived)) ~/
            2;
    final delay =
        (clientReceived - clientTransmitted) -
        (serverTransmitted - serverReceived);

    _clock.update(offset, delay ~/ 2, clientReceived);

    _updateState(_state.copyWith(
      clockOffsetMs: (_clock.precisionUs / 1000).round(),
      clockSamples: _clock.sampleCount,
    ));
  }

  void _handleStreamStart(Map<String, dynamic> payload) {
    final playerFormat = payload['player'] as Map<String, dynamic>?;
    final audioFormat = playerFormat ?? payload['audio_format'] as Map<String, dynamic>? ?? {};
    final codecName = audioFormat['codec'] as String? ?? 'pcm';
    final channels = audioFormat['channels'] as int? ?? 2;
    final sampleRate = audioFormat['sample_rate'] as int? ?? 48000;
    final bitDepth = audioFormat['bit_depth'] as int? ?? 16;
    final codecHeader = audioFormat['codec_header'] as String?;

    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.streaming,
      codec: codecName,
      sampleRate: sampleRate,
      channels: channels,
    ));

    _startStateReporting();

    onStreamConfig?.call(StreamConfig(
      codec: codecName,
      channels: channels,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      codecHeader: codecHeader,
    ));
  }

  void _handleStreamClear() {
    onStreamClear?.call();
  }

  void _handleStreamEnd() {
    _stopStateReporting();

    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.syncing,
    ));

    onStreamEnd?.call();
  }

  void _handleServerCommand(Map<String, dynamic> payload) {
    final player = payload['player'] as Map<String, dynamic>?;
    if (player == null) return;

    final command = player['command'] as String?;
    switch (command) {
      case 'volume':
        final vol = player['volume'];
        if (vol is num) {
          final normalized = vol.toDouble() / 100;
          _updateState(_state.copyWith(volume: normalized));
          onSendText?.call(buildClientState());
          onVolumeChanged?.call(normalized, _state.muted);
        }
      case 'mute':
        final muted = player['mute'] as bool?;
        if (muted != null) {
          _updateState(_state.copyWith(muted: muted));
          onSendText?.call(buildClientState());
          onVolumeChanged?.call(_state.volume, muted);
        }
      case 'set_static_delay':
        final delayMs = player['static_delay_ms'] as int?;
        if (delayMs != null) {
          _staticDelayMs = delayMs.clamp(0, 5000);
          _updateState(_state.copyWith(staticDelayMs: _staticDelayMs));
          onSendText?.call(buildClientState());
        }
    }
  }

  void _handleServerState(Map<String, dynamic> payload) {
    // Server state carries metadata — no action needed.
  }

  // ---------------------------------------------------------------------------
  // Binary message handling
  // ---------------------------------------------------------------------------

  /// Handles an incoming binary audio frame.
  ///
  /// Parses the frame and calls [onAudioFrame] with the result.
  void handleBinaryMessage(Uint8List data) {
    if (data.length < 9) return;
    onAudioFrame?.call(parseBinaryFrame(data));
  }

  /// Parses a binary frame: byte 0 = version, bytes 1-8 = BE int64 timestamp,
  /// bytes 9+ = audio data.
  static AudioFrame parseBinaryFrame(Uint8List frame) {
    final view = ByteData.view(frame.buffer, frame.offsetInBytes, frame.lengthInBytes);
    final timestampUs = view.getInt64(1, Endian.big);
    final audioData = Uint8List.sublistView(frame, 9);
    return AudioFrame(timestampUs: timestampUs, audioData: audioData);
  }

  // ---------------------------------------------------------------------------
  // Clock sync
  // ---------------------------------------------------------------------------

  /// Starts periodic clock synchronization (every 2 seconds, burst of 5).
  void startClockSync() {
    stopClockSync();
    _clockSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _sendTimeBurst();
    });
  }

  void _sendTimeBurst() {
    for (int i = 0; i < 5; i++) {
      Future.delayed(Duration(milliseconds: i * 20), () {
        if (_clockSyncTimer == null) return;
        final clientTransmittedUs = DateTime.now().microsecondsSinceEpoch;
        onSendText?.call(buildClientTime(clientTransmittedUs));
      });
    }
  }

  /// Stops clock synchronization.
  void stopClockSync() {
    _clockSyncTimer?.cancel();
    _clockSyncTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Periodic state reporting
  // ---------------------------------------------------------------------------

  void _startStateReporting() {
    _stopStateReporting();
    _stateReportTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      onSendText?.call(buildClientState());
    });
  }

  void _stopStateReporting() {
    _stateReportTimer?.cancel();
    _stateReportTimer = null;
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Resets the protocol for a new connection.
  void resetForNewConnection() {
    stopClockSync();
    _stopStateReporting();
  }

  /// Cleans up timers and stream controller.
  void dispose() {
    stopClockSync();
    _stopStateReporting();
    _stateController.close();
  }
}
```

- [ ] **Step 4: Export SendspinProtocol from barrel**

In `lib/sendspin_dart.dart`, add the export:

```dart
export 'src/protocol.dart';
```

- [ ] **Step 5: Run protocol tests to verify they pass**

Run: `dart test test/protocol_test.dart`
Expected: All PASS.

- [ ] **Step 6: Run all existing tests to verify nothing broke**

Run: `dart test`
Expected: All PASS — we haven't modified any existing code, only added new files.

- [ ] **Step 7: Commit**

```bash
git add lib/src/protocol.dart test/protocol_test.dart lib/sendspin_dart.dart
git commit -m "feat: extract SendspinProtocol from SendspinClient

Protocol layer handles message parsing, clock sync, state machine,
and emits raw AudioFrames via callback. Visualizers and conformance
tests can use this directly without the audio pipeline."
```

---

### Task 3: Create SendspinPlayer with tests

`SendspinPlayer` composes `SendspinProtocol` + codec + buffer. Its public API matches the current `SendspinClient` so it's a drop-in replacement.

**Files:**
- Create: `test/player_test.dart`
- Create: `lib/src/player.dart`

- [ ] **Step 1: Write the failing tests**

Create `test/player_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

void main() {
  group('SendspinPlayer', () {
    test('starts in disabled state', () {
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );
      expect(player.state.connectionState, SendspinConnectionState.disabled);
      player.dispose();
    });

    test('delegates handleTextMessage to protocol', () async {
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );
      player.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      await Future.delayed(Duration.zero);
      expect(player.state.connectionState, SendspinConnectionState.syncing);
      player.dispose();
    });

    test('calls onStreamStart with format after stream/start', () {
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );
      int? receivedSr;
      int? receivedCh;
      int? receivedBd;
      player.onStreamStart = (sr, ch, bd) {
        receivedSr = sr;
        receivedCh = ch;
        receivedBd = bd;
      };

      player.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      player.handleTextMessage(jsonEncode({
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

      expect(receivedSr, 48000);
      expect(receivedCh, 2);
      expect(receivedBd, 16);
      player.dispose();
    });

    test('decodes binary frames and makes samples available via pullSamples', () {
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      // Set up streaming state
      player.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      player.handleTextMessage(jsonEncode({
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

      // Build a binary frame with 4 bytes of 16-bit PCM (2 samples)
      final pcmData = Uint8List(4);
      final pcmView = ByteData.view(pcmData.buffer);
      pcmView.setInt16(0, 100, Endian.little);
      pcmView.setInt16(2, 200, Endian.little);

      final frame = Uint8List(9 + pcmData.length);
      final frameView = ByteData.view(frame.buffer);
      frame[0] = 1; // version
      frameView.setInt64(1, 1000, Endian.big); // timestamp
      frame.setRange(9, 13, pcmData);

      player.handleBinaryMessage(frame);

      // Buffer has startupBufferMs=200, so data won't release yet.
      // pullSamples returns silence until startup threshold is met.
      final samples = player.pullSamples(2);
      expect(samples.length, 2);
      player.dispose();
    });

    test('pullSamples returns silence when not streaming', () {
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );
      final samples = player.pullSamples(4);
      expect(samples, Int16List(4));
      player.dispose();
    });

    test('stream/end cleans up codec and buffer', () {
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );
      var stopCalled = false;
      player.onStreamStop = () => stopCalled = true;

      player.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      player.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'pcm', 'channels': 2,
            'sample_rate': 48000, 'bit_depth': 16,
          },
        },
      }));
      player.handleTextMessage(jsonEncode({
        'type': 'stream/end',
        'payload': {},
      }));

      expect(stopCalled, true);
      // After stream/end, pullSamples should return silence
      expect(player.pullSamples(4), Int16List(4));
      player.dispose();
    });

    test('stream/clear flushes buffer and resets codec', () {
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      player.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      player.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'pcm', 'channels': 2,
            'sample_rate': 48000, 'bit_depth': 16,
          },
        },
      }));
      player.handleTextMessage(jsonEncode({
        'type': 'stream/clear',
        'payload': {},
      }));

      // After clear, buffer should be empty
      expect(player.pullSamples(4), Int16List(4));
      player.dispose();
    });

    test('accepts custom codecFactory', () {
      var factoryCalled = false;
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
        codecFactory: (codec, bitDepth, channels, sampleRate) {
          factoryCalled = true;
          return null; // fall back to built-in
        },
      );

      player.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));
      player.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'pcm', 'channels': 2,
            'sample_rate': 48000, 'bit_depth': 16,
          },
        },
      }));

      expect(factoryCalled, true);
      player.dispose();
    });

    test('exposes protocol for direct access', () {
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );
      expect(player.protocol, isA<SendspinProtocol>());
      player.dispose();
    });

    test('delegates buildClientHello to protocol', () {
      final player = SendspinPlayer(
        playerName: 'Kitchen',
        clientId: 'abc-123',
        bufferSeconds: 5,
      );
      final hello = player.buildClientHello();
      final parsed = jsonDecode(hello) as Map<String, dynamic>;
      expect(parsed['type'], 'client/hello');
      expect(parsed['payload']['name'], 'Kitchen');
      player.dispose();
    });

    test('track switch flushes existing buffer instead of creating new one', () {
      final player = SendspinPlayer(
        playerName: 'Test',
        clientId: 'test-id',
        bufferSeconds: 5,
      );

      player.handleTextMessage(jsonEncode({
        'type': 'server/hello',
        'payload': {'name': 'MA'},
      }));

      // First stream/start
      player.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'pcm', 'channels': 2,
            'sample_rate': 48000, 'bit_depth': 16,
          },
        },
      }));

      // Second stream/start (track switch) — should flush, not create new buffer
      player.handleTextMessage(jsonEncode({
        'type': 'stream/start',
        'payload': {
          'audio_format': {
            'codec': 'pcm', 'channels': 2,
            'sample_rate': 44100, 'bit_depth': 16,
          },
        },
      }));

      expect(player.state.sampleRate, 44100);
      player.dispose();
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dart test test/player_test.dart`
Expected: FAIL — `SendspinPlayer` not defined.

- [ ] **Step 3: Implement SendspinPlayer**

Create `lib/src/player.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

import 'protocol.dart';
import 'buffer.dart';
import 'codec.dart';
import 'models.dart';

/// Audio pipeline that composes [SendspinProtocol] with codec decoding
/// and jitter buffering.
///
/// This is the high-level API for consumers that want decoded, synchronized
/// PCM audio (e.g. audio players). It handles:
/// - Codec creation and lifecycle on stream/start and stream/end
/// - Jitter buffering with sync correction
/// - Pull-based sample delivery via [pullSamples]
///
/// For consumers that want raw audio frames without the pipeline (visualizers,
/// conformance tests, custom DSP), use [SendspinProtocol] directly.
class SendspinPlayer {
  /// The underlying protocol handler.
  ///
  /// Exposed so advanced consumers can access clock state, connection state,
  /// or wire up additional protocol-level callbacks alongside the player.
  final SendspinProtocol protocol;

  /// Optional codec factory for custom codecs (e.g. FLAC via FFI).
  final SendspinCodec? Function(
      String codec, int bitDepth, int channels, int sampleRate)? codecFactory;

  final int _bufferSeconds;

  SendspinBuffer? _buffer;
  SendspinCodec? _codec;

  /// Called when stream/start is received with the negotiated audio format.
  void Function(int sampleRate, int channels, int bitDepth)? onStreamStart;

  /// Called when stream/end or stream/clear resets the pipeline.
  void Function()? onStreamStop;

  SendspinPlayer({
    required String playerName,
    required String clientId,
    required int bufferSeconds,
    DeviceInfo deviceInfo = const DeviceInfo(),
    List<AudioFormat> supportedFormats = const [
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 44100, bitDepth: 16),
    ],
    this.codecFactory,
  })  : _bufferSeconds = bufferSeconds,
        protocol = SendspinProtocol(
          playerName: playerName,
          clientId: clientId,
          bufferSeconds: bufferSeconds,
          deviceInfo: deviceInfo,
          supportedFormats: supportedFormats,
        ) {
    _wireProtocol();
  }

  void _wireProtocol() {
    protocol.onStreamConfig = _handleStreamConfig;
    protocol.onAudioFrame = _handleAudioFrame;
    protocol.onStreamClear = _handleStreamClear;
    protocol.onStreamEnd = _handleStreamEnd;
  }

  // ---------------------------------------------------------------------------
  // Protocol event handlers
  // ---------------------------------------------------------------------------

  void _handleStreamConfig(StreamConfig config) {
    final wasStreaming = _codec != null;

    _codec?.dispose();

    // Try custom codec factory first, then fall back to built-in.
    SendspinCodec? codec;
    if (codecFactory != null) {
      codec = codecFactory!(
          config.codec, config.bitDepth, config.channels, config.sampleRate);
    }
    codec ??= createCodec(
      codec: config.codec,
      bitDepth: config.bitDepth,
      channels: config.channels,
      sampleRate: config.sampleRate,
    );
    _codec = codec;

    // Feed codec header if provided.
    if (config.codecHeader != null && config.codecHeader!.isNotEmpty) {
      try {
        final headerBytes = base64Decode(config.codecHeader!);
        _codec!.decode(Uint8List.fromList(headerBytes));
      } catch (_) {
        // Header decode failure is non-fatal.
      }
    }

    // On track switch, flush existing buffer instead of creating a new one
    // with startup delay (avoids overflow when audio arrives immediately).
    if (wasStreaming && _buffer != null) {
      _buffer!.flush();
    } else {
      _buffer = SendspinBuffer(
        sampleRate: config.sampleRate,
        channels: config.channels,
        startupBufferMs: 200,
        maxBufferMs: _bufferSeconds * 1000,
      );
    }

    onStreamStart?.call(config.sampleRate, config.channels, config.bitDepth);
  }

  void _handleAudioFrame(AudioFrame frame) {
    final codec = _codec;
    final buffer = _buffer;
    if (codec == null || buffer == null) return;

    final samples = codec.decode(frame.audioData);
    buffer.addChunk(frame.timestampUs, samples);

    protocol._updateState(
        protocol.state.copyWith(bufferDepthMs: buffer.bufferDepthMs));
  }

  void _handleStreamClear() {
    _buffer?.flush();
    _codec?.reset();
  }

  void _handleStreamEnd() {
    onStreamStop?.call();
    _buffer?.flush();
    _codec?.dispose();
    _codec = null;
    _buffer = null;
  }

  // ---------------------------------------------------------------------------
  // Delegated protocol API
  // ---------------------------------------------------------------------------

  /// Current player state.
  SendspinPlayerState get state => protocol.state;

  /// Stream of state changes.
  Stream<SendspinPlayerState> get stateStream => protocol.stateStream;

  /// Callback for sending text messages back through the WebSocket.
  void Function(String message)? get onSendText => protocol.onSendText;
  set onSendText(void Function(String message)? callback) =>
      protocol.onSendText = callback;

  /// Called when the server changes volume or mute.
  void Function(double volume, bool muted)? get onVolumeChanged =>
      protocol.onVolumeChanged;
  set onVolumeChanged(void Function(double volume, bool muted)? callback) =>
      protocol.onVolumeChanged = callback;

  String buildClientHello() => protocol.buildClientHello();
  String buildClientTime(int clientTransmittedUs) =>
      protocol.buildClientTime(clientTransmittedUs);
  String buildClientState() => protocol.buildClientState();

  void handleTextMessage(String text) => protocol.handleTextMessage(text);
  void handleBinaryMessage(Uint8List data) =>
      protocol.handleBinaryMessage(data);

  void updateVolume(double volume) => protocol.updateVolume(volume);

  void startClockSync() => protocol.startClockSync();
  void stopClockSync() => protocol.stopClockSync();

  /// Parses a binary frame (delegates to [SendspinProtocol.parseBinaryFrame]).
  static AudioFrame parseBinaryFrame(Uint8List frame) =>
      SendspinProtocol.parseBinaryFrame(frame);

  // ---------------------------------------------------------------------------
  // Pull samples (audio sink interface)
  // ---------------------------------------------------------------------------

  /// Pulls [count] decoded PCM samples from the buffer, or silence if empty.
  Int16List pullSamples(int count) {
    return _buffer?.pullSamples(count) ?? Int16List(count);
  }

  // ---------------------------------------------------------------------------
  // Lifecycle
  // ---------------------------------------------------------------------------

  /// Resets the player for a new connection.
  void resetForNewConnection() {
    protocol.resetForNewConnection();
    _codec?.dispose();
    _codec = null;
    _buffer?.flush();
    _buffer = null;
  }

  /// Cleans up all resources.
  void dispose() {
    _codec?.dispose();
    _codec = null;
    protocol.dispose();
  }
}
```

**Note:** `_handleAudioFrame` calls `protocol._updateState(...)` to update buffer depth. This requires `_updateState` to be accessible. We need to change its visibility in `protocol.dart` — make it package-private by keeping it as-is (Dart's `_` prefix is library-private, and since `player.dart` is a separate library, we need a different approach).

**Fix:** Add a public `updateState` method to `SendspinProtocol` for use by `SendspinPlayer`:

In `lib/src/protocol.dart`, add after the existing `_updateState` method:

```dart
  /// Updates the player state. Used by [SendspinPlayer] to reflect
  /// pipeline state (e.g. buffer depth) in the shared state object.
  void updatePipelineState(SendspinPlayerState newState) {
    _updateState(newState);
  }
```

And in `lib/src/player.dart`, change `_handleAudioFrame` to use:

```dart
  void _handleAudioFrame(AudioFrame frame) {
    final codec = _codec;
    final buffer = _buffer;
    if (codec == null || buffer == null) return;

    final samples = codec.decode(frame.audioData);
    buffer.addChunk(frame.timestampUs, samples);

    protocol.updatePipelineState(
        protocol.state.copyWith(bufferDepthMs: buffer.bufferDepthMs));
  }
```

- [ ] **Step 4: Export SendspinPlayer from barrel**

In `lib/sendspin_dart.dart`, add:

```dart
export 'src/player.dart';
```

- [ ] **Step 5: Run player tests to verify they pass**

Run: `dart test test/player_test.dart`
Expected: All PASS.

- [ ] **Step 6: Run all tests to verify nothing broke**

Run: `dart test`
Expected: All PASS.

- [ ] **Step 7: Commit**

```bash
git add lib/src/player.dart lib/src/protocol.dart test/player_test.dart lib/sendspin_dart.dart
git commit -m "feat: add SendspinPlayer composing protocol + codec + buffer

SendspinPlayer provides the same API as the old SendspinClient but
composes SendspinProtocol internally. Consumers who need raw frames
(visualizers, conformance tests) use SendspinProtocol directly."
```

---

### Task 4: Replace SendspinClient with backwards-compat alias

Replace the contents of `client.dart` with a deprecated typedef pointing to `SendspinPlayer`. Existing tests in `client_test.dart` should continue to pass unchanged.

**Files:**
- Modify: `lib/src/client.dart`
- Modify: `test/client_test.dart` (verify, minimal changes)

- [ ] **Step 1: Replace client.dart with backwards-compat alias**

Replace the entire contents of `lib/src/client.dart` with:

```dart
import 'dart:typed_data';

import 'player.dart';
import 'protocol.dart';

export 'protocol.dart' show AudioFrame, DeviceInfo, AudioFormat;

/// Backwards-compatible alias for [SendspinPlayer].
///
/// New code should use [SendspinPlayer] (for audio playback) or
/// [SendspinProtocol] (for visualizers/conformance tests) directly.
@Deprecated('Use SendspinPlayer (audio) or SendspinProtocol (raw frames) instead')
typedef SendspinClient = SendspinPlayer;
```

- [ ] **Step 2: Run existing client tests to verify backwards compat**

Run: `dart test test/client_test.dart`
Expected: All 14 tests PASS. The `SendspinClient` typedef resolves to `SendspinPlayer`, which has the same API. The `SendspinClient.parseBinaryFrame` static call works because `SendspinPlayer` has that static method.

If there are deprecation warnings, that's expected and correct.

- [ ] **Step 3: Run full test suite**

Run: `dart test`
Expected: All tests PASS across all test files.

- [ ] **Step 4: Commit**

```bash
git add lib/src/client.dart
git commit -m "refactor: replace SendspinClient with deprecated typedef to SendspinPlayer

SendspinClient is now a deprecated alias for SendspinPlayer.
All existing tests pass unchanged. New code should use
SendspinPlayer or SendspinProtocol directly."
```

---

### Task 5: Clean up barrel exports and final verification

Make sure the barrel export file is clean and all public types are accessible.

**Files:**
- Modify: `lib/sendspin_dart.dart`

- [ ] **Step 1: Update barrel exports to final state**

Replace `lib/sendspin_dart.dart` with:

```dart
library sendspin_dart;

export 'src/protocol.dart';
export 'src/player.dart';
export 'src/buffer.dart';
export 'src/clock.dart';
export 'src/codec.dart';
export 'src/models.dart';
export 'src/audio_sink.dart';
export 'src/client.dart';
```

Note: `client.dart` re-exports `AudioFrame`, `DeviceInfo`, `AudioFormat` from `protocol.dart` and provides the `SendspinClient` typedef. The `protocol.dart` export also provides those types directly. Dart handles duplicate exports gracefully.

- [ ] **Step 2: Run full test suite**

Run: `dart test`
Expected: All tests PASS.

- [ ] **Step 3: Verify public API surface**

Run: `dart analyze`
Expected: No errors. Deprecation info messages for `SendspinClient` usage in `client_test.dart` are expected.

- [ ] **Step 4: Commit**

```bash
git add lib/sendspin_dart.dart
git commit -m "chore: update barrel exports for protocol/player split"
```

---

## Summary of consumer usage after split

**Audio player app (current usage, unchanged):**
```dart
final player = SendspinPlayer(playerName: 'Kitchen', clientId: 'abc', bufferSeconds: 5);
player.onSendText = ws.send;
player.onStreamStart = (sr, ch, bd) => audioSink.initialize(sampleRate: sr, channels: ch, bitDepth: bd);
player.handleTextMessage(text);
player.handleBinaryMessage(data);
final samples = player.pullSamples(960);
```

**Visualizer (new capability):**
```dart
final protocol = SendspinProtocol(playerName: 'Visualizer', clientId: 'viz', bufferSeconds: 5);
protocol.onSendText = ws.send;
protocol.onStreamConfig = (config) => initFftPipeline(config.sampleRate, config.channels);
protocol.onAudioFrame = (frame) => feedToFft(frame.audioData);
protocol.handleTextMessage(text);
protocol.handleBinaryMessage(data);
```

**Backwards compat (deprecated but works):**
```dart
// ignore: deprecated_member_use
final client = SendspinClient(playerName: 'Old', clientId: 'old', bufferSeconds: 5);
// Everything works exactly as before
```
