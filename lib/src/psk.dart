// ABOUTME: Pre-shared keys for the Noise handshake: categories, ids, Sentinel.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/dart.dart';

import 'encoding.dart';

const DartSha256 _sha256 = DartSha256();

/// The category a PSK is used as, declared by the server in Noise message 1.
enum SendspinPskCategory {
  /// A long-term PSK from a pairing record: a paired session.
  longTerm('lt'),

  /// The client's pairing PSK.
  pairing('pr'),

  /// The published Sentinel PSK, used when no other PSK applies.
  sentinel('sn');

  final String wireValue;
  const SendspinPskCategory(this.wireValue);

  static SendspinPskCategory? fromWire(Object? value) {
    for (final c in values) {
      if (c.wireValue == value) return c;
    }
    return null;
  }
}

/// The Sentinel PSK: `SHA-256("sendspin-sentinel-psk-v1")`. It is a published
/// constant and authenticates nothing on its own.
final Uint8List sentinelPsk = Uint8List.fromList(
    _sha256.hashSync(ascii.encode('sendspin-sentinel-psk-v1')).bytes);

/// `psk_id = base64url(SHA-256("sendspin-psk-id-v1" || PSK))`, 43 characters.
String pskIdOf(List<int> psk) => base64UrlNoPad(
    _sha256.hashSync([...ascii.encode('sendspin-psk-id-v1'), ...psk]).bytes);

/// A PSK the client is willing to complete a handshake with.
class SendspinPskCandidate {
  final SendspinPskCategory category;
  final Uint8List psk;

  /// For a long-term PSK, the `server_id` stored in its pairing record. The
  /// handshake fails if the server presenting this PSK has a different id.
  final String? serverId;

  SendspinPskCandidate.longTerm(
      {required this.psk, required String this.serverId})
      : category = SendspinPskCategory.longTerm;

  SendspinPskCandidate.pairing(this.psk)
      : category = SendspinPskCategory.pairing,
        serverId = null;
}
