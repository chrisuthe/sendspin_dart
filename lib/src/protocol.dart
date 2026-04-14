import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';
import 'clock.dart';

/// Reason codes for the client/goodbye message (Sendspin spec).
enum SendspinGoodbyeReason {
  anotherServer('another_server'),
  shutdown('shutdown'),
  restart('restart'),
  userRequest('user_request');

  final String wireValue;
  const SendspinGoodbyeReason(this.wireValue);
}

/// Binary frame type IDs per Sendspin spec. Player frames are type 4
/// (bits 000001_xx). Artwork is 8-11, visualizer is 16-23.
const int _binaryTypePlayerMin = 4;
const int _binaryTypePlayerMax = 7;

/// A parsed binary audio frame from the Sendspin protocol.
class AudioFrame {
  final int type;
  final int timestampUs;
  final Uint8List audioData;

  const AudioFrame({
    required this.type,
    required this.timestampUs,
    required this.audioData,
  });
}

/// Device info sent in the client/hello handshake.
class DeviceInfo {
  final String productName;
  final String manufacturer;
  final String softwareVersion;

  const DeviceInfo({
    this.productName = 'sendspin_dart',
    this.manufacturer = 'sendspin_dart',
    this.softwareVersion = '0.1.0',
  });
}

/// Audio format description for supported codec negotiation.
class AudioFormat {
  final String codec;
  final int channels;
  final int sampleRate;
  final int bitDepth;

  const AudioFormat({
    required this.codec,
    required this.channels,
    required this.sampleRate,
    required this.bitDepth,
  });

  Map<String, dynamic> toJson() => {
        'codec': codec,
        'channels': channels,
        'sample_rate': sampleRate,
        'bit_depth': bitDepth,
      };
}

/// Sendspin protocol state machine.
///
/// Handles all text message parsing/building, binary frame parsing, clock sync,
/// connection state management, volume/mute commands, and periodic state
/// reporting. Does NOT create codecs, buffer audio, decode audio, or provide
/// pullSamples() — those concerns belong to the player layer.
class SendspinProtocol {
  final String playerName;
  final String clientId;
  final int bufferSeconds;
  final DeviceInfo deviceInfo;
  final List<AudioFormat> supportedFormats;

  final SendspinClock _clock = SendspinClock();

  int _staticDelayMs = 0;
  bool _pipelineError = false;

  SendspinPlayerState _state = const SendspinPlayerState();
  final StreamController<SendspinPlayerState> _stateController =
      StreamController<SendspinPlayerState>.broadcast();

  Timer? _clockSyncTimer;
  Timer? _stateReportTimer;

  // -------------------------------------------------------------------------
  // Callbacks
  // -------------------------------------------------------------------------

  /// Callback for sending text messages back through the WebSocket.
  void Function(String message)? onSendText;

  /// Called when stream/start is received with the negotiated audio format.
  void Function(StreamConfig config)? onStreamConfig;

  /// Called when stream/clear is received.
  void Function()? onStreamClear;

  /// Called when stream/end is received.
  void Function()? onStreamEnd;

  /// Called when a binary audio frame is received.
  void Function(AudioFrame frame)? onAudioFrame;

  /// Called when the server changes volume or mute via server/command.
  void Function(double volume, bool muted)? onVolumeChanged;

  /// Called when the server updates the static delay via server/command.
  void Function(int delayMs)? onStaticDelayChanged;

  /// Called when a group/update message arrives. The argument is the
  /// merged state after applying the delta.
  void Function(SendspinGroupState groupState)? onGroupUpdate;

  /// Called when a server/state message updates the metadata sub-object.
  /// The argument is the full new snapshot.
  void Function(SendspinMetadata metadata)? onMetadataUpdate;

  /// Called when a server/state message updates the controller sub-object.
  /// The argument is the full new snapshot.
  void Function(SendspinControllerInfo controller)? onControllerUpdate;

