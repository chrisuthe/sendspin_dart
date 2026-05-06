import 'dart:async';

/// Burst-strategy driver for NTP-style clock sync.
///
/// The Sendspin time-filter README's "Recommended Usage" section calls for
/// a burst of N NTP exchanges sent **sequentially** (each waiting for its
/// reply) every ~10 seconds, with only the lowest-`max_error` sample of the
/// burst fed to the Kalman filter. Sendspin runs over an ordered TCP /
/// WebSocket transport, so consecutive RTTs are correlated; sending all
/// messages in parallel and feeding every reply to the filter violates the
/// filter's independence assumption and degrades convergence.
///
/// This driver is transport-agnostic: it asks for messages to be sent via
/// [onSendTimeMessage] and receives replies via [onTimeResponse]. When a
/// burst completes, it invokes [onApplyBestSample] with the best sample's
/// `(offset, max_error, time_added)`.
///
/// State machine, mirroring `Jasionf/M5STACK-HomeAssistant`'s
/// `sendspin_time_burst.cpp` reference:
///
/// 1. `start()` kicks off a burst immediately.
/// 2. Each slot: fire one `client/time`, arm a [responseTimeout]. If the
///    matching `server/time` arrives via [onTimeResponse], cancel the
///    timeout, record the best sample, and either fire the next slot or
///    finish the burst. If the timeout fires first, treat the slot as
///    failed and move on.
/// 3. When `burstIndex == burstSize`, apply the burst's best sample to
///    the filter (if any survived), then schedule the next burst after
///    [burstInterval].
class SendspinTimeBurst {
  /// Number of NTP exchanges per burst. Default 8 matches the upstream
  /// README recommendation.
  final int burstSize;

  /// Time between burst starts. Default 10s matches the ESPHome reference
  /// integration. Convergence is dominated by per-burst best-sample
  /// quality, not raw rate, so longer intervals are fine.
  final Duration burstInterval;

  /// How long to wait for each individual `server/time` reply before
  /// giving up on the slot and moving on. Default 10s matches the ESPHome
  /// reference.
  final Duration responseTimeout;

  /// Wall-clock source. Tests can inject a deterministic clock.
  final int Function() _now;

  /// Called when the driver wants to send a `client/time` message. The
  /// argument is the `client_transmitted` timestamp to embed in the
  /// payload.
  void Function(int clientTransmittedUs)? onSendTimeMessage;

  /// Called once per burst with the lowest-`max_error` sample. Wire this
  /// into [SendspinClock.update].
  void Function(int offset, int maxError, int timeAdded)? onApplyBestSample;

  // -------- internal state --------

  bool _started = false;
  int _burstIndex = 0;

  /// `-1` means "no sample collected yet this burst".
  int _bestMaxError = -1;
  int _bestOffset = 0;
  int _bestTimeAdded = 0;

  bool _pending = false;
  Timer? _interBurstTimer;
  Timer? _responseTimeoutTimer;

  int _burstsCompleted = 0;

  SendspinTimeBurst({
    this.burstSize = 8,
    this.burstInterval = const Duration(seconds: 10),
    this.responseTimeout = const Duration(seconds: 10),
    int Function()? now,
  })  : assert(burstSize > 0, 'burstSize must be positive'),
        _now = now ?? _defaultNow;

  static int _defaultNow() => DateTime.now().microsecondsSinceEpoch;

  /// Number of bursts that have produced an applied filter update. Useful
  /// for telemetry and tests.
  int get burstsCompleted => _burstsCompleted;

  /// Whether the driver is currently active.
  bool get isStarted => _started;

  /// Begin sending bursts. Idempotent.
  void start() {
    if (_started) return;
    _started = true;
    _beginBurst();
  }

  /// Stop sending bursts and cancel any pending timers. Idempotent.
  void stop() {
    _started = false;
    _interBurstTimer?.cancel();
    _interBurstTimer = null;
    _responseTimeoutTimer?.cancel();
    _responseTimeoutTimer = null;
    _pending = false;
    _burstIndex = 0;
    _bestMaxError = -1;
  }

  /// Stops the driver and clears all telemetry counters. Use this when the
  /// underlying connection is being replaced (vs `stop()` which is a pause).
  /// Mirrors ESPHome's `SendspinTimeBurst::reset()`.
  void reset() {
    stop();
    _burstsCompleted = 0;
  }

  /// Hand a parsed `server/time` reply to the driver. `offset` and
  /// `maxError` are the NTP-derived measurement and uncertainty;
  /// `timeAdded` is the client timestamp to record alongside them
  /// (typically the moment the reply arrived).
  ///
  /// Stray responses (arrived after the slot timed out, or while the
  /// driver is stopped) are silently ignored.
  void onTimeResponse(int offset, int maxError, int timeAdded) {
    if (!_started || !_pending) return;
    _responseTimeoutTimer?.cancel();
    _responseTimeoutTimer = null;
    _pending = false;

    if (_bestMaxError < 0 || maxError < _bestMaxError) {
      _bestMaxError = maxError;
      _bestOffset = offset;
      _bestTimeAdded = timeAdded;
    }

    _advanceBurst();
  }

  // -------- internal transitions --------

  void _beginBurst() {
    _interBurstTimer = null;
    if (!_started) return;
    _burstIndex = 0;
    _bestMaxError = -1;
    _sendNextSlot();
  }

  void _sendNextSlot() {
    if (!_started) return;
    final clientTransmittedUs = _now();
    onSendTimeMessage?.call(clientTransmittedUs);
    _pending = true;
    _responseTimeoutTimer = Timer(responseTimeout, _onResponseTimeout);
  }

  void _onResponseTimeout() {
    if (!_started) return;
    _responseTimeoutTimer = null;
    _pending = false;
    _advanceBurst();
  }

  void _advanceBurst() {
    _burstIndex++;
    if (_burstIndex >= burstSize) {
      _completeBurst();
    } else {
      _sendNextSlot();
    }
  }

  void _completeBurst() {
    if (_bestMaxError >= 0) {
      onApplyBestSample?.call(_bestOffset, _bestMaxError, _bestTimeAdded);
      _burstsCompleted++;
    }
    if (!_started) return;
    _interBurstTimer = Timer(burstInterval, _beginBurst);
  }
}
