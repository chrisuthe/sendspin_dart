/// Reason a Sendspin server initiated (or accepted) a connection.
/// Used to prioritize between multiple servers during discovery.
enum SendspinConnectionReason {
  discovery('discovery'),
  playback('playback'),
  unknown('unknown');

  final String wireValue;
  const SendspinConnectionReason(this.wireValue);

  static SendspinConnectionReason fromWire(String? value) {
    for (final r in SendspinConnectionReason.values) {
      if (r.wireValue == value) return r;
    }
    return SendspinConnectionReason.unknown;
  }
}

/// Group playback state reported via group/update.
enum SendspinGroupPlaybackState {
  playing('playing'),
  stopped('stopped'),
  unknown('unknown');

  final String wireValue;
  const SendspinGroupPlaybackState(this.wireValue);

  static SendspinGroupPlaybackState fromWire(String? value) {
    for (final s in SendspinGroupPlaybackState.values) {
      if (s.wireValue == value) return s;
    }
    return SendspinGroupPlaybackState.unknown;
  }
}

/// Group state reported by the server via group/update messages.
///
/// All fields are nullable because the message is delta-encoded: the
/// server only sends fields that have changed. Consumers merge incoming
/// deltas with their existing view via [mergeDelta].
class SendspinGroupState {
  final SendspinGroupPlaybackState? playbackState;
  final String? groupId;
  final String? groupName;

  const SendspinGroupState({
    this.playbackState,
    this.groupId,
    this.groupName,
  });

  /// Returns a new state with any non-null fields from [delta] applied
  /// on top of this state.
  SendspinGroupState mergeDelta(SendspinGroupState delta) {
    return SendspinGroupState(
      playbackState: delta.playbackState ?? playbackState,
      groupId: delta.groupId ?? groupId,
      groupName: delta.groupName ?? groupName,
    );
  }
}

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
  final SendspinConnectionReason connectionReason;
  final List<String> activeRoles;
  final SendspinGroupState groupState;

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
    this.connectionReason = SendspinConnectionReason.unknown,
    this.activeRoles = const <String>[],
    this.groupState = const SendspinGroupState(),
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
    SendspinConnectionReason? connectionReason,
    List<String>? activeRoles,
    SendspinGroupState? groupState,
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
      connectionReason: connectionReason ?? this.connectionReason,
      activeRoles: activeRoles ?? this.activeRoles,
      groupState: groupState ?? this.groupState,
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
