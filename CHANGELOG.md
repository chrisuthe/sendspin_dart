## 0.0.4

### Multi-role support

- Add `SendspinRole` enum and `roles` parameter to `SendspinProtocol`; `buildClientHello` is now role-aware.
- Add `ArtworkChannel` and `ArtworkFrame` models; dispatch artwork binary frames when the artwork role is active.
- Add controller command-sending methods (`sendControllerCommand`, `sendControllerVolume`, `sendControllerMute`) for controller-role clients.
- Add `additionalRoles` on `SendspinPlayer` with delegation to controller and artwork handlers; `player` role is always included.

### Spec compliance

- `client/state` `supported_commands` now only advertises `set_static_delay`. `volume` and `mute` belong in `client/hello`'s `player@v1_support.supported_commands`; listing them at the state level violates the spec, and newer aiosendspin closes the connection on violation.

Note: version 0.0.3 was tagged on a separate lineage and never released; all of its content is rolled into 0.0.4.

## 0.0.2

### Spec compliance

- Send `client/goodbye` via new `sendGoodbye()` API with `SendspinGoodbyeReason` enum.
- Wire `set_static_delay` from protocol through to the jitter buffer so server-commanded delay actually affects playback timing.
- Accept `initialStaticDelayMs` in the constructor and expose `onStaticDelayChanged` so consumer apps can persist the value across reboots.
- Emit `client/state` with `state: "error"` on sustained buffer underrun, and recover to `"synchronized"` when audio resumes.
- Filter binary frames by message type (player range 4–7); drop artwork/visualizer frames instead of mis-routing them. `AudioFrame` now carries a required `type` field.
- Compute `buffer_capacity` in `client/hello` from the largest advertised `supportedFormats` entry rather than a hardcoded 48k/stereo/16-bit value.

### New observability

- Parse `connection_reason` and `active_roles` from `server/hello`; exposed on `SendspinPlayerState`.
- Handle `group/update` messages with delta merge; adds `SendspinGroupState`, `SendspinGroupPlaybackState`, and `onGroupUpdate` callback.
- Parse `server/state` metadata and controller sub-objects; adds `SendspinMetadata`, `SendspinMetadataProgress`, `SendspinControllerInfo`, `SendspinRepeatMode`, plus `onMetadataUpdate` and `onControllerUpdate` callbacks.

### Docs

- README section documenting that mDNS discovery (`_sendspin._tcp.local.`) is intentionally left to consumer apps.

## 0.0.1

- Initial release
- Pure Dart Sendspin protocol client (no Flutter dependency)
- Three-layer architecture:
  - `SendspinProtocol` — protocol state machine (message parsing, clock sync, state) for visualizers, conformance tests, and headless consumers
  - `SendspinPlayer` — audio pipeline composing protocol + codec + jitter buffer (drop-in for audio playback)
  - `AudioSink` — abstract platform-specific audio output
- Kalman filter clock synchronization
- Pull-based jitter buffer with sync corrections (deadband, micro-correction, re-anchor)
- PCM codec (16, 24, 32-bit)
- Pluggable codec factory for custom codecs (e.g. FLAC via FFI)
- `SendspinClient` kept as a deprecated alias for `SendspinPlayer`
