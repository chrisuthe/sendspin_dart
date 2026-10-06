// ABOUTME: Unpadded base64url helpers used for keys, PSK ids and Noise data.
import 'dart:convert';
import 'dart:typed_data';

/// Encodes [bytes] as base64url without `=` padding, the form the Sendspin
/// spec uses for keys, PSK identifiers and Noise handshake data.
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes unpadded base64url, or returns null if [text] is not exactly
/// that: the standard alphabet (`+`, `/`), any padding, and non-canonical
/// trailing bits are all rejected, so one value has one accepted spelling.
Uint8List? base64UrlNoPadDecode(String text) {
  final Uint8List bytes;
  try {
    bytes = base64Url.decode(base64Url.normalize(text));
  } on FormatException {
    return null;
  }
  return base64UrlNoPad(bytes) == text ? bytes : null;
}
