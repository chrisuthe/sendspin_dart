## Unreleased (Sendspin 1.0.0-rc1)

Breaking: this release moves the library to the Sendspin 1.0.0-rc1 wire
protocol. It cannot talk to pre-rc1 servers.

### Encrypted transport and connection sequence

- Every connection is now encrypted with Noise `KKpsk2`
  (`25519_ChaChaPoly_SHA256`). The client sends `client/init`, reads
  `server/init` and Noise message 1, answers with message 2, and from then on
  every message is an encrypted WebSocket **binary** message: JSON is binary
  message ID 0 and messages over 65518 bytes are fragmented as ID 1.
- New consumer wiring: call `start()` once the socket is open (it replaces
  sending `buildClientHello()` yourself), wire `onSendBinary` next to
  `onSendText`, and close the socket when `onClose` fires. Handshake, AEAD and
  framing failures are silent on the wire and surface only through `onClose`;
  a `server/error` is also reported through `onServerError`.
- The order after the handshake is `server/hello`, `client/hello`,
  `server/activate`. Nothing else is sent before the first activation except
  `client/goodbye`, and clock sync starts on that activation.
- `client/hello` has the rc1 shape: `client_id` and `version` moved to
  `client/init`, `player@v1_support` lost `supported_commands`, and
  `supported_pair_methods` and `unpaired_access` were added. `DeviceInfo`
  gains an optional `macAddress`. `artwork@v1_support` is no longer sent.
- `server/activate` is handled: `state.activities`, `state.activeRoles` and
  the `onActivate` callback follow it, `active_roles` persists across
  activations that omit it, and an inadmissible activation is answered with
  `client/goodbye` (`pairing_required` or `unauthorized`) or `pair/abort`
  (`method_not_supported`) as the spec prescribes.
- New required constructor argument `unpairedAccess`: whether a server with
  no pairing record may activate roles or declare playback. It can be changed
  at runtime; turning it off closes a session that relies on it.
- When a role is removed its output or state goes with it: the player stream
  ends, metadata state and its pending update are discarded, controller state
  is cleared. Messages and binary data for inactive roles are ignored, and
  `sendController*` throws unless the controller role is active.
- In-band re-handshake is supported. Application messages produced between
  the re-handshake and the `server/activate` that follows are held and sent
  afterwards.
- `stream/clear` and `stream/end` honour their `roles` list.
- `SendspinGoodbyeReason` adds `unauthorized`, `pairingRequired`,
  `concurrentAttempt` and `unpaired`.
- Removed: `SendspinConnectionReason` and `state.connectionReason` (rc1 has
  no `connection_reason`; use `state.activities`), and the legacy top-level
  `audio_format` fallback in `stream/start`.
- New: `state.serverId`, `serverId`, `isPaired`, `isRoleActive`,
  `SendspinChannel`, `NoiseHandshake` / `NoiseSession`, and
  `example/sendspin_cli.dart`.

### Clock-scheduled playback

- **`pullSamples` changed:** `pullSamples(count, outputTimeUs: ...)`. The
  consumer passes the local time, on the `nowUs()` clock, at which the first
  requested sample will leave the audio port (now plus backend and DAC
  latency). The buffer returns exactly the audio due then, so the consumer's
  output latency is compensated instead of being ignored.
- `SendspinBuffer` is rewritten to schedule against the local clock. It keeps
  server timestamps and translates them through the time filter at the moment
  of each pull, subtracting the output delay, rather than anchoring to the
  first chunk and counting frames.
- On startup, `stream/clear`, underrun recovery and any error above 1 ms it
  snaps to position once: a late prefix is dropped, or silence is inserted
  until the audio is due. The 200 ms startup threshold is gone, so there is
  no startup warble and no fixed startup latency.
- Steady-state correction uses a 100 µs dead band and drops or duplicates
  whole frames (1 at 44.1/48 kHz, 2 at 96 kHz, 4 at 192 kHz), limited to 0.5%
  of the audio in any 150 ms. Previously: 2 ms dead band, up to 4%, and a
  500 ms re-anchor threshold.
- Output delay is a timestamp offset, not a hold-back of buffered samples. A
  change takes effect on the next pull; reducing it leaves extra audio
  buffered and playback waits it out.
- A `stream/start` on a running stream no longer flushes. Buffered chunks
  stay, each chunk is decoded in the format in effect when it arrived, and
  `onStreamStart` is called again from inside `pullSamples` at the sample
  where the new format takes effect.
- Chunks that arrive after their time has passed are dropped; a missing
  chunk becomes silence of the same length.