  SendspinProtocol({
    required this.playerName,
    required this.clientId,
    required this.bufferSeconds,
    this.deviceInfo = const DeviceInfo(),
    this.supportedFormats = const [
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 44100, bitDepth: 16),
    ],
    int initialStaticDelayMs = 0,
  }) {
    _staticDelayMs = initialStaticDelayMs.clamp(0, 5000);
    _state = _state.copyWith(staticDelayMs: _staticDelayMs);
  }

  // -------------------------------------------------------------------------
  // Public getters
  // -------------------------------------------------------------------------

  /// The clock filter, exposed for consumers that need time conversion.
  SendspinClock get clock => _clock;

  /// Current player state.
  SendspinPlayerState get state => _state;

  /// Stream of state changes.
  Stream<SendspinPlayerState> get stateStream => _stateController.stream;

  /// Current static delay in milliseconds (set by server/command).
  int get staticDelayMs => _staticDelayMs;

  // -------------------------------------------------------------------------
  // State management
  // -------------------------------------------------------------------------

  void _updateState(SendspinPlayerState newState) {
    _state = newState;
    _stateController.add(newState);
  }

  /// Called by the player layer to update state (e.g. buffer depth).
  void updatePipelineState(SendspinPlayerState newState) {
    _updateState(newState);
  }

  // -------------------------------------------------------------------------
  // Message builders
  // -------------------------------------------------------------------------

  /// Builds the client/hello handshake message per the Sendspin spec.
  String buildClientHello() {
    return jsonEncode({
      'type': 'client/hello',
      'payload': {
        'client_id': clientId,
        'name': playerName,
        'version': 1,
        'supported_roles': ['player@v1'],
        'device_info': {
          'product_name': deviceInfo.productName,
          'manufacturer': deviceInfo.manufacturer,
          'software_version': deviceInfo.softwareVersion,
        },
        'player@v1_support': {
          'supported_formats': supportedFormats.map((f) => f.toJson()).toList(),
          'buffer_capacity': _computeBufferCapacityBytes(),
          'supported_commands': ['volume', 'mute'],
        },
      },
    });
  }

  int _computeBufferCapacityBytes() {
    if (supportedFormats.isEmpty) return bufferSeconds * 48000 * 2 * 2;
    int maxBps = 0;
    for (final f in supportedFormats) {
      final bytesPerSample = (f.bitDepth + 7) ~/ 8;
      final bps = f.channels * f.sampleRate * bytesPerSample;
      if (bps > maxBps) maxBps = bps;
    }
    return bufferSeconds * maxBps;
  }

  /// Builds a client/time message for clock synchronization.
  String buildClientTime(int clientTransmittedUs) {
    return jsonEncode({
      'type': 'client/time',
      'payload': {
        'client_transmitted': clientTransmittedUs,
      },
    });
  }

  /// Builds a client/state report.
  String buildClientState() {
    return jsonEncode({
      'type': 'client/state',
      'payload': {
        'state': _pipelineError ? 'error' : 'synchronized',
        'player': {
          'volume': (_state.volume * 100).round(),
          'muted': _state.muted,
          'static_delay_ms': _staticDelayMs,
          'supported_commands': ['set_static_delay'],
        },
      },
    });
  }

  /// Builds a client/goodbye message with the given reason.
  String buildClientGoodbye(SendspinGoodbyeReason reason) {
    return jsonEncode({
      'type': 'client/goodbye',
      'payload': {
        'reason': reason.wireValue,
      },
    });
  }

  /// Sends a client/goodbye message via [onSendText].
  ///
  /// The consumer remains responsible for closing the underlying transport
  /// after this returns.
  void sendGoodbye(SendspinGoodbyeReason reason) {
    onSendText?.call(buildClientGoodbye(reason));
  }

  /// Sets the pipeline error flag and immediately reports state if changed.
  ///
  /// Per spec, clients mute output on `state: 'error'` and resume on
  /// `state: 'synchronized'` once sync is restored.
  void setPipelineError(bool error) {
    if (_pipelineError == error) return;
    _pipelineError = error;
    onSendText?.call(buildClientState());
  }

  /// Update volume from local UI and report to server.
  void updateVolume(double volume) {
    _updateState(_state.copyWith(volume: volume.clamp(0.0, 1.0)));
    onSendText?.call(buildClientState());
  }

  // -------------------------------------------------------------------------
  // Text message handling
  // -------------------------------------------------------------------------

  /// Dispatches an incoming JSON text message by its `type` field.
  void handleTextMessage(String text) {
    final Map<String, dynamic> msg;
    try {
      msg = jsonDecode(text) as Map<String, dynamic>;
    } catch (e) {
      return;
    }

    final type = msg['type'] as String?;
    final payload = msg['payload'] as Map<String, dynamic>? ?? {};

    switch (type) {
      case 'server/hello':
        _handleServerHello(payload);
      case 'server/time':
        _handleServerTime(payload);
      case 'stream/start':
        _handleStreamStart(payload);
      case 'stream/clear':
        _handleStreamClear();
      case 'stream/end':
        _handleStreamEnd();
      case 'server/command':
        _handleServerCommand(payload);
      case 'server/state':
        _handleServerState(payload);
      case 'group/update':
        _handleGroupUpdate(payload);
    }
  }

  void _handleGroupUpdate(Map<String, dynamic> payload) {
    SendspinGroupPlaybackState? newPlaybackState;
    if (payload.containsKey('playback_state')) {
      newPlaybackState = SendspinGroupPlaybackState.fromWire(
          payload['playback_state'] as String?);
    }

    final delta = SendspinGroupState(
      playbackState: newPlaybackState,
      groupId: payload.containsKey('group_id')
          ? payload['group_id'] as String?
          : null,
      groupName: payload.containsKey('group_name')
          ? payload['group_name'] as String?
          : null,
    );

    final merged = _state.groupState.mergeDelta(delta);
    _updateState(_state.copyWith(groupState: merged));
    onGroupUpdate?.call(merged);
  }

  void _handleServerHello(Map<String, dynamic> payload) {
    final serverName = payload['name'] as String? ?? 'Unknown';
    final connectionReason = SendspinConnectionReason.fromWire(
        payload['connection_reason'] as String?);
    final activeRoles =
        (payload['active_roles'] as List?)?.whereType<String>().toList() ??
            const <String>[];

    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.syncing,
      serverName: serverName,
      connectionReason: connectionReason,
      activeRoles: activeRoles,
    ));

    // Send initial state report, then start clock sync.
    onSendText?.call(buildClientState());
    startClockSync();
  }

  void _handleServerTime(Map<String, dynamic> payload) {
    final serverReceived = payload['server_received'] as int? ?? 0;
    final serverTransmitted = payload['server_transmitted'] as int? ?? 0;
    final clientReceived = DateTime.now().microsecondsSinceEpoch;
    final clientTransmitted = payload['client_transmitted'] as int? ?? 0;

    // NTP-style offset calculation.
    final offset = ((serverReceived - clientTransmitted) +
            (serverTransmitted - clientReceived)) ~/
        2;
    final delay = (clientReceived - clientTransmitted) -
        (serverTransmitted - serverReceived);

    _clock.update(offset, delay ~/ 2, clientReceived);

    _updateState(_state.copyWith(
      clockOffsetMs: (_clock.precisionUs / 1000).round(),
      clockSamples: _clock.sampleCount,
    ));
  }

  void _handleStreamStart(Map<String, dynamic> payload) {
    // Spec nests format under "player"; fall back to top-level for compat.
    final playerFormat = payload['player'] as Map<String, dynamic>?;
    final audioFormat =
        playerFormat ?? payload['audio_format'] as Map<String, dynamic>? ?? {};
    final codecName = audioFormat['codec'] as String? ?? 'pcm';
    final channels = audioFormat['channels'] as int? ?? 2;
    final sampleRate = audioFormat['sample_rate'] as int? ?? 48000;
    final bitDepth = audioFormat['bit_depth'] as int? ?? 16;
    final codecHeader = audioFormat['codec_header'] as String?;

    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.streaming,
      codec: codecName,
      sampleRate: sampleRate,
      channels: channels,
    ));

    _startStateReporting();

    onStreamConfig?.call(StreamConfig(
      codec: codecName,
      channels: channels,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      codecHeader:
          (codecHeader != null && codecHeader.isNotEmpty) ? codecHeader : null,
    ));
  }

  void _handleStreamClear() {
    onStreamClear?.call();
  }

  void _handleStreamEnd() {
    _stopStateReporting();

    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.syncing,
    ));

    onStreamEnd?.call();
  }

  void _handleServerCommand(Map<String, dynamic> payload) {
    final player = payload['player'] as Map<String, dynamic>?;
    if (player == null) return;

    final command = player['command'] as String?;
    switch (command) {
      case 'volume':
        final vol = player['volume'];
        if (vol is num) {
          final normalized = vol.toDouble() / 100;
          _updateState(_state.copyWith(volume: normalized));
          onSendText?.call(buildClientState());
          onVolumeChanged?.call(normalized, _state.muted);
        }
      case 'mute':
        final muted = player['mute'] as bool?;
        if (muted != null) {
          _updateState(_state.copyWith(muted: muted));
          onSendText?.call(buildClientState());
          onVolumeChanged?.call(_state.volume, muted);
        }
      case 'set_static_delay':
        final delayMs = player['static_delay_ms'] as int?;
        if (delayMs != null) {
          _staticDelayMs = delayMs.clamp(0, 5000);
          _updateState(_state.copyWith(staticDelayMs: _staticDelayMs));
          onSendText?.call(buildClientState());
          onStaticDelayChanged?.call(_staticDelayMs);
        }
    }
  }

  void _handleServerState(Map<String, dynamic> payload) {
    final metadata =
        _parseMetadata(payload['metadata'] as Map<String, dynamic>?);
    final controller =
        _parseController(payload['controller'] as Map<String, dynamic>?);

    if (metadata == null && controller == null) return;

    // Per-message full-snapshot replacement: the spec doesn't mark
    // server/state as delta-encoded, and Music Assistant sends complete
    // sub-objects, so we replace wholesale rather than field-merging.
    var newState = _state;
    if (metadata != null) newState = newState.copyWith(metadata: metadata);
    if (controller != null) {
      newState = newState.copyWith(controller: controller);
    }
    _updateState(newState);

    if (metadata != null) onMetadataUpdate?.call(metadata);
    if (controller != null) onControllerUpdate?.call(controller);
  }

  SendspinMetadata? _parseMetadata(Map<String, dynamic>? json) {
    if (json == null) return null;
    final progressJson = json['progress'] as Map<String, dynamic>?;
    SendspinMetadataProgress? progress;
    if (progressJson != null) {
      progress = SendspinMetadataProgress(
        trackProgress: (progressJson['track_progress'] as num?)?.toInt() ?? 0,
        trackDuration: (progressJson['track_duration'] as num?)?.toInt() ?? 0,
        playbackSpeed:
            (progressJson['playback_speed'] as num?)?.toInt() ?? 1000,
      );
    }
    return SendspinMetadata(
      timestamp: (json['timestamp'] as num?)?.toInt() ?? 0,
      title: json['title'] as String?,
      artist: json['artist'] as String?,
      albumArtist: json['album_artist'] as String?,
      album: json['album'] as String?,
      artworkUrl: json['artwork_url'] as String?,
      year: (json['year'] as num?)?.toInt(),
      track: (json['track'] as num?)?.toInt(),
      progress: progress,
      repeat: SendspinRepeatMode.fromWire(json['repeat'] as String?),
      shuffle: json['shuffle'] as bool?,
    );
  }

  SendspinControllerInfo? _parseController(Map<String, dynamic>? json) {
    if (json == null) return null;
    final rawCommands = json['supported_commands'] as List?;
    return SendspinControllerInfo(
      supportedCommands:
          rawCommands?.whereType<String>().toList() ?? const <String>[],
      volume: (json['volume'] as num?)?.toInt() ?? 0,
      muted: json['muted'] as bool? ?? false,
    );
  }

  // -------------------------------------------------------------------------
  // Binary message handling
  // -------------------------------------------------------------------------

  /// Handles an incoming binary audio frame.
  ///
  /// Parses the frame and emits it via [onAudioFrame] only if the frame is
  /// a player-range type (4-7). Non-player frames (artwork, visualizer) are
  /// silently dropped. Does not decode or buffer — that is the player layer's
  /// responsibility.
  void handleBinaryMessage(Uint8List data) {
    if (data.length < 9) {
      return;
    }
    final frame = parseBinaryFrame(data);
    if (frame.type < _binaryTypePlayerMin ||
        frame.type > _binaryTypePlayerMax) {
      return;
    }
    onAudioFrame?.call(frame);
  }

  /// Parses a binary frame: byte 0 = message type, bytes 1-8 = BE int64
  /// timestamp, bytes 9+ = audio data.
  static AudioFrame parseBinaryFrame(Uint8List frame) {
    final view =
        ByteData.view(frame.buffer, frame.offsetInBytes, frame.lengthInBytes);
    final type = view.getUint8(0);
    final timestampUs = view.getInt64(1, Endian.big);
    final audioData = Uint8List.sublistView(frame, 9);
    return AudioFrame(
        type: type, timestampUs: timestampUs, audioData: audioData);
  }

  // -------------------------------------------------------------------------
  // Clock sync
  // -------------------------------------------------------------------------

  /// Starts periodic clock synchronization (every 2 seconds, burst of 5).
  void startClockSync() {
    stopClockSync();
    _clockSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _sendTimeBurst();
    });
  }

  void _sendTimeBurst() {
    for (int i = 0; i < 5; i++) {
      Future.delayed(Duration(milliseconds: i * 20), () {
        if (_clockSyncTimer == null) return; // cancelled
        final clientTransmittedUs = DateTime.now().microsecondsSinceEpoch;
        onSendText?.call(buildClientTime(clientTransmittedUs));
      });
    }
  }

  /// Stops clock synchronization.
  void stopClockSync() {
    _clockSyncTimer?.cancel();
    _clockSyncTimer = null;
  }

  // -------------------------------------------------------------------------
  // Periodic state reporting
  // -------------------------------------------------------------------------

  void _startStateReporting() {
    _stopStateReporting();
    _stateReportTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      onSendText?.call(buildClientState());
    });
  }

  void _stopStateReporting() {
    _stateReportTimer?.cancel();
    _stateReportTimer = null;
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Resets the protocol for a new connection.
  ///
  /// Stops all periodic timers and resets the clock so nothing is sent
  /// on the new socket before the server/hello handshake completes.
  void resetForNewConnection() {
    stopClockSync();
    _stopStateReporting();
    _clock.reset();
  }

  /// Cleans up timers and stream controller.
  void dispose() {
    stopClockSync();
    _stopStateReporting();
    _stateController.close();
  }
}
