import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:sendspin_dart/sendspin_dart.dart';

import 'support/connected.dart';
import 'support/fake_server.dart';
import 'test_identity.dart';

const _album = ArtworkChannel(
    source: 'album', format: 'jpeg', mediaWidth: 300, mediaHeight: 300);
const _artist = ArtworkChannel(
    source: 'artist', format: 'png', mediaWidth: 128, mediaHeight: 128);

/// An artwork client on a controllable clock, with the artwork stream
/// started. The time filter maps server time straight onto local time.
class _Rig {
  final FakeAsync async;
  late final SendspinProtocol protocol;
  late final FakeServer server;
  final List<ArtworkFrame> images = [];
  final List<String> closes = [];

  _Rig(this.async, {bool startStream = true, bool synchronize = true}) {
    protocol = SendspinProtocol(
      playerName: 'Display',
      identity: testIdentity,
      bufferSeconds: 0,
      unpairedAccess: true,
      roles: const {SendspinRole.artwork},
      artworkChannels: const [_album, _artist],
      now: now,
    );
    protocol.onArtworkFrame = images.add;
    protocol.onClose = closes.add;
    server = connect(protocol);
    if (synchronize) {
      protocol.clock.update(0, 100, 1);
      protocol.clock.update(0, 100, 2);
    }
    if (startStream) this.startStream();
  }

  int now() => 1000000 + async.elapsed.inMicroseconds;

  void startStream([List<Map<String, dynamic>>? channels]) =>
      server.sendJson('stream/start', {
        'server_transmitted': 0,
        'artwork': {
          'channels': channels ??
              [
                {
                  'source': 'album',
                  'format': 'jpeg',
                  'width': 300,
                  'height': 300
                },
                {
                  'source': 'artist',
                  'format': 'png',
                  'width': 128,
                  'height': 128
                },
              ],
        },
      });

  void announce(int channel, int timestampUs, int totalSize) {
    final message = Uint8List(14)
      ..[0] = 8 + channel
      ..[1] = 0x02;
    ByteData.view(message.buffer)
      ..setInt64(2, timestampUs, Endian.big)
      ..setUint32(10, totalSize, Endian.big);
    server.sendMessage(message);
  }

  void part(int channel, List<int> data) =>
      server.sendMessage(Uint8List.fromList([8 + channel, 0x00, ...data]));

  void cancel(int channel) =>
      server.sendMessage(Uint8List.fromList([8 + channel, 0x01]));

  /// Sends a whole image due now.
  void image(int channel, List<int> data, {int? timestampUs}) {
    announce(channel, timestampUs ?? now(), data.length);
    if (data.isNotEmpty) part(channel, data);
  }

  void dispose() => protocol.dispose();
}

void _run(void Function(_Rig rig) body,
    {bool startStream = true, bool synchronize = true}) {
  fakeAsync((async) {
    final rig = _Rig(async, startStream: startStream, synchronize: synchronize);
    body(rig);
    rig.dispose();
  });
}

