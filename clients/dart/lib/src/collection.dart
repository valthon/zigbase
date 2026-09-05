/// Per-collection API surface: auth, record CRUD, and cursor pagination.
///
/// This is a byte-for-byte behavioral port of `CollectionService` in
/// `clients/typescript/src/collection.ts` — every endpoint, request body,
/// `skipAuth` flag, and auth-store side effect below mirrors that file
/// exactly (see the comment on each method for the TS counterpart). Wire
/// field names that differ from Dart's camelCase convention (the server's
/// `authURL`, and the session-list endpoint's deliberately snake_case
/// `last_seen`/`user_agent`/`is_current`) are documented where parsed.
library;

import 'auth_store.dart';
import 'cursor.dart';
import 'errors.dart';
import 'query.dart';
import 'records.dart';
import 'transport.dart';

/// Response shape from the password/refresh auth endpoints.
class TwoFactorRequiredException implements Exception {
  final Map<String, dynamic> pending;
  TwoFactorRequiredException(this.pending);
  @override
  String toString() => 'Second factor required.';
}

class AuthResponse {
  final String token;
  final ZbRecord? record;
  final Map<String, dynamic>? meta;

  AuthResponse({required this.token, this.record, this.meta});

  factory AuthResponse.fromJson(Map<String, dynamic> json) {
    final rawRecord = json['record'];
    return AuthResponse(
      token: json['token'] as String,
      record: rawRecord is Map<String, dynamic> ? ZbRecord(rawRecord) : null,
      meta: json['meta'] as Map<String, dynamic>?,
    );
  }
}

/// One configured OAuth2 provider, as returned by `listAuthProviders`. The
/// wire key for [authUrl] is the server's `authURL` (see `src/api/oauth.zig`).
class OAuth2Provider {
  final String name;
  final String? authUrl;
  final String? clientId;
  final List<String>? scopes;

  OAuth2Provider(
      {required this.name, this.authUrl, this.clientId, this.scopes});

