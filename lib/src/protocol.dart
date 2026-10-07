import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'activation.dart';
import 'arrival_delay.dart';
import 'artwork.dart';
import 'channel.dart';
import 'identity.dart';
import 'encoding.dart';
import 'json_util.dart';
import 'models.dart';
import 'pairing.dart';
import 'clock.dart';
import 'psk.dart';
import 'time_burst.dart';

/// Reason codes for the client/goodbye message (Sendspin spec).
enum SendspinGoodbyeReason {
  anotherServer('another_server'),
  shutdown('shutdown'),
  restart('restart'),
  userRequest('user_request'),
  unauthorized('unauthorized'),
  pairingRequired('pairing_required'),
  concurrentAttempt('concurrent_attempt'),
  unpaired('unpaired');

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

  /// MAC address of the network interface the connection is opened on, in
  /// lowercase colon-separated form (`aa:bb:cc:dd:ee:ff`). Optional.
  final String? macAddress;

  const DeviceInfo({
    this.productName = 'sendspin_dart',
    this.manufacturer = 'sendspin_dart',
    this.softwareVersion = '0.1.0',
    this.macAddress,
  });

  Map<String, dynamic> toJson() => {
        'product_name': productName,
        'manufacturer': manufacturer,
        'software_version': softwareVersion,
        if (macAddress != null) 'mac_address': macAddress,
      };
}

/// Commands a server may send to the player role, as advertised in
/// `supported_commands` of `client/state`.
enum SendspinPlayerCommand {
  volume('volume'),
  mute('mute'),
  setOutputDelay('set_output_delay');

  final String wireValue;
  const SendspinPlayerCommand(this.wireValue);
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

  bool sameAs(AudioFormat other) =>
      codec == other.codec &&
      channels == other.channels &&
      sampleRate == other.sampleRate &&
      bitDepth == other.bitDepth;
}

/// Sendspin protocol state machine.
///
/// Handles the encrypted channel, message parsing/building, binary frame
/// parsing, clock sync, connection state management, volume/mute commands,
/// and periodic state reporting. Does NOT create codecs, buffer audio, decode
/// audio, or provide pullSamples() — those concerns belong to the player
/// layer.
///
/// Transport is injected. Wire [onSendText] and [onSendBinary] to a
/// WebSocket, feed its messages to [handleTextMessage] and
/// [handleBinaryMessage], call [start] once the socket is open, and close
/// the socket when [onClose] fires.
///
/// The connection sequence is: `client/init`, `server/init` and the Noise
/// handshake in cleartext, then encrypted `server/hello`, `client/hello` and
/// `server/activate`. Nothing else is sent until that first activation.
class SendspinProtocol {
  final String playerName;

  /// The client's static Curve25519 identity. Its public key is the
  /// `client_id`.
  final SendspinIdentity identity;
  final int bufferSeconds;
  final DeviceInfo deviceInfo;
  final List<AudioFormat> supportedFormats;
  final Set<SendspinRole> roles;
  List<ArtworkChannel>? _artworkChannels;

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

  late final SendspinChannel _channel;
  bool _unpairedAccess;

  /// The outcome of the latest Noise handshake on this connection.
  SendspinHandshakeResult? _handshake;
  bool _helloReceived = false;

  /// Set by the first admissible `server/activate`. Until then the client
  /// sends nothing but `client/hello` (and, if it must, `client/goodbye`).
  bool _activated = false;

  /// Between a re-handshake starting and the `server/activate` that follows
  /// it, no new application message may be sent; they wait in [_held].
  bool _rehandshaking = false;
  final List<(String, SendspinRole?)> _held = [];
  bool _clockSyncPaused = false;
  bool _playerStreamActive = false;

  /// Drops a connection whose server never declares its purpose.
  Timer? _activateTimer;

  late final ArtworkReceiver _artwork = ArtworkReceiver(
    // With no samples the filter cannot place a timestamp: show it now.
    usUntil: (timestampUs) {
      if (_clock.sampleCount == 0) return 0;
      // Compared before subtracting, so an extreme timestamp cannot wrap.
      final dueUs = _clock.computeClientTime(timestampUs);
      final now = nowUs();
      return dueUs <= now ? 0 : dueUs - now;
    },
  )..onImage = (frame) => onArtworkFrame?.call(frame);
  bool _artworkStreamActive = false;

  /// Pairing `server/activate` messages received since the last Noise
  /// handshake; sent as `pairing_index`.
  int _pairingIndex = 0;

  /// The long-term PSK offered in the pairing attempt in progress, from
  /// `client/pair-init` until success or abort.
  Uint8List? _pairingAttemptPsk;
  Timer? _pairingAttemptTimer;

  /// Set once this client has aborted an attempt: pairing messages still in
  /// flight from the server are discarded until the next `server/activate`.
  bool _pairingAborted = false;

  /// The server whose pairing record keys this connection, kept from
  /// eviction while the connection is open.
  String? _retainedServerId;

  int _outputDelayMs = 0;
  int _requiredLeadTimeMs;
  int _minBufferMs;
  Set<SendspinPlayerCommand> _supportedCommands;
  AudioFormat? _preferredFormat;

  /// False while the consumer reports a non-interruptible external activity.
  bool _availableToSendspin = true;

  /// The `available` and `min_buffer_ms` values last put on the wire, to
  /// notice when the time filter or the delay measurement changes them.
  bool? _reportedAvailable;
  bool _stateHeld = false;
  int? _reportedMinBufferMs;

  SendspinPlayerState _state = const SendspinPlayerState();
  final StreamController<SendspinPlayerState> _stateController =
      StreamController<SendspinPlayerState>.broadcast();

  /// A metadata state whose timestamp is still in the future. At most one is
  /// held; [_pendingMetadataTimer] applies it when its time is reached.
  SendspinMetadata? _pendingMetadata;
  Timer? _pendingMetadataTimer;

  // -------------------------------------------------------------------------
  // Callbacks
  // -------------------------------------------------------------------------

  /// Sends a WebSocket text message. Only the cleartext opening of the
  /// connection (`client/init` and the Noise handshake reply) uses text.
  void Function(String message)? onSendText;

  /// Sends a WebSocket binary message. Everything after the handshake is an
  /// encrypted binary message, JSON included.
  void Function(Uint8List data)? onSendBinary;

