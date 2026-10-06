// ABOUTME: The encrypted Sendspin channel: client/init, Noise KKpsk2
// ABOUTME: handshake and re-handshake, and encrypted binary message framing.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'encoding.dart';
import 'framing.dart';
import 'identity.dart';
import 'noise.dart';
import 'psk.dart';

/// The outcome of a Noise handshake, initial or in-band.
class SendspinHandshakeResult {
  /// The server's static public key, base64url (from `server/init`).
  final String serverId;

  /// The category of the PSK the handshake completed with. Only
  /// [SendspinPskCategory.longTerm] is a paired session.
  final SendspinPskCategory matchedCategory;

  /// The PSK the handshake completed with.
  final Uint8List matchedPsk;

  /// True when the server referenced a PSK this client does not hold and the
  /// handshake was completed with the Sentinel PSK instead.
  final bool sentinelFallback;

  /// The Noise handshake hash `h`, shared by both sides.
  final Uint8List handshakeHash;

  /// True for an in-band re-handshake on an already encrypted connection.
  final bool isRehandshake;

  const SendspinHandshakeResult({
    required this.serverId,
    required this.matchedCategory,
    required this.matchedPsk,
    required this.sentinelFallback,
    required this.handshakeHash,
    required this.isRehandshake,
  });
}

enum _Phase { idle, awaitingServerInit, awaitingMessage1, transport, closed }

/// The transport security layer of a Sendspin connection.
///
/// Drives the cleartext opening (`client/init`, `server/init`, the two
/// `noise/handshake` messages), then carries every message as a Noise
/// transport message whose first decrypted byte is the binary message ID:
/// JSON is ID 0 and oversized messages are fragmented as ID 1.
///
/// The channel has no socket. Wire [onSendText] / [onSendBinary] to the
/// WebSocket, feed it with [handleText] / [handleBinary], and close the
/// socket when [onClose] fires.
class SendspinChannel {
  /// The only cipher suite this client implements.
  static const String suite = '25519_ChaChaPoly_SHA256';

  final SendspinIdentity identity;

  /// How long to wait for each expected message of the opening handshake.
  final Duration handshakeTimeout;

  final List<SendspinPskCandidate> Function()? _pskCandidates;

  /// Sends a cleartext WebSocket text message (handshake only).
  void Function(String text)? onSendText;

  /// Sends a WebSocket binary message holding one Noise transport message.
  void Function(Uint8List data)? onSendBinary;

  /// A decrypted JSON message: an object with a `type` string and a
  /// `payload` object. `noise/handshake` is handled here and not passed on.
  void Function(Map<String, dynamic> message)? onJson;

  /// A decrypted, reassembled binary message with an ID other than 0 or 1.
  /// Byte 0 is the message ID.
  void Function(Uint8List message)? onBinary;

  /// A handshake completed and the channel is in transport mode under the
  /// keys it produced.
  void Function(SendspinHandshakeResult result)? onHandshakeComplete;

  /// The server began an in-band re-handshake. No new application message
  /// may be sent until the `server/activate` that follows it.
  void Function()? onRehandshakeStarted;

  /// The server refused `client/init` with `server/error`. [onClose] follows.
  void Function(String reason)? onServerError;

  /// The connection must be closed. [reason] is for logging only: every
  /// failure here is silent on the wire.
  void Function(String reason)? onClose;

  _Phase _phase = _Phase.idle;
  Timer? _timeout;
  String? _clientInit;
  String? _serverInit;
  String? _serverId;
  Uint8List? _serverPublicKey;
  NoiseSession? _session;
  final MessageReassembler _reassembler = MessageReassembler();

  SendspinChannel({
    required this.identity,
    List<SendspinPskCandidate> Function()? pskCandidates,
    this.handshakeTimeout = const Duration(seconds: 30),
  }) : _pskCandidates = pskCandidates;

  /// Whether the handshake has completed and messages can be sent.
  bool get isEstablished => _phase == _Phase.transport;

  /// The server's id, once `server/init` has been accepted.
  String? get serverId => _serverId;

  /// Begins a connection by sending `client/init`.
  void start() {
    if (_phase != _Phase.idle) {
      throw StateError('Channel already started; call reset() first');
    }
    final clientInit = jsonEncode({
      'type': 'client/init',
      'payload': {
        'client_id': identity.clientId,
        'version': 1,
        'suite': suite,
      },
    });
    _clientInit = clientInit;
    _phase = _Phase.awaitingServerInit;
    _armTimeout();
    onSendText?.call(clientInit);
  }

  /// Returns the channel to its initial state for a new connection.
  void reset() {
    _timeout?.cancel();
    _timeout = null;
    _phase = _Phase.idle;
    _clientInit = null;
    _serverInit = null;
    _serverId = null;
    _serverPublicKey = null;
    _session = null;
    _reassembler.reset();
  }

