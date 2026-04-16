import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'protocol.dart';
import 'buffer.dart';
import 'codec.dart';
import 'models.dart';

/// High-level audio player that composes [SendspinProtocol] with a codec and
/// jitter buffer to provide the full audio pipeline.
///
/// Its public API mirrors the old `SendspinClient` so it can serve as a
/// drop-in replacement.
class SendspinPlayer {
  /// The underlying protocol instance, exposed for advanced consumers.
  final SendspinProtocol protocol;

  /// Called when audio streaming begins with the negotiated format.
  void Function(int sampleRate, int channels, int bitDepth)? onStreamStart;

  /// Called when audio streaming ends.
  void Function()? onStreamStop;

  /// Optional factory for creating codecs. If it returns null or is not set,
  /// the built-in [createCodec] is used as a fallback.
  final SendspinCodec? Function(
      String codec, int bitDepth, int channels, int sampleRate)? codecFactory;

  final int bufferSeconds;

  SendspinCodec? _codec;
  SendspinBuffer? _buffer;
  Timer? _underrunPollTimer;

  void Function(int delayMs)? _userOnStaticDelayChanged;

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

  // ---------------------------------------------------------------------------
  // Delegated getters / setters
  // ---------------------------------------------------------------------------

  SendspinPlayerState get state => protocol.state;
  Stream<SendspinPlayerState> get stateStream => protocol.stateStream;

  void Function(String message)? get onSendText => protocol.onSendText;
  set onSendText(void Function(String message)? cb) => protocol.onSendText = cb;

  void Function(double volume, bool muted)? get onVolumeChanged =>
      protocol.onVolumeChanged;
  set onVolumeChanged(void Function(double volume, bool muted)? cb) =>
      protocol.onVolumeChanged = cb;

  void Function(SendspinGroupState groupState)? get onGroupUpdate =>
      protocol.onGroupUpdate;
  set onGroupUpdate(void Function(SendspinGroupState groupState)? cb) =>
      protocol.onGroupUpdate = cb;

  void Function(SendspinMetadata metadata)? get onMetadataUpdate =>
      protocol.onMetadataUpdate;
  set onMetadataUpdate(void Function(SendspinMetadata metadata)? cb) =>
      protocol.onMetadataUpdate = cb;

  void Function(SendspinControllerInfo controller)? get onControllerUpdate =>
      protocol.onControllerUpdate;
  set onControllerUpdate(
          void Function(SendspinControllerInfo controller)? cb) =>
      protocol.onControllerUpdate = cb;

  void Function(ArtworkFrame frame)? get onArtworkFrame =>
      protocol.onArtworkFrame;
  set onArtworkFrame(void Function(ArtworkFrame frame)? cb) =>
      protocol.onArtworkFrame = cb;

  int get staticDelayMs => protocol.staticDelayMs;

  void Function(int delayMs)? get onStaticDelayChanged =>
      _userOnStaticDelayChanged;
  set onStaticDelayChanged(void Function(int delayMs)? cb) =>
      _userOnStaticDelayChanged = cb;

  // ---------------------------------------------------------------------------
  // Delegated methods
  // ---------------------------------------------------------------------------

  String buildClientHello() => protocol.buildClientHello();
  String buildClientTime(int clientTransmittedUs) =>
      protocol.buildClientTime(clientTransmittedUs);
  String buildClientState() => protocol.buildClientState();

  String buildClientGoodbye(SendspinGoodbyeReason reason) =>
      protocol.buildClientGoodbye(reason);

  void sendGoodbye(SendspinGoodbyeReason reason) =>
      protocol.sendGoodbye(reason);

  void sendControllerCommand(String command) =>
      protocol.sendControllerCommand(command);
  void sendControllerVolume(int volume) =>
      protocol.sendControllerVolume(volume);
  void sendControllerMute(bool mute) => protocol.sendControllerMute(mute);

  void handleTextMessage(String text) => protocol.handleTextMessage(text);
  void handleBinaryMessage(Uint8List data) =>
      protocol.handleBinaryMessage(data);

  void updateVolume(double volume) => protocol.updateVolume(volume);

  void startClockSync() => protocol.startClockSync();
  void stopClockSync() => protocol.stopClockSync();

