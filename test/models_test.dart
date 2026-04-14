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

  group('SendspinMetadata', () {
    test('defaults: all-null fields and repeat is unknown', () {
      const m = SendspinMetadata();
      expect(m.timestamp, 0);
      expect(m.title, isNull);
      expect(m.artist, isNull);
      expect(m.albumArtist, isNull);
      expect(m.album, isNull);
      expect(m.artworkUrl, isNull);
      expect(m.year, isNull);
      expect(m.track, isNull);
      expect(m.progress, isNull);
      expect(m.shuffle, isNull);
      expect(m.repeat, SendspinRepeatMode.unknown);
    });
  });

  group('SendspinRepeatMode.fromWire', () {
    test('maps all four wire values', () {
      expect(SendspinRepeatMode.fromWire('off'), SendspinRepeatMode.off);
      expect(SendspinRepeatMode.fromWire('one'), SendspinRepeatMode.one);
      expect(SendspinRepeatMode.fromWire('all'), SendspinRepeatMode.all);
      expect(SendspinRepeatMode.fromWire(null), SendspinRepeatMode.unknown);
      expect(SendspinRepeatMode.fromWire('bogus'), SendspinRepeatMode.unknown);
    });
  });

  group('SendspinControllerInfo', () {
    test('defaults', () {
      const c = SendspinControllerInfo();
      expect(c.supportedCommands, isEmpty);
      expect(c.volume, 0);
      expect(c.muted, false);
    });
  });
}
