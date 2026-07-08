# zigbase_client

Official Dart client for [ZigBase](../../README.md). Runs on the Dart VM, Flutter (iOS/
Android/desktop), and Flutter web.

For the full guide (integration-test recipe, security notes, known limitations) see
[docs/dart-sdk.md](../../docs/dart-sdk.md).

## Install

**Not yet published to pub.dev** (tracked in [RELEASING.md](RELEASING.md)). Until the first
publish, add it as a git dependency in your `pubspec.yaml`:

```yaml
dependencies:
  zigbase_client:
    git:
      url: https://github.com/valthon/zigbase
      path: clients/dart
```

Once published, install will be the usual:

```sh
dart pub add zigbase_client
```

Runtime dependencies: `http`, `web_socket_channel`, `crypto`, `stream_channel`,
`http_parser`.

## Quick start

```dart
import 'package:zigbase_client/zigbase_client.dart';

Future<void> main() async {
  final zb = ZigbaseClient('http://127.0.0.1:8090');

  // Authenticate (saves the token + record into the auth store)
  await zb.collection('users').authWithPassword('you@example.com', 'secret');

  // Read records
  final posts = await zb.collection('posts').getList(page: 1, perPage: 30);
  print(posts.items.first.getString('title'));

  // Call any endpoint directly
  final health = await zb.send('GET', '/api/health') as Map<String, dynamic>;
  print(health['status']); // "ok"

  await zb.close(); // releases the underlying http.Client (+ realtime socket, if opened)
}
```

## Auth + stores

Two stores ship in the box:

- **`MemoryAuthStore`** — the default. Never persists; gone on process exit.
- **`AsyncAuthStore`** — persists via caller-supplied async callbacks, so a Flutter app can
  plug in `shared_preferences` (or any other storage) without the SDK depending on Flutter.

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
  initial: cachedAuthJson, // read synchronously at startup, e.g. from a prefs cache
);

final zb = ZigbaseClient('http://127.0.0.1:8090', authStore: store);

zb.authStore.isValid; // local JWT-exp check (UX only — see security note)
zb.authStore.record;  // the authenticated record
await zb.collection('users').authRefresh();
await zb.collection('users').logout(); // clears the store

// react to login / logout / refresh anywhere
zb.authStore.onChange.listen((event) {
  print('auth changed: ${event.record?['id'] ?? '(signed out)'}');
});
```

### OAuth2 (Authorization-Code + PKCE)

```dart
final providers = await zb.collection('users').listAuthProviders();
final pkce = createPkceChallenge();
final state = randomState();
// 1. redirect to the provider authorize URL with pkce.challenge + state
// 2. on the callback, exchange the code:
final token = await zb.collection('users').authWithOAuth2(
  provider: 'github',
  code: code,
  codeVerifier: pkce.verifier,
  redirectUrl: 'https://app.example.com/callback',
  state: state,
);
```

> **Security.** `isValid` decodes the JWT `exp` **client-side** — it is a UX/expiry hint
> only, never an authorization decision (the server authorizes every request). There is no
> `CookieAuthStore` equivalent in this SDK yet; for a persisted store use `AsyncAuthStore`
> backed by secure device storage.

## Records + safe filters

```dart
final posts = zb.collection('posts');

final page = await posts.getList(
  page: 1,
  perPage: 30,
  filter: zbFilter('status = {:s}', {'s': 'published'}),
  sort: '-created',
  expand: 'author',
);
print(page.items.first.getString('title'));

final post = await posts.getOne('REC_ID', expand: 'author');
final draft = await posts.getFirstListItem("status = 'draft'"); // throws 404 ZigbaseException if none

final created = await posts.create({'title': 'Hi', 'status': 'draft'});
final updated = await posts.update(created.id, {'title': 'Edited'});
await posts.delete(created.id);
```

`zbFilter` interpolates named `{:name}` placeholders and always single-quotes/escapes string
values against the server's filter lexer — any string is representable, including values
containing both `'` and `"`. Build the filter yourself with `filterValue(value)` for one-off
operands.

## Pagination — offset vs cursor

```dart
// Offset: random page access + exact totals.
final p = await posts.getList(page: 2, perPage: 30);
p.totalItems; // total across all pages
p.totalPages;

// Cursor (keyset): stable under inserts, no deep-offset cost.
var c = await posts.getPage(limit: 20, sort: '-created');
render(c.items);
while (c.hasNext && c.nextCursor != null) {
  c = await posts.getPage(limit: 20, sort: '-created', cursor: c.nextCursor);
  render(c.items);
}

// Iterate every matching record (stable even while rows are inserted):
await for (final post in posts.iterate(sort: '-created')) {
  handle(post);
}
final all = await posts.getFullList(filter: "status = 'published'");
```

