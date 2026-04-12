/// Connection states for the Sendspin player lifecycle.
enum SendspinConnectionState {
  disabled,
  advertising,
  connected,
  syncing,
  streaming,
  disconnected,
}

/// Observable state of the Sendspin player.
class SendspinPlayerState {
  final SendspinConnectionState connectionState;
  final double volume;
  final bool muted;
  final int? sampleRate;
  final int? channels;
  final String? codec;
  final String? serverName;
  final int bufferDepthMs;
  final int clockOffsetMs;
  final int clockSamples;
  final int staticDelayMs;

  const SendspinPlayerState({
    this.connectionState = SendspinConnectionState.disabled,
    this.volume = 1.0,
    this.muted = false,
    this.sampleRate,
    this.channels,
    this.codec,
    this.serverName,
    this.bufferDepthMs = 0,
    this.clockOffsetMs = 0,
    this.clockSamples = 0,
    this.staticDelayMs = 0,
  });

  bool get isActive =>
      connectionState == SendspinConnectionState.connected ||
      connectionState == SendspinConnectionState.syncing ||
      connectionState == SendspinConnectionState.streaming;

  SendspinPlayerState copyWith({
    SendspinConnectionState? connectionState,
    double? volume,
    bool? muted,
    int? sampleRate,
    int? channels,
    String? codec,
    String? serverName,
    int? bufferDepthMs,
    int? clockOffsetMs,
    int? clockSamples,
    int? staticDelayMs,
  }) {
    return SendspinPlayerState(
      connectionState: connectionState ?? this.connectionState,
      volume: volume ?? this.volume,
      muted: muted ?? this.muted,
      sampleRate: sampleRate ?? this.sampleRate,
      channels: channels ?? this.channels,
      codec: codec ?? this.codec,
      serverName: serverName ?? this.serverName,
      bufferDepthMs: bufferDepthMs ?? this.bufferDepthMs,
      clockOffsetMs: clockOffsetMs ?? this.clockOffsetMs,
      clockSamples: clockSamples ?? this.clockSamples,
      staticDelayMs: staticDelayMs ?? this.staticDelayMs,
    );
  }
}

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
