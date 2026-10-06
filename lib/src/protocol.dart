import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'arrival_delay.dart';
import 'identity.dart';
import 'models.dart';
import 'clock.dart';
import 'time_burst.dart';

/// Reason codes for the client/goodbye message (Sendspin spec).
enum SendspinGoodbyeReason {
  anotherServer('another_server'),
  shutdown('shutdown'),
  restart('restart'),
  userRequest('user_request');

  final String wireValue;
  const SendspinGoodbyeReason(this.wireValue);
}

/// Binary message IDs per Sendspin spec. The player role owns 4-7, of which
/// only 4 (audio chunk) is defined. Artwork is 8-11, visualizer is 16-23.
const int _binaryTypePlayerMin = 4;
const int _binaryTypePlayerMax = 7;
const int _binaryTypeAudioChunk = 4;
const int _binaryTypeArtworkMin = 8;
const int _binaryTypeArtworkMax = 11;

/// Audio chunk header: message type, int64 timestamp, uint32 send_ahead.
const int _audioChunkHeaderSize = 13;

/// A parsed binary audio chunk from the Sendspin protocol.
class AudioFrame {
  /// `send_ahead` values that report "no lead measured" rather than a lead of
  /// that length; chunks carrying either are not usable as delay samples.
  static const int sendAheadSaturatedLow = 0;
  static const int sendAheadSaturatedHigh = 0xFFFFFFFF;

  final int type;
  final int timestampUs;

  /// Microseconds from the server's transmission of this chunk to
  /// [timestampUs]. Carries no scheduling meaning.
  final int sendAheadUs;
  final Uint8List audioData;

  const AudioFrame({
    required this.type,
    required this.timestampUs,
    this.sendAheadUs = sendAheadSaturatedLow,
    required this.audioData,
  });

  /// Whether [sendAheadUs] is a real measurement.
  bool get hasSendAhead =>
      sendAheadUs != sendAheadSaturatedLow &&
      sendAheadUs != sendAheadSaturatedHigh;
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

  /// The client's static Curve25519 identity. Its public key is the
  /// `client_id`.
  final SendspinIdentity identity;
  final int bufferSeconds;
  final DeviceInfo deviceInfo;
  final List<AudioFormat> supportedFormats;
  final Set<SendspinRole> roles;
  final List<ArtworkChannel>? artworkChannels;

  final SendspinClock _clock = SendspinClock();

  /// Monotonic time source for everything client-side: the `client/time`
  /// `client_transmitted` value, the `server/time` reply's locally-recorded
  /// receive timestamp (T4), and the burst module's slot timing. Switching
  /// to a [Stopwatch] (vs `DateTime.now().microsecondsSinceEpoch`) protects
  /// the Kalman filter from OS NTP corrections and DST jumps that would
  /// otherwise feed into `time_added` and explode the predicted covariance.
  /// The wire-format `client_transmitted` is opaque to the server — it just
  /// echoes it back as `T1` in the round-trip math, so the Stopwatch's
  /// process-relative epoch does not affect the protocol.
  final Stopwatch _stopwatch = Stopwatch()..start();
  final int Function()? _now;
  late final SendspinTimeBurst _timeBurst;

  final ArrivalDelayTracker _arrivalDelay = ArrivalDelayTracker();

  int _staticDelayMs = 0;
  bool _pipelineError = false;

  SendspinPlayerState _state = const SendspinPlayerState();
  final StreamController<SendspinPlayerState> _stateController =
      StreamController<SendspinPlayerState>.broadcast();

  Timer? _stateReportTimer;

  /// A metadata state whose timestamp is still in the future. At most one is
  /// held; [_pendingMetadataTimer] applies it when its time is reached.
  SendspinMetadata? _pendingMetadata;
  Timer? _pendingMetadataTimer;

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

  /// Called with each audio chunk's arrival delay in microseconds:
  /// `arrival - computeClientTime(timestamp - send_ahead)`. Not called for
  /// chunks with a saturated `send_ahead` or before the clock is synchronized.
  void Function(int delayUs)? onArrivalDelay;

  /// Called when a binary artwork frame is received (artwork role).
  void Function(ArtworkFrame frame)? onArtworkFrame;

  /// Called when the server changes volume or mute via server/command.
  void Function(double volume, bool muted)? onVolumeChanged;

  /// Called when the server updates the static delay via server/command.
  void Function(int delayMs)? onStaticDelayChanged;

  /// Called when a group/update message arrives with the new group state.
  void Function(SendspinGroupState groupState)? onGroupUpdate;

  /// Called when a metadata state takes effect: immediately for a past or
  /// present timestamp, or when a scheduled update's time is reached.
  void Function(SendspinMetadata metadata)? onMetadataUpdate;

