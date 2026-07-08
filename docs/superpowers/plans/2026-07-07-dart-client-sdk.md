# Dart Client SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `clients/dart/` — pub package `zigbase_client` 0.1.0, a feature-parity port of the base tier of `@zigbase/client` (REST + auth + files + cursor pagination + realtime WebSocket), with unit + integration tests, CI job, and synced docs.

**Architecture:** One Dart package. `Transport` (HTTP engine over `package:http`) is the linchpin; `CollectionService` carries per-collection auth + CRUD + cursor pagination; `RealtimeService` speaks the server's JSON frame protocol over `web_socket_channel`. Records are dynamic (`ZbRecord` wrapping `Map<String, dynamic>`).

**Tech Stack:** Dart 3.12 (via mise), `http` ^1.2, `web_socket_channel` ^3.0, `crypto` ^3.0, `stream_channel` (test + realtime injection), dev: `test`, `lints`.

**Normative reference:** The TypeScript SDK at `clients/typescript/src/` is the authoritative behavior spec. Where a task says "port `X.ts`", read that file and reproduce its behavior exactly (endpoints, query params, edge cases), adapted to the Dart signatures given in the task's **Interfaces** block. The design spec is `docs/superpowers/specs/2026-07-07-dart-client-sdk-design.md`.

## Global Constraints

- Package name `zigbase_client`, version `0.1.0`, path `clients/dart/`.
- Dart pinned via mise: run everything as `mise exec dart@3.12 -- dart <cmd>` from `clients/dart/`.
- No Flutter dependency. Runtime deps limited to `http`, `web_socket_channel`, `crypto`, `stream_channel`.
- All server paths root at `<baseUrl>/api/...`. Auth header: `Authorization: Bearer <token>`.
- Every list-envelope from the server is `{items: [...]}` (house convention); side-effect success is 204.
- `dart analyze --fatal-infos` and `dart format --output=none --set-exit-if-changed .` must pass at every commit.
- Commit after every task with a `feat(dart-sdk): ...` / `test(dart-sdk): ...` message ending in the Claude co-author trailer.
- Public API symbols exactly as specified in **Interfaces** blocks — later tasks depend on the exact names.

---

### Task 1: Package scaffold + toolchain

**Files:**
- Create: `clients/dart/pubspec.yaml`, `clients/dart/analysis_options.yaml`, `clients/dart/lib/zigbase_client.dart`, `clients/dart/lib/src/version.dart`, `clients/dart/test/smoke_test.dart`, `clients/dart/.gitignore`, `clients/dart/LICENSE` (copy `clients/typescript/LICENSE`)
- Modify: `mise.toml` (add `dart = "3.12"` to `[tools]`)

**Interfaces:**
- Produces: `const String zigbaseClientVersion = '0.1.0';` in `lib/src/version.dart`, exported from `lib/zigbase_client.dart`.

- [ ] **Step 1: Add dart to mise and install**

Append `dart = "3.12"` to the `[tools]` section of `mise.toml`, then run `mise install dart@3.12` (from repo root). Expected: dart 3.12.x installs.

- [ ] **Step 2: Write scaffold files**

`clients/dart/pubspec.yaml`:
```yaml
name: zigbase_client
description: Official Dart client for ZigBase — REST, auth, cursor pagination, files, and realtime.
version: 0.1.0
repository: https://github.com/valthon/zigbase
environment:
  sdk: ^3.5.0
dependencies:
  crypto: ^3.0.3
  http: ^1.2.0
  stream_channel: ^2.1.2
  web_socket_channel: ^3.0.0
dev_dependencies:
  lints: ^5.0.0
  test: ^1.25.0
```

`clients/dart/analysis_options.yaml`:
```yaml
include: package:lints/recommended.yaml
analyzer:
  language:
    strict-casts: true
    strict-inference: true
    strict-raw-types: true
```

`clients/dart/.gitignore`: `.dart_tool/` and `pubspec.lock` (library package convention).

`lib/src/version.dart`: `const String zigbaseClientVersion = '0.1.0';`
`lib/zigbase_client.dart`: library doc comment + `export 'src/version.dart';`
`test/smoke_test.dart`:
```dart
import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

void main() {
  test('exports version', () => expect(zigbaseClientVersion, '0.1.0'));
}
```

- [ ] **Step 3: Verify**

From `clients/dart/`: `mise exec dart@3.12 -- dart pub get && mise exec dart@3.12 -- dart analyze --fatal-infos && mise exec dart@3.12 -- dart test`. Expected: PASS.

- [ ] **Step 4: Commit** (`feat(dart-sdk): scaffold zigbase_client package`)

---

### Task 2: Errors + JWT utilities

**Files:**
- Create: `lib/src/errors.dart`, `lib/src/jwt.dart`, `test/errors_test.dart`, `test/jwt_test.dart`
- Modify: `lib/zigbase_client.dart` (add exports)

