// ABOUTME: Clock-scheduled jitter buffer for decoded PCM audio chunks.
// ABOUTME: Plays each frame at the local time its server timestamp maps to.
import 'dart:collection';
import 'dart:typed_data';

class _AudioChunk implements Comparable<_AudioChunk> {
  /// Server-clock time at which the first frame should be output.
  final int timestampUs;
  final Int16List samples;
  final int sampleRate;
  final int channels;

  /// Frames already consumed from the front.
  int offset = 0;

  _AudioChunk(this.timestampUs, this.samples, this.sampleRate, this.channels);

  int get frames => samples.length ~/ channels;
  int get remaining => frames - offset;

  /// Server-clock time of the next unconsumed frame.
  int get headUs => timestampUs + (offset * 1000000 / sampleRate).round();

  int get durationUs => (frames * 1000000 / sampleRate).round();

  @override
  int compareTo(_AudioChunk other) => timestampUs.compareTo(other.timestampUs);
}

/// Pull-based jitter buffer that schedules audio against the local clock.
///
/// Chunks carry server timestamps. Each [pullSamples] call says when its
/// first sample will reach the output, and the buffer returns exactly the
/// audio that is due then, translating timestamps through [serverToLocalUs]
/// (the time filter) at the moment of the pull and subtracting the output
/// delay.
///
/// Following the Sendspin player role:
///
/// - On startup, after [flush], after an underrun, and whenever the error
///   exceeds 1 ms, playback **snaps** to position in one step: a late prefix
///   is dropped, or silence is inserted until the audio is due.
/// - In steady state an error above a 100 µs dead band is corrected by
///   dropping or duplicating a few whole frames, never more than 0.5% of the
///   audio in any 150 ms. Everything else is passed through bit-exact.
/// - A chunk that arrives after its time has passed is dropped.
/// - Each chunk keeps the format it was added with, so a format change on a
///   running stream does not disturb the audio already buffered.
class SendspinBuffer {
  /// Translates a server timestamp to the local clock that [pullSamples] is
  /// given times in. Normally [SendspinClock.computeClientTime].
  final int Function(int serverTimeUs) serverToLocalUs;

  /// Upper bound on buffered audio; beyond it the oldest audio is dropped.
  final int maxBufferMs;

  /// Errors below this are not corrected.
  static const int deadbandUs = 100;

  /// Errors above this are corrected in one step instead of gradually.
  static const int resyncThresholdUs = 1000;

  /// Steady-state correction changes the playback speed by at most this
  /// fraction, measured over [speedWindowUs].
  static const double maxSpeedDeviation = 0.005;
  static const int speedWindowUs = 150000;

  /// Duration of one correction step; the frame count scales with the rate.
  static const int _correctionStepUs = 21;

  final SplayTreeSet<_AudioChunk> _chunks = SplayTreeSet();
  int _bufferedUs = 0;
  int _outputDelayUs = 0;

  int? _sampleRate;
  int? _channels;

  /// False until playback has been aligned to the timeline, and again after
  /// anything that breaks continuity.
  bool _synced = false;

  /// Local time just past the last sample handed out.
  int? _outputEndUs;

  /// Recent soft corrections as (output time, frames), for the speed limit.
  final Queue<(int, int)> _recentCorrections = Queue();

  int _lastSyncErrorUs = 0;
  int _framesDropped = 0;
  int _framesInserted = 0;
  int _resyncCount = 0;
  int _lateChunksDropped = 0;

  /// Called when playback reaches audio in a different format from the one
  /// being output. The pull in which this fires returns silence; later pulls
  /// must be sized for the new format.
  void Function(int sampleRate, int channels)? onFormatChange;

  SendspinBuffer({required this.serverToLocalUs, required this.maxBufferMs});

  /// Sample rate of the audio currently being output, once known.
  int? get sampleRate => _sampleRate;

  /// Channel count of the audio currently being output, once known.
  int? get channels => _channels;

  /// Output delay in milliseconds, subtracted from every translated
  /// timestamp: audio is handed out that much earlier.
  set outputDelayMs(int value) => _outputDelayUs = value * 1000;