  void _armTimeout() {
    _timeout?.cancel();
    _timeout = Timer(handshakeTimeout, () => _fail('handshake timeout'));
  }

  /// Closes without sending anything further.
  void _fail(String reason) {
    if (_phase == _Phase.closed) return;
    _timeout?.cancel();
    _timeout = null;
    _phase = _Phase.closed;
    _session = null;
    _reassembler.reset();
    onClose?.call(reason);
  }

  // ---------------------------------------------------------------------
  // Inbound
  // ---------------------------------------------------------------------

  /// Handles a WebSocket text message. Text is only valid during the
  /// cleartext opening.
  void handleText(String text) {
    switch (_phase) {
      case _Phase.awaitingServerInit:
        _handleServerInit(text);
      case _Phase.awaitingMessage1:
        final message = _decodeMessage(text);
        final data = message?['type'] == 'noise/handshake'
            ? _handshakeData(message!)
            : null;
        if (data == null) return _fail('expected noise/handshake');
        _respondToMessage1(data,
            prologue: _initialPrologue(), isRehandshake: false);
      case _Phase.transport:
        _fail('cleartext message in transport mode');
      case _Phase.idle:
      case _Phase.closed:
        break;
    }
  }

  /// Handles a WebSocket binary message: one Noise transport message.
  void handleBinary(Uint8List data) {
    if (_phase == _Phase.closed || _phase == _Phase.idle) return;
    final session = _session;
    if (_phase != _Phase.transport || session == null) {
      return _fail('binary message before transport mode');
    }

    final Uint8List? message;
    try {
      message = _reassembler.add(session.decrypt(data));
    } on NoiseError catch (e) {
      return _fail(e.message);
    } on FramingError catch (e) {
      return _fail(e.message);
    }
    if (message == null) return;

    if (message[0] != messageIdJson) {
      onBinary?.call(message);
      return;
    }

    final Map<String, dynamic>? json;
    try {
      json = _decodeMessage(utf8.decode(Uint8List.sublistView(message, 1)));
    } on FormatException {
      return;
    }
    // Anything that is not a typed message object is ignored.
    if (json == null) return;

    if (json['type'] == 'noise/handshake') {
      final handshakeData = _handshakeData(json);
      if (handshakeData == null) return _fail('malformed noise/handshake');
      onRehandshakeStarted?.call();
      // The callback may have reset or closed the channel.
      if (_session != session) return;
      _respondToMessage1(handshakeData,
          prologue: session.handshakeHash, isRehandshake: true);
      return;
    }
    onJson?.call(json);
  }

