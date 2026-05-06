import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

void main() {
  group('SendspinClock', () {
    test('first update sets offset directly', () {
      final clock = SendspinClock();
      clock.update(1000, 50, 100000);
      final serverTime = clock.computeServerTime(200000);
      expect((serverTime - 201000).abs(), lessThan(100));
    });

    test('computeClientTime is inverse of computeServerTime', () {
      final clock = SendspinClock();
      clock.update(5000, 100, 100000);
      final clientTime = 500000;
      final serverTime = clock.computeServerTime(clientTime);
      final backToClient = clock.computeClientTime(serverTime);
      expect((backToClient - clientTime).abs(), lessThan(2));
    });

    test('converges on stable offset with repeated measurements', () {
      final clock = SendspinClock();
      for (int i = 0; i < 10; i++) {
        clock.update(2000, 50, 100000 + i * 10000000);
      }
      final serverTime = clock.computeServerTime(1000000);
      expect((serverTime - 1002000).abs(), lessThan(50));
    });

    test('error decreases with more measurements', () {
      final clock = SendspinClock();
      clock.update(1000, 100, 100000);
      final error1 = clock.getError();
      for (int i = 1; i < 20; i++) {
        clock.update(1000, 100, 100000 + i * 10000000);
      }
      final error2 = clock.getError();
      expect(error2, lessThan(error1));
    });

    test('tracks drift when clocks diverge', () {
      final clock = SendspinClock();
      for (int i = 0; i < 50; i++) {
        final timeUs = i * 1000000;
        final offset = i; // 1us/s drift
        clock.update(offset, 50, timeUs);
      }
      final predicted = clock.computeServerTime(60000000);
      expect((predicted - 60000060).abs(), lessThan(200));
    });

    test('reset clears all state', () {
      final clock = SendspinClock();
      clock.update(5000, 100, 100000);
      clock.reset();
      clock.update(1000, 50, 200000);
      final serverTime = clock.computeServerTime(300000);
      expect((serverTime - 301000).abs(), lessThan(100));
    });

    test('adaptive forgetting recovers from disruption', () {
      final clock = SendspinClock(minSamples: 10);
      for (int i = 0; i < 20; i++) {
        clock.update(1000, 50, i * 1000000);
      }
      // Disruption: offset jumps from 1000 to 5000
      for (int i = 0; i < 20; i++) {
        clock.update(5000, 50, (20 + i) * 1000000);
      }
      // Query near last update to minimize drift extrapolation error
      final serverTime = clock.computeServerTime(39500000);
      expect((serverTime - 39505000).abs(), lessThan(700));
    });

    test('getError returns -1 before any measurement', () {
      final clock = SendspinClock();
      expect(clock.getError(), equals(-1));
    });

    test('precisionUs is infinite before any measurement', () {
      final clock = SendspinClock();
      expect(clock.precisionUs, equals(double.infinity));
    });

    test('maxErrorScale halves the post-init error vs unscaled', () {
      // After the first update, the upstream filter sets:
      //   offset_covariance = (max_error * max_error_scale)^2
      // So sqrt(cov) == max_error * max_error_scale.
      final scaled = SendspinClock(); // default 0.5
      final unscaled = SendspinClock(maxErrorScale: 1.0);
      scaled.update(0, 100, 1);
      unscaled.update(0, 100, 1);
      expect(scaled.getError(), equals(50));
      expect(unscaled.getError(), equals(100));
    });

    test(
        'default adaptiveCutoff (3.0) does NOT forget on 2x max_error '
        'residuals', () {
      // With cutoff=3.0, residuals up to 3x max_error are absorbed by
      // ordinary Kalman update. If we fed regular 2x-max_error noise into
      // a (legacy) cutoff=0.75 filter, forgetting would fire constantly
      // and the variance would balloon. With the upstream default it
      // settles below the initial bound.
      final clock = SendspinClock(minSamples: 10);
      for (int i = 0; i < 60; i++) {
        // Alternate +200 and -200 around the true offset (max_error=100,
        // so |residual| ~= 2*max_error each step — well under the 3x cutoff).
        final m = 1000 + ((i.isEven) ? 200 : -200);
        clock.update(m, 100, i * 1000000);
      }
      // After 60 samples of 2*max_error noise, the filter should still be
      // tracking the centre and not have its variance blown up by spurious
      // forgetting.
      expect(clock.getError(), lessThan(150));
      final serverTime = clock.computeServerTime(60 * 1000000);
      expect((serverTime - (60 * 1000000 + 1000)).abs(), lessThan(500));
    });

    test('stable offset converges to small precision under upstream defaults',
        () {
      // Tighter than the legacy tolerance — proves the new defaults
      // actually converge.
      final clock = SendspinClock();
      for (int i = 0; i < 20; i++) {
        clock.update(2000, 50, 100000 + i * 10000000);
      }
      final serverTime = clock.computeServerTime(1000000);
      expect((serverTime - 1002000).abs(), lessThan(10));
      expect(clock.getError(), lessThan(15));
    });
  });
}
