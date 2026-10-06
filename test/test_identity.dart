import 'dart:typed_data';

import 'package:sendspin_dart/sendspin_dart.dart';

/// A fixed identity for tests that need a protocol or player instance but do
/// not care which key it has.
final SendspinIdentity testIdentity = SendspinIdentity.fromPrivateKey(
    Uint8List.fromList(List<int>.generate(32, (i) => i + 1)));
