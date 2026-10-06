import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

import 'support/connected.dart';
import 'support/fake_server.dart';
import 'test_identity.dart';

const _pcm48 =
    AudioFormat(codec: 'pcm', channels: 2, sampleRate: 48000, bitDepth: 16);
const _pcm44 =
    AudioFormat(codec: 'pcm', channels: 2, sampleRate: 44100, bitDepth: 16);

SendspinProtocol _protocol({
  Set<SendspinRole> roles = const {SendspinRole.player},
  Set<SendspinPlayerCommand> supportedCommands = const {
    SendspinPlayerCommand.volume,
    SendspinPlayerCommand.mute,
    SendspinPlayerCommand.setOutputDelay,
  },
  int initialOutputDelayMs = 0,
  int requiredLeadTimeMs = 250,
  int minBufferMs = 250,
  List<ArtworkChannel>? artworkChannels,
  int Function()? now,
}) {
  final protocol = SendspinProtocol(
    playerName: 'P',
    identity: testIdentity,
    bufferSeconds: 5,
    unpairedAccess: true,
    roles: roles,
    supportedFormats: const [_pcm48, _pcm44],
    supportedCommands: supportedCommands,
    initialOutputDelayMs: initialOutputDelayMs,
    requiredLeadTimeMs: requiredLeadTimeMs,
    minBufferMs: minBufferMs,
    artworkChannels: artworkChannels,
    now: now,
  );
  addTearDown(protocol.dispose);
  return protocol;
}

void _synchronize(SendspinProtocol protocol) {
  protocol.clock.update(0, 100, 1);
  protocol.clock.update(0, 100, 2);
}

Map<String, dynamic> _lastState(Object target) =>
    sentOfType(target, 'client/state').last['payload'] as Map<String, dynamic>;

Map<String, dynamic> _built(SendspinProtocol protocol) =>
    (jsonDecode(protocol.buildClientState()) as Map<String, dynamic>)['payload']
        as Map<String, dynamic>;

/// Answers each client/time so the time filter converges on offset 0.
void _answerTime(FakeServer server) {
  server.onJson = (msg) {
    if (msg['type'] != 'client/time') return;
    final t = (msg['payload'] as Map)['client_transmitted'] as int;
    scheduleMicrotask(() => server.sendJson('server/time', {
          'client_transmitted': t,
          'server_received': t,
          'server_transmitted': t,
        }));
  };
}

