/// Realtime (WebSocket) service: a direct port of
/// `clients/typescript/src/realtime.ts`.
///
/// The service opens a single WebSocket to `<baseUrl>/api/realtime` (with the
/// `http`/`https` scheme mapped to `ws`/`wss`) lazily on the first subscribe,
/// then multiplexes every collection- and topic-subscription over it. The wire
/// protocol is authoritative in `src/realtime/` on the server:
///
///  - Uplink: `{"action":"auth","token":…}`,
///    `{"action":"subscribe","topic":…,"filter"?:…}` (the `filter` key is
///    omitted when null), `{"action":"unsubscribe","topic":…}`.
///  - Downlink, dispatched on `type`: `connect` (stores `clientId`), `auth`
///    (`status` `ok`|`error` gates the resubscribe), `ack` (resolves pending
///    subscribes for the topic), `event` (`topic`/`action`/`record` →
///    record callbacks), `signal`/`message` (topic callbacks), `error`
///    (rejects pending subscribes and calls `onError`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'auth_store.dart';
import 'live/live_collection.dart';
import 'records.dart';

/// Builds and connects the underlying transport. The default connects via
/// [WebSocketChannel.connect] and awaits [WebSocketChannel.ready] so a failed
/// connection surfaces as a rejected [Future] (which drives the backoff).
///
/// A [WebSocketChannel] *is* a [StreamChannel]: the service reads server frames
/// from [StreamChannel.stream] and writes uplink frames to
/// [StreamChannel.sink].
typedef WebSocketConnector = Future<StreamChannel<dynamic>> Function(Uri uri);

/// Cancels a subscription; returned by [RealtimeService.subscribe] and
/// [RealtimeService.subscribeTopic].
typedef ZbUnsubscribe = Future<void> Function();

/// A record mutation delivered on a collection topic. [action] is one of
/// `create`, `update`, `delete` (a delete carries an `{id}`-only [record]).
class RecordEvent {
  final String topic;
  final String action;
  final ZbRecord record;

  const RecordEvent(this.topic, this.action, this.record);
}

/// A frame delivered on a custom (non-collection) topic. [kind] is `signal`
/// (a re-fetch hint, no [data]) or `message` (a payload-carrying broadcast).
class TopicMessage {
  final String topic;
  final String kind;
  final dynamic data;

  const TopicMessage(this.topic, this.kind, this.data);
}

enum _Kind { records, topic }

class _Subscription {
  final String topic;
  final _Kind kind;
  final String? filter;
  final Set<void Function(RecordEvent)> callbacks = {};
  final Set<void Function(TopicMessage)> topicCallbacks = {};

  /// Completers waiting for the `ack` of the in-flight subscribe frame.
  final List<Completer<void>> pending = [];
  bool acked = false;

  /// A subscribe frame is on the wire awaiting its ack — concurrent
  /// subscribers must join [pending] without sending a duplicate frame.
  bool inflight = false;

  _Subscription(this.topic, this.kind, {this.filter});
}

/// Multiplexes realtime subscriptions over a single, auto-reconnecting
/// WebSocket. Construct one per client; call [close] to tear it down.
///
/// Implements [LiveSubscriber], so it can back the high-level live store
/// (`client.realtime.collection(name)` → [LiveCollection]).
class RealtimeService implements LiveSubscriber {
  final String baseUrl;
  final AuthStore authStore;
  final WebSocketConnector _connector;
  final Duration minReconnect;
  final Duration maxReconnect;
  final Future<void> Function(Duration) _sleep;
  final void Function(Object error)? onError;

  /// Builds the [LiveReader] a [collection]'s live store seeds through. Injected
  /// by [ZigbaseClient] (each reader adapts the collection's `CollectionService`);
  /// null on a standalone service, where [collection] then throws.
  final LiveReader Function(String name)? liveReaderFactory;

  final Map<String, _Subscription> _subscriptions = {};