void main() {
  group('image transfer', () {
    test('an announce followed by its parts delivers the image', () {
      _run((rig) {
        rig.announce(0, rig.now(), 6);
        rig.part(0, [1, 2, 3]);
        expect(rig.images, isEmpty, reason: 'transfer not complete');
        rig.part(0, [4, 5, 6]);

        expect(rig.images, hasLength(1));
        expect(rig.images.single.channel, 0);
        expect(rig.images.single.imageData, [1, 2, 3, 4, 5, 6]);
        expect(rig.protocol.currentArtwork(0), [1, 2, 3, 4, 5, 6]);
        expect(rig.closes, isEmpty);
      });
    });

    test('message types 8-11 are channels 0-3', () {
      _run((rig) {
        rig.image(1, [9, 9]);
        expect(rig.images.single.channel, 1);
        expect(rig.protocol.currentArtwork(1), [9, 9]);
        expect(rig.protocol.currentArtwork(0), isNull);
      });
    });

    test('other messages may arrive between the parts of a transfer', () {
      _run((rig) {
        rig.announce(0, rig.now(), 2);
        rig.server.sendJson('group/update', {
          'playback_state': 'playing',
          'group_id': 'g',
          'group_name': 'G',
        });
        rig.part(0, [7]);
        rig.part(0, [8]);
        expect(rig.images.single.imageData, [7, 8]);
      });
    });

    test('an image of size zero clears the channel', () {
      _run((rig) {
        rig.image(0, [1, 2]);
        rig.announce(0, rig.now(), 0);

        expect(rig.images, hasLength(2));
        expect(rig.images.last.imageData, isEmpty);
        expect(rig.protocol.currentArtwork(0), isNull);
      });
    });

    test('artwork arriving late is still shown', () {
      _run((rig) {
        rig.image(0, [1], timestampUs: rig.now() - 60000000);
        expect(rig.images, hasLength(1));
      });
    });
  });

  group('scheduled images', () {
    test('a future image is held until its timestamp', () {
      _run((rig) {
        rig.image(0, [1]);
        rig.image(0, [2], timestampUs: rig.now() + 5000000);
        expect(rig.protocol.currentArtwork(0), [1]);

        rig.async.elapse(const Duration(seconds: 4));
        expect(rig.protocol.currentArtwork(0), [1]);
        rig.async.elapse(const Duration(seconds: 1));
        expect(rig.protocol.currentArtwork(0), [2]);
        expect(rig.images.map((f) => f.imageData.single), [1, 2]);
      });
    });

    test('an announce discards the pending image on that channel', () {
      _run((rig) {
        rig.image(0, [1], timestampUs: rig.now() + 5000000);
        rig.image(0, [2], timestampUs: rig.now() + 6000000);
        rig.async.elapse(const Duration(seconds: 10));
        expect(rig.images.map((f) => f.imageData.single), [2]);
      });
    });

    test('a pending image on another channel is unaffected', () {
      _run((rig) {
        rig.image(0, [1], timestampUs: rig.now() + 5000000);
        rig.image(1, [2]);
        rig.async.elapse(const Duration(seconds: 5));
        expect(rig.protocol.currentArtwork(0), [1]);
        expect(rig.protocol.currentArtwork(1), [2]);
      });
    });

    test('cancel discards the pending image and keeps the current one', () {
      _run((rig) {
        rig.image(0, [1]);
        rig.image(0, [2], timestampUs: rig.now() + 5000000);
        rig.cancel(0);
        rig.async.elapse(const Duration(seconds: 10));
        expect(rig.protocol.currentArtwork(0), [1]);
        expect(rig.images, hasLength(1));
      });
    });

    test('cancel ends a transfer in flight so another can be announced', () {
      _run((rig) {
        rig.announce(0, rig.now(), 10);
        rig.part(0, [1, 2]);
        rig.cancel(0);
        rig.image(1, [5]);
        expect(rig.closes, isEmpty);
        expect(rig.images.single.channel, 1);
      });
    });

    test('a scheduled clear takes effect at its timestamp', () {
      _run((rig) {
        rig.image(0, [1]);
        rig.announce(0, rig.now() + 2000000, 0);
        expect(rig.protocol.currentArtwork(0), [1]);
        rig.async.elapse(const Duration(seconds: 2));
        expect(rig.protocol.currentArtwork(0), isNull);
      });
    });

    test('an image is shown immediately while the time filter has no samples',
        () {
      _run((rig) {
        rig.image(0, [1], timestampUs: rig.now() + 3600000000);
        expect(rig.protocol.currentArtwork(0), [1]);
      }, synchronize: false);
    });
  });

  group('stream lifecycle', () {
    test('artwork outside an active artwork stream is ignored', () {
      _run((rig) {
        rig.image(0, [1]);
        expect(rig.images, isEmpty);
        expect(rig.closes, isEmpty);
      }, startStream: false);
    });

    test('stream/end clears the current image and discards the pending one',
        () {
      _run((rig) {
        rig.image(0, [1]);
        rig.image(0, [2], timestampUs: rig.now() + 5000000);
        rig.server.sendJson('stream/end', {
          'roles': ['artwork']
        });

        expect(rig.protocol.currentArtwork(0), isNull);
        expect(rig.images.last.imageData, isEmpty,
            reason: 'the clear is reported');
        rig.async.elapse(const Duration(seconds: 10));
        expect(rig.protocol.currentArtwork(0), isNull);
      });
    });

    test('a stream/end for another role leaves artwork alone', () {
      _run((rig) {
        rig.image(0, [1]);
        rig.server.sendJson('stream/end', {
          'roles': ['player']
        });
        expect(rig.protocol.currentArtwork(0), [1]);
      });
    });

    test('a stream/start that changes a channel discards its pending image',
        () {
      _run((rig) {
        rig.image(0, [1], timestampUs: rig.now() + 5000000);
        rig.image(1, [2], timestampUs: rig.now() + 5000000);
        // Channel 0 changes size; channel 1 keeps its configuration.
        rig.startStream([
          {'source': 'album', 'format': 'jpeg', 'width': 600, 'height': 600},
          {'source': 'artist', 'format': 'png', 'width': 128, 'height': 128},
        ]);
        rig.async.elapse(const Duration(seconds: 10));
        expect(rig.protocol.currentArtwork(0), isNull);
        expect(rig.protocol.currentArtwork(1), [2]);
      });
    });

    test('removing the artwork role clears its images', () {
      _run((rig) {
        rig.image(0, [1]);
        activate(rig.server, rig.protocol, roles: <String>[]);
        expect(rig.protocol.currentArtwork(0), isNull);
        expect(rig.images.last.imageData, isEmpty);
      });
    });
  });

  group('malformed messages close the connection', () {
    void expectClose(void Function(_Rig rig) send, {bool startStream = true}) {
      _run((rig) {
        send(rig);
        expect(rig.closes, hasLength(1));
        expect(rig.images, isEmpty);
      }, startStream: startStream);
    }

    test('a message shorter than two bytes', () {
      expectClose((rig) => rig.server.sendMessage(Uint8List.fromList([8])));
    });

    test('an announce that is not 14 bytes', () {
      expectClose((rig) => rig.server
          .sendMessage(Uint8List.fromList([8, 0x02, 0, 0, 0, 0, 0, 0, 0, 1])));
      expectClose(
          (rig) => rig.server.sendMessage(Uint8List(15)..setAll(0, [8, 0x02])));
    });

    test('a cancel longer than two bytes', () {
      expectClose(
          (rig) => rig.server.sendMessage(Uint8List.fromList([8, 0x01, 0])));
    });

    test('a reserved flag bit', () {
      expectClose(
          (rig) => rig.server.sendMessage(Uint8List.fromList([8, 0x04, 1])));
    });

    test('announce and cancel flags together', () {
      expectClose(
          (rig) => rig.server.sendMessage(Uint8List(14)..setAll(0, [8, 0x03])));
    });

    test('a malformed message is a protocol error even with no stream', () {
      expectClose(
          (rig) => rig.server.sendMessage(Uint8List.fromList([8, 0x80])),
          startStream: false);
    });

    test('a message over the size cap', () {
      // 65519 bytes is the largest artwork message; one more is malformed.
      // It arrives fragmented, since it no longer fits one Noise message.
      expectClose((rig) {
        rig.announce(0, rig.now(), 100000);
        rig.server.sendMessage(Uint8List(65520)..[0] = 8);
      });
    });
  });

  group('malformed sequences close the connection', () {
    test('an announce while a transfer is in flight', () {
      _run((rig) {
        rig.announce(0, rig.now(), 10);
        rig.announce(1, rig.now(), 10);
        expect(rig.closes, hasLength(1));
      });
    });

    test('a part with no transfer in flight', () {
      _run((rig) {
        rig.part(0, [1]);
        expect(rig.closes, hasLength(1));
      });
    });

    test('a part on another channel than the transfer in flight', () {
      _run((rig) {
        rig.announce(0, rig.now(), 10);
        rig.part(1, [1]);
        expect(rig.closes, hasLength(1));
      });
    });

    test('a part that runs past total_size', () {
      _run((rig) {
        rig.announce(0, rig.now(), 2);
        rig.part(0, [1, 2, 3]);
        expect(rig.closes, hasLength(1));
        expect(rig.images, isEmpty);
      });
    });

    test('a part after the transfer completed', () {
      _run((rig) {
        rig.image(0, [1, 2]);
        rig.part(0, [3]);
        expect(rig.closes, hasLength(1));
      });
    });
  });

  group('client without the artwork role', () {
    test('ignores artwork messages, malformed or not', () {
      final protocol = SendspinProtocol(
        playerName: 'P',
        identity: testIdentity,
        bufferSeconds: 5,
        unpairedAccess: true,
      );
      addTearDown(protocol.dispose);
      final closes = <String>[];
      protocol.onClose = closes.add;
      final server = connect(protocol);
      server.sendMessage(Uint8List.fromList([8, 0x80]));
      server.sendMessage(Uint8List.fromList([8]));
      expect(closes, isEmpty);
    });
  });

  group('channel configuration', () {
    test('setArtworkChannels reports the new configuration', () {
      _run((rig) {
        rig.server.receivedJson.clear();
        rig.protocol.setArtworkChannels(const [
          ArtworkChannel(
              source: 'none', format: 'jpeg', mediaWidth: 0, mediaHeight: 0),
        ]);
        expect(
            sentOfType(rig.protocol, 'client/state').single['payload']
                ['artwork'],
            {
              'channels': [
                {'source': 'none'}
              ]
            });
      });
    });

    test('setArtworkChannels rejects more than four channels', () {
      _run((rig) {
        expect(() => rig.protocol.setArtworkChannels(List.filled(5, _album)),
            throwsArgumentError);
      });
    });
  });
}