  /// The connection is finished and the WebSocket must be closed: the
  /// handshake or an encrypted message failed, the server refused
  /// `client/init`, or the client said goodbye. [reason] is for logging.
  void Function(String reason)? onClose;

  /// Called when the server refuses `client/init` with `server/error`
  /// (`unsupported_version`, `unsupported_suite` or `malformed`). [onClose]
  /// follows.
  void Function(String reason)? onServerError;

  /// Called when a pairing completes: the record for [serverId] is held and
  /// is being written to the store ([onPairingStoreError] reports a failed
  /// write). The server normally re-handshakes to the new long-term PSK
  /// straight afterwards.
  void Function(String serverId)? onPaired;

  /// Called when a pairing attempt ends without pairing because the server
  /// sent `pair/abort`, with its reason (e.g. `user_cancelled`).
  void Function(String reason)? onPairingAborted;

  /// Called if persisting pairing records through the [SendspinPairingStore]
  /// fails. The in-memory records are already updated.
  void Function(Object error)? onPairingStoreError;

  /// Called after each admissible `server/activate` has been applied, with
  /// the connection's activities and active roles. Also readable from
  /// [state].
  void Function(Set<String> activities, List<String> activeRoles)? onActivate;

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

  /// Called when an artwork channel's image changes: an image has been
  /// received in full and its display time has been reached, or the channel
  /// was cleared, in which case `imageData` is empty.
  void Function(ArtworkFrame frame)? onArtworkFrame;

  /// Called when the server changes volume or mute via server/command.
  void Function(double volume, bool muted)? onVolumeChanged;