**Which one?** Use **offset** (`getList`) when you need jump-to-page-N or a total count. Use
**cursor** (`getPage` / `iterate` / `getFullList`) for stable feeds and infinite scroll where
deep offsets get slow — the server mints an opaque `nextCursor`/`prevCursor` token the client
just forwards back. Totals are skipped by default; pass `withTotal: true` to `getPage` to
include `totalItems`.

## File uploads & URLs

A `create`/`update` body value that is an `http.MultipartFile` (or a `List` containing one) is
sent as multipart automatically — no special method:

```dart
import 'package:http/http.dart' as http;

final bytes = await File('cover.png').readAsBytes();
final rec = await posts.create({
  'title': 'Hi',
  'status': 'draft',
  'cover': http.MultipartFile.fromBytes('cover', bytes, filename: 'cover.png'),
});

// Build a URL to the stored file:
final url = zb.files.getUrl(rec, rec.getString('cover')!, thumb: '100x100');

// Protected files: mint a short-lived access token for <img>/emails:
final token = await zb.files.getToken();
final protectedUrl = zb.files.getUrl(rec, rec.getString('cover')!, token: token);

// Or build a URL without a record object (collection + id explicitly):
final url2 = zb.files.getUrlFor('posts', rec.id, 'cover.png', download: true);
```

An `http.MultipartFile` is single-use (`package:http` finalizes its byte stream once);
construct a fresh instance per `create`/`update` call — reusing one across two calls throws
a `StateError`.

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

// ...or as a Stream, unsubscribing on cancel:
final sub = zb.realtime.stream('posts').listen((e) => print(e.action));
await sub.cancel();
```

A single shared WebSocket multiplexes every topic, auto-reconnects with bounded exponential
backoff, and re-auths from the auth store on login/logout/refresh. Anonymous subscriptions
require a `@public` view rule on the collection (server-enforced). There is no live-store tier
yet (see [docs/dart-sdk.md](../../docs/dart-sdk.md) → Not yet).

Pass `onRealtimeError` to the client to catch a realtime error with no pending subscribe to
reject it (e.g. a rejection delivered after other callbacks already subscribed successfully):

```dart
final zb = ZigbaseClient(
  'http://127.0.0.1:8090',
  onRealtimeError: (error) => print('realtime error: $error'),
);
```

An unconsumed error is never silently dropped: when `onRealtimeError` is omitted, the client
falls back to a visible `dart:developer` log entry instead of doing nothing.

## Error handling

Every non-2xx response throws a `ZigbaseException` carrying `status`, `message`, `url`, and
per-field validation errors in `data`:

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
issuing a new request with a key supersedes any in-flight request sharing that key. **This is
discard, not abort**: `package:http` cannot cancel a live socket, so the superseded call's
`Future` completes with a `ZigbaseCancelledException` while its HTTP request keeps running in
the background — its eventual response is simply discarded on arrival.

```dart
// As the user types, only the latest search's Future resolves; the rest reject.
try {
  final results = await posts.getList(filter: filter, requestKey: 'search');
} on ZigbaseCancelledException {
  // a newer keyed request superseded this one
}
```

## Escape hatch — `send()` and `rawRequest()`

`send()` calls any endpoint the typed surface doesn't cover, returning parsed JSON; the auth
header, retries, and `ZigbaseException` mapping still apply. For a non-GET request, `body` is
always JSON-encoded (`Content-Type: application/json`) unless it contains an
`http.MultipartFile` — even a bare `String` body, which is sent as a quoted JSON string
literal (`"hi"`), not raw text:

```dart
final stats = await zb.send('GET', '/api/custom/stats', query: {'window': '7d'})
    as Map<String, dynamic>;
await zb.send('POST', '/api/custom/reindex', body: {'collection': 'posts'});
```

When you need the **raw `http.Response`** (binary/text bodies, custom headers), use
`zb.rawRequest(method, path, opts)`. It passes through `query`/`body`/`headers` and the auth
header, but does **not** JSON-parse and does **not** throw on non-2xx:

```dart
final res = await zb.rawRequest('GET', '/api/export.csv', query: {'format': 'csv'});
if (res.statusCode == 200) print(res.body);
```
