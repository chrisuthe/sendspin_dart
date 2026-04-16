// ABOUTME: Data models for the Sendspin streaming-audio protocol.
import 'dart:typed_data';

/// Client roles defined by the Sendspin protocol.
enum SendspinRole {
  player('player@v1'),
  controller('controller@v1'),
  metadata('metadata@v1'),
  artwork('artwork@v1');

  final String wireValue;
  const SendspinRole(this.wireValue);
}

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

/// Repeat mode reported in server/state metadata.
enum SendspinRepeatMode {
  off('off'),
  one('one'),
  all('all'),
  unknown('unknown');

  final String wireValue;
  const SendspinRepeatMode(this.wireValue);

  static SendspinRepeatMode fromWire(String? value) {
    if (value == null) return SendspinRepeatMode.unknown;
    for (final r in SendspinRepeatMode.values) {
      if (r.wireValue == value) return r;
    }
    return SendspinRepeatMode.unknown;
  }
}

/// Playback progress sub-object inside metadata.
///
/// Used to compute the current track position via the spec formula:
///   progress = track_progress + (now - timestamp) * playback_speed / 1_000_000
class SendspinMetadataProgress {
  /// Current track progress in milliseconds at the moment the enclosing
  /// metadata [SendspinMetadata.timestamp] was captured.
  final int trackProgress;

  /// Total track duration in milliseconds; 0 means unlimited (e.g. live stream).
  final int trackDuration;

  /// Playback speed multiplied by 1000 (1000 = 1.0x, 1500 = 1.5x, 0 = paused).
  final int playbackSpeed;

  const SendspinMetadataProgress({
    required this.trackProgress,
    required this.trackDuration,
    required this.playbackSpeed,
  });
}

/// Now-playing metadata reported via server/state.
///
/// All fields are optional. When the server sends a server/state with a
/// metadata object, this replaces the previous snapshot in full — any
/// field not present in the new message is treated as cleared.
class SendspinMetadata {
  /// Server-clock microsecond timestamp at which this metadata (and any
  /// embedded progress) becomes valid. May be 0 if the server omitted it.
  final int timestamp;
  final String? title;
  final String? artist;
  final String? albumArtist;
  final String? album;
  final String? artworkUrl;
  final int? year;
  final int? track;
  final SendspinMetadataProgress? progress;
  final SendspinRepeatMode repeat;
  final bool? shuffle;

  const SendspinMetadata({
    this.timestamp = 0,
    this.title,
    this.artist,
    this.albumArtist,
    this.album,
    this.artworkUrl,
    this.year,
    this.track,
    this.progress,
    this.repeat = SendspinRepeatMode.unknown,
    this.shuffle,
  });
}

/// Controller capabilities reported via server/state. Describes what
/// commands this client may issue if it is acting as a controller, along
/// with the current group volume/mute.
class SendspinControllerInfo {
  final List<String> supportedCommands;
  final int volume;
  final bool muted;

  const SendspinControllerInfo({
    this.supportedCommands = const <String>[],
    this.volume = 0,
    this.muted = false,
  });
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
  final SendspinMetadata? metadata;
  final SendspinControllerInfo? controller;

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
    this.metadata,
    this.controller,
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
    SendspinMetadata? metadata,
    SendspinControllerInfo? controller,
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
      metadata: metadata ?? this.metadata,
      controller: controller ?? this.controller,
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

/// Artwork channel configuration for the artwork@v1 role.
///
/// Each channel requests a specific image source, format, and resolution.
/// Up to 4 channels may be configured (mapping to binary frame types 8-11).
class ArtworkChannel {
  final String source;
  final String format;
  final int mediaWidth;
  final int mediaHeight;

  const ArtworkChannel({
    required this.source,
    required this.format,
    required this.mediaWidth,
    required this.mediaHeight,
  });

  Map<String, dynamic> toJson() => {
        'source': source,
        'format': format,
        'media_width': mediaWidth,
        'media_height': mediaHeight,
      };
}

/// A parsed binary artwork frame from the Sendspin protocol.
///
/// Artwork frames use binary message types 8-11, mapping to channels 0-3.
class ArtworkFrame {
  final int channel;
  final int timestampUs;
  final Uint8List imageData;

  const ArtworkFrame({
    required this.channel,
    required this.timestampUs,
    required this.imageData,
  });
}
