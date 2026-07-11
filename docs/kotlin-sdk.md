# ZigBase Kotlin SDK

The official Kotlin client (`io.github.valthon:zigbase-client`) wraps the ZigBase HTTP REST
API ([docs/api.md](api.md)) in an ergonomic surface: auth + stores, records, offset and cursor
pagination, files, and multi-tenancy/analytics/senders services. It ships one **coroutine-first**
facade — `ZigbaseClient`, over [Ktor](https://ktor.io/)'s `CIO` engine and
`kotlinx.serialization` — every I/O method a `suspend fun`, targeting JDK 17+ (Kotlin/JVM;
Android/Kotlin Multiplatform are not yet targets — see [Requirements](#requirements)).

Like the [TypeScript](typescript-sdk.md), [Dart](dart-sdk.md), and [Python](python-sdk.md)
SDKs, this is a straight behavioral port of the same client contract — same wire format, same
filter-escaping rules, same cursor-pagination semantics — with a few deliberate divergences
called out in [Divergences and what's next](#divergences-and-whats-next), including
[realtime](#realtime)'s scope-ownership divergence. It also ships a generated [typed
tier](#typed-tier): `zigbase typegen --lang kotlin` emits `@Serializable` record models, an
injection-safe fluent filter builder, and typed collection/realtime services over a new
`io.github.valthon.zigbase.typed` runtime.

## Install

**Not yet published to Maven Central.** The publishing workflow (`release-kotlin-sdk.yml`)
is wired up, but the first publish still needs one-time owner setup on Central Portal — see
[clients/kotlin/RELEASING.md](../clients/kotlin/RELEASING.md). Until then, build it locally
into your Maven local repository and depend on that:

```bash
git clone https://github.com/valthon/zigbase.git
cd zigbase/clients/kotlin
./gradlew publishToMavenLocal   # or: mise exec gradle@9.6 -- gradle publishToMavenLocal
```

```kotlin
// your project's settings.gradle.kts or build.gradle.kts
repositories {
    mavenLocal()
    mavenCentral()
}

dependencies {
    implementation("io.github.valthon:zigbase-client:0.1.0")
}
```

(If you're iterating on the SDK itself alongside a consumer project, an `includeBuild(...)`
composite build against `clients/kotlin` avoids the `publishToMavenLocal` round-trip.)

Once published:

```kotlin
dependencies {
    implementation("io.github.valthon:zigbase-client:0.1.0")
}
```

Runtime dependencies: `kotlinx-coroutines-core`, `kotlinx-serialization-json`, and Ktor's
`ktor-client-core`/`ktor-client-cio`/`ktor-client-content-negotiation`/
`ktor-serialization-kotlinx-json` — all pulled in transitively.

## Quick start

Every network call is a `suspend fun`; call it from a coroutine (`runBlocking` bridges from
`fun main` or any non-suspend caller — see [Coroutines-first](#coroutines-first)):

```kotlin
import io.github.valthon.zigbase.ZigbaseClient
import kotlinx.coroutines.runBlocking

fun main() = runBlocking {
    ZigbaseClient("http://127.0.0.1:8090").use { zb ->
        zb.collection("users").authWithPassword("you@example.com", "secret")

        val posts = zb.collection("posts").getList()
        println(posts.items.first().getString("title"))

        val health = zb.health()
        println(health["status"])
    }
}
```

`ZigbaseClient` is `AutoCloseable`; `use { ... }` (or an explicit `zb.close()`) releases the
underlying Ktor `HttpClient` — but only if the client created it itself; see [Auth +
stores](#auth--stores) for the ownership rule when you pass your own.

## Create a client

```kotlin
import io.github.valthon.zigbase.ZigbaseClient

val zb =
    ZigbaseClient(
        "http://127.0.0.1:8090",
        autoRefresh = true,
        authCollection = "users",
    )
```

`ZigbaseClient(baseUrl, ...)` constructor options:

| Option | Default | Purpose |
| --- | --- | --- |
| `authStore` | `MemoryAuthStore()` | Where the token + auth record live. |
| `autoRefresh` | `false` | Retry once on a 401 by refreshing the token (needs `authCollection`). |
| `authCollection` | `null` | The auth collection used for automatic refresh (e.g. `"users"`). |
| `accountId` | `null` | Bakes `X-Account-Id` into every request from this client (multi-tenancy). |
| `lang` | `null` | `Accept-Language` for localized server errors. |
| `maxRetries` | `3` | 429-backoff retry budget. |
| `httpClient` | a fresh Ktor `HttpClient(CIO)` | Override the HTTP transport (tests, connection pooling, custom timeouts — see [Divergences](#divergences-and-whats-next)). |

### Ownership & `close()`

A client constructed without an explicit `httpClient =` **owns** the Ktor `HttpClient` it
builds and tears it down in `close()`; a client built with `httpClient = <your own>` never
closes it — that instance is yours to close. `close()` is idempotent. Using a closed client
surfaces Ktor's own exception on the next request — there is no ZigBase-specific guard.

`withAccount(accountId)` returns a **sibling**: a second `ZigbaseClient` sharing this client's
`authStore` **and** underlying Ktor `HttpClient` (a login/logout on either is visible to both),
scoped to send `X-Account-Id: <accountId>` on every request. Because the sibling is built by
passing this instance's `httpClient` through, it never owns the shared client — only closing
the original (non-sibling) instance actually closes it.

## Auth + stores

Two stores ship in the box:

- **`MemoryAuthStore`** — the default. Never persists; gone on process exit.
- **`FileAuthStore`** — JSON-file-backed, for CLI/script use across process runs. Loads
  eagerly on construction; an unreadable/missing/malformed file is treated as empty rather
  than raising (repo-wide philosophy: unreadable = nonexistent). Writes are atomic
  (write-temp-then-`ATOMIC_MOVE`) and the file is created with owner-only (`0600`)
  permissions, since it holds a live auth token.

```kotlin
import io.github.valthon.zigbase.ZigbaseClient
import io.github.valthon.zigbase.auth.FileAuthStore
import java.nio.file.Path

val store = FileAuthStore(Path.of(System.getProperty("user.home"), ".config/myapp/zb_auth.json"))
val zb = ZigbaseClient("http://127.0.0.1:8090", authStore = store, autoRefresh = true, authCollection = "users")

// password auth — saves {token, record} into the store on success
zb.collection("users").authWithPassword("you@example.com", "secret")

zb.authStore.isValid   // decodes the JWT `exp` locally — UX hint only, see security note below
zb.authStore.record    // the authenticated JsonObject, or null
zb.authStore.token     // the raw JWT

// refresh + logout
zb.collection("users").authRefresh()
zb.collection("users").logout()   // clears the store

// react to login/logout/refresh anywhere; returns an unsubscribe function
val unsubscribe =
    zb.authStore.onChange { token, record ->
        println("auth changed: ${record?.get("id") ?: "(signed out)"}")
    }
```

`autoRefresh = true` opts the transport into a single-flight 401 auto-refresh: the first
request that gets a 401 triggers one `auth-refresh` call (concurrent coroutines' 401s join
that same flight rather than each firing their own), and the original request is retried once
with the new token.

### OAuth2 (Authorization-Code + PKCE)

```kotlin
import io.github.valthon.zigbase.auth.codeChallengeS256
import io.github.valthon.zigbase.auth.generateCodeVerifier

val users = zb.collection("users")

// Discover configured providers (name, authURL, clientId, scopes):
val providers = users.listAuthProviders()

val verifier = generateCodeVerifier()
val challenge = codeChallengeS256(verifier)
val state = generateCodeVerifier(32)   // any random string works for state too
// 1. redirect the user to the provider authorize URL with `challenge` + `state`
// 2. on the callback, exchange the code:
val auth =
    users.authWithOAuth2(
        provider = "github",
        code = code,
        codeVerifier = verifier,
        redirectUrl = "https://app.example.com/callback",
        state = state,
    )
```

`authWithOAuth2` returns an `AuthResponse` with `record = null` — the endpoint sets
`zb_auth`/`zb_csrf` cookies directly and never returns a record.

### Verification + password reset

```kotlin
users.requestVerification("you@example.com")
users.confirmVerification(tokenFromEmail)

users.requestPasswordReset("you@example.com")
users.confirmPasswordReset(tokenFromEmail, "new-secret")
```

### Changing a password (`changePassword`)

*Requires ZigBase >= 0.10.0.*

```kotlin
users.changePassword(userId, "old-secret", "new-secret")
```

A self-service change while already logged in — distinct from the "forgot password" flow
above. It rides `PATCH /records/:id` with `{password, oldPassword}`; the server verifies
`oldPassword` against the target record (non-oracle: wrong/missing `oldPassword` both fail the
same way) and rotates the record's session epoch, dropping every other outstanding session.
When the auth store's current principal *is* the target record, `changePassword` transparently
re-authenticates with the stored identity (`email`, falling back to `username`) and the new
password, so a bearer-token client stays logged in.

### Sessions (`listSessions` / `revokeSession` / `revokeAllSessions`)

*Requires ZigBase >= 0.10.0. `listSessions`/`revokeSession` additionally require the server
to run `App(.{ .auth = .{ .session = .{ .store = .table } } })` — the default `.epoch` mode
has no per-device state to list, and the call surfaces the server's 404 as a
`ZigbaseException`.*

```kotlin
import kotlinx.serialization.json.jsonPrimitive

val sessions = users.listSessions()   // List<JsonObject>, newest first
// sessions[i]["is_current"] marks the one THIS request authenticated with

users.revokeSession(sessions[1]["id"]!!.jsonPrimitive.content)   // log out one other device
users.revokeAllSessions()   // log out everywhere, incl. this device
```

Wire keys stay **snake_case** as received (`last_seen`, `user_agent`, `is_current`) — the SDK
does not remap them into a typed class. `revokeAllSessions()` works in both session-store
modes and always clears the local `AuthStore`, even if the request fails.

### Security notes

- **`authStore.isValid` is not authorization.** It decodes the JWT `exp` claim client-side
  purely so the UI can pre-empt an expired session; the server authorizes every request —
  never gate sensitive logic on `isValid` alone.
- There is no browser-cookie store in this SDK (this is a JVM client, not a browser, unlike
  the TypeScript SDK's `CookieAuthStore`). For CLI/desktop persistence, use `FileAuthStore`,
  ideally pointed at a file with restrictive permissions (which it already sets for you).

## Account scoping (multi-tenancy)

*Requires ZigBase >= 0.9.0 with `.tenancy` enabled.*

```kotlin
// 1. Bake it into the client at creation time.
val zb = ZigbaseClient(url, accountId = "acc_123")

// 2. withAccount(id) — a sibling client scoped to a (possibly different) account.
val tenantZb = zb.withAccount("acc_123")
tenantZb.collection("notes").getList()   // every request carries X-Account-Id: acc_123

// accounts.activate(id) — verify membership + set the zb_account cookie (browser/webview apps).
val scope = zb.accounts.activate("acc_123")
scope["account"]   // "acc_123"
scope["role"]      // the caller's role on that account
```

`withAccount` shares the same `AuthStore` (and underlying Ktor `HttpClient`) as the client it
was derived from, and **replaces** the account id rather than stacking. Per-request
`X-Account-Id` (via `accountId =`/`withAccount`) always wins over the `zb_account` cookie
server-side.

## Records

```kotlin
val posts = zb.collection("posts")

val page =
    posts.getList(
        page = 1,
        perPage = 30,
        filter = "status = 'published'",
        sort = "-created",
        expand = "author",
    )
println(page.items.first().getString("title"))

val one = posts.getOne("REC123", expand = "author")

// create/update — multipart is auto-detected when a body value is a FileArg
val made = posts.create(mapOf("title" to "Hi", "status" to "draft"))
val updated = posts.update(made.id, mapOf("title" to "Edited"))
posts.delete(made.id)

// getFirstListItem — getList(1, 1, skipTotal = true) sugar; throws a synthesized 404
// ZigbaseException when nothing matches
val draft = posts.getFirstListItem("status = 'draft'")
```

Every read/write returns a `ZbRecord` — a thin wrapper over the raw `JsonObject` with
null-safe typed accessors: `record.id`, `record.getString("title")`, `record.getInt("views")`,
`record.getDouble(...)`, `record.getBoolean(...)`, `record.getStringList(...)`, `record.expand`
— plus `record["key"]` for the raw `JsonElement` and `record.raw` for the whole object. Nothing
validates a record's shape against its collection's schema (that's the [typed
tier](#divergences-and-whats-next)'s job in a future release) — every accessor is best-effort
and returns `null` rather than throwing on a missing or mistyped field.

### Safe filters — `zbFilter`

Build filter strings without injection risk using `zbFilter(expr, params)`, which
interpolates named `{:name}` placeholders via `filterValue`. String values are always
single-quoted and escaped against the server lexer (`'`, `\`, and newline/tab/CR are
backslash-escaped); `Int`/`Long`/`Double`/`Float`/`Boolean` render bare; `Instant`/
`OffsetDateTime` become a millisecond-clamped UTC ISO-8601 string. Any string is
representable — including values containing both `'` and `"`.

```kotlin
import io.github.valthon.zigbase.query.zbFilter

val userInput = untrusted   // even `' || 1=1 --` or `he said "hi" to O'Brien` is safely quoted
val filter = zbFilter("status = {:s} && author ~ {:q}", mapOf("s" to "published", "q" to userInput))
val listing = posts.getList(filter = filter)
```

`zbFilter` is a **reject-don't-coerce** API — it throws `IllegalArgumentException` if `expr`
references a placeholder missing from `params`, **or** if `params` contains a key `expr` never
references (the latter catches copy-paste mistakes early; matches the Python SDK's posture,
stricter than the Dart port, which only checks the former).

`filterValue(value)` (`io.github.valthon.zigbase.query.filterValue`) is the single-operand
primitive `zbFilter` calls internally — reach for it directly to build one operand at a time.
Both throw `IllegalArgumentException` on a non-finite `Double`/`Float` or an unsupported type
(`List` operands are ambiguous — expand them yourself, e.g. into an `||` chain or a native
`in (...)` clause). A `Float` widens to `Double` via an *exact* binary32→binary64 conversion,
not decimal re-parsing — see the `filterValue` KDoc if you need JS-`Number` decimal fidelity
from a `Float`.

### Vector search

*Requires ZigBase >= 0.9.0 built with `-Dvector=true`.*

```kotlin
import io.github.valthon.zigbase.query.vectorSpec

val nearest =
    posts.getList(
        perPage = 10,
        vector = vectorSpec("embedding", listOf(0.12, 0.34), metric = "cosine"),
    )
```

`vectorSpec(field, embedding, metric = null)` serializes to the wire's
`<field>[:metric]:<json-embedding>` mini-grammar; it throws `IllegalArgumentException` on a
non-finite embedding element. Vector search is **offset-only** — the server rejects it in
cursor mode. `search` (full-text) is a plain string parameter on `getList`/`getPage`/
`iterate`/`getFullList` and works in both modes.

## Pagination — offset + cursor

```kotlin
// Offset: random page access + exact totals.
val p = posts.getList(page = 2, perPage = 30)
p.totalItems   // total across all pages
p.totalPages

// Cursor / keyset: stable under inserts; ideal for feeds and infinite scroll.
var c = posts.getPage(limit = 30, sort = "-created")
c.items
while (c.hasNext && !c.nextCursor.isNullOrEmpty()) {
    c = posts.getPage(limit = 30, sort = "-created", cursor = c.nextCursor)
}

// iterate every matching record as a Flow (stable even while rows are inserted):
posts.iterate(sort = "-created").collect { post -> handle(post) }

val allPublished = posts.getFullList(filter = "status = 'published'")
```

**Which one to use?** Reach for **offset** (`getList`) when you need jump-to-page-N navigation
or an exact total count. Reach for **cursor** (`getPage` / `iterate` / `getFullList`) for
stable feeds and infinite scroll: it is stable under concurrent inserts and avoids the cost of
deep offsets.

Cursor pagination is **native server-side keyset pagination**. The server mints an opaque
token; the client treats `nextCursor`/`prevCursor` as opaque strings and forwards whatever it
received on the next `getPage` call — it never decodes or synthesizes one. The server skips the
total count by default (the expensive part); pass `withTotal = true` to a `getPage` call to
include `totalItems`. An absent or empty `cursor` requests the first page.

`iterate`/`getFullList` throw a status-0 `ZigbaseException` if the server ever answers with a
**non-advancing cursor page** — an empty page that still claims `hasNext`, or a `nextCursor`
identical to the one just used — a guard against looping forever on a misbehaving server.
`status = 0` on a `ZigbaseException` always denotes this kind of client-side protocol
violation rather than a real HTTP response; see [Error handling](#error-handling).

## Files

A `create`/`update` body value that is a `FileArg` — `FileArg.Bytes(filename, content,
contentType?)` for in-memory bytes, or `FileArg.FromFile(file, contentType?)` for a filesystem
`java.io.File` — or a `List` containing any of those, is sent as `multipart/form-data`
automatically. No special method call needed:

```kotlin
import io.github.valthon.zigbase.FileArg

val rec =
    posts.create(
        mapOf(
            "title" to "Hi",
            "status" to "draft",
            "cover" to FileArg.Bytes("cover.png", coverBytes, "image/png"),
        ),
    )

// build a (optionally thumbnailed) file URL from the record:
val url = zb.files.getUrl(rec, rec.getString("cover")!!, thumb = "100x100")

// short-lived token for protected-file access (<img>, emails):
val token = zb.files.getToken()
val protectedUrl = zb.files.getUrl(rec, rec.getString("cover")!!, token = token)

// or pass collection + id explicitly instead of a record object:
val url2 = zb.files.getUrlFor("posts", "REC123", "cover.png", download = true)
```

`zb.files.getUrl(record, filename, ...)` reads the collection from `record`'s `collectionId`,
falling back to `collectionName`; it throws `IllegalArgumentException` when neither is present
(e.g. a hand-built `ZbRecord` that never round-tripped through the server). `getUrl`/`getUrlFor`
are pure string builders — no request; only `getToken` is `suspend`.

`FileArg.FromFile` reads bytes from disk exactly once, at request-encode time, buffering them
into the request body — a 429-retry can resend the buffered bytes without touching the
filesystem again.

## Abilities

*Requires ZigBase >= 0.9.0.*

```kotlin
val abilities = posts.getAbilities("REC123")
abilities.view     // always true on success — you couldn't have fetched abilities otherwise
abilities.update   // Boolean
abilities.delete   // Boolean
```

**404, not 403, when the record isn't viewable** — a deliberate non-oracle: a
`ZigbaseException(status = 404)` never distinguishes "exists but you lack access" from
"doesn't exist."

## Analytics

*Requires ZigBase >= 0.9.0 (cursor pagination on `events` requires >= 0.10.0).*

```kotlin
import java.time.Instant

val feed = zb.analytics.events(name = "signup", since = Instant.parse("2026-01-01T00:00:00Z"), limit = 50)
feed.items[0]["payload"]   // arbitrary JSON value
if (feed.hasNext) {
    zb.analytics.events(cursor = feed.nextCursor)
}

val rollup =
    zb.analytics.rollup(
        "daily_signups",
        from = Instant.parse("2026-01-01T00:00:00Z"),
        to = Instant.parse("2026-01-08T00:00:00Z"),
    )
rollup[0]["value"]
```

Wire field names stay **snake_case** as the server sends them (`actor_collection`,
`occurred_at`, `computed_at`, …) — `events()` reuses the same cursor-envelope parser
`getPage` does, so its rows come back as `ZbRecord` (index them with `["snake_case_key"]`)
even though they aren't schema-backed records; `rollup()` returns raw `JsonObject` rows
instead, since it isn't paginated. `events()` is 401 for an anonymous caller, returns empty
`items` when there's no active account, and a superuser sees every account's events.
`rollup(name)` is 404 for an undeclared rollup name and 403 when a non-superuser queries a
rollup that isn't grouped by account.

## Senders

*`list` requires ZigBase >= 0.10.0; `create`/`verify` require >= 0.9.0.*

```kotlin
import kotlinx.serialization.json.jsonPrimitive

// request verification — the token is EMAILED to the address, never returned
val pending = zb.senders.create("orders@my-shop.example")
pending["status"]   // "pending" (201) or already-verified (200)

// confirm with the token from the email
zb.senders.verify(pending["id"]!!.jsonPrimitive.content, tokenFromEmail)

// the active account's identities (requires server >= 0.10.0)
val items = zb.senders.list()
items[0]["verified_at"]
```

A re-send of `create()` for the same `(account, email)` within the server's throttle window
throws a 429 `ZigbaseException`. `verify()` returns the `verified` flag from the response body
on success; a wrong token, wrong account, or wrong id throws a 404 `ZigbaseException` — a
deliberate non-oracle that never distinguishes the three.

## Realtime

WebSocket subscriptions need **no extra dependency**. Unlike the Python SDK's
`zigbase[realtime]` extra, `ktor-client-websockets` (plus the CIO engine) ships as a plain
runtime dependency of `zigbase-client` itself — there is nothing to add to your own
`build.gradle.kts`.

```kotlin
import io.github.valthon.zigbase.RealtimeEvent

val unsub =
    zb.realtime.subscribe("posts", filter = "status = 'published'") { event ->
        event.action           // "create" | "update" | "delete"
        event.record.getString("title")
    }
...
unsub()   // stop this callback

// a single record's own topic
zb.realtime.subscribe("posts/$recordId") { event -> handle(event) }
```

`zb.realtime` lazily builds **one `RealtimeService`** per `ZigbaseClient` on first access; it
opens a single WebSocket to `<baseUrl>/api/realtime` (`http`/`https` mapped to `ws`/`wss`) on
the first `subscribe`/`subscribeTopic` call and multiplexes every subscription over it — a
`withAccount` sibling gets its **own**, independent `RealtimeService` (own scope, own socket).
It:

- **auto-reconnects** with bounded exponential backoff (see [Reconnect](#reconnect) below),
- **re-authenticates** from the `AuthStore` on login, logout, and refresh,
- **resubscribes** every surviving subscription after a reconnect.

Anonymous subscriptions are allowed only for collections with a `@public` view rule
(server-enforced, never pre-gated client-side) — a rejected `subscribe`/`subscribeTopic`
throws a `ZigbaseException` out of the call itself. **Known wire-protocol limitation:** the
server keys one subscription per topic per *connection* — subscribing to the same topic
twice with two different filters makes the second filter silently overwrite the first
server-side, so both callbacks then receive the second filter's events.

**Scope ownership (a deliberate Kotlin divergence).** Unlike the Python/TypeScript/Dart ports,
which piggyback on a caller-supplied event loop or scope, `RealtimeService` owns a **private**
`CoroutineScope(SupervisorJob() + Dispatchers.Default)` for its receive loop and
reconnect/re-auth work — you never construct or pass one in. `zb.close()` (non-suspend,
`AutoCloseable`) tears the realtime service down via its non-suspend `shutdown()` before
closing the underlying `HttpClient`. If you're managing a `RealtimeService` directly and want
to `await` its teardown (e.g. in a test), `zb.realtime.close()` — a `suspend fun` — is
available too.

### `unsubscribe`

```kotlin
zb.realtime.unsubscribe("posts", onEvent)   // this callback, every filter variant
zb.realtime.unsubscribe("posts", onEvent, filter = "status = 'published'")   // one exact variant
```

Every `subscribe`/`subscribeTopic` call also returns an unsubscribe function —
`unsub()` is equivalent and saves holding onto the callback/filter yourself.

### `stream()` — cold `Flow`

```kotlin
zb.realtime.stream("posts", filter = "status = 'published'")
    .collect { event -> println("${event.action} ${event.record.id}") }

// stop after the first few events -- unsubscribes automatically on completion:
zb.realtime.stream("posts").take(3).collect { event -> handle(event) }
```

`stream()` subscribes on the **first `collect`**, not at call time (calling it does no I/O by
itself), and unsubscribes when collection ends for any reason: normal completion (`take(n)`),
the collecting coroutine being cancelled, or the whole service being torn down. A subscribe
rejected by the server throws the `ZigbaseException` out of `collect { }` — matching
`subscribe`'s own contract — while a service-initiated `close()`/`shutdown()` ends the flow
**cleanly** instead (no exception). The internal buffer between the subscribe callback and
your collector is **unbounded** — see [Backpressure](#backpressure).

### Custom topics — `subscribeTopic`

```kotlin
import io.github.valthon.zigbase.TopicMessage

val unsub =
    zb.realtime.subscribeTopic("availability") { msg ->
        msg.kind   // "signal" | "message"
        if (msg.kind == "message") {
            msg.data   // the broadcast payload (JsonElement?)
        }
    }
zb.realtime.unsubscribeTopic("availability")

// or as a Flow:
zb.realtime.streamTopic("availability").collect { msg -> handle(msg) }
```

`kind` mirrors the wire frame's `type` field verbatim: `signal` is a re-fetch hint with
`data = null`; `message` carries a payload from a custom route's
`ctx.realtime().broadcast(...)`. Topic subscriptions reuse the same shared-socket machinery
(ack/pending/resubscribe/backoff) as record subscriptions, but take no `filter`.

### Auth lifecycle

On connect, a present `authStore.token` is sent as an `auth` frame **before** any
resubscribe, and every resubscribe is gated on that `auth` reply **settling** — whether the
server's `status` comes back `ok` or `error` — not on it succeeding, so a `@public`
subscription still resubscribes even when auth itself fails. An anonymous open (no token)
resubscribes immediately. Once open, the service's own `authStore.onChange` listener
(registered internally — you never wire this yourself) automatically re-sends a fresh `auth`
frame whenever the token changes: a login re-authenticates the socket, and a logout sends an
empty token (`auth("")`), which de-auths the connection server-side.

**Token expiry is silent.** The server checks the connection's identity against the token's
`exp` claim on every event, but sends no frame when it lapses — the connection just quietly
starts being evaluated as anonymous (or, under multi-tenancy, loses its account scope). If a
session can outlive its token, refresh proactively — e.g. call
`zb.collection("users").authRefresh()` on a timer well before `exp`, rather than waiting for a
rejected read to notice. `authRefresh()` updates the `AuthStore`, and the `onChange` listener
above turns that into a fresh `auth` frame automatically.

Realtime errors — an auth failure, a rejected subscribe, a socket-level error — are all
surfaced through the `onRealtimeError` callback passed to the `ZigbaseClient` constructor
(default: a `System.Logger` warning, so nothing is ever silently dropped):

```kotlin
val zb = ZigbaseClient(url, onRealtimeError = { msg -> logger.warn("realtime: $msg") })
```

This matches the Python SDK's posture — a realtime failure is always routed through
`onRealtimeError`, never by rejecting a `subscribe()`/`subscribeTopic()` call after it has
already returned — and diverges from the TypeScript/Dart SDKs, which swallow a realtime auth
failure silently.

### Reconnect

An unexpected drop (not an explicit `close()`/`shutdown()`) schedules a reconnect after
`min(10_000, 250 shl attempts)` ms — `250ms, 500ms, 1s, 2s, 4s, 8s, 10s, 10s, …` — reset to
the first step after a successful connect. Reconnecting is gated on there being at least one
live subscription left to resurrect the socket for — an idle connection every caller has
already unsubscribed from is never reopened; it re-authenticates first, then resends every
surviving subscription's frame, matching the TypeScript/Dart/Python SDKs.

**There is no event replay.** Any create/update/delete that happened on the server during the
gap is never redelivered on resubscribe, so treat a reconnect as a cue to re-fetch (e.g.
`getList()`/`getFullList()`) rather than assuming the stream picked up exactly where it left
off.

### Backpressure

`stream()`/`streamTopic()`'s internal buffer (between the subscribe callback and your
`collect { }`) is unbounded — a consumer that falls behind the server just grows memory
rather than applying backpressure to sibling subscriptions sharing the same receive loop. The
server already disconnects slow consumers outright, so this is accepted behavior, not an
oversight — matching the Python/TypeScript/Dart SDKs.

### Known limitations

- A still-pending (unacked) `subscribe()`/`subscribeTopic()` call whose subscription is
  removed by a concurrent `unsubscribe()`/`unsubscribeTopic()` to the same topic/filter
  before the server's ack arrives never settles — most often during a reconnect backoff
  window (the entry vanishes before the reconnect can resend its frame), but it can equally
  happen on an already-open, healthy connection.
- Cancelling the coroutine awaiting `subscribe()`/`subscribeTopic()` (e.g. a `withTimeout`
  wrapping it, or the enclosing `Job` being cancelled) while it's still awaiting its ack does
  **not** undo the callback registration — call `unsubscribe()`/`unsubscribeTopic()` explicitly
  to remove it once you're done.
- Callback dispatch is serialized on the service's single receive loop: it awaits each
  callback before decoding the next frame. A callback that itself calls
  `subscribe()`/`subscribeTopic()` for a topic that hasn't been acked yet deadlocks — that ack
  can only be processed by the same receive loop, which is blocked awaiting the callback.

## Error handling

Every non-2xx response throws `ZigbaseException`, carrying `status`, `message`, `url`, and
per-field validation errors in `data` (`Map<String, FieldError>`):

```kotlin
import io.github.valthon.zigbase.errors.ZigbaseException

try {
    posts.create(mapOf("title" to ""))
} catch (e: ZigbaseException) {
    if (e.status == 400) {
        println(e.data["title"]?.message)   // field-level error
    }
}
```

`status = 0` is reserved for a client-side protocol violation with no real HTTP response
behind it — currently, only a non-advancing cursor page (see
[Pagination](#pagination--offset--cursor)).

## Escape hatch — `send()` and `rawRequest()`

`zb.send(method, path, ...)` calls any endpoint the typed surface doesn't cover, returning
parsed JSON (or `null` for a 204/empty body); the auth header, 401 auto-refresh, and
`ZigbaseException` mapping still apply:

```kotlin
import io.ktor.http.HttpMethod

val stats = zb.send(HttpMethod.Get, "/api/custom/stats", query = mapOf("window" to "7d"))
zb.send(HttpMethod.Post, "/api/custom/reindex", body = mapOf("collection" to "posts"))
```

When you need the **raw Ktor `HttpResponse`** (binary/text bodies, response headers, custom
status handling), use `zb.rawRequest(method, path, ...)`. It passes through `query`/`body`/
`headers` and the auth header, but does **not** JSON-parse and does **not** throw on a
non-2xx status:

```kotlin
import io.ktor.client.statement.bodyAsText

val res = zb.rawRequest(HttpMethod.Get, "/api/export.csv", query = mapOf("format" to "csv"))
if (res.status.value == 200) {
    println(res.bodyAsText())
}
```

## Coroutines-first

Every I/O method on `ZigbaseClient` and its services is a `suspend fun` — there is no
blocking-facade twin (unlike the Python SDK's sync/async pair). From non-coroutine code (a
`fun main`, a JUnit test, a legacy callback-based framework), bridge in with
`kotlinx.coroutines.runBlocking`:

```kotlin
import kotlinx.coroutines.runBlocking

fun legacyCaller() {
    val record = runBlocking { zb.collection("posts").getOne("REC_ID") }
    println(record.getString("title"))
}
```

Inside an existing coroutine scope (a Ktor server route, an Android `viewModelScope`, a
`CoroutineWorker`), just `await`/call it directly — no bridge needed. `MemoryAuthStore`/
`FileAuthStore` are internally lock-guarded, so a single `ZigbaseClient` (and its
`withAccount` siblings, which share the same store) is safe to call from multiple coroutines
concurrently.

## Typed tier

Beyond the dynamic base client, `zigbase typegen --lang kotlin` (or the build-time comptime
generator) emits a **typed Kotlin client**: `@Serializable` record data classes with
`fromRecord` wire coercion, `Create`/`Update` payload classes with a `toMap()` wire encoder,
an injection-safe fluent filter builder, typed expand, typed `Flow`-based realtime, and
int/fixed numeric coercion — over a new `io.github.valthon.zigbase.typed` runtime that ships
in `zigbase-client` itself (no extra dependency, unlike the Python SDK's `zigbase[typed]`
extra). It's the Kotlin counterpart of the
[TypeScript](typescript-sdk.md#typed-client--zigbaseclienttyped),
[Dart](dart-sdk.md#typed-tier), and [Python](python-sdk.md#typed-tier) typed clients. Every
generated record/enum/payload is already `@Serializable`, so — unlike Pydantic's free
JSON-Schema export on the Python side — the win here is that these types drop straight into
anything else in your app that already speaks `kotlinx.serialization` (Ktor content
negotiation, disk caching, …) with zero extra annotations.

### Generate

The same generator that emits TypeScript/Dart/Python emits Kotlin — pass `--lang kotlin`:

```bash
# Runtime introspection (no Zig source; reads a provisioned data dir or a live server):
zigbase typegen --data-dir ./zb_data --out ZbaseGen.kt --lang kotlin --package com.example.app
zigbase typegen --url https://api.example.com --admin-email admin@x.io --admin-password '…' \
  --out ZbaseGen.kt --lang kotlin --package com.example.app

# Comptime (reads your Zig schema) via a build step wired with genClientStep's `lang: "kotlin"`:
zig build gen-client   # when the consumer's step passes .lang = "kotlin"
```

The generated file imports the base SDK (`io.github.valthon.zigbase`) and its typed runtime
(`io.github.valthon.zigbase.typed`), so the emitted code stays thin — the same split the
TypeScript/Dart/Python typed tiers use. `--client-name` (default `ZbClient`) renames the
façade class; the `createClient` factory function's name is fixed regardless. Regenerate and
re-run your formatter on the output — this repo formats its own committed golden with
`gradle -p clients/kotlin spotlessApply` — then pass `--check` in CI to fail the build when
the committed file has drifted from the schema, the same staleness-gate recipe as the
[TypeScript generator](typescript-sdk.md#staleness-gate-ci).

**`--package <name>` sets the emitted `package` declaration** (Kotlin-only; ignored for every
other `--lang`). Defaults to `io.github.valthon.zigbase.codegen.dating` (the repo's own golden
fixture's package) so an unqualified invocation keeps the committed golden byte-stable — pass
`--package com.example.app` to target your own project's namespace instead of hand-editing the
generated file's `package` line afterward.

The header comment stamps a `schema-hash` (a content fingerprint — what `--check` actually
compares) and a `typed-core-version` — the `io.github.valthon.zigbase.typed.TYPED_CORE_VERSION`
the emitter targeted (currently `"0.1.0"`). It's a human/tooling compatibility marker, not a
runtime assertion: nothing checks it at import time, so regenerate after any `zigbase-client`
upgrade that bumps `TYPED_CORE_VERSION` rather than relying on it to fail loudly.

### Create a typed client

```kotlin
import io.github.valthon.zigbase.codegen.myapp.createClient

val zb = createClient("http://127.0.0.1:8090")
// authCollection defaults to your schema's auth collection; pass the same kwargs
// ZigbaseClient(...) takes (authStore=..., httpClient=..., ...) for persistence/customization.
```

`createClient` returns a `ZbClient` — one `suspend`-only, coroutine-first façade (Kotlin ships
no sync/async split, matching the base SDK). It exposes one accessor per collection
(`zb.profiles`, `zb.photos`, …) plus a matching realtime accessor per collection
(`zb.photosRealtime`, …) — see [Typed realtime + files](#typed-realtime--files). `zb.raw` is
the underlying `ZigbaseClient` for anything the typed surface doesn't wrap; `zb.close()`
(`AutoCloseable`, so `use { }` works too) tears it down — but only when `zb` owns it, i.e. it
was built via `createClient` (`owned = true`), matching the base client's `close()` ownership
rule.

### Typed records + CRUD

Every read returns a `@Serializable` data class with typed fields; writes take a typed
`Create`/`Update` payload and its `toMap()`:

```kotlin
val profile = zb.profiles.getOne("REC123")
profile.email    // String
profile.age      // Long (an int-mode number field)
profile.gender   // ProfileGender? (a generated enum from the select field)

val created = zb.profiles.create(
    ProfileCreate(email = "a@b.com", password = "secret", passwordConfirm = "secret", age = 28),
)
val page = zb.profiles.getList(page = 1, perPage = 20)   // TypedList<Profile>
val cursorPage = zb.profiles.getPage(limit = 20)          // TypedCursorPage<Profile> (nextCursor/hasNext)
zb.profiles.iterate().collect { p -> ... }                // Flow<Profile>
```

**Schema casing.** Generated members mirror your schema's field/collection names exactly —
the wire key, filter path, and `toMap()` key are never touched. The **only** rewriting is
collision avoidance: a schema name that is a Kotlin keyword (`class`, `object`, …), or that
would clash with a member the generated class already needs, gets a trailing `_` appended on
the **Kotlin side only** (field `class` becomes member `class_`), with a `@SerialName`
carrying the original wire key. Two schema names that would sanitize to the same Kotlin
identifier is a generation-time error naming both, shared with the
TypeScript/Dart/Python emitters (the identifier/guard layer is language-neutral).

### Typed filters — the fluent builder

`where =` takes a lambda over a generated `<Rec>Fields` builder and compiles to a server
filter string. Every operand is escaped through the same `filterValue` the base SDK's
[`zbFilter`](#safe-filters--zbfilter) uses, so a `where =` lambda is exactly as
injection-safe as a hand-built filter string. Kotlin cannot overload `==`/`&`/`|` to return a
non-`Boolean` `Expr`, so operators are `infix` methods and combinators are `infix and`/`or`:

```kotlin
import io.github.valthon.zigbase.typed.and

// scalar + enum + and (`.and`, or nest expressions with `.or`):
zb.profiles.getList(where = { p -> (p.gender eq ProfileGender.FEMALE) and (p.age gte 21) })

// native `in (...)`:
zb.profiles.getList(where = { p -> p.gender.inList(listOf(ProfileGender.FEMALE, ProfileGender.NONBINARY)) })

// one level of nested-relation filtering (owner.username ~ 'a'):
zb.photos.getList(where = { p -> p.owner.rel { it.username like "a" } })
```

Operators: `eq`/`neq` (every field), `gt`/`gte`/`lt`/`lte` (numbers, dates, strings),
`like`/`nlike` (strings), `inList` (a plain method, not infix). A `select` field's
`eq`/`neq`/`inList` also accept `null` for null filtering (`p.gender eq null` ->
`gender = null`), same as every other field. `<Service>.filter(fn)` compiles a `where =`-style
lambda to a plain filter string without issuing a request, when you need the string itself
rather than a request.

### Typed expand

Every generated record with a relation field carries a typed `expand` property (defaulting to
an empty expand instance, so hand-constructing a record in a test never requires building one
by hand); request it with `expand = listOf(...)` and read the related record(s) off it:

```kotlin
val withOwner = zb.photos.getOne("REC123", expand = listOf("owner"))
withOwner.expand.owner   // Profile? (populated when requested)

val withTags = zb.photos.getOne("REC123", expand = listOf("tags"))
withTags.expand.tags     // List<Tag>
```

Kotlin has no way to statically prove "this call requested `owner`", so `expand` properties
are nullable/empty by design — same as the Python and Dart typed tiers.

### Typed realtime + files

```kotlin
// PhotoFields/PhotoFileField are generated symbols, imported from your generated
// file's own package alongside createClient.

// where = takes an already-compiled Expr (build one from the collection's *Fields
// builder directly), or filter = a plain string via <Service>.filter(fn):
val unsub =
    zb.photosRealtime.subscribe(where = PhotoFields().caption.like("cat")) { event ->
        event.action   // "create" | "update" | "delete"
        event.record.caption
    }
...
unsub()

// or as a cold Flow -- subscribes on first collect, unsubscribes on completion/cancellation:
zb.photosRealtime.stream().collect { event -> handle(event) }

// File URLs: `field` is a generated enum of the collection's single-value file fields.
val url = zb.photos.fileUrl(photo, field = PhotoFileField.IMAGE, token = token)
```

Typed realtime wraps the client's single, shared, multiplexed `RealtimeService`
(`zb.raw.realtime`), so there is deliberately no per-collection `close()`: tear down individual
subscriptions with the unsubscribe function `subscribe()` returns (or by ending collection of
a `stream()`), and the connection itself with `zb.close()`. `where` takes precedence over
`filter` when both are given. A `delete` event's `record` is still mapped through
`fromRecord` from an id-only object — its coercer fallbacks tolerate the missing fields, same
as the Python/Dart ports.

### int/fixed numbers

ZigBase `number` fields can be integer or fixed-point. To preserve full i64 precision they
travel as **decimal strings** on the wire; the typed layer coerces both directions — int
fields surface as Kotlin `Long`, fixed fields as `Double`, and `Create`/`Update.toMap()`
serializes them back to decimal strings. Plain float fields are `Double` and pass through
untouched. An int-mode field receiving a value with a fractional part (schema drift) throws
`IllegalArgumentException` rather than silently truncating.

Fixed-point encoding (`encodeFixed`) rounds the double's exact binary value (`BigDecimal(v)`,
not `BigDecimal(v.toString())`) **half-up** to the field's scale, matching the Dart port's
`toStringAsFixed` — not `String.format`'s round-half-to-even default, which would render an
exact tie like `0.125` at scale 2 as `"0.12"` instead of the `"0.13"` this SDK (and Dart)
produce.

### Scope

The typed `rpc.*` (custom routes), auth-method, and feature-flag surfaces are
**TypeScript-only** for now — in Kotlin, call custom routes through `zb.raw.send(...)` and
non-password auth through the base `zb.raw.collection(name)` methods. These are planned
follow-ups, same as the Python and Dart typed tiers. Kotlin ships **one** coroutine-first
typed surface (no sync/async fork, matching the base SDK and the Dart typed tier) and carries
the same [`requestKey`/SSE divergence](#divergences-and-whats-next) as the rest of this SDK.

## Divergences and what's next

This is a straight behavioral port of the TypeScript SDK (the wire truth), cross-checked
against the Python and Dart SDKs, but a few things differ by design or aren't here yet:

- **No `requestKey` de-duplication.** The TypeScript/Dart SDKs' opt-in last-write-wins request
  cancellation (`requestKey =`) has no Kotlin equivalent; use structured concurrency instead —
  cancel the previous request's coroutine `Job` before launching a new one at the call site.
- **No per-call `timeout=`/`signal=`.** Configure timeouts (and any other transport policy) by
  constructing your own Ktor `HttpClient(CIO) { install(HttpTimeout) { ... } }` and passing it
  as `httpClient =` to `ZigbaseClient`, rather than a bespoke per-call parameter — following
  Ktor's own convention (the same posture the Python SDK takes with `httpx.Client(timeout=...)`).
- **Error-message fallback treats a whitespace-only status reason as absent.** When a non-2xx
  response body isn't parseable JSON, the error parser falls back to the HTTP status reason
  phrase (e.g. `"Not Found"`), then to a generic `"Request failed with status $status"`. This
  SDK treats a **blank** (empty-or-whitespace) reason phrase as absent; the Dart SDK only
  treats an **empty** string as absent. Both produce the same result for every reason phrase
  Ktor/OkHttp/the JDK's own `HttpClient` ever actually supplies (none of them synthesize a
  whitespace-only one), so this is a defensive divergence with no observed behavioral
  difference in practice — flagged here for completeness rather than as a compatibility
  concern.

## Integration-test recipe

The SDK's own end-to-end suite (`clients/kotlin/src/integrationTest/`) drives the public API
against a real `zigbase serve` process — the same pattern works for consumer apps that want a
live-server smoke test:

```bash
# 1. Build the server binary once.
mise exec zig@0.16.0 -- zig build

# 2. Point ZIGBASE_TEST_BINARY at it and run the integration test source set.
ZIGBASE_TEST_BINARY="$(pwd)/zig-out/bin/zigbase" \
  mise exec gradle@9.6 -- gradle -p clients/kotlin integrationTest

# Everything else (format/lint/unit tests) stays fast and needs no Zig toolchain:
mise exec gradle@9.6 -- gradle -p clients/kotlin spotlessCheck build
```

The integration suite aborts (JUnit5 "aborted", not "failed") when `ZIGBASE_TEST_BINARY` is
unset, so `gradle build` stays green without the Zig toolchain. The harness launches the
binary on a free loopback port with a fresh tempdir data directory and `--insecure-cookies`,
seeds a superuser via the `superuser create` CLI subcommand, polls `/api/health` for
readiness, and tears the process + tempdir down on teardown.

## Requirements

- JDK 17+ (Kotlin/JVM; the build's `kotlin { jvmToolchain(17) }`)
- A running ZigBase server (`zigbase serve`) — see the [repo README](../README.md) to get one
  running locally.

## See also

- [API reference](api.md) — the underlying HTTP protocol.
- [TypeScript SDK](typescript-sdk.md) — the most mature sibling client, including realtime,
  the live store, and the typed `rpc.*`/auth-method/flags surfaces.
- [Dart SDK](dart-sdk.md) — the Dart/Flutter sibling client, including realtime, the live
  store, and a typed tier.
- [Python SDK](python-sdk.md) — the Python sibling client, including realtime and a typed tier.
- [Recipes](recipes.md) — schema provisioning, owner-scoped rules, signup flows.
- [Tutorial](tutorial.md) — build an app on ZigBase end to end.
