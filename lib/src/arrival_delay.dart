// ABOUTME: Sizes the player's min_buffer_ms from audio-chunk arrival delay.
// ABOUTME: Debounced upper-tail tracker fed by the send_ahead measurement.

/// Derives a `min_buffer_ms` value from the arrival delay of audio chunks.
///
/// Per the Sendspin player role, a chunk's delay is
/// `arrival - compute_client_time(timestamp - send_ahead)` and players size
/// `min_buffer_ms` from the upper tail of that distribution, measured over a
/// window long enough to include intermittent interference, and debounced so
/// the reported value only moves on a sustained shift.
///
/// Samples are grouped into windows of [windowUs], each summarised by its
/// 95th-percentile delay so a lone late chunk does not define the tail. The
/// last [historyWindows] summaries are kept, and [minBufferMs] is the second
/// largest of them rounded up to a multiple of [stepMs]: a delay level has to
/// show up in two windows before it is reported, and stops being reported
/// once fewer than two windows in the history still show it.
class ArrivalDelayTracker {
  final int windowUs;
  final int historyWindows;
  final int stepMs;

  final List<int> _history = [];
  final List<int> _window = [];
  int? _windowStartUs;
  int? _reportedMs;

  ArrivalDelayTracker({
    this.windowUs = 10 * 1000 * 1000,
    this.historyWindows = 6,
    this.stepMs = 10,
  })  : assert(windowUs > 0, 'windowUs must be positive'),
        assert(historyWindows > 0, 'historyWindows must be positive'),
        assert(stepMs > 0, 'stepMs must be positive');

  /// The debounced value to report as `min_buffer_ms`, or null until one full
  /// window of samples has been observed.
  int? get minBufferMs => _reportedMs;

  /// Records one chunk's arrival delay, taken at local time [nowUs].
  void addSample({required int delayUs, required int nowUs}) {
    final start = _windowStartUs;
    if (start == null) {
      _windowStartUs = nowUs;
    } else if (nowUs - start >= windowUs * historyWindows) {
      // No samples for longer than the history covers (the stream stopped):
      // what was measured before the gap no longer describes the network.
      _history.clear();
      _window.clear();
      _windowStartUs = nowUs;
    } else if (nowUs - start >= windowUs) {
      _closeWindow();
      _windowStartUs = nowUs;
    }
    _window.add(delayUs < 0 ? 0 : delayUs);
  }

  void _closeWindow() {
    _window.sort();
    // Nearest-rank 95th percentile.
    final rank = (_window.length * 95 + 99) ~/ 100;
    _history.add(_window[rank - 1]);
    _window.clear();
    if (_history.length > historyWindows) _history.removeAt(0);

    final sorted = List<int>.of(_history)..sort();
    final tailUs =
        sorted.length == 1 ? sorted.single : sorted[sorted.length - 2];
    final stepUs = stepMs * 1000;
    _reportedMs = (tailUs + stepUs - 1) ~/ stepUs * stepMs;
  }

  /// Forgets all samples, e.g. when the connection is replaced.
  void reset() {
    _history.clear();
    _window.clear();
    _windowStartUs = null;
    _reportedMs = null;
  }
}
