# Changelog

All notable changes to `zigbase_client` are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/), and this package adheres to
[Semantic Versioning](https://semver.org/).

## [0.1.0] - 2026-07-08

Initial release of the official Dart client for ZigBase — a behavioral port of
`@zigbase/client` (the TypeScript SDK) to Dart, for the Dart VM, Flutter, and Flutter web.

### Added

- **Records.** `CollectionService` CRUD (`getList`, `getOne`, `getFirstListItem`, `create`,
  `update`, `delete`) with offset pagination, and native server-side cursor (keyset)
  pagination (`getPage`, `iterate`, `getFullList`).
- **Safe filters.** `zbFilter`/`filterValue` — injection-safe interpolation of `{:name}`
  placeholders into filter expressions, matching the server's filter lexer byte-for-byte.
- **Search & vector.** `search` on every list read; structured `VectorQuery` nearest-neighbor
  search (`-Dvector` server builds).
- **Auth.** Password auth, OAuth2 Authorization-Code + PKCE (`createPkceChallenge`,
  `randomState`), email verification, password reset, self-service `changePassword`, and
  per-device session management (`listSessions`/`revokeSession`/`revokeAllSessions`).
  `AuthResponse.record` is an optional named parameter (it was always nullable, but the
  constructor mistakenly required a value at every call site).
- **Auth stores.** `MemoryAuthStore` (default, in-memory) and `AsyncAuthStore` (persists via
  caller-supplied async callbacks, e.g. `shared_preferences`).
- **Multi-tenancy.** `accountId`/`withAccount(id)` request scoping and
  `AccountsService.activate(id)`.
- **Abilities.** `getAbilities(id)` for per-record view/update/delete permission checks.
- **Analytics.** `AnalyticsService.events`/`.rollup` reads over the tenant-scoped activity
  feed.
- **Senders.** `SendersService.list`/`create`/`verify` for verified From-address management.
- **Files.** `FilesService.getUrl`/`getUrlFor`/`getToken`; automatic multipart encoding for
  `create`/`update` bodies containing an `http.MultipartFile`.
- **Realtime.** `RealtimeService.subscribe`/`subscribeTopic`/`stream` over a single
  auto-reconnecting, auto-reauthenticating WebSocket, multiplexing every collection and
  custom-topic subscription. `ZigbaseClient(onRealtimeError: ...)` wires an error callback
  into the client's lazily-created `RealtimeService`; when omitted, an unconsumed realtime
  error is never silently dropped — it falls back to a visible `dart:developer` log entry
  (matching the TS SDK's `console.warn` fallback).
- **Transport.** One-shot 401 auto-refresh, 429 backoff with `Retry-After` support, and
  opt-in `requestKey` request de-duplication (discard-not-abort semantics — see
  [docs/dart-sdk.md](../../docs/dart-sdk.md#auto-cancellation--requestkey)). Every non-GET,
  non-multipart request body — including a bare `String`/`num`/`bool` — is JSON-encoded with
  `Content-Type: application/json`, matching the TS SDK's `JSON.stringify`-everything
  behavior byte-for-byte. A query key that duplicates one already present in the request
  path is appended rather than overwritten, so both values survive.
- **Errors.** `ZigbaseException` (status/message/per-field `data`) and
  `ZigbaseCancelledException` for superseded `requestKey` requests.
