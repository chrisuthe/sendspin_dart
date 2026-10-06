import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

import 'support/connected.dart';
import 'support/fake_server.dart';
import 'test_identity.dart';

/// The server clock runs this far ahead of the player's local clock.
const _offsetUs = 5000000;

const _frames = 480; // 10 ms at 48 kHz
const _count = _frames * 2;

/// A player on a manually advanced clock, connected and streaming.
class _Rig {
  int now = 1000000;
  late final SendspinPlayer player;
  late final FakeServer server;
  final List<(int, int, int)> starts = [];
  int stops = 0;

  _Rig({
    int initialOutputDelayMs = 0,
    bool synchronize = true,
    SendspinCodec? Function(String, int, int, int)? codecFactory,
  }) {
    player = SendspinPlayer(
      playerName: 'P',
      identity: testIdentity,
      bufferSeconds: 5,
      unpairedAccess: true,
      initialOutputDelayMs: initialOutputDelayMs,
      codecFactory: codecFactory,
      now: () => now,
    );
    addTearDown(player.dispose);
    player.onStreamStart = (r, c, b) => starts.add((r, c, b));
    player.onStreamStop = () => stops++;
    server = connect(player);
    if (synchronize) this.synchronize();
  }

  /// Seeds the time filter: server = local + [_offsetUs].
  void synchronize() {
    player.protocol.clock.update(_offsetUs, 100, 1);
    player.protocol.clock.update(_offsetUs, 100, 2);
  }

  void streamStart({
    int sampleRate = 48000,
    int channels = 2,
    int bitDepth = 16,
    String? codecHeader,
  }) =>
      server.sendJson('stream/start', {
        'server_transmitted': 0,
        'player': {
          'codec': 'pcm',
          'sample_rate': sampleRate,
          'channels': channels,
          'bit_depth': bitDepth,
          if (codecHeader != null) 'codec_header': codecHeader,
        },
      });

  /// Sends a PCM chunk due at local time [localUs]; the left sample of frame
  /// `i` is `first + i`.
  void chunk(int localUs, int first, {int frames = _frames, int channels = 2}) {
    final pcm = Int16List(frames * channels);
    for (var i = 0; i < frames; i++) {
      for (var c = 0; c < channels; c++) {
        pcm[i * channels + c] = first + i;
      }
    }
    final bytes = Uint8List.view(pcm.buffer);
    final message = Uint8List(13 + bytes.length)..[0] = 4;
    ByteData.view(message.buffer).setInt64(1, localUs + _offsetUs, Endian.big);
    message.setRange(13, message.length, bytes);
    server.sendMessage(message);
  }

  Int16List pull(int outputTimeUs, {int count = _count}) =>
      player.pullSamples(count, outputTimeUs: outputTimeUs);
}

/// Records what the player asks of its codec.
class _SpyCodec implements SendspinCodec {
  final String name;
  int decodes = 0;
  int resets = 0;
  bool disposed = false;
  _SpyCodec(this.name);

  @override
  Int16List decode(Uint8List data) {
    decodes++;
    final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
    return Int16List.fromList([
      for (var i = 0; i + 1 < data.length; i += 2)
        view.getInt16(i, Endian.little),
    ]);
  }

  @override
  void reset() => resets++;

  @override
  void dispose() => disposed = true;
}

