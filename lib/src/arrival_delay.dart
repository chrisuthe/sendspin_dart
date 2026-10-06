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
/// Samples are grouped into windows of [windowUs]. The estimate is the largest
/// delay seen across the last [historyWindows] windows, rounded up to a
/// multiple of [stepMs]. [minBufferMs] follows the estimate only once the
/// same new value has come out of two consecutive windows.
class ArrivalDelayTracker {
  final int windowUs;
  final int historyWindows;
  final int stepMs;

  final List<int> _history = [];
  int? _windowStartUs;
  int _windowMaxUs = 0;
  int? _reportedMs;
  int? _candidateMs;

  ArrivalDelayTracker({
    this.windowUs = 10 * 1000 * 1000,
    this.historyWindows = 6,
    this.stepMs = 10,
  });

  /// The debounced value to report as `min_buffer_ms`, or null until one full
  /// window of samples has been observed.
  int? get minBufferMs => _reportedMs;

  /// Records one chunk's arrival delay, taken at local time [nowUs].
  void addSample({required int delayUs, required int nowUs}) {
    final start = _windowStartUs;
    if (start == null) {
      _windowStartUs = nowUs;
    } else if (nowUs - start >= windowUs) {
      _closeWindow();
      _windowStartUs = nowUs;
      _windowMaxUs = 0;
    }
    if (delayUs > _windowMaxUs) _windowMaxUs = delayUs;
  }

  void _closeWindow() {
    _history.add(_windowMaxUs);
    if (_history.length > historyWindows) _history.removeAt(0);

    final tailUs = _history.reduce((a, b) => a > b ? a : b);
    final stepUs = stepMs * 1000;
    final estimateMs = (tailUs + stepUs - 1) ~/ stepUs * stepMs;

    if (_reportedMs == null) {
      _reportedMs = estimateMs;
    } else if (estimateMs == _reportedMs) {
      _candidateMs = null;
    } else if (estimateMs == _candidateMs) {
      _reportedMs = estimateMs;
      _candidateMs = null;
    } else {
      _candidateMs = estimateMs;
    }
  }

  /// Forgets all samples, e.g. when the connection is replaced.
  void reset() {
    _history.clear();
    _windowStartUs = null;
    _windowMaxUs = 0;
    _reportedMs = null;
    _candidateMs = null;
  }
}
