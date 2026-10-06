import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/src/noise.dart';

Uint8List _hex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Known-answer vectors produced by `test/vectors/gen_noise_kkpsk2.py` with
/// the Python `noiseprotocol` package, the library the aiosendspin reference
/// implementation is built on.
final List<Map<String, dynamic>> _vectors =
    (jsonDecode(File('test/vectors/noise_kkpsk2.json').readAsStringSync())
            as List)
        .cast<Map<String, dynamic>>();

NoiseHandshake _initiator(Map<String, dynamic> v, {Uint8List? prologue}) =>
    NoiseHandshake.initiator(
      staticPrivateKey: _hex(v['initiator_static_private'] as String),
      remoteStaticPublicKey: _hex(v['responder_static_public'] as String),
      prologue: prologue ?? _hex(v['prologue'] as String),
      ephemeralPrivateKey: _hex(v['initiator_ephemeral_private'] as String),
    );

NoiseHandshake _responder(Map<String, dynamic> v, {Uint8List? prologue}) =>
    NoiseHandshake.responder(
      staticPrivateKey: _hex(v['responder_static_private'] as String),
      remoteStaticPublicKey: _hex(v['initiator_static_public'] as String),
      prologue: prologue ?? _hex(v['prologue'] as String),
      ephemeralPrivateKey: _hex(v['responder_ephemeral_private'] as String),
    );

/// Runs a full handshake from vector [v] and returns (initiator, responder)
/// transport sessions.
(NoiseSession, NoiseSession) _handshake(Map<String, dynamic> v) {
  final psk = _hex(v['psk'] as String);
  final i = _initiator(v);
  final r = _responder(v);
  r.readMessage1(i.writeMessage1(_hex(v['payload_1'] as String)));
  i.readMessage2(r.writeMessage2(_hex(v['payload_2'] as String), psk), psk);
  return (i.session, r.session);
}

