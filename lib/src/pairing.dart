// ABOUTME: Pairing credentials: the device's pairing PSK, the pairing
// ABOUTME: records it holds for servers, their storage, and pairing tokens.
import 'dart:math';
import 'dart:typed_data';

import 'encoding.dart';
import 'psk.dart';

void _checkLength(Uint8List bytes, String name) {
  if (bytes.length != pskLength) {
    throw ArgumentError.value(
        bytes.length, '$name.length', '$name must be $pskLength bytes');
  }
}

Uint8List _randomBytes() {
  final random = Random.secure();
  return Uint8List.fromList(
      List<int>.generate(pskLength, (_) => random.nextInt(256)));
}

/// One successful pairing: the long-term PSK and the server it belongs to.
class SendspinPairingRecord {
  /// The server's `server_id`. A handshake that matches [longTermPsk] fails
  /// unless the server presenting it has this id.
  final String serverId;
  final Uint8List longTermPsk;

  SendspinPairingRecord({required this.serverId, required this.longTermPsk}) {
    _checkLength(longTermPsk, 'longTermPsk');
  }

  Map<String, dynamic> toJson() => {
        'server_id': serverId,
        'long_term_psk': base64UrlNoPad(longTermPsk),
      };

  factory SendspinPairingRecord.fromJson(Map<String, dynamic> json) =>
      SendspinPairingRecord(
        serverId: json['server_id'] as String,
        longTermPsk: base64UrlNoPadDecode(json['long_term_psk'] as String) ??
            (throw const FormatException('long_term_psk is not base64url')),
      );
}

/// Everything a device persists for pairing. These are secrets: store them
/// the way the identity's private key is stored.
class SendspinPairingData {
  /// The device's own pairing PSK. Per device, long-lived, not consumed by a
  /// pairing.
  final Uint8List pairingPsk;

  /// Pairing records, least recently used first.
  final List<SendspinPairingRecord> records;

  SendspinPairingData({required this.pairingPsk, required this.records});

  Map<String, dynamic> toJson() => {
        'pairing_psk': base64UrlNoPad(pairingPsk),
        'records': records.map((r) => r.toJson()).toList(),
      };

  factory SendspinPairingData.fromJson(Map<String, dynamic> json) =>
      SendspinPairingData(
        pairingPsk: base64UrlNoPadDecode(json['pairing_psk'] as String) ??
            (throw const FormatException('pairing_psk is not base64url')),
        records: (json['records'] as List)
            .map((r) =>
                SendspinPairingRecord.fromJson(r as Map<String, dynamic>))
            .toList(),
      );
}

/// Persists [SendspinPairingData] across restarts. Implemented by the
/// consumer; the library does not choose a storage location.
abstract class SendspinPairingStore {
  /// Returns the stored data, or null if nothing has been saved yet.
  Future<SendspinPairingData?> load();

  /// Persists [data], replacing what was stored.
  Future<void> save(SendspinPairingData data);
}

/// Encodes a version-0 pairing token: the client's public key and pairing
/// PSK, which the operator enters into a server (as text or a QR code) to
/// pair by the Pairing PSK method.
///
/// `"SP:" || "0" || base32(client_key || pairing_psk)`, unpadded, with every
/// `2` written as `9` so the token stays within the QR alphanumeric set.
String encodePairingToken({
  required Uint8List clientKey,
  required Uint8List pairingPsk,
}) {
  _checkLength(clientKey, 'clientKey');
  _checkLength(pairingPsk, 'pairingPsk');
  return 'SP:0${_base32([...clientKey, ...pairingPsk]).replaceAll('2', '9')}';
}

/// RFC 4648 base32 without padding.
String _base32(List<int> bytes) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  final out = StringBuffer();
  var buffer = 0;
  var bits = 0;
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      bits -= 5;
      out.write(alphabet[(buffer >> bits) & 0x1F]);
    }
    buffer &= (1 << bits) - 1;
  }
  if (bits > 0) out.write(alphabet[(buffer << (5 - bits)) & 0x1F]);
  return out.toString();
}

/// The pairing credentials a client holds: its pairing PSK and its pairing
/// records, kept in memory for the handshake and written through to a
/// [SendspinPairingStore].
///
/// One instance may be shared by several connections; [retain] and [release]
/// keep a record that backs an open connection from being evicted.
class SendspinPairing {
  /// The spec requires room for at least this many records.
  static const int minimumCapacity = 5;

  /// How many pairing records are kept before the least recently used one is
  /// evicted to make room.
  final int capacity;