  /// Buffered audio not yet played, in milliseconds.
  int get bufferDepthMs => _bufferedUs ~/ 1000;

  /// The last measured error in microseconds: positive when the audio was
  /// running late against its schedule, negative when early.
  int get syncErrorUs => _lastSyncErrorUs;

  /// Frames removed by steady-state correction.
  int get framesDropped => _framesDropped;

  /// Frames duplicated by steady-state correction.
  int get framesInserted => _framesInserted;

  /// One-shot resynchronizations, including the initial alignment.
  int get resyncCount => _resyncCount;

  /// Chunks discarded because they arrived after their time had passed.
  int get lateChunksDropped => _lateChunksDropped;

  /// Sets the format pulls are sized for before any audio has arrived.
  void setOutputFormat({required int sampleRate, required int channels}) {
    _sampleRate = sampleRate;
    _channels = channels;
  }

  /// Local time at which [chunk]'s next unconsumed frame is due.
  int _dueUs(_AudioChunk chunk) =>
      serverToLocalUs(chunk.headUs) - _outputDelayUs;

  /// Adds decoded PCM whose first frame is due at server time [timestampUs].
  ///
  /// Chunks may arrive out of order. A second chunk with a timestamp already
  /// held is ignored, and so is one whose whole duration has already been
  /// passed by the output.
  void addChunk(
    int timestampUs,
    Int16List samples, {
    required int sampleRate,
    required int channels,
  }) {
    if (samples.length < channels) return;
    final chunk = _AudioChunk(
        timestampUs, Int16List.fromList(samples), sampleRate, channels);

    final outputEnd = _outputEndUs;
    if (outputEnd != null &&
        serverToLocalUs(timestampUs + chunk.durationUs) - _outputDelayUs <=
            outputEnd) {
      _lateChunksDropped++;
      return;
    }
    if (!_chunks.add(chunk)) return;
    _bufferedUs += chunk.durationUs;

    while (_bufferedUs > maxBufferMs * 1000 && _chunks.length > 1) {
      _remove(_chunks.first);
    }
  }

  void _remove(_AudioChunk chunk) {
    _chunks.remove(chunk);
    _bufferedUs -= (chunk.remaining * 1000000 / chunk.sampleRate).round();
    if (_chunks.isEmpty) _bufferedUs = 0;
  }

  /// Consumes [frames] frames from the front of [chunk].
  void _consume(_AudioChunk chunk, int frames) {
    chunk.offset += frames;
    _bufferedUs -= (frames * 1000000 / chunk.sampleRate).round();
    if (chunk.remaining <= 0) {
      _chunks.remove(chunk);
      if (_chunks.isEmpty) _bufferedUs = 0;
    }
  }

