import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

void main() {
  group('SendspinBuffer', () {
    test('buffers chunks and retrieves in timestamp order', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.addChunk(2000, Int16List.fromList([5, 6, 7, 8]));
      buffer.addChunk(1000, Int16List.fromList([1, 2, 3, 4]));
      buffer.addChunk(3000, Int16List.fromList([9, 10, 11, 12]));
      final samples = buffer.pullSamples(12);
      expect(samples, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
    });

    test('returns silence on underrun', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      final samples = buffer.pullSamples(4);
      expect(samples, [0, 0, 0, 0]);
    });

    test('flush clears all buffered data', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.addChunk(1000, Int16List.fromList([1, 2, 3, 4]));
      buffer.flush();
      final samples = buffer.pullSamples(4);
      expect(samples, [0, 0, 0, 0]);
    });

    test('startup buffering holds data until threshold met', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 100,
        maxBufferMs: 15000,
      );
      buffer.addChunk(1000, Int16List.fromList(List.filled(100, 1)));
      final samples = buffer.pullSamples(100);
      expect(samples, Int16List(100)); // silence — startup not met
    });

    test('reports buffer depth in milliseconds', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.addChunk(1000,
          Int16List.fromList(List.filled(96000, 1))); // 1000ms at 48kHz stereo
      expect(buffer.bufferDepthMs, 1000);
    });

    test('drops oldest chunks when max buffer exceeded', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 10,
      );
      buffer.addChunk(1000, Int16List.fromList(List.filled(960, 1))); // 10ms
      buffer.addChunk(2000, Int16List.fromList(List.filled(960, 2))); // 10ms
      buffer.addChunk(3000, Int16List.fromList(List.filled(960, 3))); // 10ms
      expect(buffer.bufferDepthMs, lessThanOrEqualTo(20));
    });

    test('flush resets startup buffering requirement', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 100,
        maxBufferMs: 15000,
      );
      buffer.addChunk(
          1000, Int16List.fromList(List.filled(96000, 1))); // exceed startup
      final samples1 = buffer.pullSamples(10);
      expect(samples1.any((s) => s != 0), true);
      buffer.flush();
      buffer.addChunk(2000, Int16List.fromList(List.filled(100, 1)));
      final samples2 = buffer.pullSamples(100);
      expect(samples2, Int16List(100)); // startup not met again
    });

    test('returns Int16List from pullSamples', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.addChunk(1000, Int16List.fromList([1, 2, 3, 4]));
      final samples = buffer.pullSamples(4);
      expect(samples, isA<Int16List>());
    });

    test('isInUnderrun false before any real audio produced', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.pullSamples(4);
      expect(buffer.isInUnderrun, isFalse);
    });

    test('isInUnderrun false after a successful real-audio pull', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.addChunk(1000, Int16List.fromList(List.filled(960, 1)));
      buffer.pullSamples(960);
      expect(buffer.isInUnderrun, isFalse);
    });

    test('isInUnderrun becomes true after exhausting the buffer', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.addChunk(1000, Int16List.fromList(List.filled(960, 1)));
      buffer.pullSamples(960);
      expect(buffer.isInUnderrun, isFalse);
      buffer.pullSamples(960);
      expect(buffer.isInUnderrun, isTrue);
    });

    test('isInUnderrun clears when fresh audio arrives after underrun', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.addChunk(1000, Int16List.fromList(List.filled(960, 1)));
      buffer.pullSamples(960);
      buffer.pullSamples(960);
      expect(buffer.isInUnderrun, isTrue);
      buffer.addChunk(2000, Int16List.fromList(List.filled(960, 2)));
      buffer.pullSamples(960);
      expect(buffer.isInUnderrun, isFalse);
    });

    test('flush resets isInUnderrun flag', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.addChunk(1000, Int16List.fromList(List.filled(960, 1)));
      buffer.pullSamples(960);
      buffer.pullSamples(960);
      expect(buffer.isInUnderrun, isTrue);
      buffer.flush();
      expect(buffer.isInUnderrun, isFalse);
    });

    test('static-delay hold does not flag isInUnderrun', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.staticDelayMs = 1000; // 96000 samples needed
      buffer.addChunk(1000, Int16List.fromList(List.filled(960, 1)));
      final result = buffer.pullSamples(960);
      expect(result, Int16List(960));
      expect(buffer.isInUnderrun, isFalse);
    });

    test('pre-startup silence does not flag isInUnderrun', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 100,
        maxBufferMs: 15000,
      );
      buffer.pullSamples(960);
      expect(buffer.isInUnderrun, isFalse);
    });

    test('partial chunk consumption advances offset correctly', () {
      final buffer = SendspinBuffer(
        sampleRate: 48000,
        channels: 2,
        startupBufferMs: 0,
        maxBufferMs: 15000,
      );
      buffer.addChunk(1000, Int16List.fromList([1, 2, 3, 4, 5, 6]));
      final first = buffer.pullSamples(2);
      expect(first, [1, 2]);
      final second = buffer.pullSamples(4);
      expect(second, [3, 4, 5, 6]);
    });
  });

  group('SendspinBuffer sync correction', () {
    const int sampleRate = 48000;
    const int channels = 2;
    const int pullSize = 960; // 10 ms of stereo audio
    const int frameDurationUs = 10000; // 10 ms in us

    SendspinBuffer makeBuffer() => SendspinBuffer(
          sampleRate: sampleRate,
          channels: channels,
          startupBufferMs: 0,
          maxBufferMs: 15000,
        );

    test('deadband: sync error < 2 ms produces no correction', () {
      final buffer = makeBuffer();
      buffer.addChunk(0, Int16List(pullSize));
      buffer.pullSamples(pullSize);
      buffer.addChunk(9000, Int16List(pullSize));
      buffer.pullSamples(pullSize);
      expect(buffer.syncErrorUs.abs(), lessThan(2000));
      expect(buffer.bufferDepthMs, 0);
    });

    test('micro-correction when behind: drops frames over time', () {
      final buffer = makeBuffer();
      const int bigChunkSamples = 48000; // 500 ms
      buffer.addChunk(0, Int16List(bigChunkSamples));
      for (var i = 0; i < 20; i++) {
        buffer.pullSamples(pullSize);
      }
      expect(buffer.bufferDepthMs, lessThan(300));
      expect(buffer.syncErrorUs, greaterThan(0));
    });

    test('micro-correction when ahead: pads frames over time', () {
      final buffer = makeBuffer();
      buffer.addChunk(0, Int16List(pullSize));
      buffer.pullSamples(pullSize);

      const int chunkCount = 50;
      const int chunkSpacing = 20000;
      var ts = frameDurationUs + 100000;
      for (var i = 0; i < chunkCount; i++) {
        buffer.addChunk(ts, Int16List(pullSize));
        ts += chunkSpacing;
      }

      final depthBefore = buffer.bufferDepthMs;

      var hadNegativeError = false;
      for (var i = 0; i < 30; i++) {
        final samples = buffer.pullSamples(pullSize);
        expect(samples.length, pullSize);
        if (buffer.syncErrorUs < 0) hadNegativeError = true;
      }

      expect(hadNegativeError, true,
          reason: 'sync error should have been negative at some point');

      final depthAfter = buffer.bufferDepthMs;
      const normalDrain = 30 * 10;
      final actualDrain = depthBefore - depthAfter;
      expect(actualDrain, lessThan(normalDrain),
          reason: 'ahead correction should slow buffer drain');
    });

    test('re-anchor: sync error > 500 ms flushes the buffer', () {
      final buffer = makeBuffer();
      buffer.addChunk(1000000, Int16List(pullSize));
      buffer.pullSamples(pullSize);
      buffer.addChunk(1, Int16List(pullSize));
      final result = buffer.pullSamples(pullSize);
      expect(result, Int16List(pullSize));
      expect(buffer.bufferDepthMs, 0);
    });

    test('re-anchor cooldown: within 5 s falls through to micro-correction',
        () {
      final buffer = makeBuffer();
      buffer.addChunk(0, Int16List(57600));
      buffer.pullSamples(pullSize);
      for (var i = 0; i < 40; i++) {
        buffer.pullSamples(pullSize);
      }
      for (var i = 0; i < 11; i++) {
        buffer.pullSamples(pullSize);
      }
      buffer.addChunk(1, Int16List(pullSize));
      final depthBefore = buffer.bufferDepthMs;
      buffer.pullSamples(pullSize);
      expect(buffer.bufferDepthMs, lessThanOrEqualTo(depthBefore));
      expect(depthBefore, greaterThan(0),
          reason: 'buffer should have data before pull');
    });

    test('correction rate clamped to +-4 percent of pull size', () {
      final buffer = makeBuffer();
      const int bigBlock = 960000; // 10 s
      buffer.addChunk(0, Int16List(bigBlock));
      buffer.pullSamples(pullSize);
      const int pullCount = 48;
      for (var i = 0; i < pullCount; i++) {
        buffer.pullSamples(pullSize);
      }
      final remainingMs = buffer.bufferDepthMs;
      const int noCorrectionRemaining = 912960;
      const int maxTotalExtra = 48 * 39;
      const int minRemainingSamples = noCorrectionRemaining - maxTotalExtra;
      const int minRemainingMs = minRemainingSamples ~/ 96;
      expect(remainingMs, greaterThanOrEqualTo(minRemainingMs),
          reason: 'buffer should not drain faster than 4% correction allows');
      const int noCorrectionRemainingMs = noCorrectionRemaining ~/ 96;
      expect(remainingMs, lessThan(noCorrectionRemainingMs),
          reason: 'some frame-dropping correction should have occurred');
    });

    test('output length always equals requested count regardless of correction',
        () {
      final buffer = makeBuffer();
      buffer.addChunk(0, Int16List(96000));
      for (var i = 0; i < 30; i++) {
        final result = buffer.pullSamples(pullSize);
        expect(result.length, pullSize,
            reason: 'pull $i should return exactly $pullSize samples');
        expect(result, isA<Int16List>());
      }
    });

    test('when ahead, output is padded with duplicated last frame', () {
      final buffer = makeBuffer();
      final anchor = Int16List.fromList(List.filled(pullSize, 42));
      buffer.addChunk(0, anchor);
      buffer.pullSamples(pullSize);
      const int aheadTs = 200000;
      final aheadData = Int16List.fromList(List.filled(pullSize, 7));
      buffer.addChunk(aheadTs, aheadData);
      final result = buffer.pullSamples(pullSize);
      expect(result.length, pullSize);
      final nonZeroCount = result.where((s) => s == 7).length;
      expect(nonZeroCount, pullSize,
          reason:
              'all samples should be 7 (pulled or duplicated from last frame)');
    });

    test('syncErrorUs getter reflects last computed error', () {
      final buffer = makeBuffer();
      expect(buffer.syncErrorUs, 0);
      buffer.addChunk(0, Int16List(pullSize));
      buffer.pullSamples(pullSize);
      buffer.addChunk(5000, Int16List(pullSize));
      buffer.pullSamples(pullSize);
      expect(buffer.syncErrorUs, 5000);
    });

    test('deadband resets correction accumulator', () {
      final buffer = makeBuffer();
      buffer.addChunk(0, Int16List(pullSize * 10));
      for (var i = 0; i < 5; i++) {
        buffer.pullSamples(pullSize);
      }
      expect(buffer.syncErrorUs.abs(), greaterThan(2000));
      buffer.flush();
      var ts = 0;
      for (var i = 0; i < 10; i++) {
        buffer.addChunk(ts, Int16List(pullSize));
        ts += frameDurationUs;
      }
      buffer.pullSamples(pullSize);
      buffer.pullSamples(pullSize);
      expect(buffer.syncErrorUs.abs(), lessThanOrEqualTo(2000));
    });
  });
}
