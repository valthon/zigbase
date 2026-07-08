---
title: Dart SDK
description: The official zigbase_client Dart SDK — auth, records, offset + cursor pagination, files, and realtime, for the Dart VM, Flutter, and Flutter web.
order: 6
group: guides
---

# ZigBase Dart SDK

The official Dart client (`zigbase_client`) wraps the ZigBase HTTP REST + realtime WebSocket
API ([API reference](./api)) in an ergonomic surface: auth + stores, records, offset and cursor
pagination, files, and realtime subscriptions. It runs on the Dart VM, Flutter (iOS, Android,
desktop), and Flutter web.

Unlike the [TypeScript SDK](./typescript-sdk), there is currently only **one** tier — a
hand-written dynamic client. There is no comptime/runtime code generator for Dart yet (see
[Not yet](#not-yet) below).

## Install

**Not yet published to pub.dev.** The publishing workflow (`release-dart-sdk.yml`, OIDC
automated publishing) is wired up, but the first publish still needs one-time owner setup
on pub.dev — see
[clients/dart/RELEASING.md](https://github.com/valthon/zigbase/blob/main/clients/dart/RELEASING.md).
Until then, add it as a git dependency:

```yaml
dependencies:
  zigbase_client:
    git:
      url: https://github.com/valthon/zigbase
      path: clients/dart
```

Once published:

```sh
dart pub add zigbase_client
```

Runtime dependencies: `http` (transport), `web_socket_channel` + `stream_channel` (realtime),
`crypto` (PKCE), `http_parser` (multipart). SDK version: `zigbaseClientVersion` (currently
`0.1.0`, exported from `package:zigbase_client/zigbase_client.dart`).

## Create a client

```dart
import 'package:zigbase_client/zigbase_client.dart';

final zb = ZigbaseClient(
  'http://127.0.0.1:8090',
  authStore: AsyncAuthStore(save: persist, initial: cached), // omit for in-memory
);
```

`ZigbaseClient(baseUrl, {...})` constructor options:

| Option | Default | Purpose |
| --- | --- | --- |
| `authStore` | `MemoryAuthStore()` | Where the token + auth record live. |
| `autoRefresh` | `false` | Retry once on a 401 by refreshing the token (needs `authCollection`). |
| `authCollection` | — | The auth collection used for automatic refresh (e.g. `"users"`). |
| `accountId` | — | Bakes `X-Account-Id` into every request from this client (multi-tenancy). |
| `lang` | — | `Accept-Language` for localized server errors. |
| `maxRetries` | `3` | 429-backoff retry budget. |
| `httpClient` | `http.Client()` | Override the HTTP transport (tests, custom `http.Client`). |
| `webSocketConnector` | `WebSocketChannel.connect` | Override the realtime transport. |
| `onRealtimeError` | logs via `dart:developer` | Realtime error callback — see [Realtime](#realtime). |

### Ownership & `close()`

A `ZigbaseClient` constructed with the public constructor **owns** its `http.Client` (whether
it built the default one or was handed one) and, when the caller did not supply an
`AuthStore`, its `authStore` too. `close()` is idempotent and tears down exactly what this
instance owns: the `RealtimeService` (if `realtime` was ever accessed), the underlying
`http.Client`, and (only for the default `MemoryAuthStore`) the `authStore`. **A closed client
is terminal** — every accessor (`collection`, the service getters, `send`, `rawRequest`,
`withAccount`) throws `StateError` afterwards.

`withAccount(accountId)` returns a **sibling**: a second `ZigbaseClient` sharing this client's
`authStore` and `http.Client` (a login/logout on either is visible to both), scoped to send
`X-Account-Id: <accountId>` on every request. A sibling's `close()` only tears down its own
`RealtimeService`; closing the parent invalidates every sibling.

## Auth + stores

Two stores ship in the box:

- **`MemoryAuthStore`** — the default. In-memory only, gone on process exit.
- **`AsyncAuthStore`** — persists via caller-supplied async callbacks, so a Flutter app can
  plug in `shared_preferences`/`flutter_secure_storage`/anything else without the SDK
  depending on Flutter. `save`/`clear` calls are queued and applied in order (never
  interleaved); a throwing callback is swallowed (the write is dropped, later writes still
  run) — callbacks that need failure visibility should log internally.

```dart
final store = AsyncAuthStore(
  save: (data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('zb_auth', data);
  },
  clear: () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('zb_auth');
  },
  initial: cachedAuthJson, // must be read synchronously BEFORE constructing the store
);

// password auth — saves {token, record} into the store on success
await zb.collection('users').authWithPassword('you@example.com', 'secret');

zb.authStore.isValid; // decodes the JWT `exp` locally — UX hint only (see security note)
zb.authStore.record;  // the authenticated record (Map<String, dynamic>?)
zb.authStore.token;   // the raw JWT

// refresh + logout
await zb.collection('users').authRefresh();
await zb.collection('users').logout(); // clears the store

// react to login/logout/refresh anywhere
zb.authStore.onChange.listen((event) {
  print('auth changed: ${event.record?['id'] ?? '(signed out)'}');
});
```

### OAuth2 (Authorization-Code + PKCE)

```dart
// Discover configured providers (name, authUrl, clientId, scopes):
final providers = await zb.collection('users').listAuthProviders();

final pkce = createPkceChallenge(); // { verifier, challenge }
final state = randomState();
// 1. redirect the user to the provider authorize URL with pkce.challenge + state
// 2. on callback, exchange the code:
final token = await zb.collection('users').authWithOAuth2(
  provider: 'github',
  code: code,
  codeVerifier: pkce.verifier,
  redirectUrl: 'https://app.example.com/callback',
  state: state,
);
```

`authWithOAuth2` returns the raw token `String` and saves it into the auth store with a
`null` record — the endpoint sets `zb_auth`/`zb_csrf` cookies directly and never returns a
record.

### Verification + password reset

```dart
await zb.collection('users').requestVerification('you@example.com');
await zb.collection('users').confirmVerification(tokenFromEmail);

await zb.collection('users').requestPasswordReset('you@example.com');
await zb.collection('users').confirmPasswordReset(tokenFromEmail, 'new-secret');
```

### Changing a password (`changePassword`)

*Requires ZigBase >= 0.10.0.*

```dart
await zb.collection('users').changePassword(userId, 'old-secret', 'new-secret');
```

A self-service change while already logged in — distinct from the "forgot password" flow
above. It rides `PATCH /records/:id` with `{password, oldPassword}`; the server verifies
`oldPassword` against the target record (non-oracle: wrong/missing `oldPassword` both fail
the same way) and rotates the record's session epoch, dropping every other outstanding
session. When the auth store's current principal *is* the target record, `changePassword`
transparently re-authenticates with the stored identity (`email`, falling back to
`username`) and the new password, so a bearer-token client stays logged in.

### Sessions (`listSessions` / `revokeSession` / `revokeAllSessions`)

*Requires ZigBase >= 0.10.0. `listSessions`/`revokeSession` additionally require the server
to run `App(.{ .auth = .{ .session = .{ .store = .table } } })` — the default `.epoch` mode
has no per-device state to list, and the call surfaces the server's 404 as a
`ZigbaseException`.*

```dart
final sessions = await zb.collection('users').listSessions(); // List<SessionInfo>, newest first
// sessions[i].isCurrent marks the one THIS request authenticated with

await zb.collection('users').revokeSession(sessions[1].id); // log out one other device
await zb.collection('users').revokeAllSessions(); // log out everywhere, incl. this device
```

`SessionInfo` fields: `id`, `created`, `lastSeen`, `userAgent`, `ip`, `isCurrent` (mapped from
the server's snake_case `last_seen`/`user_agent`/`is_current`). `revokeAllSessions()` works in
both session-store modes and always clears the local `AuthStore`, even if the request fails.

### Security notes

- **`isValid` is not authorization.** It decodes the JWT `exp` claim client-side purely so the
  UI can pre-empt an expired session; the server authorizes every request — never gate
  sensitive UI on `isValid` alone.
- There is no cookie-based store in this SDK (no browser `document.cookie`, unlike the
  TypeScript SDK's `CookieAuthStore`). For a persisted store, back `AsyncAuthStore` with
  device-appropriate secure storage (e.g. `flutter_secure_storage` on mobile).

## Account scoping (multi-tenancy)

*Requires ZigBase >= 0.9.0 with `.tenancy` enabled.*

```dart
// 1. Bake it into the client at creation time.
final zb = ZigbaseClient(url, accountId: 'acc_123');

// 2. withAccount(id) — a sibling client scoped to a (possibly different) account.
final scoped = zb.withAccount('acc_123');
await scoped.collection('notes').getList(); // every request carries X-Account-Id: acc_123

// accounts.activate(id) — verify membership + set the zb_account cookie (browser/webview apps).
final scope = await zb.accounts.activate('acc_123');
scope.account; // "acc_123"
scope.role;    // the caller's role on that account
```

`withAccount` shares the same `AuthStore` as the client it was derived from and **replaces**
the account id rather than stacking. Per-request `X-Account-Id` (via `accountId`/
`withAccount`) always wins over the `zb_account` cookie server-side.

## Records

```dart
final posts = zb.collection('posts');

final page = await posts.getList(
  page: 1,
  perPage: 30,
  filter: "status = 'published'",
  sort: '-created',
  expand: 'author',
);
page.items.first.getString('title');

final one = await posts.getOne('REC123', expand: 'author');

// create — multipart is auto-detected when a body value is an http.MultipartFile
final made = await posts.create({'title': 'Hi', 'status': 'draft'});
final updated = await posts.update('REC123', {'title': 'Edited'});
await posts.delete('REC123');

// getFirstListItem — getList(perPage: 1) sugar; throws a 404 ZigbaseException when nothing matches
final draft = await posts.getFirstListItem("status = 'draft'");
```

`ZbRecord` wraps the raw JSON `Map<String, dynamic>` with typed accessors: `id`,
`operator [](key)`, `getString`/`getInt`/`getDouble`/`getBool`/`getList`, and `toJson()`.

### Safe filters — `zbFilter`

Build filter strings without injection risk using `zbFilter(expr, params)`, which
interpolates named `{:name}` placeholders via `filterValue`. String values are always
single-quoted and escaped against the server lexer (`'`, `\`, and newline/tab/CR are
backslash-escaped); `int`/`double`/`bool` render bare; `DateTime` becomes a millisecond-
clamped UTC ISO-8601 string. Any string is representable — including values containing both
`'` and `"`.

```dart
final q = userInput; // even `' || 1=1 --` or `he said "hi" to O'Brien` is safely quoted
final filter = zbFilter('status = {:s} && author ~ {:q}', {'s': 'published', 'q': q});
final list = await posts.getList(filter: filter);
```

`filterValue(value)` is the single-operand primitive `zbFilter` calls internally — reach for
it directly to build one operand at a time. Both throw `ArgumentError` on a non-finite
`double` or an unsupported type (`List`/`Map` operands are ambiguous — expand them yourself,
e.g. into an `||` chain or a native `in (...)` clause).

### Vector search

*Requires ZigBase >= 0.9.0 built with `-Dvector=true`.*

```dart
final nearest = await posts.getList(
  perPage: 10,
  vector: VectorQuery(field: 'embedding', metric: 'cosine', values: [0.12, 0.34 /* … */]),
);
```

`VectorQuery(field, metric, values).spec()` serializes to the wire's
`<field>[:metric]:<json-embedding>` mini-grammar; it throws `ArgumentError` on a non-finite
embedding value. Vector search is **offset-only** — the server rejects it in cursor mode.
`search` (full-text) is a plain `String` param on `getList`/`getPage`/`iterate`/`getFullList`
and works in both modes.

## Pagination — offset + cursor

```dart
// Offset: random page access + exact totals.
final p = await posts.getList(page: 2, perPage: 30);
p.totalItems; // total across all pages
p.totalPages;

// Cursor / keyset: stable under inserts; ideal for feeds and infinite scroll.
var c = await posts.getPage(limit: 30, sort: '-created');
c.items; c.nextCursor; c.hasNext;
while (c.hasNext && c.nextCursor != null) {
  c = await posts.getPage(limit: 30, sort: '-created', cursor: c.nextCursor);
}

// async-iterate every matching record over the stable cursor engine
await for (final post in posts.iterate(sort: '-created')) {
  // ...
}
final all = await posts.getFullList(filter: "status = 'published'");
```

**Which one to use?** Reach for **offset** (`getList`) when you need jump-to-page-N
navigation or an exact total count. Reach for **cursor** (`getPage` / `iterate` /
`getFullList`) for stable feeds and infinite scroll: it is stable under concurrent inserts
and avoids the cost of deep offsets.

Cursor pagination is **native server-side keyset pagination**. The server mints an opaque
token; the client treats `nextCursor`/`prevCursor` as opaque strings and forwards whatever it
received on the next `getPage` call — it never decodes or synthesizes one. The server skips
the total count by default (the expensive part); pass `withTotal: true` to a `getPage` call to
include `totalItems`. `getPage` sends `limit` (defaulting to 30); omitting `cursor` requests
the first page.

## Files

A `create`/`update` body value that is an `http.MultipartFile` (or a `List` containing one) is
sent as multipart automatically — no special method. The outer map key, not whatever field
name the `MultipartFile` was constructed with, becomes the form field name.

```dart
import 'package:http/http.dart' as http;

final bytes = await File('cover.png').readAsBytes();
final rec = await posts.create({
  'title': 'Hi',
  'status': 'draft',
  'cover': http.MultipartFile.fromBytes('cover', bytes, filename: 'cover.png'),
});

// build a (optionally thumbnailed) file URL from the record:
final url = zb.files.getUrl(rec, rec.getString('cover')!, thumb: '100x100');

// short-lived token for protected-file access (<img>, emails):
final token = await zb.files.getToken();
final protectedUrl = zb.files.getUrl(rec, rec.getString('cover')!, token: token);

// or pass collection + id explicitly instead of a record object:
final url2 = zb.files.getUrlFor('posts', 'REC123', 'cover.png', download: true);
```

An `http.MultipartFile` is single-use (`package:http` finalizes its byte stream once);
construct a fresh instance for each `create`/`update` call — reusing one across two calls
throws a `StateError`.

`zb.files.getUrl(record, filename, {...})` reads the collection from
`record.data['collectionId']`, falling back to `collectionName`; it throws `ArgumentError`
when neither is present (e.g. a hand-built map that never round-tripped through the server).

## Abilities

*Requires ZigBase >= 0.9.0.*

```dart
final abilities = await posts.getAbilities('REC123');
abilities.view;   // always true on success — you couldn't have fetched abilities otherwise
abilities.update; // bool
abilities.delete; // bool
```

**404, not 403, when the record isn't viewable** — a deliberate non-oracle: a
`ZigbaseException(status: 404)` never distinguishes "exists but you lack access" from
"doesn't exist."

## Analytics

*Requires ZigBase >= 0.9.0 (cursor pagination on `events` requires >= 0.10.0).*

```dart
final feed = await zb.analytics.events(name: 'signup', since: '2026-01-01T00:00:00Z', limit: 50);
feed.items.first['payload']; // dynamic (JSON value; null when unparseable/empty)
if (feed.hasNext) await zb.analytics.events(cursor: feed.nextCursor);

final rollup = await zb.analytics.rollup('daily_signups', from: weekAgoIso, to: nowIso);
rollup.first['value'];
```

Wire field names stay **snake_case** as the server sends them (`actor_collection`,
`occurred_at`, `computed_at`, …) — rows are returned as raw `Map<String, dynamic>` rather than
a typed class. `since`/`from`/`to` are plain ISO-8601 `String`s (format them yourself; there is
no `DateTime`-accepting overload). `events()` is 401 for an anonymous caller, returns empty
`items` when there's no active account, and a superuser sees every account's events.
`rollup(name)` is 404 for an undeclared rollup name and 403 when a non-superuser queries a
rollup that isn't grouped by account.

## Senders

*`list` requires ZigBase >= 0.10.0; `create`/`verify` require >= 0.9.0.*

```dart
// request verification — the token is EMAILED to the address, never returned
final pending = await zb.senders.create('orders@my-shop.example');
pending.status; // "pending" (201) or already-verified (200)

// confirm with the token from the email
await zb.senders.verify(pending.id, tokenFromEmail);

// the active account's identities (requires server >= 0.10.0)
final items = await zb.senders.list();
items.first.verifiedAt;
```

A re-send of `create()` for the same `(account, email)` within the server's throttle window
throws a 429 `ZigbaseException`. `verify()` returns `false`/404 — never a distinguishing
error — for a wrong token, wrong account, or wrong id.

## Realtime

```dart
final unsub = await zb.realtime.subscribe(
  'posts',
  (e) {
    e.action; // 'create' | 'update' | 'delete'
    e.record; // the record (a delete carries only {id})
  },
  filter: "status = 'published'",
);

await unsub(); // stop this callback; the socket closes when the last topic goes away

// single-record topic
await zb.realtime.subscribe('posts/REC123', (e) {
  // fires on update/delete of one record
});
```

A **single shared WebSocket** to `<baseUrl>/api/realtime` (http/https mapped to ws/wss) is
created lazily on the first `subscribe`/`subscribeTopic` call and multiplexes every topic. It:

- **auto-reconnects** with bounded exponential backoff (250ms–10s by default),
- **re-auths** from the `AuthStore` on login/logout/refresh,
- **resubscribes** every active topic after a reconnect.

Anonymous subscriptions are allowed only for collections with a `@public` view rule
(server-enforced); the client does not pre-gate — a rejected subscribe rejects the returned
`Future` and/or calls the error callback. **Known limitation:** the server keys a
subscription per topic per connection, so subscribing to the same topic with two different
filters on one client makes the second filter overwrite the first server-side — both
callbacks then receive the second filter's events.

### Error handling — `onRealtimeError`

```dart
final zb = ZigbaseClient(
  'http://127.0.0.1:8090',
  onRealtimeError: (error) => myLogger.warn('realtime: $error'),
);
```

Pass `onRealtimeError` to the client constructor to observe server-side realtime errors —
e.g. a server rejection of an anonymous subscribe to a non-public collection, or a
socket-level error with no in-flight subscribe at all. The callback fires for **every**
server error frame, *including* errors also delivered to (and rejecting) a pending
`subscribe`/`subscribeTopic` call — treat it as a logging/telemetry hook, not a replacement
for handling a rejected subscribe `Future`. **A realtime error is never silently dropped:**
when `onRealtimeError` is omitted, the client falls back to logging the error visibly via
`dart:developer` (shows up in IDE/DevTools consoles). Constructing a `RealtimeService`
directly (bypassing the client) still defaults its own `onError` to `null` (a real no-op)
if you don't pass one.

### As a `Stream`

```dart
final sub = zb.realtime.stream('posts', filter: "status = 'published'").listen((e) {
  print('${e.action}: ${e.record.id}');
});
// later:
await sub.cancel(); // unsubscribes, including mid-flight ack round-trips
```

### Custom topics — `subscribeTopic`

*Requires ZigBase >= 0.9.0 for custom-route `signal`/`message` broadcasts; the built-in
`__features` signal requires >= 0.10.0.*

```dart
final unsub = await zb.realtime.subscribeTopic('availability', (msg) {
  msg.topic; // 'availability'
  msg.kind;  // 'signal' | 'message'
  if (msg.kind == 'message') msg.data; // the broadcast payload
});

await zb.realtime.unsubscribeTopic('availability', callback);
```

`kind` mirrors the wire frame's `type` field verbatim. Topic subscriptions reuse the same
shared-socket machinery as record subscriptions (ack/pending/resubscribe/backoff) but take no
`filter`.

## Error handling

Every non-2xx response throws a `ZigbaseException` carrying `status`, `message`, `url`, and
per-field validation errors in `data` (`Map<String, FieldError>`):

```dart
try {
  await posts.create({'title': ''});
} on ZigbaseException catch (e) {
  if (e.status == 400) {
    print(e.data['title']?.message); // field-level error
  }
}
```

## Auto-cancellation — `requestKey`

Pass `requestKey` on any read/mutation (or `send`) for opt-in last-write-wins de-duplication:
issuing a new request with a key supersedes any in-flight request sharing that key. Without a
key, nothing is auto-cancelled.

**This is discard, not abort.** `package:http` has no way to cancel a live socket, so
cancellation is cooperative: the superseded call's `Future` completes with a
`ZigbaseCancelledException` while its underlying HTTP request keeps running in the background
— its eventual response (success or error) is silently discarded on arrival, never leaking as
an unhandled async error. This is a deliberate divergence from the TypeScript SDK, whose
`fetch`-based transport can truly `AbortController.abort()` the in-flight request.

```dart
// As the user types, only the latest search's Future resolves; earlier ones reject.
try {
  final results = await posts.getList(filter: filter, requestKey: 'search');
} on ZigbaseCancelledException {
  // a newer keyed request superseded this one — safe to ignore
}
```

## Escape hatch — `send()` and `rawRequest()`

`zb.send(method, path, {...})` calls any endpoint the typed surface doesn't cover, returning
parsed JSON (or `null` for 204/empty); the auth header, 401 auto-refresh, 429 backoff, and
`ZigbaseException` mapping still apply:

```dart
final stats = await zb.send('GET', '/api/custom/stats', query: {'window': '7d'})
    as Map<String, dynamic>;
await zb.send('POST', '/api/custom/reindex', body: {'collection': 'posts'});
```

For a non-GET request, `body` is **always** JSON-encoded (`Content-Type: application/json`)
unless it contains an `http.MultipartFile`, matching the TypeScript SDK's
`JSON.stringify`-everything behavior byte-for-byte — this applies even to a bare scalar, so
`body: 'hi'` is sent as the quoted JSON string literal `"hi"`, never as raw unquoted text.
A `DateTime` nested anywhere in the body serializes as a millisecond-clamped UTC ISO-8601
string (as JS `JSON.stringify` does for a `Date`); any other non-encodable value throws an
`ArgumentError`.

When you need the **raw `http.Response`** (binary/text bodies, response headers, custom
status handling), use `zb.rawRequest(method, path, {...})`. It passes through
`query`/`body`/`headers` and the auth header, but does **not** JSON-parse and does **not**
throw on a non-2xx status:

```dart
final res = await zb.rawRequest('GET', '/api/export.csv', query: {'format': 'csv'});
if (res.statusCode == 200) {
  print(res.headers['content-type']);
  print(res.body);
}
```

## Integration-test recipe

The SDK's own end-to-end suite (`clients/dart/test/integration/`) drives the public API
against a real `zigbase serve` process — the same pattern works for consumer apps that want a
live-server smoke test:

```sh
# 1. Build the server binary once.
mise exec zig@0.16.0 -- zig build

# 2. Point ZIGBASE_TEST_BINARY at it and run the tagged suite.
ZIGBASE_TEST_BINARY="$(pwd)/zig-out/bin/zigbase" \
  mise exec dart@3.12 -- dart test --tags integration
```

The suite is a clean no-op (a printed skip, never a failure) when `ZIGBASE_TEST_BINARY` is
unset, so plain `dart test` stays green without the Zig toolchain. The harness
(`test/integration/harness.dart`) launches the binary on a free loopback port with a fresh
tempdir data directory and `--insecure-cookies`, seeds a superuser via the `superuser create`
CLI subcommand, polls `/api/health` for readiness (retrying on a fresh port if a bind race
kills the child), and `SIGTERM`s + removes the tempdir on teardown.

## Not yet

The Dart SDK is a base client — a few surfaces the TypeScript SDK has do not exist here yet:

- **Typed codegen tier.** There is no Dart equivalent of `zig build gen-client` /
  `npx @zigbase/typegen` — every read is dynamically typed (`ZbRecord`/`Map<String, dynamic>`),
  and you `getString`/`getInt`/… your way to a value. No typed `db.*`/`rpc.*`/`auth.*`
  surfaces.
- **Live store.** `zb.realtime.collection(name)` (kept-in-sync live records/lists,
  `LiveList.mode` precise/refetch tracking) has no Dart port; only the low-level
  `subscribe`/`subscribeTopic`/`stream` primitives exist.
- **SSE transport.** The server exposes realtime over both WebSocket and SSE
  (`EventSource`); this SDK speaks WebSocket only.
- **Cookie-based auth store.** No `CookieAuthStore` equivalent — persist via `AsyncAuthStore`
  backed by your platform's secure storage instead.

These are planned follow-ups, not permanent gaps — track them alongside the TypeScript SDK's
own SP2.1b typed-generator work.

## See also

- [API reference](./api) — the underlying HTTP + WebSocket protocol.
- [TypeScript SDK](./typescript-sdk) — the more mature sibling client, including the typed
  codegen tiers and live store this SDK doesn't have yet.
- [Recipes](./recipes) — schema provisioning, owner-scoped rules, signup flows.
- [Tutorial](./tutorial) — build an app on ZigBase end to end.
