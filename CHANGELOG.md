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
