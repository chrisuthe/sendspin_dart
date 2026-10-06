import 'dart:convert';
import 'dart:typed_data';

import 'package:sendspin_dart/sendspin_dart.dart';

import 'fake_server.dart';

final Expando<FakeServer> _servers = Expando<FakeServer>();

SendspinProtocol _protocolOf(Object target) =>
    target is SendspinPlayer ? target.protocol : target as SendspinProtocol;

/// Connects [target] (a [SendspinProtocol] or [SendspinPlayer]) to a
/// [FakeServer]: `client/init`, the Noise handshake, `server/hello`,
/// `client/hello` and, unless [activate] is false, a `server/activate`
/// declaring [activities] and [roles] (default: every role the client
/// supports). The server's record of received messages is cleared afterwards,
/// so a test only sees what it causes.
///
/// The default server uses the Sentinel PSK, so declaring `playback`
/// requires the client to have unpaired access enabled.
FakeServer connect(
  Object target, {
  FakeServer? server,
  List<String>? roles,
  List<String> activities = const ['playback'],
  bool activate = true,
}) {
  final protocol = _protocolOf(target);
  final fake = server ?? FakeServer();
  _servers[protocol] = fake;
  protocol.onSendText = fake.receiveText;
  protocol.onSendBinary = fake.receiveBinary;
  fake.deliverText = protocol.handleTextMessage;
  fake.deliverBinary = protocol.handleBinaryMessage;

  protocol.start();
  fake.sendJson('server/hello', {'name': 'TestServer'});
  if (activate) {
    fake.sendJson('server/activate', {
      'activities': activities,
      'active_roles': roles ?? protocol.roles.map((r) => r.wireValue).toList(),
    });
  }
  fake.receivedJson.clear();
  return fake;
}

/// Sends a `server/activate` from [server] declaring [activities] and
/// [roles] (default: every role [target] supports).
void activate(
  FakeServer server,
  Object target, {
  List<String>? roles,
  List<String> activities = const ['playback'],
}) =>
    server.sendJson('server/activate', {
      'activities': activities,
      'active_roles':
          roles ?? _protocolOf(target).roles.map((r) => r.wireValue).toList(),
    });

/// The [FakeServer] [target] is connected to, connecting it first if needed.
FakeServer serverOf(Object target) =>
    _servers[_protocolOf(target)] ?? connect(target);

/// Delivers a JSON message from the server, encrypted.
void serverSends(Object target, String json) =>
    serverOf(target).sendJsonText(json);

/// Delivers a binary message (ID byte first) from the server, encrypted.
void serverSendsBinary(Object target, Uint8List message) =>
    serverOf(target).sendMessage(message);

/// Appends every JSON message the client sends from now on to [sink], each
/// re-encoded as a string.
void captureSent(Object target, List<String> sink) =>
    serverOf(target).onJson = (json) => sink.add(jsonEncode(json));

/// The JSON messages the client has sent since it connected.
List<Map<String, dynamic>> sentBy(Object target) =>
    serverOf(target).receivedJson;

/// The messages of [type] the client has sent since it connected.
List<Map<String, dynamic>> sentOfType(Object target, String type) =>
    sentBy(target).where((m) => m['type'] == type).toList();
