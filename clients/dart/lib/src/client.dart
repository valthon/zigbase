/// [ZigbaseClient] — the top-level entry point consumers construct.
///
/// Assembles a [Transport] plus every service ([CollectionService] instances
/// cached per collection name, [FilesService], [AccountsService],
/// [AnalyticsService], [SendersService], and a lazily-created
/// [RealtimeService]) around one [AuthStore]. A byte-for-byte behavioral port
/// of `createClient` in `clients/typescript/src/client.ts`, adapted to Dart's
/// class-based (rather than closure-returning-object-literal) idiom.
library;

import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import 'accounts.dart';
import 'analytics.dart';
import 'auth_store.dart';
import 'collection.dart';
import 'files.dart';
import 'realtime.dart';
import 'senders.dart';
import 'transport.dart';

/// Fallback for [ZigbaseClient.realtime]'s [RealtimeService.onError] when
/// the client is not given an `onRealtimeError` callback.
///
/// A realtime `error` frame must never be silently dropped just because the
/// service was built by the facade — so rather than passing no callback at
/// all (the pre-existing behavior of the `realtime` getter), a client with
/// no `onRealtimeError` gets this visible default: a `dart:developer` log
/// entry (shows up in IDE/DevTools consoles), at the `WARNING` level (900)
/// `logging`-package convention.
///
/// Parity note (tracked follow-up): [RealtimeService] invokes `onError` for
/// EVERY server error frame — including one a pending subscribe already
/// consumed (rejected) — so this default logs those too. The TS SDK gates
/// its equivalent `console.warn` fallback on the error NOT having been
/// consumed by a pending subscribe (`!rejected`); matching that requires a
/// change in `realtime.dart`, which a concurrent branch owns.
void _defaultRealtimeErrorLog(Object error) {
  developer.log('Unhandled realtime error: $error',
      name: 'zigbase.realtime', level: 900);
}

/// The official ZigBase Dart client.
///
/// ```dart
/// final client = ZigbaseClient('http://127.0.0.1:8090',
///     autoRefresh: true, authCollection: 'users');
/// await client.collection('users').authWithPassword('a@b.com', 'secret');
/// final posts = await client.collection('posts').getList();
/// ```
///
/// ### Ownership & [close]
///
/// A client constructed with the public constructor **owns** its
/// [http.Client] (whether it built the default one or was handed one by the
/// caller) and, when the caller did not supply an [AuthStore], its
/// [authStore] too. [close] tears down exactly the resources this instance
/// owns:
///
///  - the [RealtimeService], if [realtime] was ever accessed;
///  - the underlying [http.Client] (via the [Transport]);
///  - the [AuthStore], via [AuthStore.dispose] — **only** when this client
///    created the default [MemoryAuthStore]; a caller-supplied store is left
///    alone (the caller may be sharing it elsewhere and owns its lifecycle).
///
/// [close] is idempotent, and a closed client is **terminal**: every accessor
/// ([collection], the service getters including [realtime], [send],
/// [rawRequest], and [withAccount]) throws [StateError] afterwards. This is
/// what makes the teardown promise airtight — nothing can lazily mint a new
/// service (in particular a new [RealtimeService] with its
/// [AuthStore.onChange] listener) after the one-and-only teardown has run.
///
/// [withAccount] returns a **sibling**: a second [ZigbaseClient] that shares
/// this client's [authStore] and [http.Client] (so a login/logout on either
/// is visible to both) but sends `X-Account-Id: <accountId>` on every
/// request. A sibling's [close] is deliberately narrower — it closes only its
/// own [RealtimeService] (if created) and never the shared [http.Client] or
/// [authStore], since those are owned by the parent. **Closing the parent
/// invalidates every sibling** (their shared [http.Client] stops working);
/// siblings do not need to be closed individually unless they created their
/// own [RealtimeService], but calling [close] on one is always safe (it is
/// idempotent and a no-op on the shared resources).
class ZigbaseClient {
  /// The normalized base URL (no trailing slash).
  final String baseUrl;

  /// The auth store backing every service built from this client.
  final AuthStore authStore;

  final http.Client _httpClient;
  final WebSocketConnector? _webSocketConnector;
  final bool _ownsAuthStore;
  final bool _isSibling;
  final bool _autoRefresh;
  final String? _authCollection;
  final String? _lang;
  final int _maxRetries;
  final void Function(Object error)? _onRealtimeError;
  late final Transport _transport;

