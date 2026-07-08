# Dart Client SDK — Design

Date: 2026-07-07
Status: approved (autonomous session — assumptions documented inline)

## Goal

Ship an official Dart client for ZigBase at `clients/dart/` (pub package
`zigbase_client`), at feature parity with the **base tier** of the TypeScript
SDK (`@zigbase/client` v0.3.0): REST core, pluggable auth stores, per-collection
auth (password + OAuth2/PKCE + sessions), offset **and** cursor pagination,
injection-safe filters, file URLs/tokens/multipart uploads, accounts, analytics,
senders, and realtime over WebSocket. Runs on Dart VM, Flutter (iOS/Android/
desktop), and Flutter web.

## Scope decisions (assumptions)

Made autonomously; each mirrors an existing repo precedent:

1. **Base dynamic tier only.** The SDK three-tier strategy shipped the TS base
   client first (SP1) and layered typed codegen later. The Dart SDK follows the
   same ladder: this PR is the dynamic base client. The **typed/codegen tier**
   and the **live store** (LiveList/LiveRecord + client-side filter eval — which
   in Dart raises a Flutter-dependency question worth its own design round) are
   explicit follow-ups, not in scope.
2. **Package name `zigbase_client`**, version `0.1.0`, independently versioned
   like the TS SDK (own CHANGELOG.md + RELEASING.md; publishing to pub.dev is a
   later, separate step — this PR only scaffolds the release notes).
3. **Dependencies** (all Dart-team maintained, cross-platform): `http` ^1.2
   (HTTP), `web_socket_channel` ^3.0 (realtime), `crypto` ^3.0 (PKCE SHA-256).
   Dev: `test`, `lints`. No Flutter dependency.
4. **Toolchain**: add `dart = "3.12"` to `mise.toml` (matches how node/python
   are pinned); CI gets a `dart-sdk` job mirroring `ts-sdk`.

## Architecture

One library `package:zigbase_client/zigbase_client.dart` exporting everything;
realtime is a separate file but same package (Dart has no bundle-size concern
that motivated the TS entry-point split).

```
clients/dart/
  pubspec.yaml
  analysis_options.yaml
  README.md  CHANGELOG.md  RELEASING.md  LICENSE
  lib/
    zigbase_client.dart          # exports
    src/
      client.dart                # ZigbaseClient facade + withAccount()
      transport.dart             # HTTP engine
      errors.dart                # ZigbaseException, FieldError
      auth_store.dart            # AuthStore, MemoryAuthStore, AsyncAuthStore
      jwt.dart                   # decodeJwtPayload, isTokenExpired
      pkce.dart                  # createPkceChallenge, randomState
      collection.dart            # CollectionService (auth + CRUD + cursor)
      records.dart               # ZbRecord, ListResult, multipart detection
      cursor.dart                # CursorPage
      query.dart                 # zbFilter, filterValue, vector spec
      files.dart                 # FilesService
      accounts.dart              # AccountsService
      analytics.dart             # AnalyticsService
      senders.dart               # SendersService
      realtime.dart              # RealtimeService (WebSocket)
  test/                          # unit tests (MockClient / fake WS channel)
  test/integration/              # gated on ZIGBASE_TEST_BINARY env
```

### Unit responsibilities

**`ZigbaseClient`** — constructor `ZigbaseClient(String baseUrl, {AuthStore?
authStore, bool autoRefresh = false, String? authCollection, String? accountId,
String? lang, int maxRetries = 3, http.Client? httpClient, WebSocketConnector?
webSocketConnector})`. Exposes `collection(name)`, lazy `files/accounts/
analytics/senders/realtime`, `send()` (JSON escape hatch), `rawRequest()`
(returns `http.Response`, no throw/parse), `withAccount(id)` (sibling sharing
the AuthStore), `close()` (closes HTTP client + realtime).

**`Transport`** — same semantics as TS `transport.ts`:
- `Authorization: Bearer <token>` unless `skipAuth`; `Accept-Language` when
  `lang`; `X-Account-Id` when configured (per-request header wins).
- Body: `Map`/`List` → JSON; a body containing `http.MultipartFile` values →
  multipart (same field-encoding rules as TS `toFormData`: skip null-absent,
  `null`→`""`, `DateTime`→ISO-8601 UTC, nested Map/List→JSON string, scalars
  →`toString()`; file arrays repeat the key).
- 2xx: `204`/empty → `null`, else `jsonDecode`.
- 401 + `autoRefresh` + `authCollection`: one-shot `authRefresh()` then retry.
- 429: retry up to `maxRetries`, honoring numeric `Retry-After` (seconds),
  else `min(30s, 2^attempt * 200ms)`.
