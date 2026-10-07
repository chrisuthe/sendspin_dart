// ABOUTME: Receiver for the artwork role's binary image transfers.
// ABOUTME: Announce / part / cancel parsing, pending and current images.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'models.dart';

/// A malformed artwork message or sequence. Per the artwork role these are
/// protocol errors and the client must close the connection.
class ArtworkError implements Exception {
  final String message;
  const ArtworkError(this.message);

  @override
  String toString() => 'ArtworkError: $message';
}

const int _firstArtworkId = 8;
const int _channelCount = 4;
const int _flagCancel = 0x01;
const int _flagAnnounce = 0x02;
const int _flagsReserved = 0xFC;
const int _announceLength = 14;

/// The largest artwork message, so each fits one Noise transport message.
const int _maxMessageLength = 65519;

/// The most recently announced image on a channel, until it becomes current.
class _PendingImage {
  final int timestampUs;
  final int totalSize;

  /// True when the image's bytes are counted but not kept: the client is
  /// unavailable, or the image is larger than it is willing to hold.
  final bool discard;
  final BytesBuilder data = BytesBuilder(copy: true);
  int received = 0;
  Timer? timer;

  _PendingImage(this.timestampUs, this.totalSize, {required this.discard});

  bool get isComplete => received == totalSize;
}

/// Receives artwork for up to four channels.
///
/// An image arrives as an announce (timestamp and total size) followed by
/// parts, with at most one transfer in flight across all channels. Each
/// channel keeps a current image and at most one pending image; the pending
/// one becomes current once its transfer is complete and its timestamp has
/// been reached. Artwork is never dropped for being late.
class ArtworkReceiver {
  /// Microseconds until server time [timestampUs] is reached on the local
  /// clock, by the time filter's current estimate. Zero or less means now.
  final int Function(int timestampUs) usUntil;

  /// The largest image that is kept. A larger one is still received and
  /// tracked to the end of its transfer, as the role requires, but its bytes
  /// are not stored and it is never shown.
  static const int maxImageBytes = 32 * 1024 * 1024;

  /// Called when a channel's image changes: a pending image became current,
  /// or the channel was cleared, in which case the image data is empty.
  void Function(ArtworkFrame frame)? onImage;

  final List<Uint8List?> _current = List.filled(_channelCount, null);
  final List<_PendingImage?> _pending = List.filled(_channelCount, null);
  final List<String?> _config = List.filled(_channelCount, null);

  /// The channel whose image is part-way through transfer, if any.
  int? _transferChannel;

  ArtworkReceiver({required this.usUntil});

  /// A copy of the image a channel currently shows, or null if it shows
  /// none.
  Uint8List? currentImage(int channel) {
    final image =
        channel >= 0 && channel < _channelCount ? _current[channel] : null;
    return image == null ? null : Uint8List.fromList(image);
  }

  /// Handles one artwork binary message (IDs 8-11). Malformed messages
  /// always throw [ArtworkError]; a well-formed message outside an active
  /// artwork stream is ignored.
  ///
  /// With [discard] set (the client is unavailable) announces, parts and
  /// cancels are still processed and checked, but an image's bytes are not
  /// kept and it is not shown. A zero-size image, which clears the channel,
  /// is applied regardless.
  void handleMessage(
    Uint8List message, {
    required bool streamActive,
    bool discard = false,
  }) {
    if (message.length < 2) {
      throw const ArtworkError('message shorter than two bytes');
    }
    if (message.length > _maxMessageLength) {
      throw const ArtworkError('message exceeds the size cap');
    }
    final channel = message[0] - _firstArtworkId;
    if (channel < 0 || channel >= _channelCount) {
      throw const ArtworkError('not an artwork message ID');
    }
    final flags = message[1];
    if (flags & _flagsReserved != 0) {
      throw const ArtworkError('reserved flag bit set');
    }
    final isAnnounce = flags & _flagAnnounce != 0;
    final isCancel = flags & _flagCancel != 0;
    if (isAnnounce && isCancel) {
      throw const ArtworkError('announce and cancel flags both set');
    }
    if (isAnnounce && message.length != _announceLength) {
      throw const ArtworkError('announce is not 14 bytes');
    }
    if (isCancel && message.length != 2) {
      throw const ArtworkError('cancel is longer than two bytes');
    }
    if (!streamActive) return;

    if (isCancel) {
      _discardPending(channel);
    } else if (isAnnounce) {
      if (_transferChannel != null) {
        throw const ArtworkError('announce while a transfer is in flight');
      }
      final view = ByteData.sublistView(message);
      _discardPending(channel);
      final totalSize = view.getUint32(10, Endian.big);
      final pending = _PendingImage(
        view.getInt64(2, Endian.big),
        totalSize,
        discard: totalSize > maxImageBytes || (discard && totalSize > 0),
      );
      _pending[channel] = pending;
      if (pending.isComplete) {
        _evaluate(channel);
      } else {
        _transferChannel = channel;
      }
    } else {
      final pending = _pending[channel];
      if (_transferChannel != channel || pending == null) {
        throw const ArtworkError('part without a transfer on its channel');
      }
      final length = message.length - 2;
      if (pending.received + length > pending.totalSize) {
        throw const ArtworkError('part extends past total_size');
      }
      pending.received += length;
      if (!pending.discard) {
        pending.data.add(Uint8List.sublistView(message, 2));
      }
      if (pending.isComplete) {
        _transferChannel = null;
        if (pending.discard) {
          _pending[channel] = null;
        } else {
          _evaluate(channel);
        }
      }
    }
  }