  final Map<String, CollectionService> _collections = {};
  FilesService? _filesService;
  AccountsService? _accountsService;
  AnalyticsService? _analyticsService;
  SendersService? _sendersService;
  RealtimeService? _realtimeService;
  bool _closed = false;

  ZigbaseClient(
    String baseUrl, {
    AuthStore? authStore,
    bool autoRefresh = false,
    String? authCollection,
    String? accountId,
    String? lang,
    int maxRetries = 3,
    http.Client? httpClient,
    WebSocketConnector? webSocketConnector,
    void Function(Object error)? onRealtimeError,
  })  : baseUrl = _normalize(baseUrl),
        authStore = authStore ?? MemoryAuthStore(),
        _httpClient = httpClient ?? http.Client(),
        _webSocketConnector = webSocketConnector,
        _ownsAuthStore = authStore == null,
        _isSibling = false,
        _autoRefresh = autoRefresh,
        _authCollection = authCollection,
        _lang = lang,
        _maxRetries = maxRetries,
        _onRealtimeError = onRealtimeError {
    _transport = Transport(
      baseUrl: this.baseUrl,
      authStore: this.authStore,
      httpClient: _httpClient,
      autoRefresh: autoRefresh,
      maxRetries: maxRetries,
      lang: lang,
      accountId: accountId,
    );
    _wireAuthRefresh(authCollection);
  }

  /// Internal constructor for [withAccount] siblings: reuses the parent's
  /// [authStore]/[http.Client]/[WebSocketConnector] verbatim and builds a
  /// fresh [Transport] scoped to [accountId].
  ZigbaseClient._sibling({
    required this.baseUrl,
    required this.authStore,
    required http.Client httpClient,
    required WebSocketConnector? webSocketConnector,
    required bool autoRefresh,
    required String? authCollection,
    required String? accountId,
    required String? lang,
    required int maxRetries,
    required void Function(Object error)? onRealtimeError,
  })  : _httpClient = httpClient,
        _webSocketConnector = webSocketConnector,
        _ownsAuthStore = false,
        _isSibling = true,
        _autoRefresh = autoRefresh,
        _authCollection = authCollection,
        _lang = lang,
        _maxRetries = maxRetries,
        _onRealtimeError = onRealtimeError {
    _transport = Transport(
      baseUrl: baseUrl,
      authStore: authStore,
      httpClient: _httpClient,
      autoRefresh: autoRefresh,
      maxRetries: maxRetries,
      lang: lang,
      accountId: accountId,
    );
    _wireAuthRefresh(authCollection);
  }

  /// Wires `transport.refresh` to `collection(authCollection).authRefresh()`
  /// when [authCollection] is given. The closure captures `this` (not the
  /// not-yet-built [_transport]), so it is safe to install before the
  /// constructor body finishes — it is only invoked later, on a live 401.
  ///
  /// Note: `authRefresh()` posts with `skipAuth: false` (it must send the
  /// current — possibly near-expiry but not yet cleared — token so the
  /// server knows which session to refresh). That nested request goes
  /// through this same [Transport], which means it is itself eligible for
  /// exactly one nested auto-refresh attempt if `/auth-refresh` answers 401.
  /// This mirrors `clients/typescript/src/transport.ts` exactly (same
  /// per-call `didRefresh` scoping) — a persistently-401ing refresh endpoint
  /// recurses in both SDKs alike; it is not a regression introduced here.
  /// The common, correctly-configured case (refresh succeeds) makes exactly
  /// one nested call, verified by the `autoRefresh + authCollection` test.
  void _wireAuthRefresh(String? authCollection) {
    if (authCollection == null) return;
    _transport.refresh = () async {
      await collection(authCollection).authRefresh();
    };
  }

  static String _normalize(String url) => url.replaceAll(RegExp(r'/+$'), '');

  /// Hard gate on every accessor: once [close] has run, using this client is
  /// a programming error surfaced as a clear SDK-level [StateError] rather
  /// than a confusing downstream failure — a raw "http.Client is closed"
  /// error, a silently doomed [withAccount] sibling, or (worst) a freshly
  /// minted [RealtimeService] that the already-run, idempotent [close] would
  /// never tear down.
  void _checkNotClosed() {
    if (_closed) throw StateError('ZigbaseClient has been closed');
  }

  /// Returns the [CollectionService] for [name], creating and caching it on
  /// first access — repeated calls with the same [name] return the identical
  /// instance. Throws [StateError] after [close].
  CollectionService collection(String name) {
    _checkNotClosed();
    return _collections.putIfAbsent(
        name, () => CollectionService(_transport, authStore, name));
  }

