// ABOUTME: CPACE-X25519-SHA512, the PAKE behind code-based pairing.
// ABOUTME: Initiator-responder mode with explicit mutual key confirmation.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// A CPace step failed: a bad peer share, or a method used out of order.
class CPaceError implements Exception {
  final String message;
  const CPaceError(this.message);

  @override
  String toString() => 'CPaceError: $message';
}

/// The two CPace roles. In Sendspin the server is the initiator (`A`) and the
/// client the responder (`B`).
enum CPaceRole { initiator, responder }

const DartSha512 _sha512 = DartSha512();
const DartHmac _hmacSha512 = DartHmac(DartSha512());
const DartX25519 _x25519 = DartX25519();

const int _fieldBytes = 32;
const int _sha512BlockBytes = 128;

final List<int> _dsi = ascii.encode('CPace255');
final List<int> _dsiIsk = ascii.encode('CPace255_ISK');
final List<int> _macLabel = ascii.encode('CPaceMac');

// Curve25519 field prime, Montgomery coefficient, and the non-square used by
// Elligator2.
final BigInt _q = (BigInt.one << 255) - BigInt.from(19);
final BigInt _a = BigInt.from(486662);
final BigInt _z = BigInt.two;

Uint8List _hash(List<int> data) =>
    Uint8List.fromList(_sha512.hashSync(data).bytes);

/// `prepend_len`: the length as a little-endian base-128 varint, then data.
List<int> _prependLen(List<int> data) {
  final out = <int>[];
  var length = data.length;
  while (true) {
    out.add(length & 0x7F);
    length >>= 7;
    if (length == 0) break;
    out[out.length - 1] |= 0x80;
  }
  return out..addAll(data);
}

/// `lv_cat`: the concatenation of each part with its length prepended.
List<int> _lvCat(List<List<int>> parts) =>
    [for (final part in parts) ..._prependLen(part)];

BigInt _decodeLittleEndian(List<int> bytes) {
  var value = BigInt.zero;
  for (var i = bytes.length - 1; i >= 0; i--) {
    value = (value << 8) | BigInt.from(bytes[i]);
  }
  return value;
}

Uint8List _encodeLittleEndian(BigInt value) {
  final out = Uint8List(_fieldBytes);
  var v = value;
  final mask = BigInt.from(0xFF);
  for (var i = 0; i < _fieldBytes; i++) {
    out[i] = (v & mask).toInt();
    v >>= 8;
  }
  return out;
}

/// Elligator2 for Curve25519: maps a field element to the u-coordinate of a
/// curve point.
Uint8List _elligator2(BigInt r) {
  final rr = r % _q;
  // inv0: Fermat inversion, which maps 0 to 0.
  final denominator = (BigInt.one + _z * rr * rr) % _q;
  final inverse = denominator.modPow(_q - BigInt.two, _q);
  final v = (-_a * inverse) % _q;
  final eps =
      ((v * v * v + _a * v * v + v) % _q).modPow((_q - BigInt.one) >> 1, _q);
  final inverseOfTwo = BigInt.two.modPow(_q - BigInt.two, _q);
  final x = (eps * v - (BigInt.one - eps) * _a * inverseOfTwo) % _q;
  return _encodeLittleEndian(x);
}

/// The CPace generator for a password [prs] and session id [sid], with an
/// empty channel identifier: the Elligator2 map of a hash of both.
Uint8List cpaceGenerator(List<int> prs, List<int> sid) {
  final zeroPad = max(
      0,
      _sha512BlockBytes -
          1 -
          _prependLen(prs).length -
          _prependLen(_dsi).length);
  final generatorString =
      _lvCat([_dsi, prs, Uint8List(zeroPad), const <int>[], sid]);
  final u = _hash(generatorString).sublist(0, _fieldBytes);
  // A 255-bit field: the unused top bit is ignored.
  u[_fieldBytes - 1] &= 0x7F;
  return _elligator2(_decodeLittleEndian(u));
}

/// X25519 scalar multiplication that rejects a result encoding the identity,
/// which is what a low-order point produces.
Uint8List? _scalarMult(Uint8List scalar, Uint8List point) {
  final secret = _x25519.sharedSecretSync(
    keyPairData: SimpleKeyPairData(scalar,
        publicKey: SimplePublicKey(point, type: KeyPairType.x25519),
        type: KeyPairType.x25519),
    remotePublicKey: SimplePublicKey(point, type: KeyPairType.x25519),
  );
  final bytes = Uint8List.fromList((secret as SecretKeyData).bytes);
  return bytes.every((b) => b == 0) ? null : bytes;
}

