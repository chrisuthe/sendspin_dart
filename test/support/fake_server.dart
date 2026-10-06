import 'dart:convert';
import 'dart:typed_data';

import 'package:sendspin_dart/src/encoding.dart';
import 'package:sendspin_dart/src/framing.dart';
import 'package:sendspin_dart/src/noise.dart';
import 'package:sendspin_dart/src/psk.dart';

/// A minimal Sendspin server for tests: the Noise initiator side of the
/// handshake plus encrypted framing. It talks to the client under test
/// through [deliverText] / [deliverBinary] and is fed with [receiveText] /
/// [receiveBinary].
class FakeServer {
  final Uint8List staticPrivateKey;

  /// The PSK the next handshake references, and the category it claims.
  Uint8List psk;
  String pskCategory;

  /// Sends a WebSocket text / binary message to the client.
  void Function(String text)? deliverText;
  void Function(Uint8List data)? deliverBinary;

  /// When set, sent in place of the real `server/init`.
  String? serverInitOverride;

  /// When set, hashed into the prologue instead of the `server/init` actually
  /// sent, as if the message had been altered in transit.
  String? prologueServerInitOverride;

  /// Overrides the JSON payload carried inside Noise message 1.
  String? message1PayloadOverride;

  /// When false, `server/init` is sent but Noise message 1 is withheld.
  bool sendMessage1 = true;

  /// Every cleartext text message the client sent.
  final List<String> receivedText = [];

  /// Every decrypted JSON message the client sent, in order.
  final List<Map<String, dynamic>> receivedJson = [];

  /// Every decrypted non-JSON binary message the client sent.
  final List<Uint8List> receivedBinary = [];

  /// The transport messages the client sent, before decryption.
  final List<Uint8List> receivedCiphertext = [];

  /// Set when the client's message 2 only verified under the Sentinel PSK.
  bool sawSentinelFallback = false;

  NoiseHandshake? _handshake;
  NoiseSession? _session;
  Uint8List? _clientPublicKey;
  final MessageReassembler _reassembler = MessageReassembler();

  FakeServer({Uint8List? staticPrivateKey, Uint8List? psk, String? pskCategory})
      : staticPrivateKey = staticPrivateKey ??
            Uint8List.fromList(List<int>.generate(32, (i) => 200 - i)),
        psk = psk ?? sentinelPsk,
        pskCategory = pskCategory ?? 'sn';

  String get serverId => base64UrlNoPad(x25519PublicKey(staticPrivateKey));

  bool get isEstablished => _session != null;

  Uint8List get handshakeHash => _session!.handshakeHash;

  String get _serverInit => jsonEncode({
        'type': 'server/init',
        'payload': {'server_id': serverId, 'version': 1},
      });

  String _message1Payload() =>
      message1PayloadOverride ??
      jsonEncode({'psk_id': pskIdOf(psk), 'psk_category': pskCategory});

  static String _handshakeMessage(Uint8List data) => jsonEncode({
        'type': 'noise/handshake',
        'payload': {'data': base64UrlNoPad(data)},
      });

  /// Feeds a cleartext text message from the client.
  void receiveText(String text) {
    receivedText.add(text);
    final message = jsonDecode(text) as Map<String, dynamic>;
    final payload = message['payload'] as Map<String, dynamic>;
    switch (message['type']) {
      case 'client/init':
        _clientPublicKey = base64UrlNoPadDecode(payload['client_id'] as String);
        final serverInit = serverInitOverride ?? _serverInit;
        deliverText?.call(serverInit);
        if (!sendMessage1) return;
        _handshake = NoiseHandshake.initiator(
          staticPrivateKey: staticPrivateKey,
          remoteStaticPublicKey: _clientPublicKey!,
          prologue: Uint8List.fromList(
              utf8.encode(text + (prologueServerInitOverride ?? serverInit))),
        );
        deliverText?.call(_handshakeMessage(_handshake!.writeMessage1(
            Uint8List.fromList(utf8.encode(_message1Payload())))));
      case 'noise/handshake':
        _finishHandshake(base64UrlNoPadDecode(payload['data'] as String)!);
    }
  }

  void _finishHandshake(Uint8List message2) {
    final handshake = _handshake!;
    try {
      handshake.readMessage2(message2, psk);
    } on NoiseError {
      // Same check a real server makes: retry under the Sentinel PSK.
      handshake.readMessage2(message2, sentinelPsk);
      sawSentinelFallback = true;
    }
    _session = handshake.session;
    _handshake = null;
  }

  /// Feeds an encrypted binary message from the client.
  void receiveBinary(Uint8List data) {
    receivedCiphertext.add(data);
    final message = _reassembler.add(_session!.decrypt(data));
    if (message == null) return;
    if (message[0] != messageIdJson) {
      receivedBinary.add(message);
      return;
    }
    final json = jsonDecode(utf8.decode(Uint8List.sublistView(message, 1)))
        as Map<String, dynamic>;
    if (json['type'] == 'noise/handshake' && _handshake != null) {
      // Message 2 of a re-handshake travels under the old keys.
      _finishHandshake(base64UrlNoPadDecode(
          (json['payload'] as Map<String, dynamic>)['data'] as String)!);
      return;
    }
    receivedJson.add(json);
  }

  /// Encrypts and sends one binary message (ID byte followed by payload),
  /// fragmenting if needed.
  void sendMessage(Uint8List message) {
    for (final frame in fragmentMessage(message)) {
      sendFrame(frame);
    }
  }

  /// Encrypts and sends [frame] as a single transport message, bypassing
  /// fragmentation, so tests can build malformed sequences.
  void sendFrame(Uint8List frame) =>
      deliverBinary?.call(_session!.encrypt(frame));

  void sendJsonText(String json) =>
      sendMessage(Uint8List.fromList([messageIdJson, ...utf8.encode(json)]));

  void sendJson(String type, [Map<String, dynamic> payload = const {}]) =>
      sendJsonText(jsonEncode({'type': type, 'payload': payload}));

  /// Starts an in-band re-handshake to [newPsk]: Noise message 1 goes out as
  /// an encrypted JSON message and the prologue is the current handshake
  /// hash.
  void startRehandshake(Uint8List newPsk, String category) {
    psk = newPsk;
    pskCategory = category;
    _handshake = NoiseHandshake.initiator(
      staticPrivateKey: staticPrivateKey,
      remoteStaticPublicKey: _clientPublicKey!,
      prologue: _session!.handshakeHash,
    );
    sendJsonText(_handshakeMessage(_handshake!
        .writeMessage1(Uint8List.fromList(utf8.encode(_message1Payload())))));
  }
}