  /// Parses [text] as `{"type": String, "payload": Object}`, or null.
  static Map<String, dynamic>? _decodeMessage(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['type'] is! String ||
        decoded['payload'] is! Map<String, dynamic>) {
      return null;
    }
    return decoded;
  }

  static Uint8List? _handshakeData(Map<String, dynamic> message) {
    final data = (message['payload'] as Map<String, dynamic>)['data'];
    return data is String ? base64UrlNoPadDecode(data) : null;
  }

  void _handleServerInit(String text) {
    final message = _decodeMessage(text);
    if (message == null) return _fail('malformed server/init');
    final payload = message['payload'] as Map<String, dynamic>;

    if (message['type'] == 'server/error') {
      final reason = payload['reason'];
      onServerError?.call(reason is String ? reason : 'unknown');
      // The callback may have reset the channel for a new attempt.
      if (_phase != _Phase.awaitingServerInit) return;
      return _fail('server/error');
    }
    if (message['type'] != 'server/init') {
      return _fail('expected server/init');
    }
    // `version` names the single core format the sender speaks: an integer,
    // exact match.
    final version = payload['version'];
    if (version is! int || version != 1) {
      return _fail('unsupported server version');
    }

    final serverId = payload['server_id'];
    final publicKey =
        serverId is String ? base64UrlNoPadDecode(serverId) : null;
    if (publicKey == null || publicKey.length != SendspinIdentity.keyLength) {
      return _fail('malformed server_id');
    }
    _serverId = serverId as String;
    _serverPublicKey = publicKey;
    // The prologue is the bytes of both init messages exactly as sent and
    // received, so keep the text rather than re-encoding the parsed form.
    _serverInit = text;
    _phase = _Phase.awaitingMessage1;
    _armTimeout();
  }

  Uint8List _initialPrologue() =>
      Uint8List.fromList(utf8.encode(_clientInit! + _serverInit!));

  /// Reads Noise message 1, selects the PSK it references, and answers with
  /// message 2. Used for both the initial handshake and a re-handshake.
  void _respondToMessage1(
    Uint8List message1, {
    required Uint8List prologue,
    required bool isRehandshake,
  }) {
    final handshake = NoiseHandshake.responder(
      staticPrivateKey: identity.privateKey,
      remoteStaticPublicKey: _serverPublicKey!,
      prologue: prologue,
    );

    final Uint8List payloadBytes;
    try {
      payloadBytes = handshake.readMessage1(message1);
    } on NoiseError catch (e) {
      return _fail(e.message);
    }

    // Message 1's payload is readable without the PSK; it says which one the
    // server is using.
    final Object? payload;
    try {
      payload = jsonDecode(utf8.decode(payloadBytes));
    } on FormatException {
      return _fail('malformed handshake payload');
    }
    final pskId = payload is Map<String, dynamic> ? payload['psk_id'] : null;
    final category = payload is Map<String, dynamic>
        ? SendspinPskCategory.fromWire(payload['psk_category'])
        : null;
    if (pskId is! String || pskId.length != 43 || category == null) {
      return _fail('malformed handshake payload');
    }

    var matchedCategory = category;
    var sentinelFallback = false;
    Uint8List? psk;
    if (category == SendspinPskCategory.sentinel) {
      if (pskId == pskIdOf(sentinelPsk)) psk = sentinelPsk;
    } else {
      final List<SendspinPskCandidate> candidates;
      try {
        candidates = _pskCandidates?.call() ?? const [];
      } catch (_) {
        return _fail('PSK lookup failed');
      }
      for (final candidate in candidates) {
        if (candidate.category != category || pskIdOf(candidate.psk) != pskId) {
          continue;
        }
        // A long-term PSK is bound to the server it was paired with. A
        // different server presenting it is a misbinding, not a miss.
        if (category == SendspinPskCategory.longTerm &&
            candidate.serverId != _serverId) {
          return _fail('long-term PSK belongs to another server');
        }
        psk = candidate.psk;
        break;
      }
    }
    if (psk == null) {
      // Sentinel Fallback applies to the initial handshake only.
      if (isRehandshake) return _fail('unknown psk_id in re-handshake');
      psk = sentinelPsk;
      matchedCategory = SendspinPskCategory.sentinel;
      sentinelFallback = true;
    }

    // Message 2's payload is the literal two bytes `{}`.
    final message2 = jsonEncode({
      'type': 'noise/handshake',
      'payload': {
        'data': base64UrlNoPad(handshake.writeMessage2(
            Uint8List.fromList(const [0x7B, 0x7D]), psk)),
      },
    });

    // Switch to the new keys before anything is handed to the transport: a
    // send callback may deliver the server's next message, or reset or close
    // the channel, before it returns.
    final previous = _session;
    final session = handshake.session;
    final List<Uint8List>? underOldKeys = isRehandshake
        // Message 2 of a re-handshake still travels under the previous keys.
        ? _encrypt(previous!, _jsonMessage(message2))
        : null;
    _timeout?.cancel();
    _timeout = null;
    _session = session;
    _phase = _Phase.transport;

    // Report the new keys first, so whatever the server sends next is
    // judged against the PSK this handshake matched.
    onHandshakeComplete?.call(SendspinHandshakeResult(
      serverId: _serverId!,
      matchedCategory: matchedCategory,
      matchedPsk: Uint8List.fromList(psk),
      sentinelFallback: sentinelFallback,
      handshakeHash: session.handshakeHash,
      isRehandshake: isRehandshake,
    ));
    // The callback may have reset or closed the channel.
    if (_session != session) return;

    if (underOldKeys != null) {
      underOldKeys.forEach(_emitBinary);
    } else {
      onSendText?.call(message2);
    }
  }

  // ---------------------------------------------------------------------
  // Outbound
  // ---------------------------------------------------------------------

  static Uint8List _jsonMessage(String json) {
    final body = utf8.encode(json);
    return Uint8List(body.length + 1)
      ..[0] = messageIdJson
      ..setRange(1, body.length + 1, body);
  }

  static List<Uint8List> _encrypt(NoiseSession session, Uint8List message) =>
      [for (final frame in fragmentMessage(message)) session.encrypt(frame)];

  void _emitBinary(Uint8List data) {
    if (_phase == _Phase.transport) onSendBinary?.call(data);
  }

  /// Sends a JSON message body as an encrypted binary message with ID 0.
  void sendJsonText(String json) => _send(_jsonMessage(json));

  /// Sends a binary message whose first byte is its message ID. Fragment
  /// messages (ID 1) are produced here and cannot be sent directly.
  void sendBinary(Uint8List message) {
    if (message.isEmpty || message[0] == messageIdFragment) {
      throw ArgumentError('A binary message starts with an ID other than 1');
    }
    _send(message);
  }

  void _send(Uint8List message) {
    if (_phase == _Phase.closed) return;
    final session = _session;
    if (_phase != _Phase.transport || session == null) {
      throw StateError('Channel is not in transport mode');
    }
    _encrypt(session, message).forEach(_emitBinary);
  }
}
