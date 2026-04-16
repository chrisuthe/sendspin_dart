# Multi-Role Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Controller, Metadata, and Artwork role support so a single SendSpin connection can hold any combination of roles.

**Architecture:** New `SendspinRole` enum drives `client/hello` generation, binary frame dispatch, and controller command sending. All changes are additive to existing files. Default behavior (Player-only) is preserved for backward compatibility.

**Tech Stack:** Dart 3.0+, `package:test`

**Spec:** `docs/superpowers/specs/2026-04-16-multi-role-support-design.md`

---

### Task 1: Add Models — SendspinRole, ArtworkChannel, ArtworkFrame

**Files:**
- Modify: `lib/src/models.dart`
- Modify: `test/models_test.dart`

- [ ] **Step 1: Write tests for new models**

Add to the end of `test/models_test.dart`, before the closing `}`:

```dart
  group('SendspinRole', () {
    test('wireValue maps correctly', () {
      expect(SendspinRole.player.wireValue, 'player@v1');
      expect(SendspinRole.controller.wireValue, 'controller@v1');
      expect(SendspinRole.metadata.wireValue, 'metadata@v1');
      expect(SendspinRole.artwork.wireValue, 'artwork@v1');
    });
  });

  group('ArtworkChannel', () {
    test('stores all fields', () {
      const ch = ArtworkChannel(
        source: 'album',
        format: 'jpeg',
        mediaWidth: 512,
        mediaHeight: 512,
      );
      expect(ch.source, 'album');
      expect(ch.format, 'jpeg');
      expect(ch.mediaWidth, 512);
      expect(ch.mediaHeight, 512);
    });

    test('toJson produces correct wire format', () {
      const ch = ArtworkChannel(
        source: 'artist',
        format: 'png',
        mediaWidth: 256,
        mediaHeight: 256,
      );
      expect(ch.toJson(), {
        'source': 'artist',
        'format': 'png',
        'media_width': 256,
        'media_height': 256,
      });
    });
  });

  group('ArtworkFrame', () {
    test('stores channel, timestamp, and image data', () {
      final frame = ArtworkFrame(
        channel: 2,
        timestampUs: 123456,
        imageData: Uint8List.fromList([0xFF, 0xD8]),
      );
      expect(frame.channel, 2);
      expect(frame.timestampUs, 123456);
      expect(frame.imageData, [0xFF, 0xD8]);
    });
  });
```

Also add `import 'dart:typed_data';` at the top of the test file.

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/models_test.dart`
Expected: Compilation errors — `SendspinRole`, `ArtworkChannel`, `ArtworkFrame` not defined.

- [ ] **Step 3: Implement SendspinRole enum**

Add to the top of `lib/src/models.dart`, before the `SendspinConnectionReason` enum:

```dart
/// Client roles defined by the Sendspin protocol.
enum SendspinRole {
  player('player@v1'),
  controller('controller@v1'),
  metadata('metadata@v1'),
  artwork('artwork@v1');

  final String wireValue;
  const SendspinRole(this.wireValue);
}
```

- [ ] **Step 4: Implement ArtworkChannel class**

Add after the `StreamConfig` class at the bottom of `lib/src/models.dart`:

```dart
/// Artwork channel configuration for the artwork@v1 role.
///
/// Each channel requests a specific image source, format, and resolution.
/// Up to 4 channels may be configured (mapping to binary frame types 8-11).
class ArtworkChannel {
  final String source;
  final String format;
  final int mediaWidth;
  final int mediaHeight;

  const ArtworkChannel({
    required this.source,
    required this.format,
    required this.mediaWidth,
    required this.mediaHeight,
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'format': format,
        'media_width': mediaWidth,
        'media_height': mediaHeight,
      };
}
```

- [ ] **Step 5: Implement ArtworkFrame class**

Add after `ArtworkChannel` in `lib/src/models.dart`:

```dart
/// A parsed binary artwork frame from the Sendspin protocol.
///
/// Artwork frames use binary message types 8-11, mapping to channels 0-3.
class ArtworkFrame {
  final int channel;
  final int timestampUs;
  final Uint8List imageData;

