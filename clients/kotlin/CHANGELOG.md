# Changelog

All notable changes to `zigbase-client` (the Kotlin client) are documented here. The format
is based on [Keep a Changelog](https://keepachangelog.com/), and this package adheres to
[Semantic Versioning](https://semver.org/).

Unlike the ZigBase server's `CHANGELOG.md` (which never carries an `## [Unreleased]` section
between releases), this client changelog keeps one — SDK releases are cut independently and
less frequently, so accumulating entries here between tags is more useful than a
fragment-file pipeline.

## [Unreleased]

Initial development of the official Kotlin client for ZigBase — a behavioral port of
`@zigbase/client` (the TypeScript SDK) to Kotlin/JVM, cross-checked against `zigbase`
(the Python SDK, the hardened normative reference for auth/transport hardening) and
`zigbase_client` (the Dart SDK), built on Ktor and kotlinx.serialization with a
coroutines-first, `suspend fun` API (JDK 17+).

### Added

- **Records.** `CollectionService` CRUD (`getList`, `getOne`, `getFirstListItem`, `create`,
  `update`, `delete`) with offset pagination, and native server-side cursor (keyset)
  pagination (`getPage`, `iterate` — a `Flow<ZbRecord>` — and `getFullList`, which abort with
  a clear `ZigbaseException` rather than looping forever on a non-advancing server cursor).
- **Safe filters.** `zbFilter`/`filterValue` — injection-safe interpolation of `{:name}`
  placeholders into filter expressions, byte-matching the TypeScript/Python/Dart SDKs'
  escaping and number/date formatting (including a from-scratch shortest-round-trip decimal
  formatter reproducing JS `Number.prototype.toString()` on the JVM).
- **Search & vector.** `search` on every list read; `vectorSpec` nearest-neighbor search
  (`-Dvector` server builds).
- **Auth.** Password auth, OAuth2 Authorization-Code + PKCE (`generateCodeVerifier`,
  `codeChallengeS256`), email verification, password reset, self-service `changePassword`,
  and per-device session management (`listSessions`/`revokeSession`/`revokeAllSessions`).
- **Auth stores.** `MemoryAuthStore` (default, in-memory) and `FileAuthStore` (JSON-file
  persistence for CLI/script use across process runs, atomic writes, owner-only `0600`
  permissions).
- **`autoRefresh`.** Opt-in single-flight 401 auto-refresh, safe under concurrent coroutines.
- **Multi-tenancy.** `accountId`/`withAccount(id)` request scoping and
  `AccountsService.activate(id)`.
- **Abilities.** `getAbilities(id)` for per-record view/update/delete permission checks.
- **Analytics.** `AnalyticsService.events`/`.rollup` reads over the tenant-scoped activity
  feed.
- **Senders.** `SendersService.list`/`create`/`verify` for verified From-address management.
- **Files.** `FilesService.getUrl`/`getUrlFor`/`getToken`; `create`/`update` bodies
  auto-switch to `multipart/form-data` when they contain a `FileArg`.
- **Escape hatch.** `send()` (parsed JSON, auth/retry/error-mapping applied) and
  `rawRequest()` (the raw Ktor `HttpResponse`, no parsing or error mapping) for any endpoint
  the typed surface doesn't cover.
- **Packaging.** Published to Maven Central as `io.github.valthon:zigbase-client` (deferred —
  see [RELEASING.md](RELEASING.md)); JDK 17 toolchain, Kotlin 2.4, ktlint-enforced style via
  Spotless.

### Known limitations

- **No realtime tier yet.** WebSocket subscriptions and the live-store
  (`LiveRecord`/`LiveList`) observables ship in a follow-up SDK milestone (KSP2).
- **No typed codegen tier yet.** The generated-schema client (typed record models, an
  injection-safe fluent filter builder, typed collection services) that the Python/Dart SDKs
  ship follows in a later milestone (KSP3).
- **No request-key de-duplication.** The TypeScript/Dart SDKs' opt-in `requestKey`
  last-write-wins cancellation has no Kotlin equivalent yet; use coroutine `Job` cancellation
  (cancel the previous request's `Job` before launching a new one) at the call site instead.

[Unreleased]: https://github.com/valthon/zigbase/tree/main/clients/kotlin