  /// Returns [count] interleaved samples whose first sample will be output
  /// at local time [outputTimeUs] (now plus whatever delay lies between this
  /// call and the audio port). Anything not covered by due audio is silence.
  Int16List pullSamples(int count, int outputTimeUs) {
    final out = Int16List(count);
    final head = _chunks.isEmpty ? null : _chunks.first;

    // Reaching audio in another format: report it and let the caller resize.
    if (head != null &&
        (head.sampleRate != _sampleRate || head.channels != _channels)) {
      final first = _sampleRate == null;
      _sampleRate = head.sampleRate;
      _channels = head.channels;
      _synced = false;
      if (!first) {
        onFormatChange?.call(head.sampleRate, head.channels);
        return out;
      }
    }

    final rate = _sampleRate;
    final channels = _channels;
    if (rate == null || channels == null) return out;
    if (count % channels != 0) {
      throw ArgumentError.value(
          count, 'count', 'must be a whole number of $channels-channel frames');
    }
    final frames = count ~/ channels;
    int usOf(int n) => (n * 1000000 / rate).round();
    int framesOf(int us) => (us * rate / 1000000).round();

    var written = 0;
    var aligned = _synced;
    var firstChunk = true;
    var resyncing = false;

    while (written < frames && _chunks.isNotEmpty) {
      final chunk = _chunks.first;
      // Audio in another format ends this pull; the next one switches.
      if (chunk.sampleRate != rate || chunk.channels != channels) break;

      // Positive: this audio should already have played. Negative: not yet.
      final errorUs = outputTimeUs + usOf(written) - _dueUs(chunk);
      if (firstChunk) _lastSyncErrorUs = errorUs;

      if (!aligned || errorUs.abs() > resyncThresholdUs) {
        // One-shot resynchronization: skip what is late, wait out what is
        // early. This is the startup, underrun and discontinuity path.
        if (errorUs > 0) {
          final late = framesOf(errorUs);
          if (late >= chunk.remaining) {
            _remove(chunk);
            resyncing = true;
            continue;
          }
          _consume(chunk, late);
        } else {
          final early = framesOf(-errorUs);
          if (early >= frames - written) {
            // Not due within this pull. Stay unaligned so the next pull
            // lines it up exactly.
            _synced = false;
            _outputEndUs = outputTimeUs + usOf(frames);
            return out;
          }
          written += early;
        }
        resyncing = true;
        aligned = true;
      } else if (firstChunk && errorUs.abs() > deadbandUs) {
        written += _softCorrect(
            chunk, errorUs, outputTimeUs, rate, channels, out, frames);
      }
      firstChunk = false;
      if (resyncing) {
        // Counted once, when audio is actually lined up again.
        _resyncCount++;
        resyncing = false;
      }

      final n = chunk.remaining < frames - written
          ? chunk.remaining
          : frames - written;
      out.setRange(written * channels, (written + n) * channels, chunk.samples,
          chunk.offset * channels);
      written += n;
      _consume(chunk, n);
    }

    // Running dry breaks continuity: whatever comes next is lined up afresh.
    _synced = aligned && written >= frames;
    _outputEndUs = outputTimeUs + usOf(frames);
    return out;
  }

  /// Corrects part of a small error at the start of a pull by dropping
  /// frames (running late) or repeating the next frame (running early),
  /// within the speed limit. Returns how many output frames it wrote.
  int _softCorrect(_AudioChunk chunk, int errorUs, int outputTimeUs, int rate,
      int channels, Int16List out, int frames) {
    while (_recentCorrections.isNotEmpty &&
        _recentCorrections.first.$1 <= outputTimeUs - speedWindowUs) {
      _recentCorrections.removeFirst();
    }
    final spent = _recentCorrections.fold<int>(0, (sum, c) => sum + c.$2);
    final allowance =
        (maxSpeedDeviation * speedWindowUs * rate / 1000000).floor() - spent;
    final step = (_correctionStepUs * rate / 1000000).round();
    final needed = (errorUs.abs() * rate / 1000000).round();

    var n = step < 1 ? 1 : step;
    if (n > needed) n = needed;
    if (n > allowance) n = allowance;
    if (n <= 0) return 0;

    if (errorUs > 0) {
      // Late: let the neighbouring frames abut. Keep at least one frame.
      if (n >= chunk.remaining) n = chunk.remaining - 1;
      if (n <= 0) return 0;
      chunk.offset += n;
      _bufferedUs -= (n * 1000000 / rate).round();
      _framesDropped += n;
      _recentCorrections.add((outputTimeUs, n));
      return 0;
    }
    // Early: repeat the next frame n times, then carry on from it.
    if (n >= frames) n = frames - 1;
    if (n <= 0) return 0;
    final source = chunk.offset * channels;
    for (var i = 0; i < n; i++) {
      out.setRange(i * channels, (i + 1) * channels, chunk.samples, source);
    }
    _framesInserted += n;
    _recentCorrections.add((outputTimeUs, n));
    return n;
  }

  /// Discards all buffered audio, e.g. on `stream/clear` or `stream/end`.
  /// The next audio is aligned to the timeline from scratch.
  void flush() {
    _chunks.clear();
    _bufferedUs = 0;
    _synced = false;
    _lastSyncErrorUs = 0;
    _recentCorrections.clear();
  }
}