void main() {
  group('client/state shape', () {
    test('carries available and the full rc1 player object', () {
      final protocol = _protocol(initialOutputDelayMs: 120);
      connect(protocol);
      _synchronize(protocol);

      final payload = _built(protocol);
      expect(payload.keys.toSet(), {'available', 'player'});
      expect(payload.containsKey('state'), isFalse);
      expect(payload['player'], {
        'volume': 100,
        'muted': false,
        'output_delay_ms': 120,
        'required_lead_time_ms': 250,
        'min_buffer_ms': 250,
        'supported_commands': ['volume', 'mute', 'set_output_delay'],
      });
    });

    test('omits the player object while the player role is inactive', () {
      final protocol =
          _protocol(roles: const {SendspinRole.player, SendspinRole.metadata});
      connect(protocol, roles: ['metadata@v1']);
      expect(_built(protocol), {'available': true});
    });

    test('reports only the commands the player accepts', () {
      final protocol =
          _protocol(supportedCommands: const {SendspinPlayerCommand.mute});
      connect(protocol);
      expect(_built(protocol)['player']['supported_commands'], ['mute']);
    });

    test('an empty command set is reported as an empty list', () {
      final protocol = _protocol(supportedCommands: const {});
      connect(protocol);
      expect(_built(protocol)['player']['supported_commands'], isEmpty);
    });

    test('output delay is clamped to 0-5000', () {
      final high = _protocol(initialOutputDelayMs: 9000);
      connect(high);
      expect(_built(high)['player']['output_delay_ms'], 5000);
      final low = _protocol(initialOutputDelayMs: -5);
      connect(low);
      expect(_built(low)['player']['output_delay_ms'], 0);
    });

    test('declares artwork channels with width and height', () {
      final protocol = _protocol(
        roles: const {SendspinRole.artwork},
        artworkChannels: const [
          ArtworkChannel(
              source: 'album',
              format: 'jpeg',
              mediaWidth: 300,
              mediaHeight: 200),
          ArtworkChannel(
              source: 'none', format: 'jpeg', mediaWidth: 0, mediaHeight: 0),
        ],
      );
      connect(protocol);
      expect(_built(protocol)['artwork'], {
        'channels': [
          {'source': 'album', 'format': 'jpeg', 'width': 300, 'height': 200},
          {'source': 'none'},
        ],
      });
    });
  });

  group('available', () {
    test('a player is not available until its time filter is synchronized', () {
      final protocol = _protocol();
      connect(protocol);
      expect(_built(protocol)['available'], isFalse);
      _synchronize(protocol);
      expect(_built(protocol)['available'], isTrue);
    });

    test('a client without the player role is available straight away', () {
      final protocol = _protocol(roles: const {SendspinRole.metadata});
      connect(protocol);
      expect(_built(protocol)['available'], isTrue);
    });

    test('the initial state after activation reports available false', () {
      final protocol = _protocol();
      final server = connect(protocol, activate: false);
      activate(server, protocol);
      final state = _lastState(protocol);
      expect(state['available'], isFalse);
      expect(state.containsKey('player'), isTrue,
          reason: 'the player object is due as soon as the role is active');
    });

    test('a new state is sent when the time filter becomes synchronized', () {
      fakeAsync((async) {
        final protocol =
            _protocol(now: () => 1000000 + async.elapsed.inMicroseconds);
        final server = connect(protocol, activate: false);
        _answerTime(server);
        activate(server, protocol);
        expect(_lastState(protocol)['available'], isFalse);

        // The second burst follows quickly while unsynchronized, so the
        // player does not sit unavailable for a whole burst interval.
        async.elapse(const Duration(seconds: 1));
        expect(protocol.clock.isSynchronized, isTrue);
        final states = sentOfType(protocol, 'client/state');
        expect(states, hasLength(2));
        expect(states.last['payload']['available'], isTrue);
        protocol.dispose();
      });
    });

    test('bursts return to the normal interval once synchronized', () {
      fakeAsync((async) {
        final protocol =
            _protocol(now: () => 1000000 + async.elapsed.inMicroseconds);
        final server = connect(protocol, activate: false);
        _answerTime(server);
        activate(server, protocol);
        async.elapse(const Duration(seconds: 1));
        final afterSync = protocol.clock.sampleCount;
        async.elapse(const Duration(seconds: 9));
        expect(protocol.clock.sampleCount, lessThanOrEqualTo(afterSync + 1));
        protocol.dispose();
      });
    });

    test('setAvailable(false) reports unavailable and true restores it', () {
      final protocol = _protocol();
      connect(protocol);
      _synchronize(protocol);

      protocol.setAvailable(false);
      expect(_lastState(protocol)['available'], isFalse);
      protocol.setAvailable(true);
      expect(_lastState(protocol)['available'], isTrue);
      expect(sentOfType(protocol, 'client/state'), hasLength(2));
    });

    test('setAvailable does not resend when nothing changed', () {
      final protocol = _protocol();
      connect(protocol);
      _synchronize(protocol);
      protocol.setAvailable(true);
      expect(sentOfType(protocol, 'client/state'), isEmpty);
    });

    test('stream messages are still processed while unavailable', () {
      final protocol = _protocol();
      StreamConfig? config;
      protocol.onStreamConfig = (c) => config = c;
      final server = connect(protocol);
      protocol.setAvailable(false);
      server.sendJson('stream/start', {
        'server_transmitted': 0,
        'player': {
          'codec': 'pcm',
          'sample_rate': 48000,
          'channels': 2,
          'bit_depth': 16
        },
      });
      expect(config, isNotNull);
    });

    test('sendLeave sends client/leave with an empty payload', () {
      final protocol = _protocol();
      connect(protocol);
      protocol.sendLeave();
      expect(sentBy(protocol).single,
          {'type': 'client/leave', 'payload': <String, dynamic>{}});
    });
  });

  group('player commands', () {
    late SendspinProtocol protocol;
    late FakeServer server;
    setUp(() {
      protocol = _protocol();
      server = connect(protocol);
      _synchronize(protocol);
    });

    void command(Map<String, dynamic> player) =>
        server.sendJson('server/command', {'player': player});

    test('set_output_delay updates the delay and reports it', () {
      final delays = <int>[];
      protocol.onOutputDelayChanged = delays.add;
      command({'command': 'set_output_delay', 'output_delay_ms': 340});

      expect(protocol.outputDelayMs, 340);
      expect(protocol.state.outputDelayMs, 340);
      expect(delays, [340]);
      expect(_lastState(protocol)['player']['output_delay_ms'], 340);
    });

    test('set_output_delay clamps to 0-5000', () {
      command({'command': 'set_output_delay', 'output_delay_ms': 99999});
      expect(protocol.outputDelayMs, 5000);
      command({'command': 'set_output_delay', 'output_delay_ms': -1});
      expect(protocol.outputDelayMs, 0);
    });

    test('the pre-rc1 set_static_delay command is not recognized', () {
      command({'command': 'set_static_delay', 'static_delay_ms': 340});
      expect(protocol.outputDelayMs, 0);
      expect(sentOfType(protocol, 'client/state'), isEmpty);
    });

    test('volume does not clear mute', () {
      command({'command': 'mute', 'mute': true});
      command({'command': 'volume', 'volume': 40});
      expect(protocol.state.muted, isTrue);
      expect(_lastState(protocol)['player'], containsPair('volume', 40));
      expect(_lastState(protocol)['player'], containsPair('muted', true));
    });

    test('commands absent from supported_commands are ignored', () {
      final limited =
          _protocol(supportedCommands: const {SendspinPlayerCommand.mute});
      final s = connect(limited);
      var changes = 0;
      limited.onVolumeChanged = (_, __) => changes++;
      limited.onOutputDelayChanged = (_) => changes++;

      s.sendJson('server/command', {
        'player': {'command': 'volume', 'volume': 10},
      });
      s.sendJson('server/command', {
        'player': {'command': 'set_output_delay', 'output_delay_ms': 200},
      });
      expect(limited.state.volume, 1.0);
      expect(limited.outputDelayMs, 0);
      expect(changes, 0);
      expect(sentOfType(limited, 'client/state'), isEmpty);

      s.sendJson('server/command', {
        'player': {'command': 'mute', 'mute': true},
      });
      expect(limited.state.muted, isTrue);
    });
  });

  group('local changes', () {
    late SendspinProtocol protocol;
    setUp(() {
      protocol = _protocol();
      connect(protocol);
      _synchronize(protocol);
    });

    test('setOutputDelayMs reports the new delay without the callback', () {
      final delays = <int>[];
      protocol.onOutputDelayChanged = delays.add;
      protocol.setOutputDelayMs(700);
      expect(_lastState(protocol)['player']['output_delay_ms'], 700);
      expect(protocol.outputDelayMs, 700);
      expect(delays, isEmpty);
    });

    test('updateMuted reports mute without touching volume', () {
      protocol.updateVolume(0.5);
      protocol.updateMuted(true);
      expect(_lastState(protocol)['player'], containsPair('muted', true));
      expect(_lastState(protocol)['player'], containsPair('volume', 50));
    });

    test('setTimingParameters reports lead time and minimum buffer', () {
      protocol.setTimingParameters(requiredLeadTimeMs: 80, minBufferMs: 400);
      final player = _lastState(protocol)['player'] as Map;
      expect(player['required_lead_time_ms'], 80);
      expect(player['min_buffer_ms'], 400);
    });

    test('setTimingParameters can change one value and keeps the other', () {
      protocol.setTimingParameters(requiredLeadTimeMs: 80);
      final player = _lastState(protocol)['player'] as Map;
      expect(player['required_lead_time_ms'], 80);
      expect(player['min_buffer_ms'], 250);
    });

    test('negative timing parameters are rejected', () {
      expect(() => protocol.setTimingParameters(minBufferMs: -1),
          throwsArgumentError);
    });

    test('preferredFormat is reported and can be cleared', () {
      protocol.preferredFormat = _pcm44;
      expect(_lastState(protocol)['player']['format'], {
        'codec': 'pcm',
        'channels': 2,
        'sample_rate': 44100,
        'bit_depth': 16,
      });
      protocol.preferredFormat = null;
      expect((_lastState(protocol)['player'] as Map).containsKey('format'),
          isFalse);
    });

    test('preferredFormat must be one of the supported formats', () {
      expect(
          () => protocol.preferredFormat = const AudioFormat(
              codec: 'flac', channels: 2, sampleRate: 96000, bitDepth: 24),
          throwsArgumentError);
    });

    test('setSupportedCommands is reported', () {
      protocol.setSupportedCommands(const {SendspinPlayerCommand.volume});
      expect(_lastState(protocol)['player']['supported_commands'], ['volume']);
    });
  });

  group('measured min_buffer_ms', () {
    test('raises the reported value above the configured minimum', () {
      var now = 0;
      final protocol = _protocol(minBufferMs: 20, now: () => now);
      // Synchronized before connecting, so the initial state already reports
      // available and the only later change is the measured buffer.
      _synchronize(protocol);
      final server = connect(protocol);
      server.sendJson('stream/start', {
        'server_transmitted': 0,
        'player': {
          'codec': 'pcm',
          'sample_rate': 48000,
          'channels': 2,
          'bit_depth': 16
        },
      });
      server.receivedJson.clear();

      Uint8List chunk(int timestampUs, int sendAheadUs) {
        final frame = Uint8List(13)..[0] = 4;
        ByteData.view(frame.buffer)
          ..setInt64(1, timestampUs, Endian.big)
          ..setUint32(9, sendAheadUs, Endian.big);
        return frame;
      }

      // Three 10 s windows of chunks that each arrive 85 ms after they were
      // sent. The first completed window produces the first report.
      for (var w = 0; w < 3; w++) {
        now = w * 10000000 + 85000;
        server.sendMessage(chunk(w * 10000000 + 500000, 500000));
      }
      expect(protocol.measuredMinBufferMs, 90);
      expect(_lastState(protocol)['player']['min_buffer_ms'], 90);
      expect(sentOfType(protocol, 'client/state'), hasLength(1),
          reason: 'sent once, when the debounced value changed');
    });

    test('never lowers the reported value below the configured minimum', () {
      final protocol = _protocol(minBufferMs: 250);
      connect(protocol);
      expect(_built(protocol)['player']['min_buffer_ms'], 250);
    });
  });
}
