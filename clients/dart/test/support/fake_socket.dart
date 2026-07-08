/// Test doubles for [RealtimeService]'s [WebSocketConnector].
///
/// A [FakeSocketFactory] hands out a fresh [FakeConnection] on every connect
/// (so reconnect tests can grab the newest socket via [FakeSocketFactory.last]).
/// Each connection is backed by a [StreamChannelController]: the service reads
/// the `local` channel while the test drives the `foreign` side —
///
///  - frames the service sends (`local.sink.add`) are captured, JSON-decoded,
///    into [FakeConnection.sent];
///  - the test pushes a server frame with [FakeConnection.push];
///  - the test simulates an unexpected transport drop with
///    [FakeConnection.serverClose].
library;

import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';

/// A single fake WebSocket connection over an in-memory [StreamChannel].
class FakeConnection {
  final StreamChannelController<dynamic> _ctrl =
      StreamChannelController<dynamic>();

  /// Frames the service sent, JSON-decoded (each is a `Map<String, dynamic>`).
  final List<dynamic> sent = <dynamic>[];

  late final StreamSubscription<dynamic> _capture;

  /// `true` once the service closed its side of the channel.
  bool serviceClosed = false;

  FakeConnection() {
    _capture = _ctrl.foreign.stream.listen((dynamic data) {
      sent.add(jsonDecode(data as String));
    }, onDone: () => serviceClosed = true);
  }

  /// The channel handed to the service under test.
  StreamChannel<dynamic> get channel => _ctrl.local;

  /// Only the `subscribe` frames the service sent, in order.
  List<dynamic> get subscribeFrames =>
      sent.where((f) => (f as Map)['action'] == 'subscribe').toList();

  /// Only the `unsubscribe` frames the service sent, in order.
  List<dynamic> get unsubscribeFrames =>
      sent.where((f) => (f as Map)['action'] == 'unsubscribe').toList();

  /// Push a server frame to the service.
  void push(Map<String, dynamic> frame) {
    _ctrl.foreign.sink.add(jsonEncode(frame));
  }

  /// Simulate an unexpected transport drop (peer closed the socket).
  Future<void> serverClose() async {
    await _ctrl.foreign.sink.close();
  }

  /// Stop capturing (called by the factory when tearing down).
  Future<void> dispose() async {
    await _capture.cancel();
  }
}

/// A [WebSocketConnector] that records every connection it builds.
class FakeSocketFactory {
  final List<FakeConnection> connections = <FakeConnection>[];

  /// Connect attempts to fail (reject) before succeeding, for backoff tests.
  int pendingFailures = 0;

  /// The error thrown by a failing connect attempt.
  Object failWith = StateError('connect failed');

  /// The last [Uri] the connector was asked to open.
  Uri? lastUri;

  /// When set, [connect] parks on this gate before resolving, letting a test
  /// interleave work (e.g. `close()`) while the connect is still in flight.
  Completer<void>? gate;

  /// The [WebSocketConnector] closure to pass to [RealtimeService].
  Future<StreamChannel<dynamic>> connect(Uri uri) async {
    lastUri = uri;
    final g = gate;
    if (g != null) await g.future;
    if (pendingFailures > 0) {
      pendingFailures -= 1;
      throw failWith;
    }
    final conn = FakeConnection();
    connections.add(conn);
    return conn.channel;
  }

  /// The most recently constructed connection.
  FakeConnection get last {
    if (connections.isEmpty) {
      throw StateError('no FakeConnection constructed yet');
    }
    return connections.last;
  }
}
