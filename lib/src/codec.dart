import 'dart:typed_data';

/// Empty sentinel to avoid allocating a new empty Int16List on every call.
final Int16List _emptyInt16List = Int16List(0);

/// Abstract interface for audio codecs in the Sendspin protocol.
abstract class SendspinCodec {
  /// Decodes encoded audio data into interleaved PCM samples.
  Int16List decode(Uint8List encodedData);

  /// Resets decoder state (e.g. between tracks).
  void reset();

  /// Release any native resources held by this codec.
  ///
  /// Subclasses that allocate native memory (e.g. FLAC decoders) must override
  /// this to free those resources. The default implementation is a no-op.
  void dispose() {}
}

/// PCM codec — decodes raw PCM bytes at 16, 24, or 32-bit depth to Int16.
class PcmCodec implements SendspinCodec {
  final int bitDepth;
  final int channels;
  final int sampleRate;

  PcmCodec(
      {required this.bitDepth,
      required this.channels,
      required this.sampleRate});

  @override
  Int16List decode(Uint8List encodedData) {
    if (encodedData.isEmpty) return _emptyInt16List;
    final view = ByteData.view(encodedData.buffer, encodedData.offsetInBytes,
        encodedData.lengthInBytes);

    switch (bitDepth) {
      case 16:
        final sampleCount = encodedData.length ~/ 2;
        if (encodedData.offsetInBytes % 2 == 0 &&
            Endian.host == Endian.little) {
          // Zero-copy: reinterpret the underlying byte buffer as Int16List.
          return Int16List.sublistView(encodedData, 0, sampleCount * 2);
        }
        final samples = Int16List(sampleCount);
        for (int i = 0; i < sampleCount; i++) {
          samples[i] = view.getInt16(i * 2, Endian.little);
        }
        return samples;
      case 24:
        final sampleCount = encodedData.length ~/ 3;
        final samples = Int16List(sampleCount);
        for (int i = 0; i < sampleCount; i++) {
          final offset = i * 3;
          var value = encodedData[offset] |
              (encodedData[offset + 1] << 8) |
              (encodedData[offset + 2] << 16);
          if (value & 0x800000 != 0) value |= 0xFF000000;
          // Truncate 24-bit to 16-bit (keep upper bits for best fidelity).
          samples[i] = value >> 8;
        }
        return samples;
      case 32:
        final sampleCount = encodedData.length ~/ 4;
        final samples = Int16List(sampleCount);
        for (int i = 0; i < sampleCount; i++) {
          // Truncate 32-bit to 16-bit (keep upper bits for best fidelity).
          samples[i] = view.getInt32(i * 4, Endian.little) >> 16;
        }
        return samples;
      default:
        throw ArgumentError('Unsupported bit depth: $bitDepth');
    }
  }

  @override
  void reset() {}

  @override
  void dispose() {}
}

/// Factory function to create a codec by name.
///
/// Supported codecs:
/// - `pcm`: Raw PCM (always available)
///
/// For FLAC support, provide a custom [SendspinCodec] implementation using
/// dart:ffi or another native binding.
SendspinCodec createCodec({
  required String codec,
  required int bitDepth,
  required int channels,
  required int sampleRate,
}) {
  switch (codec) {
    case 'pcm':
      return PcmCodec(
          bitDepth: bitDepth, channels: channels, sampleRate: sampleRate);
    default:
      throw ArgumentError('Unsupported codec: $codec. '
          'Only "pcm" is built-in. For FLAC, provide a custom SendspinCodec.');
  }
}
