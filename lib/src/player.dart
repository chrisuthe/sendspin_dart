import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'protocol.dart';
import 'buffer.dart';
import 'codec.dart';
import 'identity.dart';
import 'models.dart';
import 'pairing.dart';

/// High-level audio player that composes [SendspinProtocol] with a codec and
/// jitter buffer to provide the full audio pipeline.
///
/// Its public API mirrors the old `SendspinClient` so it can serve as a
/// drop-in replacement.
class SendspinPlayer {
  /// The underlying protocol instance, exposed for advanced consumers.
  final SendspinProtocol protocol;

  /// Called with the format of the audio [pullSamples] is about to return:
  /// when a stream starts, and again when playback reaches audio in a
  /// different format after the server changed it on the running stream. In
  /// the second case the call comes from inside [pullSamples], at the sample
  /// where the change takes effect, and later pulls must be sized for the
  /// new format. [bitDepth] is the wire format's; the samples returned are
  /// always 16-bit.
  void Function(int sampleRate, int channels, int bitDepth)? onStreamStart;

  /// Called when audio streaming ends.
  void Function()? onStreamStop;

  /// Called when a `stream/start` cannot be played: no codec could be built
  /// for its format, or its codec header could not be decoded. The stream's
  /// audio is discarded until a usable `stream/start` arrives.
  void Function(Object error)? onStreamError;

  /// Optional factory for creating codecs. If it returns null or is not set,
  /// the built-in [createCodec] is used as a fallback.
  final SendspinCodec? Function(
      String codec, int bitDepth, int channels, int sampleRate)? codecFactory;

  final int bufferSeconds;

  SendspinCodec? _codec;
  SendspinBuffer? _buffer;

  /// The format audio chunks are currently arriving in.
  StreamConfig? _config;

  void Function(int delayMs)? _userOnOutputDelayChanged;

