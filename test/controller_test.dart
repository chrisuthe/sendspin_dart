import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

import 'support/connected.dart';
import 'support/fake_server.dart';
import 'test_identity.dart';

void main() {
  late SendspinProtocol protocol;
  late FakeServer server;

  setUp(() {
    protocol = SendspinProtocol(
      playerName: 'Remote',
      identity: testIdentity,
      bufferSeconds: 0,
      unpairedAccess: true,
      roles: const {SendspinRole.controller, SendspinRole.metadata},
    );
    addTearDown(protocol.dispose);
    server = connect(protocol);
  });

  void controllerState(Map<String, dynamic> controller) =>
      server.sendJson('server/state', {'controller': controller});

  Map<String, dynamic> lastCommand() =>
      (sentOfType(protocol, 'client/command').last['payload']
          as Map)['controller'] as Map<String, dynamic>;

  group('controller state', () {
    test('parses repeat, shuffle and seek_max_ms', () {
      controllerState({
        'supported_commands': ['play', 'seek'],
        'volume': 40,
        'muted': true,
        'repeat': 'all',
        'shuffle': true,
        'seek_max_ms': 215000,
      });
      final c = protocol.state.controller!;
      expect(c.supportedCommands, ['play', 'seek']);
      expect(c.volume, 40);
      expect(c.muted, isTrue);
      expect(c.repeat, SendspinRepeatMode.all);
      expect(c.shuffle, isTrue);
      expect(c.seekMaxMs, 215000);
    });

    test('seek_max_ms is absent when the range is unknown', () {
      controllerState({
        'supported_commands': ['play', 'seek_relative'],
        'volume': 40,
        'muted': false,
        'repeat': 'off',
        'shuffle': false,
      });
      expect(protocol.state.controller!.seekMaxMs, isNull);
      expect(protocol.state.controller!.repeat, SendspinRepeatMode.off);
    });

    test('each state replaces the previous one', () {
      controllerState({
        'supported_commands': ['seek'],
        'volume': 1,
        'muted': false,
        'repeat': 'one',
        'shuffle': true,
        'seek_max_ms': 1000,
      });
      controllerState({
        'supported_commands': ['play'],
        'volume': 2,
        'muted': false,
        'repeat': 'off',
        'shuffle': false,
      });
      expect(protocol.state.controller!.seekMaxMs, isNull);
      expect(protocol.state.controller!.shuffle, isFalse);
    });

    test('repeat and shuffle are not read from the metadata object', () {
      server.sendJson('server/state', {
        'metadata': {'timestamp': 0, 'title': 'T', 'repeat': 'all'},
      });
      // The fields no longer exist on SendspinMetadata; the state parses.
      expect(protocol.state.metadata!.title, 'T');
    });
  });

  group('commands follow supported_commands', () {
    test('a command is refused before any controller state has arrived', () {
      expect(() => protocol.sendControllerCommand('play'), throwsStateError);
      expect(sentOfType(protocol, 'client/command'), isEmpty);
    });

    test('a listed command is sent', () {
      allowControllerCommands(protocol, ['play', 'next']);
      protocol.sendControllerCommand('next');
      expect(lastCommand(), {'command': 'next'});
    });

    test('a command the server does not list is refused', () {
      allowControllerCommands(protocol, ['play']);
      expect(() => protocol.sendControllerCommand('next'), throwsStateError);
      expect(() => protocol.sendControllerVolume(10), throwsStateError);
      expect(() => protocol.sendControllerMute(true), throwsStateError);
      expect(sentOfType(protocol, 'client/command'), isEmpty);
    });

    test('the list in force is the latest one', () {
      allowControllerCommands(protocol, ['play', 'next']);
      allowControllerCommands(protocol, ['play']);
      expect(() => protocol.sendControllerCommand('next'), throwsStateError);
    });

    test('canSendControllerCommand reports what is currently allowed', () {
      expect(protocol.canSendControllerCommand('play'), isFalse);
      allowControllerCommands(protocol, ['play']);
      expect(protocol.canSendControllerCommand('play'), isTrue);
      expect(protocol.canSendControllerCommand('seek'), isFalse);
    });
  });

  group('seek', () {
    test('seek sends an absolute position', () {
      allowControllerCommands(protocol, ['seek'], 200000);
      protocol.sendControllerSeek(90500);
      expect(lastCommand(), {'command': 'seek', 'position_ms': 90500});
    });

    test('seek accepts the ends of the range', () {
      allowControllerCommands(protocol, ['seek'], 200000);
      protocol.sendControllerSeek(0);
      protocol.sendControllerSeek(200000);
      expect(sentOfType(protocol, 'client/command'), hasLength(2));
    });

    test('seek outside 0..seek_max_ms is rejected', () {
      allowControllerCommands(protocol, ['seek'], 200000);
      expect(() => protocol.sendControllerSeek(-1), throwsRangeError);
      expect(() => protocol.sendControllerSeek(200001), throwsRangeError);
      expect(sentOfType(protocol, 'client/command'), isEmpty);
    });

    test('seek_relative sends a signed offset', () {
      allowControllerCommands(protocol, ['seek_relative']);
      protocol.sendControllerSeekRelative(-15000);
      expect(lastCommand(), {'command': 'seek_relative', 'offset_ms': -15000});
      protocol.sendControllerSeekRelative(30000);
      expect(lastCommand(), {'command': 'seek_relative', 'offset_ms': 30000});
    });

    test('seek is refused when only seek_relative is offered', () {
      allowControllerCommands(protocol, ['seek_relative']);
      expect(() => protocol.sendControllerSeek(1000), throwsStateError);
    });
  });
}