  /// Controllers minted by [stream] that are still live (not yet
  /// cancelled by their listener). Closed by [close] so a consumer's
  /// `await for`/`listen` over an already-acked [stream] completes rather
  /// than hanging forever once the service is torn down.
  final Set<StreamController<RecordEvent>> _streamControllers = {};
  late final StreamSubscription<AuthEvent> _authSub;

  StreamChannel<dynamic>? _channel;
  StreamSubscription<dynamic>? _streamSub;
  bool _opened = false;
  bool _connecting = false;

  /// A reconnect is scheduled and sleeping out its backoff — the channel is
  /// null and [_connecting] is false, so [_ensureConnected] must still defer to
  /// it rather than racing a second connect.
  bool _reconnectPending = false;
  bool _closedByUser = false;
  int _reconnectAttempts = 0;
  String? _clientId;
  Completer<void>? _authAck;

  RealtimeService({
    required this.baseUrl,
    required this.authStore,
    WebSocketConnector? connector,
    this.minReconnect = const Duration(milliseconds: 250),
    this.maxReconnect = const Duration(seconds: 10),
    Future<void> Function(Duration)? sleep,
    this.onError,
    this.liveReaderFactory,
  })  : _connector = connector ?? _defaultConnector,
        _sleep = sleep ?? _defaultSleep {
    // Re-auth whenever the token changes (login/logout/refresh). On logout
    // (event.token == null) an EMPTY-token frame is sent so the server, which
    // clears a connection's identity only on an auth frame that fails
    // verification, de-auths this connection instead of retaining the old
    // identity indefinitely. The token from the event is used verbatim (rather
    // than re-reading [authStore.token]) so rapid successive changes each send
    // their own value rather than coalescing on the latest.
    _authSub = authStore.onChange.listen((event) {
      if (_opened) _sendAuthFrame(event.token ?? '');
    });
  }

  static Future<StreamChannel<dynamic>> _defaultConnector(Uri uri) async {
    final channel = WebSocketChannel.connect(uri);
    await channel.ready;
    return channel;
  }

  static Future<void> _defaultSleep(Duration d) => Future<void>.delayed(d);

  /// The server-assigned connection id from the last `connect` frame, or null
  /// before the socket has connected.
  String? get clientId => _clientId;

  /// The high-level live store for [name] (mirrors the TypeScript SDK's
  /// `client.realtime.collection(name)`): returns a [LiveCollection] whose
  /// records/lists stay in sync from realtime events.
  ///
  /// Requires a [liveReaderFactory] — present on a service created by
  /// [ZigbaseClient]. A standalone [RealtimeService] built without one throws a
  /// [StateError] (obtain live collections via the client). Throws once the
  /// service has been [close]d.
  LiveCollection collection(String name) {
    if (_closedByUser) throw StateError('RealtimeService has been closed');
    final factory = liveReaderFactory;
    if (factory == null) {
      throw StateError(
          'RealtimeService.collection requires a live reader factory; obtain '
          'live collections via ZigbaseClient.realtime, not a standalone '
          'RealtimeService');
    }
    return LiveCollection(name, factory(name), this);
  }

  // ---- public API ---------------------------------------------------------

  /// Subscribe to a collection [topic] (optionally narrowed by a server-side
  /// [filter]). The returned [Future] resolves once the server `ack`s the
  /// subscription; the returned [ZbUnsubscribe] removes exactly this callback.
  ///
  /// Limitation (inherited from the TypeScript SDK): the server keys
  /// subscriptions per topic per connection (`subFilter` in
  /// `src/realtime/ws.zig` stores a single filter per topic), so subscribing
  /// to the same [topic] with two different [filter]s on one service makes the
  /// second filter overwrite the first server-side — both callbacks then
  /// receive the second filter's events.
  ///
  /// Throws a [StateError] once the service has been [close]d.
  @override
  Future<ZbUnsubscribe> subscribe(
    String topic,
    void Function(RecordEvent) callback, {
    String? filter,
  }) async {
    if (_closedByUser) throw StateError('RealtimeService has been closed');
    final key = _subKey(topic, filter);
    final sub = _subscriptions.putIfAbsent(
        key, () => _Subscription(topic, _Kind.records, filter: filter));
    sub.callbacks.add(callback);

    _ensureConnected();

    if (!sub.acked) {
      final completer = Completer<void>();
      sub.pending.add(completer);
      // If the socket is open and no subscribe frame is awaiting its ack, send
      // one now; concurrent callers just join `pending`.
      if (_opened && !sub.inflight) _sendSubscribe(sub);
      await completer.future;
    }

    return () => unsubscribe(topic, callback, filter);
  }

