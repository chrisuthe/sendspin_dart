import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

import 'support/connected.dart';
import 'support/fake_server.dart';
import 'test_identity.dart';

const _allRoles = {
  SendspinRole.player,
  SendspinRole.controller,
  SendspinRole.metadata,
};

SendspinProtocol _protocol({
  bool unpairedAccess = true,
  Set<SendspinRole> roles = _allRoles,
  List<SendspinPskCandidate> Function()? pskCandidates,
  DeviceInfo deviceInfo = const DeviceInfo(),
}) {
  final protocol = SendspinProtocol(
    playerName: 'Kitchen',
    identity: testIdentity,
    bufferSeconds: 5,
    roles: roles,
    unpairedAccess: unpairedAccess,
    pskCandidates: pskCandidates,
    deviceInfo: deviceInfo,
  );
  addTearDown(protocol.dispose);
  return protocol;
}

final Uint8List _longTermPsk =
    Uint8List.fromList(List<int>.generate(32, (i) => 100 + i));
final Uint8List _pairingPsk =
    Uint8List.fromList(List<int>.generate(32, (i) => 50 + i));

/// A protocol and a server that share a long-term PSK: a paired session.
(SendspinProtocol, FakeServer) _paired() {
  final server = FakeServer(psk: _longTermPsk, pskCategory: 'lt');
  final protocol = _protocol(
    unpairedAccess: false,
    pskCandidates: () => [
      SendspinPskCandidate.longTerm(
          psk: _longTermPsk, serverId: server.serverId),
    ],
  );
  return (protocol, server);
}

Uint8List _audioChunk() => Uint8List(13 + 4)..[0] = 4;

String _streamStart() => jsonEncode({
      'type': 'stream/start',
      'payload': {
        'server_transmitted': 0,
        'player': {
          'codec': 'pcm',
          'sample_rate': 48000,
          'channels': 2,
          'bit_depth': 16,
        },
      },
    });

