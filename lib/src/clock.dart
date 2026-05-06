import 'dart:math';

/// Two-dimensional Kalman filter for NTP-style time synchronization.
///
/// Tracks [offset, drift] between client and server clocks with a 2x2
/// covariance matrix. Faithfully ported from the C++ Sendspin time-filter
/// reference implementation, which the Sendspin protocol spec designates
/// as the source of truth for clients:
/// https://github.com/Sendspin/time-filter
///
/// All times are in microseconds (int). The diffusion-coefficient units
/// follow upstream's theory.md: [processStdDev] in µs / sqrt(µs) and
/// [driftProcessStdDev] in 1 / sqrt(µs) (drift itself is dimensionless,
/// µs of offset per µs of elapsed time).
class SendspinClock {
  /// Constructs a 2D Kalman time-sync filter.
  ///
  /// Defaults mirror the current upstream `Config` struct (April 2026):
  ///
  /// - [processStdDev] (default 0.0): Offset random-walk diffusion. Variance
  ///   grows by `processStdDev² * dt` per microsecond elapsed.
  /// - [driftProcessStdDev] (default 1e-11): Drift random-walk diffusion. Drift
  ///   variance grows by `driftProcessStdDev² * dt` per microsecond elapsed.
  /// - [forgetFactor] (default 2.0): Standard-deviation scale (>1) applied
  ///   when residuals exceed [adaptiveCutoff] times max_error. Squared into
  ///   a variance multiplier inside the filter.
  /// - [adaptiveCutoff] (default 3.0): Multiple of (unscaled) max_error that
  ///   triggers adaptive forgetting.
  /// - [minSamples] (default 100): Samples to accumulate before adaptive
  ///   forgetting is enabled.
  /// - [driftSignificanceThreshold] (default 2.0): SNR multiplier (~95%) that
  ///   gates whether drift is applied during time conversion.
  /// - [maxErrorScale] (default 0.5): Scales max_error before it is used as
  ///   the measurement standard deviation. Round-trip half-delay is a worst-
  ///   case bound, not a 1σ estimate, so values < 1 prevent measurement-
  ///   variance inflation. The (unscaled) max_error is still used as the
  ///   adaptive-forgetting cutoff reference.
  SendspinClock({
    double processStdDev = 0.0,
    double driftProcessStdDev = 1e-11,
    double forgetFactor = 2.0,
    double adaptiveCutoff = 3.0,
    int minSamples = 100,
    double driftSignificanceThreshold = 2.0,
    double maxErrorScale = 0.5,
  })  : _processVariance = processStdDev * processStdDev,
        _driftProcessVariance = driftProcessStdDev * driftProcessStdDev,
        _forgetVarianceFactor = forgetFactor * forgetFactor,
        _adaptiveForgettingCutoff = adaptiveCutoff,
        _minSamplesForForgetting = minSamples,
        _driftSignificanceThresholdSquared =
            driftSignificanceThreshold * driftSignificanceThreshold,
        _maxErrorScale = maxErrorScale {
    reset();
  }

  // Persisted state
  int _lastUpdate = 0;
  double _offset = 0.0;
  double _drift = 0.0;
  double _offsetCovariance = double.infinity;
  double _offsetDriftCovariance = 0.0;
  double _driftCovariance = 0.0;
  bool _useDrift = false;
  int _count = 0;

  /// Estimated clock offset in microseconds (server - client).
  /// This is a large absolute value (different clock epochs) — not useful
  /// for display. Use [precisionUs] for sync quality.
  double get offsetUs => _offset;

  /// Estimated sync precision (1-sigma) in microseconds.
  /// Lower is better. Square root of the Kalman filter's offset covariance.
  double get precisionUs => _offsetCovariance.isFinite
      ? sqrt(_offsetCovariance.abs())
      : double.infinity;

  /// Number of time sync samples processed.
  int get sampleCount => _count;

  /// Whether the filter has accumulated enough samples for adaptive
  /// forgetting. This is a count-based heuristic only — it does NOT mean
  /// the offset variance has actually shrunk to a usable level. Inspect
  /// [precisionUs] for that.
  bool get isConverged => _count >= _minSamplesForForgetting;

  // Immutable parameters
  final double _processVariance;
  final double _driftProcessVariance;
  final double _forgetVarianceFactor;
  final double _adaptiveForgettingCutoff;
  final int _minSamplesForForgetting;
  final double _driftSignificanceThresholdSquared;
  final double _maxErrorScale;

