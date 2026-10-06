// ABOUTME: Noise_KKpsk2_25519_ChaChaPoly_SHA256 handshake and transport.
// ABOUTME: Pure state machine with no I/O; the channel layer drives it.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

/// A Noise handshake or transport failure: a message that does not
/// authenticate, is malformed, or arrives out of order. Per the Sendspin spec
/// these are silent failures: the connection is closed without a reply.
class NoiseError implements Exception {
  final String message;
  const NoiseError(this.message);

  @override
  String toString() => 'NoiseError: $message';
}

const int _keyLength = 32;
const int _tagLength = 16;

const DartSha256 _sha256 = DartSha256();
const DartHmac _hmac = DartHmac(DartSha256());
const DartX25519 _x25519 = DartX25519();
const DartChacha20 _chachaPoly = DartChacha20.poly1305Aead();

Uint8List _hash(List<int> data) =>
    Uint8List.fromList(_sha256.hashSync(data).bytes);

Uint8List _hmacSha256(List<int> key, List<int> data) =>
    Uint8List.fromList(_hmac.calculateMacSync(data,
        secretKeyData: SecretKeyData(key), nonce: const []).bytes);

Uint8List _concat(List<int> a, List<int> b) => Uint8List(a.length + b.length)
  ..setRange(0, a.length, a)
  ..setRange(a.length, a.length + b.length, b);

SimplePublicKey _publicKey(List<int> bytes) =>
    SimplePublicKey(bytes, type: KeyPairType.x25519);

final SimplePublicKey _basePoint = _publicKey(Uint8List(_keyLength)..[0] = 9);

Uint8List _dh(Uint8List privateKey, Uint8List publicKey) {
  final secret = _x25519.sharedSecretSync(
    keyPairData: SimpleKeyPairData(privateKey,
        publicKey: _basePoint, type: KeyPairType.x25519),
    remotePublicKey: _publicKey(publicKey),
  );
  return Uint8List.fromList((secret as SecretKeyData).bytes);
}

/// The Curve25519 public key for [privateKey].
Uint8List x25519PublicKey(Uint8List privateKey) {
  final base = Uint8List(_keyLength)..[0] = 9;
  return _dh(privateKey, base);
}

/// One direction's AEAD key and message counter.
class _CipherState {
  Uint8List? key;
  int nonce = 0;

  _CipherState([this.key]);

  _CipherState copy() => _CipherState(key)..nonce = nonce;

  // ChaChaPoly nonce: 32 zero bits followed by the little-endian counter.
  Uint8List _nonceBytes() =>
      Uint8List(12)..buffer.asByteData().setUint64(4, nonce, Endian.little);

  Uint8List encrypt(List<int> ad, List<int> plaintext) {
    final k = key;
    if (k == null) return Uint8List.fromList(plaintext);
    final box = _chachaPoly.encryptSync(
      plaintext,
      secretKey: SecretKeyData(k),
      nonce: _nonceBytes(),
      aad: ad,
    );
    nonce++;
    return _concat(box.cipherText, box.mac.bytes);
  }

  Uint8List decrypt(List<int> ad, Uint8List ciphertext) {
    final k = key;
    if (k == null) return Uint8List.fromList(ciphertext);
    if (ciphertext.length < _tagLength) {
      throw const NoiseError('message shorter than the AEAD tag');
    }
    final split = ciphertext.length - _tagLength;
    final List<int> plaintext;
    try {
      plaintext = _chachaPoly.decryptSync(
        SecretBox(
          Uint8List.sublistView(ciphertext, 0, split),
          nonce: _nonceBytes(),
          mac: Mac(Uint8List.sublistView(ciphertext, split)),
        ),
        secretKey: SecretKeyData(k),
        aad: ad,
      );
    } on SecretBoxAuthenticationError {
      throw const NoiseError('AEAD authentication failed');
    }
    nonce++;
    return Uint8List.fromList(plaintext);
  }
}

/// Noise SymmetricState: chaining key, handshake hash and handshake cipher.
class _SymmetricState {
  Uint8List ck;
  Uint8List h;
  final _CipherState cipher;

  _SymmetricState(this.ck, this.h, this.cipher);

  factory _SymmetricState.named(String protocolName) {
    final name = ascii.encode(protocolName);
    // Names up to the hash length are zero-padded; longer ones are hashed.
    final h = name.length <= _keyLength
        ? (Uint8List(_keyLength)..setRange(0, name.length, name))
        : _hash(name);
    return _SymmetricState(h, Uint8List.fromList(h), _CipherState());
  }

  _SymmetricState copy() => _SymmetricState(
      Uint8List.fromList(ck), Uint8List.fromList(h), cipher.copy());

  void mixHash(List<int> data) => h = _hash(_concat(h, data));

  /// HKDF with the chaining key as salt, producing [count] 32-byte outputs.
  List<Uint8List> _hkdf(List<int> inputKeyMaterial, int count) {
    final tempKey = _hmacSha256(ck, inputKeyMaterial);
    final outputs = <Uint8List>[];
    var previous = Uint8List(0);
    for (var i = 1; i <= count; i++) {
      previous = _hmacSha256(tempKey, _concat(previous, [i]));
      outputs.add(previous);
    }
    return outputs;
  }