  /// Lazily-created, cached [FilesService]. Throws [StateError] after
  /// [close].
  FilesService get files {
    _checkNotClosed();
    return _filesService ??= FilesService(_transport, baseUrl);
  }

  /// Lazily-created, cached [AccountsService]. Throws [StateError] after
  /// [close].
  AccountsService get accounts {
    _checkNotClosed();
    return _accountsService ??= AccountsService(_transport);
  }

  /// Lazily-created, cached [AnalyticsService]. Throws [StateError] after
  /// [close].
  AnalyticsService get analytics {
    _checkNotClosed();
    return _analyticsService ??= AnalyticsService(_transport);
  }

  /// Lazily-created, cached [SendersService]. Throws [StateError] after
  /// [close].
  SendersService get senders {
    _checkNotClosed();
    return _sendersService ??= SendersService(_transport);
  }

  /// Lazily-created, cached [RealtimeService]. The socket is not opened until
  /// the first [RealtimeService.subscribe]/[RealtimeService.subscribeTopic]
  /// call; accessing this getter alone does not connect. Throws [StateError]
  /// after [close] (which is what guarantees [close] tears down every
  /// [RealtimeService] this client ever creates).
  ///
  /// The service's [RealtimeService.onError] is the constructor's
  /// `onRealtimeError`, or (when omitted) a private `dart:developer`-logging
  /// default — so a realtime error is never silently dropped just because
  /// this getter, rather than direct [RealtimeService] construction, built
  /// it. Either way the callback fires for **every** server error frame,
  /// including one also delivered to (and rejecting) a pending
  /// [RealtimeService.subscribe] call.
  RealtimeService get realtime {
    _checkNotClosed();
    return _realtimeService ??= RealtimeService(
      baseUrl: baseUrl,
      authStore: authStore,
      connector: _webSocketConnector,
      onError: _onRealtimeError ?? _defaultRealtimeErrorLog,
    );
  }

  /// Issues a request through the shared [Transport] and returns its parsed
  /// JSON body (or `null` for a 204/empty body). Non-2xx responses throw a
  /// `ZigbaseException`; subject to the same 401 auto-refresh / 429 backoff
  /// as every service call (they all go through this same transport). Throws
  /// [StateError] after [close].
  Future<dynamic> send(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    Map<String, String>? headers,
    String? requestKey,
  }) {
    _checkNotClosed();
    return _transport.send(
      path,
      method: method,
      query: query,
      body: body,
      headers: headers,
      requestKey: requestKey,
    );
  }

  /// Raw escape hatch: returns the [http.Response] as-is — no JSON parse, no
  /// error mapping, no 401 refresh, no 429 retry. Use for binary/text bodies
  /// or custom status handling. Throws [StateError] after [close].
  Future<http.Response> rawRequest(
    String method,
    String path, {
    Map<String, dynamic>? query,
    Object? body,
    Map<String, String>? headers,
  }) {
    _checkNotClosed();
    return _transport.raw(
      path,
      method: method,
      query: query,
      body: body,
      headers: headers,
    );
  }

  /// Returns a sibling client scoped to [accountId]: same [authStore] (a
  /// login/logout on either client is visible to both) and same underlying
  /// [http.Client]/[WebSocketConnector] and other config (`autoRefresh`,
  /// `authCollection`, `lang`, `maxRetries`) as this client, but its own
  /// [Transport] sending `X-Account-Id: <accountId>` on every request. See
  /// the class doc for the [close] ownership implications. Throws
  /// [StateError] after [close] (a sibling minted from a closed parent could
  /// never work — its shared [http.Client] is already closed).
  ZigbaseClient withAccount(String accountId) {
    _checkNotClosed();
    return ZigbaseClient._sibling(
      baseUrl: baseUrl,
      authStore: authStore,
      httpClient: _httpClient,
      webSocketConnector: _webSocketConnector,
      autoRefresh: _autoRefresh,
      authCollection: _authCollection,
      accountId: accountId,
      lang: _lang,
      maxRetries: _maxRetries,
      onRealtimeError: _onRealtimeError,
    );
  }

  /// Idempotent teardown. See the class doc for exactly what a parent vs. a
  /// [withAccount] sibling closes.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_realtimeService != null) await _realtimeService!.close();
    // A sibling shares the parent's http.Client; only the parent closes it.
    if (!_isSibling) _transport.close();
    if (_ownsAuthStore) authStore.dispose();
  }
}
