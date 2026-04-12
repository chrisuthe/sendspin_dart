import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

void main() {
  group('StreamConfig', () {
    test('stores all audio format fields from stream/start', () {
      final config = StreamConfig(
        codec: 'flac',
        channels: 2,
        sampleRate: 48000,
        bitDepth: 24,
        codecHeader: 'base64data==',
      );
      expect(config.codec, 'flac');
      expect(config.channels, 2);
      expect(config.sampleRate, 48000);
      expect(config.bitDepth, 24);
      expect(config.codecHeader, 'base64data==');
    });

    test('codecHeader defaults to null', () {
      final config = StreamConfig(
        codec: 'pcm',
        channels: 2,
        sampleRate: 44100,
        bitDepth: 16,
      );
      expect(config.codecHeader, isNull);
    });
  });
}