  /// Remove a record callback. When [filter] is null, [callback] is removed
  /// from *every* variant of [topic] (mirrors the TS public path, where a
  /// filtered subscription would otherwise silently leak); when non-null, only
  /// the exact `(topic, filter)` variant is targeted. A single `unsubscribe`
  /// frame is sent once [topic] has no live variants left.
  Future<void> unsubscribe(
    String topic, [
    void Function(RecordEvent)? callback,
    String? filter,
  ]) async {
    final targets = filter != null
        ? [_subscriptions[_subKey(topic, filter)]].whereType<_Subscription>()
        : _subscriptions.values
            .where((s) => s.kind == _Kind.records && s.topic == topic)
            .toList();

    var removed = false;
    for (final sub in targets) {
      if (callback != null) {
        sub.callbacks.remove(callback);
      } else {
        sub.callbacks.clear();
      }
      if (sub.callbacks.isEmpty) {
        // Known pre-existing gap (documented, not fixed here): a still-pending
        // (unacked) subscribe whose entry is removed at this point — e.g.
        // unsubscribed while a reconnect backoff is in flight — never settles
        // its future; nothing acks or rejects it after the entry is gone.
        _subscriptions.remove(_subKey(sub.topic, sub.filter));
        removed = true;
      }
    }

    if (removed && _opened && _channel != null && !_hasTopic(topic)) {
      _send({'action': 'unsubscribe', 'topic': topic});
    }
  }

  /// Subscribe to a custom (non-collection) [topic], receiving `signal` and
  /// `message` frames as [TopicMessage]s. Same ack/resubscribe/backoff
  /// machinery as [subscribe]; a server-rejected subscribe rejects the
  /// returned [Future]. Throws a [StateError] once the service has been
  /// [close]d.
  Future<ZbUnsubscribe> subscribeTopic(
    String topic,
    void Function(TopicMessage) callback,
  ) async {
    if (_closedByUser) throw StateError('RealtimeService has been closed');
    final key = _topicKey(topic);
    final sub = _subscriptions.putIfAbsent(
        key, () => _Subscription(topic, _Kind.topic));
    sub.topicCallbacks.add(callback);

    _ensureConnected();

    if (!sub.acked) {
      final completer = Completer<void>();
      sub.pending.add(completer);
      if (_opened && !sub.inflight) _sendSubscribe(sub);
      await completer.future;
    }

    return () => unsubscribeTopic(topic, callback);
  }

  /// Remove a topic callback (all of them when [callback] is omitted); sends
  /// one `unsubscribe` frame when the topic has no live variants left.
  Future<void> unsubscribeTopic(
    String topic, [
    void Function(TopicMessage)? callback,
  ]) async {
    final sub = _subscriptions[_topicKey(topic)];
    if (sub == null) return;
    if (callback != null) {
      sub.topicCallbacks.remove(callback);
    } else {
      sub.topicCallbacks.clear();
    }
    if (sub.topicCallbacks.isEmpty) {
      _subscriptions.remove(_topicKey(topic));
      if (_opened && _channel != null && !_hasTopic(topic)) {
        _send({'action': 'unsubscribe', 'topic': topic});
      }
    }
  }