**Interfaces (Produces):**
```dart
// errors.dart
class FieldError { final String code; final String message; const FieldError(this.code, this.message); }
class ZigbaseException implements Exception {
  final int status; final String message; final Map<String, FieldError> data; final String url;
  ZigbaseException({required this.status, required this.message, this.data = const {}, required this.url});
  @override String toString(); // 'ZigbaseException($status): $message ($url)'
}
class ZigbaseCancelledException implements Exception { final String message; }
/// Builds a ZigbaseException from a response body (may be non-JSON).
ZigbaseException parseErrorResponse(int status, String bodyText, String url, {String? reasonPhrase});
// jwt.dart
Map<String, dynamic>? decodeJwtPayload(String token); // null on any malformed input
bool isTokenExpired(String token, {int leewaySeconds = 0}); // true when no exp or exp-leeway <= now
```

Port of `clients/typescript/src/errors.ts` and `jwt.ts`. `parseErrorResponse` parses `{message?, data?}` where `data` is `{field: {code, message}}`; on non-JSON body fall back to `reasonPhrase`, then `'Request failed with status $status'`. `decodeJwtPayload` base64url-decodes segment 1 (add `=` padding; UTF-8 decode).

- [ ] **Step 1: Write failing tests** — cases: valid error JSON with field data; non-JSON body falls back to reasonPhrase then generic; `decodeJwtPayload` on a hand-built token (`base64Url.encode(utf8.encode('{"id":"u1","exp":9999999999}'))` glued with dots) returns the map; malformed → null; `isTokenExpired` false for far-future exp, true for past exp, true for missing exp, leeway respected.
- [ ] **Step 2: Run, verify FAIL** (`mise exec dart@3.12 -- dart test test/errors_test.dart test/jwt_test.dart`)
- [ ] **Step 3: Implement both modules; export from `zigbase_client.dart`**
- [ ] **Step 4: Run tests + analyze, verify PASS**
- [ ] **Step 5: Commit** (`feat(dart-sdk): error model and jwt utilities`)

---

### Task 3: Auth stores

**Files:**
- Create: `lib/src/auth_store.dart`, `test/auth_store_test.dart`
- Modify: `lib/zigbase_client.dart`

**Interfaces (Produces):**
```dart
class AuthEvent { final String? token; final Map<String, dynamic>? record; }
abstract class AuthStore {
  String? get token;
  Map<String, dynamic>? get record;
  bool get isValid; // token != null && !isTokenExpired(token)
  void save(String token, Map<String, dynamic>? record);
  void clear();
  Stream<AuthEvent> get onChange; // broadcast; emits after save/clear
  void dispose(); // closes the stream controller
}
class MemoryAuthStore extends AuthStore { MemoryAuthStore(); }
class AsyncAuthStore extends AuthStore {
  /// Persists '{"token":...,"record":...}' JSON via [save] on every change,
  /// calls [clear] (or save('')) on clear, rehydrates from [initial].
  AsyncAuthStore({required Future<void> Function(String data) save,
                  Future<void> Function()? clear, String? initial});
}
```