  void mixKey(List<int> inputKeyMaterial) {
    final out = _hkdf(inputKeyMaterial, 2);
    ck = out[0];
    cipher
      ..key = out[1]
      ..nonce = 0;
  }

  void mixKeyAndHash(List<int> inputKeyMaterial) {
    final out = _hkdf(inputKeyMaterial, 3);
    ck = out[0];
    mixHash(out[1]);
    cipher
      ..key = out[2]
      ..nonce = 0;
  }

  Uint8List encryptAndHash(List<int> plaintext) {
    final ciphertext = cipher.encrypt(h, plaintext);
    mixHash(ciphertext);
    return ciphertext;
  }

  Uint8List decryptAndHash(Uint8List ciphertext) {
    final plaintext = cipher.decrypt(h, ciphertext);
    mixHash(ciphertext);
    return plaintext;
  }

  /// Derives the two transport keys; the first is the initiator's send key.
  List<Uint8List> split() => _hkdf(const [], 2);
}

enum _Step { message1, message2, done }

/// A Noise `KKpsk2` handshake.
///
/// ```
/// KKpsk2:
///   -> s
///   <- s
///   ...
///   -> e, es, ss
///   <- e, ee, se, psk
/// ```
///
/// Both static keys are known in advance. The PSK is only mixed in at the end
/// of message 2, so the responder can read message 1's payload first and use
/// it to choose the PSK before writing message 2. In Sendspin the server is
/// always the initiator and the client the responder.
class NoiseHandshake {
  static const String protocolName = 'Noise_KKpsk2_25519_ChaChaPoly_SHA256';

  final bool _isInitiator;
  final Uint8List _staticPrivate;
  final Uint8List _remoteStaticPublic;
  final Uint8List _ephemeralPrivate;
  late final Uint8List _ephemeralPublic = x25519PublicKey(_ephemeralPrivate);

  _SymmetricState _state;
  Uint8List? _remoteEphemeralPublic;
  _Step _step = _Step.message1;
  NoiseSession? _session;

  NoiseHandshake._(
    this._isInitiator, {
    required Uint8List staticPrivateKey,
    required Uint8List remoteStaticPublicKey,
    required Uint8List prologue,
    Uint8List? ephemeralPrivateKey,
  })  : _staticPrivate = Uint8List.fromList(staticPrivateKey),
        _remoteStaticPublic = Uint8List.fromList(remoteStaticPublicKey),
        _ephemeralPrivate = ephemeralPrivateKey == null
            ? _randomKey()
            : Uint8List.fromList(ephemeralPrivateKey),
        _state = _SymmetricState.named(protocolName) {
    if (_staticPrivate.length != _keyLength ||
        _remoteStaticPublic.length != _keyLength ||
        _ephemeralPrivate.length != _keyLength) {
      throw ArgumentError('Noise keys must be $_keyLength bytes');
    }
    _state.mixHash(prologue);
    // Pre-messages: the initiator's static key, then the responder's.
    final localStaticPublic = x25519PublicKey(_staticPrivate);
    _state.mixHash(_isInitiator ? localStaticPublic : _remoteStaticPublic);
    _state.mixHash(_isInitiator ? _remoteStaticPublic : localStaticPublic);
  }

  /// The initiating side (the Sendspin server).
  ///
  /// [ephemeralPrivateKey] pins the ephemeral key for known-answer tests; in
  /// normal use it is omitted and drawn from a CSPRNG.
  NoiseHandshake.initiator({
    required Uint8List staticPrivateKey,
    required Uint8List remoteStaticPublicKey,
    required Uint8List prologue,
    Uint8List? ephemeralPrivateKey,
  }) : this._(
          true,
          staticPrivateKey: staticPrivateKey,
          remoteStaticPublicKey: remoteStaticPublicKey,
          prologue: prologue,
          ephemeralPrivateKey: ephemeralPrivateKey,
        );

  /// The responding side (the Sendspin client).
  NoiseHandshake.responder({
    required Uint8List staticPrivateKey,
    required Uint8List remoteStaticPublicKey,
    required Uint8List prologue,
    Uint8List? ephemeralPrivateKey,
  }) : this._(
          false,
          staticPrivateKey: staticPrivateKey,
          remoteStaticPublicKey: remoteStaticPublicKey,
          prologue: prologue,
          ephemeralPrivateKey: ephemeralPrivateKey,
        );