  final SendspinPairingStore? _store;
  final Uint8List _pairingPsk;

  /// Least recently used first.
  final List<SendspinPairingRecord> _records;
  final Map<String, int> _retained = {};

  SendspinPairing._(
      this._store, this._pairingPsk, this._records, this.capacity) {
    if (capacity < minimumCapacity) {
      throw ArgumentError.value(capacity, 'capacity',
          'A client must hold at least $minimumCapacity pairing records');
    }
  }

  /// Credentials that are not persisted. For tests, or a device that
  /// provisions its pairing PSK some other way and accepts losing its
  /// pairings on restart.
  factory SendspinPairing.inMemory({
    Uint8List? pairingPsk,
    List<SendspinPairingRecord> records = const [],
    int capacity = minimumCapacity,
  }) {
    final psk = pairingPsk ?? _randomBytes();
    _checkLength(psk, 'pairingPsk');
    return SendspinPairing._(
        null, Uint8List.fromList(psk), List.of(records), capacity);
  }

  /// Loads the credentials from [store]. On first use a pairing PSK is drawn
  /// from a CSPRNG and saved; it is then reused for the life of the device.
  ///
  /// A stored pairing PSK of the wrong length throws [StateError] instead of
  /// being replaced, since servers may already hold its pairing token.
  static Future<SendspinPairing> load(
    SendspinPairingStore store, {
    int capacity = minimumCapacity,
  }) async {
    final data = await store.load();
    if (data == null) {
      final pairing = SendspinPairing._(store, _randomBytes(), [], capacity);
      await pairing._save();
      return pairing;
    }
    if (data.pairingPsk.length != pskLength) {
      throw StateError('Stored pairing PSK is ${data.pairingPsk.length} '
          'bytes, expected $pskLength. Refusing to replace it.');
    }
    return SendspinPairing._(store, Uint8List.fromList(data.pairingPsk),
        List.of(data.records), capacity);
  }

  /// The device's pairing PSK. Expose it to an operator only as a
  /// [pairingToken], never bare.
  Uint8List get pairingPsk => Uint8List.fromList(_pairingPsk);

  /// The pairing records held, least recently used first.
  List<SendspinPairingRecord> get records => List.unmodifiable(_records);

  /// The pairing token for a device whose public key is [clientKey].
  String pairingToken(Uint8List clientKey) =>
      encodePairingToken(clientKey: clientKey, pairingPsk: _pairingPsk);

  /// The PSKs offered to a handshake: every long-term PSK, and always the
  /// pairing PSK, so a server can re-handshake to it at any time.
  List<SendspinPskCandidate> candidates() => [
        for (final record in _records)
          SendspinPskCandidate.longTerm(
              psk: record.longTermPsk, serverId: record.serverId),
        SendspinPskCandidate.pairing(_pairingPsk),
      ];

  /// Stores [record], replacing any record already held for its server. At
  /// capacity the least recently used record that does not back an open
  /// connection is evicted, so a pairing never fails for lack of room.
  Future<void> addRecord(SendspinPairingRecord record) {
    _records.removeWhere((r) => r.serverId == record.serverId);
    while (_records.length >= capacity) {
      final victim =
          _records.indexWhere((r) => !_retained.containsKey(r.serverId));
      // Every record is in use; the spec has the client cap its open paired
      // connections below capacity so this does not happen. Drop the oldest.
      _records.removeAt(victim < 0 ? 0 : victim);
    }
    _records.add(record);
    return _save();
  }

  /// Removes the record for [serverId], if any.
  Future<void> removeRecord(String serverId) {
    _records.removeWhere((r) => r.serverId == serverId);
    return _save();
  }

  /// Marks the record for [serverId] as the most recently used.
  void markUsed(String serverId) {
    final index = _records.indexWhere((r) => r.serverId == serverId);
    if (index < 0) return;
    _records.add(_records.removeAt(index));
  }

  /// Declares that an open connection is keyed by the record for
  /// [serverId], protecting it from eviction until [release].
  void retain(String serverId) =>
      _retained[serverId] = (_retained[serverId] ?? 0) + 1;

  void release(String serverId) {
    final count = (_retained[serverId] ?? 0) - 1;
    if (count > 0) {
      _retained[serverId] = count;
    } else {
      _retained.remove(serverId);
    }
  }

  Future<void> _save() async {
    await _store?.save(SendspinPairingData(
      pairingPsk: Uint8List.fromList(_pairingPsk),
      records: List.of(_records),
    ));
  }
}
