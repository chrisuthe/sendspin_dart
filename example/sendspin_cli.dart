// ABOUTME: Minimal command-line Sendspin player built on SendspinPlayer.
// ABOUTME: Connects to a server, logs the session, and writes the audio
// ABOUTME: as raw PCM if asked to.
//
// Usage: dart run example/sendspin_cli.dart ws://host:8927/sendspin
//          [--seconds N] [--key-file PATH] [--pairing-file PATH]
//          [--token-file PATH] [--no-unpaired] [--name NAME]
//          [--pcm-out PATH|-] [--latency-ms N] [--artwork]
//          [--send-command NAME]
//
// With `--pcm-out -` the decoded audio goes to stdout as 16-bit little-endian
// PCM and the log goes to stderr, e.g.
//   dart run example/sendspin_cli.dart ws://host:8927/sendspin --pcm-out - \
//     | aplay -f S16_LE -r 48000 -c 2
import 'dart:async';
import 'dart:convert';
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

/// Keeps the pairing PSK and pairing records in a JSON file.
class FilePairingStore implements SendspinPairingStore {
  final File file;
  FilePairingStore(String path) : file = File(path);

  @override
  Future<SendspinPairingData?> load() async => await file.exists()
      ? SendspinPairingData.fromJson(
          jsonDecode(await file.readAsString()) as Map<String, dynamic>)
      : null;

  @override
  Future<void> save(SendspinPairingData data) =>
      file.writeAsString(jsonEncode(data.toJson()), flush: true);
}