  /// Convenience wrapper: a [Stream] of [RecordEvent]s for [topic]. Subscribes
  /// on first listen and unsubscribes when the listener cancels — including
  /// when the cancel lands while the subscribe's ack round-trip is still in
  /// flight (the late-resolving subscription is torn down immediately).
  /// Throws a [StateError] once the service has been [close]d.
  Stream<RecordEvent> stream(String topic, {String? filter}) {
    if (_closedByUser) throw StateError('RealtimeService has been closed');
    late StreamController<RecordEvent> controller;
    ZbUnsubscribe? unsub;
    var cancelled = false;
    controller = StreamController<RecordEvent>(
      onListen: () async {
        ZbUnsubscribe u;
        try {
          u = await subscribe(topic, controller.add, filter: filter);
        } catch (e, st) {
          // A rejection after cancel has no listener to inform; swallow it
          // (the server error is still surfaced via [onError]).
          if (!cancelled) {
            controller.addError(e, st);
            await controller.close();
          }
          return;
        }
        if (cancelled) {
          // The listener went away during the ack round-trip: tear the
          // just-established subscription down instead of leaking it.
          await u();
        } else {
          unsub = u;
        }
      },
      onCancel: () async {
        cancelled = true;
        _streamControllers.remove(controller);
        final u = unsub;
        unsub = null;
        if (u != null) await u();
      },
    );
    _streamControllers.add(controller);
    return controller.stream;
  }

  /// Tear down the socket, stop reconnecting, and complete any pending
  /// subscribes with an error so no future is left dangling.
  Future<void> close() async {
    _closedByUser = true;
    await _authSub.cancel();
    _failPending(StateError('RealtimeService has been closed'));
    _subscriptions.clear();
    final controllers =
        List<StreamController<RecordEvent>>.from(_streamControllers);
    _streamControllers.clear();
    for (final controller in controllers) {
      // Not awaited: a controller whose stream was never listened to has a
      // close() future that never completes; a listened one still receives
      // its done event asynchronously.
      if (!controller.isClosed) unawaited(controller.close());
    }
    await _streamSub?.cancel();
    _streamSub = null;
    await _channel?.sink.close();
    _channel = null;
    _opened = false;
  }

  // ---- connection lifecycle ----------------------------------------------

  void _ensureConnected() {
    // Defer to an in-flight connect OR a scheduled reconnect that is sleeping
    // out its backoff — during that sleep [_channel] is null and [_connecting]
    // is false, and a fresh subscribe here would otherwise open a second socket
    // that races the reconnect loop and orphans one of them.
    if (_channel != null || _connecting || _reconnectPending) return;
    _connect();
  }

  void _connect() {
    _connecting = true;
    _opened = false;
    final uri = _wsUrl(baseUrl);
    _connector(uri).then((channel) {
      if (_closedByUser) {
        // close() ran while the connect was in flight: tear the late channel
        // down and reset `_connecting` so the state isn't left wedged.
        _connecting = false;
        channel.sink.close();
        return;
      }
      _connecting = false;
      _opened = true;
      _channel = channel;
      _reconnectAttempts = 0;
      _streamSub = channel.stream.listen(
        _onMessage,
        onDone: _onClose,
        onError: (Object e) => onError?.call(e),
      );
      _onOpen();
    }).catchError((Object e) {
      // A connect failure (invalid URL, handshake refused) must not leave
      // `connecting` stuck; reset, surface, and schedule a backoff reconnect.
      _connecting = false;
      _channel = null;
      onError?.call(e);
      if (!_closedByUser && _subscriptions.isNotEmpty) _reconnect();
    });
  }

  void _onOpen() {
    // Auth first (if a token exists), then (re)subscribe every active topic —
    // gated on the auth response so the server has applied the identity before
    // evaluating subscription rules. Anonymous: resubscribe synchronously.
    final authFut = _sendAuth();
    if (authFut != null) {
      authFut.then((_) {
        if (!_closedByUser && _opened) _resubscribeAll();
      });
    } else {
      _resubscribeAll();
    }
  }

  void _resubscribeAll() {
    for (final sub in _subscriptions.values) {
      sub.acked = false;
      _sendSubscribe(sub);
    }
  }

  /// Sends an auth frame when a token exists; returns a future that completes
  /// on the auth response (or null when anonymous, so [_onOpen] resubscribes
  /// synchronously). The returned future never throws — an auth failure is
  /// surfaced via [onError] and must not block the resubscribe. Callers on the
  /// on-open path rely on the null return for the anonymous case; the
  /// connected-then-logged-out de-auth goes through [_sendAuthFrame] directly.
  Future<void>? _sendAuth() {
    final token = authStore.token;
    if (token == null) return null;
    return _sendAuthFrame(token);
  }