  const ArtworkFrame({
    required this.channel,
    required this.timestampUs,
    required this.imageData,
  });
}
```

Also add `import 'dart:typed_data';` at the top of `lib/src/models.dart`.

- [ ] **Step 6: Run tests to verify they pass**

Run: `dart test test/models_test.dart`
Expected: All tests pass.

- [ ] **Step 7: Run full test suite to check for regressions**

Run: `dart test`
Expected: All existing tests still pass.

- [ ] **Step 8: Commit**

```bash
git add lib/src/models.dart test/models_test.dart
git commit -m "feat: add SendspinRole, ArtworkChannel, and ArtworkFrame models"
```

---

### Task 2: Add `roles` Parameter and Role-Aware `buildClientHello`

**Files:**
- Modify: `lib/src/protocol.dart`
- Modify: `test/protocol_test.dart`

- [ ] **Step 1: Write tests for role-aware client/hello**

Add a new group in `test/protocol_test.dart`, after the existing `SendspinProtocol` group (before the `server/state metadata` group):

```dart
  group('multi-role client/hello', () {
    test('default roles produces player@v1 only (backward compat)', () {
      final p = SendspinProtocol(
        playerName: 'P',
        clientId: 'c',
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
        clientId: 'c',
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
        clientId: 'c',
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

    test('artwork role includes artwork@v1_support with channels', () {
      final p = SendspinProtocol(
        playerName: 'Display',
        clientId: 'c',
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
      final support = payload['artwork@v1_support'] as Map<String, dynamic>;
      final channels = support['channels'] as List;
      expect(channels, hasLength(1));
      final ch = channels[0] as Map<String, dynamic>;
      expect(ch['source'], 'album');
      expect(ch['format'], 'jpeg');
      expect(ch['media_width'], 512);
      expect(ch['media_height'], 512);
      p.dispose();
    });

    test('multi-role advertises all roles and correct support blocks', () {
      final p = SendspinProtocol(
        playerName: 'Full Client',
        clientId: 'c',
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
      expect(roles, containsAll([
        'player@v1',
        'controller@v1',
        'metadata@v1',
        'artwork@v1',
      ]));
      expect(payload.containsKey('player@v1_support'), isTrue);
      expect(payload.containsKey('artwork@v1_support'), isTrue);
      // controller and metadata have no support blocks
      expect(payload.containsKey('controller@v1_support'), isFalse);
      expect(payload.containsKey('metadata@v1_support'), isFalse);
      p.dispose();
    });

    test('artwork role without channels throws ArgumentError', () {
      expect(
        () => SendspinProtocol(
          playerName: 'P',
          clientId: 'c',
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
          clientId: 'c',
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
          clientId: 'c',
          bufferSeconds: 0,
          roles: const {SendspinRole.artwork},
          artworkChannels: const [
            ArtworkChannel(source: 'album', format: 'jpeg', mediaWidth: 100, mediaHeight: 100),
            ArtworkChannel(source: 'artist', format: 'jpeg', mediaWidth: 100, mediaHeight: 100),
            ArtworkChannel(source: 'none', format: 'jpeg', mediaWidth: 100, mediaHeight: 100),
            ArtworkChannel(source: 'album', format: 'png', mediaWidth: 100, mediaHeight: 100),
            ArtworkChannel(source: 'artist', format: 'png', mediaWidth: 100, mediaHeight: 100),
          ],
        ),
        throwsArgumentError,
      );
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/protocol_test.dart`
Expected: Compilation errors — `roles` parameter and `ArtworkChannel` not accepted.

- [ ] **Step 3: Add `roles` and `artworkChannels` parameters to `SendspinProtocol`**

In `lib/src/protocol.dart`, modify the `SendspinProtocol` class fields and constructor:

Add fields after `supportedFormats`:

```dart
  final Set<SendspinRole> roles;
  final List<ArtworkChannel>? artworkChannels;
```

Update the constructor signature to accept the new params (add after `supportedFormats`):

```dart
  SendspinProtocol({
    required this.playerName,
    required this.clientId,
    required this.bufferSeconds,
    this.deviceInfo = const DeviceInfo(),
    this.supportedFormats = const [
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 44100, bitDepth: 16),
    ],
    this.roles = const {SendspinRole.player},
    this.artworkChannels,
    int initialStaticDelayMs = 0,
  }) {
    if (roles.contains(SendspinRole.artwork) &&
        (artworkChannels == null || artworkChannels!.isEmpty)) {
      throw ArgumentError(
          'artworkChannels is required when artwork role is present');
    }
    if (artworkChannels != null && artworkChannels!.length > 4) {
      throw ArgumentError('artworkChannels may have at most 4 entries');
    }
    _staticDelayMs = initialStaticDelayMs.clamp(0, 5000);
    _state = _state.copyWith(staticDelayMs: _staticDelayMs);
  }
```

- [ ] **Step 4: Rewrite `buildClientHello` to be role-driven**

Replace the existing `buildClientHello` method body:

```dart
  String buildClientHello() {
    final payload = <String, dynamic>{
      'client_id': clientId,
      'name': playerName,
      'version': 1,
      'supported_roles': roles.map((r) => r.wireValue).toList(),
      'device_info': {
        'product_name': deviceInfo.productName,
        'manufacturer': deviceInfo.manufacturer,
        'software_version': deviceInfo.softwareVersion,
      },
    };

    if (roles.contains(SendspinRole.player)) {
      payload['player@v1_support'] = {
        'supported_formats': supportedFormats.map((f) => f.toJson()).toList(),
        'buffer_capacity': _computeBufferCapacityBytes(),
        'supported_commands': ['volume', 'mute', 'set_static_delay'],
      };
    }

    if (roles.contains(SendspinRole.artwork)) {
      payload['artwork@v1_support'] = {
        'channels': artworkChannels!.map((c) => c.toJson()).toList(),
      };
    }

    return jsonEncode({'type': 'client/hello', 'payload': payload});
  }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `dart test test/protocol_test.dart`
Expected: All tests pass, including the existing `buildClientHello` tests (they still create default player-only protocols).

- [ ] **Step 6: Run full test suite**

Run: `dart test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/src/protocol.dart test/protocol_test.dart
git commit -m "feat: add roles parameter and role-aware buildClientHello"
```

---

### Task 3: Artwork Binary Frame Dispatch

**Files:**
- Modify: `lib/src/protocol.dart`
- Modify: `test/protocol_test.dart`

- [ ] **Step 1: Write tests for artwork frame dispatch**

Add a new group in `test/protocol_test.dart`:

```dart
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
        clientId: 'c',
        bufferSeconds: 0,
        roles: const {SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(source: 'album', format: 'jpeg', mediaWidth: 100, mediaHeight: 100),
        ],
      );
      ArtworkFrame? received;
      p.onArtworkFrame = (f) => received = f;

      p.handleBinaryMessage(buildTypedFrame(8, 555000, [0xFF, 0xD8, 0xFF]));

      expect(received, isNotNull);
      expect(received!.channel, 0);
      expect(received!.timestampUs, 555000);
      expect(received!.imageData, [0xFF, 0xD8, 0xFF]);
      p.dispose();
    });

    test('artwork frame type 11 maps to channel 3', () {
      final p = SendspinProtocol(
        playerName: 'P',
        clientId: 'c',
        bufferSeconds: 0,
        roles: const {SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(source: 'album', format: 'jpeg', mediaWidth: 100, mediaHeight: 100),
          ArtworkChannel(source: 'artist', format: 'jpeg', mediaWidth: 100, mediaHeight: 100),
          ArtworkChannel(source: 'none', format: 'jpeg', mediaWidth: 100, mediaHeight: 100),
          ArtworkChannel(source: 'album', format: 'png', mediaWidth: 100, mediaHeight: 100),
        ],
      );
      ArtworkFrame? received;
      p.onArtworkFrame = (f) => received = f;

      p.handleBinaryMessage(buildTypedFrame(11, 999, [0x01]));

      expect(received, isNotNull);
      expect(received!.channel, 3);
      p.dispose();
    });

    test('artwork frames are dropped when artwork role is not active', () {
      final p = SendspinProtocol(
        playerName: 'P',
        clientId: 'c',
        bufferSeconds: 5,
        roles: const {SendspinRole.player},
      );
      ArtworkFrame? received;
      p.onArtworkFrame = (f) => received = f;

      p.handleBinaryMessage(buildTypedFrame(8, 1, [0x01]));

      expect(received, isNull);
      p.dispose();
    });

    test('player frames still work alongside artwork role', () {
      final p = SendspinProtocol(
        playerName: 'P',
        clientId: 'c',
        bufferSeconds: 5,
        roles: const {SendspinRole.player, SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(source: 'album', format: 'jpeg', mediaWidth: 100, mediaHeight: 100),
        ],
      );
      AudioFrame? audioReceived;
      ArtworkFrame? artworkReceived;
      p.onAudioFrame = (f) => audioReceived = f;
      p.onArtworkFrame = (f) => artworkReceived = f;

      p.handleBinaryMessage(buildTypedFrame(4, 100, [0x01, 0x02]));
      p.handleBinaryMessage(buildTypedFrame(8, 200, [0xFF, 0xD8]));

      expect(audioReceived, isNotNull);
      expect(audioReceived!.type, 4);
      expect(artworkReceived, isNotNull);
      expect(artworkReceived!.channel, 0);
      p.dispose();
    });

    test('player frames dropped when player role not active', () {
      final p = SendspinProtocol(
        playerName: 'P',
        clientId: 'c',
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      AudioFrame? received;
      p.onAudioFrame = (f) => received = f;

      p.handleBinaryMessage(buildTypedFrame(4, 1, [0x01]));

      expect(received, isNull);
      p.dispose();
    });
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/protocol_test.dart`
Expected: Compilation error — `onArtworkFrame` not defined.

- [ ] **Step 3: Add `onArtworkFrame` callback and update `handleBinaryMessage`**

In `lib/src/protocol.dart`, add the callback with the other callbacks (after `onAudioFrame`):

```dart
  /// Called when a binary artwork frame is received (artwork role).
  void Function(ArtworkFrame frame)? onArtworkFrame;
```

Add constants for artwork type range (after the existing player constants):

```dart
const int _binaryTypeArtworkMin = 8;
const int _binaryTypeArtworkMax = 11;
```

Replace the `handleBinaryMessage` method:

```dart
  void handleBinaryMessage(Uint8List data) {
    if (data.length < 9) return;
    final frame = parseBinaryFrame(data);

    if (frame.type >= _binaryTypePlayerMin &&
        frame.type <= _binaryTypePlayerMax) {
      if (roles.contains(SendspinRole.player)) {
        onAudioFrame?.call(frame);
      }
      return;
    }

    if (frame.type >= _binaryTypeArtworkMin &&
        frame.type <= _binaryTypeArtworkMax) {
      if (roles.contains(SendspinRole.artwork)) {
        onArtworkFrame?.call(ArtworkFrame(
          channel: frame.type - _binaryTypeArtworkMin,
          timestampUs: frame.timestampUs,
          imageData: frame.audioData,
        ));
      }
      return;
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test test/protocol_test.dart`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite**

Run: `dart test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/src/protocol.dart test/protocol_test.dart
git commit -m "feat: dispatch artwork binary frames when artwork role is active"
```

---

### Task 4: Controller Command Sending

**Files:**
- Modify: `lib/src/protocol.dart`
- Modify: `test/protocol_test.dart`

- [ ] **Step 1: Write tests for controller commands**

Add a new group in `test/protocol_test.dart`:

```dart
  group('controller commands', () {
    test('sendControllerCommand sends client/command with controller payload', () {
      final p = SendspinProtocol(
        playerName: 'Remote',
        clientId: 'c',
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      p.onSendText = sent.add;

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
        clientId: 'c',
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      p.onSendText = sent.add;

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
        clientId: 'c',
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      p.onSendText = sent.add;

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
        clientId: 'c',
        bufferSeconds: 5,
        roles: const {SendspinRole.player},
      );
      expect(() => p.sendControllerCommand('play'), throwsStateError);
      p.dispose();
    });

    test('sendControllerVolume throws StateError without controller role', () {
      final p = SendspinProtocol(
        playerName: 'P',
        clientId: 'c',
        bufferSeconds: 5,
      );
      expect(() => p.sendControllerVolume(50), throwsStateError);
      p.dispose();
    });

    test('sendControllerMute throws StateError without controller role', () {
      final p = SendspinProtocol(
        playerName: 'P',
        clientId: 'c',
        bufferSeconds: 5,
      );
      expect(() => p.sendControllerMute(true), throwsStateError);
      p.dispose();
    });

    test('all spec commands can be sent', () {
      final p = SendspinProtocol(
        playerName: 'Remote',
        clientId: 'c',
        bufferSeconds: 0,
        roles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      p.onSendText = sent.add;

      const commands = [
        'play', 'pause', 'stop', 'next', 'previous',
        'repeat_off', 'repeat_one', 'repeat_all',
        'shuffle', 'unshuffle', 'switch',
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
  });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/protocol_test.dart`
Expected: Compilation errors — `sendControllerCommand`, `sendControllerVolume`, `sendControllerMute` not defined.

- [ ] **Step 3: Implement controller command methods**

Add to `lib/src/protocol.dart`, in the message builders section (after `buildClientGoodbye`):

```dart
  void _requireRole(SendspinRole role) {
    if (!roles.contains(role)) {
      throw StateError(
          '${role.wireValue} role is required but not in the role set');
    }
  }

  /// Sends a controller command (e.g. 'play', 'pause', 'stop', 'next').
  ///
  /// Throws [StateError] if the controller role is not active.
  void sendControllerCommand(String command) {
    _requireRole(SendspinRole.controller);
    onSendText?.call(jsonEncode({
      'type': 'client/command',
      'payload': {
        'controller': {'command': command},
      },
    }));
  }

  /// Sends a controller volume command (0-100).
  ///
  /// Throws [StateError] if the controller role is not active.
  void sendControllerVolume(int volume) {
    _requireRole(SendspinRole.controller);
    onSendText?.call(jsonEncode({
      'type': 'client/command',
      'payload': {
        'controller': {'command': 'volume', 'volume': volume},
      },
    }));
  }

  /// Sends a controller mute command.
  ///
  /// Throws [StateError] if the controller role is not active.
  void sendControllerMute(bool mute) {
    _requireRole(SendspinRole.controller);
    onSendText?.call(jsonEncode({
      'type': 'client/command',
      'payload': {
        'controller': {'command': 'mute', 'mute': mute},
      },
    }));
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `dart test test/protocol_test.dart`
Expected: All tests pass.

- [ ] **Step 5: Run full test suite**

Run: `dart test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add lib/src/protocol.dart test/protocol_test.dart
git commit -m "feat: add controller command sending methods"
```

---

### Task 5: SendspinPlayer `additionalRoles` and Delegation

**Files:**
- Modify: `lib/src/player.dart`
- Modify: `test/player_test.dart`

- [ ] **Step 1: Write tests for additionalRoles and delegation**

Add to the `SendspinPlayer` group in `test/player_test.dart`, before the closing `});`:

```dart
    test('additionalRoles are passed through to protocol', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        clientId: 'c',
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller, SendspinRole.metadata},
      );
      p.onSendText = (_) {};
      expect(p.protocol.roles, containsAll([
        SendspinRole.player,
        SendspinRole.controller,
        SendspinRole.metadata,
      ]));
      p.dispose();
    });

    test('player role is always included even if not in additionalRoles', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        clientId: 'c',
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller},
      );
      p.onSendText = (_) {};
      expect(p.protocol.roles, contains(SendspinRole.player));
      p.dispose();
    });

