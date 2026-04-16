# Multi-Role Support Design

**Date:** 2026-04-16
**Status:** Approved
**Scope:** Add Controller, Metadata, and Artwork role support to sendspin_dart

## Context

The SendSpin protocol defines five client roles: Player, Controller, Metadata,
Artwork, and Visualizer. This library currently only supports the Player role.
Controller and Metadata data is partially received (via `server/state` parsing)
but neither role is advertised, no controller commands can be sent, and artwork
binary frames (type 8-11) are silently dropped.

This design adds full support for Controller, Metadata, and Artwork. Visualizer
is out of scope.

## Design Principles

- A single connection can hold any combination of roles (multi-role).
- A connection with no Player role is valid (e.g. a control surface).
- Backward compatible: existing code that doesn't specify roles defaults to
  Player-only, matching current behavior.
- Follows the existing codebase patterns: enum-with-wire-value, callback-based
  dispatch, protocol/player layer split.

## 1. Role Enum

New enum in `models.dart`:

```dart
enum SendspinRole {
  player('player@v1'),
  controller('controller@v1'),
  metadata('metadata@v1'),
  artwork('artwork@v1');

  final String wireValue;
  const SendspinRole(this.wireValue);
}
```

## 2. Protocol Configuration

`SendspinProtocol` gets a `roles` parameter:

```dart
SendspinProtocol({
  required this.playerName,
  required this.clientId,
  required this.bufferSeconds,
  this.roles = const {SendspinRole.player},
  this.artworkChannels,
  // ... existing params unchanged
})
```

- `roles` defaults to `{SendspinRole.player}` for backward compatibility.
- `artworkChannels` is required when `SendspinRole.artwork` is in the role set.
  Constructor throws `ArgumentError` if artwork role is present but channels
  are null or empty, or if more than 4 channels are provided.
- `supportedFormats` and `bufferSeconds` are only meaningful when
  `SendspinRole.player` is in the role set.

## 3. Artwork Channel Configuration

New model in `models.dart`:

```dart
class ArtworkChannel {
  final String source;     // 'album', 'artist', 'none'
  final String format;     // 'jpeg', 'png', 'bmp'
  final int mediaWidth;
  final int mediaHeight;

  const ArtworkChannel({
    required this.source,
    required this.format,
    required this.mediaWidth,
    required this.mediaHeight,
  });
}
```

Up to 4 channels (matching binary frame types 8-11 = channels 0-3).

## 4. Artwork Frame Model

New model in `models.dart`:

```dart
class ArtworkFrame {
  final int channel;        // 0-3, derived from (type - 8)
  final int timestampUs;
  final Uint8List imageData;

  const ArtworkFrame({
    required this.channel,
    required this.timestampUs,
    required this.imageData,
  });
}
```

## 5. client/hello Wire Format

`buildClientHello()` becomes role-driven. The `supported_roles` array contains
the wire value of each role in the set. Role-specific support blocks are
included only when the corresponding role is present:

**Player** (`player@v1_support`) — unchanged from today:
```json
{
  "supported_formats": [...],
  "buffer_capacity": 960000,
  "supported_commands": ["volume", "mute", "set_static_delay"]
}
```

**Controller** — no support block per spec. Just listed in `supported_roles`.

**Metadata** — no support block per spec. Just listed in `supported_roles`.

**Artwork** (`artwork@v1_support`):
```json
{
  "channels": [
    {"source": "album", "format": "jpeg", "media_width": 512, "media_height": 512}
  ]
}
```

## 6. Binary Frame Dispatch

`handleBinaryMessage` dispatches by type range and role:

| Type Range | Role Required | Callback |
|---|---|---|
| 4-7 | `SendspinRole.player` | `onAudioFrame` (existing) |
| 8-11 | `SendspinRole.artwork` | `onArtworkFrame` (new) |
| All others | — | Dropped |

Frames for roles not in the active set are silently dropped (same as today).

## 7. Controller Command Sending

New methods on `SendspinProtocol`:

```dart
void sendControllerCommand(String command);
void sendControllerVolume(int volume);
void sendControllerMute(bool mute);
```

Wire format per spec:
```json
{
  "type": "client/command",
  "payload": {
    "controller": {
      "command": "play"
    }
  }
}
```

For `volume` and `mute`, the corresponding parameter is added alongside
`command`. These methods throw `StateError` if
`SendspinRole.controller` is not in the role set.

Spec-defined commands: `play`, `pause`, `stop`, `next`, `previous`, `volume`,
`mute`, `repeat_off`, `repeat_one`, `repeat_all`, `shuffle`, `unshuffle`,
`switch`.

## 8. SendspinPlayer Changes

`SendspinPlayer` gets an `additionalRoles` parameter:

```dart
SendspinPlayer({
  // ... existing params
  Set<SendspinRole> additionalRoles = const {},
})
```

It merges `{SendspinRole.player, ...additionalRoles}` and passes to the
underlying `SendspinProtocol`. The Player role is always included since
`SendspinPlayer` is the audio pipeline.

New callbacks (`onArtworkFrame`) and controller command methods are delegated
through to the protocol, following the same pattern as existing delegations
like `onVolumeChanged` and `onMetadataUpdate`.

## 9. New Callbacks

| Callback | On `SendspinProtocol` | Delegated via `SendspinPlayer` |
|---|---|---|
| `onArtworkFrame` | Yes | Yes |

`onMetadataUpdate` and `onControllerUpdate` already exist.

## 10. Files Changed

| File | Change |
|---|---|
| `lib/src/models.dart` | Add `SendspinRole`, `ArtworkChannel`, `ArtworkFrame` |
| `lib/src/protocol.dart` | `roles` param, role-aware `buildClientHello`, artwork dispatch, controller command methods |
| `lib/src/player.dart` | `additionalRoles` param, delegate new callbacks + controller methods |
| `test/protocol_test.dart` | Multi-role hello, controller commands, artwork frames |
| `test/player_test.dart` | additionalRoles delegation |
| `test/models_test.dart` | New model classes |

No new files.

## 11. Backward Compatibility

- Default `roles` is `{SendspinRole.player}` — existing code works unchanged.
- `SendspinPlayer` always includes Player — existing player code works unchanged.
- `SendspinClient` typedef continues to alias `SendspinPlayer` — no change.
- All new parameters are optional with backward-compatible defaults.
