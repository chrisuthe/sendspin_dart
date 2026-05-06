import 'dart:async';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

/// Yields to the Dart event loop until [condition] becomes true or the
/// timeout elapses. Used to wait for `Timer(Duration.zero, ...)` callbacks
/// without depending on an empirical fixed number of awaits.
Future<void> _pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('pumpUntil: condition not met within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

void main() {
  group('SendspinTimeBurst', () {
    test('start sends the first slot synchronously', () {
      final sent = <int>[];
      var nowUs = 1000000;
      final burst = SendspinTimeBurst(
        burstSize: 4,
        burstInterval: const Duration(seconds: 1),
        responseTimeout: const Duration(seconds: 1),
        now: () => nowUs,
      )..onSendTimeMessage = sent.add;

      burst.start();
      expect(sent, equals([1000000]));
      burst.stop();
    });

    test('start is idempotent', () {
      final sent = <int>[];
      final burst = SendspinTimeBurst(
        burstSize: 4,
        responseTimeout: const Duration(seconds: 10),
        now: () => 1,
      )..onSendTimeMessage = sent.add;

      burst.start();
      burst.start();
      burst.start();
      // Only the first start should fire a slot — subsequent calls are noops.
      expect(sent.length, 1);
      burst.stop();
    });

    test('responses chain into the next slot until the burst completes', () {
      final sent = <int>[];
      var nowUs = 0;
      final burst = SendspinTimeBurst(
        burstSize: 4,
        responseTimeout: const Duration(seconds: 10),
        burstInterval: const Duration(seconds: 10),
        now: () => ++nowUs,
      )..onSendTimeMessage = sent.add;

      burst.start();
      // Slot 1 fired. Reply with a sample.
      burst.onTimeResponse(100, 50, 1);
      // Slot 2 fired. Reply.
      burst.onTimeResponse(101, 80, 2);
      burst.onTimeResponse(102, 30, 3);
      burst.onTimeResponse(103, 60, 4);
      // 4 sends, 4 replies — burst should be complete and waiting for
      // the inter-burst timer.
      expect(sent.length, 4);
      expect(burst.burstsCompleted, 1);
      burst.stop();
    });

    test('feeds only the lowest-max_error sample to onApplyBestSample', () {
      late int appliedOffset;
      late int appliedMaxError;
      late int appliedTimeAdded;
      var applyCount = 0;

      final burst = SendspinTimeBurst(
        burstSize: 4,
        responseTimeout: const Duration(seconds: 10),
        burstInterval: const Duration(seconds: 10),
        now: () => 1,
      )
        ..onSendTimeMessage = (_) {}
        ..onApplyBestSample = (offset, maxError, timeAdded) {
          appliedOffset = offset;
          appliedMaxError = maxError;
          appliedTimeAdded = timeAdded;
          applyCount++;
        };

      burst.start();
      burst.onTimeResponse(100, 80, 1000);
      burst.onTimeResponse(101, 30, 1001); // best
      burst.onTimeResponse(102, 90, 1002);
      burst.onTimeResponse(103, 70, 1003);

      expect(applyCount, 1);
      expect(appliedOffset, 101);
      expect(appliedMaxError, 30);
      expect(appliedTimeAdded, 1001);
      burst.stop();
    });

    test('stray responses (no pending slot) are ignored', () {
      var applyCount = 0;
      final burst = SendspinTimeBurst(
        burstSize: 2,
        responseTimeout: const Duration(seconds: 10),
        burstInterval: const Duration(seconds: 10),
        now: () => 1,
      )
        ..onSendTimeMessage = (_) {}
        ..onApplyBestSample = (_, __, ___) => applyCount++;

      // Driver not started — should ignore.
      burst.onTimeResponse(0, 0, 0);
      expect(applyCount, 0);

      burst.start();
      burst.onTimeResponse(100, 50, 1); // slot 1 ok
      burst.onTimeResponse(200, 40, 2); // slot 2 ok → burst complete
      // Now no slot is pending. Stray reply must not advance anything.
      burst.onTimeResponse(999, 1, 3);
      expect(burst.burstsCompleted, 1);
      burst.stop();
    });

    test('response timeout advances the burst slot', () async {
      // Use Duration.zero for the timeout so the slot timer fires on the
      // next event-loop tick. _pumpUntil yields until the burst has sent
      // every slot's message — no reliance on a hand-counted number of
      // awaits.
      final sent = <int>[];
      var nowUs = 0;
      final burst = SendspinTimeBurst(
        burstSize: 3,
        responseTimeout: Duration.zero,
        burstInterval: const Duration(seconds: 10),
        now: () => ++nowUs,
      )..onSendTimeMessage = sent.add;

      burst.start();
      await _pumpUntil(() => sent.length >= 3);

      expect(sent.length, 3);
      burst.stop();
    });

    test(
        'completes a burst with no replies (all timeouts) and applies '
        'nothing', () async {
      var applyCount = 0;
      final sent = <int>[];
      final burst = SendspinTimeBurst(
        burstSize: 2,
        responseTimeout: Duration.zero,
        burstInterval: const Duration(seconds: 10),
        now: () => 1,
      )
        ..onSendTimeMessage = sent.add
        ..onApplyBestSample = (_, __, ___) => applyCount++;

      burst.start();
      await _pumpUntil(() => sent.length >= 2);

      expect(sent.length, 2);
      expect(applyCount, 0); // no samples → nothing to apply
      expect(burst.burstsCompleted, 0);
      burst.stop();
    });

    test('inter-burst interval delays the next burst', () async {
      final sent = <int>[];
      final burst = SendspinTimeBurst(
        burstSize: 1,
        responseTimeout: const Duration(seconds: 10),
        burstInterval: const Duration(milliseconds: 50),
        now: () => 1,
      )..onSendTimeMessage = sent.add;

      burst.start();
      burst.onTimeResponse(0, 1, 1); // completes burst 1 immediately

      expect(sent.length, 1);
      expect(burst.burstsCompleted, 1);

      // Before the inter-burst interval elapses, no new send.
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(sent.length, 1);

      // After the interval, burst 2 should have started.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(sent.length, 2);

      burst.stop();
    });

    test('stop cancels in-flight timeout and inter-burst timer', () async {
      final sent = <int>[];
      final burst = SendspinTimeBurst(
        burstSize: 4,
        responseTimeout: const Duration(milliseconds: 30),
        burstInterval: const Duration(milliseconds: 30),
        now: () => 1,
      )..onSendTimeMessage = sent.add;

      burst.start();
      expect(sent.length, 1); // first slot
      burst.stop();

      // Wait long enough that any unstopped timeout would have fired and
      // sent another message.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(sent.length, 1);
      expect(burst.isStarted, isFalse);
    });

    test('reset zeroes burstsCompleted (vs stop, which preserves it)', () {
      final burst = SendspinTimeBurst(
        burstSize: 1,
        responseTimeout: const Duration(seconds: 10),
        burstInterval: const Duration(seconds: 10),
        now: () => 1,
      )..onSendTimeMessage = (_) {};

      burst.start();
      burst.onTimeResponse(0, 1, 1); // completes burst 1
      expect(burst.burstsCompleted, 1);

      burst.stop();
      expect(burst.burstsCompleted, 1, reason: 'stop preserves telemetry');

      burst.reset();
      expect(burst.burstsCompleted, 0,
          reason: 'reset is the new-connection hook');
    });

    test('stop -> start resumes from a fresh burst', () {
      final sent = <int>[];
      var nowUs = 0;
      final burst = SendspinTimeBurst(
        burstSize: 2,
        responseTimeout: const Duration(seconds: 10),
        burstInterval: const Duration(seconds: 10),
        now: () => ++nowUs,
      )..onSendTimeMessage = sent.add;

      burst.start();
      burst.onTimeResponse(0, 100, 1);
      // Mid-burst stop.
      burst.stop();
      expect(sent.length, 2);

      sent.clear();
      burst.start();
      // Should send a fresh first slot.
      expect(sent.length, 1);
      burst.stop();
    });
  });
}