  /// Called when a server/state message updates the controller sub-object.
  /// The argument is the full new snapshot.
  void Function(SendspinControllerInfo controller)? onControllerUpdate;

  SendspinProtocol({
    required this.playerName,
    required this.identity,
    required this.bufferSeconds,
    this.deviceInfo = const DeviceInfo(),
    this.supportedFormats = const [
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16),
      AudioFormat(codec: 'pcm', channels: 2, sampleRate: 44100, bitDepth: 16),
    ],
    this.roles = const {SendspinRole.player},
    this.artworkChannels,
    int initialStaticDelayMs = 0,
    int Function()? now,
  }) : _now = now {
    if (roles.contains(SendspinRole.artwork) &&
        (artworkChannels == null || artworkChannels!.isEmpty)) {
      throw ArgumentError(
          'artworkChannels is required when artwork role is present');
    }
    if (roles.contains(SendspinRole.artwork) && artworkChannels!.length > 4) {
      throw ArgumentError('artworkChannels may have at most 4 entries');
    }
    _staticDelayMs = initialStaticDelayMs.clamp(0, 5000);
    _state = _state.copyWith(staticDelayMs: _staticDelayMs);
    _timeBurst = SendspinTimeBurst(now: nowUs);
    _wireTimeBurst();
  }

  /// Local monotonic clock in microseconds. All client-side timestamps
  /// (filter `time_added`, NTP `client_transmitted`/`client_received`, and
  /// the output domain of [SendspinClock.computeClientTime]) live in this
  /// domain.
  int nowUs() => _now?.call() ?? _stopwatch.elapsedMicroseconds;

  void _wireTimeBurst() {
    _timeBurst.onSendTimeMessage = (clientTransmittedUs) {
      onSendText?.call(buildClientTime(clientTransmittedUs));
    };
    _timeBurst.onApplyBestSample = (offset, maxError, timeAdded) {
      _clock.update(offset, maxError, timeAdded);
      _updateState(_state.copyWith(
        clockOffsetMs: (_clock.precisionUs / 1000).round(),
        clockSamples: _clock.sampleCount,
      ));
      // The mapping just moved, so a held scheduled update may now be due
      // (or due later than its timer says).
      _evaluatePendingMetadata();
    };
  }

  // -------------------------------------------------------------------------
  // Public getters
  // -------------------------------------------------------------------------

  /// The `client_id` sent to servers: the identity's public key as unpadded
  /// base64url.
  String get clientId => identity.clientId;

  /// The clock filter, exposed for consumers that need time conversion.
  SendspinClock get clock => _clock;

  /// Current player state.
  SendspinPlayerState get state => _state;

  /// Stream of state changes.
  Stream<SendspinPlayerState> get stateStream => _stateController.stream;

  /// Current static delay in milliseconds (set by server/command).
  int get staticDelayMs => _staticDelayMs;

  /// The scheduled metadata update that has not taken effect yet, if any.
  /// The current state is [SendspinPlayerState.metadata].
  SendspinMetadata? get pendingMetadata => _pendingMetadata;

  /// Current track position in milliseconds, extrapolated from the current
  /// metadata state (never from [pendingMetadata]), or null when the server
  /// reported no progress.
  int? get currentTrackPositionMs {
    final metadata = _state.metadata;
    final progress = metadata?.progress;
    if (metadata == null || progress == null) return null;
    final serverNowUs = _clock.computeServerTime(nowUs());
    final position = progress.trackProgress +
        (serverNowUs - metadata.timestamp) * progress.playbackSpeed ~/ 1000000;
    if (position < 0) return 0;
    if (progress.trackDuration != 0 && position > progress.trackDuration) {
      return progress.trackDuration;
    }
    return position;
  }

  /// `min_buffer_ms` sized from measured audio-chunk arrival delay, or null
  /// until enough chunks have been observed.
  int? get measuredMinBufferMs => _arrivalDelay.minBufferMs;

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
    final payload = <String, dynamic>{
      'client_id': identity.clientId,
      'name': playerName,
      'version': 1,
      'supported_roles': roles.map((r) => r.wireValue).toList(),
      'device_info': {
        'product_name': deviceInfo.productName,
        'manufacturer': deviceInfo.manufacturer,
        'software_version': deviceInfo.softwareVersion,
      },
    };

    if (roles.contains(SendspinRole.player)) {
      payload['player@v1_support'] = {
        'supported_formats': supportedFormats.map((f) => f.toJson()).toList(),
        'buffer_capacity': _computeBufferCapacityBytes(),
        // Spec: player@v1_support.supported_commands is a subset of
        // {'volume', 'mute'}. set_static_delay belongs in client/state's
        // player.supported_commands, not in the hello support object.
        // MA's Sendspin server closes the connection (WS close 1000) on
        // hellos that advertise set_static_delay here.
        'supported_commands': ['volume', 'mute'],
      };
    }

    if (roles.contains(SendspinRole.artwork)) {
      payload['artwork@v1_support'] = {
        'channels': artworkChannels!.map((c) => c.toJson()).toList(),
      };
    }

    return jsonEncode({'type': 'client/hello', 'payload': payload});
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
    final payload = <String, dynamic>{
      'state': _pipelineError ? 'error' : 'synchronized',
    };

    if (roles.contains(SendspinRole.player)) {
      payload['player'] = {
        'volume': (_state.volume * 100).round(),
        'muted': _state.muted,
        'static_delay_ms': _staticDelayMs,
        'supported_commands': ['set_static_delay'],
      };
    }

    return jsonEncode({'type': 'client/state', 'payload': payload});
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

  void _requireRole(SendspinRole role) {
    if (!roles.contains(role)) {
      throw StateError(
          '${role.wireValue} role is required but not in the role set');
    }
  }

  /// Sends a controller command (e.g. 'play', 'pause', 'stop', 'next').
  ///
  /// Throws [StateError] if the controller role is not active.
  void sendControllerCommand(String command) {
    _requireRole(SendspinRole.controller);
    onSendText?.call(jsonEncode({
      'type': 'client/command',
      'payload': {
        'controller': {'command': command},
      },
    }));
  }

  /// Sends a controller volume command (0-100).
  ///
  /// Throws [StateError] if the controller role is not active.
  /// Throws [RangeError] if [volume] is outside 0-100.
  void sendControllerVolume(int volume) {
    _requireRole(SendspinRole.controller);
    RangeError.checkValueInInterval(volume, 0, 100, 'volume');
    onSendText?.call(jsonEncode({
      'type': 'client/command',
      'payload': {
        'controller': {'command': 'volume', 'volume': volume},
      },
    }));
  }

  /// Sends a controller mute command.
  ///
  /// Throws [StateError] if the controller role is not active.
  void sendControllerMute(bool mute) {
    _requireRole(SendspinRole.controller);
    onSendText?.call(jsonEncode({
      'type': 'client/command',
      'payload': {
        'controller': {'command': 'mute', 'mute': mute},
      },
    }));
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
    final groupState = SendspinGroupState(
      playbackState: SendspinGroupPlaybackState.fromWire(
          payload['playback_state'] as String?),
      groupId: payload['group_id'] as String?,
      groupName: payload['group_name'] as String?,
    );
    _updateState(_state.copyWith(groupState: groupState));
    onGroupUpdate?.call(groupState);
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
    final clientReceived = nowUs();
    final clientTransmitted = payload['client_transmitted'] as int? ?? 0;

    // NTP-style offset and round-trip delay.
    final offset = ((serverReceived - clientTransmitted) +
            (serverTransmitted - clientReceived)) ~/
        2;
    final delay = (clientReceived - clientTransmitted) -
        (serverTransmitted - serverReceived);

    // Hand the parsed sample to the burst driver, which keeps the
    // best-RTT sample of the burst and only feeds that one into the
    // filter. The state-update callback wired in [_wireTimeBurst] runs
    // when the burst completes.
    _timeBurst.onTimeResponse(offset, delay ~/ 2, clientReceived);
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
    // Each role object carries that role's full state; an omitted object
    // leaves the role's state, and any pending scheduled update, unchanged.
    final metadataJson = payload['metadata'] as Map<String, dynamic>?;
    // `timestamp` is required; without it the state cannot be placed in time
    // or have its progress extrapolated, so the object is ignored.
    if (metadataJson != null && metadataJson['timestamp'] is num) {
      // Either way a held pending update is gone: a future-timestamped state
      // replaces it, a past or present one discards it.
      _pendingMetadata = SendspinMetadata.fromJson(metadataJson);
      _evaluatePendingMetadata();
    }

    final controller =
        _parseController(payload['controller'] as Map<String, dynamic>?);
    if (controller != null) {
      _updateState(_state.copyWith(controller: controller));
      onControllerUpdate?.call(controller);
    }
  }

  /// Applies [_pendingMetadata] if its timestamp, translated to the local
  /// clock with the time filter's current best estimate, has been reached;
  /// otherwise (re)arms the timer for the remainder. Runs when a state is
  /// received, when the timer fires, and whenever the filter is updated.
  void _evaluatePendingMetadata() {
    _pendingMetadataTimer?.cancel();
    _pendingMetadataTimer = null;
    final pending = _pendingMetadata;
    if (pending == null) return;

    // With no samples the filter is the identity mapping and cannot place a
    // server timestamp at all, so there is nothing to wait for.
    final waitUs = _clock.sampleCount == 0
        ? 0
        : _clock.computeClientTime(pending.timestamp) - nowUs();
    if (waitUs > 0) {
      _pendingMetadataTimer =
          Timer(Duration(microseconds: waitUs), _evaluatePendingMetadata);
      return;
    }
    _pendingMetadata = null;
    _applyMetadata(pending);
  }

  void _applyMetadata(SendspinMetadata metadata) {
    _updateState(_state.copyWith(metadata: metadata));
    onMetadataUpdate?.call(metadata);
  }

  /// Drops the current metadata state and any pending scheduled update.
  void _discardMetadata() {
    _pendingMetadataTimer?.cancel();
    _pendingMetadataTimer = null;
    _pendingMetadata = null;
    if (_state.metadata != null) {
      _updateState(_state.copyWith(clearMetadata: true));
    }
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

  /// Handles an incoming binary message, dispatching by message ID and
  /// active roles.
  ///
  /// Audio chunks (ID 4) are forwarded to [onAudioFrame] only when the
  /// [SendspinRole.player] role is active. The remaining player IDs (5-7) are
  /// not defined and are ignored. Artwork frames (ID 8-11) are forwarded to
  /// [onArtworkFrame] only when [SendspinRole.artwork] is active. All other
  /// IDs are silently dropped.
  void handleBinaryMessage(Uint8List data) {
    if (data.isEmpty) return;
    final type = data[0];

    if (type >= _binaryTypePlayerMin && type <= _binaryTypePlayerMax) {
      if (type != _binaryTypeAudioChunk) return;
      if (data.length < _audioChunkHeaderSize) return;
      if (!roles.contains(SendspinRole.player)) return;
      final frame = parseBinaryFrame(data);
      _measureArrivalDelay(frame);
      onAudioFrame?.call(frame);
      return;
    }

    if (type >= _binaryTypeArtworkMin && type <= _binaryTypeArtworkMax) {
      if (data.length < 9) return;
      if (roles.contains(SendspinRole.artwork)) {
        final view =
            ByteData.view(data.buffer, data.offsetInBytes, data.lengthInBytes);
        onArtworkFrame?.call(ArtworkFrame(
          channel: type - _binaryTypeArtworkMin,
          timestampUs: view.getInt64(1, Endian.big),
          imageData: Uint8List.sublistView(data, 9),
        ));
      }
      return;
    }
  }

  /// Records the chunk's arrival delay for sizing `min_buffer_ms`. Saturated
  /// `send_ahead` values and samples taken before the time filter has
  /// synchronized are not delay samples.
  void _measureArrivalDelay(AudioFrame frame) {
    if (!frame.hasSendAhead || !_clock.isSynchronized) return;
    final arrivalUs = nowUs();
    final transmittedUs =
        _clock.computeClientTime(frame.timestampUs - frame.sendAheadUs);
    final delayUs = arrivalUs - transmittedUs;
    _arrivalDelay.addSample(delayUs: delayUs, nowUs: arrivalUs);
    onArrivalDelay?.call(delayUs);
  }

  /// Parses an audio chunk: byte 0 = message type, bytes 1-8 = BE int64
  /// timestamp, bytes 9-12 = BE uint32 send_ahead, bytes 13+ = audio data.
  static AudioFrame parseBinaryFrame(Uint8List frame) {
    final view =
        ByteData.view(frame.buffer, frame.offsetInBytes, frame.lengthInBytes);
    return AudioFrame(
      type: view.getUint8(0),
      timestampUs: view.getInt64(1, Endian.big),
      sendAheadUs: view.getUint32(9, Endian.big),
      audioData: Uint8List.sublistView(frame, _audioChunkHeaderSize),
    );
  }

  // -------------------------------------------------------------------------
  // Clock sync
  // -------------------------------------------------------------------------

  /// Starts the burst-strategy clock-sync driver.
  ///
  /// Per the upstream `Sendspin/time-filter` README: 8 NTP exchanges sent
  /// sequentially every ~10 seconds, only the lowest-`max_error` sample of
  /// each burst is fed to the Kalman filter. Sending in parallel and
  /// updating on every reply violates the filter's measurement-independence
  /// assumption on TCP/WebSocket transports.
  void startClockSync() {
    _timeBurst.start();
  }

  /// Stops the burst-strategy clock-sync driver.
  void stopClockSync() {
    _timeBurst.stop();
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
    _timeBurst.reset();
    _stopStateReporting();
    _clock.reset();
    _arrivalDelay.reset();
    _discardMetadata();
  }

  /// Cleans up timers and stream controller.
  void dispose() {
    stopClockSync();
    _stopStateReporting();
    _discardMetadata();
    _stateController.close();
  }
}