String? _option(List<String> args, String name) {
  final i = args.indexOf(name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
}

void _log(String line) => stderr.writeln(line);

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first.startsWith('--')) {
    stderr.writeln('usage: sendspin_cli.dart ws://host:port/sendspin '
        '[--seconds N] [--key-file PATH] [--pairing-file PATH] '
        '[--token-file PATH] [--no-unpaired] [--name NAME] '
        '[--pcm-out PATH|-] [--latency-ms N] [--artwork] '
        '[--send-command NAME]');
    exit(64);
  }
  final url = args.first;
  final seconds = int.parse(_option(args, '--seconds') ?? '10');
  final keyFile = _option(args, '--key-file');

  final identity = keyFile == null
      ? SendspinIdentity.generate()
      : await SendspinIdentity.loadOrCreate(FileIdentityStore(keyFile));
  _log('client_id ${identity.clientId}');

  final pairingFile = _option(args, '--pairing-file');
  final pairing = pairingFile == null
      ? SendspinPairing.inMemory()
      : await SendspinPairing.load(FilePairingStore(pairingFile));
  final token = pairing.pairingToken(identity.publicKey);
  _log('pairing token $token (${pairing.records.length} pairing records)');
  final tokenFile = _option(args, '--token-file');
  if (tokenFile != null) await File(tokenFile).writeAsString(token);

  final player = SendspinPlayer(
    playerName: _option(args, '--name') ?? 'sendspin_dart example',
    identity: identity,
    bufferSeconds: 5,
    unpairedAccess: !args.contains('--no-unpaired'),
    pairing: pairing,
    additionalRoles: {
      SendspinRole.metadata,
      SendspinRole.controller,
      if (args.contains('--artwork')) SendspinRole.artwork,
    },
    artworkChannels: args.contains('--artwork')
        ? const [
            ArtworkChannel(
                source: 'album',
                format: 'jpeg',
                mediaWidth: 256,
                mediaHeight: 256),
          ]
        : null,
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
  player.onPaired = (serverId) => _log('paired with $serverId');
  player.onPairingAborted = (reason) => _log('pairing aborted: $reason');
  player.onActivate = (activities, roles) =>
      _log('activate activities=$activities roles=$roles '
          'paired=${player.isPaired} server=${player.serverId}');
  player.onMetadataUpdate = (m) => _log('metadata title=${m.title} '
      'artist=${m.artist} position=${player.currentTrackPositionMs}ms');
  player.onGroupUpdate =
      (g) => _log('group ${g.groupName} ${g.playbackState?.wireValue}');
  player.onVolumeChanged = (v, m) => _log('volume $v muted=$m');
  player.onArtworkFrame = (frame) => _log(frame.imageData.isEmpty
      ? 'artwork channel ${frame.channel} cleared'
      : 'artwork channel ${frame.channel} ${frame.imageData.length} bytes '
          'jpeg=${frame.imageData[0] == 0xFF && frame.imageData[1] == 0xD8}');
  final commandToSend = _option(args, '--send-command');
  var commandSent = false;
  player.onControllerUpdate = (c) {
    _log('controller commands=${c.supportedCommands} volume=${c.volume} '
        'repeat=${c.repeat.wireValue} shuffle=${c.shuffle} '
        'seek_max_ms=${c.seekMaxMs}');
    if (commandToSend != null &&
        !commandSent &&
        player.canSendControllerCommand(commandToSend)) {
      commandSent = true;
      player.sendControllerCommand(commandToSend);
      _log('sent controller command $commandToSend');
    }
  };

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

  // Stand in for an audio device: a steady sample clock derived from the
  // local clock. Each tick pulls the frames that have become due and says
  // when they leave the "port": their position on that sample clock plus a
  // fixed pipeline latency.
  final pcmPath = _option(args, '--pcm-out');
  final IOSink? pcmOut = pcmPath == null
      ? null
      : (pcmPath == '-' ? stdout : File(pcmPath).openWrite());
  final latencyUs = int.parse(_option(args, '--latency-ms') ?? '100') * 1000;

  var pulled = 0;
  var audible = 0;
  var maxErrorUs = 0;
  var errorSamples = 0;
  var errorSumUs = 0;
  var dropped = 0;
  var inserted = 0;
  var resyncs = 0;
  var late = 0;
  var lastResyncCount = 0;
  int? deviceStartUs;
  var devicePulledFrames = 0;
  int? deviceRate;
  int? deviceChannels;

  void collectStats() {
    dropped += player.framesDropped;
    inserted += player.framesInserted;
    resyncs += player.resyncCount;
    late += player.lateChunksDropped;
  }

  player.onStreamStart = (rate, channels, depth) {
    _log('stream/start ${rate}Hz ${channels}ch ${depth}bit');
    // A new format restarts the stand-in device.
    deviceRate = rate;
    deviceChannels = channels;
    deviceStartUs = null;
    devicePulledFrames = 0;
    lastResyncCount = 0;
  };
  player.onStreamStop = () {
    collectStats();
    _log('stream/end');
    deviceRate = null;
  };

  final pump = Timer.periodic(const Duration(milliseconds: 5), (_) {
    final rate = deviceRate;
    final channels = deviceChannels;
    if (rate == null || channels == null) return;
    final now = player.nowUs();
    final start = deviceStartUs ??= now;
    final dueFrames = (now - start) * rate ~/ 1000000 - devicePulledFrames;
    if (dueFrames <= 0) return;
    final outputTimeUs =
        start + devicePulledFrames * 1000000 ~/ rate + latencyUs;
    final samples =
        player.pullSamples(dueFrames * channels, outputTimeUs: outputTimeUs);
    // A format change reported from inside the pull restarted the device.
    if (deviceStartUs == null) return;
    devicePulledFrames += dueFrames;
    pulled += samples.length;
    final nonZero = samples.where((s) => s != 0).length;
    audible += nonZero;
    // Steady-state error only: a pull that resynchronized measured the
    // error it then removed.
    final resynced = player.resyncCount != lastResyncCount;
    lastResyncCount = player.resyncCount;
    if (nonZero > 0 && !resynced) {
      final error = player.syncErrorUs.abs();
      if (error > maxErrorUs) maxErrorUs = error;
      errorSumUs += error;
      errorSamples++;
    }
    pcmOut?.add(Uint8List.view(samples.buffer));
  });

  player.start();
  final why = await done.future.timeout(Duration(seconds: seconds),
      onTimeout: () => 'time limit reached');
  pump.cancel();
  collectStats();
  // Let queued PCM drain before exiting, to a pipe as well as a file.
  await pcmOut?.flush();
  if (pcmOut != null && pcmOut != stdout) await pcmOut.close();

  final state = player.state;
  _log('done: $why');
  _log('summary roles=${state.activeRoles} activities=${state.activities} '
      'clock_samples=${state.clockSamples} pulled=$pulled audible=$audible');
  _log('sync resyncs=$resyncs dropped=$dropped inserted=$inserted '
      'late_chunks=$late max_error_us=$maxErrorUs '
      'mean_error_us=${errorSamples == 0 ? 0 : errorSumUs ~/ errorSamples} '
      'min_buffer_ms=${player.protocol.reportedMinBufferMs}');
  if (ws.readyState == WebSocket.open) {
    player.sendGoodbye(SendspinGoodbyeReason.shutdown);
  }
  await ws.close();
  player.dispose();
  exit(0);
}
