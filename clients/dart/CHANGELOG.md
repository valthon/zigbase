# Changelog

All notable changes to `zigbase_client` are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/), and this package adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `ZigbaseException.code` — the error envelope's frozen machine code (`not_found`,
  `validation_failed`, `email_not_verified`, …). Branch on this instead of matching
  `message` text, whose wording is explicitly not part of the API contract. It is empty
  when the server sent no code (a non-JSON body, or a response from something that isn't
  ZigBase); an integer `code` from a pre-unification server is ignored rather than
  surfaced. Additive — no existing field changed.

## [0.1.0] - 2026-07-08

Initial release of the official Dart client for ZigBase — a behavioral port of
`@zigbase/client` (the TypeScript SDK) to Dart, for the Dart VM, Flutter, and Flutter web.

### Added

- **Records.** `CollectionService` CRUD (`getList`, `getOne`, `getFirstListItem`, `create`,
  `update`, `delete`) with offset pagination, and native server-side cursor (keyset)
  pagination (`getPage`, `iterate`, `getFullList` — which abort with a clear
  `ZigbaseException` rather than looping forever on a non-advancing server cursor).
- **Safe filters.** `zbFilter`/`filterValue` — injection-safe interpolation of `{:name}`
  placeholders into filter expressions, matching the server's filter lexer byte-for-byte.
- **Search & vector.** `search` on every list read; structured `VectorQuery` nearest-neighbor
  search (`-Dvector` server builds).
- **Auth.** Password auth, OAuth2 Authorization-Code + PKCE (`createPkceChallenge`,
  `randomState`), email verification, password reset, self-service `changePassword`, and
  per-device session management (`listSessions`/`revokeSession`/`revokeAllSessions`).
- **Optional `AuthResponse.record`.** An optional named parameter — it was always nullable,
  but the constructor mistakenly required a value at every call site.
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
  custom-topic subscription. A server-rejected subscribe is dropped (never silently
  re-subscribed on reconnect), a subscribe issued during the reconnect backoff never
  opens a competing socket, and the service is hardened after `close()`
  (`subscribe`/`subscribeTopic`/`stream` throw; pending subscribes are failed).
  `ZigbaseClient(onRealtimeError: ...)` wires an error callback into the client's
  lazily-created `RealtimeService`; it fires for every server error frame, including
  errors also delivered to a pending subscribe call. When omitted, a realtime error is
  never silently dropped — it falls back to a visible `dart:developer` log entry.
- **Live store.** `zb.realtime.collection(name)` returns `LiveRecord`/`LiveList` objects kept
  in sync from realtime events, backed by one shared ref-counted per-collection record cache.
  Pure-Dart observables (synchronous `get()`/`version` + a broadcast `changes` stream, no
  Flutter dependency). Filtered lists pick a two-tier correctness `mode`: `precise` (own-field
  filters — surgical client-side insert/remove/move) or `refetch` (relation/macro filters — a
  debounced single-flight re-fetch). `close()` is mandatory and idempotent; post-close use
  throws.
- **Transport.** One-shot, single-flight 401 auto-refresh (concurrent 401s all await
  the one in-flight refresh and then retry; a refresh endpoint that itself answers 401
  propagates rather than recursing without bound), 429 backoff with `Retry-After`
  support, and opt-in `requestKey` request de-duplication (discard-not-abort semantics
  — see [docs/dart-sdk.md](../../docs/dart-sdk.md#auto-cancellation--requestkey)). Every
  non-GET, non-multipart request body — including a bare `String`/`num`/`bool` — is
  JSON-encoded with `Content-Type: application/json`, matching the TS SDK's
  `JSON.stringify`-everything behavior byte-for-byte; a nested `DateTime` serializes as
  a millisecond-clamped UTC ISO-8601 string (as JS `JSON.stringify` does for a `Date`),
  and any other non-encodable value throws an `ArgumentError`. A query key that
  duplicates one already present in the request path is appended rather than
  overwritten, so both values survive.
- **Errors.** `ZigbaseException` (status/message/per-field `data`) and
  `ZigbaseCancelledException` for superseded `requestKey` requests.
- **Typed tier** (`package:zigbase_client/typed.dart`). The generic runtime a generated
  `zbase.gen.dart` instantiates: `CollectionMeta`/`FieldMeta` descriptors, a fluent filter
  builder (`Expr`, `FieldExpr` family with `eq`/`neq`/`gt`/`like`/`inList`, enum + nested-relation
  support) that compiles to server filter strings, `TypedCollection<T>` (typed CRUD wrapping
  `CollectionService`, mapping records to generated classes), `TypedRealtime<T>`, and int/fixed
  decimal-string coercion helpers (`coerceInt`/`coerceDouble`/`encodeInt`/`encodeFixed`). Generate
  a client with `zigbase typegen --lang dart` (or `zig build gen-client` with a `.dart` output).