void main() {
  group('scheduled playback', () {
    test('returns silence when not streaming', () {
      final rig = _Rig();
      expect(rig.pull(rig.now), everyElement(0));
    });

    test('plays audio at the local time its server timestamp maps to', () {
      final rig = _Rig()..streamStart();
      rig.chunk(2000000, 100);

      expect(rig.pull(1990000), everyElement(0), reason: 'not due yet');
      final out = rig.pull(2000000);
      expect(out.first, 100);
      expect(out.last, 100 + _frames - 1);
    });

    test('compensates the delay the consumer reports for its output path', () {
      // The consumer pulls at 1.95 s but says the samples reach the port at
      // 2.0 s (50 ms of backend buffering): it gets the audio due at 2.0 s.
      final rig = _Rig()..streamStart();
      rig.chunk(2000000, 100);
      rig.now = 1950000;
      expect(rig.pull(rig.player.nowUs() + 50000).first, 100);
    });

    test('nowUs is the clock pull times are expressed in', () {
      final rig = _Rig();
      rig.now = 4242;
      expect(rig.player.nowUs(), 4242);
    });

    test('returns silence until the time filter is synchronized', () {
      final rig = _Rig(synchronize: false)..streamStart();
      rig.chunk(2000000, 100);
      expect(rig.pull(2000000), everyElement(0));
      expect(rig.player.state.bufferDepthMs, 10,
          reason: 'nothing was consumed');
    });

    test('audio buffered before synchronization plays on time afterwards', () {
      // Scheduling uses the filter's estimate at the moment of the pull, so
      // a chunk received before the clock converged is still placed right.
      final rig = _Rig(synchronize: false)..streamStart();
      rig.chunk(2000000, 100);
      rig.synchronize();
      expect(rig.pull(1990000), everyElement(0));
      expect(rig.pull(2000000).first, 100);
    });

    test('reports buffer depth as audio arrives and is played', () {
      final rig = _Rig()..streamStart();
      rig.chunk(2000000, 100);
      rig.chunk(2010000, 600);
      expect(rig.player.state.bufferDepthMs, 20);
      rig.pull(2000000);
      expect(rig.player.state.bufferDepthMs, 10);
    });

    test('exposes the measured playback error', () {
      final rig = _Rig()..streamStart();
      for (var c = 0; c < 5; c++) {
        rig.chunk(2000000 + c * 10000, 100 + c * _frames);
      }
      rig.pull(2000000);
      // The filter's estimate moves 40 µs: the audio is now that much late.
      rig.player.protocol.clock.reset();
      rig.player.protocol.clock.update(_offsetUs + 40, 100, 1);
      rig.player.protocol.clock.update(_offsetUs + 40, 100, 2);
      rig.pull(2010000);
      expect(rig.player.syncErrorUs, 40);
    });
  });

  group('output delay', () {
    test('the initial delay moves playback earlier', () {
      final rig = _Rig(initialOutputDelayMs: 100)..streamStart();
      rig.chunk(2000000, 100);
      expect(rig.pull(1900000).first, 100);
    });

    test('set_output_delay applies to a running stream', () {
      final rig = _Rig()..streamStart();
      final delays = <int>[];
      rig.player.onOutputDelayChanged = delays.add;
      for (var c = 0; c < 20; c++) {
        rig.chunk(2000000 + c * 10000, 100 + c * _frames);
      }
      rig.pull(2000000);

      rig.server.sendJson('server/command', {
        'player': {'command': 'set_output_delay', 'output_delay_ms': 50},
      });
      expect(delays, [50]);
      // Everything is due 50 ms earlier now: 2400 frames are skipped.
      expect(rig.pull(2010000).first, 100 + _frames + 2400);
    });

    test('setOutputDelayMs applies to a running stream', () {
      final rig = _Rig()..streamStart();
      for (var c = 0; c < 20; c++) {
        rig.chunk(2000000 + c * 10000, 100 + c * _frames);
      }
      rig.pull(2000000);
      rig.player.setOutputDelayMs(50);
      expect(rig.pull(2010000).first, 100 + _frames + 2400);
    });
  });

  group('stream lifecycle', () {
    test('stream/start reports the format', () {
      final rig = _Rig()..streamStart(sampleRate: 44100, bitDepth: 24);
      expect(rig.starts, [(44100, 2, 24)]);
    });

    test('stream/clear discards buffered audio and playback carries on', () {
      final rig = _Rig()..streamStart();
      rig.chunk(2000000, 100);
      rig.chunk(2010000, 600);
      rig.pull(2000000);

      rig.server.sendJson('stream/clear');
      expect(rig.player.state.bufferDepthMs, 0);
      expect(rig.pull(2010000), everyElement(0));
      expect(rig.stops, 0);

      rig.chunk(2030000, 900);
      expect(rig.pull(2030000).first, 900);
    });

    test('stream/end stops output and a new stream starts fresh', () {
      final rig = _Rig()..streamStart();
      rig.chunk(2000000, 100);
      rig.server.sendJson('stream/end');
      expect(rig.stops, 1);
      expect(rig.pull(2000000), everyElement(0));

      rig.streamStart(sampleRate: 44100);
      expect(rig.starts, [(48000, 2, 16), (44100, 2, 16)]);
    });

    test('removing the player role stops output', () {
      final rig = _Rig()..streamStart();
      rig.chunk(2000000, 100);
      activate(rig.server, rig.player, roles: <String>[]);
      expect(rig.stops, 1);
      expect(rig.pull(2000000), everyElement(0));
    });

    test('resetForNewConnection drops the stream', () {
      final rig = _Rig()..streamStart();
      rig.chunk(2000000, 100);
      rig.player.resetForNewConnection();
      expect(rig.pull(2000000), everyElement(0));
    });
  });

  group('format change on a running stream', () {
    test('keeps buffered audio and reports the change where it takes effect',
        () {
      final rig = _Rig()..streamStart();
      rig.chunk(2000000, 100);

      // The server switches to 44.1 kHz mono; its audio continues the
      // timeline.
      rig.streamStart(sampleRate: 44100, channels: 1);
      expect(rig.starts, [(48000, 2, 16)],
          reason: 'not reported when the message arrives');
      rig.chunk(2010000, 5000, frames: 441, channels: 1);
      rig.chunk(2020000, 6000, frames: 441, channels: 1);

      // The 48 kHz audio that was already buffered still plays in full.
      final old = rig.pull(2000000);
      expect(old.first, 100);
      expect(old.last, 100 + _frames - 1);
      expect(rig.starts, hasLength(1));

      // Reaching the new audio reports the format from inside the pull.
      expect(rig.pull(2010000), everyElement(0));
      expect(rig.starts, [(48000, 2, 16), (44100, 1, 16)]);

      // Pulls sized for the new format get the new audio on schedule.
      expect(rig.pull(2020000, count: 441).first, 6000);
    });

    test('a new chunk is decoded with the codec in effect when it arrived', () {
      final codecs = <_SpyCodec>[];
      final rig = _Rig(codecFactory: (codec, depth, channels, rate) {
        final spy = _SpyCodec('$rate/$channels');
        codecs.add(spy);
        return spy;
      })
        ..streamStart();
      rig.chunk(2000000, 100);
      rig.streamStart(sampleRate: 44100, channels: 1);
      rig.chunk(2010000, 5000, frames: 441, channels: 1);

      expect(codecs.map((c) => c.name), ['48000/2', '44100/1']);
      expect(codecs[0].decodes, 1);
      expect(codecs[1].decodes, 1);
      expect(codecs[0].disposed, isTrue);
    });

    test('a stream/start that keeps rate and channels is not reported again',
        () {
      final rig = _Rig()..streamStart();
      rig.chunk(2000000, 100);
      rig.streamStart(bitDepth: 16);
      rig.chunk(2010000, 600);
      rig.pull(2000000);
      expect(rig.pull(2010000).first, 600, reason: 'no gap at the boundary');
      expect(rig.starts, hasLength(1));
    });
  });

  group('malformed stream/start', () {
    test('a format with a zero rate or channel count is ignored', () {
      for (final bad in [
        {'sample_rate': 0, 'channels': 2},
        {'sample_rate': 48000, 'channels': 0},
        {'sample_rate': -1, 'channels': 2},
      ]) {
        final rig = _Rig();
        rig.server.sendJson('stream/start', {
          'player': {'codec': 'pcm', 'bit_depth': 16, ...bad},
        });
        expect(rig.starts, isEmpty, reason: '$bad');
        rig.chunk(2000000, 100);
        expect(rig.pull(2000000), everyElement(0));
      }
    });

    test('a codec the player cannot build is reported, not thrown', () {
      final rig = _Rig();
      final errors = <Object>[];
      rig.player.onStreamError = errors.add;
      rig.server.sendJson('stream/start', {
        'player': {
          'codec': 'flac',
          'sample_rate': 48000,
          'channels': 2,
          'bit_depth': 16,
        },
      });
      expect(errors, hasLength(1));
      expect(rig.starts, isEmpty);
      rig.chunk(2000000, 100);
      expect(rig.pull(2000000), everyElement(0));
    });

    test('a bad codec header is reported, not thrown', () {
      final rig = _Rig();
      final errors = <Object>[];
      rig.player.onStreamError = errors.add;
      rig.server.sendJson('stream/start', {
        'player': {
          'codec': 'pcm',
          'sample_rate': 48000,
          'channels': 2,
          'bit_depth': 16,
          'codec_header': '!!! not base64 !!!',
        },
      });
      expect(errors, hasLength(1));
    });
  });

  group('codec', () {
    test('the codec header is passed through the codec', () {
      _SpyCodec? codec;
      _Rig(codecFactory: (_, __, ___, ____) => codec = _SpyCodec('x'))
          .streamStart(codecHeader: base64.encode([1, 2, 3, 4]));
      expect(codec!.decodes, 1);
    });

    test('stream/clear resets the codec and stream/end disposes it', () {
      _SpyCodec? codec;
      final rig = _Rig(codecFactory: (_, __, ___, ____) {
        return codec = _SpyCodec('x');
      })
        ..streamStart();
      rig.server.sendJson('stream/clear');
      expect(codec!.resets, 1);
      rig.server.sendJson('stream/end');
      expect(codec!.disposed, isTrue);
    });
  });
}
