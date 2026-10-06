import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

import 'test_identity.dart';

void main() {
  group('ArrivalDelayTracker', () {
    const windowUs = 10 * 1000 * 1000;

    /// Adds one sample at the start of window [index]. The first sample of a
    /// window is what closes the previous one.
    void sampleIn(ArrivalDelayTracker t, int index, int delayUs) =>
        t.addSample(delayUs: delayUs, nowUs: index * windowUs);

    test('reports nothing until a full window has been observed', () {
      final t = ArrivalDelayTracker();
      t.addSample(delayUs: 12000, nowUs: 0);
      t.addSample(delayUs: 14000, nowUs: windowUs - 1);
      expect(t.minBufferMs, isNull);
    });

    test('reports the upper tail of the first window, rounded up', () {
      final t = ArrivalDelayTracker();
      t.addSample(delayUs: 3000, nowUs: 0);
      t.addSample(delayUs: 14000, nowUs: 1000);
      sampleIn(t, 1, 2000);
      expect(t.minBufferMs, 20);
    });

    test('clamps negative delays to zero', () {
      final t = ArrivalDelayTracker();
      sampleIn(t, 0, -5000);
      sampleIn(t, 1, -5000);
      expect(t.minBufferMs, 0);
    });

    test('a lone outlier chunk in a busy window is not the upper tail', () {
      final t = ArrivalDelayTracker();
      for (var i = 0; i < 99; i++) {
        t.addSample(delayUs: 5000, nowUs: i);
      }
      t.addSample(delayUs: 90000, nowUs: 99);
      sampleIn(t, 1, 5000);
      expect(t.minBufferMs, 10);
    });

    test('a spike confined to one window never moves the report', () {
      final t = ArrivalDelayTracker();
      sampleIn(t, 0, 5000);
      sampleIn(t, 1, 90000);
      expect(t.minBufferMs, 10);
      // The 90 ms window stays in the history for six closes and then ages
      // out; the report must not follow it at any point.
      for (var w = 2; w < 12; w++) {
        sampleIn(t, w, 5000);
        expect(t.minBufferMs, 10, reason: 'after closing window ${w - 1}');
      }
    });

    test('raises the report once two windows show the higher delay', () {
      final t = ArrivalDelayTracker();
      sampleIn(t, 0, 5000);
      sampleIn(t, 1, 90000);
      sampleIn(t, 2, 90000);
      expect(t.minBufferMs, 10);
      sampleIn(t, 3, 90000);
      expect(t.minBufferMs, 90);
    });

    test('lowers the report once fewer than two windows still show it', () {
      final t = ArrivalDelayTracker(historyWindows: 3);
      sampleIn(t, 0, 50000);
      sampleIn(t, 1, 50000);
      sampleIn(t, 2, 5000);
      expect(t.minBufferMs, 50);
      sampleIn(t, 3, 5000);
      expect(t.minBufferMs, 50, reason: 'history is [50, 50, 5]');
      sampleIn(t, 4, 5000);
      expect(t.minBufferMs, 10, reason: 'history is [50, 5, 5]');
    });

    test('a gap longer than the history discards the stale windows', () {
      final t = ArrivalDelayTracker();
      sampleIn(t, 0, 80000);
      sampleIn(t, 1, 80000);
      sampleIn(t, 2, 80000);
      expect(t.minBufferMs, 80);

      // The stream stops for far longer than the six-window history.
      sampleIn(t, 1000, 5000);
      sampleIn(t, 1001, 5000);
      expect(t.minBufferMs, 10);
    });

    test('reset forgets all samples', () {
      final t = ArrivalDelayTracker();
      sampleIn(t, 0, 5000);
      sampleIn(t, 1, 5000);
      t.reset();
      expect(t.minBufferMs, isNull);
    });
  });

  group('SendspinProtocol arrival-delay measurement', () {
    late int now;
    late SendspinProtocol protocol;

    Uint8List chunk(int timestampUs, int sendAheadUs) {
      final frame = Uint8List(13);
      frame[0] = 4;
      final view = ByteData.view(frame.buffer);
      view.setInt64(1, timestampUs, Endian.big);
      view.setUint32(9, sendAheadUs, Endian.big);
      return frame;
    }

    /// Seeds the filter with server = client + 1 s, so server time
    /// `t + 1_000_000` maps to client time `t`.
    void synchronize() {
      protocol.clock.update(1000000, 100, 1);
      protocol.clock.update(1000000, 100, 2);
    }

    setUp(() {
      now = 0;
      protocol = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        bufferSeconds: 5,
        now: () => now,
      );
    });

    tearDown(() => protocol.dispose());

    test('measures arrival minus the translated transmit time', () {
      synchronize();
      final delays = <int>[];
      protocol.onArrivalDelay = delays.add;

      // Sent at server 6.0 s (= client 5.0 s), arrives at client 5.007 s.
      now = 5007000;
      protocol.handleBinaryMessage(chunk(6500000, 500000));

      expect(delays, [7000]);
    });

    test('skips chunks received before the time filter is synchronized', () {
      final delays = <int>[];
      protocol.onArrivalDelay = delays.add;
      now = 5007000;
      protocol.handleBinaryMessage(chunk(6500000, 500000));
      expect(delays, isEmpty);
    });

    test('skips the saturated send_ahead values 0 and 0xFFFFFFFF', () {
      synchronize();
      final delays = <int>[];
      protocol.onArrivalDelay = delays.add;
      now = 5007000;
      protocol.handleBinaryMessage(chunk(6500000, 0));
      protocol.handleBinaryMessage(chunk(6500000, 0xFFFFFFFF));
      expect(delays, isEmpty);
    });

    test('feeds samples into measuredMinBufferMs', () {
      synchronize();
      expect(protocol.measuredMinBufferMs, isNull);
      now = 5007000;
      protocol.handleBinaryMessage(chunk(6500000, 500000));
      now = 15007000;
      protocol.handleBinaryMessage(chunk(16500000, 500000));
      expect(protocol.measuredMinBufferMs, 10);
    });
  });

  group('SendspinClock.isSynchronized', () {
    test('is false until two measurements have been applied', () {
      final clock = SendspinClock();
      expect(clock.isSynchronized, isFalse);
      clock.update(1000, 100, 1);
      expect(clock.isSynchronized, isFalse);
      clock.update(1000, 100, 2);
      expect(clock.isSynchronized, isTrue);
      clock.reset();
      expect(clock.isSynchronized, isFalse);
    });
  });
}
