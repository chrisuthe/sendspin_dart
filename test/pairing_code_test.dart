import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';
import 'package:sendspin_dart/src/cpace.dart';
import 'package:sendspin_dart/src/pairing_code.dart';

Uint8List _hex(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

String _toHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Known answers from `test/vectors/gen_pairing_code.py`, which uses the
/// Python `cpace` package the aiosendspin reference server is built on.
final Map<String, dynamic> _vectors =
    jsonDecode(File('test/vectors/pairing_code.json').readAsStringSync())
        as Map<String, dynamic>;

final Map<String, dynamic> _code = _vectors['code'] as Map<String, dynamic>;
final List<Map<String, dynamic>> _cpace =
    (_vectors['cpace'] as List).cast<Map<String, dynamic>>();

CPace _side(Map<String, dynamic> v, CPaceRole role) => CPace(
      role: role,
      prs: _hex(v['prs'] as String),
      sid: _hex(v['sid'] as String),
      ad: utf8.encode(role == CPaceRole.initiator ? 'server' : 'client'),
      scalar: _hex(
          v[role == CPaceRole.initiator ? 'scalar_a' : 'scalar_b'] as String),
    );

void main() {
  group('dynamic pairing code', () {
    final h = _hex(_code['handshake_hash'] as String);
    final nonceA = _hex(_code['nonce_a'] as String);
    final nonceB = _hex(_code['nonce_b'] as String);

    test('commit_B is the hash of the label and nonce_B', () {
      expect(_toHex(pairingCommit(nonceB)), _code['commit_b']);
    });

    test('digits are the digest mod 10^6, zero-padded to six', () {
      final code = DynamicPairingCode.derive(
          handshakeHash: h, nonceA: nonceA, nonceB: nonceB);
      expect(code.digits, _code['digits']);
      expect(code.digits, hasLength(6));
    });

    test('the QR code is the first 24 bytes of the digest', () {
      final code = DynamicPairingCode.derive(
          handshakeHash: h, nonceA: nonceA, nonceB: nonceB);
      expect(_toHex(code.qrCode), _code['qr_code']);
      expect(code.qrToken, _code['qr_token']);
    });

    test('the version-1 token matches the spec reference vector', () {
      final code = Uint8List.fromList(List.generate(24, (i) => 0xE0 + i));
      expect(encodePairingCodeToken(code),
          'SP:14DQ6FY7E4XTOP9HJ5LV6Z3PO57YPD4XT6T97N5Y');
      expect(() => encodePairingCodeToken(Uint8List(23)), throwsArgumentError);
    });

    test('a leading zero is kept', () {
      // Any digest whose value mod 10^6 is below 100000 must still be six
      // characters; check the formatting directly.
      expect(formatPairingDigits(BigInt.from(42)), '000042');
    });

    test('presentation groups the digits without changing the code', () {
      expect(groupPairingDigits('123456'), '123-456');
      expect(groupPairingDigits('12345678'), '1234-5678');
    });
  });

  group('PAKE session id', () {
    test('is the label, h, and the big-endian index and round', () {
      for (final v in _cpace) {
        expect(
            _toHex(pakeSid(
              handshakeHash: _hex(v['handshake_hash'] as String),
              pairingIndex: v['pairing_index'] as int,
              round: v['round'] as int,
            )),
            v['sid']);
      }
    });
  });

  group('CPACE-X25519-SHA512 known answers', () {
    for (var n = 0; n < _cpace.length; n++) {
      final v = _cpace[n];

      test('vector $n: the generator is the Elligator2 map of the hash', () {
        expect(
            _toHex(cpaceGenerator(
                _hex(v['prs'] as String), _hex(v['sid'] as String))),
            v['generator']);
      });

      test('vector $n: public shares', () {
        expect(_toHex(_side(v, CPaceRole.initiator).publicShare), v['ya']);
        expect(_toHex(_side(v, CPaceRole.responder).publicShare), v['yb']);
      });

      test('vector $n: the responder derives the ISK and both tags', () {
        final b = _side(v, CPaceRole.responder);
        b.derive(_hex(v['ya'] as String), peerAd: utf8.encode('server'));
        expect(_toHex(b.isk), v['isk']);
        expect(_toHex(b.tag()), v['tb']);
        expect(b.verify(_hex(v['ta'] as String)), isTrue);
      });

      test('vector $n: the initiator agrees', () {
        final a = _side(v, CPaceRole.initiator);
        a.derive(_hex(v['yb'] as String), peerAd: utf8.encode('client'));
        expect(_toHex(a.isk), v['isk']);
        expect(_toHex(a.tag()), v['ta']);
        expect(a.verify(_hex(v['tb'] as String)), isTrue);
      });

      test('vector $n: wrapped PSK and nonce', () {
        final sid = _hex(v['sid'] as String);
        final isk = _hex(v['isk'] as String);
        expect(
            _toHex(wrapPairingValue(
                label: pskWrapLabel,
                sid: sid,
                isk: isk,
                value: _hex(v['long_term_psk'] as String))),
            v['wrapped_psk']);
        expect(
            _toHex(wrapPairingValue(
                label: nonceWrapLabel,
                sid: sid,
                isk: isk,
                value: _hex(v['nonce_b'] as String))),
            v['wrapped_nonce_b']);
      });

      test('vector $n: a wrapped value unwraps to the original', () {
        final sid = _hex(v['sid'] as String);
        final isk = _hex(v['isk'] as String);
        expect(
            unwrapPairingValue(
                label: pskWrapLabel,
                sid: sid,
                isk: isk,
                wrapped: _hex(v['wrapped_psk'] as String)),
            _hex(v['long_term_psk'] as String));
      });
    }
  });

  group('CPace behaviour', () {
    final v = _cpace.first;

    test('a wrong password gives a tag that does not verify', () {
      final a = _side(v, CPaceRole.initiator);
      final b = CPace(
        role: CPaceRole.responder,
        prs: utf8.encode('000000'),
        sid: _hex(v['sid'] as String),
        ad: utf8.encode('client'),
      );
      a.derive(b.publicShare, peerAd: utf8.encode('client'));
      b.derive(a.publicShare, peerAd: utf8.encode('server'));
      expect(b.verify(a.tag()), isFalse);
      expect(a.verify(b.tag()), isFalse);
    });

    test('a different session id gives a tag that does not verify', () {
      final a = _side(v, CPaceRole.initiator);
      final b = CPace(
        role: CPaceRole.responder,
        prs: _hex(v['prs'] as String),
        sid: Uint8List.fromList([..._hex(v['sid'] as String), 1]),
        ad: utf8.encode('client'),
      );
      a.derive(b.publicShare, peerAd: utf8.encode('client'));
      b.derive(a.publicShare, peerAd: utf8.encode('server'));
      expect(b.verify(a.tag()), isFalse);
    });

    test('each run draws a fresh scalar', () {
      CPace fresh() => CPace(
            role: CPaceRole.responder,
            prs: _hex(v['prs'] as String),
            sid: _hex(v['sid'] as String),
            ad: utf8.encode('client'),
          );
      expect(fresh().publicShare, isNot(fresh().publicShare));
    });

    test('a share of the wrong length is rejected', () {
      expect(() => _side(v, CPaceRole.responder).derive(Uint8List(31)),
          throwsA(isA<CPaceError>()));
    });

    test('a low-order share is rejected', () {
      // The all-zero point and the point of order 1.
      expect(() => _side(v, CPaceRole.responder).derive(Uint8List(32)),
          throwsA(isA<CPaceError>()));
      expect(() => _side(v, CPaceRole.responder).derive(Uint8List(32)..[0] = 1),
          throwsA(isA<CPaceError>()));
    });

    test('derive is single use', () {
      final b = _side(v, CPaceRole.responder);
      b.derive(_hex(v['ya'] as String), peerAd: utf8.encode('server'));
      expect(
          () => b.derive(_hex(v['ya'] as String)), throwsA(isA<CPaceError>()));
    });

    test('the key and tags are unavailable before derive', () {
      final b = _side(v, CPaceRole.responder);
      expect(() => b.isk, throwsA(isA<CPaceError>()));
      expect(() => b.tag(), throwsA(isA<CPaceError>()));
      expect(() => b.verify(Uint8List(64)), throwsA(isA<CPaceError>()));
    });

    test('a reflected share and tag do not verify', () {
      final b = _side(v, CPaceRole.responder);
      b.derive(b.publicShare, peerAd: utf8.encode('client'));
      expect(b.verify(b.tag()), isFalse);
    });

    test('a tag of the wrong length does not verify', () {
      final b = _side(v, CPaceRole.responder);
      b.derive(_hex(v['ya'] as String), peerAd: utf8.encode('server'));
      expect(b.verify(Uint8List(63)), isFalse);
    });
  });

  group('wrapping', () {
    final v = _cpace.first;
    final sid = _hex(v['sid'] as String);
    final isk = _hex(v['isk'] as String);

    test('the wrapped value is 48 bytes', () {
      expect(
          wrapPairingValue(
              label: pskWrapLabel, sid: sid, isk: isk, value: Uint8List(32)),
          hasLength(48));
    });

    test('the two labels give different ciphertexts', () {
      final value = Uint8List(32);
      expect(
          wrapPairingValue(
              label: pskWrapLabel, sid: sid, isk: isk, value: value),
          isNot(wrapPairingValue(
              label: nonceWrapLabel, sid: sid, isk: isk, value: value)));
    });

    test('a tampered or wrongly keyed value does not unwrap', () {
      final wrapped = _hex(v['wrapped_psk'] as String);
      expect(
          unwrapPairingValue(
              label: nonceWrapLabel, sid: sid, isk: isk, wrapped: wrapped),
          isNull);
      wrapped[0] ^= 1;
      expect(
          unwrapPairingValue(
              label: pskWrapLabel, sid: sid, isk: isk, wrapped: wrapped),
          isNull);
    });
  });
}
