// ABOUTME: Derivations for code-based pairing: the dynamic pairing code,
// ABOUTME: the commitment, the PAKE session id and value wrapping.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'pairing.dart';

const DartSha256 _sha256 = DartSha256();
const DartChacha20 _chachaPoly = DartChacha20.poly1305Aead();

Uint8List _hash(List<int> data) =>
    Uint8List.fromList(_sha256.hashSync(data).bytes);

/// Labels that separate the two values wrapped under the CPace output.
const String pskWrapLabel = 'sendspin-pair-psk-wrap-v1';
const String nonceWrapLabel = 'sendspin-pair-nonce-wrap-v1';

/// `commit_B = SHA-256("sendspin-pair-commit-v1" || nonce_B)`: the client's
/// commitment to its nonce, sent before it learns anything from the server.
Uint8List pairingCommit(List<int> nonceB) =>
    _hash([...ascii.encode('sendspin-pair-commit-v1'), ...nonceB]);

/// The six decimal digits for [value], zero-padded on the left.
String formatPairingDigits(BigInt value) =>
    (value % BigInt.from(1000000)).toString().padLeft(6, '0');

/// Groups a pairing code for display: `123-456` for six digits, `1234-5678`
/// for eight. Grouping is presentation only; the code is the bare digits.
String groupPairingDigits(String digits) {
  final half = digits.length ~/ 2;
  return '${digits.substring(0, half)}-${digits.substring(half)}';
}

/// The per-session pairing code of the Dynamic Pairing Code flow, in both
/// emission formats. Both come from one digest of the Noise handshake hash
/// and the two nonces, which is what binds the code to this connection.
class DynamicPairingCode {
  /// The `digits` format: six decimal digits for the operator to type.
  final String digits;

  /// The `qr_code` format: 24 raw bytes.
  final Uint8List qrCode;

  DynamicPairingCode._(this.digits, this.qrCode);

  factory DynamicPairingCode.derive({
    required List<int> handshakeHash,
    required List<int> nonceA,
    required List<int> nonceB,
  }) {
    final digest = _hash([
      ...ascii.encode('sendspin-pairing-code-derive-v1'),
      ...handshakeHash,
      ...nonceA,
      ...nonceB,
    ]);
    var value = BigInt.zero;
    for (final byte in digest) {
      value = (value << 8) | BigInt.from(byte);
    }
    return DynamicPairingCode._(
        formatPairingDigits(value), Uint8List.sublistView(digest, 0, 24));
  }

  /// The QR code's content: a version-1 pairing token (`SP:1...`).
  String get qrToken => encodePairingCodeToken(qrCode);
}

/// The CPace session id: the label, the Noise handshake hash, and the
/// pairing index and round as big-endian 32-bit integers.
Uint8List pakeSid({
  required List<int> handshakeHash,
  required int pairingIndex,
  required int round,
}) {
  final counters = ByteData(8)
    ..setUint32(0, pairingIndex, Endian.big)
    ..setUint32(4, round, Endian.big);
  return Uint8List.fromList([
    ...ascii.encode('sendspin-pair-pake-v1'),
    ...handshakeHash,
    ...counters.buffer.asUint8List(),
  ]);
}

SecretKeyData _wrapKey(String label, List<int> sid, List<int> isk) =>
    SecretKeyData(_hash([...ascii.encode(label), ...sid, ...isk]));

/// Seals a 32-byte [value] under the CPace output:
/// `K_wrap = SHA-256(label || sid || ISK)`, ChaCha20-Poly1305 with an
/// all-zero nonce and no associated data. Each key wraps exactly one value,
/// so the fixed nonce is never reused. Returns 48 bytes.
Uint8List wrapPairingValue({
  required String label,
  required List<int> sid,
  required List<int> isk,
  required List<int> value,
}) {
  final box = _chachaPoly.encryptSync(value,
      secretKey: _wrapKey(label, sid, isk), nonce: Uint8List(12));
  return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
}

/// Opens a value sealed by [wrapPairingValue], or returns null if it does
/// not authenticate.
Uint8List? unwrapPairingValue({
  required String label,
  required List<int> sid,
  required List<int> isk,
  required Uint8List wrapped,
}) {
  if (wrapped.length < 16) return null;
  final split = wrapped.length - 16;
  try {
    return Uint8List.fromList(_chachaPoly.decryptSync(
      SecretBox(Uint8List.sublistView(wrapped, 0, split),
          nonce: Uint8List(12),
          mac: Mac(Uint8List.sublistView(wrapped, split))),
      secretKey: _wrapKey(label, sid, isk),
    ));
  } on SecretBoxAuthenticationError {
    return null;
  }
}
