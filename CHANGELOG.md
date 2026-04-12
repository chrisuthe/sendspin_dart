## 0.1.0

- Initial release
- Pure Dart Sendspin protocol client (no Flutter dependency)
- Kalman filter clock synchronization
- Pull-based jitter buffer with sync corrections (deadband, micro-correction, re-anchor)
- PCM codec (16, 24, 32-bit)
- Abstract AudioSink interface for platform-specific audio output
- Pluggable codec factory for custom codecs (e.g. FLAC via FFI)
