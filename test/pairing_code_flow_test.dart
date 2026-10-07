import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';
import 'package:sendspin_dart/src/cpace.dart';
import 'package:sendspin_dart/src/encoding.dart';
import 'package:sendspin_dart/src/pairing_code.dart';

import 'support/connected.dart';
import 'support/fake_server.dart';
import 'test_identity.dart';

final Uint8List _nonceA =
    Uint8List.fromList(List<int>.generate(32, (i) => 0x80 + i));

/// A client offering one code method, connected to a server on the Sentinel
/// PSK, plus the server's side of the pairing exchange.
class _Fixture {
  final SendspinPairing pairing;
  final SendspinProtocol protocol;
  final FakeServer server;
  final List<String> closes = [];
  final List<String> paired = [];
  final List<String> aborted = [];
  final List<SendspinPairingCode> shown = [];
  int ended = 0;

  CPace? _cpace;
  Uint8List? _sid;

  _Fixture._(this.pairing, this.protocol, this.server) {
    protocol.onClose = closes.add;
    protocol.onPaired = paired.add;
    protocol.onPairingAborted = aborted.add;
    protocol.onPairingCode = shown.add;
    protocol.onPairingCodeEnded = () => ended++;
  }

  factory _Fixture(SendspinCodePairing codePairing,
      {SendspinPairing? pairing}) {
    final credentials = pairing ?? SendspinPairing.inMemory();
    final protocol = SendspinProtocol(
      playerName: 'P',
      identity: testIdentity,
      bufferSeconds: 5,
      unpairedAccess: false,
      pairing: credentials,
      codePairing: codePairing,
    );
    addTearDown(protocol.dispose);
    final server = connect(protocol, activate: false);
    return _Fixture._(credentials, protocol, server);
  }

  /// What the client sent, leaving out clock sync.
  List<Map<String, dynamic>> get sent =>
      server.receivedJson.where((m) => m['type'] != 'client/time').toList();

  List<String> get sentTypes => sent.map((m) => m['type'] as String).toList();

  Map<String, dynamic> payloadOf(String type) =>
      sentOfType(protocol, type).last['payload'] as Map<String, dynamic>;

  void activatePairing(String method, {String? format}) =>
      server.sendJson('server/activate', {
        'activities': ['pairing'],
        'active_roles': <String>[],
        'pairing': {'method': method, if (format != null) 'format': format},
      });

  /// Server: `server/pair-auth` for the code the operator [entered].
  void sendAuth(List<int> entered, {int pairingIndex = 1, int round = 1}) {
    _sid = pakeSid(
        handshakeHash: server.handshakeHash,
        pairingIndex: pairingIndex,
        round: round);
    _cpace = CPace(
        role: CPaceRole.initiator,
        prs: entered,
        sid: _sid!,
        ad: utf8.encode('server'));
    server.sendJson('server/pair-auth',
        {'pake_msg_1': base64UrlNoPad(_cpace!.publicShare)});
  }

  /// Server: derives from the client's share and sends `server/pair-confirm`.
  void sendConfirm() {
    final yb = base64UrlNoPadDecode(
        payloadOf('client/pair-auth')['pake_msg_2'] as String)!;
    _cpace!.derive(yb, peerAd: utf8.encode('client'));
    server.sendJson(
        'server/pair-confirm', {'server_kc': base64UrlNoPad(_cpace!.tag())});
  }

  /// Server: whether the client's `client_kc` verifies.
  bool get clientTagVerifies => _cpace!.verify(base64UrlNoPadDecode(
      payloadOf('client/pair-confirm')['client_kc'] as String)!);

  Uint8List? unwrap(String label, String type, String field) =>
      unwrapPairingValue(
          label: label,
          sid: _sid!,
          isk: _cpace!.isk,
          wrapped: base64UrlNoPadDecode(payloadOf(type)[field] as String)!);
}

SendspinCodePairing _dynamic({Set<String> formats = const {'digits'}}) =>
    SendspinDynamicCodePairing(formats: formats);

class _MemoryStore implements SendspinPairingStore {
  SendspinPairingData? stored;

