// ABOUTME: The client's static Curve25519 identity and its storage interface.
// ABOUTME: The public key is the client_id and the Noise static key.
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:cryptography/dart.dart';

import 'encoding.dart';

/// Persists the client's static private key across restarts.
///
/// The library does not choose a storage location. Implement this over
/// whatever the platform offers for secrets (a keystore, a file with
/// restricted permissions, ...).
abstract class SendspinIdentityStore {
  /// Returns the stored 32-byte private key, or null if none has been saved.
  Future<Uint8List?> loadPrivateKey();

  /// Persists [privateKey]. Only called when no key is stored yet.
  Future<void> savePrivateKey(Uint8List privateKey);
}

/// The client's static Curve25519 keypair.
///
/// Per the Sendspin spec the base64url public key is the `client_id`, and the
/// same keypair is the static key of the Noise handshake. The identity is the
/// key: generating a new one makes servers see a new client, so persist the
/// private key and use [loadOrCreate] rather than calling [generate] on every
/// start.
class SendspinIdentity {
  static const int keyLength = 32;

  static final SimplePublicKey _basePoint = SimplePublicKey(
    Uint8List(keyLength)..[0] = 9,
    type: KeyPairType.x25519,
  );

  final Uint8List _privateKey;
  final Uint8List _publicKey;

  SendspinIdentity._(this._privateKey, this._publicKey);

  /// Rebuilds an identity from a previously stored 32-byte private key.
  factory SendspinIdentity.fromPrivateKey(Uint8List privateKey) {
    if (privateKey.length != keyLength) {
      throw ArgumentError.value(privateKey.length, 'privateKey.length',
          'A Curve25519 private key is $keyLength bytes');
    }
    final private = Uint8List.fromList(privateKey);
    return SendspinIdentity._(private, _derivePublicKey(private));
  }

  /// Creates a new identity from a CSPRNG.
  ///
  /// This is a new identity every time. Use [loadOrCreate] unless the caller
  /// persists the result itself. [random] exists for tests; the default is
  /// [Random.secure].
  factory SendspinIdentity.generate({Random? random}) {
    final source = random ?? Random.secure();
    final private = Uint8List(keyLength);
    for (var i = 0; i < keyLength; i++) {
      private[i] = source.nextInt(256);
    }
    return SendspinIdentity._(private, _derivePublicKey(private));
  }

  /// In-flight [loadOrCreate] calls, one per store instance.
  static final Expando<Future<SendspinIdentity>> _loading =
      Expando<Future<SendspinIdentity>>();

  /// Loads the identity from [store], generating and saving one only when the
  /// store is empty.
  ///
  /// A stored key of the wrong length throws [StateError] instead of being
  /// replaced: silently regenerating would rotate the device's identity.
  ///
  /// Overlapping calls for the same [store] share one load, so two callers
  /// racing on an empty store cannot each generate and save a different key.
  /// Separate store instances over the same storage are not coordinated.
  static Future<SendspinIdentity> loadOrCreate(SendspinIdentityStore store) =>
      _loading[store] ??=
          _loadOrCreate(store).whenComplete(() => _loading[store] = null);

  static Future<SendspinIdentity> _loadOrCreate(
      SendspinIdentityStore store) async {
    final stored = await store.loadPrivateKey();
    if (stored != null) {
      if (stored.length != keyLength) {
        throw StateError(
            'Stored Sendspin private key is ${stored.length} bytes, expected '
            '$keyLength. Refusing to replace it; clear the store explicitly '
            'to issue a new identity.');
      }
      return SendspinIdentity.fromPrivateKey(stored);
    }
    final identity = SendspinIdentity.generate();
    await store.savePrivateKey(identity.privateKey);
    return identity;
  }

  /// The 32-byte private key. Keep it secret; persist it via a
  /// [SendspinIdentityStore].
  Uint8List get privateKey => Uint8List.fromList(_privateKey);

  /// The 32-byte Curve25519 public key.
  Uint8List get publicKey => Uint8List.fromList(_publicKey);

  /// The `client_id`: the public key as unpadded base64url (43 characters).
  String get clientId => base64UrlNoPad(_publicKey);

  static Uint8List _derivePublicKey(Uint8List privateKey) {
    // The public key is the scalar multiplication of the base point.
    final secret = const DartX25519().sharedSecretSync(
      keyPairData: SimpleKeyPairData(
        privateKey,
        publicKey: _basePoint,
        type: KeyPairType.x25519,
      ),
      remotePublicKey: _basePoint,
    );
    return Uint8List.fromList((secret as SecretKeyData).bytes);
  }
}
