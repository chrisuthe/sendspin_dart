// ABOUTME: Minimal command-line Sendspin player built on SendspinPlayer.
// ABOUTME: Connects to a server, logs the session and discards the audio.
//
// Usage: dart run example/sendspin_cli.dart ws://host:8927/sendspin
//          [--seconds N] [--key-file PATH] [--no-unpaired] [--name NAME]
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:sendspin_dart/sendspin_dart.dart';

/// Keeps the identity's private key in a file so the client_id is stable
/// across runs.
class FileIdentityStore implements SendspinIdentityStore {
  final File file;
  FileIdentityStore(String path) : file = File(path);

  @override
  Future<Uint8List?> loadPrivateKey() async =>
      await file.exists() ? await file.readAsBytes() : null;

  @override
  Future<void> savePrivateKey(Uint8List privateKey) =>
      file.writeAsBytes(privateKey, flush: true);
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

void _log(String line) => stdout.writeln(line);

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first.startsWith('--')) {
    stderr.writeln('usage: sendspin_cli.dart ws://host:port/sendspin '
        '[--seconds N] [--key-file PATH] [--no-unpaired] [--name NAME]');
    exit(64);
  }
  final url = args.first;
  final seconds = int.parse(_option(args, '--seconds') ?? '10');
  final keyFile = _option(args, '--key-file');

  final identity = keyFile == null
      ? SendspinIdentity.generate()
      : await SendspinIdentity.loadOrCreate(FileIdentityStore(keyFile));
  _log('client_id ${identity.clientId}');

  final player = SendspinPlayer(
    playerName: _option(args, '--name') ?? 'sendspin_dart example',
    identity: identity,
    bufferSeconds: 5,
    unpairedAccess: !args.contains('--no-unpaired'),
    additionalRoles: const {SendspinRole.metadata, SendspinRole.controller},
  );

  final ws = await WebSocket.connect(url);
  final done = Completer<String>();
  void finish(String why) {
    if (!done.isCompleted) done.complete(why);
  }

  player.onSendText = ws.add;
  player.onSendBinary = ws.add;
  player.onClose = (reason) => finish('closed: $reason');
  player.onServerError = (reason) => _log('server/error $reason');
  player.onActivate = (activities, roles) =>
      _log('activate activities=$activities roles=$roles '
          'paired=${player.isPaired} server=${player.serverId}');
  player.onStreamStart = (rate, channels, depth) =>
      _log('stream/start ${rate}Hz ${channels}ch ${depth}bit');
  player.onStreamStop = () => _log('stream/end');
  player.onMetadataUpdate = (m) => _log('metadata title=${m.title} '
      'artist=${m.artist} position=${player.currentTrackPositionMs}ms');
  player.onGroupUpdate =
      (g) => _log('group ${g.groupName} ${g.playbackState?.wireValue}');
  player.onVolumeChanged = (v, m) => _log('volume $v muted=$m');

  ws.listen(
    (message) {
      if (message is String) {
        player.handleTextMessage(message);
      } else {
        player.handleBinaryMessage(Uint8List.fromList(message as List<int>));
      }
    },
    onDone: () => finish('socket closed code=${ws.closeCode}'),
    onError: (Object e) => finish('socket error: $e'),
  );

  // Drain the buffer the way an audio callback would: 10 ms at a time.
  var pulled = 0;
  var audible = 0;
  final pump = Timer.periodic(const Duration(milliseconds: 10), (_) {
    final rate = player.state.sampleRate;
    final channels = player.state.channels;
    if (rate == null || channels == null) return;
    final samples = player.pullSamples(rate ~/ 100 * channels);
    pulled += samples.length;
    audible += samples.where((s) => s != 0).length;
  });

  player.start();
  final why = await done.future.timeout(Duration(seconds: seconds),
      onTimeout: () => 'time limit reached');
  pump.cancel();

  final state = player.state;
  _log('done: $why');
  _log('summary roles=${state.activeRoles} activities=${state.activities} '
      'clock_samples=${state.clockSamples} pulled=$pulled audible=$audible');
  if (ws.readyState == WebSocket.open) {
    player.sendGoodbye(SendspinGoodbyeReason.shutdown);
  }
  await ws.close();
  player.dispose();
  exit(0);
}
