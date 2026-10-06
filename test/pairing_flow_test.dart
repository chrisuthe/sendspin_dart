import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';
import 'package:sendspin_dart/src/encoding.dart';

import 'support/connected.dart';
import 'support/fake_server.dart';
import 'test_identity.dart';

final Uint8List _pairingPsk =
    Uint8List.fromList(List<int>.generate(32, (i) => 50 + i));
final Uint8List _longTermPsk =
    Uint8List.fromList(List<int>.generate(32, (i) => 100 + i));

const _pairingActivation = {
  'activities': ['pairing'],
  'active_roles': <String>[],
  'pairing': {'method': 'pairing_psk'},
};

class _Fixture {
  final SendspinPairing pairing;
  final SendspinProtocol protocol;
  final FakeServer server;
  final List<String> closes = [];
  final List<String> paired = [];
  final List<String> aborted = [];

  _Fixture._(this.pairing, this.protocol, this.server) {
    protocol.onClose = closes.add;
    protocol.onPaired = paired.add;
    protocol.onPairingAborted = aborted.add;
  }

  /// A client and a server that knows its pairing token, connected under the
  /// pairing PSK and not yet activated.
  factory _Fixture.pairingSession({bool unpairedAccess = false}) {
    final pairing = SendspinPairing.inMemory(pairingPsk: _pairingPsk);
    final protocol = SendspinProtocol(
      playerName: 'P',
      identity: testIdentity,
      bufferSeconds: 5,
      unpairedAccess: unpairedAccess,
      pairing: pairing,
    );
    addTearDown(protocol.dispose);
    final server = FakeServer(psk: _pairingPsk, pskCategory: 'pr');
    final fixture = _Fixture._(pairing, protocol, server);
    connect(protocol, server: server, activate: false);
    return fixture;
  }

  /// A client that already holds a pairing record for the server.
  factory _Fixture.pairedSession() {
    final server = FakeServer(psk: _longTermPsk, pskCategory: 'lt');
    final pairing = SendspinPairing.inMemory(
      pairingPsk: _pairingPsk,
      records: [
        SendspinPairingRecord(
            serverId: server.serverId, longTermPsk: _longTermPsk),
      ],
    );
    final protocol = SendspinProtocol(
      playerName: 'P',
      identity: testIdentity,
      bufferSeconds: 5,
      unpairedAccess: false,
      pairing: pairing,
    );
    addTearDown(protocol.dispose);
    final fixture = _Fixture._(pairing, protocol, server);
    connect(protocol, server: server);
    return fixture;
  }

  /// What the client sent, leaving out clock sync.
  List<Map<String, dynamic>> get sent =>
      server.receivedJson.where((m) => m['type'] != 'client/time').toList();

  List<String> get sentTypes => sent.map((m) => m['type'] as String).toList();

  Uint8List get deliveredPsk => base64UrlNoPadDecode(
      (sentOfType(protocol, 'client/pair-finalize').single['payload']
          as Map)['long_term_psk'] as String)!;
}

