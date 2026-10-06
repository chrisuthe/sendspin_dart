import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

const _rate = 48000;
const _channels = 2;

/// 10 ms of stereo audio at 48 kHz.
const _pullFrames = 480;
const _pullUs = 10000;

/// A chunk of [frames] stereo frames whose samples identify their position:
/// the left sample of frame `i` is `first + i`, the right one its negative.
Int16List _ramp(int first, int frames, {int channels = _channels}) {
  final samples = Int16List(frames * channels);
  for (var i = 0; i < frames; i++) {
    samples[i * channels] = first + i;
    if (channels > 1) samples[i * channels + 1] = -(first + i);
  }
  return samples;
}

/// The left-channel value of each output frame.
List<int> _left(Int16List out, {int channels = _channels}) =>
    [for (var i = 0; i < out.length; i += channels) out[i]];

SendspinBuffer _buffer({int Function(int)? serverToLocalUs}) => SendspinBuffer(
      serverToLocalUs: serverToLocalUs ?? (t) => t,
      maxBufferMs: 10000,
    );

void _add(SendspinBuffer b, int timestampUs, Int16List samples,
        {int sampleRate = _rate, int channels = _channels}) =>
    b.addChunk(timestampUs, samples,
        sampleRate: sampleRate, channels: channels);

/// Adds [seconds] of contiguous 10 ms chunks starting at [startUs]; frame `n`
/// of the stream carries the value `1 + n` (wrapping within int16).
void _addStream(SendspinBuffer b, int startUs, {double seconds = 1}) {
  final chunks = (seconds * 100).round();
  for (var c = 0; c < chunks; c++) {
    final samples = Int16List(_pullFrames * _channels);
    for (var i = 0; i < _pullFrames; i++) {
      final v = ((1 + c * _pullFrames + i) % 30000) + 1;
      samples[i * 2] = v;
      samples[i * 2 + 1] = -v;
    }
    _add(b, startUs + c * _pullUs, samples);
  }
}

