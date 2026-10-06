import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';
import 'package:sendspin_dart/src/framing.dart';

import 'support/fake_server.dart';
import 'test_identity.dart';

/// A channel wired to a [FakeServer], recording everything it reports.
class _Link {
  final FakeServer server;
  late final SendspinChannel channel;

  final List<Map<String, dynamic>> json = [];
  final List<Uint8List> binary = [];
  final List<SendspinHandshakeResult> handshakes = [];
  final List<String> events = [];
  final List<String> closes = [];
  final List<String> serverErrors = [];

  /// Messages the channel sent, as the transport would see them.
  final List<String> sentText = [];
  final List<Uint8List> sentBinary = [];

  _Link({
    FakeServer? server,
    List<SendspinPskCandidate> Function()? pskCandidates,
    bool connectToServer = true,
  }) : server = server ?? FakeServer() {
    channel = SendspinChannel(
      identity: testIdentity,
      pskCandidates: pskCandidates,
    );
    channel.onSendText = (text) {
      sentText.add(text);
      if (connectToServer) this.server.receiveText(text);
    };
    channel.onSendBinary = (data) {
      sentBinary.add(data);
      if (connectToServer) this.server.receiveBinary(data);
    };
    channel.onJson = json.add;
    channel.onBinary = binary.add;
    channel.onHandshakeComplete = (result) {
      handshakes.add(result);
      events.add(result.isRehandshake ? 'rehandshake-complete' : 'handshake');
    };
    channel.onRehandshakeStarted = () => events.add('rehandshake-started');
    channel.onServerError = serverErrors.add;
    channel.onClose = closes.add;
    this.server.deliverText = channel.handleText;
    this.server.deliverBinary = channel.handleBinary;
  }
}

Uint8List _key(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xFF));

