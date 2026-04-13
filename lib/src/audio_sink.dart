import 'dart:typed_data';

/// Abstract interface for platform-specific audio output.
///
/// Implementations handle the actual audio playback on a given platform
/// (e.g. WASAPI on Windows, PulseAudio/ALSA on Linux, CoreAudio on macOS).
/// The [SendspinClient] produces decoded PCM samples; an [AudioSink]
/// implementation consumes them and sends them to the hardware.
abstract class AudioSink {
  /// Initialize the audio output with the given format.
  Future<void> initialize(
      {required int sampleRate, required int channels, required int bitDepth});

  /// Start audio playback.
  Future<void> start();

  /// Stop audio playback.
  Future<void> stop();

  /// Write interleaved PCM samples to the audio output.
  Future<void> writeSamples(Uint8List samples);

  /// Set the playback volume (0.0 to 1.0).
  Future<void> setVolume(double volume);

  /// Set the muted state.
  Future<void> setMuted(bool muted);

  /// Release all resources.
  Future<void> dispose();
}
