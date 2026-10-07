// ABOUTME: Pairing credentials: the device's pairing PSK, the pairing
// ABOUTME: records it holds for servers, their storage, and pairing tokens.
import 'dart:async';
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

  /// The key bytes are copied, and [longTermPsk] is unmodifiable.
  SendspinPairingRecord(
      {required this.serverId, required Uint8List longTermPsk})
      : longTermPsk = Uint8List.fromList(longTermPsk).asUnmodifiableView() {
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

  /// The pairing PSK is copied and unmodifiable, and so is the record list.
  SendspinPairingData({
    required Uint8List pairingPsk,
    required List<SendspinPairingRecord> records,
  })  : pairingPsk = Uint8List.fromList(pairingPsk).asUnmodifiableView(),
        records = List.unmodifiable(records);

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

/// A pairing-code method the client offers in addition to the Pairing PSK
/// method. At most one may be offered.
sealed class SendspinCodePairing {
  const SendspinCodePairing();

  /// The method identifier used in `supported_pair_methods` and
  /// `server/activate`.
  String get method;

  /// The emission formats offered for this method.
  Set<String> get formats;

  /// The method's descriptor in `client/hello`.
  Map<String, dynamic> get descriptor;
}

/// Dynamic Pairing Code: the device shows (or speaks) a fresh code for each
/// pairing and the operator enters it into the server. For devices with a
/// display or a speaker.
class SendspinDynamicCodePairing extends SendspinCodePairing {
  /// How the code reaches the operator: `display`, `speaker`.
  final Set<String> outChannels;

  /// `digits` (six digits to type) and/or `qr_code` (a token to scan, which
  /// needs a display able to render a QR code).
  @override
  final Set<String> formats;

  SendspinDynamicCodePairing({
    this.outChannels = const {'display'},
    this.formats = const {'digits'},
  }) {
    if (outChannels.isEmpty ||
        !outChannels.every(const {'display', 'speaker'}.contains)) {
      throw ArgumentError.value(outChannels, 'outChannels',
          "must be a non-empty subset of 'display', 'speaker'");
    }
    if (formats.isEmpty ||
        !formats.every(const {'digits', 'qr_code'}.contains)) {
      throw ArgumentError.value(formats, 'formats',
          "must be a non-empty subset of 'digits', 'qr_code'");
    }
  }

  @override
  String get method => 'dynamic_pairing_code';

  @override
  Map<String, dynamic> get descriptor => {
        'out_channels': [
          for (final c in const ['display', 'speaker'])
            if (outChannels.contains(c)) c
        ],
        'formats': [
          for (final f in const ['digits', 'qr_code'])
            if (formats.contains(f)) f
        ],
      };
}

/// Static Pairing Code: a fixed 8-digit code, for devices with no way to
/// emit one. Every attempt needs a pairing window opened by a physical
/// gesture on the device ([SendspinPairing.openPairingWindow]).
///
/// The code must be random per device, never a shared default: anyone who
/// knows it can pair with the device while a window is open.
class SendspinStaticCodePairing extends SendspinCodePairing {
  /// The 8 decimal digits.
  final String code;

  /// Where the operator finds the code: `device`, `leaflet`, `operator`.
  final List<String>? locations;

  SendspinStaticCodePairing({required this.code, this.locations}) {
    if (!RegExp(r'^\d{8}$').hasMatch(code)) {
      throw ArgumentError.value(
          code.length, 'code.length', 'A static pairing code is 8 digits');
    }
  }

  @override
  String get method => 'static_pairing_code';

  @override
  Set<String> get formats => const {};

  @override
  Map<String, dynamic> get descriptor =>
      {if (locations != null) 'locations': locations};
}

/// A dynamic pairing code for the device to emit.
class SendspinPairingCode {
  /// `digits` or `qr_code`.
  final String format;

  /// What the operator enters: six digits, or the `SP:1...` token to render
  /// as a QR code.
  final String code;

  /// The code as it should be shown: digits grouped `123-456`; the token
  /// unchanged.
  final String display;

  /// The bytes fed to the key exchange: the ASCII digits, or the 24-byte
  /// code the token carries.
  final Uint8List rawCode;

  SendspinPairingCode({
    required this.format,
    required this.code,
    required this.display,
    required this.rawCode,
  });
}

/// Encodes a version-1 pairing token: the 24-byte dynamic pairing code in
/// the `qr_code` emission format, which the device renders as a QR code for
/// the operator to scan into the server.
String encodePairingCodeToken(Uint8List code) {
  if (code.length != 24) {
    throw ArgumentError.value(
        code.length, 'code.length', 'A QR pairing code is 24 bytes');
  }
  return 'SP:1${_base32(code).replaceAll('2', '9')}';
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

  /// Notified when a held-back attempt may be able to proceed.
  final List<void Function()> _listeners = [];

  int _failedRounds = 0;
  bool _holdingBack = false;

  bool _windowOpen = false;
  int _windowFailures = 0;
  Object? _windowOwner;
  Timer? _windowTimer;

  /// Dynamic-code rounds allowed since the last one whose `server_kc`
  /// verified. On reaching it the client aborts and holds attempts back.
  static const int roundLimit = 20;

  /// Failed attempts that close a static pairing window.
  static const int windowFailureLimit = 5;

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

  /// Marks the record for [serverId] as the most recently used and persists
  /// the new order, so eviction still follows usage after a restart.
  Future<void> markUsed(String serverId) async {
    final index = _records.indexWhere((r) => r.serverId == serverId);
    if (index < 0 || index == _records.length - 1) return;
    _records.add(_records.removeAt(index));
    await _save();
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

  // ---------------------------------------------------------------------
  // Code-based pairing: rate limiting shared by every connection
  // ---------------------------------------------------------------------

  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List.of(_listeners)) {
      listener();
    }
  }

  /// Dynamic-code rounds that have failed since one last verified. Not
  /// partitioned by server.
  int get failedRounds => _failedRounds;

  /// True once the round limit has been reached: dynamic-code attempts are
  /// answered with `client/pair-pending` until [releaseHoldBack].
  bool get isHoldingBack => _holdingBack;

  /// Records the outcome of a dynamic-code round. Returns true when a
  /// failure reached the round limit, so the attempt must be aborted.
  bool recordRound({required bool verified}) {
    if (verified) {
      _failedRounds = 0;
      return false;
    }
    _failedRounds++;
    if (_failedRounds < roundLimit) return false;
    _holdingBack = true;
    return true;
  }

  /// Lets dynamic-code attempts proceed again and resets the round count.
  /// Call this only for a deliberate operator action on the device.
  void releaseHoldBack() {
    _holdingBack = false;
    _failedRounds = 0;
    _notify();
  }

  /// Whether a static-code pairing window is open.
  bool get isPairingWindowOpen => _windowOpen;

  /// Opens a pairing window: static-code attempts are accepted until one
  /// succeeds, five fail, the connection using it drops, or [lifetime]
  /// passes. Call this for a deliberate physical gesture on the device (a
  /// button press), not for anything that can be triggered remotely.
  void openPairingWindow({Duration lifetime = const Duration(minutes: 5)}) {
    _windowTimer?.cancel();
    _windowOpen = true;
    _windowFailures = 0;
    _windowOwner = null;
    _windowTimer = Timer(lifetime, closePairingWindow);
    _notify();
  }

  /// Closes the pairing window. An attempt already in progress runs on.
  void closePairingWindow() {
    _windowTimer?.cancel();
    _windowTimer = null;
    _windowOpen = false;
    _windowOwner = null;
  }

  /// Whether [connection] may start a static-code attempt now: a window is
  /// open, and it is not already tied to another connection. A window admits
  /// attempts only on the connection that carried its first.
  bool claimPairingWindow(Object connection) {
    if (!_windowOpen) return false;
    _windowOwner ??= connection;
    return identical(_windowOwner, connection);
  }

  /// Records a failed static-code attempt; the fifth closes the window.
  void recordWindowFailure() {
    if (!_windowOpen) return;
    _windowFailures++;
    if (_windowFailures >= windowFailureLimit) closePairingWindow();
  }

  /// Closes the window if [connection] is the one using it.
  void connectionDropped(Object connection) {
    if (identical(_windowOwner, connection)) closePairingWindow();
  }

  Future<void> _save() async {
    await _store?.save(SendspinPairingData(
      pairingPsk: Uint8List.fromList(_pairingPsk),
      records: List.of(_records),
    ));
  }
}