void main() {
  group('connection sequence', () {
    test('start sends only client/init', () {
      final protocol = _protocol();
      final text = <String>[];
      final binary = <Uint8List>[];
      protocol.onSendText = text.add;
      protocol.onSendBinary = binary.add;
      protocol.start();

      expect(binary, isEmpty);
      expect(jsonDecode(text.single)['type'], 'client/init');
      expect(protocol.state.connectionState, SendspinConnectionState.connected);
    });

    test('nothing is sent after the handshake until server/hello arrives', () {
      final protocol = _protocol();
      final server = FakeServer();
      protocol.onSendText = server.receiveText;
      protocol.onSendBinary = server.receiveBinary;
      server.deliverText = protocol.handleTextMessage;
      server.deliverBinary = protocol.handleBinaryMessage;
      protocol.start();

      expect(server.isEstablished, isTrue);
      expect(server.receivedJson, isEmpty);
      expect(protocol.serverId, server.serverId);
      expect(protocol.state.serverId, server.serverId);
    });

    test('client/hello answers server/hello and is the only message sent', () {
      final protocol = _protocol();
      final server = connect(protocol, activate: false);
      // connect() clears the record, so replay the hello exchange by hand.
      expect(protocol.state.serverName, 'TestServer');
      expect(protocol.state.connectionState, SendspinConnectionState.syncing);
      expect(server.receivedJson, isEmpty);
    });

    test('client/hello has the rc1 shape', () {
      final protocol = _protocol(
        unpairedAccess: false,
        deviceInfo: const DeviceInfo(
          productName: 'Hearth',
          manufacturer: 'Acme',
          softwareVersion: '2.0',
          macAddress: 'aa:bb:cc:dd:ee:ff',
        ),
      );
      final server = FakeServer();
      protocol.onSendText = server.receiveText;
      protocol.onSendBinary = server.receiveBinary;
      server.deliverText = protocol.handleTextMessage;
      server.deliverBinary = protocol.handleBinaryMessage;
      protocol.start();
      server.sendJson('server/hello', {'name': 'S'});

      final hello = server.receivedJson.single;
      expect(hello['type'], 'client/hello');
      final payload = hello['payload'] as Map<String, dynamic>;
      expect(payload.keys.toSet(), {
        'name',
        'device_info',
        'supported_roles',
        'player@v1_support',
        'supported_pair_methods',
        'unpaired_access',
      });
      expect(payload['name'], 'Kitchen');
      expect(payload['device_info'], {
        'product_name': 'Hearth',
        'manufacturer': 'Acme',
        'software_version': '2.0',
        'mac_address': 'aa:bb:cc:dd:ee:ff',
      });
      expect(payload['supported_roles'],
          ['player@v1', 'controller@v1', 'metadata@v1']);
      expect(payload['supported_pair_methods'], {'pairing_psk': {}});
      expect(payload['unpaired_access'], {'enabled': false});
    });

    test('mac_address is omitted when not configured', () {
      final hello = jsonDecode(_protocol().buildClientHello());
      expect(
          (hello['payload']['device_info'] as Map).containsKey('mac_address'),
          isFalse);
    });

    test('a repeated server/hello does not produce a second client/hello', () {
      final protocol = _protocol();
      final server = connect(protocol, activate: false);
      server.sendJson('server/hello', {'name': 'Again'});
      expect(server.receivedJson, isEmpty);
      expect(protocol.state.serverName, 'TestServer');
    });

    test('server/error is reported and closes the connection', () {
      final protocol = _protocol();
      final errors = <String>[];
      final closes = <String>[];
      protocol.onServerError = errors.add;
      protocol.onClose = closes.add;
      protocol.start();
      protocol.handleTextMessage(jsonEncode({
        'type': 'server/error',
        'payload': {'reason': 'unsupported_version'},
      }));
      expect(errors, ['unsupported_version']);
      expect(closes, hasLength(1));
      expect(
          protocol.state.connectionState, SendspinConnectionState.disconnected);
    });

    test('a transport failure closes the connection', () {
      final protocol = _protocol();
      final closes = <String>[];
      protocol.onClose = closes.add;
      connect(protocol);
      protocol.handleBinaryMessage(Uint8List(64));
      expect(closes, hasLength(1));
      expect(
          protocol.state.connectionState, SendspinConnectionState.disconnected);
    });
  });

  group('before the first server/activate', () {
    late SendspinProtocol protocol;
    late FakeServer server;
    setUp(() {
      protocol = _protocol();
      server = connect(protocol, activate: false);
    });

    test('no client/state or client/time is sent', () {
      protocol.updateVolume(0.4);
      protocol.setPipelineError(true);
      protocol.startClockSync();
      expect(server.receivedJson, isEmpty);
    });

    test('controller commands are refused', () {
      expect(() => protocol.sendControllerCommand('play'), throwsStateError);
      expect(server.receivedJson, isEmpty);
    });

    test('server messages other than hello and activate are ignored', () {
      var groupUpdates = 0;
      protocol.onGroupUpdate = (_) => groupUpdates++;
      server.sendJson('group/update', {
        'playback_state': 'playing',
        'group_id': 'g',
        'group_name': 'G',
      });
      server.sendMessage(_audioChunk());
      expect(groupUpdates, 0);
    });

    test('client/goodbye may be sent', () {
      protocol.sendGoodbye(SendspinGoodbyeReason.shutdown);
      expect(server.receivedJson.single, {
        'type': 'client/goodbye',
        'payload': {'reason': 'shutdown'},
      });
    });

    test('the connection is dropped if no activation arrives in time', () {
      fakeAsync((async) {
        final p = _protocol();
        final closes = <String>[];
        p.onClose = closes.add;
        connect(p, activate: false);
        async.elapse(const Duration(seconds: 29));
        expect(closes, isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(closes, hasLength(1));
        p.dispose();
      });
    });

    test('the timeout does not fire once activated', () {
      fakeAsync((async) {
        final p = _protocol();
        final closes = <String>[];
        p.onClose = closes.add;
        connect(p);
        async.elapse(const Duration(minutes: 2));
        expect(closes, isEmpty);
        p.dispose();
      });
    });
  });

  test('client/goodbye is not sent before the handshake completes', () {
    final protocol = _protocol();
    final text = <String>[];
    final binary = <Uint8List>[];
    protocol.onSendText = text.add;
    protocol.onSendBinary = binary.add;
    protocol.start();
    protocol.sendGoodbye(SendspinGoodbyeReason.shutdown);
    expect(text, hasLength(1));
    expect(binary, isEmpty);
  });

  test('goodbye reasons use the rc1 wire values', () {
    expect(SendspinGoodbyeReason.values.map((r) => r.wireValue), [
      'another_server',
      'shutdown',
      'restart',
      'user_request',
      'unauthorized',
      'pairing_required',
      'concurrent_attempt',
      'unpaired',
    ]);
  });

  group('server/activate', () {
    test('the first activation records activities and roles', () {
      final protocol = _protocol();
      final activations = <(Set<String>, List<String>)>[];
      protocol.onActivate = (a, r) => activations.add((a, r));
      final server = connect(protocol, activate: false);
      activate(server, protocol, roles: ['player@v1', 'metadata@v1']);

      expect(protocol.state.activities, {'playback'});
      expect(protocol.state.activeRoles, ['player@v1', 'metadata@v1']);
      expect(protocol.isRoleActive(SendspinRole.player), isTrue);
      expect(protocol.isRoleActive(SendspinRole.controller), isFalse);
      expect(activations, hasLength(1));
      expect(activations.single.$1, {'playback'});
    });

    test('the first activation starts clock sync and sends client/state', () {
      final protocol = _protocol();
      final server = connect(protocol, activate: false);
      activate(server, protocol);
      expect(server.receivedJson.map((m) => m['type']),
          containsAll(['client/state', 'client/time']));
      expect(sentOfType(protocol, 'client/state'), hasLength(1));
    });

    test('a first activation that omits active_roles carries none', () {
      final protocol = _protocol();
      final server = connect(protocol, activate: false);
      server.sendJson('server/activate', {'activities': <String>[]});

      expect(protocol.state.activeRoles, isEmpty);
      expect(protocol.state.activities, isEmpty);
      expect(sentOfType(protocol, 'client/state'), isEmpty,
          reason: 'only a client with active roles sends the initial state');
    });

    test('a later activation that omits active_roles keeps them', () {
      final protocol = _protocol();
      final server = connect(protocol);
      server.sendJson('server/activate', {'activities': <String>[]});

      expect(protocol.state.activities, isEmpty);
      expect(protocol.state.activeRoles,
          ['player@v1', 'controller@v1', 'metadata@v1']);
      expect(sentOfType(protocol, 'client/state'), isEmpty);
    });

    test('a role that becomes active is reported with client/state', () {
      final protocol = _protocol();
      final server = connect(protocol, roles: ['metadata@v1']);
      activate(server, protocol, roles: ['metadata@v1', 'player@v1']);
      expect(sentOfType(protocol, 'client/state'), hasLength(1));
    });

    test('removing the player role stops output', () {
      final protocol = _protocol();
      var ended = 0;
      protocol.onStreamEnd = () => ended++;
      final server = connect(protocol);
      server.sendJsonText(_streamStart());
      expect(protocol.state.connectionState, SendspinConnectionState.streaming);

      activate(server, protocol, roles: ['metadata@v1']);
      expect(ended, 1);
      expect(protocol.state.connectionState, SendspinConnectionState.syncing);
    });

    test('removing the player role clears output even after stream/end', () {
      final protocol = _protocol();
      var ended = 0;
      protocol.onStreamEnd = () => ended++;
      final server = connect(protocol);
      server.sendJsonText(_streamStart());
      server.sendJson('stream/end', {
        'roles': ['player']
      });
      expect(ended, 1);
      activate(server, protocol, roles: <String>[]);
      expect(ended, 2);
    });

    test('removing the metadata role discards its state and pending update',
        () {
      final protocol = _protocol();
      final server = connect(protocol);
      protocol.clock.update(0, 100, 1);
      protocol.clock.update(0, 100, 2);
      server.sendJson('server/state', {
        'metadata': {'timestamp': 0, 'title': 'Now'},
      });
      server.sendJson('server/state', {
        'metadata': {
          'timestamp': protocol.nowUs() + 60000000,
          'title': 'Later',
        },
      });
      expect(protocol.state.metadata!.title, 'Now');
      expect(protocol.pendingMetadata, isNotNull);

      activate(server, protocol, roles: ['player@v1']);
      expect(protocol.state.metadata, isNull);
      expect(protocol.pendingMetadata, isNull);
    });

    test('removing the controller role discards its state', () {
      final protocol = _protocol();
      final server = connect(protocol);
      server.sendJson('server/state', {
        'controller': {
          'supported_commands': ['play'],
          'volume': 30,
          'muted': false,
        },
      });
      expect(protocol.state.controller, isNotNull);

      activate(server, protocol, roles: ['player@v1']);
      expect(protocol.state.controller, isNull);
      expect(() => protocol.sendControllerCommand('play'), throwsStateError);
    });

    test('state for roles that stay active is unchanged', () {
      final protocol = _protocol();
      final server = connect(protocol);
      server.sendJson('server/state', {
        'metadata': {'timestamp': 0, 'title': 'Now'},
      });
      activate(server, protocol, roles: ['metadata@v1']);
      expect(protocol.state.metadata!.title, 'Now');
    });
  });

  group('inadmissible server/activate', () {
    test('playback on an unpaired session without unpaired access', () {
      final protocol = _protocol(unpairedAccess: false);
      final closes = <String>[];
      protocol.onClose = closes.add;
      final server = connect(protocol, activate: false);
      activate(server, protocol);

      expect(server.receivedJson.single, {
        'type': 'client/goodbye',
        'payload': {'reason': 'pairing_required'},
      });
      expect(closes, hasLength(1));
      expect(protocol.state.activeRoles, isEmpty);
    });

    test('pairing on a paired session is unauthorized', () {
      final (protocol, fake) = _paired();
      final closes = <String>[];
      protocol.onClose = closes.add;
      final server = connect(protocol, server: fake, activate: false);
      server.sendJson('server/activate', {
        'activities': ['pairing'],
        'active_roles': <String>[],
        'pairing': {'method': 'pairing_psk'},
      });

      expect(server.receivedJson.single, {
        'type': 'client/goodbye',
        'payload': {'reason': 'unauthorized'},
      });
      expect(closes, hasLength(1));
    });

    test('an unsupported pairing method gets pair/abort and stays open', () {
      final protocol = _protocol();
      final closes = <String>[];
      protocol.onClose = closes.add;
      final server = connect(protocol, activate: false);
      // pairing_psk needs the pairing PSK to have matched; this is Sentinel.
      server.sendJson('server/activate', {
        'activities': ['pairing'],
        'active_roles': <String>[],
        'pairing': {'method': 'pairing_psk'},
      });

      expect(server.receivedJson.single, {
        'type': 'pair/abort',
        'payload': {'reason': 'method_not_supported'},
      });
      expect(closes, isEmpty);
      expect(protocol.state.activities, isEmpty, reason: 'not applied');

      // The connection is still usable: a valid activation is accepted.
      activate(server, protocol);
      expect(protocol.state.activities, {'playback'});
    });

    test('nothing more is sent after the goodbye', () {
      final protocol = _protocol(unpairedAccess: false);
      final server = connect(protocol, activate: false);
      activate(server, protocol);
      server.receivedJson.clear();

      protocol.updateVolume(0.2);
      protocol.sendGoodbye(SendspinGoodbyeReason.shutdown);
      server.sendJson('server/activate', {'activities': <String>[]});
      expect(server.receivedJson, isEmpty);
    });
  });

  group('paired session', () {
    test('playback is admissible without unpaired access', () {
      final (protocol, fake) = _paired();
      connect(protocol, server: fake);
      expect(protocol.isPaired, isTrue);
      expect(protocol.state.activities, {'playback'});
      expect(protocol.state.activeRoles, isNotEmpty);
    });

    test('an unpaired session is not paired', () {
      final protocol = _protocol();
      connect(protocol);
      expect(protocol.isPaired, isFalse);
    });
  });

  group('unpairedAccess setting', () {
    test('turning it off closes an unpaired session that relies on it', () {
      final protocol = _protocol();
      final closes = <String>[];
      protocol.onClose = closes.add;
      final server = connect(protocol);

      protocol.unpairedAccess = false;
      expect(server.receivedJson.single, {
        'type': 'client/goodbye',
        'payload': {'reason': 'pairing_required'},
      });
      expect(closes, hasLength(1));
    });

    test('turning it off leaves an idle unpaired session open', () {
      final protocol = _protocol();
      final closes = <String>[];
      protocol.onClose = closes.add;
      final server = connect(protocol, activities: [], roles: []);
      protocol.unpairedAccess = false;
      expect(server.receivedJson, isEmpty);
      expect(closes, isEmpty);
    });

    test('turning it off does not affect a paired session', () {
      final server = FakeServer(psk: _longTermPsk, pskCategory: 'lt');
      final protocol = _protocol(
        pskCandidates: () => [
          SendspinPskCandidate.longTerm(
              psk: _longTermPsk, serverId: server.serverId),
        ],
      );
      final closes = <String>[];
      protocol.onClose = closes.add;
      connect(protocol, server: server);
      protocol.unpairedAccess = false;
      expect(server.receivedJson, isEmpty);
      expect(closes, isEmpty);
    });

    test('the current value is advertised in client/hello', () {
      final protocol = _protocol(unpairedAccess: false);
      protocol.unpairedAccess = true;
      final hello = jsonDecode(protocol.buildClientHello());
      expect(hello['payload']['unpaired_access'], {'enabled': true});
    });
  });

  group('re-handshake', () {
    late SendspinProtocol protocol;
    late FakeServer server;
    setUp(() {
      protocol = _protocol(
          pskCandidates: () => [SendspinPskCandidate.pairing(_pairingPsk)]);
      server = connect(protocol);
    });

    test('application messages wait for the activation that follows', () {
      server.startRehandshake(_pairingPsk, 'pr');
      protocol.updateVolume(0.3);
      expect(server.receivedJson, isEmpty);

      server.sendJson('server/activate', {
        'activities': ['playback']
      });
      expect(sentOfType(protocol, 'client/state'), hasLength(1));
      expect(
          (sentOfType(protocol, 'client/state').single['payload']['player']
              as Map)['volume'],
          30);
    });

    test('roles and stream state persist across it', () {
      server.sendJsonText(_streamStart());
      server.startRehandshake(_pairingPsk, 'pr');
      server.sendJson('server/activate', {
        'activities': ['playback']
      });

      expect(protocol.state.activeRoles, isNotEmpty);
      expect(protocol.state.connectionState, SendspinConnectionState.streaming);
      var frames = 0;
      protocol.onAudioFrame = (_) => frames++;
      server.sendMessage(_audioChunk());
      expect(frames, 1);
    });

    test('clock sync pauses during it and resumes afterwards', () {
      fakeAsync((async) {
        final p = _protocol(
            pskCandidates: () => [SendspinPskCandidate.pairing(_pairingPsk)]);
        final s = connect(p);
        s.startRehandshake(_pairingPsk, 'pr');
        async.elapse(const Duration(seconds: 30));
        expect(sentOfType(p, 'client/time'), isEmpty);

        s.sendJson('server/activate', {
          'activities': ['playback']
        });
        expect(sentOfType(p, 'client/time'), hasLength(1));
        p.dispose();
      });
    });

    test('the activation is judged against the newly matched PSK', () {
      // After re-handshaking to the pairing PSK, pairing_psk is admissible.
      server.startRehandshake(_pairingPsk, 'pr');
      server.sendJson('server/activate', {
        'activities': ['pairing'],
        'pairing': {'method': 'pairing_psk'},
      });
      expect(protocol.state.activities, {'pairing'});
      expect(sentOfType(protocol, 'pair/abort'), isEmpty);
    });
  });

  group('message handling once activated', () {
    test('unknown JSON types and binary IDs are ignored', () {
      final protocol = _protocol();
      final closes = <String>[];
      protocol.onClose = closes.add;
      final server = connect(protocol);
      server.sendJson('future/message', {'x': 1});
      server.sendMessage(Uint8List.fromList([200, 1, 2, 3]));
      server.sendMessage(Uint8List.fromList([2]));
      expect(closes, isEmpty);
      expect(server.receivedJson, isEmpty);
    });

    test('audio chunks are dropped while the player role is inactive', () {
      final protocol = _protocol();
      var frames = 0;
      protocol.onAudioFrame = (_) => frames++;
      final server = connect(protocol, roles: ['metadata@v1']);
      server.sendMessage(_audioChunk());
      expect(frames, 0);
    });

    test('player commands are ignored while the player role is inactive', () {
      final protocol = _protocol();
      final server = connect(protocol, roles: ['metadata@v1']);
      server.sendJson('server/command', {
        'player': {'command': 'volume', 'volume': 10},
      });
      expect(protocol.state.volume, 1.0);
      expect(server.receivedJson, isEmpty);
    });

    test('stream/end for another role leaves the player stream running', () {
      final protocol = _protocol();
      var ended = 0;
      protocol.onStreamEnd = () => ended++;
      final server = connect(protocol);
      server.sendJsonText(_streamStart());
      server.sendJson('stream/end', {
        'roles': ['artwork']
      });
      expect(ended, 0);
      server.sendJson('stream/end');
      expect(ended, 1);
    });

    test('stream/clear for another role does not clear the player', () {
      final protocol = _protocol();
      var cleared = 0;
      protocol.onStreamClear = () => cleared++;
      final server = connect(protocol);
      server.sendJsonText(_streamStart());
      server.sendJson('stream/clear', {
        'roles': ['visualizer']
      });
      expect(cleared, 0);
      server.sendJson('stream/clear', {
        'roles': ['player']
      });
      expect(cleared, 1);
    });
  });

  group('resetForNewConnection', () {
    test('allows a fresh connection and clears per-connection state', () {
      final protocol = _protocol();
      connect(protocol);
      protocol.resetForNewConnection();

      expect(protocol.state.activeRoles, isEmpty);
      expect(protocol.state.activities, isEmpty);
      expect(protocol.state.serverId, isNull);
      expect(protocol.serverId, isNull);
      expect(protocol.state.connectionState, SendspinConnectionState.disabled);

      final server = connect(protocol, activate: false);
      expect(server.isEstablished, isTrue);
      expect(sentOfType(protocol, 'client/state'), isEmpty,
          reason: 'the new connection is gated until its own activation');
      activate(server, protocol);
      expect(protocol.state.activeRoles, isNotEmpty);
    });

    test('keeps the local volume and mute settings', () {
      final protocol = _protocol();
      connect(protocol);
      protocol.updateVolume(0.25);
      protocol.resetForNewConnection();
      expect(protocol.state.volume, 0.25);
    });
  });
}