  /// Sends an `auth` frame carrying [token] (the empty string de-auths the
  /// connection) and returns a future that completes on the next auth response.
  ///
  /// If an auth frame is already awaiting its response, its completer is REUSED
  /// rather than replaced: back-to-back sends (e.g. rapid login/logout churn)
  /// therefore never strand an earlier waiter — every waiter settles on the
  /// first auth response, which is sufficient for [_onOpen]'s resubscribe gate
  /// (it only needs *an* auth to have been applied before resubscribing, and
  /// the newest frame is already on the wire ahead of the resubscribes). The
  /// returned future never throws (auth failures are swallowed here and
  /// surfaced via [onError]/the error handler in [_onMessage]).
  Future<void> _sendAuthFrame(String token) {
    final ack = (_authAck != null && !_authAck!.isCompleted)
        ? _authAck!
        : (_authAck = Completer<void>());
    _send({'action': 'auth', 'token': token});
    return ack.future.catchError((Object _) {});
  }

  void _sendSubscribe(_Subscription sub) {
    sub.inflight = true;
    final frame = <String, dynamic>{'action': 'subscribe', 'topic': sub.topic};
    if (sub.filter != null) frame['filter'] = sub.filter;
    _send(frame);
  }

  void _send(Map<String, dynamic> frame) {
    _channel?.sink.add(jsonEncode(frame));
  }

  void _onMessage(dynamic data) {
    Map<String, dynamic> frame;
    try {
      final decoded = jsonDecode(data as String);
      if (decoded is! Map<String, dynamic>) return;
      frame = decoded;
    } catch (_) {
      return;
    }
    switch (frame['type']) {
      case 'connect':
        final id = frame['clientId'];
        _clientId = id is String ? id : null;
        break;
      case 'auth':
        {
          // Detach before completing so a superseded frame's later response
          // (the completer is reused across back-to-back sends) finds a null
          // slot and is a no-op rather than a double-completion. A de-auth's
          // {"status":"error"} response is benign here: its future carries a
          // swallowing `catchError` (see [_sendAuthFrame]).
          final ack = _authAck;
          _authAck = null;
          if (ack != null && !ack.isCompleted) {
            if (frame['status'] == 'ok') {
              ack.complete();
            } else {
              ack.completeError(StateError('auth failed'));
            }
          }
        }
        break;
      case 'ack':
        _onAck(frame['topic'] as String?);
        break;
      case 'event':
        _onEvent(frame);
        break;
      case 'signal':
      case 'message':
        _onTopicFrame(frame);
        break;
      case 'error':
        final msg = frame['message'];
        _onErrorFrame(msg is String ? msg : 'realtime error');
        break;
    }
  }

  void _onAck(String? topic) {
    if (topic == null) return;
    for (final sub in _subscriptions.values) {
      if (sub.topic != topic) continue;
      sub.acked = true;
      sub.inflight = false;
      final pending = List<Completer<void>>.from(sub.pending);
      sub.pending.clear();
      for (final c in pending) {
        if (!c.isCompleted) c.complete();
      }
    }
  }

  void _onEvent(Map<String, dynamic> frame) {
    final topic = frame['topic'];
    if (topic is! String) return;
    final record = frame['record'];
    final event = RecordEvent(
      topic,
      frame['action'] as String? ?? '',
      ZbRecord(record is Map<String, dynamic> ? record : <String, dynamic>{}),
    );
    for (final sub in _subscriptions.values) {
      if (sub.kind == _Kind.records && sub.topic == topic) {
        for (final cb in sub.callbacks.toList()) {
          cb(event);
        }
      }
    }
  }