    test('artwork additionalRole with channels is passed to protocol', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        clientId: 'c',
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
      p.onSendText = (_) {};
      expect(p.protocol.roles, contains(SendspinRole.artwork));

      final hello = jsonDecode(p.buildClientHello()) as Map<String, dynamic>;
      final payload = hello['payload'] as Map<String, dynamic>;
      expect(payload.containsKey('artwork@v1_support'), isTrue);
      p.dispose();
    });

    test('sendControllerCommand delegates to protocol', () {
      final p = SendspinPlayer(
        playerName: 'Full',
        clientId: 'c',
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      p.onSendText = sent.add;

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
        clientId: 'c',
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      p.onSendText = sent.add;

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
        clientId: 'c',
        bufferSeconds: 5,
        additionalRoles: const {SendspinRole.controller},
      );
      final sent = <String>[];
      p.onSendText = sent.add;

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
        clientId: 'c',
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
      p.onSendText = (_) {};

      ArtworkFrame? received;
      p.onArtworkFrame = (f) => received = f;

      final frame = Uint8List(12);
      frame[0] = 8; // artwork type
      ByteData.view(frame.buffer).setInt64(1, 777, Endian.big);
      frame[9] = 0xFF;
      frame[10] = 0xD8;
      frame[11] = 0xFF;
      p.handleBinaryMessage(frame);

      expect(received, isNotNull);
      expect(received!.channel, 0);
      expect(received!.timestampUs, 777);
      p.dispose();
    });
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dart test test/player_test.dart`
Expected: Compilation errors — `additionalRoles`, `artworkChannels`, `sendControllerCommand`, `sendControllerVolume`, `sendControllerMute`, `onArtworkFrame` not defined on `SendspinPlayer`.

- [ ] **Step 3: Add `additionalRoles` and `artworkChannels` to `SendspinPlayer`**

In `lib/src/player.dart`, update the constructor to accept and pass through the new params:

```dart
  SendspinPlayer({
    required String playerName,
    required String clientId,
    required int bufferSeconds,
    DeviceInfo deviceInfo = const DeviceInfo(),
    List<AudioFormat> supportedFormats = const [
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 44100, bitDepth: 16),
    ],
    Set<SendspinRole> additionalRoles = const {},
    List<ArtworkChannel>? artworkChannels,
    this.codecFactory,
    int initialStaticDelayMs = 0,
  })  : bufferSeconds = bufferSeconds,
        protocol = SendspinProtocol(
          playerName: playerName,
          clientId: clientId,
          bufferSeconds: bufferSeconds,
          deviceInfo: deviceInfo,
          supportedFormats: supportedFormats,
          roles: {SendspinRole.player, ...additionalRoles},
          artworkChannels: artworkChannels,
          initialStaticDelayMs: initialStaticDelayMs,
        ) {
    _wireProtocol();
  }
