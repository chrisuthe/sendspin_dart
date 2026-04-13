import 'player.dart';
import 'protocol.dart';

export 'protocol.dart' show AudioFrame, DeviceInfo, AudioFormat;

/// Backwards-compatible alias for [SendspinPlayer].
///
/// New code should use [SendspinPlayer] (for audio playback) or
/// [SendspinProtocol] (for visualizers/conformance tests) directly.
@Deprecated(
    'Use SendspinPlayer (audio) or SendspinProtocol (raw frames) instead')
typedef SendspinClient = SendspinPlayer;