  /// Processes a new time synchronization measurement.
  ///
  /// [measurement] is the computed offset from NTP-style exchange in us.
  /// [maxError] is half the round-trip delay in us.
  /// [timeAdded] is the client timestamp when this measurement was taken in us.
  void update(int measurement, int maxError, int timeAdded) {
    if (timeAdded <= _lastUpdate) {
      // Skip non-monotonic timestamps
      return;
    }

    final double dt = (timeAdded - _lastUpdate).toDouble();
    final double dtSquared = dt * dt;
    _lastUpdate = timeAdded;

    // max_error is the round-trip half-delay — a worst-case bound, not a
    // 1-sigma estimate. Scale it before squaring to avoid inflating R.
    final double updateStdDev = maxError.toDouble() * _maxErrorScale;
    final double measurementVariance = updateStdDev * updateStdDev;

    // Phase 1: First measurement establishes offset baseline
    if (_count <= 0) {
      _count++;
      _offset = measurement.toDouble();
      _offsetCovariance = measurementVariance;
      _drift = 0.0;
      return;
    }

    // Phase 2: Second measurement — initial drift from finite differences
    if (_count == 1) {
      _count++;
      _drift = (measurement.toDouble() - _offset) / dt;
      _offset = measurement.toDouble();
      _driftCovariance = (_offsetCovariance + measurementVariance) / dtSquared;
      _offsetCovariance = measurementVariance;
      return;
    }

    // Phase 3: Full Kalman predict -> innovate -> adapt -> update

    /*** Prediction Step ***/
    final double predictedOffset = _offset + _drift * dt;

    final double driftProcessVariance = dt * _driftProcessVariance;
    double newDriftCovariance = _driftCovariance + driftProcessVariance;

    double newOffsetDriftCovariance =
        _offsetDriftCovariance + _driftCovariance * dt;

    final double offsetProcessVariance = dt * _processVariance;
    double newOffsetCovariance = _offsetCovariance +
        2 * _offsetDriftCovariance * dt +
        _driftCovariance * dtSquared +
        offsetProcessVariance;

    /*** Innovation and Adaptive Forgetting ***/
    final double residual = measurement.toDouble() - predictedOffset;
    // The cutoff intentionally uses UNSCALED max_error (matching upstream
    // impl.cpp:99): adaptiveCutoff is in units of the worst-case bound, not
    // of measurement standard deviations.
    final double maxResidualCutoff =
        maxError.toDouble() * _adaptiveForgettingCutoff;

    if (_count < _minSamplesForForgetting) {
      _count++;
    } else if (residual.abs() > maxResidualCutoff) {
      newDriftCovariance *= _forgetVarianceFactor;
      newOffsetDriftCovariance *= _forgetVarianceFactor;
      newOffsetCovariance *= _forgetVarianceFactor;
    }

    /*** Update Step ***/
    final double uncertainty =
        1.0 / (newOffsetCovariance + measurementVariance);

    final double offsetGain = newOffsetCovariance * uncertainty;
    final double driftGain = newOffsetDriftCovariance * uncertainty;

    _offset = predictedOffset + offsetGain * residual;
    _drift += driftGain * residual;

    _driftCovariance =
        newDriftCovariance - driftGain * newOffsetDriftCovariance;
    _offsetDriftCovariance =
        newOffsetDriftCovariance - driftGain * newOffsetCovariance;
    _offsetCovariance = newOffsetCovariance - offsetGain * newOffsetCovariance;

    // Drift significance check (SNR)
    final double driftSquared = _drift * _drift;
    _useDrift =
        driftSquared > _driftSignificanceThresholdSquared * _driftCovariance;
  }

  /// Converts a client timestamp to the equivalent server timestamp.
  int computeServerTime(int clientTime) {
    final double dt = (clientTime - _lastUpdate).toDouble();
    final double effectiveDrift = _useDrift ? _drift : 0.0;
    final int offset = (_offset + effectiveDrift * dt).round();
    return clientTime + offset;
  }

  /// Converts a server timestamp to the equivalent client timestamp.
  int computeClientTime(int serverTime) {
    final double effectiveDrift = _useDrift ? _drift : 0.0;
    return ((serverTime.toDouble() -
                _offset +
                effectiveDrift * _lastUpdate.toDouble()) /
            (1.0 + effectiveDrift))
        .round();
  }

  /// Resets the filter to its initial uninitialized state.
  void reset() {
    _count = 0;
    _offset = 0.0;
    _drift = 0.0;
    _offsetCovariance = double.infinity;
    _offsetDriftCovariance = 0.0;
    _driftCovariance = 0.0;
    _lastUpdate = 0;
    _useDrift = false;
  }

  /// Returns the estimated standard deviation of the offset in us.
  ///
  /// Returns `-1` before the first measurement (covariance starts at infinity)
  /// to avoid throwing when callers query an uninitialised filter.
  int getError() {
    if (!_offsetCovariance.isFinite) return -1;
    return sqrt(_offsetCovariance.abs()).round();
  }
}