/// One side of a CPACE-X25519-SHA512 run
/// ([draft-irtf-cfrg-cpace](https://datatracker.ietf.org/doc/draft-irtf-cfrg-cpace/)).
///
/// Both sides derive a generator from the shared password, exchange one
/// public share each, and arrive at the same intermediate session key only
/// if their passwords and session ids matched. The confirmation tags prove
/// that to each other without revealing the password.
class CPace {
  final CPaceRole role;
  final Uint8List _sid;
  final Uint8List _ad;
  Uint8List? _scalar;

  /// This side's public share (`Ya` or `Yb`), 32 bytes.
  late final Uint8List publicShare;

  Uint8List? _isk;
  Uint8List? _macKey;

  /// (share, associated data) for the initiator, then for the responder.
  List<List<int>> _initiatorSide = const [];
  List<List<int>> _responderSide = const [];

  /// Starts a run. [scalar] pins the secret scalar for known-answer tests;
  /// normally it is omitted and drawn from a CSPRNG.
  CPace({
    required this.role,
    required List<int> prs,
    required List<int> sid,
    List<int> ad = const [],
    Uint8List? scalar,
  })  : _sid = Uint8List.fromList(sid),
        _ad = Uint8List.fromList(ad) {
    final random = Random.secure();
    final secret = scalar == null
        ? Uint8List.fromList(
            List<int>.generate(_fieldBytes, (_) => random.nextInt(256)))
        : Uint8List.fromList(scalar);
    final share = _scalarMult(secret, cpaceGenerator(prs, sid));
    if (share == null) {
      throw const CPaceError('generator encodes a low-order point');
    }
    _scalar = secret;
    publicShare = share;
  }

  /// Takes the peer's public share and associated data, deriving the session
  /// key. Can be called once.
  void derive(Uint8List peerShare, {List<int> peerAd = const []}) {
    final scalar = _scalar;
    if (scalar == null)
      throw const CPaceError('derive may only be called once');
    _scalar = null;
    if (peerShare.length != _fieldBytes) {
      throw const CPaceError('peer share must be 32 bytes');
    }
    final shared = _scalarMult(scalar, peerShare);
    if (shared == null) {
      throw const CPaceError('peer share encodes a low-order point');
    }
    final mine = <List<int>>[publicShare, _ad];
    final theirs = <List<int>>[peerShare, peerAd];
    _initiatorSide = role == CPaceRole.initiator ? mine : theirs;
    _responderSide = role == CPaceRole.initiator ? theirs : mine;

    final transcript = [..._lvCat(_initiatorSide), ..._lvCat(_responderSide)];
    final isk = _hash([
      ..._lvCat([_dsiIsk, _sid, shared]),
      ...transcript
    ]);
    _isk = isk;
    _macKey = _hash([..._macLabel, ..._sid, ...isk]);
  }

  /// The 64-byte intermediate session key.
  Uint8List get isk =>
      _isk ?? (throw const CPaceError('derive must be called first'));

  Uint8List _mac(List<List<int>> side) {
    final key = _macKey;
    if (key == null) throw const CPaceError('derive must be called first');
    return Uint8List.fromList(_hmacSha512.calculateMacSync(_lvCat(side),
        secretKeyData: SecretKeyData(key), nonce: const []).bytes);
  }

  /// This side's confirmation tag: `Ta` for the initiator, `Tb` for the
  /// responder. 64 bytes.
  Uint8List tag() {
    _requireDerived();
    return _mac(role == CPaceRole.initiator ? _initiatorSide : _responderSide);
  }

  void _requireDerived() {
    if (_macKey == null) throw const CPaceError('derive must be called first');
  }

  /// Whether [peerTag] proves the peer derived the same key, and so knew the
  /// same password. Compared in constant time.
  bool verify(Uint8List peerTag) {
    _requireDerived();
    final expected =
        _mac(role == CPaceRole.initiator ? _responderSide : _initiatorSide);
    // A reflected share would make the expected peer tag equal our own.
    if (_same(_initiatorSide[0], _responderSide[0]) &&
        _same(_initiatorSide[1], _responderSide[1])) {
      return false;
    }
    if (peerTag.length != expected.length) return false;
    var difference = 0;
    for (var i = 0; i < expected.length; i++) {
      difference |= expected[i] ^ peerTag[i];
    }
    return difference == 0;
  }

  static bool _same(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