  static AudioFrame parseBinaryFrame(Uint8List frame) =>
      SendspinProtocol.parseBinaryFrame(frame);

  // ---------------------------------------------------------------------------
  // Own methods
  // ---------------------------------------------------------------------------

  /// Pulls [count] samples from the jitter buffer, or returns silence if not
  /// streaming.
  Int16List pullSamples(int count) {
    if (_buffer == null) return Int16List(count);
    return _buffer!.pullSamples(count);
  }

  /// Resets for a new WebSocket connection: clears codec, buffer, and protocol
  /// timers.
  void resetForNewConnection() {
    protocol.resetForNewConnection();
    _underrunPollTimer?.cancel();
    _underrunPollTimer = null;
    _codec?.dispose();
    _codec = null;
    _buffer?.flush();
    _buffer = null;
  }

  /// Cleans up codec and protocol resources.
  void dispose() {
    _underrunPollTimer?.cancel();
    _underrunPollTimer = null;
    _codec?.dispose();
    _codec = null;
    _buffer = null;
    protocol.dispose();
  }

  // ---------------------------------------------------------------------------
  // Internal wiring
  // ---------------------------------------------------------------------------

  void _wireProtocol() {
    protocol.onStreamConfig = _handleStreamConfig;
    protocol.onAudioFrame = _handleAudioFrame;
    protocol.onStreamClear = _handleStreamClear;
    protocol.onStreamEnd = _handleStreamEnd;
    protocol.onStaticDelayChanged = (delayMs) {
      _buffer?.staticDelayMs = delayMs;
      _userOnStaticDelayChanged?.call(delayMs);
    };
  }

  void _handleStreamConfig(StreamConfig config) {
    final wasStreaming = _codec != null;

    // Dispose old codec.
    _codec?.dispose();
    _codec = null;

    // Try custom factory first, then fall back to built-in.
    if (codecFactory != null) {
      _codec = codecFactory!(
          config.codec, config.bitDepth, config.channels, config.sampleRate);
    }
    _codec ??= createCodec(
      codec: config.codec,
      bitDepth: config.bitDepth,
      channels: config.channels,
      sampleRate: config.sampleRate,
    );

    // If codec header is present, push it through the codec (e.g. FLAC STREAMINFO).
    if (config.codecHeader != null) {
      // codecHeader is base64-encoded.
      // Note: dart:convert is already available via protocol.dart's transitive
      // import, but we import it explicitly if needed.
      _codec!.decode(_base64Decode(config.codecHeader!));
    }

    // Buffer management: flush on track switch, create fresh otherwise.
    if (wasStreaming && _buffer != null) {
      _buffer!.flush();
    } else {
      _buffer = SendspinBuffer(
        sampleRate: config.sampleRate,
        channels: config.channels,
        startupBufferMs: 200,
        maxBufferMs: bufferSeconds * 1000,
      );
    }
    _buffer!.staticDelayMs = protocol.staticDelayMs;

    _underrunPollTimer ??= Timer.periodic(
        const Duration(milliseconds: 500), (_) => _checkUnderrun());

    onStreamStart?.call(config.sampleRate, config.channels, config.bitDepth);
  }

  void _checkUnderrun() {
    final buf = _buffer;
    if (buf == null) return;
    protocol.setPipelineError(buf.isInUnderrun);
  }

  void _handleAudioFrame(AudioFrame frame) {
    if (_codec == null || _buffer == null) return;
    final samples = _codec!.decode(frame.audioData);
    _buffer!.addChunk(frame.timestampUs, samples);
    protocol.updatePipelineState(
        protocol.state.copyWith(bufferDepthMs: _buffer!.bufferDepthMs));
  }

  void _handleStreamClear() {
    _buffer?.flush();
    _codec?.reset();
  }

  void _handleStreamEnd() {
    _underrunPollTimer?.cancel();
    _underrunPollTimer = null;
    protocol.setPipelineError(false);
    onStreamStop?.call();
    _buffer?.flush();
    _codec?.dispose();
    _codec = null;
    _buffer = null;
  }

  /// Decodes a base64 string to bytes.
  static Uint8List _base64Decode(String encoded) {
    return base64.decode(encoded);
  }
}
