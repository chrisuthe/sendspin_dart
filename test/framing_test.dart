import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:sendspin_dart/src/framing.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);

/// A message of [length] bytes total: ID [id] then a repeating pattern.
Uint8List _message(int id, int length) => Uint8List.fromList(
    [id, for (var i = 1; i < length; i++) (i * 31 + 7) & 0xFF]);

void main() {
  group('fragmentMessage', () {
    test('a message that fits one transport message is sent whole', () {
      final message = _message(4, maxTransportPlaintext);
      final frames = fragmentMessage(message);
      expect(frames, hasLength(1));
      expect(frames.single, message);
    });

    test('the payload limit per transport message is 65518 bytes', () {
      expect(maxTransportPlaintext, 65519);
      expect(fragmentMessage(_message(0, 1 + 65518)), hasLength(1));
      expect(fragmentMessage(_message(0, 1 + 65519)), hasLength(2));
    });

    test('an oversized message is split into first and last fragments', () {
      final message = _message(0, maxTransportPlaintext + 1);
      final frames = fragmentMessage(message);
      expect(frames, hasLength(2));

      // First: [1][flags=first][orig_type][data]
      expect(frames[0].sublist(0, 3), [1, 0x02, 0]);
      expect(frames[0], hasLength(maxTransportPlaintext));
      // Last: [1][flags=last][data]
      expect(frames[1].sublist(0, 2), [1, 0x01]);

      final data = [...frames[0].skip(3), ...frames[1].skip(2)];
      expect(data, message.sublist(1));
    });

    test('middle fragments carry neither flag', () {
      final frames = fragmentMessage(_message(8, 3 * maxTransportPlaintext));
      expect(frames.length, greaterThanOrEqualTo(3));
      expect(frames.first[1], 0x02);
      for (final middle in frames.sublist(1, frames.length - 1)) {
        expect(middle.sublist(0, 2), [1, 0x00]);
        expect(middle, hasLength(maxTransportPlaintext));
      }
      expect(frames.last[1], 0x01);
    });

    test('an empty message is refused', () {
      expect(() => fragmentMessage(Uint8List(0)), throwsArgumentError);
    });

    test('a fragment message itself cannot be fragmented', () {
      expect(() => fragmentMessage(_message(1, maxTransportPlaintext + 1)),
          throwsArgumentError);
    });
  });

  group('MessageReassembler', () {
    test('passes a non-fragment message straight through', () {
      final r = MessageReassembler();
      expect(r.add(_bytes([4, 9, 9])), [4, 9, 9]);
    });

    test('reassembles what fragmentMessage produced', () {
      final message = _message(0, 3 * maxTransportPlaintext + 17);
      final r = MessageReassembler();
      Uint8List? result;
      final frames = fragmentMessage(message);
      for (var i = 0; i < frames.length; i++) {
        result = r.add(frames[i]);
        if (i < frames.length - 1) expect(result, isNull);
      }
      expect(result, message);
      expect(r.inFlight, isFalse);
    });

    test('a single fragment may be both first and last', () {
      final r = MessageReassembler();
      expect(r.add(_bytes([1, 0x03, 4, 0xAA, 0xBB])), [4, 0xAA, 0xBB]);
    });

    test('accepts messages again after a completed sequence', () {
      final r = MessageReassembler();
      r.add(_bytes([1, 0x02, 4, 1]));
      r.add(_bytes([1, 0x01, 2]));
      expect(r.add(_bytes([0, 123])), [0, 123]);
    });

    test('a first fragment while one is in flight is malformed', () {
      final r = MessageReassembler();
      r.add(_bytes([1, 0x02, 4, 1]));
      expect(
          () => r.add(_bytes([1, 0x02, 4, 1])), throwsA(isA<FramingError>()));
    });

    test('a non-first fragment with none in flight is malformed', () {
      expect(() => MessageReassembler().add(_bytes([1, 0x00, 1])),
          throwsA(isA<FramingError>()));
      expect(() => MessageReassembler().add(_bytes([1, 0x01, 1])),
          throwsA(isA<FramingError>()));
    });

    test('a non-fragment message mid-sequence is malformed', () {
      final r = MessageReassembler();
      r.add(_bytes([1, 0x02, 4, 1]));
      expect(() => r.add(_bytes([0, 123])), throwsA(isA<FramingError>()));
    });

    test('a nonzero reserved flag bit is malformed', () {
      expect(() => MessageReassembler().add(_bytes([1, 0x06, 4, 1])),
          throwsA(isA<FramingError>()));
      final r = MessageReassembler()..add(_bytes([1, 0x02, 4, 1]));
      expect(() => r.add(_bytes([1, 0x81, 1])), throwsA(isA<FramingError>()));
    });

    test('an orig_type of 1 is malformed', () {
      expect(() => MessageReassembler().add(_bytes([1, 0x02, 1, 0])),
          throwsA(isA<FramingError>()));
    });

    test('a fragment too short for its header is malformed', () {
      expect(() => MessageReassembler().add(_bytes([1])),
          throwsA(isA<FramingError>()));
      expect(() => MessageReassembler().add(_bytes([1, 0x02])),
          throwsA(isA<FramingError>()));
    });

    test('an empty message is malformed', () {
      expect(() => MessageReassembler().add(Uint8List(0)),
          throwsA(isA<FramingError>()));
    });

    test('a reassembled message over the size cap is malformed', () {
      final r = MessageReassembler(maxMessageLength: 10);
      r.add(_bytes([1, 0x02, 4, 1, 2, 3, 4, 5]));
      expect(() => r.add(_bytes([1, 0x00, 6, 7, 8, 9, 10])),
          throwsA(isA<FramingError>()));
    });
  });
}