Port of `auth-store.ts` (Memory/Base) with `AsyncAuthStore` following the PocketBase-Dart pattern (callback persistence so Flutter apps plug `shared_preferences` without an SDK Flutter dep). Persistence calls are fire-and-forget awaited internally in order (chain futures so writes don't interleave).

- [ ] **Step 1: Failing tests** — save→token/record/isValid (use a far-future hand-built JWT); clear resets; onChange emits on save and clear (use `expectLater` with `emitsInOrder`); AsyncAuthStore rehydrates from `initial` JSON, calls save callback with serialized JSON on save, clear callback on clear; invalid `initial` ignored.
- [ ] **Step 2: Verify FAIL** → **Step 3: Implement + export** → **Step 4: PASS + analyze** → **Step 5: Commit** (`feat(dart-sdk): pluggable auth stores`)

---

### Task 4: Query helpers (filter safety + vector)

**Files:**
- Create: `lib/src/query.dart`, `test/query_test.dart`
- Modify: `lib/zigbase_client.dart`

**Interfaces (Produces):**
```dart
String filterValue(Object? value); // throws ArgumentError on List/Map/unsupported
String zbFilter(String expr, [Map<String, Object?> params = const {}]);
class VectorQuery {
  final String field; final String? metric; final List<double> values; // metric: 'cosine'|'l2'
  const VectorQuery({required this.field, this.metric, required this.values});
  String spec(); // '<field>[:metric]:<json-array>'; throws on non-finite values
}
```

Port of `query.ts` (`quoteString`/`filterValue`/`vectorSpec`). Escaping rules (byte-for-byte with TS): single-quote the string; backslash-escape `\`, `'`, and encode newline as `\n`, tab as `\t`, CR as `\r`. `null`→`null`, finite num→bare, bool→`true`/`false`, `DateTime`→quoted `toUtc().toIso8601String()`. `zbFilter` replaces `{:name}` placeholders with `filterValue(params[name])`; unknown placeholder throws `ArgumentError`.

- [ ] **Step 1: Failing tests** — include the TS suite's injection cases:
```dart
test('quotes and escapes hostile input', () {
  expect(filterValue("' || 1=1 --"), r"'\' || 1=1 --'");
  expect(filterValue('he said "hi" to O\'Brien'), contains(r"\'"));
  expect(filterValue("a\nb\tc\rd"), r"'a\nb\tc\rd'");
  expect(filterValue(5), '5');
  expect(filterValue(true), 'true');
  expect(filterValue(null), 'null');
  expect(() => filterValue([1, 2]), throwsArgumentError);
});
test('zbFilter interpolates named placeholders', () {
  expect(zbFilter('status = {:s} && n > {:n}', {'s': 'pub', 'n': 5}),
      "status = 'pub' && n > 5");
  expect(() => zbFilter('x = {:missing}'), throwsArgumentError);
});
test('vector spec', () {
  expect(const VectorQuery(field: 'emb', metric: 'cosine', values: [1, 2.5]).spec(),
      'emb:cosine:[1.0,2.5]');
  expect(() => VectorQuery(field: 'e', values: [double.nan]).spec(), throwsArgumentError);
});
```
(Verify the exact TS escape output by reading `clients/typescript/src/query.ts` + its test before finalizing expectations; the goal is identical wire bytes.)
- [ ] **Step 2: FAIL** → **Step 3: Implement + export** → **Step 4: PASS + analyze** → **Step 5: Commit** (`feat(dart-sdk): injection-safe filter helpers`)

---

### Task 5: Record types, envelopes, multipart encoding

**Files:**
- Create: `lib/src/records.dart`, `lib/src/cursor.dart`, `test/records_test.dart`
- Modify: `lib/zigbase_client.dart`

**Interfaces (Produces):**
```dart
class ZbRecord {
  final Map<String, dynamic> data;
  ZbRecord(this.data);
  String get id; // data['id'] as String? ?? ''
  dynamic operator [](String key);
  String? getString(String key); int? getInt(String key); double? getDouble(String key);
  bool? getBool(String key); List<dynamic>? getList(String key);
  Map<String, dynamic> toJson(); // returns data
}
class ListResult {
  final int page, perPage, totalItems, totalPages; final List<ZbRecord> items;
  factory ListResult.fromJson(Map<String, dynamic> json);
}
class CursorPage { // lib/src/cursor.dart
  final List<ZbRecord> items; final String? nextCursor, prevCursor;
  final bool hasNext, hasPrev; final int? totalItems;
  factory CursorPage.fromJson(Map<String, dynamic> json);
}
// records.dart — used by Transport:
bool hasFilePayload(Map<String, dynamic> body); // any value (or list element) is http.MultipartFile
/// Splits body into multipart fields + files per the TS toFormData rules.
({Map<String, List<String>> fields, List<http.MultipartFile> files})
    encodeMultipart(Map<String, dynamic> body);
```

`encodeMultipart` rules (port `toFormData` in `records.ts`): skip absent/`null`-valued? — no: skip *undefined* in TS ≈ omit key entirely in Dart only when value is a sentinel we don't have, so: `null`→`''`; `http.MultipartFile` appended as file (list of them repeats the field name — set each file's `field` to the key); `DateTime`→UTC ISO string; nested `Map`/`List` (non-file)→`jsonEncode`; scalars→`toString()`. Repeated keys accumulate in the `List<String>` values.

- [ ] **Step 1: Failing tests** — ZbRecord accessors + numeric coercion (`getInt` on a `num`), ListResult/CursorPage fromJson (including `nextCursor: null`, missing `totalItems`), `hasFilePayload` true for file and list-of-files, false otherwise; `encodeMultipart` on `{title:'x', when: DateTime.utc(2026,1,2), meta:{a:1}, tags:['a','b'], cover: MultipartFile.fromString('cover','bytes'), nullme: null}` → fields `{'title':['x'],'when':['2026-01-02T00:00:00.000Z'],'meta':['{"a":1}'],'tags':['a','b'],'nullme':['']}` wait — `tags` is a non-file List → JSON-encoded once: `{'tags':['["a","b"]']}`. Use the TS behavior: **arrays repeat the key only for files; other lists are JSON-stringified** — confirm against `records.ts` and encode that as the expectation.
- [ ] **Step 2: FAIL** → **Step 3: Implement + export** → **Step 4: PASS + analyze** → **Step 5: Commit** (`feat(dart-sdk): record types and multipart encoding`)

---

### Task 6: Transport (HTTP engine)

**Files:**
- Create: `lib/src/transport.dart`, `test/transport_test.dart`
- Modify: `lib/zigbase_client.dart` (export nothing new — Transport is internal, but keep it importable via `src/`; do export `RequestOptions`? No — keep internal.)

**Interfaces (Produces — consumed by every service task):**
```dart
class Transport {
  Transport({
    required String baseUrl, required AuthStore authStore, required http.Client httpClient,
    bool autoRefresh = false, int maxRetries = 3, String? lang, String? accountId,
    Future<void> Function()? refresh,               // wired later by ZigbaseClient
    Future<void> Function(Duration)? sleep,          // injectable for tests
  });
  String get baseUrl;
  Uri buildUrl(String path, [Map<String, dynamic>? query]); // skips null values; path passed through if starts with 'http'
  Future<dynamic> send(String path, {String method = 'GET', Map<String, dynamic>? query,
      Object? body, Map<String, String>? headers, bool skipAuth = false, String? requestKey});
  Future<http.Response> raw(String path, {String method = 'GET', Map<String, dynamic>? query,
      Object? body, Map<String, String>? headers, bool skipAuth = false});
  set refresh(Future<void> Function()? fn);
  void close(); // closes httpClient
}
```