- `pullSamples` returns silence until the time filter is synchronized.
- New on `SendspinPlayer`: `nowUs()`, `syncErrorUs`, `framesDropped`,
  `framesInserted`, `resyncCount`, `lateChunksDropped`, and a `now` clock
  source. Removed from `SendspinBuffer`: `startupBufferMs`, `isInUnderrun`,
  and the fixed `sampleRate` / `channels` constructor arguments.

### Pairing

- The Pairing PSK method is implemented. After a pairing `server/activate`
  on a connection keyed by the pairing PSK, the client sends
  `client/pair-init` and `client/pair-finalize` back to back with a fresh
  long-term PSK, stores the pairing record when `server/pair-finalize`
  arrives, and is ready for the server's re-handshake to that PSK.
- New `SendspinPairing` holds the device's pairing PSK and its pairing
  records (at least 5, least recently used evicted, never one backing an
  open connection, an existing record for the same server replaced). It is
  loaded from a `SendspinPairingStore` the consumer implements; pass it as
  `pairing:`. Without one, an in-memory instance is used and pairings do not
  survive a restart.
- `pairingToken` gives the `SP:0...` token (public key plus pairing PSK) to
  show the operator as text or a QR code.
- The pairing PSK is always among the handshake candidates, so a server can
  re-handshake to it at any time.
- `pair/abort` in both directions: `cancelPairing()` (`user_cancelled`),
  `rejectConcurrentPairing()` (`concurrent_attempt`, then close), the 2-minute
  attempt timeout (`attempt_timeout`), and `onPairingAborted` for an abort
  from the server. A `server/activate` in place of `server/pair-finalize`
  abandons the attempt and nothing is stored.
- `server/unpair` on a paired session removes the record, sends
  `client/goodbye` reason `unpaired` and closes; on an unpaired session it is
  ignored.
- A pairing message that is out of sequence closes the connection without an
  application-level message.
- New callbacks `onPaired`, `onPairingAborted`, `onPairingStoreError`.
- The `pskCandidates` constructor hook is replaced by `pairing`.
- Not implemented: the optional dynamic and static pairing-code methods.

### client/state and player commands

- `client/state` carries `available` on every message instead of
  `state: 'synchronized' | 'error'`. A player reports `available: false`
  until its time filter is synchronized, then sends a new state. The second
  clock-sync burst now follows the first after 100 ms rather than 10 s, so
  that takes well under a second.
- The player object is the rc1 one: `volume`, `muted`, `output_delay_ms`,
  `required_lead_time_ms`, `min_buffer_ms`, `supported_commands`
  (`volume`, `mute`, `set_output_delay`) and optional `format`. It is sent in
  full each time, and only while the player role is active.
- **Renamed:** static delay is output delay throughout:
  `initialOutputDelayMs`, `outputDelayMs`, `onOutputDelayChanged`,
  `state.outputDelayMs`, `SendspinBuffer.outputDelayMs`, and on the wire
  `output_delay_ms` / `set_output_delay`. The spec requires the delay to
  survive reboots: persist it from `onOutputDelayChanged` and pass it back as
  `initialOutputDelayMs`.
- New constructor arguments `requiredLeadTimeMs` and `minBufferMs` (both
  default to 250) and `setTimingParameters(...)` to update them. They depend
  on the audio backend, so the consumer supplies them. The reported
  `min_buffer_ms` is `minBufferMs` or the measured arrival-delay tail,
  whichever is larger.
- New `supportedCommands` constructor argument and `setSupportedCommands`.
  Commands not currently listed are ignored.
- New `preferredFormat`, `setAvailable`, `sendLeave`, `setOutputDelayMs`,
  `updateMuted`, `isAvailable`.
- The `artwork` object (channels with `width` / `height`) is reported in
  `client/state` while the artwork role is active.
- **Removed:** `setPipelineError`, the player's underrun poll that drove it,
  and the 5-second periodic `client/state` resend. rc1 has no error state and
  state is sent when it changes.

### Identity: client_id is a Curve25519 public key

- `SendspinProtocol` and `SendspinPlayer` take `identity:` (a
  `SendspinIdentity`) instead of a free-form `clientId:` string. `clientId`
  is now a getter returning the public key as 43-character unpadded
  base64url.
- New `SendspinIdentity` (`generate`, `fromPrivateKey`, `loadOrCreate`) and
  the `SendspinIdentityStore` interface the consumer implements to persist
  the private key. The library does not choose a storage location.
- `loadOrCreate` only generates a key when the store is empty, and throws on
  a stored key of the wrong length instead of replacing it, so a bad read
  cannot rotate the device's identity.