void main() {
  group('scheduling against the local clock', () {
    test('returns silence when nothing is buffered', () {
      final b = _buffer();
      expect(b.pullSamples(960, 0), everyElement(0));
    });

    test('plays a chunk at the local time of its timestamp', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      final out = b.pullSamples(_pullFrames * 2, 1000000);
      expect(_left(out), List.generate(_pullFrames, (i) => 100 + i));
      expect(out[1], -100, reason: 'channels stay interleaved');
    });

    test('holds a chunk whose time has not come', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      expect(b.pullSamples(_pullFrames * 2, 500000), everyElement(0));
      expect(b.bufferDepthMs, 10, reason: 'nothing was consumed');
    });

    test('starts mid-pull with silence in front when early', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      // The pull begins 5 ms (240 frames) before the chunk is due.
      final left = _left(b.pullSamples(_pullFrames * 2, 995000));
      expect(left.sublist(0, 240), everyElement(0));
      expect(left.sublist(240), List.generate(240, (i) => 100 + i));
    });

    test('drops a leading prefix when late', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      // The pull begins 5 ms after the chunk was due.
      final left = _left(b.pullSamples(_pullFrames * 2, 1005000));
      expect(left.sublist(0, 240), List.generate(240, (i) => 340 + i));
      expect(left.sublist(240), everyElement(0), reason: 'ran out of audio');
    });

    test('drops whole chunks that are entirely in the past', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      _add(b, 1010000, _ramp(1000, _pullFrames));
      final left = _left(b.pullSamples(_pullFrames * 2, 1010000));
      expect(left.first, 1000);
    });

    test('translates timestamps through the supplied clock mapping', () {
      // server = local + 2 s
      final b = _buffer(serverToLocalUs: (t) => t - 2000000);
      _add(b, 3000000, _ramp(100, _pullFrames));
      expect(_left(b.pullSamples(_pullFrames * 2, 1000000)).first, 100);
    });

    test('plays contiguous chunks back to back without corrections', () {
      final b = _buffer();
      _addStream(b, 1000000);
      final played = <int>[];
      for (var p = 0; p < 100; p++) {
        played.addAll(
            _left(b.pullSamples(_pullFrames * 2, 1000000 + p * _pullUs)));
      }
      expect(played, List.generate(48000, (i) => ((1 + i) % 30000) + 1));
      expect(b.framesDropped, 0);
      expect(b.framesInserted, 0);
      expect(b.resyncCount, 1, reason: 'only the startup snap');
    });

    test('chunks may arrive out of order', () {
      final b = _buffer();
      _add(b, 1010000, _ramp(1000, _pullFrames));
      _add(b, 1000000, _ramp(100, _pullFrames));
      expect(_left(b.pullSamples(_pullFrames * 2, 1000000)).first, 100);
      expect(_left(b.pullSamples(_pullFrames * 2, 1010000)).first, 1000);
    });

    test('a duplicate timestamp is ignored', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      _add(b, 1000000, _ramp(900, _pullFrames));
      expect(b.bufferDepthMs, 10);
      expect(_left(b.pullSamples(_pullFrames * 2, 1000000)).first, 100);
    });

    test('a pull size that is not a whole number of frames is rejected', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      b.pullSamples(960, 1000000);
      expect(() => b.pullSamples(961, 1010000), throwsArgumentError);
    });
  });

  group('output delay', () {
    test('is subtracted from the translated timestamp', () {
      final b = _buffer()..outputDelayMs = 100;
      _add(b, 1000000, _ramp(100, _pullFrames));
      // Due 100 ms earlier on the local clock.
      expect(b.pullSamples(_pullFrames * 2, 800000), everyElement(0));
      expect(_left(b.pullSamples(_pullFrames * 2, 900000)).first, 100);
    });

    test('an increase mid-stream skips ahead and playback continues', () {
      final b = _buffer();
      _addStream(b, 1000000);
      b.pullSamples(_pullFrames * 2, 1000000);
      b.outputDelayMs = 50;
      // Everything is now due 50 ms earlier: 2400 frames are skipped.
      final left = _left(b.pullSamples(_pullFrames * 2, 1010000));
      expect(left.first, 1 + 480 + 2400 + 1);
      expect(b.resyncCount, 2);
    });

    test('a decrease mid-stream waits with silence and stays operational', () {
      final b = _buffer()..outputDelayMs = 50;
      _addStream(b, 1000000);
      b.pullSamples(_pullFrames * 2, 950000);
      b.outputDelayMs = 0;
      // The next frame is now due 50 ms later.
      for (var p = 1; p <= 5; p++) {
        expect(b.pullSamples(_pullFrames * 2, 950000 + p * _pullUs),
            everyElement(0));
      }
      final left = _left(b.pullSamples(_pullFrames * 2, 1010000));
      expect(left.first, 1 + 480 + 1);
    });
  });

  group('one-shot resynchronization', () {
    test('an underrun is followed by a snap to the next chunk', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      b.pullSamples(_pullFrames * 2, 1000000);
      expect(b.pullSamples(_pullFrames * 2, 1010000), everyElement(0));

      // Audio resumes 30 ms later, 2 ms into a pull.
      _add(b, 1042000, _ramp(500, _pullFrames));
      final left = _left(b.pullSamples(_pullFrames * 2, 1040000));
      expect(left.sublist(0, 96), everyElement(0));
      expect(left[96], 500);
    });

    test('a missing chunk becomes silence of the same length', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      // The chunk for 1.010 s never arrives.
      _add(b, 1020000, _ramp(2000, _pullFrames));
      _left(b.pullSamples(_pullFrames * 2, 1000000));
      expect(b.pullSamples(_pullFrames * 2, 1010000), everyElement(0));
      expect(_left(b.pullSamples(_pullFrames * 2, 1020000)).first, 2000);
    });

    test('a gap inside one pull is filled with silence in place', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, 240));
      // 5 ms of audio, a 2 ms hole, then more audio.
      _add(b, 1007000, _ramp(700, 240));
      final left = _left(b.pullSamples(_pullFrames * 2, 1000000));
      expect(left.sublist(0, 240), List.generate(240, (i) => 100 + i));
      expect(left.sublist(240, 336), everyElement(0));
      expect(left[336], 700);
    });

    test('an error beyond 1 ms is corrected in one step, not gradually', () {
      final b = _buffer();
      _addStream(b, 1000000);
      b.pullSamples(_pullFrames * 2, 1000000);
      // The output clock jumps 3 ms ahead of the audio.
      final left = _left(b.pullSamples(_pullFrames * 2, 1013000));
      expect(left.first, 1 + 480 + 144 + 1);
      expect(b.resyncCount, 2);
      expect(b.framesDropped, 0, reason: 'a resync is not a soft correction');
    });

    test('flush discards everything and the next chunk starts cleanly', () {
      final b = _buffer();
      _addStream(b, 1000000);
      b.pullSamples(_pullFrames * 2, 1000000);
      b.flush();
      expect(b.bufferDepthMs, 0);
      expect(b.pullSamples(_pullFrames * 2, 1010000), everyElement(0));

      _add(b, 5000000, _ramp(100, _pullFrames));
      expect(_left(b.pullSamples(_pullFrames * 2, 5000000)).first, 100);
    });
  });

  group('late chunks', () {
    test('a chunk that arrives after its time has passed is dropped', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      b.pullSamples(_pullFrames * 2, 1000000);
      b.pullSamples(_pullFrames * 2, 1010000);

      _add(b, 1005000, _ramp(900, 240));
      expect(b.bufferDepthMs, 0);
      expect(b.lateChunksDropped, 1);
    });

    test('a chunk that is only partly late is kept', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      b.pullSamples(_pullFrames * 2, 1000000);
      _add(b, 1005000, _ramp(900, _pullFrames));
      expect(b.bufferDepthMs, 10);
    });
  });

  group('steady-state correction', () {
    /// Plays one second with the output clock running [ppm] parts per
    /// million fast (positive) or slow relative to the audio, and returns
    /// the buffer.
    SendspinBuffer playWithDrift(int ppm, {int pullFrames = _pullFrames}) {
      final b = _buffer();
      _addStream(b, 1000000, seconds: 3);
      final pullUs = pullFrames * 1000000 / _rate;
      final pulls = (2 * _rate / pullFrames).round();
      for (var p = 0; p < pulls; p++) {
        final t = 1000000 + p * pullUs * (1 + ppm / 1e6);
        b.pullSamples(pullFrames * 2, t.round());
      }
      return b;
    }

    test('an error inside the dead band is left alone', () {
      final b = _buffer();
      _addStream(b, 1000000);
      b.pullSamples(_pullFrames * 2, 1000000);
      // 60 µs late: under the 100 µs dead band.
      final left = _left(b.pullSamples(_pullFrames * 2, 1010060));
      expect(left.first, 1 + 480 + 1);
      expect(b.framesDropped, 0);
      expect(b.framesInserted, 0);
      expect(b.syncErrorUs, 60);
    });

    test('running late drops single frames to catch up', () {
      final b = playWithDrift(200);
      expect(b.framesDropped, greaterThan(0));
      expect(b.framesInserted, 0);
      expect(b.resyncCount, 1, reason: 'drift is absorbed without resyncing');
      expect(b.syncErrorUs.abs(), lessThan(200));
    });

    test('running early duplicates single frames to wait', () {
      final b = playWithDrift(-200);
      expect(b.framesInserted, greaterThan(0));
      expect(b.framesDropped, 0);
      expect(b.resyncCount, 1);
      expect(b.syncErrorUs.abs(), lessThan(200));
    });

    test('corrects by one frame per pull at 48 kHz', () {
      final b = _buffer();
      _addStream(b, 1000000);
      b.pullSamples(_pullFrames * 2, 1000000);
      // 500 µs late: 24 frames behind, but only one is dropped now.
      final left = _left(b.pullSamples(_pullFrames * 2, 1010500));
      expect(b.framesDropped, 1);
      expect(left.first, 1 + 480 + 1 + 1);
      // The rest of the pull is untouched audio.
      expect(left.last, left.first + 479);
    });

    test('a duplicated frame repeats and the rest is bit-exact', () {
      final b = _buffer();
      _addStream(b, 1000000);
      b.pullSamples(_pullFrames * 2, 1000000);
      // 500 µs early.
      final left = _left(b.pullSamples(_pullFrames * 2, 1009500));
      expect(b.framesInserted, 1);
      expect(left[0], left[1]);
      expect(left.last, left[1] + 478);
    });

    test('the correction rate stays within 0.5% over any 150 ms', () {
      for (final pullFrames in [64, 128, 480, 1024, 4800]) {
        final b = _buffer();
        _addStream(b, 1000000, seconds: 3);
        final pullUs = pullFrames * 1000000 / _rate;
        // Aligned at startup, then the output clock sits 900 µs ahead: an
        // error that always wants correcting but never forces a resync.
        final history = <(double, int)>[];
        var corrected = 0;
        for (var p = 0; p * pullUs < 2000000; p++) {
          final t = 1000000 + p * pullUs;
          b.pullSamples(pullFrames * 2, (t + (p == 0 ? 0 : 900)).round());
          final now = b.framesDropped + b.framesInserted;
          history.add((t, now - corrected));
          corrected = now;
          // Sum corrections over the trailing 150 ms.
          final window = history
              .where((h) => h.$1 > t - 150000)
              .fold<int>(0, (sum, h) => sum + h.$2);
          expect(window, lessThanOrEqualTo((0.005 * 0.150 * _rate).floor()),
              reason: 'pull of $pullFrames frames at ${t.round()} us');
        }
        expect(corrected, greaterThan(0), reason: 'pull of $pullFrames frames');
      }
    });

    test('scales the step with the sample rate', () {
      SendspinBuffer at(int rate) {
        final b = _buffer();
        final frames = rate ~/ 100;
        for (var c = 0; c < 10; c++) {
          b.addChunk(1000000 + c * 10000, Int16List(frames * 2),
              sampleRate: rate, channels: 2);
        }
        b.pullSamples(frames * 2, 1000000);
        b.pullSamples(frames * 2, 1010500);
        return b;
      }

      expect(at(44100).framesDropped, 1);
      expect(at(96000).framesDropped, 2);
      expect(at(192000).framesDropped, 4);
    });
  });

  group('format changes', () {
    test('chunks keep the format they were added with', () {
      final b = _buffer();
      final changes = <(int, int)>[];
      b.onFormatChange = (rate, channels) => changes.add((rate, channels));

      _add(b, 1000000, _ramp(100, _pullFrames));
      // The next chunk continues the timeline at 44.1 kHz mono.
      _add(b, 1010000, _ramp(5000, 441, channels: 1),
          sampleRate: 44100, channels: 1);

      expect(_left(b.pullSamples(_pullFrames * 2, 1000000)).last, 579);
      expect(changes, isEmpty, reason: 'still inside the 48 kHz audio');

      // Reaching the new chunk reports the change and plays nothing of it
      // into a pull that was sized for the old format.
      expect(b.pullSamples(_pullFrames * 2, 1010000), everyElement(0));
      expect(changes, [(44100, 1)]);
      expect(b.sampleRate, 44100);
      expect(b.channels, 1);

      // The consumer now pulls in the new format and gets the new audio at
      // the right place on the timeline.
      final out = b.pullSamples(441, 1020000);
      expect(out, everyElement(0), reason: 'that audio was due at 1.010 s');
    });

    test('a format change mid-pull ends that pull with silence', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, 240));
      _add(b, 1005000, _ramp(5000, 441, channels: 1),
          sampleRate: 44100, channels: 1);
      final left = _left(b.pullSamples(_pullFrames * 2, 1000000));
      expect(left.sublist(0, 240), List.generate(240, (i) => 100 + i));
      expect(left.sublist(240), everyElement(0));
    });

    test('the first chunk sets the format without a change notification', () {
      final b = _buffer();
      var changes = 0;
      b.onFormatChange = (_, __) => changes++;
      _add(b, 1000000, _ramp(100, 441, channels: 1),
          sampleRate: 44100, channels: 1);
      expect(b.pullSamples(441, 1000000).first, 100);
      expect(changes, 0);
    });

    test('new-format audio plays on schedule after the switch', () {
      final b = _buffer();
      _add(b, 1000000, _ramp(100, _pullFrames));
      for (var c = 0; c < 5; c++) {
        _add(b, 1010000 + c * 10000, _ramp(5000 + c * 441, 441, channels: 1),
            sampleRate: 44100, channels: 1);
      }
      b.pullSamples(_pullFrames * 2, 1000000);
      b.pullSamples(_pullFrames * 2, 1010000); // reports the change
      // Pulling 10 ms of mono 44.1 kHz for the slot starting at 1.020 s.
      expect(b.pullSamples(441, 1020000).first, 5441);
    });
  });

  group('buffer accounting', () {
    test('bufferDepthMs counts what has not been played', () {
      final b = _buffer();
      _addStream(b, 1000000, seconds: 0.5);
      expect(b.bufferDepthMs, 500);
      b.pullSamples(_pullFrames * 2, 1000000);
      expect(b.bufferDepthMs, 490);
    });

    test('the oldest audio is trimmed beyond maxBufferMs', () {
      final b = SendspinBuffer(serverToLocalUs: (t) => t, maxBufferMs: 100);
      _addStream(b, 1000000, seconds: 0.5);
      expect(b.bufferDepthMs, 100);
      // What is left is the newest 100 ms.
      final left = _left(b.pullSamples(_pullFrames * 2, 1400000));
      expect(left.first, 1 + 40 * 480 + 1);
    });
  });
}