  factory OAuth2Provider.fromJson(Map<String, dynamic> json) {
    return OAuth2Provider(
      name: json['name'] as String,
      authUrl: json['authURL'] as String?,
      clientId: json['clientId'] as String?,
      scopes: (json['scopes'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(growable: false),
    );
  }
}

/// Response shape from `POST /auth/oauth2/initiate`.
class OAuth2InitResponse {
  final String? authUrl;
  final String? clientId;
  final List<String>? scopes;

  /// OAuth2 CSRF state — present when the server included state in the
  /// initiate response (`app.oauth_state_server`).
  final String? state;

  OAuth2InitResponse({this.authUrl, this.clientId, this.scopes, this.state});

  factory OAuth2InitResponse.fromJson(Map<String, dynamic> json) {
    return OAuth2InitResponse(
      authUrl: json['authURL'] as String?,
      clientId: json['clientId'] as String?,
      scopes: (json['scopes'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList(growable: false),
      state: json['state'] as String?,
    );
  }
}

/// One active server-side session row (server `.auth.session.store = .table`
/// only). The wire keys are deliberately snake_case (`src/api/sessions.zig`)
/// even though the rest of the API is camelCase; mapped here to Dart-idiomatic
/// field names.
class SessionInfo {
  final String id;
  final String created;
  final String lastSeen;
  final String userAgent;
  final String ip;

  /// `true` for the session THIS request was authenticated with.
  final bool isCurrent;

  SessionInfo({
    required this.id,
    required this.created,
    required this.lastSeen,
    required this.userAgent,
    required this.ip,
    required this.isCurrent,
  });

  factory SessionInfo.fromJson(Map<String, dynamic> json) {
    return SessionInfo(
      id: json['id'] as String,
      created: json['created'] as String,
      lastSeen: json['last_seen'] as String,
      userAgent: json['user_agent'] as String,
      ip: json['ip'] as String,
      isCurrent: json['is_current'] as bool? ?? false,
    );
  }
}

/// The actions the current principal may perform on a specific record (#155).
class RecordAbilities {
  final bool view;
  final bool update;
  final bool delete;

  RecordAbilities(
      {required this.view, required this.update, required this.delete});

  factory RecordAbilities.fromJson(Map<String, dynamic> json) {
    return RecordAbilities(
      view: json['view'] as bool? ?? false,
      update: json['update'] as bool? ?? false,
      delete: json['delete'] as bool? ?? false,
    );
  }
}

/// Per-collection auth + record CRUD + cursor pagination API.
///
/// One instance is bound to a single collection [name]; `ZigbaseClient`
/// (Task 10) hands out cached instances keyed by name.
class CollectionService {
  final Transport _transport;
  final AuthStore _authStore;
  final String name;

  CollectionService(this._transport, this._authStore, this.name);

  String _base() => '/api/collections/${Uri.encodeComponent(name)}';

  String _recordsBase() => '${_base()}/records';

  Map<String, dynamic> _asMap(dynamic v) => v as Map<String, dynamic>;

  void _rejectPending(Map<String, dynamic> body) {
    if (body['pendingToken'] is String &&
        (body['status'] == 'factor_required' ||
            body['status'] == 'enrollment_required')) {
      _authStore.clear();
      throw TwoFactorRequiredException(body);
    }
  }

  /// Two-factor ceremony or management action. Pending capabilities stay out of the auth store.
  Future<Map<String, dynamic>?> secondFactor(
      String action, Map<String, dynamic> body) async {
    final result = await _transport.send(
        '${_base()}/auth/two-factor/${Uri.encodeComponent(action)}',
        method: 'POST',
        body: body,
        skipAuth: action != 'enroll');
    if (result == null) {
      if (action == 'remove') _authStore.clear();
      return null;
    }
    final out = _asMap(result);
    if (out['token'] is String) {
      final auth = AuthResponse.fromJson(out);
      _authStore.save(auth.token, auth.record?.data);
    }
    if (out['reauthenticate'] == true) _authStore.clear();
    return out;
  }

  // ---------------------------------------------------------------------
  // Auth
  // ---------------------------------------------------------------------

  Future<AuthResponse> _authRequest(String path, Map<String, dynamic> body,
      {required bool skipAuth}) async {
    // The refresh request must carry the bearer header (so no skipAuth) but is
    // exempt from the transport's single-flight 401-refresh branch: a 401 here
    // propagates instead of awaiting/starting a refresh (self-await deadlock /
    // unbounded recursion otherwise).
    final res = await _transport.send('${_base()}$path',
        method: 'POST',
        body: body,
        skipAuth: skipAuth,
        isRefreshCall: path == '/auth-refresh');
    _rejectPending(_asMap(res));
    final auth = AuthResponse.fromJson(_asMap(res));
    _authStore.save(auth.token, auth.record?.data);
    return auth;
  }

  /// `POST /auth-with-password` with `{identity, password}`, `skipAuth: true`.
  Future<AuthResponse> authWithPassword(String identity, String password) {
    return _authRequest(
        '/auth-with-password', {'identity': identity, 'password': password},
        skipAuth: true);
  }

  /// `POST /auth-refresh`.
  Future<AuthResponse> authRefresh() {
    return _authRequest('/auth-refresh', const {}, skipAuth: false);
  }

  /// `POST /auth/oauth2/complete`, `skipAuth: true`. The endpoint sets
  /// `zb_auth`/`zb_csrf` cookies directly and does not return a record;
  /// only the token is stored/returned.
  Future<String> authWithOAuth2({
    required String provider,
    required String code,
    required String codeVerifier,
    required String redirectUrl,
    String? state,
  }) async {
    final body = <String, dynamic>{
      'provider': provider,
      'code': code,
      'codeVerifier': codeVerifier,
      'redirectUrl': redirectUrl,
      if (state != null) 'state': state,
    };
    final res = await _transport.send('${_base()}/auth/oauth2/complete',
        method: 'POST', body: body, skipAuth: true);
    _rejectPending(_asMap(res));
    final token = _asMap(res)['token'] as String;
    _authStore.save(token, null);
    return token;
  }

  /// `POST /auth/oauth2/initiate` with `{provider}`.
  Future<OAuth2InitResponse> oauth2Init(String provider) async {
    final res = await _transport.send('${_base()}/auth/oauth2/initiate',
        method: 'POST', body: {'provider': provider});
    return OAuth2InitResponse.fromJson(_asMap(res));
  }

  /// `GET /auth/oauth2/providers` — unwraps the `{items}` envelope.
  Future<List<OAuth2Provider>> listAuthProviders() async {
    final res = await _transport.send('${_base()}/auth/oauth2/providers');
    final items = _asMap(res)['items'] as List<dynamic>? ?? const [];
    return items
        .map((e) => OAuth2Provider.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// `POST /auth-logout`. Clears the auth store even when the request fails.
  Future<void> logout() async {
    try {
      await _transport.send('${_base()}/auth-logout', method: 'POST');
    } finally {
      _authStore.clear();
    }
  }

  /// `POST /request-verification` with `{email}`.
  Future<void> requestVerification(String email) async {
    await _transport.send('${_base()}/request-verification',
        method: 'POST', body: {'email': email});
  }

  /// `POST /confirm-verification` with `{token}`, `skipAuth: true`.
  Future<void> confirmVerification(String token) async {
    await _transport.send('${_base()}/confirm-verification',
        method: 'POST', body: {'token': token}, skipAuth: true);
  }

  /// `POST /request-password-reset` with `{email}`.
  Future<void> requestPasswordReset(String email) async {
    await _transport.send('${_base()}/request-password-reset',
        method: 'POST', body: {'email': email});
  }

  /// `POST /confirm-password-reset` with `{token, password}`, `skipAuth: true`.
  Future<void> confirmPasswordReset(String token, String password) async {
    await _transport.send(
      '${_base()}/confirm-password-reset',
      method: 'POST',
      body: {'token': token, 'password': password},
      skipAuth: true,
    );
  }

  /// `PATCH /records/:id` with `{password, oldPassword}` (requires ZigBase
  /// >= 0.10.0; the server verifies `oldPassword` against the TARGET record
  /// and rotates its tokenKey). Mirrors `collection.ts`'s `changePassword`:
  /// when the auth store's current principal IS the target record, this
  /// additionally re-runs [authWithPassword] with the stored identity
  /// (`email`, falling back to `username` — see `collection.ts:171-175`) and
  /// the new password, so bearer-token clients stay logged in too. Returns
  /// the updated record.
  Future<ZbRecord> changePassword(
      String id, String oldPassword, String newPassword) async {
    final rec =
        await update(id, {'password': newPassword, 'oldPassword': oldPassword});
    final principal = _authStore.record;
    final identity = (principal?['email'] ?? principal?['username']) as String?;
    if (principal != null && principal['id'] == id && identity != null) {
      await authWithPassword(identity, newPassword);
    }
    return rec;
  }

  /// `GET /auth/sessions` — the caller's active sessions, newest first
  /// (requires `.auth.session.store = .table`; `.epoch` mode answers 404).
  Future<List<SessionInfo>> listSessions() async {
    final res = await _transport.send('${_base()}/auth/sessions');
    final items = _asMap(res)['items'] as List<dynamic>? ?? const [];
    return items
        .map((e) => SessionInfo.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// `DELETE /auth/sessions/:id` — "log out THIS device" (table mode only).
  Future<void> revokeSession(String sessionId) async {
    await _transport.send(
        '${_base()}/auth/sessions/${Uri.encodeComponent(sessionId)}',
        method: 'DELETE');
  }

  /// `DELETE /auth/sessions` — "log out everywhere". Clears the auth store
  /// even when the request fails (parity with [logout]).
  Future<void> revokeAllSessions() async {
    try {
      await _transport.send('${_base()}/auth/sessions', method: 'DELETE');
    } finally {
      _authStore.clear();
    }
  }

  // ---------------------------------------------------------------------
  // Records (offset pagination)
  // ---------------------------------------------------------------------

  /// `GET /records`. `perPage` is clamped to `[1, 500]`.
  Future<ListResult> getList({
    int page = 1,
    int perPage = 30,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
    bool skipTotal = false,
    String? search,
    VectorQuery? vector,
    String? requestKey,
  }) async {
    final clampedPerPage = perPage < 1 ? 1 : (perPage > 500 ? 500 : perPage);
    final res = await _transport.send(
      _recordsBase(),
      query: {
        'page': page,
        'perPage': clampedPerPage,
        'filter': filter,
        'sort': sort,
        'expand': expand,
        'fields': fields,
        'skipTotal': skipTotal ? 1 : null,
        'search': search,
        'vector': vector?.spec(),
      },
      requestKey: requestKey,
    );
    return ListResult.fromJson(_asMap(res));
  }

  /// `GET /records/:id`.
  Future<ZbRecord> getOne(String id,
      {String? expand, String? fields, String? requestKey}) async {
    final res = await _transport.send(
      '${_recordsBase()}/${Uri.encodeComponent(id)}',
      query: {'expand': expand, 'fields': fields},
      requestKey: requestKey,
    );
    return ZbRecord(_asMap(res));
  }

  /// `getList(perPage: 1, skipTotal: true)` sugar. Throws a synthesized 404
  /// [ZigbaseException] when nothing matches.
  Future<ZbRecord> getFirstListItem(
    String filter, {
    String? expand,
    String? fields,
    String? requestKey,
  }) async {
    final list = await getList(
      page: 1,
      perPage: 1,
      filter: filter,
      skipTotal: true,
      expand: expand,
      fields: fields,
      requestKey: requestKey,
    );
    if (list.items.isEmpty) {
      throw ZigbaseException(
        status: 404,
        message: 'No record found matching the filter.',
        url: _recordsBase(),
      );
    }
    return list.items.first;
  }

  /// `POST /records`. Auto-switches to multipart when [body] contains an
  /// `http.MultipartFile` (handled transparently by [Transport]).
  ///
  /// An `http.MultipartFile` is single-use (`package:http` finalizes its
  /// byte stream once); construct a fresh one for each [create]/[update]
  /// call rather than reusing an instance across two calls, which throws a
  /// `StateError`.
  Future<ZbRecord> create(
    Map<String, dynamic> body, {
    String? expand,
    String? fields,
    String? requestKey,
  }) async {
    final res = await _transport.send(
      _recordsBase(),
      method: 'POST',
      body: body,
      query: {'expand': expand, 'fields': fields},
      requestKey: requestKey,
    );
    return ZbRecord(_asMap(res));
  }

  /// `PATCH /records/:id`. Auto-switches to multipart when [body] contains
  /// an `http.MultipartFile`.
  ///
  /// See the single-use caveat on [create] — build a new `MultipartFile` per
  /// call.
  Future<ZbRecord> update(
    String id,
    Map<String, dynamic> body, {
    String? expand,
    String? fields,
    String? requestKey,
  }) async {
    final res = await _transport.send(
      '${_recordsBase()}/${Uri.encodeComponent(id)}',
      method: 'PATCH',
      body: body,
      query: {'expand': expand, 'fields': fields},
      requestKey: requestKey,
    );
    return ZbRecord(_asMap(res));
  }

  /// `DELETE /records/:id`.
  Future<void> delete(String id) async {
    await _transport.send('${_recordsBase()}/${Uri.encodeComponent(id)}',
        method: 'DELETE');
  }

  /// `GET /records/:id/abilities` (requires ZigBase >= 0.9.0).
  Future<RecordAbilities> getAbilities(String id) async {
    final res = await _transport
        .send('${_recordsBase()}/${Uri.encodeComponent(id)}/abilities');
    return RecordAbilities.fromJson(_asMap(res));
  }

  // ---------------------------------------------------------------------
  // Cursor (keyset) pagination
  // ---------------------------------------------------------------------

  /// Native server-side cursor pagination. The server mints the opaque
  /// `nextCursor`/`prevCursor` tokens; [cursor] is forwarded verbatim and
  /// never decoded or synthesized. Omitting [cursor] requests the first
  /// page. The server skips the total count by default; pass
  /// `withTotal: true` to include `totalItems`.
  Future<CursorPage> getPage({
    String? cursor,
    int limit = 30,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
    bool withTotal = false,
    String? search,
    String? requestKey,
  }) async {
    final res = await _transport.send(
      _recordsBase(),
      query: {
        'limit': limit,
        'cursor': (cursor != null && cursor.isNotEmpty) ? cursor : null,
        'skipTotal': withTotal ? 'false' : null,
        'filter': filter,
        'sort': sort,
        'expand': expand,
        'fields': fields,
        'search': search,
      },
      requestKey: requestKey,
    );
    return CursorPage.fromJson(_asMap(res));
  }

  /// Async-iterates every matching record, following the server's
  /// `nextCursor` until a page reports `hasNext: false` (or an empty
  /// `nextCursor`).
  Stream<ZbRecord> iterate({
    int batch = 100,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
    String? search,
  }) async* {
    String? usedCursor;
    var page = await getPage(
      limit: batch,
      filter: filter,
      sort: sort,
      expand: expand,
      fields: fields,
      search: search,
    );
    for (;;) {
      for (final item in page.items) {
        yield item;
      }
      final next = page.nextCursor;
      if (!page.hasNext || next == null || next.isEmpty) return;
      // Guard against a misbehaving server that cannot make progress: a page
      // that still claims `hasNext` but carries no items, or a `nextCursor`
      // identical to the one we just used, would loop forever. Fail loudly
      // rather than spin.
      if (page.items.isEmpty || next == usedCursor) {
        throw ZigbaseException(
          status: 0,
          message: 'iterate(): the server returned a non-advancing cursor page '
              '(empty page or a repeated cursor); aborting to avoid an '
              'infinite loop.',
          url: _recordsBase(),
        );
      }
      usedCursor = next;
      page = await getPage(
        cursor: next,
        limit: batch,
        filter: filter,
        sort: sort,
        expand: expand,
        fields: fields,
        search: search,
      );
    }
  }

  /// Accumulates every matching record into a list via the native cursor
  /// engine.
  Future<List<ZbRecord>> getFullList({
    int batch = 100,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
    String? search,
  }) async {
    final out = <ZbRecord>[];
    await for (final item in iterate(
      batch: batch,
      filter: filter,
      sort: sort,
      expand: expand,
      fields: fields,
      search: search,
    )) {
      out.add(item);
    }
    return out;
  }
}