  static Uint8List _randomKey() {
    final random = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(_keyLength, (_) => random.nextInt(256)));
  }

  void _expect(bool initiator, _Step step) {
    if (_isInitiator != initiator || _step != step) {
      throw StateError('Noise handshake message used out of order');
    }
  }

  static void _checkPsk(Uint8List psk) {
    if (psk.length != _keyLength) {
      throw ArgumentError.value(
          psk.length, 'psk.length', 'A Noise PSK is $_keyLength bytes');
    }
  }

  /// Initiator: `-> e, es, ss` carrying [payload].
  Uint8List writeMessage1(Uint8List payload) {
    _expect(true, _Step.message1);
    _state.mixHash(_ephemeralPublic);
    _state.mixKey(_ephemeralPublic);
    _state.mixKey(_dh(_ephemeralPrivate, _remoteStaticPublic));
    _state.mixKey(_dh(_staticPrivate, _remoteStaticPublic));
    final ciphertext = _state.encryptAndHash(payload);
    _step = _Step.message2;
    return _concat(_ephemeralPublic, ciphertext);
  }

  /// Responder: reads `-> e, es, ss` and returns its payload.
  Uint8List readMessage1(Uint8List message) {
    _expect(false, _Step.message1);
    if (message.length < _keyLength + _tagLength) {
      throw const NoiseError('handshake message 1 is too short');
    }
    // Work on a copy so a message that fails to authenticate leaves the
    // handshake untouched.
    final state = _state.copy();
    final remoteEphemeral = Uint8List.sublistView(message, 0, _keyLength);
    state.mixHash(remoteEphemeral);
    state.mixKey(remoteEphemeral);
    state.mixKey(_dh(_staticPrivate, remoteEphemeral));
    state.mixKey(_dh(_staticPrivate, _remoteStaticPublic));
    final payload =
        state.decryptAndHash(Uint8List.sublistView(message, _keyLength));
    _state = state;
    _remoteEphemeralPublic = Uint8List.fromList(remoteEphemeral);
    _step = _Step.message2;
    return payload;
  }

  /// Responder: `<- e, ee, se, psk` carrying [payload], keyed with [psk].
  Uint8List writeMessage2(Uint8List payload, Uint8List psk) {
    _expect(false, _Step.message2);
    _checkPsk(psk);
    final remoteEphemeral = _remoteEphemeralPublic!;
    _state.mixHash(_ephemeralPublic);
    _state.mixKey(_ephemeralPublic);
    _state.mixKey(_dh(_ephemeralPrivate, remoteEphemeral));
    _state.mixKey(_dh(_ephemeralPrivate, _remoteStaticPublic));
    _state.mixKeyAndHash(psk);
    final ciphertext = _state.encryptAndHash(payload);
    _finish();
    return _concat(_ephemeralPublic, ciphertext);
  }

  /// Initiator: reads `<- e, ee, se, psk` under [psk] and returns its payload.
  ///
  /// A read that fails to authenticate leaves the handshake as it was, so the
  /// same message can be tried under another PSK.
  Uint8List readMessage2(Uint8List message, Uint8List psk) {
    _expect(true, _Step.message2);
    _checkPsk(psk);
    if (message.length < _keyLength + _tagLength) {
      throw const NoiseError('handshake message 2 is too short');
    }
    final state = _state.copy();
    final remoteEphemeral = Uint8List.sublistView(message, 0, _keyLength);
    state.mixHash(remoteEphemeral);
    state.mixKey(remoteEphemeral);
    state.mixKey(_dh(_ephemeralPrivate, remoteEphemeral));
    state.mixKey(_dh(_staticPrivate, remoteEphemeral));
    state.mixKeyAndHash(psk);
    final payload =
        state.decryptAndHash(Uint8List.sublistView(message, _keyLength));
    _state = state;
    _finish();
    return payload;
  }

  void _finish() {
    final keys = _state.split();
    _session = NoiseSession._(
      handshakeHash: Uint8List.fromList(_state.h),
      send: _CipherState(_isInitiator ? keys[0] : keys[1]),
      receive: _CipherState(_isInitiator ? keys[1] : keys[0]),
    );
    _step = _Step.done;
  }

  /// The transport session, available once both messages are processed.
  NoiseSession get session =>
      _session ?? (throw StateError('Noise handshake is not complete'));
}

/// Noise transport mode: one AEAD stream per direction, each with its own
/// message counter. A repeated, reordered or modified message fails to
/// decrypt.
class NoiseSession {
  /// Largest plaintext that fits one Noise transport message: the 65535-byte
  /// limit minus the AEAD tag.
  static const int maxPlaintextLength = 65535 - _tagLength;

  final Uint8List _handshakeHash;
  final _CipherState _send;
  final _CipherState _receive;

  NoiseSession._({
    required Uint8List handshakeHash,
    required _CipherState send,
    required _CipherState receive,
  })  : _handshakeHash = handshakeHash,
        _send = send,
        _receive = receive;

  /// The handshake hash `h`: a value both sides share that is unique to this
  /// handshake. Sendspin uses it as the prologue of a re-handshake and as a
  /// binding value during pairing.
  Uint8List get handshakeHash => Uint8List.fromList(_handshakeHash);

  Uint8List encrypt(Uint8List plaintext) {
    if (plaintext.length > maxPlaintextLength) {
      throw ArgumentError.value(plaintext.length, 'plaintext.length',
          'exceeds the Noise transport message limit');
    }
    return _send.encrypt(const [], plaintext);
  }

  Uint8List decrypt(Uint8List ciphertext) =>
      _receive.decrypt(const [], ciphertext);
}