Port `transport.ts` semantics exactly:
- Headers: bearer (unless skipAuth/no token), `Accept-Language` when lang, `X-Account-Id` when accountId and not already in per-request headers.
- Body: `Map`/`List` → `Content-Type: application/json` + jsonEncode (non-GET only). A `Map<String, dynamic>` body where `hasFilePayload` → build `http.MultipartRequest` with `encodeMultipart` output.
- 2xx: 204 or empty body → `null`; else `jsonDecode`.
- 401 → if `autoRefresh && refresh != null && !skipAuth` and not already refreshed this call: `await refresh()` then retry once.
- 429 → while attempt < maxRetries: delay = numeric `Retry-After` header seconds, else `min(30s, 200ms * 2^attempt)`; `await sleep(delay)`; retry.
- Other non-2xx → `throw parseErrorResponse(status, body, url, reasonPhrase: …)`.
- `requestKey`: map of key→`Completer`-based cancel token. A new request with the same key completes the prior request's future with `ZigbaseCancelledException` (`Future.any([httpFuture, cancelFuture])`); the stale HTTP response is ignored when it arrives. Key entry cleared on completion.
- `raw`: no parse, no throw, no refresh/retry; returns the `http.Response`.

- [ ] **Step 1: Failing tests** using `package:http/testing.dart` `MockClient`. Cover, at minimum:
```dart
test('sends bearer + accept-language + account header', ...);   // inspect request.headers
test('json body and content-type', ...);
test('multipart when body has MultipartFile', ...);             // request is MultipartRequest fields+files
test('204 and empty body return null', ...);
test('non-2xx throws ZigbaseException with parsed field data', ...);
test('401 triggers one-shot refresh then retry', () async {
  var calls = 0; var refreshed = 0;
  final t = Transport(..., autoRefresh: true, httpClient: MockClient((r) async {
    calls++;
    return calls == 1 ? http.Response('{"message":"unauthorized"}', 401)
                      : http.Response('{"ok":true}', 200);
  }))..refresh = () async { refreshed++; };
  expect(await t.send('/api/x'), {'ok': true});
  expect(refreshed, 1); expect(calls, 2);
});
test('429 backs off honoring Retry-After then succeeds', ...);  // inject sleep, assert delays [Duration(seconds:7)]
test('429 exponential default and gives up after maxRetries', ...); // delays 200ms,400ms,800ms then throws 429
test('requestKey cancels prior in-flight request', () async {
  // MockClient first request waits on a Completer; fire second with same key;
  // first future throws ZigbaseCancelledException, second succeeds.
});
test('raw returns non-2xx response without throwing', ...);
test('buildUrl skips null query values and url-encodes', ...);
```
- [ ] **Step 2: FAIL** → **Step 3: Implement** → **Step 4: PASS + analyze** → **Step 5: Commit** (`feat(dart-sdk): http transport with refresh, backoff, requestKey`)

---

### Task 7: PKCE helpers

**Files:**
- Create: `lib/src/pkce.dart`, `test/pkce_test.dart`
- Modify: `lib/zigbase_client.dart`

**Interfaces (Produces):**
```dart
class PkceChallenge { final String verifier; final String challenge; }
PkceChallenge createPkceChallenge(); // 64-char unreserved verifier; challenge = base64url-nopad(sha256(ascii(verifier)))
String randomState(); // 32-char unreserved via Random.secure()
```

