import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

void main() {
  group('ArrivalDelayTracker', () {
    const windowUs = 10 * 1000 * 1000;

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
      t.addSample(delayUs: 2000, nowUs: windowUs);
      expect(t.minBufferMs, 20);
    });

    test('clamps negative delays to zero', () {
      final t = ArrivalDelayTracker();
      t.addSample(delayUs: -5000, nowUs: 0);
      t.addSample(delayUs: -5000, nowUs: windowUs);
      expect(t.minBufferMs, 0);
    });

    test('does not react to a spike straight away', () {
      final t = ArrivalDelayTracker();
      t.addSample(delayUs: 5000, nowUs: 0);
      t.addSample(delayUs: 5000, nowUs: windowUs);
      expect(t.minBufferMs, 10);

      // One window with a 90 ms outlier, then back to normal.
      t.addSample(delayUs: 90000, nowUs: windowUs + 1);
      t.addSample(delayUs: 5000, nowUs: 2 * windowUs);
      expect(t.minBufferMs, 10,
          reason: 'a new value must repeat before it is reported');
    });

    test('raises the report once the shift persists for two windows', () {
      final t = ArrivalDelayTracker();
      t.addSample(delayUs: 5000, nowUs: 0);
      t.addSample(delayUs: 5000, nowUs: windowUs);
      t.addSample(delayUs: 90000, nowUs: windowUs + 1);
      t.addSample(delayUs: 90000, nowUs: 2 * windowUs);
      expect(t.minBufferMs, 10);
      t.addSample(delayUs: 90000, nowUs: 3 * windowUs);
      expect(t.minBufferMs, 90);
    });

    test('lowers the report only after the tail leaves the history', () {
      final t = ArrivalDelayTracker(historyWindows: 3);
      t.addSample(delayUs: 50000, nowUs: 0);
      var now = windowUs;
      t.addSample(delayUs: 5000, nowUs: now);
      expect(t.minBufferMs, 50);
      // The 50 ms window stays in the 3-window history for two more closes.
      for (var i = 0; i < 2; i++) {
        now += windowUs;
        t.addSample(delayUs: 5000, nowUs: now);
        expect(t.minBufferMs, 50);
      }
      // It has now aged out; the lower value must persist for two windows.
      now += windowUs;
      t.addSample(delayUs: 5000, nowUs: now);
      expect(t.minBufferMs, 50);
      now += windowUs;
      t.addSample(delayUs: 5000, nowUs: now);
      expect(t.minBufferMs, 10);
    });

    test('reset forgets all samples', () {
      final t = ArrivalDelayTracker();
      t.addSample(delayUs: 5000, nowUs: 0);
      t.addSample(delayUs: 5000, nowUs: windowUs);
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
        clientId: 'c',
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