- Non-2xx → throws `ZigbaseException` parsed from `{message, data}` JSON.
- **`requestKey` dedup**: a new request with the same key cancels the prior
  in-flight one. `package:http` cannot abort a socket per-request, so
  cancellation completes the stale future with `ZigbaseCancelledException`
  and discards its response on arrival (documented behavioral difference
  from the TS SDK's true abort).

**`AuthStore`** — abstract: `token`, `record`, `isValid` (JWT-exp check),
`save(token, record)`, `clear()`, `Stream<AuthEvent> onChange` (broadcast).
Ships `MemoryAuthStore` (default) and `AsyncAuthStore` (constructor takes
`save`/`clear` callbacks + optional `initial` string — the standard Dart
pattern for plugging `shared_preferences` etc. without depending on Flutter).

**`CollectionService`** — direct port of TS `collection.ts`. Auth:
`authWithPassword`, `authRefresh`, `authWithOAuth2`, `oauth2Init`,
`listAuthProviders`, `logout`, `requestVerification`, `confirmVerification`,
`requestPasswordReset`, `confirmPasswordReset`, `changePassword` (re-auths if
the target is the current principal), `listSessions`, `revokeSession`,
`revokeAllSessions`. Records: `getList` (offset, named params `page/perPage/
filter/sort/expand/fields/skipTotal/search/vector`), `getOne`,
`getFirstListItem` (404 if empty), `create`/`update` (auto-multipart),
`delete`, `getAbilities`. Cursor: `getPage` (opaque server cursor, forwarded
verbatim), `iterate` → `Stream<ZbRecord>` (async*, follows `nextCursor`,
batch default 100), `getFullList`. Superusers are just
`collection('_superusers')` — no separate class.

**`ZbRecord`** — lightweight dynamic record: `String id`, `Map<String,
dynamic> data`, `dynamic operator [](String key)`, `getString/getInt/
getDouble/getBool/getList` convenience casters, `toJson()`. List/page
envelopes: `ListResult` (page/perPage/totalItems/totalPages/items) and
`CursorPage` (items/nextCursor/prevCursor/hasNext/hasPrev/totalItems?).

**`query.dart`** — `filterValue(v)` (null→`null`, num bare, bool bare,
DateTime→quoted ISO, String→single-quoted with `\ ' \n \t \r` escaped —
byte-for-byte the TS `quoteString` rules; throws on List/Map) and
`zbFilter('status = {:s} && author ~ {:q}', {'s': …, 'q': …})` — named
`{:placeholder}` interpolation (Dart has no tagged templates; this is the
established Dart-SDK idiom). Plus `VectorQuery` → `field[:metric]:[json]`
spec for `?vector=`.

**`FilesService`** — `getUrl(record, filename, {download, thumb, token})` and
`getUrlFor(collection, recordId, filename, …)`; `getToken()` → POST
`/api/files/token`.

**`AccountsService.activate`**, **`AnalyticsService.events/rollup`**,
**`SendersService.list/create/verify`** — thin ports of the TS services,
same endpoints and envelopes.

**`RealtimeService`** — WebSocket to `ws(s)://…/api/realtime` via
`web_socket_channel`. Same wire protocol as TS: uplink `auth`/`subscribe`/
`unsubscribe` frames; downlink `connect`/`auth`/`ack`/`event`/`signal`/
`message`/`error`. Lazy connect on first subscribe; auth frame first when a
token exists (resubscribe gated on auth ok); re-auth on `authStore.onChange`;
dedup concurrent subscribes to the same (topic,filter); reconnect on
unexpected close with `min(10s, 250ms * 2^attempts)` backoff and full
resubscribe; `close()` stops reconnects. API: `Future<ZbUnsubscribe>
subscribe(topic, void Function(RecordEvent) cb, {String? filter})` (resolves
on ack), `subscribeTopic(topic, cb)` for custom topics, matching
`unsubscribe`/`unsubscribeTopic`, plus `Stream<RecordEvent> stream(topic,
{filter})` as an idiomatic-Dart convenience wrapper.

**`errors.dart`** — single `ZigbaseException implements Exception` with
`status`, `message`, `data` (`Map<String, FieldError>`), `url`; plus
`ZigbaseCancelledException`. No subclass hierarchy (matches TS).

## Error handling

All non-2xx surface as `ZigbaseException`; malformed error bodies fall back
to the HTTP reason/`Request failed with status N`. Realtime `error` frames
reject pending subscribes and route to an `onError` callback (default: no-op
log). Network failures in realtime trigger the reconnect loop, never throw
out of callbacks.

## Testing

- **Unit** (`dart test`, no network): transport auth-header/refresh/429/
  requestKey/error-parsing via `MockClient`; multipart encoding; filter
  escaping (including the injection cases from the TS suite); jwt; pkce
  (RFC 7636 vector); cursor paging/iterate; auth stores; realtime
  subscribe/ack/reconnect/re-auth over a fake `StreamChannel`.
- **Integration** (`test/integration/`, tagged `integration`, skipped unless
  `ZIGBASE_TEST_BINARY` is set): spins the real server binary on a free port
  with a tempdir (port-file pattern like the TS harness), covers superuser
  auth, users password auth + refresh, CRUD + filter + offset + cursor
  pagination, file upload + fetch via `getUrl`, and one realtime
  subscribe→create→event round-trip.
- **CI**: new `dart-sdk` job in `ci.yml` mirroring `ts-sdk` (needs `build`,
  downloads the prebuilt binary artifact, `dart pub get`, `dart analyze`
  (fatal-infos), `dart format --set-exit-if-changed`, unit tests, then
  integration tests with `ZIGBASE_TEST_BINARY` exported).

## Docs & sync obligations (per repo conventions)

- `clients/dart/README.md` (quick start mirroring the TS README structure).
- `docs/dart-sdk.md` + mirror `site/src/content/docs/dart-sdk.md` + sidebar
  entry `{ slug: 'dart-sdk', label: 'Dart SDK' }` after the TypeScript one;
  `cd site && npm run build` to verify.
- Root `README.md`: mention the Dart client alongside the TS one (verify
  current phrasing first).
- `changelog.d/dart-sdk.md` fragment: `### Features` — official Dart client.
- `docs/typescript-sdk.md` untouched.

## Follow-ups (out of scope, recorded)

- Live store tier (LiveList/LiveRecord + filter-eval) — needs a decision on
  Flutter integration (`ChangeNotifier`/`ValueListenable` vs pure streams).
- Typed/codegen tier (`zig build gen-client` emitting Dart; typegen).
- pub.dev publishing workflow (`client-dart-v*` tag, OIDC).
- SSE realtime transport as a WebSocket alternative.