- [ ] **Step 1: Failing tests** — verifier length 64 + charset `[A-Za-z0-9\-._~]`; state length 32; two calls differ; **RFC 7636 appendix B vector**: verifier `dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` → challenge `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM` (test the internal derivation via a `challengeFor(String verifier)` helper — expose it as a public function `String pkceChallengeFor(String verifier)` so it's testable).
- [ ] **Step 2: FAIL** → **Step 3: Implement + export** → **Step 4: PASS + analyze** → **Step 5: Commit** (`feat(dart-sdk): oauth2 pkce helpers`)

---

### Task 8: CollectionService — auth + CRUD + cursor

**Files:**
- Create: `lib/src/collection.dart`, `test/collection_auth_test.dart`, `test/collection_records_test.dart`, `test/collection_cursor_test.dart`
- Modify: `lib/zigbase_client.dart`

**Interfaces (Consumes):** `Transport.send`, `AuthStore`, `ZbRecord`/`ListResult`/`CursorPage`, `VectorQuery`.

**Interfaces (Produces):**
```dart
class AuthResponse { final String token; final ZbRecord? record; final Map<String, dynamic>? meta; }
class OAuth2Provider { final String name; final String? authUrl; final String? clientId; final List<String>? scopes; }
class OAuth2InitResponse { final String? authUrl; final String? clientId; final List<String>? scopes; final String? state; }
class SessionInfo { final String id; final String created, lastSeen, userAgent, ip; final bool isCurrent; }
class RecordAbilities { final bool view, update, delete; }

class CollectionService {
  CollectionService(Transport transport, AuthStore authStore, String name);
  // auth — every method's endpoint/body/skipAuth per clients/typescript/src/collection.ts:
  Future<AuthResponse> authWithPassword(String identity, String password);
  Future<AuthResponse> authRefresh();
  Future<String> authWithOAuth2({required String provider, required String code,
      required String codeVerifier, required String redirectUrl, String? state}); // returns token
  Future<OAuth2InitResponse> oauth2Init(String provider);
  Future<List<OAuth2Provider>> listAuthProviders(); // unwraps {items}
  Future<void> logout(); // clears authStore in finally
  Future<void> requestVerification(String email);
  Future<void> confirmVerification(String token);       // skipAuth
  Future<void> requestPasswordReset(String email);
  Future<void> confirmPasswordReset(String token, String password); // skipAuth
  Future<ZbRecord> changePassword(String id, String oldPassword, String newPassword); // re-auths current principal
  Future<List<SessionInfo>> listSessions();
  Future<void> revokeSession(String sessionId);
  Future<void> revokeAllSessions(); // clears authStore in finally
  // records:
  Future<ListResult> getList({int page = 1, int perPage = 30, String? filter, String? sort,
      String? expand, String? fields, bool skipTotal = false, String? search,
      VectorQuery? vector, String? requestKey});
  Future<ZbRecord> getOne(String id, {String? expand, String? fields, String? requestKey});
  Future<ZbRecord> getFirstListItem(String filter, {String? expand, String? fields, String? requestKey});
  Future<ZbRecord> create(Map<String, dynamic> body, {String? expand, String? fields, String? requestKey});
  Future<ZbRecord> update(String id, Map<String, dynamic> body, {String? expand, String? fields, String? requestKey});
  Future<void> delete(String id);
  Future<RecordAbilities> getAbilities(String id);
  // cursor:
  Future<CursorPage> getPage({String? cursor, int limit = 30, String? filter, String? sort,
      String? expand, String? fields, bool withTotal = false, String? search, String? requestKey});
  Stream<ZbRecord> iterate({int batch = 100, String? filter, String? sort, String? expand,
      String? fields, String? search});
  Future<List<ZbRecord>> getFullList({int batch = 100, String? filter, String? sort,
      String? expand, String? fields, String? search});
}
```

Endpoint map (all under `/api/collections/<uri-encoded name>`): auth-with-password, auth-refresh, auth/oauth2/complete, auth/oauth2/initiate, auth/oauth2/providers, auth-logout, request-verification, confirm-verification, request-password-reset, confirm-password-reset, auth/sessions (+`/:id`), records (+`/:id`, `/:id/abilities`). `authWithPassword` body `{identity, password}`, skipAuth, saves `{token, record}` to authStore. `getFirstListItem` = `getList(perPage:1, skipTotal:true)` and throws a synthesized 404 `ZigbaseException` when empty. `perPage` clamped 1..500. `skipTotal` sends `skipTotal=1`. Cursor: forward `cursor` verbatim, never decode; `withTotal` sends `skipTotal=false`. `changePassword`: PATCH the record with `{password, oldPassword}` then, if `authStore.record?['id'] == id`, re-run `authWithPassword(identityOf(record), newPassword)` — read `collection.ts` for which identity field it uses.

- [ ] **Step 1: Failing tests** (MockClient asserting method/path/query/body per call; a scripted queue of responses). Cover: password auth saves store; logout clears even on server error; oauth2 complete posts the exact body and saves token; getList query-param assembly (filter/sort/expand/fields/skipTotal=1/search/vector spec); perPage clamped; getFirstListItem 404 on empty; create/update pass through multipart bodies (body containing MultipartFile reaches transport unchanged); delete → DELETE; abilities parse; getPage maps envelope; iterate follows nextCursor across 3 pages and stops (assert yielded ids + request cursors); getFullList accumulates; sessions list/revoke/revokeAll (clears store).
- [ ] **Step 2: FAIL** → **Step 3: Implement + export** → **Step 4: PASS + analyze** → **Step 5: Commit** (`feat(dart-sdk): collection service — auth, crud, cursor pagination`)

---

### Task 9: Files, Accounts, Analytics, Senders services

**Files:**
- Create: `lib/src/files.dart`, `lib/src/accounts.dart`, `lib/src/analytics.dart`, `lib/src/senders.dart`, `test/files_test.dart`, `test/services_test.dart`
- Modify: `lib/zigbase_client.dart`

**Interfaces (Produces):**
```dart
class FilesService {
  FilesService(Transport transport, String baseUrl);
  String getUrl(ZbRecord record, String filename, {bool download = false, String? thumb, String? token});
    // collection from record.data['collectionId'] ?? record.data['collectionName']; throws ArgumentError if neither
  String getUrlFor(String collectionIdOrName, String recordId, String filename,
      {bool download = false, String? thumb, String? token});
  Future<String> getToken(); // POST /api/files/token → {token}
}
class AccountScope { final String account; final String role; }
class AccountsService { Future<AccountScope> activate(String accountId); } // POST /api/accounts/:id/activate
class AnalyticsEventsPage { final List<Map<String, dynamic>> items; final String? nextCursor; final bool hasNext; }
class AnalyticsService {
  Future<AnalyticsEventsPage> events({String? name, String? actor, String? since, int? limit, String? cursor});
  Future<List<Map<String, dynamic>>> rollup(String name, {String? from, String? to}); // unwraps {items}
}
class SenderIdentity { final String id; final String email; final String status; final String? verifiedAt; }
class SendersService {
  Future<List<SenderIdentity>> list();
  Future<SenderIdentity> create(String email);
  Future<bool> verify(String id, String token); // → {verified}
}
```

Port `files.ts` / `accounts.ts` / `analytics.ts` / `senders.ts`. File URL: `<baseUrl>/api/files/<col>/<rec>/<filename>` each segment `Uri.encodeComponent`-ed; query `download=1`, `thumb=<spec>`, `token=<t>`.

- [ ] **Step 1: Failing tests** — getUrl segment encoding (`filename` with spaces/`#`), thumb/download/token query, getUrlFor, getToken; activate path + parse; analytics events query params + cursor envelope; senders list/create/verify.
- [ ] **Step 2: FAIL** → **Step 3: Implement + export** → **Step 4: PASS + analyze** → **Step 5: Commit** (`feat(dart-sdk): files, accounts, analytics, senders services`)

---

### Task 10: ZigbaseClient facade

**Files:**
- Create: `lib/src/client.dart`, `test/client_test.dart`
- Modify: `lib/zigbase_client.dart`

**Interfaces (Consumes):** everything above. **(Produces):**
```dart
class ZigbaseClient {
  ZigbaseClient(String baseUrl, {
    AuthStore? authStore,                  // default MemoryAuthStore()
    bool autoRefresh = false,
    String? authCollection,               // wires transport.refresh = collection(authCollection).authRefresh
    String? accountId, String? lang, int maxRetries = 3,
    http.Client? httpClient,              // default http.Client()
    WebSocketConnector? webSocketConnector, // see Task 11; stored for realtime
  });
  String get baseUrl; AuthStore get authStore;
  CollectionService collection(String name); // cached per name
  FilesService get files; AccountsService get accounts;
  AnalyticsService get analytics; SendersService get senders;
  RealtimeService get realtime; // lazy; throws StateError before Task 11 lands? NO — Task 11 lands before this is exported as done; see ordering note
  Future<dynamic> send(String method, String path, {Map<String, dynamic>? query, Object? body,
      Map<String, String>? headers, String? requestKey});
  Future<http.Response> rawRequest(String method, String path, {Map<String, dynamic>? query,
      Object? body, Map<String, String>? headers});
  ZigbaseClient withAccount(String accountId); // sibling: same authStore/httpClient/connector, new accountId
  Future<void> close(); // closes realtime (if created) + transport + owned authStore dispose
}
```
**Ordering note:** implement Task 11 (realtime) FIRST or in the same working session as Task 10 if executing sequentially — the facade references `RealtimeService` and `WebSocketConnector`. Recommended execution order: 11 then 10, or declare the `realtime` getter in this task with the real class from Task 11 already available. **Execute Task 11 before Task 10.**

Trailing-slash: normalize `baseUrl` by stripping a trailing `/`.

- [ ] **Step 1: Failing tests** — default MemoryAuthStore; collection() caching (identical instance); send delegates with bearer; withAccount shares authStore but sends different X-Account-Id (MockClient assertion); autoRefresh+authCollection wiring: 401 → POST `/auth-refresh` → retry (end-to-end through the facade); rawRequest returns Response.
- [ ] **Step 2: FAIL** → **Step 3: Implement + export all public symbols from `zigbase_client.dart`** → **Step 4: PASS + analyze** → **Step 5: Commit** (`feat(dart-sdk): client facade`)

---

### Task 11: RealtimeService (execute BEFORE Task 10)

**Files:**
- Create: `lib/src/realtime.dart`, `test/realtime_test.dart`, `test/support/fake_socket.dart`
- Modify: `lib/zigbase_client.dart`

**Interfaces (Produces):**
```dart
typedef WebSocketConnector = Future<StreamChannel<dynamic>> Function(Uri uri);
typedef ZbUnsubscribe = Future<void> Function();
class RecordEvent { final String topic; final String action; final ZbRecord record; } // action: create|update|delete
class TopicMessage { final String topic; final String kind; final dynamic data; }     // kind: signal|message
class RealtimeService {
  RealtimeService({required String baseUrl, required AuthStore authStore,
    WebSocketConnector? connector,                    // default: WebSocketChannel.connect
    Duration minReconnect = const Duration(milliseconds: 250),
    Duration maxReconnect = const Duration(seconds: 10),
    Future<void> Function(Duration)? sleep, void Function(Object error)? onError});
  Future<ZbUnsubscribe> subscribe(String topic, void Function(RecordEvent) callback, {String? filter});
  Future<void> unsubscribe(String topic, [void Function(RecordEvent)? callback, String? filter]);
  Future<ZbUnsubscribe> subscribeTopic(String topic, void Function(TopicMessage) callback);
  Future<void> unsubscribeTopic(String topic, [void Function(TopicMessage)? callback]);
  Stream<RecordEvent> stream(String topic, {String? filter}); // convenience over subscribe; cancels on listener cancel
  Future<void> close(); // stop reconnects, clear subs, close socket
}
```

Port `realtime.ts` exactly. URL: baseUrl with `http`→`ws` scheme + `/api/realtime`. Uplink frames: `{"action":"auth","token":…}`, `{"action":"subscribe","topic":…,"filter"?:…}`, `{"action":"unsubscribe","topic":…}`. Downlink dispatch on `type`: `connect` (store clientId), `auth` (`status: ok|error` gate), `ack` (resolve pending subscribes for topic), `event` (topic/action/record → record callbacks), `signal`/`message` (topic callbacks), `error` (reject pending, call onError). Lifecycle: lazy connect on first subscribe; on open send `auth` first when token exists and gate resubscribe-all on auth ok (anonymous: resubscribe immediately); re-auth on `authStore.onChange` while connected; dedup concurrent same-(topic,filter) subscribes; record keys `r:` / topic keys `t:` namespaces; send one `unsubscribe` frame only when a topic's last variant is removed; reconnect on unexpected close with `min(maxReconnect, minReconnect * 2^attempts)`, attempts reset on successful open, mark all subs unacked and re-send.

- [ ] **Step 1: Failing tests** over a fake `StreamChannel` (a `StreamChannelController<dynamic>` in `test/support/fake_socket.dart` exposing: frames the service sent, a method to push server frames, and a way to simulate close). Cover:
  - subscribe sends subscribe frame, resolves only after `ack`, callback fires on `event` for its topic only; delete event record carries only `{id}`.
  - filter included in frame; two callbacks same topic+filter → one frame; unsubscribe of one keeps socket sub, of both sends unsubscribe frame.
  - auth frame sent first when store has token; resubscribe gated on `{"type":"auth","status":"ok"}`; authStore.save while connected → new auth frame.
  - server `error` frame rejects pending subscribe futures.
  - unexpected close → reconnect after 250ms (injected sleep), resubscribes all topics; backoff doubles on repeated failure; close() stops everything.
  - subscribeTopic receives `signal` and `message` frames as TopicMessage.
  - stream() emits events and unsubscribes on cancel.
- [ ] **Step 2: FAIL** → **Step 3: Implement + export** → **Step 4: PASS + analyze** → **Step 5: Commit** (`feat(dart-sdk): realtime websocket service`)

---

### Task 12: Integration tests (real server)

**Files:**
- Create: `clients/dart/test/integration/harness.dart`, `clients/dart/test/integration/integration_test.dart`, `clients/dart/dart_test.yaml`

**Interfaces (Consumes):** the whole public API. Read `clients/typescript/test/integration/harness.ts` FIRST and mirror its server-launch mechanics exactly (binary path from `ZIGBASE_TEST_BINARY`, free-port acquisition, data tempdir, `--insecure-cookies`, superuser bootstrap via `superuser create --email … --password …`, readiness poll on `/api/health`, teardown kill + tempdir cleanup).

`dart_test.yaml`:
```yaml
tags:
  integration:
    timeout: 2x
```
Integration file starts with `@Tags(['integration'])` and a top-of-main guard: `if (Platform.environment['ZIGBASE_TEST_BINARY'] == null) { print('skipped: ZIGBASE_TEST_BINARY unset'); return; }`. Unit runs use `dart test --exclude-tags integration`; integration runs use `dart test --tags integration`.

- [ ] **Step 1: Write the harness** (spawn server, poll health, create superuser, expose `baseUrl` + `stop()`).
- [ ] **Step 2: Write integration tests** covering: health via `send`; superuser `authWithPassword` on `_superusers`; create a `posts` collection via superuser API (`POST /api/collections` — read `docs/api.md` for the exact body) with `@public` rules for test simplicity; CRUD round-trip; filter with `zbFilter`; offset `getList` totals; cursor `getPage`/`iterate` across ≥3 pages of ≥25 seeded records; `authRefresh`; file field upload (MultipartFile) + fetch bytes via `getUrl` with `rawRequest`… (files.getUrl + plain http GET); realtime: subscribe to the collection, create a record, await the create event (with a 10s timeout).
- [ ] **Step 3: Run locally**: `mise exec zig@0.16.0 -- zig build` (repo root) then from `clients/dart/`: `ZIGBASE_TEST_BINARY=$PWD/../../zig-out/bin/zigbase mise exec dart@3.12 -- dart test --tags integration`. Expected: PASS. Iterate until green — this is the step that catches real protocol mismatches.
- [ ] **Step 4: Commit** (`test(dart-sdk): integration suite against a live server`)

---

### Task 13: CI job

**Files:**
- Modify: `.github/workflows/ci.yml` (add `dart-sdk` job after `ts-sdk`)

- [ ] **Step 1: Add job** mirroring `ts-sdk`'s shape (needs: build; checkout; `jdx/mise-action@v4`; download `zigbase-binaries` artifact; chmod + export `ZIGBASE_TEST_BINARY` — only the main binary is needed):
```yaml
  dart-sdk:
    runs-on: ubuntu-latest
    needs: build
    steps:
      - uses: actions/checkout@v7
      - uses: jdx/mise-action@v4
      - name: Download prebuilt binaries
        uses: actions/download-artifact@v8
        with:
          name: zigbase-binaries
          path: artifacts
      - name: Export prebuilt binary path
        run: |
          chmod +x artifacts/zig-out/bin/zigbase
          echo "ZIGBASE_TEST_BINARY=$GITHUB_WORKSPACE/artifacts/zig-out/bin/zigbase" >> "$GITHUB_ENV"
      - name: Cache pub
        uses: actions/cache@v5
        with:
          path: ~/.pub-cache
          key: pub-${{ runner.os }}-${{ hashFiles('clients/dart/pubspec.yaml') }}
          restore-keys: pub-${{ runner.os }}-
      - name: Install deps
        working-directory: clients/dart
        run: mise exec dart@3.12 -- dart pub get
      - name: Analyze
        working-directory: clients/dart
        run: mise exec dart@3.12 -- dart analyze --fatal-infos
      - name: Format check
        working-directory: clients/dart
        run: mise exec dart@3.12 -- dart format --output=none --set-exit-if-changed .
      - name: Unit tests
        working-directory: clients/dart
        run: mise exec dart@3.12 -- dart test --exclude-tags integration
      - name: Integration tests
        working-directory: clients/dart
        run: mise exec dart@3.12 -- dart test --tags integration
```
- [ ] **Step 2: Validate YAML** (`python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` via mise python) and confirm the artifact name matches the `build` job's upload name in the same file.
- [ ] **Step 3: Commit** (`ci: dart-sdk job`)

---

### Task 14: Docs + changelog + release scaffolding

**Files:**
- Create: `clients/dart/README.md`, `clients/dart/CHANGELOG.md`, `clients/dart/RELEASING.md`, `docs/dart-sdk.md`, `site/src/content/docs/dart-sdk.md`, `changelog.d/dart-client-sdk.md`
- Modify: `site/src/config/sidebar.ts` (add `{ slug: 'dart-sdk', label: 'Dart SDK' }` after the TypeScript SDK line), root `README.md` (add Dart client mention wherever the TS client is introduced — read it first)

- [ ] **Step 1: Write `clients/dart/README.md`** — mirror the TS README structure: install (`dart pub add zigbase_client`), quick start, auth + stores (Memory/Async + security note), records + safe filters (`zbFilter`), pagination (offset vs cursor + `iterate`), file upload/URLs, realtime (subscribe + stream + reconnect note), error handling, requestKey (document the discard-not-abort semantics), escape hatch (`send`/`rawRequest`). Every code sample must be real compiling Dart against the actual API.
- [ ] **Step 2: Write `docs/dart-sdk.md`** — fuller guide (same sections + integration-test recipe + "not yet: typed codegen, live store, SSE" limitations section), then copy verbatim to `site/src/content/docs/dart-sdk.md` **adding the Astro frontmatter block matching `site/src/content/docs/typescript-sdk.md`'s header style** (read it first: title/description frontmatter).
- [ ] **Step 3: `clients/dart/CHANGELOG.md`** (`## 0.1.0 — initial release`, bullet summary) and `RELEASING.md` (pub.dev publish is a follow-up; document independent versioning like the TS SDK's).
- [ ] **Step 4: `changelog.d/dart-client-sdk.md`**:
```markdown
### Features

- Official Dart client SDK (`clients/dart`, pub package `zigbase_client`): REST records API with offset + cursor pagination, injection-safe filters, per-collection auth (password, OAuth2/PKCE, sessions), pluggable auth stores, file uploads/URLs, accounts/analytics/senders services, and realtime subscriptions over WebSocket with auto-reconnect. Dart VM, Flutter, and Flutter web.
```
- [ ] **Step 5: Sidebar + root README edits; build the site**: `cd site && npm install && npm run build`. Expected: build succeeds.
- [ ] **Step 6: Check docs-parity test relevance**: run `mise exec python@3.13 -- python -m pytest tests/admin/test_docs_parity.py -q` (it guards config/env tables; should be untouched but verify).
- [ ] **Step 7: Commit** (`docs(dart-sdk): guides, changelog fragment, site mirror`)

---

### Task 15: Final verification sweep

- [ ] **Step 1:** From `clients/dart/`: `dart analyze --fatal-infos`, `dart format --output=none --set-exit-if-changed .`, `dart test --exclude-tags integration`, then full integration run against a freshly built binary. All PASS.
- [ ] **Step 2:** Repo root: `mise exec zig@0.16.0 -- zig build test --summary all` (nothing Zig-side should change, but the mise.toml edit warrants a sanity build) — authoritative signal is the `Build Summary` line.
- [ ] **Step 3:** `git status` clean in the worktree; verify the main checkout was not touched (`git -C /home/valthon/nothlav/zigbase status`).
- [ ] **Step 4:** Run the tell-a-git-story skill, then open the draft PR and monitor with the pr-monitor skill.
