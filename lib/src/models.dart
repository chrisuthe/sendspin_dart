// ABOUTME: Data models for the Sendspin streaming-audio protocol.
import 'dart:typed_data';

import 'json_util.dart';

/// Client roles defined by the Sendspin protocol.
enum SendspinRole {
  player('player@v1'),
  controller('controller@v1'),
  metadata('metadata@v1'),
  artwork('artwork@v1');

  final String wireValue;
  const SendspinRole(this.wireValue);
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
/// Every `group/update` carries all three fields, so each message replaces
/// the previous state. The fields are nullable only because no state exists
/// before the first message arrives.
class SendspinGroupState {
  final SendspinGroupPlaybackState? playbackState;
  final String? groupId;
  final String? groupName;

  const SendspinGroupState({
    this.playbackState,
    this.groupId,
    this.groupName,
  });
}

/// Repeat mode reported in the controller state.
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
/// Every `metadata` object carries the full state: a field the server omits
/// is absent, not unchanged. In particular an omitted [progress] means there
/// is no position to report.
class SendspinMetadata {
  /// Server-clock microsecond timestamp at which this metadata takes effect,
  /// and the point progress extrapolation runs from. 0 if the server omitted
  /// it.
  final int timestamp;
  final String? title;
  final String? artist;
  final String? albumArtist;
  final String? album;
  final String? artworkUrl;
  final int? year;
  final int? track;
  final SendspinMetadataProgress? progress;

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
  });

  /// Parses the `metadata` object of a server/state message.
  factory SendspinMetadata.fromJson(Map<String, dynamic> json) {
    return SendspinMetadata(
      timestamp: jsonInt(json['timestamp']) ?? 0,
      title: jsonString(json['title']),
      artist: jsonString(json['artist']),
      albumArtist: jsonString(json['album_artist']),
      album: jsonString(json['album']),
      artworkUrl: jsonString(json['artwork_url']),
      year: jsonInt(json['year']),
      track: jsonInt(json['track']),
      progress: _parseProgress(jsonObject(json['progress'])),
    );
  }

  static SendspinMetadataProgress? _parseProgress(Map<String, dynamic>? json) {
    if (json == null) return null;
    return SendspinMetadataProgress(
      trackProgress: jsonInt(json['track_progress']) ?? 0,
      trackDuration: jsonInt(json['track_duration']) ?? 0,
      playbackSpeed: jsonInt(json['playback_speed']) ?? 1000,
    );
  }
}

/// Controller state reported via server/state: what this client may ask
/// the server to do, and the group's volume, mute, repeat and shuffle.
class SendspinControllerInfo {
  /// Commands the server currently accepts. A command not listed here must
  /// not be sent.
  final List<String> supportedCommands;

  /// Volume of the whole group, 0-100.
  final int volume;

  /// Mute state of the whole group.
  final bool muted;
  final SendspinRepeatMode repeat;
  final bool shuffle;

  /// The furthest position a `seek` may target, in milliseconds. Present
  /// whenever `seek` is supported; absent when the range is unknown.
  final int? seekMaxMs;

  const SendspinControllerInfo({
    this.supportedCommands = const <String>[],
    this.volume = 0,
    this.muted = false,
    this.repeat = SendspinRepeatMode.unknown,
    this.shuffle = false,
    this.seekMaxMs,
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
  final int outputDelayMs;

  /// The connected server's `server_id` (its static public key), once the
  /// handshake has completed.
  final String? serverId;

  /// The purposes the server currently declares on this connection
  /// (`playback`, `pairing`), from the latest `server/activate`.
  final Set<String> activities;

  /// Versioned roles the server has activated, e.g. `player@v1`.
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
    this.outputDelayMs = 0,
    this.serverId,
    this.activities = const <String>{},
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
    int? outputDelayMs,
    String? serverId,
    Set<String>? activities,
    List<String>? activeRoles,
    SendspinGroupState? groupState,
    SendspinMetadata? metadata,
    bool clearMetadata = false,
    SendspinControllerInfo? controller,
    bool clearController = false,
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
      outputDelayMs: outputDelayMs ?? this.outputDelayMs,
      serverId: serverId ?? this.serverId,
      activities: activities ?? this.activities,
      activeRoles: activeRoles ?? this.activeRoles,
      groupState: groupState ?? this.groupState,
      metadata: clearMetadata ? null : metadata ?? this.metadata,
      controller: clearController ? null : controller ?? this.controller,
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

  /// The channel's entry in the `artwork` object of `client/state`. A
  /// channel whose source is `none` carries no format or size.
  Map<String, dynamic> toJson() => {
        'source': source,
        if (source != 'none') ...{
          'format': format,
          'width': mediaWidth,
          'height': mediaHeight,
        },
      };
}

/// A parsed binary artwork frame from the Sendspin protocol.
///
/// Artwork uses binary message types 8-11, mapping to channels 0-3.
class ArtworkFrame {
  final int channel;

  /// Server-clock time the image was scheduled for; 0 for a channel cleared
  /// by the end of the artwork stream.
  final int timestampUs;

  /// The complete encoded image, or empty when the channel was cleared.
  final Uint8List imageData;

  const ArtworkFrame({
    required this.channel,
    required this.timestampUs,
    required this.imageData,
  });
}