- **Migration:** existing deployments get a new identity. Servers will see
  each upgraded device as a new client, so group membership and per-player
  settings keyed on the old `client_id` do not carry over.
- New dependency: `package:cryptography` (pure Dart). The minimum Dart SDK
  moves from 3.0 to 3.3.

### Player audio chunks

- Audio chunks (binary ID 4) now use the 13-byte rc1 header. `AudioFrame`
  gains `sendAheadUs`, and chunks shorter than 13 bytes are rejected.
- Binary IDs 5-7 belong to the player role but are not audio; they are
  ignored instead of being handed to the decoder.
- New `ArrivalDelayTracker` sizes `min_buffer_ms` from the upper tail of
  chunk arrival delay (`arrival - computeClientTime(timestamp - send_ahead)`),
  skipping saturated `send_ahead` values and samples taken before the time
  filter is synchronized. Exposed as `SendspinProtocol.measuredMinBufferMs`
  and `onArrivalDelay`.
- New `SendspinClock.isSynchronized` (two samples and a finite variance).
- `SendspinProtocol` accepts an optional `now` clock source.

### server/state and group/update are full-state

- Each `metadata` object in `server/state` now replaces the previous state
  instead of being merged onto it. A field the server omits is absent, so an
  omitted `progress` clears the position. `SendspinMetadata.mergeDelta` is
  replaced by `SendspinMetadata.fromJson`.