void main() {
  group('SendspinChannel handshake', () {
    test('start sends client/init as cleartext text', () {
      final link = _Link(connectToServer: false);
      link.channel.start();

      expect(link.sentText, hasLength(1));
      expect(link.sentBinary, isEmpty);
      final init = jsonDecode(link.sentText.single) as Map<String, dynamic>;
      expect(init['type'], 'client/init');
      expect(init['payload'], {
        'client_id': testIdentity.clientId,
        'version': 1,
        'suite': '25519_ChaChaPoly_SHA256',
      });
    });

    test('completes the handshake with the Sentinel PSK', () {
      final link = _Link();
      link.channel.start();

      expect(link.closes, isEmpty);
      expect(link.server.isEstablished, isTrue);
      expect(link.channel.isEstablished, isTrue);
      expect(link.handshakes, hasLength(1));
      final result = link.handshakes.single;
      expect(result.serverId, link.server.serverId);
      expect(result.matchedCategory, SendspinPskCategory.sentinel);
      expect(result.sentinelFallback, isFalse);
      expect(result.isRehandshake, isFalse);
      expect(result.handshakeHash, link.server.handshakeHash);
    });

    test('Noise message 2 is a text noise/handshake carrying {}', () {
      final link = _Link();
      link.channel.start();
      expect(link.sentText, hasLength(2));
      final message = jsonDecode(link.sentText[1]) as Map<String, dynamic>;
      expect(message['type'], 'noise/handshake');
      expect((message['payload'] as Map)['data'], isA<String>());
      // The server decrypted it, so the payload was the literal `{}`; the
      // 32-byte ephemeral + 2-byte payload + 16-byte tag is 50 bytes.
      final data = (message['payload'] as Map)['data'] as String;
      expect(base64Url.decode(base64Url.normalize(data)), hasLength(50));
    });

    test('server/init altered in transit fails the handshake', () {
      final link = _Link();
      link.server.prologueServerInitOverride = jsonEncode({
        'type': 'server/init',
        'payload': {'server_id': link.server.serverId, 'version': 1, 'x': 1},
      });
      link.channel.start();

      expect(link.closes, hasLength(1));
      expect(link.handshakes, isEmpty);
      expect(link.sentText, hasLength(1), reason: 'silent failure');
    });

    test('a server/init with another version is rejected silently', () {
      final link = _Link();
      link.server.serverInitOverride = jsonEncode({
        'type': 'server/init',
        'payload': {'server_id': link.server.serverId, 'version': 2},
      });
      link.channel.start();
      expect(link.closes, hasLength(1));
      expect(link.sentText, hasLength(1));
    });

    for (final bad in <String, String>{
      'not JSON': 'hello',
      'not an object': '[1]',
      'the wrong type': '{"type":"server/hello","payload":{}}',
      'a missing server_id': '{"type":"server/init","payload":{"version":1}}',
      'a short server_id':
          '{"type":"server/init","payload":{"server_id":"AAAA","version":1}}',
      'a non-integer version':
          '{"type":"server/init","payload":{"server_id":"${'A' * 43}","version":"1"}}',
    }.entries) {
      test('a server/init that is ${bad.key} is rejected silently', () {
        final link = _Link(connectToServer: false);
        link.channel.start();
        link.channel.handleText(bad.value);
        expect(link.closes, hasLength(1));
        expect(link.sentText, hasLength(1));
      });
    }

    test('server/error is reported and closes the connection', () {
      final link = _Link(connectToServer: false);
      link.channel.start();
      link.channel.handleText(jsonEncode({
        'type': 'server/error',
        'payload': {'reason': 'unsupported_suite'},
      }));
      expect(link.serverErrors, ['unsupported_suite']);
      expect(link.closes, hasLength(1));
    });

    test('a malformed Noise message 1 payload is rejected silently', () {
      for (final payload in [
        'not json',
        '{"psk_id":"x"}',
        '{"psk_id":"${'A' * 43}","psk_category":"zz"}',
        '{"psk_id":7,"psk_category":"sn"}',
      ]) {
        final link = _Link();
        link.server.message1PayloadOverride = payload;
        link.channel.start();
        expect(link.closes, hasLength(1), reason: payload);
        expect(link.sentText, hasLength(1), reason: payload);
      }
    });

    test('a noise/handshake with undecodable data is rejected silently', () {
      final link = _Link(connectToServer: false);
      link.channel.start();
      link.channel.handleText(jsonEncode({
        'type': 'server/init',
        'payload': {'server_id': FakeServer().serverId, 'version': 1},
      }));
      link.channel.handleText(jsonEncode({
        'type': 'noise/handshake',
        'payload': {'data': '!!!'},
      }));
      expect(link.closes, hasLength(1));
    });

    test('times out waiting for server/init', () {
      fakeAsync((async) {
        final link = _Link(connectToServer: false);
        link.channel.start();
        async.elapse(const Duration(seconds: 29));
        expect(link.closes, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(link.closes, hasLength(1));
      });
    });

    test('times out waiting for Noise message 1', () {
      fakeAsync((async) {
        final link = _Link();
        link.server.sendMessage1 = false;
        link.channel.start();
        async.elapse(const Duration(seconds: 29));
        expect(link.closes, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(link.closes, hasLength(1));
      });
    });

    test('no timeout fires once the handshake has completed', () {
      fakeAsync((async) {
        final link = _Link();
        link.channel.start();
        async.elapse(const Duration(minutes: 5));
        expect(link.closes, isEmpty);
      });
    });

    test('a binary message before transport mode closes the connection', () {
      final link = _Link(connectToServer: false);
      link.channel.start();
      link.channel.handleBinary(Uint8List(40));
      expect(link.closes, hasLength(1));
    });
  });

  group('SendspinChannel PSK selection', () {
    final longTerm = _key(1);
    final pairing = _key(2);

    test('matches a long-term PSK whose record names this server', () {
      final server = FakeServer(psk: longTerm, pskCategory: 'lt');
      final link = _Link(
        server: server,
        pskCandidates: () => [
          SendspinPskCandidate.longTerm(psk: _key(9), serverId: 'other'),
          SendspinPskCandidate.longTerm(
              psk: longTerm, serverId: server.serverId),
        ],
      );
      link.channel.start();

      expect(link.closes, isEmpty);
      final result = link.handshakes.single;
      expect(result.matchedCategory, SendspinPskCategory.longTerm);
      expect(result.matchedPsk, longTerm);
      expect(result.sentinelFallback, isFalse);
      expect(server.sawSentinelFallback, isFalse);
    });

    test('fails when the matched long-term PSK belongs to another server', () {
      final server = FakeServer(psk: longTerm, pskCategory: 'lt');
      final link = _Link(
        server: server,
        pskCandidates: () => [
          SendspinPskCandidate.longTerm(
              psk: longTerm,
              serverId: FakeServer(staticPrivateKey: _key(50)).serverId),
        ],
      );
      link.channel.start();

      expect(link.closes, hasLength(1));
      expect(link.handshakes, isEmpty);
      expect(link.sentText, hasLength(1), reason: 'misbinding is not a miss');
    });

    test('matches the pairing PSK', () {
      final link = _Link(
        server: FakeServer(psk: pairing, pskCategory: 'pr'),
        pskCandidates: () => [SendspinPskCandidate.pairing(pairing)],
      );
      link.channel.start();
      expect(
          link.handshakes.single.matchedCategory, SendspinPskCategory.pairing);
      expect(link.server.sawSentinelFallback, isFalse);
    });

    test('falls back to the Sentinel PSK on a lookup miss', () {
      final server = FakeServer(psk: longTerm, pskCategory: 'lt');
      final link = _Link(server: server);
      link.channel.start();

      expect(link.closes, isEmpty);
      expect(server.sawSentinelFallback, isTrue);
      final result = link.handshakes.single;
      expect(result.matchedCategory, SendspinPskCategory.sentinel);
      expect(result.sentinelFallback, isTrue);
    });

    test('a PSK held under a different category is a lookup miss', () {
      // The server references the pairing PSK's id but calls it long-term.
      final server = FakeServer(psk: pairing, pskCategory: 'lt');
      final link = _Link(
        server: server,
        pskCandidates: () => [SendspinPskCandidate.pairing(pairing)],
      );
      link.channel.start();
      expect(server.sawSentinelFallback, isTrue);
      expect(link.handshakes.single.sentinelFallback, isTrue);
    });
  });

  group('SendspinChannel transport', () {
    late _Link link;
    setUp(() {
      link = _Link();
      link.channel.start();
      link.sentBinary.clear();
    });

    test('delivers a decrypted JSON message', () {
      link.server.sendJson('server/hello', {'name': 'S'});
      expect(link.json, [
        {
          'type': 'server/hello',
          'payload': {'name': 'S'},
        }
      ]);
    });

    test('sends JSON as an encrypted binary message with ID 0', () {
      link.channel.sendJsonText('{"type":"client/hello","payload":{}}');
      expect(link.sentBinary, hasLength(1));
      expect(link.sentText, hasLength(2), reason: 'no text after handshake');
      expect(link.server.receivedJson.single['type'], 'client/hello');
    });

    test('delivers a role binary message whole, ID byte included', () {
      link.server.sendMessage(Uint8List.fromList([4, 1, 2, 3]));
      expect(link.binary.single, [4, 1, 2, 3]);
      expect(link.json, isEmpty);
    });

    test('sends a role binary message', () {
      link.channel.sendBinary(Uint8List.fromList([12, 7, 7]));
      expect(link.server.receivedBinary.single, [12, 7, 7]);
    });

    test('reassembles a fragmented inbound JSON message', () {
      final big = 'x' * (2 * maxTransportPlaintext);
      link.server.sendJson('server/state', {'blob': big});
      expect(link.json.single['payload'], {'blob': big});
    });

    test('fragments an oversized outbound message', () {
      final big = 'y' * (2 * maxTransportPlaintext);
      link.channel.sendJsonText(jsonEncode({
        'type': 'client/x',
        'payload': {'b': big}
      }));
      expect(link.sentBinary.length, greaterThan(1));
      for (final frame in link.sentBinary) {
        expect(frame.length, lessThanOrEqualTo(65535));
      }
      expect((link.server.receivedJson.single['payload'] as Map)['b'], big);
    });

    test('ignores JSON that is not a typed message object', () {
      link.server.sendJsonText('[1,2,3]');
      link.server.sendJsonText('{"type":5,"payload":{}}');
      link.server.sendJsonText('{"type":"x/y","payload":[]}');
      link.server.sendJsonText('not json at all');
      expect(link.json, isEmpty);
      expect(link.closes, isEmpty);
    });

    test('a cleartext text message in transport mode closes silently', () {
      link.channel.handleText('{"type":"server/hello","payload":{}}');
      expect(link.closes, hasLength(1));
      expect(link.sentBinary, isEmpty);
    });

    test('a tampered transport message closes silently', () {
      final captured = <Uint8List>[];
      link.server.deliverBinary = captured.add;
      link.server.sendJson('server/hello');
      captured.single[5] ^= 0x01;
      link.channel.handleBinary(captured.single);

      expect(link.json, isEmpty);
      expect(link.closes, hasLength(1));
      expect(link.sentBinary, isEmpty);
    });

    test('a replayed transport message closes silently', () {
      final captured = <Uint8List>[];
      link.server.deliverBinary = captured.add;
      link.server.sendJson('server/hello');
      link.channel.handleBinary(captured.single);
      link.channel.handleBinary(captured.single);

      expect(link.json, hasLength(1));
      expect(link.closes, hasLength(1));
    });

    test('a malformed fragment sequence closes the connection', () {
      link.server.sendFrame(Uint8List.fromList([1, 0x00, 9]));
      expect(link.closes, hasLength(1));
    });

    test('a non-fragment message mid-sequence closes the connection', () {
      link.server.sendFrame(Uint8List.fromList([1, 0x02, 0, 0x7B]));
      link.server.sendFrame(Uint8List.fromList([4, 1, 2, 3]));
      expect(link.closes, hasLength(1));
      expect(link.binary, isEmpty);
    });

    test('after closing, input is ignored and nothing more is sent', () {
      link.channel.handleText('boom');
      expect(link.closes, hasLength(1));

      link.server.sendJson('server/hello');
      link.channel.handleText('again');
      link.channel.sendJsonText('{"type":"client/goodbye","payload":{}}');

      expect(link.json, isEmpty);
      expect(link.closes, hasLength(1));
      expect(link.sentBinary, isEmpty);
    });
  });

  group('SendspinChannel lifecycle', () {
    test('sending before transport mode is an error', () {
      final channel = SendspinChannel(identity: testIdentity);
      expect(() => channel.sendJsonText('{}'), throwsStateError);
      expect(
          () => channel.sendBinary(Uint8List.fromList([4])), throwsStateError);
    });

    test('reset allows a new connection on the same channel', () {
      final link = _Link();
      link.channel.start();
      final first = link.handshakes.single.handshakeHash;

      link.channel.reset();
      expect(link.channel.isEstablished, isFalse);
      link.channel.start();

      expect(link.handshakes, hasLength(2));
      expect(link.handshakes.last.handshakeHash, isNot(first));
      link.server.sendJson('server/hello');
      expect(link.json, hasLength(1));
    });

    test('reset cancels a pending handshake timeout', () {
      fakeAsync((async) {
        final link = _Link(connectToServer: false);
        link.channel.start();
        link.channel.reset();
        async.elapse(const Duration(minutes: 1));
        expect(link.closes, isEmpty);
      });
    });
  });

  group('SendspinChannel re-handshake', () {
    final pairing = _key(2);
    late _Link link;

    setUp(() {
      link =
          _Link(pskCandidates: () => [SendspinPskCandidate.pairing(pairing)]);
      link.channel.start();
      link.sentText.clear();
      link.sentBinary.clear();
      link.events.clear();
    });

    test('swaps to new keys without closing the connection', () {
      final oldHash = link.server.handshakeHash;
      link.server.startRehandshake(pairing, 'pr');

      expect(link.closes, isEmpty);
      expect(link.events, ['rehandshake-started', 'rehandshake-complete']);
      final result = link.handshakes.last;
      expect(result.isRehandshake, isTrue);
      expect(result.matchedCategory, SendspinPskCategory.pairing);
      expect(result.serverId, link.server.serverId);
      expect(result.handshakeHash, link.server.handshakeHash);
      expect(result.handshakeHash, isNot(oldHash));
    });

    test('Noise message 2 travels as encrypted JSON, not as text', () {
      link.server.startRehandshake(pairing, 'pr');
      expect(link.sentText, isEmpty);
      expect(link.sentBinary, hasLength(1));
      expect(link.server.receivedJson, isEmpty,
          reason: 'the handshake reply is not an application message');
    });

    test('traffic after the re-handshake uses the new keys', () {
      link.server.startRehandshake(pairing, 'pr');
      link.server.sendJson('server/activate', {'activities': []});
      expect(link.json.single['type'], 'server/activate');

      link.channel.sendJsonText('{"type":"client/state","payload":{}}');
      expect(link.server.receivedJson.single['type'], 'client/state');
    });

    test('noise/handshake is not passed to the application', () {
      link.server.startRehandshake(pairing, 'pr');
      expect(link.json, isEmpty);
    });

    test('a lookup miss during a re-handshake fails without fallback', () {
      link.server.startRehandshake(_key(77), 'lt');
      expect(link.closes, hasLength(1));
      expect(link.sentBinary, isEmpty);
      expect(link.events, ['rehandshake-started']);
    });

    test('a re-handshake to the Sentinel PSK is accepted', () {
      link.server.startRehandshake(sentinelPsk, 'sn');
      expect(link.closes, isEmpty);
      expect(
          link.handshakes.last.matchedCategory, SendspinPskCategory.sentinel);
      expect(link.handshakes.last.sentinelFallback, isFalse);
    });
  });
}
