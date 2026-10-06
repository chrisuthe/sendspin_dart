// ABOUTME: Sendspin binary message IDs and fragmentation (message ID 1).
// ABOUTME: Splits and reassembles messages larger than one Noise message.
import 'dart:typed_data';

/// Binary message ID carrying a UTF-8 JSON message body.
const int messageIdJson = 0;

/// Binary message ID of a fragment of a larger message.
const int messageIdFragment = 1;

const int _flagLast = 0x01;
const int _flagFirst = 0x02;
const int _flagsReserved = 0xFC;

/// Largest decrypted binary message that fits one Noise transport message:
/// the 65535-byte Noise limit minus the 16-byte AEAD tag. The first byte is
/// the message ID, leaving 65518 bytes of payload.
const int maxTransportPlaintext = 65535 - 16;

/// A malformed fragment sequence. Per the Sendspin spec this is a protocol
/// error and the receiver must close the connection.
class FramingError implements Exception {
  final String message;
  const FramingError(this.message);

  @override
  String toString() => 'FramingError: $message';
}

/// Splits [message] (message ID byte followed by its payload) into the
/// binary messages to send. A message that fits is returned as is; a larger
/// one becomes `[1][flags][orig_type][data]` then `[1][flags][data]`...
List<Uint8List> fragmentMessage(Uint8List message) {
  if (message.isEmpty) {
    throw ArgumentError('A binary message needs at least its ID byte');
  }
  if (message.length <= maxTransportPlaintext) return [message];
  final origType = message[0];
  if (origType == messageIdFragment) {
    throw ArgumentError('A fragment message cannot itself be fragmented');
  }

  final frames = <Uint8List>[];
  var offset = 1;
  while (offset < message.length) {
    final first = frames.isEmpty;
    final headerLength = first ? 3 : 2;
    final end = offset + maxTransportPlaintext - headerLength;
    final last = end >= message.length;
    final data =
        Uint8List.sublistView(message, offset, last ? message.length : end);
    final frame = Uint8List(headerLength + data.length);
    frame[0] = messageIdFragment;
    frame[1] = (first ? _flagFirst : 0) | (last ? _flagLast : 0);
    if (first) frame[2] = origType;
    frame.setRange(headerLength, frame.length, data);
    frames.add(frame);
    offset += data.length;
  }
  return frames;
}

/// Receiver side of fragmentation: one reassembly buffer and the in-flight
/// `orig_type`, enforcing the malformed-sequence rules.
class MessageReassembler {
  /// Upper bound on a reassembled message, so a peer cannot grow the buffer
  /// without limit.
  final int maxMessageLength;

  BytesBuilder? _buffer;
  int _origType = 0;

  MessageReassembler({this.maxMessageLength = 16 * 1024 * 1024});

  /// Whether a fragmented message is partly received.
  bool get inFlight => _buffer != null;

  /// Feeds one decrypted binary message. Returns a complete message (ID byte
  /// followed by payload), or null when more fragments are needed. Throws
  /// [FramingError] on a malformed sequence.
  Uint8List? add(Uint8List message) {
    if (message.isEmpty) {
      throw const FramingError('empty binary message');
    }
    if (message[0] != messageIdFragment) {
      if (inFlight) {
        throw const FramingError(
            'non-fragment message while a fragmented message is in flight');
      }
      return message;
    }

    if (message.length < 2) {
      throw const FramingError('fragment without a flags byte');
    }
    final flags = message[1];
    if (flags & _flagsReserved != 0) {
      throw const FramingError('reserved fragment flag bit set');
    }

    final int dataStart;
    if (flags & _flagFirst != 0) {
      if (inFlight) {
        throw const FramingError(
            'first fragment while a fragmented message is in flight');
      }
      if (message.length < 3) {
        throw const FramingError('first fragment without an orig_type');
      }
      if (message[2] == messageIdFragment) {
        throw const FramingError('fragment orig_type must not be 1');
      }
      _origType = message[2];
      _buffer = BytesBuilder(copy: false)..addByte(_origType);
      dataStart = 3;
    } else {
      if (!inFlight) {
        throw const FramingError('fragment with no message in flight');
      }
      dataStart = 2;
    }

    final buffer = _buffer!;
    if (buffer.length + message.length - dataStart > maxMessageLength) {
      _buffer = null;
      throw const FramingError('reassembled message exceeds the size limit');
    }
    buffer.add(Uint8List.sublistView(message, dataStart));
    if (flags & _flagLast == 0) return null;

    _buffer = null;
    return buffer.takeBytes();
  }

  /// Drops any partly received message.
  void reset() => _buffer = null;
}
