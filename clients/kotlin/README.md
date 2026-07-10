# ZigBase Kotlin Client

Official Kotlin client for [ZigBase](../../README.md) — REST records, auth, cursor
pagination, and files. A single, coroutine-first `ZigbaseClient` over
[Ktor](https://ktor.io/)'s `CIO` engine and `kotlinx.serialization`, targeting JDK 17+
(Kotlin/JVM; Android/Kotlin Multiplatform are not yet targets — see
[Requirements](#requirements)).

KSP1 (this package's first shipping increment) ships records, auth, files, and the
multi-tenancy/analytics/senders surface. Realtime and a typed codegen tier are **not** in
this release — see [Divergences and what's next](#divergences-and-whats-next).

## Install

**Not yet published to Maven Central** (tracked in [RELEASING.md](RELEASING.md)). Until the
first publish, build it locally into your Maven local repository and depend on that:

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
underlying Ktor `HttpClient` — but only if the client created it itself; see
[Auth + stores](#auth--stores) for the ownership rule when you pass your own.

## Auth + stores

Two stores ship in the box:

- **`MemoryAuthStore`** — the default. Never persists; gone on process exit.
- **`FileAuthStore`** — JSON-file-backed, for CLI/script use across process runs. Loads
  eagerly on construction; an unreadable/missing/malformed file is treated as empty rather
  than raising (repo-wide philosophy: unreadable = nonexistent). Writes are atomic
  (write-temp-then-`ATOMIC_MOVE`) and the file is created with owner-only (`0600`)
  permissions.

```kotlin
import io.github.valthon.zigbase.ZigbaseClient
import io.github.valthon.zigbase.auth.FileAuthStore
import java.nio.file.Path

val store = FileAuthStore(Path.of(System.getProperty("user.home"), ".config/myapp/zb_auth.json"))
val zb = ZigbaseClient("http://127.0.0.1:8090", authStore = store, autoRefresh = true)

zb.authStore.isValid   // local JWT-exp check (UX only -- see security note)
zb.authStore.record    // the authenticated JsonObject, or null
zb.collection("users").authRefresh()
zb.collection("users").logout()   // clears the store

// react to login/logout/refresh anywhere
val unsubscribe = zb.authStore.onChange { token, record ->
    println("auth changed: ${record?.get("id") ?: "(signed out)"}")
}
```

`autoRefresh = true` opts the transport into a single-flight 401 auto-refresh: the first
request that gets a 401 triggers one `auth-refresh` call (concurrent coroutines' 401s join
that same flight rather than each firing their own), and the original request is retried
once with the new token.

### OAuth2 (Authorization-Code + PKCE)

```kotlin
import io.github.valthon.zigbase.auth.codeChallengeS256
import io.github.valthon.zigbase.auth.generateCodeVerifier

val users = zb.collection("users")
val providers = users.listAuthProviders()

val verifier = generateCodeVerifier()
val challenge = codeChallengeS256(verifier)
val state = generateCodeVerifier(32)   // any random string works for state too
// 1. redirect to the provider's authorize URL with `challenge` + `state`
// 2. on the callback, exchange the code:
val auth = users.authWithOAuth2(
    provider = "github",
    code = code,
    codeVerifier = verifier,
    redirectUrl = "https://app.example.com/callback",
    state = state,
)
```

> **Security.** `authStore.isValid` decodes the JWT `exp` **client-side** — it is a UX/expiry
> hint only, never an authorization decision (the server authorizes every request). There is
> no browser-cookie store in this SDK (this is a JVM client, not a browser); for CLI/desktop
> persistence use `FileAuthStore`, ideally pointed at a file with restrictive permissions
> (which it already sets for you).

## Records + safe filters

```kotlin
import io.github.valthon.zigbase.query.zbFilter

val posts = zb.collection("posts")

val page = posts.getList(
    page = 1,
    perPage = 30,
    filter = zbFilter("status = {:s}", mapOf("s" to "published")),
    sort = "-created",
    expand = "author",
)
println(page.items.first().getString("title"))

val post = posts.getOne("REC_ID", expand = "author")
val draft = posts.getFirstListItem("status = 'draft'")   // throws a 404 ZigbaseException if none

val created = posts.create(mapOf("title" to "Hi", "status" to "draft"))
val updated = posts.update(created.id, mapOf("title" to "Edited"))
posts.delete(created.id)
```

`zbFilter` interpolates named `{:name}` placeholders and always single-quotes/escapes string
values against the server's filter lexer — byte-identical escaping to the
TypeScript/Python/Dart SDKs, so any string is representable, including values containing both
`'` and `"`. It is a **reject-don't-coerce** API: it throws `IllegalArgumentException` if
`expr` references a placeholder missing from `params`, **or** if `params` contains a key
`expr` never references — the latter catches copy-paste mistakes early and is stricter than
the Dart port. Build a one-off operand yourself with `filterValue(value)`; array/list operands
are rejected too (expand them into an `||` chain or a native `in (...)` clause yourself —
see the KDoc on `filterValue` for the full type table, including `Instant`/`OffsetDateTime`
date formatting).

`ZbRecord` (returned by every read/write) wraps the raw `JsonObject` with null-safe typed
accessors — `record.id`, `record.getString("title")`, `record.getInt("views")`,
`record.getDouble(...)`, `record.getBoolean(...)`, `record.getStringList(...)`, `record.expand`
— plus `record["key"]` for the raw `JsonElement` and `record.raw` for the whole object.

## Pagination — offset vs. cursor

```kotlin
import kotlinx.coroutines.flow.collect

// Offset: random page access + exact totals.
val p = posts.getList(page = 2, perPage = 30)
p.totalItems   // total across all pages
p.totalPages

// Cursor (keyset): stable under inserts, no deep-offset cost.
var c = posts.getPage(limit = 20, sort = "-created")
render(c.items)
while (c.hasNext && !c.nextCursor.isNullOrEmpty()) {
    c = posts.getPage(limit = 20, sort = "-created", cursor = c.nextCursor)
    render(c.items)
}

// Iterate every matching record as a Flow (stable even while rows are inserted):
posts.iterate(sort = "-created").collect { post -> handle(post) }

val allPublished = posts.getFullList(filter = "status = 'published'")
```

**Which one?** Use **offset** (`getList`) when you need jump-to-page-N or a total count. Use
**cursor** (`getPage` / `iterate` / `getFullList`) for stable feeds and infinite scroll where
deep offsets get slow — the server mints an opaque `nextCursor`/`prevCursor` token the client
just forwards back. `iterate`/`getFullList` throw a status-0 `ZigbaseException` if the server
ever answers with a non-advancing cursor page (a guard against looping forever on a
misbehaving server). Totals are skipped by default in cursor mode; pass `withTotal = true` to
`getPage` to include `totalItems`.

## File uploads & URLs

A `create`/`update` body value that is a `FileArg` — `FileArg.Bytes(filename, content,
contentType?)` for in-memory bytes, or `FileArg.FromFile(file, contentType?)` for a
filesystem `java.io.File` — or a `List` containing any of those, is sent as
`multipart/form-data` automatically. No special method call needed:

```kotlin
import io.github.valthon.zigbase.FileArg

val rec = posts.create(
    mapOf(
        "title" to "Hi",
        "status" to "draft",
        "cover" to FileArg.Bytes("cover.png", coverBytes, "image/png"),
    ),
)

// Build a URL to the stored file:
val url = zb.files.getUrl(rec, rec.getString("cover")!!, thumb = "100x100")

// Protected files: mint a short-lived access token for <img>/emails:
val token = zb.files.getToken()
val protectedUrl = zb.files.getUrl(rec, rec.getString("cover")!!, token = token)

// Or build a URL without a record object (collection + id explicitly):
val url2 = zb.files.getUrlFor("posts", rec.id, "cover.png", download = true)
```

`FileArg.FromFile` reads bytes from disk exactly once, at request-encode time, buffering them
into the request body — a 429-retry can resend the buffered bytes without touching the
filesystem again.

## Error handling

Every non-2xx response throws `ZigbaseException`, carrying `status`, `message`, `url`, and
per-field validation errors in `data`:

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

## Multi-tenancy, abilities, analytics, senders

```kotlin
import java.time.Instant

// Multi-tenancy: a sibling client scoped to one account (X-Account-Id header).
val tenantZb = zb.withAccount("ACCOUNT_ID")
zb.accounts.activate("ACCOUNT_ID")   // sets the signed zb_account cookie for browser apps

// Abilities: per-record view/update/delete permission checks.
val abilities = posts.getAbilities("REC_ID")   // Abilities(view=true, update=false, delete=false)

// Analytics: the tenant-scoped activity feed (requires ZigBase >= 0.9.0).
val events = zb.analytics.events(name = "post.viewed", limit = 50)
val totals = zb.analytics.rollup("daily-signups", from = Instant.parse("2026-01-01T00:00:00Z"))

// Senders: verified From-address management (requires ZigBase >= 0.9.0/0.10.0).
zb.senders.create("noreply@example.com")            // sends a verification email
val verified = zb.senders.verify("SENDER_ID", token) // Boolean
```

`withAccount` returns a sibling client that shares this instance's `authStore` **and**
underlying Ktor `HttpClient` — a login/logout via either is visible to both, and only the
instance that originally created the shared client (i.e. never a `withAccount` sibling)
closes it on `close()`/`use`.

## Escape hatch — `send()` and `rawRequest()`

`send()` calls any endpoint the typed surface doesn't cover, returning parsed JSON (or `null`
for a 204/empty body); the auth header, 401 auto-refresh, and `ZigbaseException` mapping all
still apply:

```kotlin
import io.ktor.http.HttpMethod

val stats = zb.send(HttpMethod.Get, "/api/custom/stats", query = mapOf("window" to "7d"))
zb.send(HttpMethod.Post, "/api/custom/reindex", body = mapOf("collection" to "posts"))
```

When you need the **raw Ktor `HttpResponse`** (binary/text bodies, custom headers), use
`zb.rawRequest(method, path, ...)`. It passes through `query`/`body`/`headers` and the auth
header, but does **not** JSON-parse and does **not** throw on a non-2xx status:

```kotlin
import io.ktor.client.statement.bodyAsText

val res = zb.rawRequest(HttpMethod.Get, "/api/export.csv", query = mapOf("format" to "csv"))
if (res.status.value == 200) {
    println(res.bodyAsText())
}
```

## Coroutines-first

Every I/O method on `ZigbaseClient` and its services is a `suspend fun` — there is no
blocking-facade twin (unlike the Python SDK's sync/async pair). From non-coroutine code
(a `fun main`, a JUnit test, a legacy callback-based framework), bridge in with
`kotlinx.coroutines.runBlocking`:

```kotlin
import kotlinx.coroutines.runBlocking

fun legacyCaller() {
    val record = runBlocking { zb.collection("posts").getOne("REC_ID") }
    println(record.getString("title"))
}
```

Inside an existing coroutine scope (a Ktor server route, an Android `viewModelScope`, a
`CoroutineWorker`), just `await` — no bridge needed. `MemoryAuthStore`/`FileAuthStore` are
internally lock-guarded, so a single `ZigbaseClient` (and its `withAccount` siblings, which
share the same store) is safe to call from multiple coroutines concurrently.

## Divergences and what's next

This is a straight behavioral port of the TypeScript SDK (the wire truth), cross-checked
against the Python and Dart SDKs, but a few things differ by design or aren't here yet:

- **No realtime tier yet.** WebSocket subscriptions and the Dart/TypeScript SDKs'
  `realtime.collection()`/`LiveRecord`/`LiveList` observables are deferred to a follow-up SDK
  milestone (KSP2).
- **No typed codegen tier yet.** The Python/Dart/TypeScript SDKs' generated-schema client
  (typed record models, an injection-safe fluent filter builder, typed collection services)
  is deferred to a later milestone (KSP3).
- **No `requestKey` de-duplication.** The TypeScript/Dart SDKs' opt-in last-write-wins request
  cancellation (`requestKey=`) has no Kotlin equivalent; use structured concurrency instead —
  cancel the previous request's coroutine `Job` before launching a new one at the call site.
- **No per-call `timeout=`/`signal=`.** Configure timeouts (and any other transport policy) by
  constructing your own Ktor `HttpClient(CIO) { install(HttpTimeout) { ... } }` and passing it
  as `httpClient =` to `ZigbaseClient`, rather than a bespoke per-call kwarg — following Ktor's
  own convention (the same posture the Python SDK takes with `httpx.Client(timeout=...)`).
- **Error-message fallback treats a whitespace-only status reason as absent.** When a non-2xx
  response body isn't parseable JSON, `parseErrorResponse` falls back to the HTTP status
  reason phrase (e.g. `"Not Found"`), then to a generic `"Request failed with status $status"`.
  This SDK treats a **blank** (empty-or-whitespace) reason phrase as absent (`isNullOrBlank`);
  the Dart SDK only treats an **empty** string as absent (`isNotEmpty`). Both produce the same
  result for every reason phrase ktor/OkHttp/the JDK's own `HttpClient` ever actually supplies
  (none of them synthesize a whitespace-only one), so this is a defensive divergence with no
  observed behavioral difference in practice — flagged here for completeness rather than as a
  compatibility concern.

## Requirements

- JDK 17+ (Kotlin/JVM; the build's `kotlin { jvmToolchain(17) }`)
- A running ZigBase server (`zigbase serve`) — see the [repo README](../../README.md) to get
  one running locally.