- Scheduled metadata updates: a `metadata` object whose `timestamp` is still
  in the future (per the time filter's current estimate) is held as
  `pendingMetadata` and applied when that moment is reached. A newer future
  update replaces it; a past or present one discards it. `onMetadataUpdate`
  fires when a state takes effect, not when it is received. The held update
  is re-evaluated whenever the time filter is updated, and a state received
  before the filter has any sample is applied immediately. A `metadata`
  object without a `timestamp` is ignored.
- New `currentTrackPositionMs` extrapolates the position from the current
  state only, never from the pending update.
- `group/update` replaces the group state; `SendspinGroupState.mergeDelta` is
  removed.
- `resetForNewConnection` discards the metadata state and any pending update.

## 0.0.7

### server/state metadata delta semantics (BUGFIX)

- `_handleServerState` now treats the `metadata` sub-object as
  delta-encoded, per the Sendspin spec and the aiosendspin reference
  implementation. Previously, every metadata update did wholesale
  snapshot replacement, dropping fields the server didn't re-send. The
  most visible casualty: `artwork_url` would disappear on the next
  title-only or progress-only update mid-track, even though the spec
  explicitly says absent fields must be preserved.
- New `SendspinMetadata.mergeDelta(Map<String, dynamic> json)` returns
  the merged result. Field-presence semantics:
  - **absent in JSON** → keep existing value
  - **`null` in JSON**  → clear (set to `null` / `RepeatMode.unknown`)
  - **value in JSON**   → replace
  Implemented by checking `Map.containsKey` per field — the absent /
  null distinction is lost once values are unwrapped through
  `as String?`, so the raw map has to be passed in.
- The `progress` sub-object is treated atomically: aiosendspin only
  emits a complete `Progress` (all three fields) or omits / nulls it,
  never a partial. So we replace the whole `progress` on present-with-
  value, keep on absent, and clear on explicit null.
- The `controller` sub-object is *not* delta-encoded —
  `ControllerStatePayload` in aiosendspin has no `omit_default` /
  `omit_none` config and all required non-nullable fields, so it's
  always emitted as a complete snapshot. `_handleServerState` continues
  to parse it wholesale, unchanged.
- Added regression tests covering: absent-keeps, null-clears, partial
  updates after a full snapshot, `cleared_update` (every field null),
  and a unit test on `SendspinMetadata.mergeDelta` itself.

## 0.0.6

### client/hello spec compliance (BUGFIX)

- Remove `set_static_delay` from `client/hello.player@v1_support.supported_commands`.
  The Sendspin spec defines this list as a subset of `{'volume', 'mute'}`;
  `set_static_delay` belongs in `client/state.player.supported_commands`
  (where it remains correctly advertised). Two earlier commits attempted
  this fix but only updated client/state, leaving the spec violation in
  client/hello. Music Assistant's Sendspin server (`aiohttp` 3.13.5)
  closes the WebSocket with code 1000 immediately on receiving a hello
  with the disallowed command, producing a connect→disconnect loop on
  every cycle. This was the root cause of the v0.0.4 / v0.0.5 handshake
  regression against MA. Added a regression test in `protocol_test.dart`.

## 0.0.5

### Clock sync (time-filter conformance)

- Bring `SendspinClock` defaults into line with the upstream `Sendspin/time-filter`
  reference (April 2026 revision): `processStdDev=0.0`, `driftProcessStdDev=1e-11`,
  `forgetFactor=2.0`, `adaptiveCutoff=3.0`, `driftSignificanceThreshold=2.0`.
  The legacy values were inherited from an older ESPHome snapshot and were
  algorithmically incorrect (cutoff and forget factor were in opposite regimes,
  causing forgetting to fire on noise while doing almost nothing when it did).
- Add `maxErrorScale` parameter (default `0.5`) that scales `max_error` before
  it is used as the measurement standard deviation, matching the upstream
  contract. The (unscaled) `max_error` is still used as the adaptive-forgetting
  cutoff reference.
- `getError()` now returns `-1` before the first measurement (covariance starts
  at infinity) instead of throwing on `infinity.round()`.

Behaviour change: callers constructing `SendspinClock()` without arguments
will see materially different filter dynamics. The new defaults converge
faster and recover from clock disruptions much more quickly. Anyone tuning
around the old broken defaults should retest.

### Burst-strategy clock sync

- New `SendspinTimeBurst` driver implements the upstream README's
  recommended burst strategy: 8 NTP exchanges sent **sequentially** (each
  awaiting its reply or a 10-second timeout) every 10 seconds. Only the
  lowest-`max_error` sample of the burst is fed to `SendspinClock.update`.
- `SendspinProtocol` now drives clock sync via this module instead of the
  previous parallel "5 messages 20 ms apart, every 2 s" loop, which
  violated the filter's measurement-independence assumption on TCP /
  WebSocket transports.
- Behaviour change: `SendspinPlayerState.clockSamples` advances at the
  burst rate (~6/min) rather than the per-reply rate (~150/min). The
  semantic is the same — "filter updates processed" — but the magnitude
  is much smaller. UI consumers using this as a "is sync alive" indicator
  should account for the slower cadence; `clockOffsetMs` (precision in ms)
  is the more robust health signal.

### Wire the time-filter into the audio pipeline

- `SendspinPlayer` now calls `SendspinClock.computeClientTime` on every
  inbound audio frame's server-clock timestamp before handing the chunk
  to the jitter buffer. Per the Sendspin spec ("Clients must translate
  this server timestamp to their local clock using the offset computed
  from clock synchronization"), this is the spec-mandated behaviour.
  Before this change the filter ran but its outputs were never used by
  the audio pipeline. Drift compensation now happens inside the Kalman
  filter where it has 100+ samples of evidence behind it, instead of
  being chased sample-by-sample by the buffer's micro-correction loop.
- All client-side timestamps used by the protocol — the filter's
  `time_added`, the NTP `client_transmitted` value sent on the wire, and
  the locally-recorded `client_received` (T4) — now derive from a single
  long-lived `Stopwatch` (monotonic). Wall-clock-derived timestamps would
  feed OS NTP corrections and DST jumps into the filter's `dt`, blowing
  up the predicted covariance.
- New: `SendspinProtocol.nowUs()` exposes the protocol-side monotonic
  clock for consumers that need to schedule events in the same domain
  as the buffered chunks' translated timestamps.

Behaviour notes:

- During the first burst window (~10 s after handshake) the filter's
  offset is still 0 and `_useDrift` is false, so `computeClientTime` is
  identity. Audio playback is unchanged from before during this window.
- When the first burst converges *while audio is already streaming*, the
  buffer's chunk timestamps shift from server-time to client-time. The
  buffer's re-anchor mechanism handles the one-time discontinuity by
  flushing once and re-anchoring on the new domain — a single audible
  glitch at convergence, not an ongoing problem.

### Buffer: spec-compliant late-chunk drop and first-re-anchor fix

- `SendspinBuffer.addChunk` now drops chunks whose entire duration falls
  before the current playhead, per the Sendspin spec ("Audio chunks may
  arrive with timestamps in the past due to network delays or buffering;
  clients should drop these late chunks to maintain sync"). Before
  translation was wired in, "late" was not meaningfully decidable
  client-side; with `computeClientTime` now driving the timestamps the
  drop is well-defined.
- The re-anchor cooldown previously gated *every* re-anchor including
  the first one, which meant the time-filter converging within ~5 s of
  stream start could silently fail to flush — leaving the buffer
  anchored in the wrong timestamp domain. The cooldown now only gates
  *subsequent* re-anchors (its actual purpose: prevent thrashing). The
  first re-anchor always fires.

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