  void _discardPending(int channel) {
    _pending[channel]?.timer?.cancel();
    _pending[channel] = null;
    if (_transferChannel == channel) _transferChannel = null;
  }

  /// Makes a channel's pending image current if it is complete and due,
  /// otherwise (re)arms the timer for it.
  void _evaluate(int channel) {
    final pending = _pending[channel];
    if (pending == null || !pending.isComplete) return;
    pending.timer?.cancel();
    final waitUs = usUntil(pending.timestampUs);
    if (waitUs > 0) {
      pending.timer =
          Timer(Duration(microseconds: waitUs), () => _evaluate(channel));
      return;
    }
    _pending[channel] = null;
    final image = pending.data.takeBytes();
    // An empty image clears the channel.
    _current[channel] = image.isEmpty ? null : image;
    // The consumer gets its own copy; what the channel shows stays ours.
    onImage?.call(ArtworkFrame(
        channel: channel,
        timestampUs: pending.timestampUs,
        imageData: Uint8List.fromList(image)));
  }

  /// Re-checks every pending image, after the time filter has moved.
  void reevaluate() {
    for (var channel = 0; channel < _channelCount; channel++) {
      _evaluate(channel);
    }
  }

  /// Applies an artwork `stream/start`. A channel whose configuration
  /// changed loses its pending image; the server re-sends it if it still
  /// applies.
  void streamStarted(List<dynamic> channels) {
    for (var channel = 0; channel < _channelCount; channel++) {
      final config =
          channel < channels.length ? _configKey(channels[channel]) : null;
      if (config != _config[channel]) _discardPending(channel);
      _config[channel] = config;
    }
  }

  /// A channel's configuration reduced to the fields that define it, so two
  /// spellings of the same configuration compare equal. A channel that is
  /// not streamed (`source: 'none'`, or malformed) is the same as an absent
  /// one.
  static String? _configKey(Object? channel) {
    if (channel is! Map<String, dynamic>) return null;
    final source = channel['source'];
    if (source is! String || source == 'none') return null;
    Object? number(Object? v) => v is num ? v.toDouble() : v;
    return jsonEncode([
      source,
      channel['format'],
      number(channel['width']),
      number(channel['height']),
    ]);
  }

  /// Ends the artwork stream: every channel's current image is cleared and
  /// any pending image discarded.
  void streamEnded() {
    for (var channel = 0; channel < _channelCount; channel++) {
      _discardPending(channel);
      _config[channel] = null;
      if (_current[channel] != null) {
        _current[channel] = null;
        onImage?.call(ArtworkFrame(
            channel: channel, timestampUs: 0, imageData: Uint8List(0)));
      }
    }
  }

  /// Drops all images and timers without reporting, for a new connection.
  void reset() {
    for (var channel = 0; channel < _channelCount; channel++) {
      _discardPending(channel);
      _config[channel] = null;
      _current[channel] = null;
    }
  }
}