  SendspinPlayer({
    required String playerName,
    required SendspinIdentity identity,
    required int bufferSeconds,
    DeviceInfo deviceInfo = const DeviceInfo(),
    List<AudioFormat> supportedFormats = const [
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 44100, bitDepth: 16),
    ],
    Set<SendspinRole> additionalRoles = const {},
    List<ArtworkChannel>? artworkChannels,
    required bool unpairedAccess,
    SendspinPairing? pairing,
    this.codecFactory,
    Set<SendspinPlayerCommand> supportedCommands = const {
      SendspinPlayerCommand.volume,
      SendspinPlayerCommand.mute,
      SendspinPlayerCommand.setOutputDelay,
    },
    int initialOutputDelayMs = 0,
    int requiredLeadTimeMs = 250,
    int minBufferMs = 250,
    int Function()? now,
  })  : bufferSeconds = bufferSeconds,
        protocol = SendspinProtocol(
          playerName: playerName,
          identity: identity,
          bufferSeconds: bufferSeconds,
          deviceInfo: deviceInfo,
          supportedFormats: supportedFormats,
          roles: {SendspinRole.player, ...additionalRoles},
          artworkChannels: artworkChannels,
          unpairedAccess: unpairedAccess,
          pairing: pairing,
          supportedCommands: supportedCommands,
          initialOutputDelayMs: initialOutputDelayMs,
          requiredLeadTimeMs: requiredLeadTimeMs,
          minBufferMs: minBufferMs,
          now: now,
        ) {
    _wireProtocol();
  }

  // ---------------------------------------------------------------------------
  // Delegated getters / setters
  // ---------------------------------------------------------------------------

  String get clientId => protocol.clientId;

  SendspinPlayerState get state => protocol.state;
  Stream<SendspinPlayerState> get stateStream => protocol.stateStream;

  void Function(String message)? get onSendText => protocol.onSendText;
  set onSendText(void Function(String message)? cb) => protocol.onSendText = cb;

  void Function(Uint8List data)? get onSendBinary => protocol.onSendBinary;
  set onSendBinary(void Function(Uint8List data)? cb) =>
      protocol.onSendBinary = cb;

  void Function(String reason)? get onClose => protocol.onClose;
  set onClose(void Function(String reason)? cb) => protocol.onClose = cb;

  void Function(String reason)? get onServerError => protocol.onServerError;
  set onServerError(void Function(String reason)? cb) =>
      protocol.onServerError = cb;

  void Function(Set<String> activities, List<String> activeRoles)?
      get onActivate => protocol.onActivate;
  set onActivate(
          void Function(Set<String> activities, List<String> activeRoles)?
              cb) =>
      protocol.onActivate = cb;

  bool get unpairedAccess => protocol.unpairedAccess;
  set unpairedAccess(bool enabled) => protocol.unpairedAccess = enabled;

  SendspinPairing get pairing => protocol.pairing;
  String get pairingToken => protocol.pairingToken;
  void cancelPairing() => protocol.cancelPairing();
  void rejectConcurrentPairing() => protocol.rejectConcurrentPairing();

  void Function(String serverId)? get onPaired => protocol.onPaired;
  set onPaired(void Function(String serverId)? cb) => protocol.onPaired = cb;

  void Function(String reason)? get onPairingAborted =>
      protocol.onPairingAborted;
  set onPairingAborted(void Function(String reason)? cb) =>
      protocol.onPairingAborted = cb;

  void Function(Object error)? get onPairingStoreError =>
      protocol.onPairingStoreError;
  set onPairingStoreError(void Function(Object error)? cb) =>
      protocol.onPairingStoreError = cb;

  String? get serverId => protocol.serverId;
  bool get isPaired => protocol.isPaired;

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

  SendspinMetadata? get pendingMetadata => protocol.pendingMetadata;
  int? get currentTrackPositionMs => protocol.currentTrackPositionMs;

  int get outputDelayMs => protocol.outputDelayMs;

  /// Sets the output delay locally and reports it to the server.
  void setOutputDelayMs(int delayMs) {
    protocol.setOutputDelayMs(delayMs);
    _buffer?.outputDelayMs = protocol.outputDelayMs;
  }

  bool get isAvailable => protocol.isAvailable;
  void setAvailable(bool available) => protocol.setAvailable(available);
  void sendLeave() => protocol.sendLeave();

  void setTimingParameters({int? requiredLeadTimeMs, int? minBufferMs}) =>
      protocol.setTimingParameters(
          requiredLeadTimeMs: requiredLeadTimeMs, minBufferMs: minBufferMs);

  void setSupportedCommands(Set<SendspinPlayerCommand> commands) =>
      protocol.setSupportedCommands(commands);

  AudioFormat? get preferredFormat => protocol.preferredFormat;
  set preferredFormat(AudioFormat? format) => protocol.preferredFormat = format;

  void Function(int delayMs)? get onOutputDelayChanged =>
      _userOnOutputDelayChanged;
  set onOutputDelayChanged(void Function(int delayMs)? cb) =>
      _userOnOutputDelayChanged = cb;

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

  /// Begins the connection by sending `client/init`.
  void start() => protocol.start();

  void handleTextMessage(String text) => protocol.handleTextMessage(text);
  void handleBinaryMessage(Uint8List data) =>
      protocol.handleBinaryMessage(data);

  void updateVolume(double volume) => protocol.updateVolume(volume);
  void updateMuted(bool muted) => protocol.updateMuted(muted);

  void startClockSync() => protocol.startClockSync();
  void stopClockSync() => protocol.stopClockSync();

  static AudioFrame parseBinaryFrame(Uint8List frame) =>
      SendspinProtocol.parseBinaryFrame(frame);

  // ---------------------------------------------------------------------------
  // Own methods
  // ---------------------------------------------------------------------------

  /// The local clock [pullSamples] is given times in, in microseconds.
  int nowUs() => protocol.nowUs();

  /// Returns [count] interleaved 16-bit samples for the audio callback.
  ///
  /// [outputTimeUs] is the local time, on the [nowUs] clock, at which the
  /// first of these samples will leave the device's audio port: now plus
  /// whatever the audio backend and DAC add (queued buffers, device latency).
  /// The buffer returns exactly the audio that is due then, so that delay is
  /// compensated here and must not be included in the output delay.
  ///
  /// The value does not need to be smooth from call to call: it is followed
  /// by a loop that rejects callback scheduling noise and tracks the output
  /// device's actual rate. It does need to be unbiased, so pass the best
  /// estimate available (for ALSA, `nowUs()` plus `snd_pcm_delay` converted
  /// to time).
  ///
  /// Returns silence when not streaming, before the clock is synchronized,
  /// and for any part of the request no audio is due for.
  Int16List pullSamples(int count, {required int outputTimeUs}) {
    final buffer = _buffer;
    if (buffer == null || !protocol.clock.isSynchronized) {
      return Int16List(count);
    }
    final samples = buffer.pullSamples(count, outputTimeUs);
    if (buffer.bufferDepthMs != protocol.state.bufferDepthMs) {
      protocol.updatePipelineState(
          protocol.state.copyWith(bufferDepthMs: buffer.bufferDepthMs));
    }
    return samples;
  }

  /// The last measured playback error in microseconds: positive when audio
  /// was running late against its schedule, negative when early.
  int get syncErrorUs => _buffer?.syncErrorUs ?? 0;

  /// Frames removed and duplicated by steady-state drift correction, one-shot
  /// resynchronizations (the initial alignment included) and chunks dropped
  /// for arriving late, all for the current stream.
  int get framesDropped => _buffer?.framesDropped ?? 0;
  int get framesInserted => _buffer?.framesInserted ?? 0;
  int get resyncCount => _buffer?.resyncCount ?? 0;
  int get lateChunksDropped => _buffer?.lateChunksDropped ?? 0;

  /// Resets for a new WebSocket connection: clears codec, buffer, and protocol
  /// timers.
  void resetForNewConnection() {
    protocol.resetForNewConnection();
    _codec?.dispose();
    _codec = null;
    _buffer?.flush();
    _buffer = null;
    _config = null;
  }

  /// Cleans up codec and protocol resources.
  void dispose() {
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
    protocol.onOutputDelayChanged = (delayMs) {
      _buffer?.outputDelayMs = delayMs;
      _userOnOutputDelayChanged?.call(delayMs);
    };
  }

  void _handleStreamConfig(StreamConfig config) {
    // Chunks are decoded as they arrive, so swapping the codec here means
    // each chunk is decoded in the format that was in effect when it was
    // received. What is already buffered stays as it is.
    _codec?.dispose();
    _codec = null;

    // Try custom factory first, then fall back to built-in. The format
    // comes from the server, so failing to build a codec for it is reported
    // rather than thrown out of the message handler.
    try {
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
      // If codec header is present, push it through the codec (e.g. FLAC
      // STREAMINFO).
      if (config.codecHeader != null) {
        _codec!.decode(_base64Decode(config.codecHeader!));
      }
    } catch (error) {
      _codec?.dispose();
      _codec = null;
      onStreamError?.call(error);
      return;
    }

    final updatesRunningStream = _buffer != null;
    _config = config;
    if (updatesRunningStream) {
      // A configuration update on an active stream continues the timeline.
      // The buffer reports the change when playback reaches the new audio.
      return;
    }

    _buffer = SendspinBuffer(
      serverToLocalUs: protocol.clock.computeClientTime,
      // Room for the advertised capacity plus what a reduced output delay
      // can leave buffered beyond it.
      maxBufferMs: bufferSeconds * 1000 + 5000,
    )
      ..outputDelayMs = protocol.outputDelayMs
      ..setOutputFormat(
          sampleRate: config.sampleRate, channels: config.channels)
      ..onFormatChange = (sampleRate, channels) {
        onStreamStart?.call(sampleRate, channels, _config?.bitDepth ?? 16);
      };

    onStreamStart?.call(config.sampleRate, config.channels, config.bitDepth);
  }

  void _handleAudioFrame(AudioFrame frame) {
    final config = _config;
    if (_codec == null || _buffer == null || config == null) return;
    final samples = _codec!.decode(frame.audioData);
    // The buffer keeps the server timestamp and translates it through the
    // time filter when the audio is pulled, so scheduling always uses the
    // filter's latest estimate.
    _buffer!.addChunk(
      frame.timestampUs,
      samples,
      sampleRate: config.sampleRate,
      channels: config.channels,
    );
    protocol.updatePipelineState(
        protocol.state.copyWith(bufferDepthMs: _buffer!.bufferDepthMs));
  }

  void _handleStreamClear() {
    _buffer?.flush();
    _codec?.reset();
    protocol.updatePipelineState(protocol.state.copyWith(bufferDepthMs: 0));
  }

  void _handleStreamEnd() {
    onStreamStop?.call();
    _buffer?.flush();
    _codec?.dispose();
    _codec = null;
    _buffer = null;
    _config = null;
    protocol.updatePipelineState(protocol.state.copyWith(bufferDepthMs: 0));
  }

  /// Decodes a base64 string to bytes.
  static Uint8List _base64Decode(String encoded) {
    return base64.decode(encoded);
  }
}