  void _onTopicFrame(Map<String, dynamic> frame) {
    final topic = frame['topic'];
    if (topic is! String) return; // malformed (missing topic) -> dropped
    final kind = frame['type'] as String;
    final msg = kind == 'message'
        ? TopicMessage(topic, kind, frame['data'])
        : TopicMessage(topic, kind, null);
    for (final sub in _subscriptions.values) {
      if (sub.kind != _Kind.topic || sub.topic != topic) continue;
      for (final cb in sub.topicCallbacks.toList()) {
        cb(msg);
      }
    }
  }

  void _onErrorFrame(String message) {
    // The server's error frame carries NO topic, so this rejects EVERY unacked
    // pending subscribe (pre-existing wire-protocol limitation: two subscribes
    // in flight when one fails are both rejected).
    // Reject any still-pending subscribe so the awaiting caller learns of it
    // (e.g. anonymous subscribe to a non-public collection), and DROP the
    // failed subscription entry entirely. It never acked, so no unsubscribe
    // frame is owed; leaving it in the map would silently re-subscribe it on
    // the next reconnect — a topic the caller was already told had failed. A
    // later subscribe() re-creates the entry and sends a fresh frame.
    final failedKeys = <String>[];
    for (final entry in _subscriptions.entries) {
      final sub = entry.value;
      if (sub.acked || sub.pending.isEmpty) continue;
      failedKeys.add(entry.key);
      final pending = List<Completer<void>>.from(sub.pending);
      sub.pending.clear();
      for (final c in pending) {
        if (!c.isCompleted) c.completeError(StateError(message));
      }
    }
    for (final key in failedKeys) {
      _subscriptions.remove(key);
    }
    onError?.call(message);
  }

  void _onClose() {
    _opened = false;
    _channel = null;
    _streamSub = null;
    if (_closedByUser || _subscriptions.isEmpty) return;
    _reconnect();
  }

  Future<void> _reconnect() async {
    // Mark the reconnect as pending for the whole backoff window so a subscribe
    // arriving mid-sleep defers to us (see [_ensureConnected]) instead of
    // opening a competing socket.
    _reconnectPending = true;
    try {
      final delay = _backoffDelay();
      _reconnectAttempts += 1;
      await _sleep(delay);
    } catch (e) {
      // A throwing injectable sleep must neither wedge [_reconnectPending]
      // (the finally below always clears it — a stuck flag would no-op
      // [_ensureConnected] forever) nor surface an unhandled async error
      // (call sites fire-and-forget this future). Surface it and treat the
      // backoff as elapsed — the reconnect itself still proceeds.
      onError?.call(e);
    } finally {
      _reconnectPending = false;
    }
    if (_closedByUser) return;
    _connect();
  }

  Duration _backoffDelay() {
    final minMs = minReconnect.inMilliseconds;
    final maxMs = maxReconnect.inMilliseconds;
    // 2^attempts, guarding against shift overflow for pathological attempt counts.
    final scaled =
        _reconnectAttempts >= 30 ? maxMs : minMs * (1 << _reconnectAttempts);
    return Duration(milliseconds: scaled < maxMs ? scaled : maxMs);
  }

  void _failPending(Object error) {
    for (final sub in _subscriptions.values) {
      final pending = List<Completer<void>>.from(sub.pending);
      sub.pending.clear();
      for (final c in pending) {
        if (!c.isCompleted) c.completeError(error);
      }
    }
  }

  bool _hasTopic(String topic) =>
      _subscriptions.values.any((s) => s.topic == topic);

  // ---- keys / url ---------------------------------------------------------

  // Record- and topic-subscription keys share one Map, so their key spaces must
  // be structurally disjoint: `r:`/`t:` prefixes guarantee no record key (however
  // adversarial the topic/filter text) can collide with a topic key.
  static String _subKey(String topic, String? filter) =>
      filter == null ? 'r:$topic' : 'r:$topic $filter';

  static String _topicKey(String topic) => 't:$topic';

  static Uri _wsUrl(String baseUrl) {
    var u = baseUrl;
    if (u.startsWith('http')) u = 'ws${u.substring(4)}'; // http->ws, https->wss
    u = u.replaceAll(RegExp(r'/+$'), '');
    return Uri.parse('$u/api/realtime');
  }
}