  /// Called when the server sets the output delay via `server/command`.
  /// The spec requires the delay to survive reboots and reconnects: persist
  /// it here and pass it back as `initialOutputDelayMs`.
  void Function(int delayMs)? onOutputDelayChanged;

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
    List<ArtworkChannel>? artworkChannels,
    required bool unpairedAccess,
    SendspinPairing? pairing,
    this.activateTimeout = const Duration(seconds: 30),
    this.pairingAttemptTimeout = const Duration(minutes: 2),
    Set<SendspinPlayerCommand> supportedCommands = const {
      SendspinPlayerCommand.volume,
      SendspinPlayerCommand.mute,
      SendspinPlayerCommand.setOutputDelay,
    },
    int initialOutputDelayMs = 0,
    int requiredLeadTimeMs = 250,
    int minBufferMs = 250,
    int Function()? now,
  })  : _now = now,
        _unpairedAccess = unpairedAccess,
        _artworkChannels = artworkChannels,
        pairing = pairing ?? SendspinPairing.inMemory(),
        _supportedCommands = Set.of(supportedCommands),
        _requiredLeadTimeMs = requiredLeadTimeMs,
        _minBufferMs = minBufferMs {
    if (requiredLeadTimeMs < 0 || minBufferMs < 0) {
      throw ArgumentError('Timing parameters must not be negative');
    }
    if (roles.contains(SendspinRole.artwork) &&
        (artworkChannels == null || artworkChannels.isEmpty)) {
      throw ArgumentError(
          'artworkChannels is required when artwork role is present');
    }
    if (roles.contains(SendspinRole.artwork) && artworkChannels!.length > 4) {
      throw ArgumentError('artworkChannels may have at most 4 entries');
    }
    _outputDelayMs = initialOutputDelayMs.clamp(0, 5000);
    _state = _state.copyWith(outputDelayMs: _outputDelayMs);
    _timeBurst = SendspinTimeBurst(now: nowUs);
    _wireTimeBurst();
    _channel = SendspinChannel(
        identity: identity, pskCandidates: this.pairing.candidates)
      ..onSendText = ((text) => onSendText?.call(text))
      ..onSendBinary = ((data) => onSendBinary?.call(data))
      ..onJson = _dispatchJson
      ..onBinary = _dispatchBinary
      ..onHandshakeComplete = _handleHandshakeComplete
      ..onRehandshakeStarted = _handleRehandshakeStarted
      ..onServerError = ((reason) => onServerError?.call(reason))
      ..onClose = _handleChannelClosed;
  }

  /// How long to wait for the first `server/activate` after the handshake
  /// before dropping the connection.
  final Duration activateTimeout;

  /// How long a pairing attempt may run, from its first message, before the
  /// client aborts it with `attempt_timeout`.
  final Duration pairingAttemptTimeout;

  /// The device's pairing PSK and pairing records. When none is supplied an
  /// in-memory one with a fresh pairing PSK is used, which loses its
  /// pairings on restart; pass one loaded from a [SendspinPairingStore] to
  /// keep them.
  final SendspinPairing pairing;

  /// The token an operator enters into a server to pair by the Pairing PSK
  /// method: this device's public key and pairing PSK, as text for a QR code
  /// or copy and paste.
  String get pairingToken => pairing.pairingToken(identity.publicKey);

  /// Local monotonic clock in microseconds. All client-side timestamps
  /// (filter `time_added`, NTP `client_transmitted`/`client_received`, and
  /// the output domain of [SendspinClock.computeClientTime]) live in this
  /// domain.
  int nowUs() => _now?.call() ?? _stopwatch.elapsedMicroseconds;

  void _wireTimeBurst() {
    _timeBurst.onSendTimeMessage = (clientTransmittedUs) {
      _sendApplication(buildClientTime(clientTransmittedUs));
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
      _artwork.reevaluate();
      // A player becomes available once the filter is synchronized.
      _reportStateIfChanged();
    };
    // Until the filter can translate timestamps the player is unavailable,
    // so do not wait a full burst interval for the second sample.
    _timeBurst.nextBurstDelay =
        () => _clock.isSynchronized ? null : const Duration(milliseconds: 100);
  }

  // -------------------------------------------------------------------------
  // Public getters
  // -------------------------------------------------------------------------

  /// The `client_id` sent to servers: the identity's public key as unpadded
  /// base64url.
  String get clientId => identity.clientId;

  /// Whether this client admits unpaired access: a server with no pairing
  /// record activating roles or declaring playback. Advertised in
  /// `client/hello`.
  bool get unpairedAccess => _unpairedAccess;

  /// Changes the unpaired-access setting. Turning it off closes a connection
  /// that relies on it with `client/goodbye` reason `pairing_required`. The
  /// new value is advertised in the next `client/hello`.
  set unpairedAccess(bool enabled) {
    if (_unpairedAccess == enabled) return;
    _unpairedAccess = enabled;
    final handshake = _handshake;
    if (enabled || handshake == null || !_activated) return;
    final relies = handshake.matchedCategory != SendspinPskCategory.longTerm &&
        (_state.activities.contains(activityPlayback) ||
            _state.activeRoles.isNotEmpty);
    if (relies) _goodbyeAndClose(SendspinGoodbyeReason.pairingRequired);
  }

  /// The `server_id` of the connected server, once the handshake completed.
  String? get serverId => _handshake?.serverId;

  /// Whether the session is paired: the handshake matched a long-term PSK
  /// from a pairing record.
  bool get isPaired =>
      _handshake?.matchedCategory == SendspinPskCategory.longTerm;

  /// The pairing methods offered in `client/hello`, each with the emission
  /// formats it offers.
  Map<String, Set<String>> get _offeredPairMethods => const {'pairing_psk': {}};

  /// The clock filter, exposed for consumers that need time conversion.
  SendspinClock get clock => _clock;

  /// Current player state.
  SendspinPlayerState get state => _state;

  /// Stream of state changes.
  Stream<SendspinPlayerState> get stateStream => _stateController.stream;

  /// Current output delay in milliseconds (0-5000): extra delay beyond the
  /// device's audio port, such as an external amplifier.
  int get outputDelayMs => _outputDelayMs;

  /// Whether the client reports `available: true`: the consumer has not
  /// declared a non-interruptible external activity, and, when the player
  /// role is active, the time filter is synchronized.
  bool get isAvailable =>
      _availableToSendspin &&
      (!isRoleActive(SendspinRole.player) || _clock.isSynchronized);

  /// The `min_buffer_ms` reported to the server: the configured minimum, or
  /// the value measured from chunk arrival delay when that is larger.
  int get reportedMinBufferMs {
    final measured = _arrivalDelay.minBufferMs ?? 0;
    return measured > _minBufferMs ? measured : _minBufferMs;
  }

  /// The format the player currently prefers, or null for no override. Must
  /// be one of [supportedFormats]. The server re-derives the stream format
  /// when this changes.
  AudioFormat? get preferredFormat => _preferredFormat;
  set preferredFormat(AudioFormat? format) {
    if (format != null && !supportedFormats.any((f) => f.sameAs(format))) {
      throw ArgumentError('preferredFormat must be one of supportedFormats');
    }
    _preferredFormat = format;
    _sendState();
  }

  /// The artwork channel configuration reported in `client/state`.
  List<ArtworkChannel>? get artworkChannels => _artworkChannels;

  /// Changes the artwork channels at runtime (index is the channel number,
  /// at most four; a channel with source `none` receives nothing) and
  /// reports the new configuration. The server answers with a
  /// `stream/start` and re-sends the images for channels that changed.
  void setArtworkChannels(List<ArtworkChannel> channels) {
    _requireSupported(SendspinRole.artwork);
    if (channels.isEmpty || channels.length > 4) {
      throw ArgumentError('artworkChannels must have 1 to 4 entries');
    }
    _artworkChannels = List.of(channels);
    _sendState();
  }

  /// The image an artwork channel currently shows, or null if none.
  Uint8List? currentArtwork(int channel) => _artwork.currentImage(channel);

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
    if (!_stateController.isClosed) _stateController.add(newState);
  }

  /// Called by the player layer to update state (e.g. buffer depth).
  void updatePipelineState(SendspinPlayerState newState) {
    _updateState(newState);
  }

  // -------------------------------------------------------------------------
  // Message builders
  // -------------------------------------------------------------------------

  /// Builds the `client/hello` message, sent in response to `server/hello`.
  ///
  /// `client_id` and `version` are not here: they travel in `client/init`.
  String buildClientHello() {
    final payload = <String, dynamic>{
      'name': playerName,
      'device_info': deviceInfo.toJson(),
      'supported_roles': roles.map((r) => r.wireValue).toList(),
      if (roles.contains(SendspinRole.player))
        'player@v1_support': {
          'supported_formats': supportedFormats.map((f) => f.toJson()).toList(),
          'buffer_capacity': _computeBufferCapacityBytes(),
        },
      'supported_pair_methods': {
        for (final method in _offeredPairMethods.keys)
          method: <String, dynamic>{},
      },
      'unpaired_access': {'enabled': _unpairedAccess},
    };
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

  /// Builds a `client/state` report: `available` plus the full state object
  /// of every active role that defines one.
  String buildClientState() {
    final payload = <String, dynamic>{'available': isAvailable};

    if (isRoleActive(SendspinRole.player)) {
      payload['player'] = {
        'volume': (_state.volume * 100).round(),
        'muted': _state.muted,
        'output_delay_ms': _outputDelayMs,
        'required_lead_time_ms': _requiredLeadTimeMs,
        'min_buffer_ms': reportedMinBufferMs,
        'supported_commands': [
          for (final command in SendspinPlayerCommand.values)
            if (_supportedCommands.contains(command)) command.wireValue,
        ],
        if (_preferredFormat != null) 'format': _preferredFormat!.toJson(),
      };
    }

    if (isRoleActive(SendspinRole.artwork)) {
      payload['artwork'] = {
        'channels': _artworkChannels!.map((c) => c.toJson()).toList(),
      };
    }

    return jsonEncode({'type': 'client/state', 'payload': payload});
  }

  /// Sends `client/state` and remembers the derived values it carried.
  void _sendState() {
    if (_activated && _rehandshaking) {
      // Every client/state is the full state, so rather than hold several
      // that will be stale, send one fresh one when the window ends.
      _stateHeld = true;
      return;
    }
    _reportedAvailable = isAvailable;
    _reportedMinBufferMs = reportedMinBufferMs;
    _sendApplication(buildClientState());
  }

  /// Sends `client/state` when a value the library derives itself
  /// (`available`, the measured `min_buffer_ms`) differs from what was last
  /// reported.
  void _reportStateIfChanged() {
    if (_reportedAvailable == null) return;
    if (_reportedAvailable != isAvailable ||
        (isRoleActive(SendspinRole.player) &&
            _reportedMinBufferMs != reportedMinBufferMs)) {
      _sendState();
    }
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

  /// Sends `client/goodbye`, encrypted. Allowed as soon as the initial
  /// Noise handshake has completed; before that there is no channel to send
  /// it on and the call does nothing.
  ///
  /// The consumer remains responsible for closing the underlying transport
  /// after this returns.
  void sendGoodbye(SendspinGoodbyeReason reason) {
    if (!_channel.isEstablished) return;
    _channel.sendJsonText(buildClientGoodbye(reason));
  }

  /// Says goodbye and asks the consumer to close the socket.
  void _goodbyeAndClose(SendspinGoodbyeReason reason) {
    sendGoodbye(reason);
    _channel.close('client/goodbye ${reason.wireValue}');
  }

  /// Sends an application message, subject to the sequencing rules: nothing
  /// before the first `server/activate`, and nothing new between a
  /// re-handshake and the activation that follows it.
  ///
  /// [role] marks a message that is only valid while that role is active; if
  /// it is held and the role is gone by the time it could be sent, it is
  /// dropped.
  void _sendApplication(String json, {SendspinRole? role}) {
    if (!_activated || !_channel.isEstablished) return;
    if (_rehandshaking) {
      _held.add((json, role));
      return;
    }
    _channel.sendJsonText(json);
  }

  /// Reports whether the client will take part in Sendspin playback.
  ///
  /// Pass false only for a non-interruptible external activity (another
  /// audio source, an HDMI input, local playback that will not yield). For an
  /// interruptible activity stay available and, if the group is playing, use
  /// [sendLeave]. Stream messages are still processed while unavailable.
  void setAvailable(bool available) {
    if (_availableToSendspin == available) return;
    _availableToSendspin = available;
    _sendState();
  }

  /// Sends `client/leave`: the client leaves its current group and ends up
  /// in a stopped solo group, rejoining only through an explicit `switch`.
  void sendLeave() {
    _sendApplication(jsonEncode({
      'type': 'client/leave',
      'payload': <String, dynamic>{},
    }));
  }

  /// Sets the output delay locally (e.g. from a settings screen) and reports
  /// it. Clamped to 0-5000 ms. [onOutputDelayChanged] is not called; it is
  /// for changes made by the server.
  void setOutputDelayMs(int delayMs) {
    _outputDelayMs = delayMs.clamp(0, 5000);
    _updateState(_state.copyWith(outputDelayMs: _outputDelayMs));
    _sendState();
  }

  /// Updates the timing parameters the server schedules audio by. Both
  /// depend on the audio backend, so the consumer supplies them:
  ///
  /// - [requiredLeadTimeMs]: startup lead from a start trigger to the first
  ///   chunk that can be played in full (codec init, backend buffering, DAC
  ///   latency).
  /// - [minBufferMs]: minimum ongoing buffer. The value reported is this or
  ///   the measured arrival-delay tail, whichever is larger.
  ///
  /// Neither includes the output delay.
  void setTimingParameters({int? requiredLeadTimeMs, int? minBufferMs}) {
    if ((requiredLeadTimeMs ?? 0) < 0 || (minBufferMs ?? 0) < 0) {
      throw ArgumentError('Timing parameters must not be negative');
    }
    _requiredLeadTimeMs = requiredLeadTimeMs ?? _requiredLeadTimeMs;
    _minBufferMs = minBufferMs ?? _minBufferMs;
    _sendState();
  }

  /// Changes which commands the server may send, e.g. when the audio output
  /// changes to one without remote volume.
  void setSupportedCommands(Set<SendspinPlayerCommand> commands) {
    _supportedCommands = Set.of(commands);
    _sendState();
  }

  /// Whether the server has activated [role] on this connection.
  bool isRoleActive(SendspinRole role) =>
      _state.activeRoles.contains(role.wireValue);

  void _requireSupported(SendspinRole role) {
    if (!roles.contains(role)) {
      throw StateError(
          '${role.wireValue} is not one of the roles of this client');
    }
  }

  void _requireRole(SendspinRole role) {
    if (!isRoleActive(role)) {
      throw StateError('${role.wireValue} role is not active');
    }
  }

  /// Whether [command] is in `supported_commands` of the latest controller
  /// state, i.e. whether it may be sent right now.
  bool canSendControllerCommand(String command) =>
      isRoleActive(SendspinRole.controller) &&
      (_state.controller?.supportedCommands.contains(command) ?? false);

  /// Sends a `client/command` controller object. A command must be listed in
  /// `supported_commands` of the latest controller state.
  void _sendControllerCommand(String command,
      [Map<String, dynamic> parameters = const {}]) {
    _requireRole(SendspinRole.controller);
    if (!canSendControllerCommand(command)) {
      throw StateError(
          "The server does not currently list '$command' in the controller's "
          'supported_commands');
    }
    _sendApplication(
      jsonEncode({
        'type': 'client/command',
        'payload': {
          'controller': {'command': command, ...parameters},
        },
      }),
      role: SendspinRole.controller,
    );
  }

  /// Sends a controller command that takes no parameter: 'play', 'pause',
  /// 'stop', 'next', 'previous', 'repeat_off', 'repeat_one', 'repeat_all',
  /// 'shuffle', 'unshuffle' or 'switch'.
  ///
  /// Throws [StateError] if the controller role is not active or the server
  /// does not currently list the command as supported.
  void sendControllerCommand(String command) {
    if (const {'volume', 'mute', 'seek', 'seek_relative'}.contains(command)) {
      throw ArgumentError.value(command, 'command',
          'takes a parameter; use the dedicated sendController method');
    }
    _sendControllerCommand(command);
  }

  /// Sends a controller volume command (0-100) for the whole group.
  ///
  /// Throws [RangeError] if [volume] is outside 0-100, and [StateError] as
  /// [sendControllerCommand] does.
  void sendControllerVolume(int volume) {
    _requireRole(SendspinRole.controller);
    RangeError.checkValueInInterval(volume, 0, 100, 'volume');
    _sendControllerCommand('volume', {'volume': volume});
  }

  /// Sends a controller mute command for the whole group.
  void sendControllerMute(bool mute) =>
      _sendControllerCommand('mute', {'mute': mute});

  /// Seeks to an absolute position in milliseconds, between 0 and the
  /// `seek_max_ms` of the latest controller state.
  ///
  /// Throws [RangeError] outside that range, and [StateError] as
  /// [sendControllerCommand] does.
  void sendControllerSeek(int positionMs) {
    _requireRole(SendspinRole.controller);
    if (!canSendControllerCommand('seek')) {
      throw StateError("The server does not currently support 'seek'");
    }
    RangeError.checkValueInInterval(
        positionMs, 0, _state.controller?.seekMaxMs ?? 0, 'positionMs');
    _sendControllerCommand('seek', {'position_ms': positionMs});
  }

  /// Seeks by a signed offset in milliseconds from the current position
  /// (positive forward, negative backward). The server clamps the result.
  void sendControllerSeekRelative(int offsetMs) =>
      _sendControllerCommand('seek_relative', {'offset_ms': offsetMs});

  /// Update volume from local UI and report to server.
  void updateVolume(double volume) {
    _updateState(_state.copyWith(volume: volume.clamp(0.0, 1.0)));
    _sendState();
  }

  /// Update mute from local UI and report to server. Independent of volume.
  void updateMuted(bool muted) {
    _updateState(_state.copyWith(muted: muted));
    _sendState();
  }

  // -------------------------------------------------------------------------
  // Connection
  // -------------------------------------------------------------------------

  /// Begins the connection by sending `client/init`. Call once the WebSocket
  /// is open, after wiring [onSendText] and [onSendBinary].
  void start() {
    _updateState(
        _state.copyWith(connectionState: SendspinConnectionState.connected));
    _channel.start();
  }

  /// Handles an incoming WebSocket text message. Text is only valid during
  /// the cleartext opening of the connection.
  void handleTextMessage(String text) => _channel.handleText(text);

  /// Handles an incoming WebSocket binary message: one encrypted message.
  void handleBinaryMessage(Uint8List data) => _channel.handleBinary(data);

  void _handleHandshakeComplete(SendspinHandshakeResult result) {
    _handshake = result;
    _pairingIndex = 0;
    _releasePairingRecord();
    if (result.matchedCategory == SendspinPskCategory.longTerm) {
      pairing
          .markUsed(result.serverId)
          .catchError((Object e) => onPairingStoreError?.call(e));
      pairing.retain(result.serverId);
      _retainedServerId = result.serverId;
    }
    if (result.isRehandshake) return;
    _updateState(_state.copyWith(serverId: result.serverId));
    _activateTimer = Timer(activateTimeout, () {
      _channel.close('no server/activate within the timeout');
    });
  }

  void _handleRehandshakeStarted() {
    // A pairing attempt does not span a re-handshake: its pairing_index and
    // matched PSK belong to the previous handshake. Ending it here also keeps
    // a later abort from being held and released into the next attempt.
    _endPairingAttempt();
    _rehandshaking = true;
    // The server must follow a re-handshake with server/activate; do not hold
    // messages and pause clock sync indefinitely if it never does.
    _activateTimer?.cancel();
    _activateTimer = Timer(activateTimeout, () {
      _channel.close('no server/activate after the re-handshake');
    });
    // A client/time held until after the re-handshake would measure the hold,
    // not the network, so pause the burst driver instead.
    if (_timeBurst.isStarted) {
      _clockSyncPaused = true;
      _timeBurst.stop();
    }
  }

  void _handleChannelClosed(String reason) {
    _stopTimers();
    _held.clear();
    // The session is over, however it ended: stop output and drop what the
    // server had activated, as if every role had been removed.
    for (final role in _state.activeRoles) {
      _handleRoleRemoved(role);
    }
    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.disconnected,
      activities: const <String>{},
      activeRoles: const <String>[],
    ));
    onClose?.call(reason);
  }

  void _releasePairingRecord() {
    final serverId = _retainedServerId;
    if (serverId != null) pairing.release(serverId);
    _retainedServerId = null;
  }

  void _stopTimers() {
    _endPairingAttempt();
    _releasePairingRecord();
    _activateTimer?.cancel();
    _activateTimer = null;
    _timeBurst.stop();
    _clockSyncPaused = false;
  }

  /// Dispatches a decrypted JSON message by its `type`. Unrecognized types
  /// are ignored.
  void _dispatchJson(Map<String, dynamic> msg) {
    final type = msg['type'] as String;
    final payload = msg['payload'] as Map<String, dynamic>;

    if (type == 'server/hello') return _handleServerHello(payload);
    if (type == 'server/activate') return _handleServerActivate(payload);
    // The server sends nothing else before its first activation, nor between
    // a re-handshake and the activation that follows it. Anything that does
    // arrive then must not be acted on with authorization from the old keys.
    if (!_activated || _rehandshaking) return;

    switch (type) {
      case 'server/pair-finalize':
      case 'server/pair-init':
      case 'server/pair-auth':
      case 'server/pair-confirm':
      case 'pair/abort':
        _handlePairingMessage(type, payload);
      case 'server/unpair':
        _handleServerUnpair();
      case 'server/time':
        _handleServerTime(payload);
      case 'stream/start':
        _handleStreamStart(payload);
      case 'stream/clear':
        _handleStreamClear(payload);
      case 'stream/end':
        _handleStreamEnd(payload);
      case 'server/command':
        _handleServerCommand(payload);
      case 'server/state':
        _handleServerState(payload);
      case 'group/update':
        _handleGroupUpdate(payload);
    }
  }

  void _handleServerHello(Map<String, dynamic> payload) {
    // Sent once per connection; not re-sent after a re-handshake.
    if (_helloReceived) return;
    _helloReceived = true;
    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.syncing,
      serverName: jsonString(payload['name']) ?? 'Unknown',
    ));
    _channel.sendJsonText(buildClientHello());
  }

  void _handleServerActivate(Map<String, dynamic> payload) {
    final handshake = _handshake;
    if (handshake == null || !_helloReceived) return;

    // `activities` is required: a list of unique strings. Anything else is
    // not an activation, and the connection stays as it was.
    final rawActivities = payload['activities'];
    if (rawActivities is! List || rawActivities.any((a) => a is! String)) {
      return;
    }
    final activities = rawActivities.cast<String>().toSet();
    if (activities.length != rawActivities.length) return;

    // Any server/activate ends a pairing attempt that has not finalized:
    // nothing is persisted and the offered PSK is discarded. It also ends the
    // window in which this client discards late pairing messages.
    _endPairingAttempt();
    _pairingAborted = false;
    if (activities.contains(activityPairing)) _pairingIndex++;
    final rawRoles = payload['active_roles'];
    final explicitRoles =
        rawRoles is List ? rawRoles.whereType<String>().toList() : null;
    // The pairing object only matters when pairing is a declared activity.
    final pairing = activities.contains(activityPairing)
        ? jsonObject(payload['pairing'])
        : null;

    final verdict = evaluateActivation(
      matched: handshake.matchedCategory,
      unpairedAccess: _unpairedAccess,
      activities: activities,
      activeRoles: explicitRoles,
      pairingMethod: jsonString(pairing?['method']),
      pairingFormat: jsonString(pairing?['format']),
      offeredPairMethods: _offeredPairMethods,
    );
    switch (verdict) {
      case ActivationVerdict.pairingRequired:
        return _goodbyeAndClose(SendspinGoodbyeReason.pairingRequired);
      case ActivationVerdict.unauthorized:
        return _goodbyeAndClose(SendspinGoodbyeReason.unauthorized);
      case ActivationVerdict.methodNotSupported:
        // The activation is refused but the connection stays open, so the
        // server has answered: stop waiting for it, and end the re-handshake
        // restriction, which lasts only until an activation is received.
        _activateTimer?.cancel();
        _activateTimer = null;
        _endRehandshakeWindow();
        _channel.sendJsonText(jsonEncode({
          'type': 'pair/abort',
          'payload': {'reason': 'method_not_supported'},
        }));
        return;
      case ActivationVerdict.admissible:
        break;
    }

    // `active_roles` persists when a later activation omits it, except that
    // roles do not survive on a connection that is no longer playback-capable.
    // A first activation that omits it carries an empty list.
    final List<String> newRoles;
    if (explicitRoles != null) {
      newRoles = explicitRoles;
    } else if (_activated &&
        isPlaybackCapable(
            handshake.matchedCategory, _unpairedAccess, activities)) {
      newRoles = _state.activeRoles;
    } else {
      newRoles = const [];
    }

    final previousRoles = _state.activeRoles;
    final removed = previousRoles.where((r) => !newRoles.contains(r)).toList();
    final added = newRoles.where((r) => !previousRoles.contains(r)).toList();
    for (final role in removed) {
      _handleRoleRemoved(role);
    }

    _updateState(
        _state.copyWith(activities: activities, activeRoles: newRoles));

    final firstActivation = !_activated;
    _activated = true;
    _activateTimer?.cancel();
    _activateTimer = null;

    _endRehandshakeWindow();

    if (firstActivation) {
      // Restart rather than start: a burst begun before the activation had
      // its first message dropped and would sit out a response timeout.
      _timeBurst.stop();
      _timeBurst.start();
    }

    // A role that defines a client/state object must be reported when it
    // becomes active, and a client with any active role sends an initial
    // client/state.
    if (added.isNotEmpty || (firstActivation && newRoles.isNotEmpty)) {
      _sendState();
    }
    // Removing the player role can make the client available: nothing
    // depends on the clock any more.
    _reportStateIfChanged();

    // Each pairing activation admits one attempt. The admissibility check
    // above has already established that the method is `pairing_psk` and
    // that the pairing PSK is what the handshake matched.
    if (activities.contains(activityPairing)) _startPairingAttempt();

    onActivate?.call(activities, newRoles);
  }

  /// Ends the restriction on new application messages that a re-handshake
  /// imposes: releases what was held, in order, and resumes clock sync.
  void _endRehandshakeWindow() {
    if (!_rehandshaking) return;
    _rehandshaking = false;
    final held = List.of(_held);
    _held.clear();
    if (_activated) {
      for (final (json, role) in held) {
        // The activation just applied may have removed the role a held
        // message was written for.
        if (role == null || isRoleActive(role)) _channel.sendJsonText(json);
      }
    }
    if (_stateHeld) {
      _stateHeld = false;
      _sendState();
    }
    if (_clockSyncPaused) {
      _clockSyncPaused = false;
      _timeBurst.start();
    }
  }

  // -------------------------------------------------------------------------
  // Pairing
  // -------------------------------------------------------------------------

  /// Pairing PSK flow: `client/pair-init` followed immediately by
  /// `client/pair-finalize` carrying a fresh long-term PSK, without waiting
  /// for the server.
  void _startPairingAttempt() {
    final random = Random.secure();
    final psk = Uint8List.fromList(
        List<int>.generate(pskLength, (_) => random.nextInt(256)));
    _pairingAttemptPsk = psk;
    _pairingAttemptTimer = Timer(pairingAttemptTimeout, () {
      _abortPairing('attempt_timeout');
    });
    _sendApplication(jsonEncode({
      'type': 'client/pair-init',
      'payload': {'pairing_index': _pairingIndex},
    }));
    _sendApplication(jsonEncode({
      'type': 'client/pair-finalize',
      'payload': {'long_term_psk': base64UrlNoPad(psk)},
    }));
  }

  void _endPairingAttempt() {
    _pairingAttemptTimer?.cancel();
    _pairingAttemptTimer = null;
    _pairingAttemptPsk = null;
  }

  /// Ends the attempt in progress with `pair/abort`. The connection stays
  /// open, and pairing messages the server sent before it saw the abort are
  /// discarded until its next `server/activate`.
  void _abortPairing(String reason) {
    if (_pairingAttemptPsk == null) return;
    _endPairingAttempt();
    _pairingAborted = true;
    _sendApplication(jsonEncode({
      'type': 'pair/abort',
      'payload': {'reason': reason},
    }));
  }

  /// Aborts the pairing attempt in progress on the operator's behalf with
  /// `pair/abort` reason `user_cancelled`. Does nothing if none is running.
  void cancelPairing() => _abortPairing('user_cancelled');

  /// Refuses this connection under the multiple-server admission rules, for
  /// example because another pairing attempt is already in progress with
  /// this device. A connection the server has declared as pairing gets
  /// `pair/abort` reason `concurrent_attempt`; any other connection gets
  /// `client/goodbye` reason `concurrent_attempt`. Either way it is closed.
  void rejectConcurrentPairing() {
    if (!_activated || !_state.activities.contains(activityPairing)) {
      return _goodbyeAndClose(SendspinGoodbyeReason.concurrentAttempt);
    }
    _endPairingAttempt();
    if (_channel.isEstablished) {
      _channel.sendJsonText(jsonEncode({
        'type': 'pair/abort',
        'payload': {'reason': 'concurrent_attempt'},
      }));
    }
    _channel.close('pair/abort concurrent_attempt');
  }

  void _handlePairingMessage(String type, Map<String, dynamic> payload) {
    final psk = _pairingAttemptPsk;
    if (type == 'pair/abort') {
      // Has no effect once the attempt is already over.
      if (psk == null) return;
      // A missing or malformed field in a pairing message is a protocol
      // error: close without an application-level message.
      final reason = jsonString(payload['reason']);
      if (reason == null) {
        return _channel.close('malformed pair/abort');
      }
      _endPairingAttempt();
      onPairingAborted?.call(reason);
      return;
    }
    if (_pairingAborted) return;

    final handshake = _handshake;
    if (type == 'server/pair-finalize' && psk != null && handshake != null) {
      // The server has persisted its record; persist ours.
      _endPairingAttempt();
      pairing
          .addRecord(SendspinPairingRecord(
              serverId: handshake.serverId, longTermPsk: psk))
          .catchError((Object e) => onPairingStoreError?.call(e));
      onPaired?.call(handshake.serverId);
      return;
    }
    // Anything else is out of sequence for the Pairing PSK method: a protocol
    // error. Close without an application-level message; persist nothing.
    _channel.close('pairing message out of sequence: $type');
  }

  /// `server/unpair`: a paired server drops its record from this client.
  /// Ignored on an unpaired session.
  void _handleServerUnpair() {
    final handshake = _handshake;
    if (handshake == null ||
        handshake.matchedCategory != SendspinPskCategory.longTerm) {
      return;
    }
    _releasePairingRecord();
    pairing
        .removeRecord(handshake.serverId)
        .catchError((Object e) => onPairingStoreError?.call(e));
    _goodbyeAndClose(SendspinGoodbyeReason.unpaired);
  }

  /// Applies the removal of [role] from `active_roles`: stream roles stop
  /// output and clear their buffers, state roles discard their state and any
  /// pending scheduled update. No preceding message from the server is
  /// required for either.
  void _handleRoleRemoved(String role) {
    if (role == SendspinRole.player.wireValue) {
      _endPlayerStream();
    } else if (role == SendspinRole.metadata.wireValue) {
      _discardMetadata();
    } else if (role == SendspinRole.controller.wireValue) {
      if (_state.controller != null) {
        _updateState(_state.copyWith(clearController: true));
      }
    } else if (role == SendspinRole.artwork.wireValue) {
      _endArtworkStream();
    }
  }

  /// Ends the artwork stream: the channels no longer display artwork.
  void _endArtworkStream() {
    _artworkStreamActive = false;
    _artwork.streamEnded();
  }

  void _handleGroupUpdate(Map<String, dynamic> payload) {
    final groupState = SendspinGroupState(
      playbackState: SendspinGroupPlaybackState.fromWire(
          jsonString(payload['playback_state'])),
      groupId: jsonString(payload['group_id']),
      groupName: jsonString(payload['group_name']),
    );
    _updateState(_state.copyWith(groupState: groupState));
    onGroupUpdate?.call(groupState);
  }

  void _handleServerTime(Map<String, dynamic> payload) {
    final serverReceived = jsonInt(payload['server_received']);
    final serverTransmitted = jsonInt(payload['server_transmitted']);
    final clientReceived = nowUs();
    final clientTransmitted = jsonInt(payload['client_transmitted']);
    if (serverReceived == null ||
        serverTransmitted == null ||
        clientTransmitted == null) {
      return;
    }

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
    // max_error is the filter's measurement uncertainty. A round trip that
    // measures as zero (or negative, from timestamp granularity) would make
    // it a zero-variance measurement and divide by zero inside the filter.
    final maxError = delay ~/ 2 < 1 ? 1 : delay ~/ 2;
    _timeBurst.onTimeResponse(offset, maxError, clientReceived);
  }

  void _handleStreamStart(Map<String, dynamic> payload) {
    final artwork = jsonObject(payload['artwork']);
    final artworkChannels = jsonList(artwork?['channels']);
    if (artworkChannels != null && isRoleActive(SendspinRole.artwork)) {
      _artwork.streamStarted(artworkChannels);
      _artworkStreamActive = true;
    }

    final audioFormat = jsonObject(payload['player']);
    if (audioFormat == null || !isRoleActive(SendspinRole.player)) return;
    final codecName = jsonString(audioFormat['codec']) ?? 'pcm';
    final channels = jsonInt(audioFormat['channels']) ?? 2;
    final sampleRate = jsonInt(audioFormat['sample_rate']) ?? 48000;
    final bitDepth = jsonInt(audioFormat['bit_depth']) ?? 16;
    final codecHeader = jsonString(audioFormat['codec_header']);
    // A format that cannot describe audio is not acted on.
    if (channels <= 0 || sampleRate <= 0 || bitDepth <= 0) return;

    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.streaming,
      codec: codecName,
      sampleRate: sampleRate,
      channels: channels,
    ));

    _playerStreamActive = true;

    onStreamConfig?.call(StreamConfig(
      codec: codecName,
      channels: channels,
      sampleRate: sampleRate,
      bitDepth: bitDepth,
      codecHeader:
          (codecHeader != null && codecHeader.isNotEmpty) ? codecHeader : null,
    ));
  }

  /// Whether a `stream/clear` or `stream/end` targets the player role: it is
  /// listed in `roles`, or `roles` is omitted (all active streams).
  static bool _targetsPlayer(Map<String, dynamic> payload) {
    final roles = payload['roles'];
    return roles is! List || roles.contains('player');
  }

  void _handleStreamClear(Map<String, dynamic> payload) {
    if (!_playerStreamActive || !_targetsPlayer(payload)) return;
    onStreamClear?.call();
  }

  void _handleStreamEnd(Map<String, dynamic> payload) {
    final roles = payload['roles'];
    if (_artworkStreamActive && (roles is! List || roles.contains('artwork'))) {
      _endArtworkStream();
    }
    if (!_playerStreamActive || !_targetsPlayer(payload)) return;
    _endPlayerStream();
  }

  /// Stops player output: on `stream/end`, and when the player role is
  /// removed (even if an earlier `stream/end` already ended the stream, so
  /// buffered audio that was still finishing is cleared too).
  void _endPlayerStream() {
    _playerStreamActive = false;

    _updateState(_state.copyWith(
      connectionState: SendspinConnectionState.syncing,
    ));

    onStreamEnd?.call();
  }

  void _handleServerCommand(Map<String, dynamic> payload) {
    final player = jsonObject(payload['player']);
    if (player == null || !isRoleActive(SendspinRole.player)) return;

    // Commands absent from the current supported_commands are ignored.
    final name = player['command'];
    final command = SendspinPlayerCommand.values
        .where((c) => c.wireValue == name && _supportedCommands.contains(c))
        .firstOrNull;
    switch (command) {
      case SendspinPlayerCommand.volume:
        final vol = player['volume'];
        if (vol is num) {
          final normalized = (vol.toDouble() / 100).clamp(0.0, 1.0);
          _updateState(_state.copyWith(volume: normalized));
          _sendState();
          onVolumeChanged?.call(normalized, _state.muted);
        }
      case SendspinPlayerCommand.mute:
        final muted = player['mute'];
        if (muted is bool) {
          _updateState(_state.copyWith(muted: muted));
          _sendState();
          onVolumeChanged?.call(_state.volume, muted);
        }
      case SendspinPlayerCommand.setOutputDelay:
        final delayMs = jsonInt(player['output_delay_ms']);
        if (delayMs != null) {
          _outputDelayMs = delayMs.clamp(0, 5000);
          _updateState(_state.copyWith(outputDelayMs: _outputDelayMs));
          _sendState();
          onOutputDelayChanged?.call(_outputDelayMs);
        }
      case null:
        break;
    }
  }

  void _handleServerState(Map<String, dynamic> payload) {
    // Each role object carries that role's full state; an omitted object
    // leaves the role's state, and any pending scheduled update, unchanged.
    final metadataJson = isRoleActive(SendspinRole.metadata)
        ? jsonObject(payload['metadata'])
        : null;
    // `timestamp` is required; without it the state cannot be placed in time
    // or have its progress extrapolated, so the object is ignored.
    if (metadataJson != null && jsonInt(metadataJson['timestamp']) != null) {
      // Either way a held pending update is gone: a future-timestamped state
      // replaces it, a past or present one discards it.
      _pendingMetadata = SendspinMetadata.fromJson(metadataJson);
      _evaluatePendingMetadata();
    }

    final controller = isRoleActive(SendspinRole.controller)
        ? _parseController(jsonObject(payload['controller']))
        : null;
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
    final rawCommands = jsonList(json['supported_commands']);
    return SendspinControllerInfo(
      // Unmodifiable: this list is what command sending is checked against.
      supportedCommands: List.unmodifiable(
          rawCommands?.whereType<String>() ?? const <String>[]),
      volume: jsonInt(json['volume']) ?? 0,
      muted: jsonBool(json['muted']) ?? false,
      repeat: SendspinRepeatMode.fromWire(jsonString(json['repeat'])),
      shuffle: jsonBool(json['shuffle']) ?? false,
      seekMaxMs: jsonInt(json['seek_max_ms']),
    );
  }

  // -------------------------------------------------------------------------
  // Binary message handling
  // -------------------------------------------------------------------------

  /// Dispatches a decrypted binary message by message ID and active roles.
  ///
  /// Audio chunks (ID 4) are forwarded to [onAudioFrame] only when the
  /// [SendspinRole.player] role is active. The remaining player IDs (5-7) are
  /// not defined and are ignored. Artwork messages (ID 8-11) go to the
  /// artwork receiver. All other IDs are silently dropped.
  void _dispatchBinary(Uint8List data) {
    if (data.isEmpty || !_activated || _rehandshaking) return;
    final type = data[0];

    if (type >= _binaryTypePlayerMin && type <= _binaryTypePlayerMax) {
      if (type != _binaryTypeAudioChunk) return;
      if (data.length < _audioChunkHeaderSize) return;
      if (!isRoleActive(SendspinRole.player)) return;
      final frame = parseBinaryFrame(data);
      _measureArrivalDelay(frame);
      onAudioFrame?.call(frame);
      return;
    }

    if (type >= _binaryTypeArtworkMin && type <= _binaryTypeArtworkMax) {
      // A client that does not implement the artwork role ignores its IDs.
      if (!roles.contains(SendspinRole.artwork)) return;
      try {
        _artwork.handleMessage(
          data,
          streamActive:
              _artworkStreamActive && isRoleActive(SendspinRole.artwork),
          // An unavailable client discards image data but keeps following
          // the transfer.
          discard: !isAvailable,
        );
      } on ArtworkError catch (e) {
        // Malformed artwork messages and sequences are protocol errors.
        _channel.close('artwork: ${e.message}');
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
    _reportStateIfChanged();
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
  ///
  /// Clock sync starts by itself on the first `server/activate` and pauses
  /// around a re-handshake; outside those points this has no effect, since
  /// `client/time` may not be sent.
  void startClockSync() {
    if (!_activated || _rehandshaking) return;
    _timeBurst.start();
  }

  /// Stops the burst-strategy clock-sync driver.
  void stopClockSync() {
    _timeBurst.stop();
  }

  // -------------------------------------------------------------------------
  // Lifecycle
  // -------------------------------------------------------------------------

  /// Resets the protocol for a new connection.
  ///
  /// Stops all periodic timers and resets the clock so nothing is sent
  /// on the new socket before the server/hello handshake completes.
  void resetForNewConnection() {
    _channel.reset();
    _activateTimer?.cancel();
    _activateTimer = null;
    _handshake = null;
    _helloReceived = false;
    _activated = false;
    _endPairingAttempt();
    _releasePairingRecord();
    _pairingAborted = false;
    _pairingIndex = 0;
    _rehandshaking = false;
    _clockSyncPaused = false;
    _playerStreamActive = false;
    _artworkStreamActive = false;
    _artwork.reset();
    _held.clear();
    _reportedAvailable = null;
    _stateHeld = false;
    _reportedMinBufferMs = null;
    _timeBurst.reset();
    _clock.reset();
    _arrivalDelay.reset();
    // One clean state, with nothing of the old connection left in it.
    _pendingMetadataTimer?.cancel();
    _pendingMetadataTimer = null;
    _pendingMetadata = null;
    _updateState(SendspinPlayerState(
      volume: _state.volume,
      muted: _state.muted,
      outputDelayMs: _state.outputDelayMs,
    ));
  }

  /// Cleans up timers and stream controller.
  void dispose() {
    _channel.reset();
    _stopTimers();
    _artwork.reset();
    _discardMetadata();
    _stateController.close();
  }
}