void main() {
  group('Noise_KKpsk2_25519_ChaChaPoly_SHA256 known answers', () {
    for (var n = 0; n < _vectors.length; n++) {
      final v = _vectors[n];
      final psk = _hex(v['psk'] as String);

      test('vector $n: initiator writes the reference message 1', () {
        final message1 =
            _initiator(v).writeMessage1(_hex(v['payload_1'] as String));
        expect(_toHex(message1), v['message_1']);
      });

      test('vector $n: responder reads message 1 and writes message 2', () {
        final r = _responder(v);
        final payload1 = r.readMessage1(_hex(v['message_1'] as String));
        expect(_toHex(payload1), v['payload_1']);

        final message2 = r.writeMessage2(_hex(v['payload_2'] as String), psk);
        expect(_toHex(message2), v['message_2']);
        expect(_toHex(r.session.handshakeHash), v['handshake_hash']);
      });

      test('vector $n: initiator reads the reference message 2', () {
        final i = _initiator(v);
        i.writeMessage1(_hex(v['payload_1'] as String));
        final payload2 = i.readMessage2(_hex(v['message_2'] as String), psk);
        expect(_toHex(payload2), v['payload_2']);
        expect(_toHex(i.session.handshakeHash), v['handshake_hash']);
      });

      test('vector $n: transport messages match in both directions', () {
        final (i, r) = _handshake(v);
        for (final m in (v['transport'] as List).cast<Map<String, dynamic>>()) {
          final toResponder = m['direction'] == 'i2r';
          final sender = toResponder ? i : r;
          final receiver = toResponder ? r : i;
          final ciphertext = sender.encrypt(_hex(m['plaintext'] as String));
          expect(_toHex(ciphertext), m['ciphertext']);
          expect(_toHex(receiver.decrypt(ciphertext)), m['plaintext']);
        }
      });
    }
  });

  group('Noise handshake failures', () {
    final v = _vectors.first;
    final psk = _hex(v['psk'] as String);

    test('a different prologue makes message 1 unreadable', () {
      final r = _responder(v, prologue: Uint8List.fromList(utf8.encode('x')));
      expect(() => r.readMessage1(_hex(v['message_1'] as String)),
          throwsA(isA<NoiseError>()));
    });

    test('a tampered message 1 is rejected', () {
      final message1 = _hex(v['message_1'] as String);
      message1[message1.length - 1] ^= 0x01;
      expect(() => _responder(v).readMessage1(message1),
          throwsA(isA<NoiseError>()));
    });

    test('a truncated message 1 is rejected', () {
      expect(() => _responder(v).readMessage1(Uint8List(31)),
          throwsA(isA<NoiseError>()));
    });

    test('message 2 written with a different PSK is rejected', () {
      final i = _initiator(v);
      final r = _responder(v);
      r.readMessage1(i.writeMessage1(Uint8List(0)));
      final message2 = r.writeMessage2(Uint8List(0), Uint8List(32));
      expect(() => i.readMessage2(message2, psk), throwsA(isA<NoiseError>()));
    });

    test('a failed message 2 read can be retried with another PSK', () {
      // The server verifies message 2 under the referenced PSK and then under
      // the Sentinel PSK, so a failed read must leave the handshake usable.
      final other = Uint8List(32)..fillRange(0, 32, 7);
      final i = _initiator(v);
      final r = _responder(v);
      r.readMessage1(i.writeMessage1(Uint8List(0)));
      final message2 = r.writeMessage2(Uint8List.fromList([1, 2]), psk);

      expect(() => i.readMessage2(message2, other), throwsA(isA<NoiseError>()));
      expect(i.readMessage2(message2, psk), [1, 2]);
      expect(i.session.handshakeHash, r.session.handshakeHash);
    });

    test('a PSK that is not 32 bytes is rejected', () {
      final i = _initiator(v);
      final r = _responder(v);
      r.readMessage1(i.writeMessage1(Uint8List(0)));
      expect(() => r.writeMessage2(Uint8List(0), Uint8List(16)),
          throwsArgumentError);
    });

    test('messages cannot be used out of order', () {
      expect(() => _responder(v).writeMessage2(Uint8List(0), psk),
          throwsStateError);
      expect(() => _initiator(v).readMessage2(Uint8List(48), psk),
          throwsStateError);
      expect(() => _initiator(v).session, throwsStateError);
    });

    test('a handshake generates a fresh ephemeral key by default', () {
      NoiseHandshake fresh() => NoiseHandshake.initiator(
            staticPrivateKey: _hex(v['initiator_static_private'] as String),
            remoteStaticPublicKey: _hex(v['responder_static_public'] as String),
            prologue: Uint8List(0),
          );
      final a = fresh().writeMessage1(Uint8List(0));
      final b = fresh().writeMessage1(Uint8List(0));
      expect(a, isNot(b));
    });
  });

  group('Noise transport', () {
    final v = _vectors.first;

    test('a replayed message fails to decrypt', () {
      final (i, r) = _handshake(v);
      final ciphertext = i.encrypt(Uint8List.fromList([1, 2, 3]));
      expect(r.decrypt(ciphertext), [1, 2, 3]);
      expect(() => r.decrypt(ciphertext), throwsA(isA<NoiseError>()));
    });

    test('an out-of-order message fails to decrypt', () {
      final (i, r) = _handshake(v);
      i.encrypt(Uint8List.fromList([1]));
      final second = i.encrypt(Uint8List.fromList([2]));
      expect(() => r.decrypt(second), throwsA(isA<NoiseError>()));
    });

    test('a tampered message fails to decrypt', () {
      final (i, r) = _handshake(v);
      final ciphertext = i.encrypt(Uint8List.fromList([1, 2, 3]));
      ciphertext[0] ^= 0x80;
      expect(() => r.decrypt(ciphertext), throwsA(isA<NoiseError>()));
    });

    test('a message shorter than the tag fails to decrypt', () {
      final (_, r) = _handshake(v);
      expect(() => r.decrypt(Uint8List(15)), throwsA(isA<NoiseError>()));
    });

    test('a message sent in the wrong direction fails to decrypt', () {
      final (i, _) = _handshake(v);
      final ciphertext = i.encrypt(Uint8List.fromList([1]));
      expect(() => i.decrypt(ciphertext), throwsA(isA<NoiseError>()));
    });

    test('ciphertext is the plaintext plus a 16-byte tag', () {
      final (i, _) = _handshake(v);
      expect(i.encrypt(Uint8List(100)), hasLength(116));
    });

    test('a plaintext over the Noise message limit is refused', () {
      final (i, _) = _handshake(v);
      expect(() => i.encrypt(Uint8List(NoiseSession.maxPlaintextLength + 1)),
          throwsArgumentError);
      expect(i.encrypt(Uint8List(NoiseSession.maxPlaintextLength)),
          hasLength(65535));
    });
  });
}