  @override
  Future<SendspinPairingData?> load() async => stored;

  @override
  Future<void> save(SendspinPairingData data) async => stored = data;
}

void main() {
  group('client/hello descriptors', () {
    Map<String, dynamic> methods(SendspinCodePairing? codePairing) {
      final protocol = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        bufferSeconds: 5,
        unpairedAccess: false,
        codePairing: codePairing,
      );
      addTearDown(protocol.dispose);
      return (jsonDecode(protocol.buildClientHello())['payload']
          as Map)['supported_pair_methods'] as Map<String, dynamic>;
    }

    test('only the Pairing PSK method without a code method', () {
      expect(methods(null), {'pairing_psk': <String, dynamic>{}});
    });

    test('the dynamic method lists its channels and formats', () {
      expect(
          methods(SendspinDynamicCodePairing(
              outChannels: const {'display'},
              formats: const {'digits', 'qr_code'})),
          {
            'pairing_psk': <String, dynamic>{},
            'dynamic_pairing_code': {
              'out_channels': ['display'],
              'formats': ['digits', 'qr_code'],
            },
          });
    });

    test('the static method may say where its code is found', () {
      expect(
          methods(SendspinStaticCodePairing(
              code: '12345678', locations: const ['device'])),
          {
            'pairing_psk': <String, dynamic>{},
            'static_pairing_code': {
              'locations': ['device'],
            },
          });
    });

    test('configuration is validated', () {
      expect(() => SendspinStaticCodePairing(code: '1234567'),
          throwsArgumentError);
      expect(() => SendspinStaticCodePairing(code: '1234567x'),
          throwsArgumentError);
      expect(() => SendspinDynamicCodePairing(formats: const {}),
          throwsArgumentError);
      expect(() => SendspinDynamicCodePairing(formats: const {'morse'}),
          throwsArgumentError);
      expect(() => SendspinDynamicCodePairing(outChannels: const {}),
          throwsArgumentError);
    });
  });

  group('Dynamic Pairing Code flow', () {
    test('pair-init carries the pairing index and a commitment', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');

      expect(f.sentTypes, ['client/pair-init']);
      final init = f.payloadOf('client/pair-init');
      expect(init.keys.toSet(), {'pairing_index', 'commit_B'});
      expect(init['pairing_index'], 1);
      expect(init['commit_B'], hasLength(43));
      expect(f.shown, isEmpty, reason: 'no code before the server nonce');
    });

    test('server/pair-init makes the client show a six-digit code', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});

      expect(f.shown, hasLength(1));
      expect(f.shown.single.format, 'digits');
      expect(f.shown.single.code, matches(RegExp(r'^\d{6}$')));
      expect(f.shown.single.display,
          '${f.shown.single.code.substring(0, 3)}-${f.shown.single.code.substring(3)}');
      expect(f.sentTypes, ['client/pair-init'],
          reason: 'the client waits for the server to enter the code');
    });

    test('the right code completes the pairing', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      f.sendAuth(utf8.encode(f.shown.single.code));
      expect(f.sentTypes.last, 'client/pair-auth');
      expect(f.payloadOf('client/pair-auth')['pake_msg_2'], hasLength(43));

      f.sendConfirm();
      expect(f.sentTypes.sublist(2),
          ['client/pair-confirm', 'client/pair-finalize']);
      expect(f.payloadOf('client/pair-confirm')['client_kc'], hasLength(86));
      expect(f.clientTagVerifies, isTrue);

      // The opened commitment is the nonce the code was derived from.
      final nonceB =
          f.unwrap(nonceWrapLabel, 'client/pair-confirm', 'wrapped_nonce_B')!;
      expect(base64UrlNoPad(pairingCommit(nonceB)),
          f.payloadOf('client/pair-init')['commit_B']);
      expect(
          DynamicPairingCode.derive(
                  handshakeHash: f.server.handshakeHash,
                  nonceA: _nonceA,
                  nonceB: nonceB)
              .digits,
          f.shown.single.code);

      // Nothing is stored until the server acknowledges.
      final psk =
          f.unwrap(pskWrapLabel, 'client/pair-finalize', 'wrapped_psk')!;
      expect(psk, hasLength(32));
      expect(f.payloadOf('client/pair-finalize').keys, ['wrapped_psk']);
      expect(f.pairing.records, isEmpty);

      f.server.sendJson('server/pair-finalize');
      expect(f.pairing.records.single.serverId, f.server.serverId);
      expect(f.pairing.records.single.longTermPsk, psk);
      expect(f.paired, [f.server.serverId]);
      expect(f.ended, 1);
      expect(f.closes, isEmpty);
    });

    test('the server can then re-handshake to the new PSK', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      f.sendAuth(utf8.encode(f.shown.single.code));
      f.sendConfirm();
      final psk =
          f.unwrap(pskWrapLabel, 'client/pair-finalize', 'wrapped_psk')!;
      f.server.sendJson('server/pair-finalize');

      f.server.startRehandshake(psk, 'lt');
      activate(f.server, f.protocol);
      expect(f.protocol.isPaired, isTrue);
      expect(f.protocol.state.activeRoles, ['player@v1']);
    });

    test('the QR format shows a token and uses the 24-byte code', () {
      final f = _Fixture(_dynamic(formats: const {'digits', 'qr_code'}));
      f.activatePairing('dynamic_pairing_code', format: 'qr_code');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});

      expect(f.shown.single.format, 'qr_code');
      expect(f.shown.single.code, startsWith('SP:1'));
      expect(f.shown.single.display, f.shown.single.code);

      // The server scans the token and uses its 24 payload bytes.
      f.sendAuth(f.shown.single.rawCode);
      f.sendConfirm();
      expect(f.shown.single.rawCode, hasLength(24));
      expect(f.sentTypes.last, 'client/pair-finalize');
    });

    test('a wrong code asks for another round with the same code', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      f.sendAuth(utf8.encode('000000'));
      f.sendConfirm();

      expect(f.sent.last, {'type': 'client/pair-retry', 'payload': {}});
      expect(sentOfType(f.protocol, 'client/pair-confirm'), isEmpty);
      expect(f.closes, isEmpty);

      // Round 2: no nonce, the same code is emitted again.
      f.server.sendJson('server/pair-init');
      expect(f.shown, hasLength(2));
      expect(f.shown[1].code, f.shown[0].code);

      f.sendAuth(utf8.encode(f.shown.first.code), round: 2);
      f.sendConfirm();
      expect(f.clientTagVerifies, isTrue);
      expect(f.sentTypes.last, 'client/pair-finalize');
    });

    test('a round keyed for the wrong round number does not verify', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      // Right code, but the server computes the session id for round 2.
      f.sendAuth(utf8.encode(f.shown.single.code), round: 2);
      f.sendConfirm();
      expect(f.sent.last['type'], 'client/pair-retry');
    });

    test('after 20 failed rounds the client aborts and holds attempts back',
        () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      for (var round = 1; round <= 20; round++) {
        if (round > 1) f.server.sendJson('server/pair-init');
        f.sendAuth(utf8.encode('000000'), round: round);
        f.sendConfirm();
        if (round < 20) expect(f.sent.last['type'], 'client/pair-retry');
      }
      expect(f.sent.last, {
        'type': 'pair/abort',
        'payload': {'reason': 'pairing_code_mismatch'},
      });
      expect(f.pairing.isHoldingBack, isTrue);

      // The method stays offered; a new attempt is held back.
      f.server.receivedJson.clear();
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      expect(f.sent.single['type'], 'client/pair-pending');
      expect(f.sent.single['payload'], {'pairing_index': 2});

      // A deliberate operator action lets it proceed.
      f.pairing.releaseHoldBack();
      expect(f.sent.last['type'], 'client/pair-init');
      expect(f.payloadOf('client/pair-init')['pairing_index'], 2);
    });

    test('a verified round resets the round count', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      for (var round = 1; round <= 5; round++) {
        if (round > 1) f.server.sendJson('server/pair-init');
        f.sendAuth(utf8.encode('000000'), round: round);
        f.sendConfirm();
      }
      expect(f.pairing.roundsSinceVerified, 5);
      f.server.sendJson('server/pair-init');
      f.sendAuth(utf8.encode(f.shown.first.code), round: 6);
      f.sendConfirm();
      expect(f.pairing.roundsSinceVerified, 0);
    });
  });

  group('Static Pairing Code flow', () {
    SendspinCodePairing staticCode() =>
        SendspinStaticCodePairing(code: '48151623');

    test('without a pairing window the attempt is reported pending', () {
      final f = _Fixture(staticCode());
      f.activatePairing('static_pairing_code');
      expect(f.sent.single, {
        'type': 'client/pair-pending',
        'payload': {'pairing_index': 1},
      });
    });

    test('opening the window starts the held attempt', () {
      final f = _Fixture(staticCode());
      f.activatePairing('static_pairing_code');
      f.pairing.openPairingWindow();
      expect(f.sent.last, {
        'type': 'client/pair-init',
        'payload': {'pairing_index': 1},
      });
    });

    test('with a window already open pair-init is sent straight away', () {
      final f = _Fixture(staticCode());
      f.pairing.openPairingWindow();
      f.activatePairing('static_pairing_code');
      expect(f.sentTypes, ['client/pair-init']);
    });

    test('the right code completes the pairing and closes the window', () {
      final f = _Fixture(staticCode());
      f.pairing.openPairingWindow();
      f.activatePairing('static_pairing_code');
      f.sendAuth(utf8.encode('48151623'));
      f.sendConfirm();

      expect(f.sentTypes.sublist(2),
          ['client/pair-confirm', 'client/pair-finalize']);
      expect(f.payloadOf('client/pair-confirm').keys, ['client_kc'],
          reason: 'no commitment to open in the static flow');
      expect(f.clientTagVerifies, isTrue);
      final psk =
          f.unwrap(pskWrapLabel, 'client/pair-finalize', 'wrapped_psk')!;

      f.server.sendJson('server/pair-finalize');
      expect(f.pairing.records.single.longTermPsk, psk);
      expect(f.paired, [f.server.serverId]);
      expect(f.pairing.isPairingWindowOpen, isFalse);
      expect(f.shown, isEmpty, reason: 'a static code is never emitted');
    });

    test('a wrong code aborts with pairing_code_mismatch', () {
      final f = _Fixture(staticCode());
      f.pairing.openPairingWindow();
      f.activatePairing('static_pairing_code');
      f.sendAuth(utf8.encode('00000000'));
      f.sendConfirm();
      expect(f.sent.last, {
        'type': 'pair/abort',
        'payload': {'reason': 'pairing_code_mismatch'},
      });
      expect(f.closes, isEmpty);
      expect(f.pairing.isPairingWindowOpen, isTrue);
    });

    test('the fifth failed attempt closes the window', () {
      final f = _Fixture(staticCode());
      f.pairing.openPairingWindow();
      for (var attempt = 1; attempt <= 5; attempt++) {
        f.activatePairing('static_pairing_code');
        f.sendAuth(utf8.encode('00000000'), pairingIndex: attempt);
        f.sendConfirm();
        expect(f.pairing.isPairingWindowOpen, attempt < 5);
      }
      f.server.receivedJson.clear();
      f.activatePairing('static_pairing_code');
      expect(f.sent.single['type'], 'client/pair-pending');
    });

    test('the window expires after its lifetime', () {
      fakeAsync((async) {
        final pairing = SendspinPairing.inMemory();
        pairing.openPairingWindow();
        async.elapse(const Duration(minutes: 4, seconds: 59));
        expect(pairing.isPairingWindowOpen, isTrue);
        async.elapse(const Duration(seconds: 2));
        expect(pairing.isPairingWindowOpen, isFalse);
      });
    });

    test('closing the connection closes the window it was used on', () {
      final f = _Fixture(staticCode());
      f.pairing.openPairingWindow();
      f.activatePairing('static_pairing_code');
      f.protocol.resetForNewConnection();
      expect(f.pairing.isPairingWindowOpen, isFalse);
    });

    test('closePairingWindow closes it', () {
      final pairing = SendspinPairing.inMemory()..openPairingWindow();
      pairing.closePairingWindow();
      expect(pairing.isPairingWindowOpen, isFalse);
    });
  });

  group('ending a code attempt', () {
    test('a server/activate abandons it and nothing is stored', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      f.sendAuth(utf8.encode(f.shown.single.code));
      f.sendConfirm();
      f.server.sendJson('server/activate', {'activities': <String>[]});
      expect(f.pairing.records, isEmpty);
      expect(f.ended, 1);
    });

    test('cancelPairing stops showing the code', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      f.protocol.cancelPairing();
      expect(f.sent.last['payload'], {'reason': 'user_cancelled'});
      expect(f.ended, 1);
    });

    test('the attempt times out two minutes after pair-init', () {
      fakeAsync((async) {
        final f = _Fixture(_dynamic());
        f.activatePairing('dynamic_pairing_code', format: 'digits');
        async.elapse(const Duration(seconds: 121));
        expect(f.sent.last['payload'], {'reason': 'attempt_timeout'});
        f.protocol.dispose();
      });
    });

    test('a pending attempt does not time out', () {
      fakeAsync((async) {
        final f = _Fixture(SendspinStaticCodePairing(code: '48151623'));
        f.activatePairing('static_pairing_code');
        async.elapse(const Duration(minutes: 10));
        expect(f.sentTypes, ['client/pair-pending']);
        f.protocol.dispose();
      });
    });
  });

  group('protocol errors close without a message', () {
    void expectSilentClose(void Function(_Fixture f) act,
        {SendspinCodePairing? codePairing,
        String method = 'dynamic_pairing_code'}) {
      final f = _Fixture(codePairing ?? _dynamic());
      if (method == 'static_pairing_code') f.pairing.openPairingWindow();
      f.activatePairing(method,
          format: method == 'dynamic_pairing_code' ? 'digits' : null);
      f.server.receivedJson.clear();
      act(f);
      expect(f.closes, hasLength(1));
      expect(f.sent, isEmpty);
      expect(f.pairing.records, isEmpty);
    }

    test('the first server/pair-init without a nonce', () {
      expectSilentClose((f) => f.server.sendJson('server/pair-init'));
    });

    test('a nonce of the wrong length', () {
      expectSilentClose((f) => f.server.sendJson(
          'server/pair-init', {'nonce_A': base64UrlNoPad(Uint8List(31))}));
    });

    test('server/pair-auth before server/pair-init in the dynamic flow', () {
      expectSilentClose((f) => f.sendAuth(utf8.encode('123456')));
    });

    test('a CPace share of the wrong length', () {
      expectSilentClose((f) {
        f.server
            .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
        f.server.receivedJson.clear();
        f.server.sendJson(
            'server/pair-auth', {'pake_msg_1': base64UrlNoPad(Uint8List(16))});
      });
    });

    test('a CPace share encoding a low-order point', () {
      expectSilentClose((f) {
        f.server
            .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
        f.server.receivedJson.clear();
        f.server.sendJson(
            'server/pair-auth', {'pake_msg_1': base64UrlNoPad(Uint8List(32))});
      });
    });

    test('a confirmation tag of the wrong length', () {
      expectSilentClose((f) {
        f.sendAuth(utf8.encode('48151623'));
        f.server.receivedJson.clear();
        f.server.sendJson('server/pair-confirm',
            {'server_kc': base64UrlNoPad(Uint8List(32))});
      },
          codePairing: SendspinStaticCodePairing(code: '48151623'),
          method: 'static_pairing_code');
    });

    test('server/pair-confirm before server/pair-auth', () {
      expectSilentClose(
          (f) => f.server.sendJson('server/pair-confirm',
              {'server_kc': base64UrlNoPad(Uint8List(64))}),
          codePairing: SendspinStaticCodePairing(code: '48151623'),
          method: 'static_pairing_code');
    });

    test('server/pair-init in the static flow', () {
      expectSilentClose(
          (f) => f.server.sendJson(
              'server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)}),
          codePairing: SendspinStaticCodePairing(code: '48151623'),
          method: 'static_pairing_code');
    });

    test('server/pair-finalize before the client has finalized', () {
      expectSilentClose((f) => f.server.sendJson('server/pair-finalize'));
    });
  });

  group('method checks', () {
    test('a format the client does not offer gets method_not_supported', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'qr_code');
      expect(f.sent.single['payload'], {'reason': 'method_not_supported'});
    });

    test('the code method not configured gets method_not_supported', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('static_pairing_code');
      expect(f.sent.single['payload'], {'reason': 'method_not_supported'});
    });
  });

  group('round limit accounting', () {
    void startRound(_Fixture f) {
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
    }

    void cancel(_Fixture f) =>
        f.server.sendJson('server/activate', {'activities': <String>[]});

    test('a round counts once its code is being emitted', () {
      final f = _Fixture(_dynamic());
      startRound(f);
      expect(f.pairing.roundsSinceVerified, 1);
      cancel(f);
      expect(f.pairing.roundsSinceVerified, 1);
    });

    test('an attempt cancelled before its code was emitted does not count', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      cancel(f);
      expect(f.pairing.roundsSinceVerified, 0);
    });

    test('a round is counted once, not again when it fails', () {
      final f = _Fixture(_dynamic());
      startRound(f);
      f.sendAuth(utf8.encode('000000'));
      f.sendConfirm();
      expect(f.sent.last['type'], 'client/pair-retry');
      expect(f.pairing.roundsSinceVerified, 1);
    });

    test('20 abandoned rounds hold the next attempt back', () {
      final f = _Fixture(_dynamic());
      for (var i = 0; i < 20; i++) {
        expect(f.pairing.isHoldingBack, isFalse);
        startRound(f);
        cancel(f);
      }
      f.server.receivedJson.clear();
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      expect(f.sent.single['type'], 'client/pair-pending');
    });

    test('the count survives a restart', () async {
      final store = _MemoryStore();
      final f =
          _Fixture(_dynamic(), pairing: await SendspinPairing.load(store));
      startRound(f);
      startRound(f);
      await pumpEventQueue();
      final reloaded = await SendspinPairing.load(store);
      expect(reloaded.roundsSinceVerified, 2);
    });

    test('stored data without a round count reads as zero', () {
      final json = SendspinPairingData(
              pairingPsk: Uint8List(32), records: const [], pairingRounds: 7)
          .toJson();
      expect(SendspinPairingData.fromJson(json).pairingRounds, 7);
      json.remove('pairing_rounds');
      expect(SendspinPairingData.fromJson(json).pairingRounds, 0);
    });

    test('nonce_A in a later round is a protocol error', () {
      final f = _Fixture(_dynamic());
      startRound(f);
      f.sendAuth(utf8.encode('000000'));
      f.sendConfirm();
      f.server.receivedJson.clear();
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      expect(f.closes, hasLength(1));
      expect(f.sent, isEmpty);
    });
  });

  group('a pending attempt', () {
    _Fixture pending() {
      final f = _Fixture(SendspinStaticCodePairing(code: '48151623'));
      f.activatePairing('static_pairing_code');
      expect(f.sentTypes, ['client/pair-pending']);
      return f;
    }

    test('is ended by pair/abort from the server', () {
      final f = pending();
      f.server.sendJson('pair/abort', {'reason': 'user_cancelled'});
      expect(f.aborted, ['user_cancelled']);
      f.pairing.openPairingWindow();
      expect(f.sentTypes, ['client/pair-pending']);
    });

    test('is ended by cancelPairing', () {
      final f = pending();
      f.protocol.cancelPairing();
      expect(f.sent.last, {
        'type': 'pair/abort',
        'payload': {'reason': 'user_cancelled'},
      });
      f.pairing.openPairingWindow();
      expect(f.sentTypes, ['client/pair-pending', 'pair/abort']);
    });
  });

  group('pairing window ownership', () {
    SendspinCodePairing staticCode() =>
        SendspinStaticCodePairing(code: '48151623');

    test('admits attempts only on the connection that carried its first', () {
      final a = _Fixture(staticCode());
      final b = _Fixture(staticCode(), pairing: a.pairing);
      a.pairing.openPairingWindow();
      a.activatePairing('static_pairing_code');
      b.activatePairing('static_pairing_code');
      expect(a.sentTypes, ['client/pair-init']);
      expect(b.sentTypes, ['client/pair-pending']);
    });

    test('an attempt from an earlier window does not close a later one', () {
      final a = _Fixture(staticCode());
      final b = _Fixture(staticCode(), pairing: a.pairing);
      a.pairing.openPairingWindow();
      a.activatePairing('static_pairing_code');
      // The first window ends while a's attempt runs on; b uses the next.
      a.pairing.closePairingWindow();
      a.pairing.openPairingWindow();
      b.activatePairing('static_pairing_code');
      expect(b.sentTypes, ['client/pair-init']);

      a.sendAuth(utf8.encode('48151623'));
      a.sendConfirm();
      a.server.sendJson('server/pair-finalize');
      expect(a.paired, hasLength(1));
      expect(a.pairing.isPairingWindowOpen, isTrue);
    });

    test('failures on another connection do not count against it', () {
      final pairing = SendspinPairing.inMemory()..openPairingWindow();
      final owner = Object();
      final other = Object();
      expect(pairing.claimPairingWindow(owner), isTrue);
      for (var i = 0; i < 5; i++) {
        pairing.recordWindowFailure(other);
      }
      expect(pairing.isPairingWindowOpen, isTrue);
    });

    test('opening a window that is open keeps its owner and failures', () {
      final pairing = SendspinPairing.inMemory()..openPairingWindow();
      final owner = Object();
      pairing.claimPairingWindow(owner);
      for (var i = 0; i < 4; i++) {
        pairing.recordWindowFailure(owner);
      }
      pairing.openPairingWindow();
      expect(pairing.claimPairingWindow(Object()), isFalse);
      pairing.recordWindowFailure(owner);
      expect(pairing.isPairingWindowOpen, isFalse);
    });

    test('opening a window that is open does not extend its lifetime', () {
      fakeAsync((async) {
        final pairing = SendspinPairing.inMemory()..openPairingWindow();
        async.elapse(const Duration(minutes: 4));
        pairing.openPairingWindow();
        async.elapse(const Duration(seconds: 61));
        expect(pairing.isPairingWindowOpen, isFalse);
      });
    });

    test('a pairing completes at a later pairing index', () {
      final f = _Fixture(staticCode());
      f.pairing.openPairingWindow();
      f.activatePairing('static_pairing_code');
      f.sendAuth(utf8.encode('00000000'));
      f.sendConfirm();
      f.activatePairing('static_pairing_code');
      f.sendAuth(utf8.encode('48151623'), pairingIndex: 2);
      f.sendConfirm();
      expect(f.sentTypes.last, 'client/pair-finalize');
      expect(f.clientTagVerifies, isTrue);
    });
  });

  group('configuration', () {
    test('the offered sets are snapshots the caller cannot change', () {
      final formats = {'digits'};
      final config = SendspinDynamicCodePairing(formats: formats);
      formats.add('qr_code');
      expect(config.formats, {'digits'});
      expect(() => config.formats.add('qr_code'), throwsUnsupportedError);
      expect(() => config.outChannels.add('speaker'), throwsUnsupportedError);
    });

    test('qr_code needs a display', () {
      expect(
          () => SendspinDynamicCodePairing(
              outChannels: {'speaker'}, formats: {'digits', 'qr_code'}),
          throwsArgumentError);
    });

    test('the emitted code cannot be used to change the CPace password', () {
      final f = _Fixture(_dynamic());
      f.activatePairing('dynamic_pairing_code', format: 'digits');
      f.server
          .sendJson('server/pair-init', {'nonce_A': base64UrlNoPad(_nonceA)});
      expect(() => f.shown.single.rawCode[0] = 0, throwsUnsupportedError);
    });
  });
}