```

- [ ] **Step 4: Add delegated controller methods and artwork callback**

Add to the delegated getters/setters section in `lib/src/player.dart`:

```dart
  void Function(ArtworkFrame frame)? get onArtworkFrame =>
      protocol.onArtworkFrame;
  set onArtworkFrame(void Function(ArtworkFrame frame)? cb) =>
      protocol.onArtworkFrame = cb;
```

Add to the delegated methods section:

```dart
  void sendControllerCommand(String command) =>
      protocol.sendControllerCommand(command);
  void sendControllerVolume(int volume) =>
      protocol.sendControllerVolume(volume);
  void sendControllerMute(bool mute) => protocol.sendControllerMute(mute);
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `dart test test/player_test.dart`
Expected: All tests pass.

- [ ] **Step 6: Run full test suite**

Run: `dart test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add lib/src/player.dart test/player_test.dart
git commit -m "feat: add additionalRoles to SendspinPlayer with controller and artwork delegation"
```

---

### Task 6: Lint, Format, and Final Validation

**Files:**
- All modified files

- [ ] **Step 1: Run formatter**

Run: `dart format .`
Expected: No changes needed (or apply fixes).

- [ ] **Step 2: Run analyzer**

Run: `dart analyze --fatal-infos --fatal-warnings`
Expected: No issues.

- [ ] **Step 3: Run full test suite**

Run: `dart test`
Expected: All tests pass.

- [ ] **Step 4: Validate package**

Run: `dart pub publish --dry-run`
Expected: No blocking issues.

- [ ] **Step 5: Commit any formatting fixes**

If the formatter or analyzer required changes:

```bash
git add -A
git commit -m "style: apply dart format"
```
