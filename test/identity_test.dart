import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

Uint8List _hex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

class _MemoryStore implements SendspinIdentityStore {
  Uint8List? stored;
  int saves = 0;

  @override
  Future<Uint8List?> loadPrivateKey() async => stored;

  @override
  Future<void> savePrivateKey(Uint8List privateKey) async {
    saves++;
    stored = Uint8List.fromList(privateKey);
  }
}

/// A [Random] that hands out a fixed byte sequence, to pin key generation.
class _FixedRandom implements Random {
  final List<int> bytes;
  int _i = 0;
  _FixedRandom(this.bytes);

  @override
  int nextInt(int max) => bytes[_i++ % bytes.length] % max;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  double nextDouble() => throw UnimplementedError();
}

void main() {
  // RFC 7748 section 6.1 test vector (Alice).
  final alicePrivate =
      _hex('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
  final alicePublic =
      _hex('8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');

  group('SendspinIdentity', () {
    test('derives the Curve25519 public key from the private key', () {
      final identity = SendspinIdentity.fromPrivateKey(alicePrivate);
      expect(identity.publicKey, alicePublic);
    });

    test('clientId is the unpadded base64url public key, 43 characters', () {
      final identity = SendspinIdentity.fromPrivateKey(alicePrivate);
      expect(identity.clientId, 'hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo');
      expect(identity.clientId, hasLength(43));
      expect(identity.clientId, isNot(contains('=')));
    });

    test('rejects a private key that is not 32 bytes', () {
      expect(() => SendspinIdentity.fromPrivateKey(Uint8List(31)),
          throwsArgumentError);
      expect(() => SendspinIdentity.fromPrivateKey(Uint8List(33)),
          throwsArgumentError);
    });

    test('does not alias the caller-supplied key bytes', () {
      final bytes = Uint8List.fromList(alicePrivate);
      final identity = SendspinIdentity.fromPrivateKey(bytes);
      bytes[0] ^= 0xFF;
      expect(identity.privateKey, alicePrivate);
    });

    test('generate draws 32 private key bytes from the random source', () {
      final identity = SendspinIdentity.generate(
          random: _FixedRandom(List<int>.from(alicePrivate)));
      expect(identity.privateKey, alicePrivate);
      expect(identity.publicKey, alicePublic);
    });

    test('generate yields a distinct identity each time', () {
      final a = SendspinIdentity.generate();
      final b = SendspinIdentity.generate();
      expect(a.clientId, isNot(b.clientId));
      expect(a.clientId, hasLength(43));
    });
  });

  group('SendspinIdentity.loadOrCreate', () {
    test('generates and persists a key when the store is empty', () async {
      final store = _MemoryStore();
      final identity = await SendspinIdentity.loadOrCreate(store);
      expect(store.saves, 1);
      expect(store.stored, identity.privateKey);
    });

    test('reuses the stored key without saving again', () async {
      final store = _MemoryStore()..stored = alicePrivate;
      final identity = await SendspinIdentity.loadOrCreate(store);
      expect(identity.publicKey, alicePublic);
      expect(store.saves, 0);
    });

    test('keeps the same identity across restarts', () async {
      final store = _MemoryStore();
      final first = await SendspinIdentity.loadOrCreate(store);
      final second = await SendspinIdentity.loadOrCreate(store);
      expect(second.clientId, first.clientId);
      expect(store.saves, 1);
    });

    test('refuses to replace a stored key that is malformed', () async {
      final store = _MemoryStore()..stored = Uint8List(5);
      await expectLater(
          SendspinIdentity.loadOrCreate(store), throwsA(isA<StateError>()));
      expect(store.saves, 0, reason: 'a bad read must not rotate the identity');
      expect(store.stored, hasLength(5));
    });
  });

  group('client/hello identity', () {
    test('client_id is the identity public key', () {
      final identity = SendspinIdentity.fromPrivateKey(alicePrivate);
      final protocol = SendspinProtocol(
        playerName: 'P',
        identity: identity,
        bufferSeconds: 5,
      );
      addTearDown(protocol.dispose);

      expect(protocol.clientId, identity.clientId);
      final hello =
          jsonDecode(protocol.buildClientHello()) as Map<String, dynamic>;
      expect((hello['payload'] as Map)['client_id'],
          'hSDwCYkwp1R0i33ctD73Wg2_Og0mOBr066SpjqqbTmo');
    });
  });
}