void main() {
  group('Pairing PSK flow', () {
    test('sends pair-init then pair-finalize without waiting', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);

      expect(f.sentTypes, ['client/pair-init', 'client/pair-finalize']);
      expect(f.sent[0]['payload'], {'pairing_index': 1});
      final finalize = f.sent[1]['payload'] as Map;
      expect(finalize.keys, ['long_term_psk']);
      expect(finalize['long_term_psk'], hasLength(43));
      expect(f.deliveredPsk, hasLength(32));
    });

    test('persists nothing until server/pair-finalize arrives', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);
      expect(f.pairing.records, isEmpty);
      expect(f.paired, isEmpty);
    });

    test('persists the record on server/pair-finalize', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);
      f.server.sendJson('server/pair-finalize');

      final record = f.pairing.records.single;
      expect(record.serverId, f.server.serverId);
      expect(record.longTermPsk, f.deliveredPsk);
      expect(f.paired, [f.server.serverId]);
      expect(f.closes, isEmpty);
    });

    test('each pairing draws a fresh long-term PSK', () {
      final a = _Fixture.pairingSession()
        ..server.sendJson('server/activate', _pairingActivation);
      final b = _Fixture.pairingSession()
        ..server.sendJson('server/activate', _pairingActivation);
      expect(a.deliveredPsk, isNot(b.deliveredPsk));
      expect(a.deliveredPsk, isNot(_pairingPsk));
    });

    test('the server can re-handshake to the new PSK and start playback', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);
      f.server.sendJson('server/pair-finalize');
      final longTerm = f.deliveredPsk;
      f.server.receivedJson.clear();

      f.server.startRehandshake(longTerm, 'lt');
      activate(f.server, f.protocol);

      expect(f.closes, isEmpty);
      expect(f.protocol.isPaired, isTrue);
      expect(f.protocol.state.activities, {'playback'});
      expect(f.protocol.state.activeRoles, ['player@v1'],
          reason: 'playback without unpaired access needs the paired session');
    });

    test('pairing replaces an existing record for the same server', () {
      final f = _Fixture.pairingSession();
      f.pairing.addRecord(SendspinPairingRecord(
          serverId: f.server.serverId, longTermPsk: _longTermPsk));
      f.server.sendJson('server/activate', _pairingActivation);
      f.server.sendJson('server/pair-finalize');

      expect(f.pairing.records.single.longTermPsk, f.deliveredPsk);
    });

    test('pairing_index counts pairing activations since the handshake', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);
      // The server leaves pairing, then admits a second attempt.
      f.server.sendJson('server/activate', {'activities': <String>[]});
      f.server.sendJson('server/activate', _pairingActivation);

      final inits = sentOfType(f.protocol, 'client/pair-init');
      expect(inits.map((m) => (m['payload'] as Map)['pairing_index']), [1, 2]);
    });

    test('pairing_index restarts after a re-handshake', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);
      f.server.sendJson('server/activate', {'activities': <String>[]});
      f.server.startRehandshake(_pairingPsk, 'pr');
      f.server.receivedJson.clear();
      f.server.sendJson('server/activate', _pairingActivation);

      expect(
          (sentOfType(f.protocol, 'client/pair-init').single['payload']
              as Map)['pairing_index'],
          1);
    });

    test('pairing can run alongside playback', () {
      final f = _Fixture.pairingSession(unpairedAccess: true);
      f.server.sendJson('server/activate', {
        'activities': ['playback', 'pairing'],
        'active_roles': ['player@v1'],
        'pairing': {'method': 'pairing_psk'},
      });
      expect(f.protocol.state.activeRoles, ['player@v1']);
      expect(f.sentTypes,
          containsAll(['client/pair-init', 'client/pair-finalize']));
    });
  });

  group('ending an attempt without finalizing', () {
    test('a server/activate in place of pair-finalize persists nothing', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);
      f.server.sendJson('server/activate', {'activities': <String>[]});

      expect(f.pairing.records, isEmpty);
      expect(f.paired, isEmpty);
      expect(f.closes, isEmpty);
      expect(f.protocol.state.activities, isEmpty);
    });

    test('pair/abort from the server ends the attempt and stays connected', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);
      f.server.sendJson('pair/abort', {'reason': 'user_cancelled'});

      expect(f.aborted, ['user_cancelled']);
      expect(f.pairing.records, isEmpty);
      expect(f.closes, isEmpty);
    });

    test('a pair/abort with no attempt in progress has no effect', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', {'activities': <String>[]});
      f.server.sendJson('pair/abort', {'reason': 'user_cancelled'});
      expect(f.aborted, isEmpty);
      expect(f.closes, isEmpty);
    });

    test('cancelPairing sends pair/abort user_cancelled', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);
      f.server.receivedJson.clear();
      f.protocol.cancelPairing();

      expect(f.sent.single, {
        'type': 'pair/abort',
        'payload': {'reason': 'user_cancelled'},
      });
      // Messages still in flight from the server are discarded silently.
      f.server.sendJson('server/pair-finalize');
      expect(f.pairing.records, isEmpty);
      expect(f.closes, isEmpty);
    });

    test('cancelPairing does nothing without an attempt', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', {'activities': <String>[]});
      f.protocol.cancelPairing();
      expect(f.sent, isEmpty);
    });

    test('the attempt times out with pair/abort attempt_timeout', () {
      fakeAsync((async) {
        final f = _Fixture.pairingSession();
        f.server.sendJson('server/activate', _pairingActivation);
        f.server.receivedJson.clear();

        async.elapse(const Duration(seconds: 119));
        expect(f.sent, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(f.sent.single, {
          'type': 'pair/abort',
          'payload': {'reason': 'attempt_timeout'},
        });

        // A late finalize from the server is discarded, not persisted.
        f.server.sendJson('server/pair-finalize');
        expect(f.pairing.records, isEmpty);
        expect(f.closes, isEmpty);
        f.protocol.dispose();
      });
    });

    test('no timeout fires after the pairing completes', () {
      fakeAsync((async) {
        final f = _Fixture.pairingSession();
        f.server.sendJson('server/activate', _pairingActivation);
        f.server.sendJson('server/pair-finalize');
        f.server.receivedJson.clear();
        async.elapse(const Duration(minutes: 5));
        expect(sentOfType(f.protocol, 'pair/abort'), isEmpty);
        f.protocol.dispose();
      });
    });
  });

  group('pairing protocol errors', () {
    test('server/pair-finalize with no attempt closes without a message', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', {'activities': <String>[]});
      f.server.sendJson('server/pair-finalize');

      expect(f.closes, hasLength(1));
      expect(f.sent, isEmpty);
      expect(f.pairing.records, isEmpty);
    });

    test('a code-flow message during a Pairing PSK attempt closes', () {
      for (final type in [
        'server/pair-init',
        'server/pair-auth',
        'server/pair-confirm',
      ]) {
        final f = _Fixture.pairingSession();
        f.server.sendJson('server/activate', _pairingActivation);
        f.server.receivedJson.clear();
        f.server.sendJson(type, {'pake_msg_1': 'x'});

        expect(f.closes, hasLength(1), reason: type);
        expect(f.sent, isEmpty, reason: type);
        expect(f.pairing.records, isEmpty, reason: type);
      }
    });

    test('a second server/pair-finalize is out of sequence', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', _pairingActivation);
      f.server.sendJson('server/pair-finalize');
      f.server.sendJson('server/pair-finalize');
      expect(f.closes, hasLength(1));
      expect(f.pairing.records, hasLength(1));
    });
  });

  group('pairing method checks', () {
    test('pairing_psk on a Sentinel session gets method_not_supported', () {
      final protocol = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        bufferSeconds: 5,
        unpairedAccess: false,
        pairing: SendspinPairing.inMemory(pairingPsk: _pairingPsk),
      );
      addTearDown(protocol.dispose);
      final server = connect(protocol, activate: false);
      server.sendJson('server/activate', _pairingActivation);

      expect(server.receivedJson.single, {
        'type': 'pair/abort',
        'payload': {'reason': 'method_not_supported'},
      });
    });

    test('a code method is not offered and gets method_not_supported', () {
      final f = _Fixture.pairingSession();
      f.server.sendJson('server/activate', {
        'activities': ['pairing'],
        'active_roles': <String>[],
        'pairing': {'method': 'static_pairing_code'},
      });
      expect(f.sent.single['payload'], {'reason': 'method_not_supported'});
      expect(f.closes, isEmpty);
    });

    test('rejectConcurrentPairing aborts with concurrent_attempt and closes',
        () {
      final f = _Fixture.pairingSession();
      f.protocol.rejectConcurrentPairing();
      expect(f.sent.single, {
        'type': 'pair/abort',
        'payload': {'reason': 'concurrent_attempt'},
      });
      expect(f.closes, hasLength(1));
    });
  });

  group('server/unpair', () {
    test('removes the record, says goodbye unpaired and closes', () {
      final f = _Fixture.pairedSession();
      expect(f.protocol.isPaired, isTrue);
      f.server.sendJson('server/unpair');

      expect(f.pairing.records, isEmpty);
      expect(f.sent.single, {
        'type': 'client/goodbye',
        'payload': {'reason': 'unpaired'},
      });
      expect(f.closes, hasLength(1));
    });

    test('is ignored on an unpaired session', () {
      final f = _Fixture.pairingSession(unpairedAccess: true);
      f.pairing.addRecord(SendspinPairingRecord(
          serverId: f.server.serverId, longTermPsk: _longTermPsk));
      activate(f.server, f.protocol);
      f.server.receivedJson.clear();
      f.server.sendJson('server/unpair');

      expect(f.pairing.records, hasLength(1));
      expect(f.sent, isEmpty);
      expect(f.closes, isEmpty);
    });
  });

  group('records and open connections', () {
    SendspinPairingRecord other(int i) => SendspinPairingRecord(
        serverId: 'other-$i',
        longTermPsk: Uint8List.fromList(List<int>.filled(32, i)));

    test('the record backing a paired session is not evicted', () async {
      final f = _Fixture.pairedSession();
      for (var i = 0; i < 6; i++) {
        await f.pairing.addRecord(other(i));
      }
      expect(f.pairing.records.map((r) => r.serverId),
          contains(f.server.serverId));
    });

    test('it becomes evictable again once the connection is reset', () async {
      final f = _Fixture.pairedSession();
      f.protocol.resetForNewConnection();
      for (var i = 0; i < 6; i++) {
        await f.pairing.addRecord(other(i));
      }
      expect(f.pairing.records.map((r) => r.serverId),
          isNot(contains(f.server.serverId)));
    });

    test('a paired handshake marks its record most recently used', () async {
      final server = FakeServer(psk: _longTermPsk, pskCategory: 'lt');
      final pairing = SendspinPairing.inMemory(records: [
        SendspinPairingRecord(
            serverId: server.serverId, longTermPsk: _longTermPsk),
        other(1),
      ]);
      final protocol = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        bufferSeconds: 5,
        unpairedAccess: false,
        pairing: pairing,
      );
      addTearDown(protocol.dispose);
      connect(protocol, server: server);
      expect(pairing.records.last.serverId, server.serverId);
    });
  });

  test('client/hello offers the Pairing PSK method', () {
    final f = _Fixture.pairingSession();
    final hello = f.protocol.buildClientHello();
    expect(hello, contains('"supported_pair_methods":{"pairing_psk":{}}'));
  });

  test('the pairing token combines the identity and the pairing PSK', () {
    final f = _Fixture.pairingSession();
    expect(
        f.protocol.pairingToken,
        encodePairingToken(
            clientKey: testIdentity.publicKey, pairingPsk: _pairingPsk));
  });
}
