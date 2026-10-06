import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

Uint8List _seq(int start) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (start + i) & 0xFF));

class _MemoryStore implements SendspinPairingStore {
  SendspinPairingData? stored;
  int saves = 0;

  @override
  Future<SendspinPairingData?> load() async => stored;

  @override
  Future<void> save(SendspinPairingData data) async {
    saves++;
    stored = data;
  }
}

SendspinPairingRecord _record(String serverId, int seed) =>
    SendspinPairingRecord(serverId: serverId, longTermPsk: _seq(seed));

void main() {
  group('pairing token', () {
    test('matches the spec reference vector for a version-0 token', () {
      // client_key = 0x00..0x1f, pairing_psk = 0xe0..0xff
      expect(
        encodePairingToken(clientKey: _seq(0x00), pairingPsk: _seq(0xE0)),
        'SP:0AAAQEAYEAUDAOCAJBIFQYDIOB4IBCEQTCQKRMFYYDENBWHA5DYP6BYPC4PSOLZXH5DU6V97M5XXO74HR6LZ7J5PW674PT6X37T6757Y',
      );
    });

    test('uses only the QR alphanumeric set', () {
      final token =
          encodePairingToken(clientKey: _seq(7), pairingPsk: _seq(99));
      expect(token, matches(RegExp(r'^SP:0[0-9A-Z]+$')));
      expect(token.substring(4), isNot(contains('2')),
          reason: '2 is transliterated to 9');
      expect(token, isNot(contains('=')));
    });

    test('rejects keys that are not 32 bytes', () {
      expect(
          () =>
              encodePairingToken(clientKey: Uint8List(31), pairingPsk: _seq(0)),
          throwsArgumentError);
      expect(
          () =>
              encodePairingToken(clientKey: _seq(0), pairingPsk: Uint8List(33)),
          throwsArgumentError);
    });
  });

  group('SendspinPairing.load', () {
    test('creates and persists a pairing PSK when the store is empty',
        () async {
      final store = _MemoryStore();
      final pairing = await SendspinPairing.load(store);
      expect(pairing.pairingPsk, hasLength(32));
      expect(pairing.records, isEmpty);
      expect(store.saves, 1);
      expect(store.stored!.pairingPsk, pairing.pairingPsk);
    });

    test('draws a different pairing PSK for each device', () async {
      final a = await SendspinPairing.load(_MemoryStore());
      final b = await SendspinPairing.load(_MemoryStore());
      expect(a.pairingPsk, isNot(b.pairingPsk));
    });

    test('reuses the stored pairing PSK and records across restarts', () async {
      final store = _MemoryStore();
      final first = await SendspinPairing.load(store);
      await first.addRecord(_record('server-a', 1));

      final second = await SendspinPairing.load(store);
      expect(second.pairingPsk, first.pairingPsk);
      expect(second.records.single.serverId, 'server-a');
      expect(second.records.single.longTermPsk, _seq(1));
    });

    test('refuses a stored pairing PSK of the wrong length', () async {
      final store = _MemoryStore()
        ..stored =
            SendspinPairingData(pairingPsk: Uint8List(8), records: const []);
      await expectLater(SendspinPairing.load(store), throwsStateError);
      expect(store.saves, 0);
    });

    test('rejects a capacity below the spec minimum of 5', () {
      expect(() => SendspinPairing.inMemory(capacity: 4), throwsArgumentError);
    });
  });

  group('SendspinPairingData JSON', () {
    test('round-trips through toJson and fromJson', () {
      final data = SendspinPairingData(
        pairingPsk: _seq(5),
        records: [_record('server-a', 1), _record('server-b', 2)],
      );
      final copy = SendspinPairingData.fromJson(data.toJson());
      expect(copy.pairingPsk, _seq(5));
      expect(copy.records.map((r) => r.serverId), ['server-a', 'server-b']);
      expect(copy.records[1].longTermPsk, _seq(2));
    });
  });

  group('pairing records', () {
    test('a new record for a known server replaces the old one', () async {
      final store = _MemoryStore();
      final pairing = await SendspinPairing.load(store);
      await pairing.addRecord(_record('server-a', 1));
      await pairing.addRecord(_record('server-a', 2));

      expect(pairing.records.single.longTermPsk, _seq(2));
      expect(store.stored!.records.single.longTermPsk, _seq(2));
    });

    test('holds at least five records', () async {
      final pairing = SendspinPairing.inMemory();
      for (var i = 0; i < 5; i++) {
        await pairing.addRecord(_record('server-$i', i));
      }
      expect(pairing.records, hasLength(5));
    });

    test('evicts the least recently used record when full', () async {
      final pairing = SendspinPairing.inMemory();
      for (var i = 0; i < 5; i++) {
        await pairing.addRecord(_record('server-$i', i));
      }
      // server-0 is the oldest; using it makes server-1 the eviction target.
      pairing.markUsed('server-0');
      await pairing.addRecord(_record('server-new', 50));

      final ids = pairing.records.map((r) => r.serverId).toSet();
      expect(ids, hasLength(5));
      expect(ids, contains('server-new'));
      expect(ids, contains('server-0'));
      expect(ids, isNot(contains('server-1')));
    });

    test('the usage order survives a restart', () async {
      final store = _MemoryStore();
      final pairing = await SendspinPairing.load(store);
      await pairing.addRecord(_record('server-a', 1));
      await pairing.addRecord(_record('server-b', 2));
      await pairing.markUsed('server-a');

      final reloaded = await SendspinPairing.load(store);
      expect(reloaded.records.map((r) => r.serverId), ['server-b', 'server-a']);
    });

    test('never evicts a record backing an open connection', () async {
      final pairing = SendspinPairing.inMemory();
      for (var i = 0; i < 5; i++) {
        await pairing.addRecord(_record('server-$i', i));
      }
      pairing.retain('server-0');
      await pairing.addRecord(_record('server-new', 50));

      final ids = pairing.records.map((r) => r.serverId).toSet();
      expect(ids, contains('server-0'));
      expect(ids, isNot(contains('server-1')));

      // Once released it is an ordinary record again.
      pairing.release('server-0');
      await pairing.addRecord(_record('server-newer', 51));
      expect(
          pairing.records.map((r) => r.serverId), isNot(contains('server-0')));
    });

    test('a pairing never fails for lack of storage', () async {
      final pairing = SendspinPairing.inMemory();
      for (var i = 0; i < 20; i++) {
        await pairing.addRecord(_record('server-$i', i));
      }
      expect(pairing.records, hasLength(5));
      expect(pairing.records.last.serverId, 'server-19');
    });

    test('removeRecord deletes and persists', () async {
      final store = _MemoryStore();
      final pairing = await SendspinPairing.load(store);
      await pairing.addRecord(_record('server-a', 1));
      await pairing.removeRecord('server-a');
      expect(pairing.records, isEmpty);
      expect(store.stored!.records, isEmpty);
    });

    test('rejects a long-term PSK that is not 32 bytes', () {
      expect(
          () =>
              SendspinPairingRecord(serverId: 's', longTermPsk: Uint8List(16)),
          throwsArgumentError);
    });
  });

  group('handshake candidates', () {
    test('always include the pairing PSK alongside every record', () async {
      final pairing = SendspinPairing.inMemory(pairingPsk: _seq(9));
      expect(pairing.candidates().single.category, SendspinPskCategory.pairing);

      await pairing.addRecord(_record('server-a', 1));
      final candidates = pairing.candidates();
      expect(candidates, hasLength(2));
      final longTerm = candidates
          .singleWhere((c) => c.category == SendspinPskCategory.longTerm);
      expect(longTerm.serverId, 'server-a');
      expect(longTerm.psk, _seq(1));
      expect(
          candidates
              .singleWhere((c) => c.category == SendspinPskCategory.pairing)
              .psk,
          _seq(9));
    });
  });
}
