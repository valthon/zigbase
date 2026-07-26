# Changelog

All notable changes to ZigBase are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and this project adheres to
[Semantic Versioning](https://semver.org/).

## [0.12.0] - 2026-07-26

### Breaking

- The three request-scoped allocator seams are now the typed `zigbase.RequestArena` instead of a bare `std.mem.Allocator`: `RecordEvent.arena` (`ev.arena` in hooks), `Ctx.arena` (`ctx.arena` / `req.ctx.arena` in custom routes and jobs), and `RequestCtx.allocator` (`ctx.allocator`). The allocator itself is the field `.a` on the wrapper, so every place you passed one of these seams to something that wants an allocator, append `.a`: `ev.arena.alloc(...)` → `ev.arena.a.alloc(...)`, `ev.record.object.put(ev.arena, …)` → `ev.record.object.put(ev.arena.a, …)`, `std.fmt.allocPrint(req.ctx.arena, …)` → `std.fmt.allocPrint(req.ctx.arena.a, …)`, `ac.ctx.allocator` → `ac.ctx.allocator.a`. Passing a seam straight through to another ZigBase API that takes a `RequestArena` needs no change; the compiler flags every site that does.

  Why the break is worth it: these arenas die at the end of the request, and the old bare-`Allocator` type made the two easiest lifetime bugs invisible — handing an arena-scoped API a long-lived general-purpose allocator (a leak), or stashing a request arena somewhere that outlives the request (a dangling read). `RequestArena` is constructible only from a real `std.heap.ArenaAllocator` at the boundary that owns it, so the first mistake no longer compiles, and the deliberate `.a` escape hatch makes the second one greppable instead of the default path.
- The dev-only build option `-Ddev-clock` is renamed `-Ddev-mode` (it already gated the frozen clock, seeded entropy, and test-capture; it now also gates the new fake field-crypto). Update any CI/e2e invocation of `-Ddev-clock=…` to `-Ddev-mode=…`.
- A file download URL built with a raw `.auth` session token in `?token=` (rather than a `.file`
  token from `POST /api/files/token`) is no longer authenticated by that token. No first-party
  client did this — the SDKs and admin UI already use `.file` tokens or the auth cookie/header —
  but a hand-built URL relying on the old behavior must switch to a `.file` token.
- `jwt.sign` now returns `error.TokenTooLarge` rather than minting a token that exceeds
  `jwt.max_token_len`, so this module can never produce a token it would itself refuse.
  An application putting more than ~3 KB into the caller-supplied `pl` claim now fails at
  sign time instead of at the next request. Applications within that budget are unaffected.

### Features

- `zigbase.checkSql` / `checkedSql`: comptime validation of raw-SQL table/column identifiers
  against the `.collections` schema, failing the build on an unknown table or a mistyped
  qualified column. Best-effort by design (tables strict, qualified columns checked, unqualified
  columns/functions untouched) to guarantee zero false compile errors on valid SQL — including
  upserts: the `UPDATE` in `ON CONFLICT ... DO UPDATE SET` is recognized as a conflict clause
  (no table operand), not an `UPDATE <table>` statement.
- `zigbase.Query.select`: a comptime, schema-checked single-table SELECT builder that emits
  validated SQL + positional binds for `queryAs` — an unknown table/column is a build error, and
  binds are positional by construction. SELECT-only / single-table in v1 (joins, writes, and `in`
  are noted as future work).
- Official Dart client SDK (`clients/dart`, pub package `zigbase_client`): REST records API with offset + cursor pagination, injection-safe filters, per-collection auth (password, OAuth2/PKCE, sessions), pluggable auth stores, file uploads/URLs, accounts/analytics/senders services, and realtime subscriptions over WebSocket with auto-reconnect. Dart VM, Flutter, and Flutter web.
- **Dart codegen.** The client generator now emits Dart alongside TypeScript. Pass
  `--lang dart` to `zigbase typegen` (runtime introspection) or `zig build gen-client`
  (comptime, via the `genClientStep` `lang` option) to generate a `zbase.gen.dart` — concrete
  typed record classes, per-collection typed services (typed CRUD, a fluent where-builder that
  compiles to server filter strings, int/fixed decimal-string coercion, typed expand, files, and
  realtime) over the base `@zigbase/client` Dart SDK's new `package:zigbase_client/typed.dart`
  runtime. Typed `rpc.*`, auth-method, and feature-flag surfaces remain TypeScript-only for now.
- `zigbase.testing` can now boot apps that declare `.encrypted` fields (#260): pass `StartOptions.field_key` for real AES-GCM, or let it default to a dev-only **fake-encrypt** mode that stores readable `fake:<key>:<value>` at rest (label defaults to `@test@`) so encrypted values are eyeball-able while debugging. Also selectable on `zigbase serve` via `ZIGBASE_FIELD_CRYPTO=fake`. Fake crypto is compiled out of release binaries (the `dev_mode` gate) and its envelopes are mutually unreadable with real ciphertext, so a fake DB can never be served by a production binary.
- Added `jwt.verifyInto` and `jwt.peekClaimsInto`, which decode and verify a token into a caller-provided scratch buffer with **zero heap allocation**. An over-large token fails closed with `error.TokenTooLarge`. `jwt.scratch_size` (16384) sizes that buffer for the measured worst case — escape-heavy claims force `std.json` to copy rather than borrow, and the consumption-to-token-length ratio *rises* with size (>4x at ~5.7 KB), so it covers 14800 bytes for any token within `max_token_len`. The allocator-taking `jwt.verify`/`jwt.peekClaims` remain for callers already holding a request arena.
- `zigbase.jwt`, `zigbase.crypto`, and `zigbase.RequestArena` are now public exports of the framework module, for consumers that need to mint/verify tokens, derive keys, or take the compile-enforced request-arena contract type directly.
- Kotlin client SDK (`clients/kotlin`, Maven `io.github.valthon:zigbase-client` 0.1.0): coroutines-first `ZigbaseClient` covering auth (password, refresh, OAuth2/PKCE, sessions), records CRUD with offset + cursor pagination and an injection-safe filter builder, multipart file uploads, file URLs/tokens, and accounts/analytics/senders services. Realtime and typed codegen tiers follow.
- Kotlin SDK realtime tier (`zb.realtime`, bundled — no extra dependency): ack-gated `subscribe`/`subscribeTopic` with an unsubscribe-function return, `stream()`/`streamTopic()` cold `Flow`s, custom broadcast topics (`signal`/`message`), automatic re-auth from `authStore` on login/logout/refresh, and exponential-backoff reconnection with full resubscribe.
- Kotlin SDK typed tier: `zigbase typegen --lang kotlin` generates `@Serializable` record data classes with `fromRecord` coercion, `Create`/`Update` payloads with `toMap` wire encoding, injection-safe fluent filter builders, and typed collection services (plus Flow-based typed realtime) over the new `io.github.valthon.zigbase.typed` runtime — golden-gated in CI against the dating fixture.
- `zigbase typegen --lang kotlin` gains a `--package <name>` flag that sets the emitted `package` declaration, honored on both the CLI and the comptime `gen-client` build step, so a consumer wiring `genClientStep` with `lang: "kotlin"` targets their own app's package instead of getting an unoverridable namespace in a file marked "do not edit". Unqualified invocations still default to the dating fixture's `io.github.valthon.zigbase.codegen.dating` namespace (keeping the committed golden and `zig build gen-dating-kotlin-client` byte-stable).
- `captcha.Result` and `oauth.discovery.Endpoints` gain a `deinit(allocator)` that frees their
  owned strings, so a result produced with a non-arena allocator can be released. Callers on the
  request-arena path (the usual `ctx.verifyCaptcha`, `resolve`/`parseDocument`) do not need it.
- New `zigbase import` subcommand + `zigbase.Import` library entrypoint: encryption-aware,
  offline (no HTTP server) bulk NDJSON record import that streams and batches through the
  record engine — validation, defaults, `.encrypted` field envelope, and auth password
  hashing all applied — with optional `--upsert-key` idempotency and source-id preservation.
- Python client SDK (`clients/python`, PyPI `zigbase` 0.1.0): sync `ZigBase` and async `AsyncZigBase` clients covering auth (password, refresh, OAuth2/PKCE, sessions), records CRUD with offset + cursor pagination and an injection-safe filter builder, file URLs/tokens, and accounts/analytics/senders services. Realtime and typed codegen tiers follow.
- Python SDK realtime tier (`zigbase[realtime]`): `AsyncZigBase.realtime` with ack-gated `subscribe`/`unsubscribe`, `stream()` async iteration, custom broadcast topics (`signal`/`message`), automatic re-auth on auth-store changes, and exponential-backoff reconnection with full resubscribe.
- Python SDK typed tier (`zigbase[typed]`): `zigbase typegen --lang python` generates Pydantic v2 record models, injection-safe fluent filter builders, and typed sync/async collection services (plus async typed realtime) over the new `zigbase.typed` runtime, golden-gated in CI against the dating fixture. A `select`-typed field's `eq`/`neq`/`in_list` accept `None` for null filtering; a generated record's `expand` attribute (and each relation on its `<Rec>Expand` submodel) defaults to an empty value, so manual instantiation (tests, mocks) never requires building an expand submodel by hand.
- Vendored/native component versions (SQLite, sqlite-vec, zap, facil.io, zigbase) are now
  discoverable via `zig build versions`, the enriched `--version` output + a startup log line,
  and a `versions` object on `GET /api/health`.
- Building against an unsupported Zig version now fails at compile time with a clear
  required-vs-actual message instead of an opaque deep-compilation error.

### Fixes

- Many of the memory-leak fixes below were surfaced by the allocator-ownership migration described
  under **Internal**. They share a shape: the leaked scratch was always reclaimed by the
  per-request or per-job arena a deployed server passes, so running servers were unaffected — but
  the leak was real for a framework consumer calling the same API with a general-purpose
  allocator, and it blinded the leak detector on that path. Each entry says which case it is.
- Static-file range handling: `normalizeRange` no longer leaks its scratch `bytes=a-b`
  string on the already-canonical passthrough path (returned `null` without freeing the
  freshly allocated buffer). A no-op under the request arena every production caller
  passes, but a genuine leak under any non-arena allocator.
- Made several framework helpers self-freeing under any allocator (allocator ownership contracts 1
  & 2), removing latent scratch/result leaks that were reclaimed only when the caller passed a
  request/job arena — as every in-tree call site does, so deployed servers were unaffected, but the
  leaks were real for a general-purpose-allocator caller:
  - `sms/twilio.zig` `TwilioSender.send` now routes its URL/auth/body build **and** the `HttpClient`
    response scratch (a fixed `max_response_bytes` buffer that has no `deinit`) through a
    function-local arena.
  - `analytics/analytics.zig` `runRollup` builds its summary-table/watermark/aggregation-SQL scratch
    on a function-local arena.
  - `api/senders.zig` `listBody` builds its intermediate JSON envelope on a function-local arena
    (only the stringified body escapes).
  - `queue/durable.zig` `claimBatch` self-frees its dynamic `IN (…)` SQL scratch and returns an
    owned `[]Claimed` freed via the new `freeClaimed` (contract-2), with per-row error-path cleanup.
  - `authz/abilities.zig` `abilityPredicate` frees the `allocPrint`-built `"<col>"."<via>" IN (`
    prefix it leaked on every non-empty ability predicate (it was passed straight into
    `appendSlice`, which copies, without freeing the temporary), and adds error-path frees for
    its predicate buffers.
  - `auth/challenge_store.zig` `takeByIdentity` frees its intermediate challenge id (previously
    leaked on every call), and `put` frees the generated id on a mid-insert error.
  - `route_types.zig` typed-route dispatch thunk (`makeThunk`) now frees its params view and — the
    real fix — keeps and deinits the JSON `Parsed` handle it previously discarded (`parseFromSlice(…).value`),
    which leaked that parse arena; only the serialized response body escapes.
- Vector search (`-Dvector`) `build`: on an allocation failure while composing the `ORDER BY`
  distance expression, the already-allocated `WHERE` fragment is now freed (added `errdefer`),
  closing an out-of-memory-path leak.
- A collection field's `hidden` flag is now persisted and round-trips through a reload. It was never written to the stored schema, so every collection load silently reset user fields to `hidden = false` (the API and admin then reported hidden fields as visible); it now survives create/update/get correctly.
- Fixed a memory leak on the auth-collection load path: `get` (and the create/update it now backs) leaked the inner fields array when prepending the auth system columns, on non-arena allocators.
- Fixed a memory leak in the `Data` facade's typed record I/O: `createAs`/`getAs`/`updateAs` parsed the intermediate `std.json.Value` record returned by `create`/`findById`/`update` into `T` but never freed that intermediate, leaking every owned string in the discarded record (~46 allocations per call) on non-arena allocators. The intermediate is now freed after the parse deep-copies into `T`.
- `dumpload.planCreateOrder` (the `migrate load` dependency-order planner) leaked its Kahn-algorithm `placed` scratch buffer on every call. Always masked by the migration's request arena; now freed explicitly.
- `schema_dump.pgColumnType`'s array-type branch (Postgres schema dump, `_<udt>` columns) leaked the base type string it formats into the final `<base>[]` result. Always masked by the per-dump scratch arena; now freed explicitly.
- Fix a memory leak in stored-filename sanitization (`files/naming.zig`): `sanitizeBase` freed its
  scratch `ArrayList` only via `errdefer`, so every successful call leaked the buffer, and
  `storedName` never freed the sanitized intermediate. Latent behind the upload request-arena, a
  real leak under any non-arena allocator. Now contract-1 (`defer`-freed; the return is always a
  fresh copy).
- JWT signing no longer leaks its intermediate buffers when handed a non-arena allocator: `jwt.sign` now frees the payload JSON, both base64 encodings, and the signing input, leaving only the returned token allocated.
- Fix a memory leak in captcha response parsing. `captcha.parseResponse` (reached via
  `ctx.verifyCaptcha`) parsed the provider's JSON with a leaky parser and never freed the
  tree, and returned `Result` fields that borrowed it — including an `errors` slice that was
  an un-freeable sub-slice of a larger allocation. It now frees the parse tree and returns
  independently-owned dupes. Requests served through a per-request arena were unaffected in
  practice (arena teardown reclaimed the tree); the leak bit any caller using a
  general-purpose allocator.
- Fix several memory leaks in the mail subsystem, latent in the request/job-arena path but real
  under any non-arena allocator:
  - Bulk email: `bulk.sendBulk` never freed the per-recipient `vars_json`/durable-job `payload`
    scratch (freed per iteration now that SQLite/enqueue copy it), and `bulk.jobHandler` never
    freed the ~9 fields it rendered per delivery (now routed through a function-scoped scratch
    arena freed on every return path).
  - Inbound webhooks: `suppression.parseProvider`/`mapSes`/`mapPostmark` never freed the provider
    JSON parse tree and returned `Event.email` as a slice borrowed from it (now duped before the
    tree is freed); `inbound.ingest` discarded the suppression `Event` slice without freeing it;
    and `inbound.webhook_handler` leaked its response `ObjectMap`.
- Multipart form-data parsing no longer leaks its per-request delimiter scratch: `files/multipart.parse` allocated two derived boundary-matching strings on every call and never freed them, leaking that memory for any caller that does not pass an arena allocator (the production HTTP upload path is arena-backed, so served requests were unaffected).
- Creating or updating a record with file uploads no longer orphans the uploaded bytes in storage when the write is rolled back (a failed commit, a denied access-rule guard, or a validation error) — the just-written files are now always removed on any pre-commit failure.
- Failures while cleaning up files after a delete/update (e.g. a transient object-store error) are now logged instead of silently swallowed, so orphaned-file accumulation is diagnosable.
- A malformed or out-of-range numeric value in a `filter`, `sort`, or cursor (e.g. `price=99999999999999999999`) now returns `400 Invalid filter or sort.` instead of `500`.
- The request error path no longer risks panicking the server (or invoking undefined behavior in a `ReleaseFast` embed) when the machine is out of memory: rendering a 500 that itself fails to allocate now falls back to a preallocated static error body.
- Malformed `.cron` schedule strings are now rejected at compile time (wrong field count, full day names like `MONDAY`, a trailing/doubled space) instead of silently making a job fire once at boot and then retire without ever running on schedule. The same validation applies to `.auth.session.gc_cron`.
- A cron/interval job whose schedule has no future fire (e.g. an impossible date like Feb 30) is now retired at startup and logged, instead of being treated like a reactive job and run at an arbitrary boot time; jobs that retire for having no next fire are now logged rather than vanishing silently.
- Cron expressions now support the full standard grammar: `<lo>-<hi>/<step>` ranges (e.g. `0-23/2` for every other hour) and day-of-week `7` as a Sunday alias (`0` and `7` both mean Sunday). Out-of-range field values (minute > 59, hour > 23, month > 12, day-of-month `0`, day-of-week > 7, etc.) are now rejected at compile time rather than compiling into a job that silently never fires.
- Typo'd keys in more config surfaces are now a loud `@compileError` instead of being silently ignored: route specs (`.rate_limit`/`.rate_limit_key`/etc.), background job specs, `.auth.methods` and each built-in method's options (`.magic_link`/`.otp`/`.password`/`.webauthn`), `.auth.oauth2` and its provider literals (e.g. `.tokenURL`), collection `.indexes` entries (`.unique`/`.collation`/`.where`), and the `.pools` tuning group.
- Duplicate or empty `.migrations` ids are now a compile error; previously a copy-pasted id silently skipped the second migration on every environment.
- A failure to create the data directory at startup (permissions, read-only filesystem, out of space) is now logged with the path and cause instead of being swallowed and later surfacing only as an opaque database-open error.
- Realtime: a failed `subscribe` is no longer acked to the client as success. Neither a facil.io `subscribe` failure nor a failure to record the just-created transport subscription (under memory pressure) can now strand the client — previously the first left a silent dead subscription and the second left a live subscription a later unsubscribe could never cancel. Both now roll back the logical subscription, log, and return an error frame the client can retry, on both the WebSocket and SSE transports.
- Realtime: a dropped broadcast/signal/message frame (allocation failure on an already-committed write) is now logged with the collection/topic and action, matching the cross-instance paths, so a client-reported "missed update" is diagnosable instead of vanishing silently.
- Realtime (Postgres): cross-instance delete-snapshot and broadcast side-table failures now distinguish a genuinely-absent row (a forged/expired token — a quiet fail-closed drop) from a real database/parse error, which is now logged instead of collapsed into the same silent null.
- Realtime (Postgres): the cross-instance `LISTEN` reconnect backoff now resets only after a connection has stayed healthy for several seconds, and sleeps before reconnecting after a short-lived session. A proxy or mid-failover node that accepts the connection and `LISTEN` but drops it on the first wait no longer drives a zero-delay connect/reconnect loop.
- A write that violates a database integrity constraint — most commonly a duplicate value on a unique field, such as signing up with an email that is already registered — now returns **409 Conflict** instead of **500 Internal Server Error**. Clients, SDKs, and error monitoring can now tell a routine user conflict apart from a genuine server fault. This applies to record create/update, runtime collection create/update, and WebAuthn credential registration, on both the SQLite and Postgres backends. Underneath, the internal database error set gained a distinct `error.Constraint` (SQLite `SQLITE_CONSTRAINT`; Postgres SQLSTATE class 23), raised from the prepared-statement `step()` path instead of collapsing every failure into `error.StepFailed`, so a custom route that lets a `ctx.records()` write propagate surfaces the 409 automatically. **Framework consumers who matched on `error.StepFailed` for a unique-violation race should match `error.Constraint`.** The `exec()`/COMMIT path (including deferred-constraint failures) is unchanged and still reports `error.ExecFailed`.
- Additive `ADD COLUMN` steps in the system migrations (session `token_epoch`, `_collections.options`, `_suppressions.updated`) no longer swallow every error as if it were the benign "duplicate column" case. A genuine DDL failure (lock timeout, disk full, connection drop) now propagates and aborts the migration instead of being recorded as applied with the column still missing — which could permanently break token issue/verify for an auth collection with no migration-based repair. Idempotence now comes from a backend-catalog column-existence check.
- On Postgres builds, a pathological placeholder count in developer-authored raw SQL now surfaces a prepare error instead of panicking the process. This covers both a numbered `?N` with an out-of-range or overflowing index (for example `?10000000` or a 20-plus-digit run), which previously panicked at statement-execution time, and an extreme number of anonymous `?` placeholders, whose running counter is now bounded by the same param cap rather than overflowing the placeholder buffer during renumbering.
- Outbound webhook delivery now bounds the total time one attempt sequence spends sleeping between retries, so a receiver returning a large `Retry-After` (or a long configured backoff) can no longer keep a delivery running past the queue's `visibility_timeout_s` — which previously let the job be re-dispatched as a concurrent duplicate and stalled other jobs on the worker for minutes.
- Fixed a table-name string leak on the out-of-memory error path of the database dump-load (`migrate load`) copy loop.
- S3 storage: the spool cache-fill path no longer leaks the joined cache path for a non-arena caller when the spool directory is unwritable or full; a failed per-object remote delete (orphaning a billed object after its record is gone) and a cache directory that becomes unlistable at runtime (silently disabling spool eviction) are now logged instead of swallowed.
- SMTP mailer: a partially-built CA bundle is freed when a system-trust-store rescan fails mid-load, closing a leak on hosts with a malformed or unreadable certificate.
- `GET /api/features`: an out-of-memory error while rendering the `403 Forbidden` body now propagates to the `500` backstop instead of hitting an `unreachable` (a panic in safe builds).
- Comptime `.migrations` bare-tuple entries now reject an unknown key (a typo'd `.transational`/`.donw` was silently dropped) with a loud `@compileError`, matching every other list-shaped config key.
- Webhook deliveries: at startup, warn about any declared queue whose `visibility_timeout_s` is too small to safely host a webhook delivery's in-handler retry backoff, which could otherwise let the queue re-dispatch an in-flight delivery as a concurrent duplicate.
- The "per-route rate limit cannot identify the client" startup warning now fires once per distinct route pattern instead of once per process, so a second unprotected route is no longer silently skipped from the log.
- Fixed a rare crash where enqueuing a background job (for example an error report) at the moment the in-memory job pool was shutting down could dereference a just-cleared pool pointer and panic the process. `App.submit` now null-checks the pool rather than asserting it, so a submit that races shutdown fails cleanly (the job is dropped) instead of crashing.
- Fix memory leaks in the shared AES-256-GCM envelope (`aead.seal`/`aead.open`) that backs every
  at-rest secret — OAuth client secrets and `.encrypted` record fields. `seal` never freed its
  ciphertext/raw/base64 scratch buffers (three allocations per call) and `open` never freed its
  decode buffer (plus the plaintext on a decrypt-verify failure). Served through a per-request
  arena the buffers were reclaimed at request end, but any non-arena caller (e.g. a batch
  re-encrypt) leaked on every encrypt/decrypt. Now contract-1: all scratch is freed, only the
  result escapes.
- Fix leaks on the OAuth login path: `oauth.client.fetchIdentity` never freed the `Bearer <token>`
  authorization header it built, and `oauth.providers.extractIdentity` never freed the JSON parse
  tree of the provider's userinfo response (leaked on every third-party login).
- `provision.appliedConsumerMigrations`/`recentConsumerMigrations` (the `migrate status`/`migrate rollback` ledger readers) leaked the lowered SQL scratch `Migrator.prepare` builds on every call. Always masked by the CLI's request arena; both now lower onto a function-local scratch arena instead.
- `provision.migrationStatus`'s `orphaned[i].name` was an un-freeable mid-buffer offset into an internal ledger-read array the caller never saw (freeing it directly would have been an invalid free of a non-base pointer) — `MigrationStatus` now dupes every retained string fresh and ships a `deinit`, so the result is a normal owned graph instead of an implicit arena-only value.
- `provision.resolveDiscoveryProviders` leaked its partially-built collection/provider arrays when an OIDC discovery fetch failed mid-batch. Inert in production (the caller aborts startup on this error), but a real leak on any other caller; now freed via a tracked rollback on error.
- Fixed a memory leak when reading or writing `json` and multi-value (`select`/`relation`/`file`) record fields on a non-arena allocator: `readValue` used to return a `std.json.Value` sub-tree from a discarded `std.json.Parsed` wrapper (freeable only under an arena), and `bindValue` never freed the `Stringify` (and encrypted-seal) scratch it allocated. `readValue` now returns a fully-owned, individually-freeable tree, and `bindValue` frees its bind scratch — so `records.freeRecord`/`ListResult.deinit` reclaim a whole record (nested json/array sub-trees included) off any allocator.
- Fix memory leaks throughout the realtime subsystem, latent behind the per-connection/per-request
  arena but real under any non-arena allocator:
  - `realtime/connection.removeSub` used `HashMap.remove`, silently dropping the entry without
    freeing the duped subscription key/filter — a connection that subscribed/unsubscribed
    repeatedly accumulated leaked topics until disconnect. Now `fetchRemove` + explicit frees, with
    a new `Conn.deinit` freeing all remaining subscriptions.
  - Realtime frame building (`protocol.zig`, `ws.zig`, `pg_bridge.zig`, `hub.zig`) leaked scratch
    `ObjectMap`s and JSON stringify/parse buffers on nearly every emitted event/signal/ack frame.
  - `realtime/pg_bridge.decode`/`decodeAny` (the Postgres realtime bridge) parsed with a leaky
    parser and returned struct fields aliased into the never-freed tree; now dupes each field fresh
    with `Event`/`Signal`/`MessageRef`/`Payload` `deinit` methods. Also fixes an unfreed
    delete-snapshot JSON buffer in `storeDeleteSnapshotInner`.
- Fixed a long-standing memory leak in the `Data` facade: `findById`/`create`/`update`/`delete`/`list` loaded the collection metadata via `collections.get` and never freed it, leaking on every call when driven by a general-purpose (non-request-arena) allocator. Record `Value`s now own their top-level keys, so the facade can free the collection safely.
- Fixed a cursor-mode `records.list` result that returned a capacity-padded item slice and left the pagination probe row unfreed — harmless under a request arena but a wrong-size free / leak on a non-arena allocator. The result is now an exact-length owned slice with a `deinit`.
- Fixed a memory leak on the record read path: when an encrypted field failed to decrypt part-way through building a row (fail-closed `error.BadEnvelope`), `records.get`/`getAtRest`/`create`/`update`/`list` leaked the partially-decoded record. `rowToObject`/`rowToObjectAtRest` now free the partial record on a mid-row read error. The same functions also leaked a hidden field's decoded value (read but never stored); that value is now freed too. Both matter for a framework consumer that calls these APIs with a plain (non-arena) allocator.
- `parseCollectionInput` (the runtime collection create/update request parser) leaked its filtered field-array scratch on every call: the intermediate array `fieldsFromJson` returns was discarded without freeing its backing allocation, and a submitted field whose name collided with a reserved system name (e.g. `"email"` on a base collection) leaked that field's own id/name/options dupe entirely. It also leaked the escaping `name`/`fields`/`indexes` themselves on a trailing error path (any of `indexesFromJson`, the rule-string dupes, or `optionsFromJson` failing after they were built) — none of these were reachable via `errdefer` once each value's own local guard went out of scope. All are always masked in production by the request arena; all are now freed explicitly.
- Fixed memory leaks throughout the collection and record write/read paths (`collections.create`/`update`/`delete`, record insert/update/delete, and record reads) when driven by a non-arena allocator. The HTTP request path reclaims this scratch through its per-request arena, but callers that pass a general-purpose allocator — the Postgres backend's collection-cache fallback and direct `Data`-facade use — leaked the DDL, SQL, column-list and `$n` placeholder-rewrite scratch on every call. These operations now free that scratch internally on both success and error paths, and validation failures hand their error list back as an owned, freeable slice, so each operation is leak-correct under any allocator.

### Changed

- `Data.createAs`/`getAs`/`updateAs` now reject a `T` that (recursively) contains a raw-JSON field (`std.json.Value`/`ObjectMap`/`Array`) at **compile time** with an actionable message. `parseFromValueLeaky` (used by these methods) returns such a field as an alias into the intermediate record they now free — which would dangle a string field (use-after-free) — so typed I/O is restricted to concrete field types; use the untyped `create`/`findById`/`update` for raw JSON.

### Performance

- Realtime: per-subscriber event delivery now parses only the three envelope fields it needs (`action`, `record.id`, and the delete-authorization snapshot) with a typed, unknown-field-skipping parse, instead of materializing the entire record body into a throwaway JSON tree for every subscriber. A create/update of a large record fanned out to many subscribers no longer does O(subscribers × record-size) redundant allocation.
- List-endpoint `?expand=` now resolves each relation target's schema once per page and reuses each `(collection, id)` view-authorization decision across rows, instead of re-loading and re-parsing the target collection and re-authorizing on every returned record. This removes redundant `_collections` reads/parses and duplicate rule queries on `GET …/records?expand=…`, most impactful on the Postgres backend where each was a network round trip.
- Realtime delete authorization: the per-subscriber in-memory authorization sandbox for a deleted record is now reused across every subscriber of the same delete event that is served on a given worker thread, instead of being rebuilt once per subscriber. Large delete fan-outs do far less redundant work; per-subscriber authorization decisions are unchanged.
- Pre-size the record-read hot path's growing collections so their backing is allocated once
  instead of reallocating as they fill. `records.rowToObject` (and its at-rest sibling)
  pre-sizes the per-record `std.json.ObjectMap` to id/created/updated + the collection's
  fields; `records.list` pre-sizes its result-item list to the page limit. Measured with
  `zig build bench`, a 30-record list read dropped from ~260 to ~226 allocations per page
  (~13%) — the 512-byte size bucket fell from 38 to 6 — and a single-record read drops an
  allocation. Output is byte-identical (insertion/append order is unchanged), verified by the
  record + cursor-pagination browser tests.

### Security

- Closed an account-enumeration oracle across every token-mail endpoint: OTP **initiate**,
  magic-link **initiate**, `request-verification`, and `request-password-reset`. Each previously
  sent its code/link synchronously and only for an existing (or auto-created) account, so both
  the response timing and a propagated SMTP failure (`500` vs `204`) revealed whether an email
  was registered — and a mailer outage turned the endpoint into a boolean existence oracle.
  Delivery now goes through the non-blocking token-mail queue on all four, so each returns `204`
  with identical timing and status regardless of whether the email matched a record.
- File downloads via the `?token=` query parameter now accept **only** purpose-built `.file`
  tokens (minted by `POST /api/files/token`), not full `.auth` session tokens. A session token
  in a URL query travels into access logs, `Referer` headers, and browser history, so permitting
  it there invited long-lived credentials into those sinks. Session-authenticated downloads
  continue to work via the `Authorization: Bearer` header or the auth cookie.
- Bound JWT token length before any allocation. `jwt.verify` and `jwt.peekClaims` now
  reject a token longer than `jwt.max_token_len` (4096 bytes) as `error.TokenTooLarge`
  as their first statement. Previously nothing on the request path bounded token length,
  while a request body may be `max_upload_size` (50 MiB by default) and a realtime frame
  256 KiB — and because a token is decoded *before* its signature is checked, an
  unauthenticated request could drive allocation proportional to the token it supplied.
- Realtime: a duplicate `subscribe` to a topic a socket already holds now REPLACES its subscription in place instead of stacking a second facil.io subscription. The old behavior let an (even anonymous) client loop subscribes on any public collection to bypass the per-connection `MAX_SUBS` cap entirely, grow per-connection memory without bound, multiply every published event's server-side authorization/delivery work N×, and orphan all-but-the-last facil.io subscription until socket close — a connection-scoped denial-of-service. Applies to both the WebSocket and SSE transports.
- Realtime: a connection can no longer be driven to unbounded memory growth by looping `auth`
  frames — closing an inbound-driven single-connection memory-exhaustion vector. `auth` frames are
  now verified on a throwaway scratch arena, with only a successful identity persisted, and that
  verified identity is held in a dedicated arena reclaimed on each re-authentication. Previously
  every `auth` frame leaked permanently into the connection-durable arena (freed only at connection
  close) — including a garbage token, which allocated during pre-validation claim parsing, so the
  attack needed no credentials at all — and even valid repeated re-authentication grew the
  connection without bound.
- Client-supplied `?filter=` and `?sort=` can no longer reference hidden fields (`passwordHash`, `tokenKey`, `token_epoch`, or any field marked `hidden`). Previously such a query on a non-locked collection turned row presence/absence into a boolean oracle, allowing character-by-character extraction of a per-user server secret the API never serializes. The query builder now rejects hidden fields in client input the same way it already rejects encrypted ones (closed, with a `400`), matching the read layer's visibility rule exactly so no serialized column is affected. Trusted, operator-authored access rules may still gate on a hidden field — a rule is a server-side `WHERE` clause whose truth is never returned to the client, so it is no oracle.
- Per-route rate limiting no longer collapses every client into a single shared bucket when the client cannot be identified (a `.custom` route limit with no `rate_limit_key`, on a directly-exposed server where `ZIGBASE_TRUST_PROXY` is off and the client IP is unknown). Previously one anonymous caller could exhaust the shared bucket and 429 the route for everyone. The bucket is now keyed per client — the app-supplied key function, else the trusted-proxy client IP, else the authenticated principal — and when none of those can distinguish the caller the limit is skipped (fail-open) with a one-time warning rather than enforced as a poisonable global bucket.
- The WebAuthn challenge check now uses the shared constant-time `crypto.timingSafeEql` helper instead of a private byte-for-byte copy, so future hardening of the constant-time primitive reaches the ceremony verification.
- Hardened the fail-closed `deny_locked` authorization floor for Postgres dialect-portability. It
  hardcoded the SQLite-only `0` false-literal (`WHERE 0`), which Postgres rejects
  (`argument of WHERE must be type boolean`); it now uses the dialect's `constFalse()` (`false` on
  Postgres) — the same constant the ability/tenant composition already emits — so the fail-closed
  floor is guaranteed-valid SQL on both backends. (In current code this branch is short-circuited by
  `authorizes` before it reaches a statement, so no live query was affected; the fix hardens the
  path against any evaluator that runs the guard directly.)
- Realtime (WebSocket/SSE) delivery now enforces relationship **abilities**, not just the
  access rule and tenant scope. A collection that was `@public` for its view rule but
  visibility-narrowed by a `view` ability previously delivered every record to every
  subscriber, bypassing the ability on the realtime channel (REST reads were unaffected).
  Effective realtime visibility is now `(rule) AND (ability) AND (tenant)`, matching the
  documented guarantee and the REST list/read paths.
- Record validation now rejects an over-`maxSelect` `relation` or `select` value on the
  element **count**, before running the per-element existence checks. Previously an
  over-limit `relation` array still ran one existence `SELECT` per submitted id under the
  writer lock, so an attacker-sized array (bounded only by the request body limit) could
  drive a large number of queries from input already known to be invalid.
- The runtime collections API now validates `tenant_field` (and `ttl_field`): it must be a valid
  identifier that names an existing field, rejected with an actionable error otherwise. Previously
  a superuser could set an invalid or dangling `tenant_field` via the admin API; because
  `tenancy.scopeApplies` treats an invalid identifier as "scoping does not apply", the tenant-owned
  collection would then be served **un-scoped** — a cross-tenant row leak. The comptime
  `.collections` path already enforced this; the runtime API now mirrors it, keeping the fail-open
  state unreachable.
- `zig build audit` compares pinned dependency versions against a curated in-repo advisory
  table (`docs/security-advisories.md`); documented update process for vendored C security fixes.

### Internal

- **Allocator-ownership contract migration.** CI now ratchets against leak-masked tests
  (`scripts/allocator-allowlist.txt`): a test may wrap `std.testing.allocator` in an arena only
  where the code under test genuinely takes a `RequestArena` (contract 4), and every remaining
  line carries a written justification. Driving that ratchet down took the bulk of this release —
  from 121 files / 889 masked tests at introduction to 44 / 299 — by giving the framework's
  internals explicit ownership contracts: a function either frees all of its own scratch and
  returns one caller-owned value (contract 1), or returns an owned handle with a `deinit`
  (contract 2). Converted subsystems include `records`/`collections`/`schema`/`ddl`, the whole
  `query/` stack (lexer, parser, compiler, joiner, sort, keyset, params), `policy`/`rules`/`authz`,
  `realtime/`, `mail/`, `oauth/` + `aead`, `files/`, `push/`, `provision`, `import`, `codegen/`,
  and the leaf libraries. **This is a correctness change, not a memory or performance
  improvement:** every in-tree caller already passes a request/job arena that reclaimed the scratch
  and still does (an arena-backed scratch arena frees no capacity on deinit), so deployed servers
  are unaffected. The value is that the leak detector can now see these paths, and that a framework
  consumer driving them with a general-purpose allocator no longer leaks. The consumer-visible
  leaks the conversion surfaced are listed under **Fixes**.
- New ownership primitives added along the way, usable directly by framework consumers:
  `schema.Collection.deinit` (plus `freeFieldsOwned`/`freeIndexesOwned` for a standalone
  `[]Field`/`[]Index`), `records.ListResult.deinit`, `query.Joiner.deinit`, `Cursor.deinit`,
  `Guard.own`/`Guard.deinit`, `auth.Verified`/`Authed.deinit`, `tenancy.Resolution.deinit`,
  `features_resolver.Resolved.deinit`, `search.Vector.deinit`, `mail.unsubscribe.Parts.deinit`,
  `provision.MigrationStatus.deinit`/`RollbackOutcome.deinit`/`freeAppliedMigrations`,
  `queue.freeClaimed`, `values.freeValue`, and an `Acquired` handle (`{ arena, collections }`,
  mirroring `std.json.Parsed`) for the codegen acquire adapters. `collections.create`/`update` now
  return a fully-owned reload of the just-written row rather than a mixed-ownership hand-assembled
  value, and record `Value`s returned by `get`/`create`/`update` own their top-level keys, while
  `records.list` interns one shared key set per query (borrowed by every row, freed once via
  `ListResult.deinit`) so the list read path adds no per-row key allocation.
- Un-masking `src/codegen/` (86 tests) surfaced pervasive ownership bugs in the client generators
  that the masking arena had hidden: `identifiers.recordName` returned a sub-slice of an internal
  allocation (freeing it was an invalid free), the shared `emit.putf` format helper leaked at every
  call site, every language generator leaked all of its scratch, and `gen_client.generate` leaked
  the whole generated buffer on its reachable `error.RpcTypeNameCollision` path. All are fixed —
  generators own their scratch internally and return a single caller-owned slice, and the
  `ts`/`dart`/`python`/`kotlin` type mappers return a uniform always-owned string. Generated client
  output is byte-identical (golden snapshots unchanged). This is a build-time tool, so none of
  these bugs affected the shipped server.
- Documented the arena-scoped ownership contract (contract 4) on `http_client.HttpResponse` and
  `DownloadResult`: the response body is a sub-slice of the fixed `max_response_bytes` buffer and
  `request()`/`download()` leave their scratch on the passed allocator, so there is intentionally
  no `deinit` and callers must pass a request-scoped/arena allocator.
- Converted the two JWT verification call sites whose claims are consumed internally
  (`auth.authenticate`, `api/auth.carrySessionCreated`) from the arena-scoped `peekClaims` to the
  caller-buffer `peekClaimsInto`, removing an allocation from the per-request auth path. The
  remaining four sites return borrowed claims and stay on the arena (safely bounded by
  `jwt.max_token_len`). In `authenticate` the peek is scoped to a block so the stack-borrowed
  claims cannot escape into the returned `Authed` — a compiler-enforced guard rather than a prose
  one.
- Added `NO_SLOP.md`, a Zig code-review standard for AI reviewers distilled from Andrew Kelley's
  positions and the official Zig docs, and referenced it from `CLAUDE.md`. Its §4 also records the
  outcome of a data-oriented-design audit of the four structures it names: none is currently
  high-cardinality enough for §4 to apply, so the guidance is now "do not 'fix' these without a
  profile" rather than an open invitation to reflexive DoD.
- Pointed the benchmark harness (`zig build bench`) at the real record read paths for the first
  time (it had only measured the jwt exemplar), reached through a `dev_mode`-gated `internal` seam
  in `root.zig` that folds to `struct {}` in any release build, so it adds nothing to the shipped
  public surface. `data/queryAs-50rows` measures the typed row-decode path (~3 small allocations
  per row); `records/findById-json` and `records/list-json-30` measure the JSON path every REST
  read returns — ~3x more allocations and ~6x more bytes per record than the typed path, and ~8.7
  allocs/record for a batched `list` vs ~13 for individual `findById` (the per-record prepare/SQL
  that N+1 gets each pay). A new `harness.runArena` measures an op under a request-style arena
  reset between iterations: identical allocation count but ~15x faster than raw malloc — which is
  the point, since the allocation count/size distribution is the real backing-independent signal
  while the raw-malloc ns is overhead the arena erases. A `query/filter-compile` benchmark of the
  SQL-injection-critical filter path is a useful negative result: ~24 allocations / ~6us, ~40x
  cheaper than a record list read, confirming filter compilation is not a hotspot.
- Postgres full-text search now concatenates its text-search configuration into the emitted SQL at
  **comptime** (`++`) instead of formatting it with `{s}`. The value lands inside a single-quoted
  SQL literal — an escaping context `schema.isValidIdentifier` does not cover — so making it
  configurable later now fails to *compile* rather than silently opening an injection, and a
  comptime guard additionally rejects a quote or backslash in the literal. The emitted SQL is
  byte-identical (verified by running the new test against the previous implementation). Added
  alongside it, the first unit coverage for the Postgres full-text lowering: `buildPostgres` is
  pure, but nothing asserted its emitted SQL, so the read-side lowering had been exercised only by
  the live-Postgres suites (skipped in a default build).
- `jwt.peekClaims` now rejects a token carrying a 4th segment, matching `jwt.verify`. Not a
  vulnerability (`verify` is authoritative and always refused such a token), but the two parsers
  read the same bytes and should not disagree about what a well-formed token is.
- Added `release-dart-sdk.yml`, a `dart-client-v*`-tag-triggered workflow that verifies
  (`dart analyze`, format check, unit tests, tag/`pubspec.yaml` version consistency,
  `dart pub publish --dry-run`) and then publishes `zigbase_client` to pub.dev via the
  official OIDC-based automated-publishing flow. The first publish still needs one-time
  owner setup on pub.dev — see `clients/dart/RELEASING.md`.
- Pinned `ruff==0.15.21` in the `python-sdk` CI job and the Python SDK release workflow's
  format/lint gates (matching the codegen job), so a floating `ruff>=0.8` release can no longer
  turn a green `main` red on a later PR without any code change — as happened when post-0.15.21
  markdown code-block formatting reflowed `clients/python/README.md`.
- The live SASLprep/SCRAM PostgreSQL tests now skip when the suite role lacks the `CREATEROLE`
  privilege their throwaway login-role fixtures require, instead of failing with an opaque
  `ExecFailed` out of the setup DDL. Running the suite against a plain dev PostgreSQL whose suite
  role is not a superuser no longer reports two misleading SCRAM failures; CI (whose suite role is
  a superuser) still runs them. The module header documents both preconditions and how to point
  `ZIGBASE_PG_TEST_URL` at a privileged role to run them locally.
- Deduplication sweep: consolidated three byte-identical RFC 3986 percent-encoders (captcha,
  Twilio SMS, OAuth token exchange) into one `url.percentEncode`; the copy-pasted JSON body
  plumbing (`parseBody`/`strField`/`jsonResponse`) shared across the auth/OAuth handlers into
  `api/common.zig`; the near-identical `request-verification`/`request-password-reset` handlers and
  the `findByEmail`/`findByIdentity` lookup loop into a single `findByField` helper (preserving the
  subtle nocase / guarded-free memory semantics); `records.zig`'s private `coerceClone` into the
  canonical `values.cloneValue` it was a byte-for-byte copy of; and the record create/update
  file-cleanup block that had been copy-pasted into four return branches into one commit-guarded
  scope guard.
- Hoisted the byte-identical, language-neutral schema-query helpers that the four client emitters
  (`emit.zig`/`emit_dart.zig`/`emit_kotlin.zig`/`emit_python.zig`) each kept their own copy of into
  a single `src/codegen/schema_query.zig`. The visible auth fields are now derived from the
  canonical `schema.authSystemFields()` (filtered to its non-hidden subset) rather than a
  hand-maintained triple in each emitter, so a new non-hidden auth system field flows into every
  generated SDK automatically instead of silently diverging until all four copies are edited. Pure
  refactor — generated client bytes are unchanged. Also corrected the Dart/Python/Kotlin generator
  module docs, which claimed the shared identifier guard is "language-neutral": it is TS-derived
  (TS identifier validity + the TS typed-core reserved-name set) and applied to every language as a
  conservative lowest common denominator, with the actual per-language keyword/member sanitizing
  living in each emitter.
- `records.last_errors` (the validation-detail threadlocal) is cleared once consumed, so it never
  outlives the per-request arena it points into. `gcExpiredRecords` (the TTL sweep) allocates its
  per-collection scratch from an internal arena, and system migration 0010 allocates its
  collection-name scratch from the run-scoped migrator arena instead of `std.heap.page_allocator` —
  restoring `std.testing.allocator` leak visibility for both paths and removing ~15 lines of manual
  cleanup from the latter.

## [0.11.0] - 2026-07-07

### Breaking

- The `onBootstrap`/`onBeforeServe`/`onBeforeTerminate` lifecycle hooks now return `anyerror!void` (was `void`) — update existing hook signatures (a `fn (...) void` no longer coerces). A returned error from `onBootstrap`/`onBeforeServe` fails the boot; an `onBeforeTerminate` error is logged (it fires in a shutdown defer).

### Features

- Admin UI: `editor` fields now use a rich-text WYSIWYG editor (bold, italic, headings, lists, links, blockquote, inline code) that stores sanitized HTML, and `json` fields use a code editor with live validation, a Format button, and Save disabled while the JSON is invalid.
- App-scoped context: declare a context type at comptime with `App(.{ .app_context = T })`, install it once in `onBootstrap` via `ctx.setAppData(T, &value)`, and read it anywhere (handler/hook/job/cron) as a `*T` with `ctx.appData(T)` — one explicit, typed handle replacing module-level globals + bootstrap setter rituals. Declaring `.app_context` makes setting it a boot contract (the server refuses to start if `onBootstrap` never installs the handle); apps that don't declare it pay nothing.
- Route-level auth-collection gating: `.auth = .{ .authed = "<collection>" }` requires a route's principal to belong to a specific auth collection (with an optional `.allow_superuser = true` to additionally admit superusers). The gate is **fail-closed** — a token from any other collection, a superuser without opt-in, or an empty-id principal is rejected with the same `401` as no token at all (no oracle) — and **comptime-validated**: the named collection must be declared in `.collections` and be of `.type = .auth`, else the build fails. Plain `.authed` still accepts any authenticated principal.
- New `App(.{ .collections_frozen = true })` config key asserts that collections do not change after boot + migrations. Frozen apps get the parsed-collection-metadata cache on **every** backend — including Postgres, where it is otherwise skipped because a concurrent instance could `ALTER` collections unseen — and the runtime collection create/update/delete endpoints return `403` (schema then evolves via `.migrations` + a redeploy). Default `false` leaves today's behavior unchanged (cache SQLite-only, DDL endpoints live).
- Cron expressions now accept case-insensitive 3-letter month (`JAN`..`DEC`) and day-of-week (`SUN`..`SAT`) names in the month and day-of-week fields (e.g. `"0 9 * * MON-FRI"`), in addition to numbers. Steps (`*/n`) remain numeric.
- Pluggable error reporter: the terminal backstop every framework-swallowed error routes through is now a swappable plugin selected via `App(.{ .reporter = MyReporterPlugin })`, mirroring `.storage`/`.mailer`. The default picks `SentryReporter` when `ZIGBASE_SENTRY_DSN` is set (POSTs a Sentry envelope) and `LogReporter` otherwise (a structured backstop line `[phase] err_name: message`); a custom plugin implements `create`/`interface`/`deinit` and returns a `Reporter` whose `report` receives a `Report{ .message, .err_name, .phase, .level }` (the `Reporter`, `Report`, `LogReporter`, `SentryReporter`, and `DefaultReporterPlugin` types are re-exported). Consumers route their own swallowed-but-notable errors through the SAME backstop with `ctx.reportError(err, "fmt", .{args})` — the `onError` handler then the reporter — tagged with the new `.app` error phase; it is best-effort and non-failing (never blocks or fails the caller, swallows its own allocation failure) and works from a route handler, hook, job, or cron.
- Error reports deliver **non-blocking** with TTL dedup: the Sentry POST is enqueued on the in-process memory queue and performed on a pool worker — never inline on the thread that swallowed the error and never on the DB writer, so reporting never blocks a request/job/cron path (a failed POST is logged and dropped, never retried into a loop). A repeat of the same `(message, phase)` within `App(.{ .reporter_dedup = .{ .window_s = 60 } })` (the default) is suppressed so a hot error path reports once per window instead of flooding Sentry; `.reporter_dedup = .off` reports every swallowed error and compiles the dedup map out entirely.
- Record read endpoints (`GET` list and get-one) accept a `fields=` query param for response projection: a comma-separated list of dot-paths selects which keys are returned (e.g. `fields=id,title,expand.author.name`), with `*` for all keys at a level and a leading `-` to exclude. Projection descends into `expand`ed relations (objects and arrays) and is a pure output filter applied after expand and access rules — it can only narrow a response, never reveal a field the record wouldn't otherwise return.
- Programmatic list filters accept bound placeholder values: put `?` tokens in `filter` and pass a parallel `filter_args` slice (`ctx.records().list(...)`). Each `?` binds its value (`.string`/`.int`/`.float`/`.bool`/`.null`) as a literal SQL parameter that is never re-parsed as filter grammar — the injection-safe way to splice a runtime value into a filter. A placeholder is coerced by the target field's type exactly as an inline literal would be (so `price = ?` with `.{ .float = 5.0 }` matches the same rows as `price = 5.00`). Placeholders bind 0-based left-to-right; a placeholder-count vs. `filter_args.len` mismatch is a loud `error.BadFilter` (so a stray `?` on the REST `?filter=` path fails closed).
- Mail: `ctx.mail()` messages can now carry file **attachments** (#219) — set `MailMessage.attachments` to a slice of `{ filename, content_type, data }` (the canonical use is a `.ics` calendar invite). The message body is wrapped in `multipart/mixed` with one base64 part per attachment; the default (`&.{}`) leaves existing mail byte-for-byte unchanged. Attachments ride through every backend (SMTP/Command get the raw MIME, SES switches to Raw MIME, Postmark uses its native `Attachments` array) and survive the durable queue round-trip. `filename`/`content_type` are CRLF/control-char checked, and a new `.mail.max_message_bytes` cap (default 10 MiB) rejects an over-sized `send`/`enqueue` at the call site with `error.MailTooLarge`. Only `cid:` inline images remain unsupported.
- `zigbase migrate dump [--out <file>]` introspects the **live database** and writes a canonical, dialect-native `structure.sql` (stdout by default; `--out` writes a file). SQLite emits the exact stored DDL; Postgres reconstructs it from the system catalogs — **no external `pg_dump`**. The output is deterministic (no timestamps) so it diffs cleanly and re-runs to recreate the schema for a fast test DB; it also emits the applied-migration ledger so a restore lands at the same migration state. It is a snapshot for inspection/diffing/test-setup, NOT a schema source (that is `.collections`), and is never loaded at boot. This completes the `migrate` CLI trio alongside `status` and `rollback`.
- `zigbase migrate status` reports your comptime `.migrations` as applied (with the ledger timestamp) or pending in declared order, and separately flags orphaned ledger rows — applied migrations no longer present in the binary — with a concise `N applied, M pending, K orphaned` summary. It reads the `_migrations` ledger only and applies nothing.
- `zigbase migrate rollback [N]` reverses the N most-recently-applied consumer migrations, newest first (N is a positional integer, default 1); system migrations are never touched. The reverse of a migration is `down orelse change` (the mirror of the forward `change orelse up`): an explicit `down` runs as-is, otherwise the `change` re-runs inverted. Each migration's reverse body and its ledger-row delete commit in one transaction (honoring `.transactional`), so re-applying afterward works. It fails loudly and changes nothing it cannot undo: a lone-`up` migration, a non-transactional `change`, or an orphaned ledger row is refused; a `change` that reverses into an irreversible op (`raw`/`records()`/a `.was`-less drop, or `addForeignKey` on SQLite) is rolled back by its transaction and named. `N` beyond the applied count rolls back all of them.
- Migrations gain a dialect-aware schema DSL (`m.createTable`/`addColumn`/`addIndex`/`renameColumn`/`addForeignKey`, …) and auto-reversible `change` migrations: write the forward change once and it inverts for rollback. `up`/`down` remain for irreversible steps; a per-statement `m.raw(.{ .sqlite, .postgres })` breakout and records-aware `m.records()` data transforms (#241) round it out. Migrations stay transactional by default with a per-migration `.transactional = false` opt-out. (A schema dump lands next.)
- `data.queryAs(T, conn, alloc, sql, args)` (and the `ctx.records().queryAs(T, sql, args)` wrapper) decode raw-SQL result rows into a struct `T` by matching each field to the result column of the **same name** (respecting `AS` aliases) instead of by position — so a reordered or newly-inserted `SELECT` column can no longer silently misalign a hand-written `columnText(n)` mapping. Args bind positionally (`?1..?N`, rewritten to `$n` on Postgres); fields decode by Zig type (`[]const u8`, integers, floats, `bool`, and `?T` over nullable columns, with SQL `NULL` → `null`); extra result columns are ignored; a non-optional field with no matching column errors with `error.ColumnNotFound`. Works on both the SQLite and Postgres backends.
- Optional S3 presigned-URL serving: with the comptime `App(.{ .files = .{ .s3_presign_redirect = true } })` option, authorized file downloads on the S3 backend are served as a 302 redirect to a time-limited presigned GET URL (`s3_presign_ttl_s`, default 900s) instead of proxying the bytes through the server — offloading bandwidth/CPU. Default is unchanged (proxy). Authorization still runs per-request before the redirect; the issued URL is a bearer capability valid until it expires.
- `ctx.sms()` — transactional SMS, the outbound-text analog of `ctx.mail()`. `ctx.sms().send(.{ .to, .body })` delivers synchronously and `ctx.sms().enqueue(...)` rides the background queue for durable retry/backoff. Provider is pluggable behind an `SmsSender` vtable (**Twilio** first, via `App(.{ .sms_provider = … })` or the `ZIGBASE_TWILIO_ACCOUNT_SID`/`_AUTH_TOKEN`/`_FROM` env vars); unconfigured it is a network-free logging no-op, so dev/CI need no credentials. Framework-owned E.164 normalization/rejection runs before any byte reaches a provider or a queue row (`.sms = .{ .default_region = .us }` sets the country code prefixed onto national numbers). Ships a `CaptureSms` in-memory test double for asserting sent messages with no network.
- Static file serving now percent-decodes the request path, so files whose names need encoding (e.g. `my%20file.pdf`) are servable. Decoding is single-pass and happens before the traversal checks, so encoded traversal (`%2e%2e`, `%2f`, `%00`, `%5c`) is decoded and then rejected fail-closed, and double-encoding is never recursively decoded; the symlink guard is unchanged.
- In-process test harness (`zigbase.testing`): boot a comptime-configured `App(.{...})` against a throwaway tempdir data dir and inject requests through the REAL pipeline — the same router, access rules, auth, hooks, and custom routes the socket server runs — with no socket, port, or background threads. `testing.start(App, .{})` runs migrations + `onBootstrap`; `t.request(method, path, .{ .json = .{...}, .auth = bearer })` returns a genuine response you assert on and parse via `r.json(T)`. Auth helpers cover both fidelities: `mintSession` (direct deterministic JWT) and `loginPassword`/`loginSuperuser` (the real auth-with-password endpoint); `createSuperuser`/`createRecord` seed rows and `captureMail` swaps in an in-memory mailer to assert outbound mail. See docs/framework.md §15.
- The TTL garbage-collection sweep cadence is now configurable via the comptime `.ttl_gc_interval` App config key (a `schedule.Interval`, default `.{ .minutes = 5 }`); expired rows are still hidden from reads immediately regardless of sweep cadence.
- `ctx.txWith(T, payload, fn)` (#237) — a `ctx.tx` companion that threads a caller-supplied payload directly into the transaction callback, so a route/hook/job that needs request data inside a transaction no longer has to smuggle it through a `threadlocal` global.
- Typed record I/O on the records handle: `ctx.records().createAs(T, col, .{…})`, `getAs(T, col, id)`, and `updateAs(T, col, id, .{…})` reflect a plain Zig struct into a write and parse the resulting record back into `T` — no more hand-assembling `ObjectMap`s or unwrapping union tags. Struct fields map to schema fields by name, optionals map to nullable columns, and every literal field is comptime-verified to exist on `T` (a typo is a build error). The `std.json.Value` API stays for dynamic callers.
- **Web Push notifications (`ctx.push()`, #223).** Send browser push notifications with RFC 8291 (`aes128gcm`) payload encryption and RFC 8292 VAPID authentication. `ctx.push().send(subscription, message)` returns a tri-state (`.delivered` / `.gone` / `.failed`) so a dead subscription (HTTP 404/410) is pruned and never retried; `ctx.push().enqueue(...)` delivers durably in the background via the built-in `"push"` job kind (registered when `.push` is configured). Enable with `App(.{ .push = .{ .subject = "mailto:ops@example.com" } })` plus a VAPID keypair in `ZIGBASE_VAPID_PUBLIC_KEY` / `ZIGBASE_VAPID_PRIVATE_KEY`; without the keys `ctx.push()` is a network-free logging no-op. New CLI subcommand `zigbase vapid-keygen` generates a keypair.

### Fixes

- The standalone `WriterData`/`ReaderData` DB-access handles (`ev.writer()`/`ev.reader()`) no longer leak on the process allocator: their `data()` accessor now allocates on an arena OWNED BY THE HANDLE, so a record op's collection metadata, SQL scratch, and returned records are all freed together when the handle's `deinit()` runs. Results are valid until `deinit()`. (`ctx.records()` was never affected — it already uses the per-request arena.)
- Setting `.auth.session.gc_cron` without `.auth.session.store = .table` is now the compile error it was always meant to be. The guard lived in a lazy comptime value referenced only by the `.table`-mode session-GC job, so in the misuse case (`.epoch` store) it was never analyzed and the misconfiguration silently compiled and did nothing; it now fails loudly at build time.
- `.int` and `.fixed`-mode `.number` fields now accept a JSON **number** on write, not only a string — symmetric with reads, which return a string. `price_cents = 500` and `price = 5.0` (scaled to a `fixed` field) bind correctly instead of failing validation; a fractional float on an `.int` field is still rejected.

### Changed

- `zigbase migrate` now applies the app's comptime `.migrations` (the consumer escape-hatch migrations) after the system migrations, so migrating from the CLI ahead of a deploy applies the same migration pass the server would. Previously `migrate` applied only the built-in system migrations. (Collection tables from `.collections` are still provisioned when the server starts, not by `migrate`.) It remains idempotent (already-applied migrations are skipped via the `_migrations` ledger).
- The S3 spool cache now bumps an entry's mtime on a cache hit, so size-triggered eviction approximates last-access LRU (a frequently-read file survives over a rarely-read newer one) instead of being purely create-time ordered. `-Ds3` builds only.

### Performance

- Feature-state resolution (`ctx.flags().resolveAll` / the public `/api/state` projection) now reads every sticky experiment's persisted assignment in a **single** batched query, so a resolve is a constant 2 queries regardless of how many `.sticky` experiments an app declares (previously 1 + N — one assignment read per sticky experiment). Variants and miss-persist behavior are byte-identical; the single-accessor `App.experiment` path is unchanged.
- Steady-state feature-flag and experiment resolution now costs **zero `_kv` reads**: an in-process cache serves the current `flag:*` / `exp:*:weights` override set to both `ctx.flags().resolveAll` and the per-flag/`App.flag`/`App.experiment` lookups. A same-instance override write (`App.setFlag`, the admin settings verbs) invalidates it instantly, so a kill-switch flip still takes effect on the next request; on Postgres, another instance's write self-heals within a 5 s staleness bound (so it runs on both backends, unlike the SQLite-only collection cache).
- Custom-route dispatch now skips authentication resolution — and its pooled reader acquire — on credential-less requests (no bearer header and no `zb_auth` cookie). `authenticate` already returns null in that case, so the reader round-trip was pure overhead on the highest-volume shape most apps serve (anonymous traffic on public routes); hoisting the credential check above the acquire lowers the per-request floor and cuts reader-pool contention for the requests that actually need a connection. Semantics are unchanged — `.authed`/`.superuser` routes without credentials still 401/403.

## [0.10.0] - 2026-07-04

### Breaking

- Auth configuration is now grouped under one comptime `App(.{ .auth = .{ … } })` key. The previously-scattered top-level auth keys moved under it:
  - `.auth = .{ .beforeRegister = fn, … }` (the flat lifecycle-hook group) → `.auth = .{ .hooks = .{ .beforeRegister = fn, … } }`
  - `.auth_methods = .{ … }` → `.auth = .{ .methods = .{ … } }` (both the bare-tuple and `.{ .builtins, .custom }` forms)
  - `.captcha = .{ .provider, .secret }` → `.auth = .{ .captcha = .{ … } }`
  - `.session_store = .epoch | .table` → `.auth = .{ .session = .{ .store = … } }`
  - `.session_gc_cron = "…"` → `.auth = .{ .session = .{ .gc_cron = "…" } }`
  Each old spelling is now a pointed `@compileError` naming its new location, so consumers get an actionable migration message rather than a silent no-op. Runtime auth knobs (`ZIGBASE_AUTH_TOKEN_TTL`, `ZIGBASE_OAUTH_STATE_*`, cookie security, `ZIGBASE_RATE_LIMIT_*`) intentionally remain env-configured and are **not** part of the `.auth` group.
- `beforeAuthSuccess` now fires on the legacy `POST …/auth-with-password` and `POST …/auth-refresh` routes — **including `_superusers`** (the admin SPA login). A hook that errors unconditionally will lock superusers out of the admin UI (fail closed, by design); fix the hook and rebuild.
- `events.AuthMethod` gained a `.refresh` variant; exhaustive `switch`es over the enum must add an arm (compile error).
- Custom-route surface: `http.Response.file_path` is now `Response.file` (`.file_path = p` → `.file = .{ .path = p }`). Plain-path delegation behavior is unchanged; the new optional `offset`/`len` window enables handler-planned partial responses.
- Postgres backend (`-Dpostgres` builds): the default `sslmode` for `postgres://` URLs is now **`verify-full`** (the server certificate chain and hostname are verified — see the TLS entry under Security). A server without TLS (e.g. a docker-compose dev database) now fails **at startup** with an error naming the one-parameter fix: append `?sslmode=disable` (plaintext) or `?sslmode=require` (encrypted, unverified) to `ZIGBASE_DB_URL`. Explicitly configured modes below `verify-full` keep working and log one startup warning.
- Side-effect auth successes are now uniform **204 No Content**: `confirm-verification` (was `{"verified":true}`), `confirm-password-reset` (was `{"success":true}`), `webauthn/register/finish` (was `{"registered":true}`). Treat any 2xx as success; `@zigbase/client` types updated to `Promise<void>`.
- The magic-link consume URL is now dash-case: `GET …/auth/magic-link/consume` (was `auth/magic_link/consume`). Hard cutover — links emailed by pre-upgrade servers 404 (tokens are short-lived). The method slug (`/auth/magic_link/initiate|complete`, `onAuth` tag) is unchanged.
- The built-in job kinds are now config-gated (embedded consumers): `ctx.webhook` requires `.webhooks = true`; `ctx.mail().enqueue` requires `.mail` (use `.mail = .{}` for defaults) or a `.mailer` plugin. Without the key the kind is not compiled in and enqueue fails loudly with a hint. Direct mailer delivery (verification/password-reset emails) is unaffected. The kind names `mail`/`webhook` remain reserved either way.
- Removed the legacy `.jobs = .{ .pool_size = N }` spelling; set `.pools = .{ .jobs = N }`. The old key is now a pointed compile error (N1).
- `RecordEvent.ctx` is now `RecordEvent.rctx` (`ctx` always means `*Ctx` in a hook signature). Mechanical migration: `ev.ctx.` → `ev.rctx.`.
- `RecordEvent.app` was removed — it put the UB footgun (`ev.app.allocator` vs `ev.arena`) one dot from every hook. Use the hook's `ctx.app`; allocate record data with `ev.arena`. (`JobEvent.app`/`ErrorEvent.app` are unchanged.)
- `RouteEvent` was deleted. It was never passed to a live route (handlers take `*Ctx`); it existed only in tests. Events carry data; `ctx` carries capabilities.
- `GET /api/collections` and `GET /api/settings` now return `{"items":[…]}` instead of a bare JSON array (superuser endpoints; admin SPA + typegen updated). `zigbase typegen --url` requires a server from this release.
- `GET /api/collections/:col/auth/oauth2/providers` returns `{"items":[…]}` (was `{"providers":[…]}`); `@zigbase/client`'s `listAuthProviders` types updated.
- `zigbase.Server` is now a generic `pub fn Server(comptime gates: Gates) type` instead of a concrete struct — the built-in route table is assembled per-app from `Gates` (R2-3). Framework consumers reach it exclusively through `App(cfg).runCli`/`serve`, which thread the new `gates` config automatically; only code that named `zigbase.Server` directly (bypassing `App`) needs an update, e.g. `server.Server(.{})` for the historical all-on table.
- Storage plugin vtable: `localPath(ctx, alloc, col, record_id, filename)` is now `fetch(ctx, io, alloc, col, record_id, filename)` — return a local filesystem path whose contents are the file, **materializing it locally if necessary**; `null` = the backend has no such object. Local-disk backends migrate mechanically (rename + the `io` parameter).
- `GET /api/senders` now returns `{"items":[…]}` instead of a bare JSON array (unified with the analytics endpoints' envelope).
- The `__features` realtime channel now emits the standard `{"type":"signal","topic":"__features"}` frame instead of the bespoke `{"type":"features.changed"}` frame.

### Features

- Admin UI: an **Email** view — manage verified sender identities (list / invite / delete), the suppression list (add / remove / filter by reason, incl. one-click-unsubscribe entries), and read-only bulk-send batch progress, with a read-only mail-policy strip. Backed by the existing mail APIs plus a new superuser `GET /api/mail/config` (booleans only, no secrets).
- Admin UI: a **Files** view — browse per-collection file fields with image previews, upload/replace files, and remove them, plus a read-only storage-backend strip (local disk vs S3). Backed by the existing records + file-serve APIs plus a new superuser `GET /api/files/config` (non-secret backend info only — never the S3 credentials).
- Admin UI: a **Logs & realtime** view — browse app analytics events with name/actor/since filters and cursor pagination, view an app-declared rollup's aggregated series, and a read-only realtime health strip (live connection count + caps). Backed by the existing analytics APIs plus a new superuser `GET /api/realtime/stats`. The Logs tab is capability-gated: it only appears when the app enables `.analytics` (the stock `zigbase serve` binary doesn't, so the tab is hidden there).
- Admin UI: a **Users** view for managing superusers and auth-collection users — list, search, create/edit/delete, admin password reset, and a read-only OAuth-providers panel. The admin SPA is now split into browser-native ES modules (no build step) and every asset is served with a CRC32 `ETag`.
- Self-service password change via `PATCH /api/collections/:col/records/:id`: non-superusers must include a verifying `oldPassword` — a non-oracle check (wrong/missing values, unknown records, and passwordless targets all return the login-identical `400 "Invalid credentials."` with argon2 timing padding), rate-limited under a new `"pwchange"` scope before any argon2 work runs. On success every other session for the record is invalidated (tokenKey rotation, plus `_sessions` purge in table mode) while a self-change keeps the calling device signed in via fresh `Set-Cookie` headers. The `beforePasswordChange`/`afterPasswordChange` lifecycle hooks now fire on this path too. `@zigbase/client` gains `collection(col).changePassword(id, oldPassword, newPassword)` (transparent re-auth in token mode).
- Official multi-arch Docker image, `ghcr.io/valthon/zigbase` — built from the existing static-musl release binaries (no in-image compilation), `distroless/static` base, non-root by default. The supported deployment path for Windows-hardware users, since ZigBase has no native Windows build. See `docs/docker.md`.
- `migrate-db` now fully supports circular relations (self-relations and mutual/N-node cycles) end-to-end, not just provisioning: cycle-edge foreign keys are omitted from the initial `CREATE TABLE` and added back as `DEFERRABLE INITIALLY IMMEDIATE` constraints (Postgres cannot create tables with circular inline `REFERENCES` in any order), and the load transaction defers those constraints to `COMMIT` (`SET CONSTRAINTS ALL DEFERRED` on Postgres, `PRAGMA defer_foreign_keys=ON` on SQLite) so rows load in any order regardless of reference direction. Previously this schema shape failed outright during provisioning; SQLite targets were always cycle-capable (inline FK DDL tolerates cycles) but are now verified round-trip end to end. A dataset with a genuinely dangling reference fails clearly at `COMMIT`, naming the affected collections, and rolls the whole load back.
- Bulk list sends: `ctx.mail().sendBulk(...)` fans one templated message out as per-recipient-rendered emails over the durable queue, with submit-time validation/dedup, per-recipient suppression checks, idempotent redelivery, and a durable send-report (`_mail_batches` / `_mail_batch_recipients`, readable as superuser via the records API) plus `batchStatus` / `cancelBatch`.
- Scheduled sends: `ctx.mail().deliverAt(msg, .{ .at | .delay_s })` returns a cancellable job id, `ctx.mail().cancel(id)` calls a pending send off, and `sendBulk` accepts `.at` — the documented drip-sequence primitives.
- One-click unsubscribe (RFC 8058): configure `.mail.unsubscribe_base_url` (or `ZIGBASE_UNSUBSCRIBE_BASE_URL`) and bulk mail automatically carries `List-Unsubscribe` / `List-Unsubscribe-Post` headers pointing at the new signed public `POST/GET /api/mail/unsubscribe` endpoint; one-click opt-outs are recorded as `unsubscribe` suppressions that block list mail only (transactional mail is unaffected).
- Per-queue rate throttling: durable queues accept `.rate = .{ .per_second = N }` — a token-bucket ceiling enforced at claim time (e.g. match SES's 14 msg/s).
- `ctx.mail()` warns when an HTML body exceeds ~100 KB (Gmail clipping threshold).
- Record-file downloads (`GET /api/files/:col/:rec/:name`) support HTTP Range and conditional requests: `206` with `Content-Range` for `bytes=a-b` / `bytes=a-` / `bytes=-n`, `Accept-Ranges: bytes`, a strong content-immutable `ETag` with `304` revalidation, `If-Range`, `416` for unsatisfiable ranges, and `HEAD` parity.
- Generic OIDC discovery for OAuth providers: set `.discoveryURL = "https://…/.well-known/openid-configuration"` on a provider (mutually exclusive with explicit endpoint URLs) and the endpoints are resolved once at startup — https-only, issuer-checked, and **fail-fast** (a failed discovery refuses to start). Covers Auth0/Okta/Keycloak/Entra-custom-tenant/Zitadel-class IdPs with one config line; scopes default to `openid email profile` with the standard OIDC claim mapping.
- `.migrations` accepts a bare tuple (`.migrations = .{ .{ .id = "...", .up = f } }`) like every other list-shaped config key; the typed-slice form still works (E1).
- New `-Dfts5` build flag (default **on**): lean custom builds can drop SQLite's FTS5 (~250-400 KB). With `-Dfts5=false`, `?search=` answers 400 and a `.searchable` SQLite schema refuses at startup. Default builds are unchanged; Postgres full-text search is independent of the flag.
- New comptime `.admin = .disabled` key: headless/embedded consumers can drop the admin SPA (dispatch + ~58 KiB embedded assets) from their binary. Default unchanged — the admin UI serves at `/_/`.
- `.auth.methods` (the app-level auth-method registry) gains an exact-set form: `.{ .builtins = .{ .password, .otp }, .custom = .{ MyMethod } }`. Deselected built-ins (WebAuthn's CBOR/COSE stack, magic-link, OAuth2, OTP) are excluded from the binary together with their routes. Absent key / bare-tuple form keep today's all-five behavior — non-breaking.
- Cross-instance custom-topic realtime on Postgres (#188): `ctx.realtime().signal(topic)` / `ctx.realtime().broadcast(topic, payload)` and the `__features` flag/experiment signal now fan out across every app instance sharing one Postgres database (best-effort, at-most-once, unordered), not just the emitting process. No app data ever rides the `LISTEN`/`NOTIFY` wire: signals carry only the topic name, and message broadcasts store the enveloped frame in a new `_rt_broadcasts` side table keyed by a random CSPRNG token (TTL-GC'd), NOTIFYing only the token — the receiving instance reads the frame back over its own connection and re-delivers it through the same per-subscriber authorization chokepoint. A forged or expired token finds no row and is dropped (fail closed). The `ctx.realtime()` public API is unchanged; on SQLite (single-process) behavior is byte-identical.
- Opt-in S3-compatible storage backend (`-Ds3` build flag; AWS S3, MinIO, Cloudflare R2), selected by configuration alone — set `ZIGBASE_S3_*` env vars on an `-Ds3` binary, no code change. Downloads are served through a local spool cache, so Range/ETag/tenancy behavior is byte-identical to local storage. A stock binary with `ZIGBASE_S3_BUCKET` set warns loudly and falls back to local storage. Startup runs a fail-fast HeadObject probe (DNS/TLS/SigV4/bucket/permissions verified before serving).
- `@zigbase/client` 0.3.0: full-text `search` + structured `vector` queries (`vectorSpec`) on list reads, with per-collection compile-time gating in the generated tiers.
- `@zigbase/client` 0.3.0: multi-tenant account scoping — `accountId` option, `client.withAccount(id)` scoped views (shared auth store), and `accounts.activate(id)`.
- `@zigbase/client` 0.3.0: per-record abilities — `getAbilities(id)` on the base and every generated collection service.
- `@zigbase/client` 0.3.0: analytics read APIs — `client.analytics.events(...)` and `client.analytics.rollup(name, ...)`.
- `@zigbase/client` 0.3.0: verified sender management — `client.senders.list/create/verify` (list requires ZigBase >= 0.10.0).
- `@zigbase/client` 0.3.0: realtime custom topics — `subscribeTopic`/`unsubscribeTopic` deliver `signal` and `message` frames (feature-change notifications are `subscribeTopic("__features", cb)`).
- Generated TS clients surface `searchable`/`tenant` schema metadata: typed `search`/`vector` options, per-collection sort unions (`sort: "-age" | [...]`), tenant fields omitted from `*Create`/`*Update`, and `accounts`/`analytics`/`senders`/`withAccount` on the generated client.
- Per-device session REST + SDK for `.auth.session.store = .table`: `GET /api/collections/:col/auth/sessions` (`{"items":[…]}`, newest first, `is_current` marked), `DELETE …/auth/sessions/:sid` (`204`; non-owned/absent ids are an indistinguishable `404`), and `DELETE …/auth/sessions` ("log out everywhere", works in **both** session-store modes, clears the session cookies). In the default `.epoch` mode the per-device routes answer `404`. `@zigbase/client` gains `listSessions()`, `revokeSession(id)`, `revokeAllSessions()` and the `SessionInfo` type. The `sessions` auth-method slug is now reserved.
- SPA fallback routing (#183): a presence-only `.spa` marker file makes its static
  directory an SPA root — GET/HEAD misses at or below it serve that directory's
  `index.html` (200), so client-routed apps survive deep links and hard refreshes.
  Works for both `--serve-static`/`.dir` trees and embedded manifests; real files,
  `/api` (including via normalized/double-slash paths), admin, and custom routes
  always win. In **dir** mode the marker is
  resolved **live** against the filesystem on every miss — adding, removing, or
  editing a `.spa`/`index.html` takes effect on the next request, no restart needed;
  startup only fails fast (with a clear, path-naming error) when a `.spa`-marked
  directory has no `index.html`, and an unreadable subdirectory is skipped with a
  warning rather than aborting boot. **Embedded** manifests keep a startup-derived,
  comptime-static marker set (there's no live filesystem to go stale). The fallback
  shell is served `Cache-Control: no-cache` with a revalidation ETag so a redeploy
  never strands deep links on a stale cached shell, and a file literally named
  `.spa` denotes this marker (ASCII case-insensitive) rather than being served.
- Comptime `static_routes` for custom builds (#183): declare `match → serve`
  rewrites on `App(.{ .static_routes = &.{...} })` with minimal segment matching
  (`:name` one segment, `*` one-or-more rest, `**` zero-or-more rest; first match
  wins). Patterns and embedded serve targets are validated at compile time; dir
  targets at startup. A new `enable_spa_marker` key gates the marker (default: on
  without routes, off with routes).
- Realtime over Server-Sent Events (#188): `GET /api/realtime/sse` (EventSource-compatible — no SDK required) + `POST /api/realtime/sse/:clientId` uplink speaking the same verb grammar as WebSocket. Same frames, same per-record delivery authorization, same Origin policy, same shared connection cap. New `--sse-heartbeat-seconds` / `ZIGBASE_SSE_HEARTBEAT_SECONDS` knob for the `: ping` heartbeat interval.
- Tunable Cache-Control for static file serving: `App(.{ .static_cache_control = "…" })`
  sets a comptime default, and `--static-cache-control <value>` /
  `ZIGBASE_STATIC_CACHE_CONTROL` override it at runtime (flag wins over env, both win
  over the comptime default). Applies only to static serving (dir/embedded/
  `--serve-static`) — record-file downloads keep their authorization-derived
  Cache-Control unchanged. Unset (the default) is byte-identical to today's stock
  `max-age=3600`. The value must be non-empty, CR/LF-free, and at most 256 bytes;
  an invalid value fails startup with a clear error instead of silently clamping
  or ignoring it.
- Static file serving now supports HTTP Range: `bytes=X-` (video seek), `bytes=-n`, and overlong ranges return correct `206` responses, unsatisfiable ranges `416` (previously these fell through to a full `200` or worse), and embedded static assets gain single-range `206`. A ranged **dir**-mode request with a matching `If-Range` now resumes with `206` instead of restarting as a full `200`: zigbase neutralizes an inverted `If-Range` branch in the vendored facil.io that deleted the `Range` header on a match (RFC 9110 §13.1.5), so interrupted downloads resume instead of re-downloading from scratch. Owned record-file (`/api/files/…`) and embedded serving were already RFC-correct here. (#192)

### Fixes

- `onAuth` on `POST …/auth-refresh` now reports `.refresh` instead of the mislabeled `.password`.
- `migrate-db` onto a non-superuser Postgres target (the common case for managed Postgres like RDS/Cloud SQL) no longer silently corrupts the load: the best-effort `SET session_replication_role = replica` FK-suspension attempt, when rejected for lack of privilege, was leaving the load transaction itself in Postgres's aborted state — so *every* subsequent statement in the load failed, regardless of whether the schema had any cycles at all. The attempt is now wrapped in a `SAVEPOINT` so a rejected privilege check no longer poisons the load.
- `_suppressions` gained the `updated` column the records engine's base-column SELECT requires, so superusers can actually browse it via the records API (migration `0019_bulk_mail`).
- Record-file downloads no longer emit a duplicate `Cache-Control` header (the handler's per-collection value used to be joined on the wire by facil.io's global `max-age=3600`).
- Shipped-binary size: fixed a code-gen accident in the bundled regex engine (`Builder`
  was materialized as a ~3 MB all-zero `.rodata` template copied at runtime on every
  `compile`) — the default ReleaseSafe binary shrinks ~40%, from ~7.6 MB to ~4.6 MB,
  with identical behavior.
- `app.submit` tasks and memory-queue jobs are now drained and joined at shutdown (a task
  submitted before shutdown completes instead of being cut off), and `app.submit` works
  whenever the server is running — a configured scheduler is no longer required.
- Postgres SCRAM authentication now applies RFC 4013 SASLprep to passwords: soft hyphens are stripped and non-ASCII spaces map to space before PBKDF2, prohibited/bidi-invalid and non-UTF-8 passwords keep PostgreSQL's own use-verbatim parity, and a password that would require NFKC normalization fails loudly at connect with a message naming the fix (previously: verbatim bytes and a mysterious `password authentication failed`). Printable-ASCII passwords are byte-identical fast-path (zero allocation).
- Postgres backend (`-Dpostgres` builds): a `postgres://` URL whose host is a DNS name (e.g. `localhost`, `db.internal`) now resolves through the OS resolver (`/etc/hosts` + `resolv.conf`) instead of failing to connect — previously only IP-literal hosts (`127.0.0.1`, `::1`) worked, so `verify-full` against a hostname could never complete its handshake.
- The `App(.{…})` config-key table in docs/framework.md claimed to be exhaustive while omitting 9 keys (`captcha`, `tenancy`, `abilities`, `mail`, `analytics`, `static_routes`, `enable_spa_marker`, `onFeatureExposure`, `features`); it is now complete, states each key's binary-size contract ("unset ⇒ excluded/data-only/always"), and documents the config-plane assignment rule + laziness contract.
- `ZIGBASE_DB_URL` (the SQLite-vs-Postgres selector), `ZIGBASE_PUBLIC_URL` (magic-link URL base), and `ZIGBASE_SENDMAIL_COMMAND` are now documented in the README env table and `zigbase help` — they were previously undiscoverable.
- Field-encryption (`ZIGBASE_FIELD_KEY`, `ZIGBASE_FIELD_KEY_GENERATION`, `ZIGBASE_FIELD_KEY_V<n>`) env vars are now in the README env table (previously only in `zigbase help`). OAuth (`ZIGBASE_OAUTH_STATE_SERVER`/`_STATE_TTL`), rate-limit (`ZIGBASE_RATE_LIMIT_MAX`/`_WINDOW`), and SMTP (`ZIGBASE_SMTP_*`) env vars are now in `zigbase help` (previously only in the README).
- README documented the `ZIGBASE_OAUTH_STATE_SERVER` default backwards (`false`); the server-side OAuth state store has defaulted **on** since it shipped. The env table now matches the code (set `=false` to opt out).
- Outbound HTTP client (`http_client.zig`, shared by S3, webhooks, OAuth2, and CAPTCHA verification): a response DEFINED to carry no body (a `HEAD` response, any `1xx`, `204 No Content`, or `304 Not Modified`) was still read as if it might have one, using whatever `Content-Length` it happened to arrive with — or, absent that, "read until the connection closes." Real S3 servers don't close keep-alive connections, so every S3 `DELETE` (always `204`, no `Content-Length`) and every `HEAD` on an existing key blocked for ~30 seconds (an unrelated idle-connection timeout eventually unblocking it) before this was caught by the new live MinIO tests.
- `.analytics.rollups` in the `App` config could never compile — a job-wrapper signature mismatch made the option dead-on-arrival since it was introduced.
- The TypeScript code generator emitted an orphan `Expand` type key (breaking `tsc`) for relations that target a collection outside the generated set; it now emits `never` for those relations instead.
- `@zigbase/client` realtime: concurrent `subscribe`/`subscribeTopic` calls for the same topic while the socket is open no longer send duplicate subscribe frames — later callers join the pending ack instead.
- Embedded static assets now send a `Cache-Control` header (previously none — revalidation still works via the unchanged CRC32 ETag).
- `.gz` sidecar responses now carry `Vary: Accept-Encoding` (shared-cache correctness).

### Changed

- Stale docs corrected: Postgres backend status in configuration, README backend
  description, tenancy example harmonization.
- `Email` / `MailMessage` gained an additive `list_unsubscribe` field (default `null`; CRLF-checked like every header field) emitted as RFC 8058 headers by all backends (SMTP/Command/SES/Postmark).
- `durable.enqueue` now returns the generated job id, and the queue GC reaps `canceled` jobs (internal signature change, pre-1.0).
- `CaptureMailer` records `reply_to`/`list_unsubscribe` and gained `all()` / `countTo()` accessors.
- The release binary no longer ships the demo feature flags/experiment (`dark_mode`, `maintenance`, `onboarding_flow`) — they were Playwright fixtures riding in production. `GET /api/features` on a stock binary is now empty until you declare your own.
- `GET /api/analytics/events` adopts the house cursor pagination: `?cursor=` request param and `nextCursor`/`hasNext` response keys (additive; `limit` cap 200 unchanged).
- Built-in routes are now comptime-assembled from your `App(.{…})` config: analytics, senders, the inbound mail webhook, one-click unsubscribe, and `accounts/:id/activate` are registered (and compiled) only when `.analytics`, `.mail`, or `.tenancy` is configured. Previously these routes always existed and answered 404/fail-closed when unconfigured; now they 404 as unknown routes. The standalone `zigbase serve` binary opts into `.mail = .{}`, so its mail routes (verified senders, the inbound webhook, RFC 8058 unsubscribe) stay registered and behave exactly as before; only the still-unconfigured analytics and tenancy routes now 404 uniformly.
- The typed where-DSL `in` operator now compiles to the native `field in (…)` filter operator (requires ZigBase >= 0.9.0; against older servers it is a 400).
- Clients regenerated by this release require `@zigbase/client` >= 0.3.0 (enforced by a `CoreSupports_0_3` marker type with a self-explaining typecheck error).
- The docs site gained dedicated feature guides for the 0.9.0 features (PostgreSQL, tenancy,
  abilities, search, analytics, email, jobs & webhooks, realtime broadcast), a CAPTCHA
  recipe, a refreshed landing page, and a competitor comparison page.

### Performance

- Collection-metadata cache: `invalidate()` no longer allocates while holding the cache spinlock. Detached entries are threaded onto an intrusive list and their arenas/keys are freed only after the lock is released, removing an alloc-under-spinlock latency/contention hazard (and any re-entrant-allocator deadlock risk) on the DDL path.
- Memory-backend queues no longer spawn one detached OS thread (with a 1 MiB stack) per
  enqueued job: jobs run on a small fixed worker pool with a bounded ring. Overflow
  returns `error.QueueFull` instead of unbounded thread creation, so enqueue bursts can
  no longer exhaust threads or address space.
- Realtime delete fan-out: the per-subscriber authorization sandbox for delete events now
  creates only the tables it needs (2 statements) instead of running the full ~28-table
  migration suite once per subscriber per delete — removing the worst per-event fan-out
  cost on the shared HTTP threads.
- Collection metadata (the parsed schema consulted by every record API request and every
  realtime delivery) is now served from a versioned in-process cache invalidated on
  collection create/update/delete (SQLite backend; Postgres deployments keep direct reads
  so multi-instance DDL stays coherent) — removing a `_collections` SELECT plus a full
  schema-JSON parse per request and per realtime fan-out delivery.
- The embedded admin UI's assets now carry build-time `ETag`s and answer `If-None-Match`
  with `304 Not Modified`, so revisiting the admin no longer re-downloads the SPA bundle
  on every load.

### Security

- The SASLprep mapping/prohibited/bidi/NFKC-quick-check sets are vendored-generated range tables (`scripts/gen-saslprep-tables.py` over the frozen RFC 3454 appendices + Unicode 16.0.0 UCD extracts) — auditable binary-search tables, mechanical to bump.
- Postgres TLS supports real server-certificate verification: `sslmode=verify-ca` / `verify-full` are accepted (previously rejected at parse time), a new `sslrootcert=<path|system>` URL parameter selects the CA bundle (built once at startup, shared by all pooled connections, fail-fast on a missing/empty bundle), certificate validity is checked against real wall-clock time, and handshake failures surface actionable startup errors (untrusted chain, hostname mismatch, expired / not-yet-valid certificate, server refused TLS) that never include the connection URL.
- Realtime slow-consumer backpressure (issue #203): each WebSocket/SSE connection now has a per-connection outbound high-water-mark. A client that reads slowly or stalls without closing used to let the server buffer its outbound frames without bound (an OOM/DoS risk); once a connection's queued outbound frames exceed the bound it is now disconnected (the standard pub/sub choice — a clean reconnect + re-fetch, never a silent frame drop). Default `1024` frames; tune with `--realtime-outbound-hwm N` / `ZIGBASE_REALTIME_OUTBOUND_HWM` (`0` disables).
- Fixed an unauthenticated, remotely-triggerable heap double-free (and double connection-slot release) on the realtime WebSocket upgrade path: a malformed `Sec-WebSocket-Version` handshake drives facil.io's `bad_request` branch, which already invokes the connection's `on_close` teardown before returning failure — the adapter then tore the connection down a second time. In a release build this was a potential denial of service. The SSE upgrade path (new in 0.10.0) is hardened identically. Both transports now leave failure-path teardown solely to facil.io's `on_close`.
- Comptime custom routes (an app's `.routes` config) now resolve the active account exactly like the REST record/analytics/senders endpoints. Previously `dispatchCustom` never resolved tenancy: `ctx.track()` calls from a custom route stamped an empty account, and — more seriously — reads of tenant-owned collections made through a custom route were served **unscoped**, exposing cross-tenant data to any caller who could reach the route. Custom routes now resolve tenancy identically to the REST chokepoints. File serving (`GET /api/files/:col/:rec/:name`) had the same gap and is fixed the same way: it now resolves the active account before evaluating `viewRule`, so a file on a tenant-owned collection is no longer reachable cross-tenant by a caller who merely knows the collection/record/filename, and `@request.account.*`/cookie-activated rules now see the correct scope.

### Internal

- CI now enforces formatting: a `zig fmt --check src build.zig` gate in the `unit` job fails the build on any unformatted file, paired with a one-shot tree-wide `zig fmt` sweep so the tree starts clean.
- Scoped the `zig-local-*` build/test caches by branch (`github.ref_name` folded into both the `key:` and `restore-keys:` prefixes of every job) so one branch can no longer restore and reference another branch's cached objects — the cross-branch cache poisoning that surfaced a phantom symbol error in unrelated CI. The content-hash-keyed `zig-global-*` caches stay shared.
- Added a multi-threaded stress test for the collection-metadata cache: N threads hammer `lease()`/`invalidate()`/release concurrently, asserting no use-after-free, no leak (via the leak-checking test allocator), and correct post-invalidation reload.
- `dumpload.zig`'s collection-creation ordering is now a proper Kahn topological sort (`planCreateOrder`), with unit-tested, deterministic handling of relation cycles (self-relations and mutual/N-node cycles) that surfaces the in-cycle relation fields instead of just falling back to declaration order. Observable dump/load behavior for acyclic schemas (the common case) is unchanged; this lands the pure ordering primitive that Postgres deferred-FK cycle support (a follow-up task) builds on.
- Parallelized the Playwright/browser test suite (`tests/admin/`) with pytest-xdist (`-n auto`) in CI and reworked the harness fixtures to reuse a per-worker Chromium browser and a template superuser data dir, cutting the suite's serial wall time (~4:53) to ~18s on a 32-core box. No consumer-visible change.
- Fix a race in the admin browser test
  `test_shell.py::test_login_then_sidebar_lists_builtin_collections`: it counted
  the `nav-_superusers` sidebar link immediately after `login()`, but `login()`
  only waits for the static `nav-collections` link while the built-in-collection
  nav items render asynchronously just after — so the bare `count()` read 0 and
  the `browser` job flaked. It now waits for the selector before counting.
- Fix a ~2.4%-per-run flake in the Postgres realtime cross-instance tests
  (`realtime_pg_test.zig`): the delete-snapshot leak-canary asserted a bare
  owner value `u9` was absent from the NOTIFY payload, but the payload embeds a
  32-char random base36 token that coincidentally contains `u9` ~2.4% of runs.
  The canaries are now anchored to their JSON string quotes (`"u9"`, `"ssn"`),
  which a quote-less token/id can never forge, while still catching a real leak.
  The cross-instance waits also now loop over benign non-notification async
  messages (matching the production `pg_bridge` listener's tolerant contract)
  instead of failing on the first one.
- Corrected a false load-bearing comment in `static_files.zig` (facil.io does NOT
  percent-decode request paths; the `..` check is safe because encoded traversal stays a
  literal segment) and documented why `query/params.zig` keeps its own query parser
  (fio type-guesses values; zap returns them undecoded).
- Postgres backend: added `scripts/gen-saslprep-tables.py`, vendored RFC 3454 / Unicode 16.0.0 UCD source extracts (`vendor/unicode/`), and the generated `src/backend/postgres/saslprep_tables.zig` range tables (RFC 3454 B.1/C.1.2/C.2.x/C.3–C.9/D.1/D.2, plus UCD `NFKC_QC` and canonical-combining-class data) that a follow-up SASLprep normalization pass will consume. Not yet wired into any code path.
- A table↔`allowed`-tuple parity test (`tests/admin/test_docs_parity.py::test_config_key_table_matches_allowed_tuple`) guards the config-key table against future drift.
- Tightened the env-var help-parity test's text slice to end at `EXAMPLES:` instead of running to EOF — the old unbounded slice would false-pass a `ZIGBASE_*` name that only appeared in a later `std.log` message, not in the actual help text.
- Browser feature tests drive a dedicated `features-fixture` binary (`fixtures/features/`).
- Doc-drift guard: `tests/admin/test_docs_parity.py` fails CI when a `ZIGBASE_*` var referenced in `src/` is missing from the README table or the help text.
- CI now enforces the gating invariant: a minimal consumer build (`fixtures/minimal/`) is nm-scanned to prove deselected subsystems (WebAuthn, magic-link, OAuth2, analytics API, senders, mail webhook, webhook/mail job kinds, admin SPA) leave zero symbols (`scripts/check-gating.sh`), self-checked against a positive-control build (`fixtures/full/`) so a renamed/vacuous pattern also fails the check.
- Realtime delivery/verb authorization extracted from the WebSocket adapter into transport-neutral `hub.frameForDelivery`/`hub.authVerb`/`hub.subscribeCheck` (behavior-preserving; WS wire byte-identical) — groundwork for the SSE transport.
- SSE connection registry scaffolding (`realtime/sse.zig`): `SseConn` + pin/unref refcount, closed-flag lifecycle, and the per-delivery snapshot, with a strict `registry_mu`/`conn.mu` never-nested lock-ordering law and threaded-stress unit tests. Internal until the transport is wired end-to-end.
- SSE stream lifecycle wired onto the shared realtime upgrade path (`realtime/ws.zig` `handleUpgrade` now dispatches `sse` targets on `/api/realtime/sse`): `on_open` dups the handle, registers, and writes the connect frame; `on_close` runs the single authoritative reap; delivery snapshots under `conn.mu` and authorizes through the same `hub.frameForDelivery` chokepoint as WebSocket. Not yet a usable transport (no subscribe uplink until the next slice); Internal until then.
- New `s3` CI job: MinIO via `docker run` + gated live Zig tests + a raw-HTTP upload→Range→delete e2e (`tests/s3/`).
- Generalized the AWS SigV4 signer (`src/mail/sigv4.zig` → `src/aws/sigv4.zig`): parameterized method / canonical URI (S3 `UriEncode`) / signed-header list / service, SES signatures pinned byte-identical. Groundwork for the S3 storage backend; zero behavior change.
- Dual-transport (ws/sse) realtime e2e delivery matrix in the browser suite.
- Static Range support is a ~20-line request-header normalization shim + `HTTP_HVALUE_MAX_AGE` FIOBJ swap at `FIO_CALL_PRE_START` — facil.io keeps ALL static serving (directive 1); no owned static layer.

## [0.9.0] - 2026-06-30

A large release: a **PostgreSQL backend** alongside the default embedded SQLite, plus multi-tenancy, relationship-based authorization, full-text & vector search, product analytics, a transactional email subsystem, background job queues, outbound webhooks, CAPTCHA verification, and a realtime broadcast API.

### Breaking

- **Consumer migrations** (`.migrations`) now receive a `*zigbase.Migrator` instead of `(alloc, io, w)`. Change each `up` to `fn (m: *zigbase.Migrator) anyerror!void`: the writer is `m.db`, the arena `m.arena`, the request `std.Io` is `m.io`. `Migrator` carries the active SQL **dialect** so one migration runs on either backend — `m.execLowered(sql)` lowers SQLite-flavored DDL/seeds to the active backend (byte-identical on SQLite), `m.exec(sql)` runs raw backend-specific SQL, and `m.dialect.kind` / `m.rawFor(.postgres, …)` branch per backend. SQLite-only consumers just swap `w` → `m.db`.
- `ErrorPhase` gained a `.webhook` variant (additive). An `onError` handler that switches exhaustively over `ErrorPhase` must add a `.webhook` arm.

### Features

- **PostgreSQL backend (opt-in).** ZigBase can now run on PostgreSQL instead of the default embedded SQLite, selected by configuration alone — a `postgres://` `ZIGBASE_DB_URL` in a `-Dpostgres` build; application code and collection definitions are unchanged.
  - **Full feature parity:** record CRUD and the typed filter/sort/expand/search query engine, the access-rule + abilities + tenancy authorization stack, analytics rollups, the KV/TTL/rate-limit/feature-flag stores, field encryption + key rotation, the deterministic test-clock, and typed-client codegen all work identically on Postgres — verified against a live server in CI.
  - **Realtime across app instances:** a Postgres deployment can run multiple stateless app instances against one database, and record-change events fan out to subscribers on every instance via `LISTEN/NOTIFY`. The NOTIFY payload carries only an opaque token — never row data — so encrypted fields never leave the database in plaintext.
  - **Pure-Zig wire driver:** no libpq, C, or OpenSSL dependency (TLS via `std.crypto.tls.Client`, SCRAM-SHA-256 via `std.crypto`); the default SQLite build links zero new symbols. *Transport is encrypted but the server certificate is not yet verified in any sslmode (`verify-full` is a tracked follow-up) — use the Postgres backend over a trusted network path until then.*
  - **`migrate-db` CLI:** `zigbase migrate-db --from ./data.db --to "postgres://…"` copies an existing SQLite instance (schema **and** data) into a fresh Postgres database — provisions the equivalent schema, bulk-loads every table in one atomic transaction, preserves ids/timestamps/metadata, and carries encrypted-field envelopes byte-for-byte (no key needed). *FK suspension requires a superuser target; a managed non-superuser Postgres uses a lightly-tested topological-order fallback.*
  - **Vector search on Postgres** via pgvector, behind the same `-Dvector` flag and `?vector=` API as SQLite's sqlite-vec — one flag enables KNN on both backends.
  - **Admin backend badge:** the admin UI shows a "SQLite"/"Postgres" badge, sourced from a new `backend` field on `GET /api/health` (the kind only — never the connection string or credentials).
  - The default SQLite single-file deployment is unchanged. One safeguard: a stock (non-`-Dpostgres`) binary now reads `ZIGBASE_DB_URL` and logs a prominent warning if it is a `postgres://` URL, rather than silently writing to local SQLite.
- **Account-scoped multi-tenancy (#156).** `App(.{ .tenancy = .{ .enabled = true, .auth_collection = "users" } })` plus a collection's `.tenant_field = "account"` auto-scopes every read/write (and realtime delivery) of a tenant-owned collection to the request's active account via a bound `tenant_field = ?` predicate; create stamps the owning account and update rejects cross-tenant moves. The active account resolves from an `X-Account-Id` header or a signed `zb_account` cookie, verified against an active `_memberships` row (fail-closed). Adds built-in `_accounts`/`_memberships`/`_invitations` collections, a configurable role order (`viewer < editor < admin < owner`), `POST /api/accounts/:id/activate`, and the `@request.account.id`/`.role`/`.ids` rule macros. Superusers bypass; `zigbase.crossTenant(rctx)` is the explicit admin override. Apps with no `.tenancy` are byte-identical to before.
- **Relationship-based row abilities (#155).** Declare per-collection, per-action authorization by the principal's relationship to the row: `App(.{ .abilities = .{ .projects = .{ .update = .{ .relationship = .{ .via = "account", .min_role = .editor } } } } })` authorizes a row when the principal holds a membership (role ≥ `.min_role`) of the account it belongs to. Abilities compose into the existing guard stack, narrow the LIST endpoint, are fail-closed and comptime-validated, and `ctx.can(.action, "col", id)` + `GET …/records/:id/abilities` expose them to custom routes. Collections with no `.abilities` are byte-identical to before.
- **Search on the list endpoint (#157).**
  - **Full-text search** ships in the default build: mark a `text`/`editor` field `.searchable = true` and query with `?search=<terms>` — ranked by relevance, with `AND`/`OR`/`NOT`/prefix operators, provisioned automatically (SQLite FTS5; Postgres `tsvector` + GIN). Search composes with the full authorization stack and structured filters: `?search=X&filter=Y` returns the scoped intersection (never an unscoped query) and terms are always bound (no injection).
  - **Vector / nearest-neighbor search** behind an opt-in `-Dvector` flag: `?vector=<field>[:cosine|:l2]:<embedding>` KNN ordering composed into the same scoped query (sqlite-vec on SQLite, pgvector on Postgres). Not compiled into the default build.
- **Product analytics (#158).** `ctx.track("user.signup", .{ .plan = "pro" })` appends an immutable event — actor, tenant, and timestamp stamped server-side — to the new `_events` collection. Declarative rollups (`App(.{ .analytics = .{ .rollups = … } })`) incrementally aggregate events into summary tables on the scheduler. Tenant-scoped, fail-closed read API: `GET /api/analytics/events` (raw feed) and `GET /api/analytics/rollups/:name`. Usable standalone with no config.
- **Email subsystem (#154)** on `ctx.mail()`:
  - A safe multipart HTML + plain-text **template engine** (HTML-escaped by default, named partials + shared layout, no code evaluation).
  - First-class **SES** and **Postmark** HTTP providers behind the `Mailer` vtable (SMTP/Command unchanged), a per-message `From` override, and a `CaptureMailer` for asserting outbound mail in tests with no network.
  - **Verified per-account sender identities** and **bounce/complaint suppression** with an inbound provider webhook, all tenant-scoped. Enforcement (`.mail.require_verified_sender`, `.check_suppression`) defaults off, so an app that only calls the existing mailer is unaffected.
  - `ctx.mail().send(...)` / `.enqueue(...)` / `.deliverLater(...)`; `mail.Email` gains `html_body`/`reply_to`; the framework owns header-injection (CRLF) defense for every backend.
- **Background jobs & queues.** A generic multi-queue/worker/job engine: declare named `.queues` (memory or durable, prioritized, per-queue retry), `.workers` (bound to queues, strict-priority drain, concurrency), and a `.jobs` kind→handler registry, then enqueue from anywhere with `ctx.enqueue(.queue, .kind, payload)`. Durable queues persist to `_queue_jobs` with at-least-once delivery, crash-reclaim, and GC; memory queues need zero schema. Powers the built-in `"mail"` and `"webhook"` job kinds.
- **Outbound webhooks.** `ctx.webhook(url, payload, .{…})` delivers in the background on the queue engine with retry/backoff (honoring `Retry-After`, capped), optional HMAC-SHA256 signing, and a stable per-delivery `Idempotency-Key`; TLS certificate verification stays on.
- **Realtime broadcast API** for custom (non-record) channels, from a route or job: `ctx.realtime().signal(topic)` (a payload-less re-fetch trigger, the default for private state) and `.broadcast(topic, payload)` (delivered verbatim), over the same WebSocket subscribe protocol clients already use. New `App(.{ .realtime = .{ .canSubscribe = fn } })` gates custom-topic subscriptions; a custom topic can never reach a real collection's record channel.
- **CAPTCHA verification (#140).** `ctx.verifyCaptcha(provider, token)` for reCAPTCHA v2/v3, hCaptcha, and Cloudflare Turnstile, configured via `App(.{ .captcha = … })` (dev-bypass when the secret is empty).
- **Custom-route ergonomics.** Response builders (`ctx.json` / `jsonError` / `html` / `redirect` / `notFound`), deferred `ctx.setCookie` / `addHeader` (merged on both the success and error paths), lazy `ctx.query()`, `ctx.randomToken` / `randomHex`, and `ctx.subjectCookie` (an anonymous per-visitor id). A declarative route **guard pipeline**: `.auth` now also accepts a `path_secret` guard (constant-time shared-secret gate, bare-404 on mismatch) and `.rate_limit` adds per-route buckets keyed on the trust-proxy client IP. `http.Cookie` gains an optional `domain`.
- **Filter/rule grammar:** a new `in` set-membership operator (`field in ("a", "b")`, compiled to a bound `IN (?, …)`, empty set fail-closed) and the `@request.account.id` / `.role` / `.ids` macros that underpin tenancy and abilities.

### Changed

- A `.nocase` (case-insensitive) index now makes both **uniqueness and lookups** case-insensitive on SQLite. Previously a `.nocase` UNIQUE index treated `Bob@x.com`/`bob@x.com` as the same identity, but the lookup was case-sensitive — so a user registered as `Bob@x.com` could not log in as `bob@x.com`. Identity/email lookups and `=`/`!=`/`in` comparisons against a `.nocase` column are now case-insensitive, agreeing with the index (and matching the Postgres backend, which uses a `lower()` functional index). The built-in auth identity index remains case-sensitive — case-insensitive identity stays opt-in via a `.nocase` index.

### Security

- The shared one-time-code comparison was unified on the audited constant-time `crypto.timingSafeEql` primitive (the OTP auth method now uses it too).
- Webhook retry backoff (including a server-supplied `Retry-After`) is capped at the queue's maximum, so a hostile or misconfigured receiver cannot park a worker thread and starve the background pool.
- The new subsystems are fail-closed by design — tenant/ability/search scoping, the email verified-sender + suppression + CRLF-injection defenses, the realtime no-row-data-on-the-NOTIFY-wire guarantee, the `path_secret` constant-time gate, and per-route rate-limit IP keying are detailed under their features above.

### Internal

- CI now runs a `-Ddev-clock=false` production-gate test pass, so the tests asserting that `ZIGBASE_FAKE_NOW`/`ZIGBASE_FAKE_SEED`/test-capture are compiled out of production builds actually execute (they were previously skipped in the only CI test run).
- The e2e test harnesses now retry server startup on a port-bind race (fresh OS-assigned port + fast `ListenError` detection + cleanup between attempts), fixing an intermittent `ListenError` → "server did not become healthy" flake in the `ts-sdk`/`browser` jobs.
- New `policy.zig` authorization-composition layer and `src/sql/dialect.zig` SQL-dialect layer are the architectural seams the abilities/tenancy and the Postgres backend compose through.
- GitHub release descriptions now contain only the released version's changelog section (`scripts/extract-release-notes.sh`), not the entire `CHANGELOG.md`.

## [0.8.0] - 2026-06-28

### Breaking

- **Feature flags are now declared-only.** Flags must be declared in the `App(.{ .flags = .{ … } })` literal; only declared flags resolve. The v0.7 runtime-string API `ctx.flag("arbitrary")` (KV-or-false) has been **removed** — use the typed `App.flag(ctx, .name)` for known flags, or `ctx.flagByName("name")` (returns `?bool`, null when undeclared) for dynamic names.
- **`ctx.setFlag` now writes a declared-flag override.** It writes the `flag:<name>` override key for a DECLARED flag and errors `error.UndeclaredFlag` otherwise (the typed, compile-checked form is `App.setFlag(ctx, .name, enabled)`). Previously it set an arbitrary `<name>` KV value.

### Features

- **Comptime feature-flag + experiment registry (#128/#129/#130).** Declare `.flags` (bare-bool default or `.{ .default, .description }`) and `.experiments` (`.{ .variants, .weights, .sticky, .description }`) in the `App(cfg)` literal. Malformed declarations (unknown sub-key, non-bool flag, variants/weights length mismatch, empty/duplicate variants, all-zero weights) are loud `@compileError`s.
- **Typed, compile-checked accessors.** `App.flag(ctx, .name) bool`, `App.setFlag(ctx, .name, enabled) !void`, and `App.experiment(ctx, .name, subject) ![]const u8` — a typo'd flag/experiment name is a compile error (generated `App.Flag` / `App.Experiment` enums).
- **Runtime resolution.** `ctx.flagByName(name) ?bool` (dynamic read), `ctx.flags().resolveAll(subject)` resolves every declared flag + experiment in a single batched `_kv` scan, and deterministic experiment bucketing (`FNV1a-64(name ++ 0x00 ++ subject)` over cumulative weights) gives a stable variant per `(name, subject)`. Per-flag overrides live in `_kv` under `flag:<name>`; experiment weight overrides under `exp:<name>:weights` (JSON).
- Admin UI gains a **Feature Flags & Experiments** screen (`/_/#/features`) showing every declared flag (name, default, description, effective value) with a toggle to set/clear the `flag:<name>` override, and each declared experiment's variants with editable weight sliders that write the `exp:<name>:weights` override; a "Reset to declared" action clears the override. Superuser-only; backed by the new `GET /api/features` endpoint.
- New `GET /api/features` endpoint (superuser) returns the comptime-declared flag + experiment registry alongside each entry's current `_kv` override — useful for custom admin tooling.
- Feature exposure events: register `.onFeatureExposure` to receive an `ExposureEvent` (`{ kind: .flag | .experiment, name, subject, value, variant }`) each time a declared flag or experiment is resolved. The hook is notify-only and zero-cost when unregistered (the resolver never builds the event without a handler).
- Realtime feature signal: any flag/experiment override change (`ctx.setFlag`/`App.setFlag` or an admin `PUT`/`DELETE` of a `flag:<name>` / `exp:<name>:weights` setting) broadcasts a signal-only `{"type":"features.changed"}` frame on the public `__features` channel. Clients may subscribe anonymously and re-`GET /api/state` on receipt; no per-subject state or experiment assignment is ever pushed over the socket.
- **Public feature-state endpoint (#130).** `GET /api/state?subject=<id>` is an **unauthenticated**, read-only projection of resolved flags + experiments: `{ "flags": { "<name>": <bool>, … }, "experiments": { "<name>": "<variant>", … } }`. It exposes resolved values ONLY — never the `_kv` keys, defaults, weights, timestamps, or any superuser settings verb (those stay behind `requireSuperuser`). A `.sticky` experiment returns its persisted assignment here too (agreeing with `App.experiment`), resolved **reader-first** so a caller-supplied subject can't storm the writer lock. Auto-mounts at `/api/state`; configure with `.features = .{ .public_route = "/state" }` to remap or `.{ .public_route = .disabled }` to turn off.
- **Typed `zb.flags.resolveAll(subject)` in the TypeScript SDK.** `zig build gen-client` now emits a fully-typed feature-state surface from your `App(.{ .flags, .experiments })`: flags as named `boolean`s and each experiment as a string-literal union of its declared variants (`FeatureState`). `await zb.flags.resolveAll("user-42")` calls `GET /api/state` and returns `{ flags: { … }, experiments: { … } }` with no `any`. Emitted only when flags/experiments are declared; the runtime-introspection tier omits it (no comptime metadata), matching typed routes and custom auth methods.
- Sticky experiment assignments (#129): declare an experiment `.sticky = true` to persist a subject's first variant in `_experiment_assignments` so it **survives later weight changes** (new subjects still follow the current weights; empty subjects are never persisted). A framework-internal `_experiment_gc` job — installed only when a `.sticky` experiment is declared — reaps assignments older than the new `.experiment_assignment_ttl` config (in days, default `90`) hourly in bounded batches.

## [0.7.1] - 2026-06-28

### Features

- TypeScript client codegen now emits **precise typed I/O for custom auth methods**. Enable a custom method in the new struct form — `.custom = &.{ .{ .slug = "corp-sso", .Initiate = .{ .Input = …, .Output = … }, .Complete = .{ .Input = …, .Output = … } } }` — and `zig build gen-client` reflects the declared Zig types into `zb.auth.<col>.<method>.{initiate,complete}` interfaces (named by the Zig type, like the typed `zb.rpc.*` route surface). A `void` Input omits the input argument; a `void` Output maps to `Promise<void>`. Bare-string slugs (`.custom = .{"slug"}`) stay fully back-compatible and untyped. Typed customs are a build-time feature (the runtime-introspection typegen tier keeps them untyped, exactly like typed routes).

### Fixes

- Exported `zigbase.Tx` — the transaction scope passed to a `ctx.tx(T, fn(*Tx) ...)` callback. It was referenced in the docs but never re-exported from the public API, so consumers could not name the callback's parameter type.
- The comptime per-auth-method `.rate_limit = .{ .custom = .{ .max = …, .window_s = … } }` config form now compiles (it previously failed with a `@tagName`-on-a-struct error; only the `.default`/`.off` enum-literal forms worked).
- The TypeScript client generator (`zig build gen-client`) no longer hits the comptime branch-quota limit on apps with larger custom-route tables.

### Internal

- golfsim example: added demos for per-device session management (`.session_store = .table` + `ctx.auth().revokeAllSessions`/`listActiveSessions`/`revoke`), an atomic hold→booking convert via `ctx.tx()`, a best-effort booking-confirmation webhook via `ctx.http()`, and KV write-side seeding from `onBootstrap`. Added a deterministic e2e suite that freezes time with `ZIGBASE_FAKE_NOW` and captures the outbound webhook. Fixed a latent date-formatting bug in golfsim's `isoFromEpoch` (signed-integer `{d:0>N}` emitted a `+` sign, breaking hold creation).
- plugins example: demonstrates the comptime `.rate_limit = .{ .custom = … }` per-method config, and documents field-key rotation (`ZIGBASE_FIELD_KEY_V<n>` + `zigbase rewrap`) in its README.

## [0.7.0] - 2026-06-28

### Breaking

- Custom handler/hook/job signatures now receive a unified per-request `*Ctx`:
  - Untyped routes are `fn(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response` (was `fn(*RouteEvent)`).
  - Record hooks are `fn(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void` (was one-arg `fn(*RecordEvent)`).
  - Jobs are `fn(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void` (was one-arg `fn(*JobEvent)`).
  - Lifecycle hooks are `fn(ctx: *zigbase.Ctx, ev: *zigbase.events.LifecycleEvent) void`.
  - Typed routes keep `fn(req: *zigbase.Req(In)) zigbase.RouteError!Out`, but reach capabilities via `req.ctx` (`req.ctx.records()`, `req.ctx.http()`, `req.ctx.arena`, `req.ctx.app`).
- DB access is now uniform through the `Ctx` capability object: `ctx.records()` (list/get/create/update/delete), `ctx.tx()` (atomic writes), and `ctx.http()` (outbound client). In a `before*` hook, `ctx.records()` is bound to the triggering write's in-transaction connection, so a side-write commits/rolls back atomically with it.
- Removed `RecordEvent.data`, `JobEvent.reader()`/`JobEvent.writer()`, `ev.caps()`, and the public `zigbase.Data` re-export. Migrate hook/job DB access to `ctx.records()`; for raw SQL on a migration-owned table use the pooled writer via `ctx.app.pool.acquireWriter()`.

### Features

- `ctx.tx(T, fn)` runs several record writes in one atomic transaction — all
  commit, or all roll back on any returned error. The callback receives a `*Tx`
  whose `t.records()` exposes the full `Records` API; all writes share the
  in-transaction connection with no deadlock. Nesting is rejected immediately
  (`error.NestedTransaction`).
- Admin UI now includes a "Settings / Feature Flags" section (`#/settings`) where
  superusers can list, create, edit, and delete KV entries, and toggle boolean feature
  flags with a checkbox — backed by the existing `/api/settings` REST surface.
- Auth lifecycle hooks (#98): a new `.auth` config group adds **before/after** hooks for
  `register`, `logout`, `refresh`, and `password-change`, extending the Theme D
  `beforeAuthSuccess` discipline into a uniform lifecycle. Before-hooks run with a `*Ctx`
  bound to the action's connection (in-transaction for register / refresh /
  password-change), so `ctx.records()` writes commit atomically with the action; returning
  an error aborts and fails closed (rolling back where a write transaction exists — e.g. an
  aborting `beforePasswordChange` leaves the password unchanged and the reset token
  un-consumed, an aborting `beforeRegister` creates no account). After-hooks are notify-only.
  Hooks fire on `register` (auth-collection record create), `POST …/auth-logout`,
  `POST …/auth-refresh`, and `POST …/confirm-password-reset`. A typo'd hook name or a
  wrong-typed handler is a compile error. The existing `beforeAuthSuccess` and `onAuth`
  hooks are unchanged.
- Handler/hook/job capability object: handlers, hooks, and jobs now receive a
  `*Ctx` directly, exposing `ctx.records()` (filtered/sorted/paginated list +
  get/create/update/delete, with `expand`/relations), an outbound `ctx.http()`
  client, and a standard error model (`ctx.fail`/`ctx.invalid`, error→status
  mapping over the existing `{code,message,data}` envelope). Custom handlers no
  longer need to drop to raw SQL or vendor an HTTP stack.
- **Encryption key rotation** — at-rest field encryption now supports a primary (write) key plus older read-only key generations. The primary key is `ZIGBASE_FIELD_KEY` at generation `ZIGBASE_FIELD_KEY_GENERATION` (default 1, = the `v<N>:` envelope version written); older generations are supplied via `ZIGBASE_FIELD_KEY_V<n>`. Writes use the primary generation; reads dispatch on each value's envelope version. The single-key default is unchanged and fully backward compatible.
- **`zigbase rewrap` command** — re-encrypts every `.encrypted` field across all collections under the primary key, and migrates legacy plaintext into ciphertext (the supported way to enable `.encrypted` on a column that already holds plaintext). Idempotent, transactional per collection, with `--dry-run`.
- **`ZIGBASE_FAKE_NOW` now also freezes `CURRENT_TIMESTAMP` and column DEFAULTs.** The dev-only test clock previously froze the framework's own timestamps and a consumer's raw `datetime('now')` / `unixepoch('now')` / `strftime(…, 'now')`, but the SQL keywords `CURRENT_TIMESTAMP` / `CURRENT_TIME` / `CURRENT_DATE` and column `DEFAULT CURRENT_TIMESTAMP` still read the OS clock (they go through SQLite's VFS, not the SQL-function layer). On dev builds, connections now open against a wrapping VFS — a byte-for-byte copy of the default VFS with only its current-time hooks overridden — so those keywords and defaults honor the frozen instant too, making tables with timestamp defaults deterministically snapshot-testable. All file I/O still delegates to the genuine OS VFS unchanged, and the wrapper is compiled out entirely on a production build (`-Ddev-clock=false`).
- **Seeded entropy for deterministic IDs/tokens in test mode (`ZIGBASE_FAKE_SEED`)** — set `ZIGBASE_FAKE_SEED` to a decimal `u64` on a dev build to make record/field ID and token key generation reproducible across runs with the same seed, enabling stable snapshot tests. Gated by the same `dev_clock` build option as `ZIGBASE_FAKE_NOW`: compiled out on production builds, so a production binary always uses the OS CSPRNG and cannot be seeded. Closes #95.
- Expired-session garbage collection for `.session_store = .table` (#114). Enabling the
  table-mode session store now auto-installs a framework-internal recurring job that deletes
  expired `_sessions` rows in bounded batches on the writer — no opt-in required. The default
  cadence is hourly; override it with `App(.{ .session_store = .table, .session_gc_cron = "…" })`
  (UTC, minute-granularity cron syntax). Nothing is installed in the default `.epoch` mode (no
  job, no timer — the zero-overhead guarantee is preserved).
- Session management verbs on `ctx.auth()` (#99): `revokeAllSessions()` ("log out
  everywhere"), `refresh()` (sliding re-mint, other sessions stay valid), and `rotate()`
  (bump + re-mint, keep this session and kill every other). Free-function forms
  `zigbase.auth.revokeAllSessions/refresh/rotate(ctx)`. Sessions remain stateless JWTs but
  are now **revocable** via a per-auth-record token epoch (the default
  `App(.{ .session_store = .epoch })` model) — **no extra query on either the verify hot path
  or login**: the epoch is folded into the single `tokenKey` SELECT each already performs.
  Existing valid tokens keep working: tokens minted before the epoch existed and freshly
  created records both read as epoch 0.
- New comptime config key `.session_store` (`.epoch` default, or `.table`). The `.table`
  variant adds a server-side `_sessions` store for full **per-device** management:
  `ctx.auth().listActiveSessions()` (with `is_current`) and `ctx.auth().revoke(sessionId)`
  ("log out THIS device", owner-or-superuser authorized). In table mode each token carries an
  opaque `sid` and verification additionally requires a live (unexpired) session row — one
  extra indexed read per authenticated request. `.epoch` stays the default and is unchanged:
  **zero extra DB work, and enabling `.table` does not alter the `.epoch`-mode token shape**
  (the `sid` claim is simply omitted when absent). In `.epoch` mode the per-device verbs
  return `error.SessionStoreNotEnabled`.
- **Field/collection policy pipeline** — a value-transform seam at the records read/write path, applied transparently with the field schema in hand. Its first behavior ships below.
- **Transparent at-rest field encryption** — mark a `text`/`editor`/`json` field `.encrypted = true` to store it encrypted (AES-256-GCM) in SQLite while handlers, the records API, and HTTP responses see plaintext. Encrypted fields cannot be indexed, marked `.unique`, or used in a `?filter`/`?sort` (compile error / 400). Key rotation is designed into the versioned `v<N>:` envelope.
- **TTL records.** A collection may declare `.ttl_field = "<field>"` naming an existing `date`/`autodate` field as the row's expiry timestamp. A framework-internal GC reaps expired rows automatically — once at startup and then on a 5-minute interval — across every TTL-enabled collection. Opt-in and additive; collections without `.ttl_field` are untouched.
- **Framework-internal scheduled jobs.** Added an internal scheduled-job mechanism (`scheduler.concatJobs`) so the framework can run its own jobs (such as the new `_ttl_gc` sweep) alongside consumer `.cron` jobs. The scheduler now starts whenever a TTL collection is declared, even with no user cron configured.
- Built-in key→value/settings store (#87): `ctx.kv().get/set/delete` (and the curated `data.kvGet`/`kvSet`/`kvDelete`/`kvList`) over a new internal `_kv` table — small server-managed values with no collection, schema, or access rules. Superuser-managed and not public by default.
- Typed feature flags (#88): `ctx.flag(name) -> bool` and `ctx.setFlag(name, enabled)`, a typed boolean view over the same KV store (`"true"`/`"1"` truthy, unset = false).
- Superuser-only settings HTTP API: `GET /api/settings`, `GET/PUT/DELETE /api/settings/:key` for managing KV/settings values.
- The `ZIGBASE_FAKE_NOW` dev test clock now also freezes a **consumer's own raw SQL**
  `datetime('now')` / `unixepoch('now')` / `strftime(…, 'now')` (and `date`/`time`/
  `julianday`, including their zero-argument implicit-`'now'` forms). SQLite's date/time
  builtins are shadowed on every reader and writer connection so they resolve to the frozen
  instant, while explicit datetimes and modifiers (`'+1 day'`, the `strftime` format string)
  pass through to genuine SQLite. This makes e2e/snapshot tests of consumer routes that use
  raw time SQL fully deterministic (#84). Like the rest of the test clock it is **compiled
  out of production builds** (`dev_clock` build option; off in any release build) — a prod
  binary is byte-for-byte unaffected and never reads the env var.
- **Dev-only test-mode capture for outbound mail + HTTP (`zigbase.testcapture`)** — for
  deterministic e2e/integration tests, the framework can now capture what it *sent* and
  inject canned responses: an in-memory mail **outbox** (`testcapture.mail`) records every
  `Mailer.send` (from/to/subject/body, optionally suppressing real delivery), and an HTTP
  **capture/mock** seam (`testcapture.http`) records every outbound `ctx.http()` call and
  returns canned responses matched by URL substring — with no network — mirroring the OAuth
  `Transport` injection. Tests read/assert the captures via a small API (`mail.count/get/
  find`, `http.mock/requestAt/requests`). Like the test clock, it shares the **same comptime
  gate** (`dev_clock` build option; on in `Debug`, off in any release build): on a production
  build `testcapture.enabled` is `comptime false`, both seams fold away, and the binary is
  byte-for-byte unaffected with no runtime branch or perf cost (#96).
- Auth lifecycle hook `beforeAuthSuccess` (#80): a writable, transactional, abortable hook
  that runs after credentials/token verification and **before** the session is issued, with
  a `*Ctx` bound to the login's in-transaction writer. Its `ctx.records()` writes commit
  atomically with the login; returning an error rolls them back (and, for magic-link,
  un-consumes the link token) and blocks the session (fail closed). Fires on the unified
  `POST /api/collections/:col/auth/:method/complete` endpoint (password / otp / webauthn /
  oauth2 / custom) and the magic-link `consume` link. The existing notify-only `onAuth` is
  unchanged and still fires once, after issuance. Motivating use case: claim anonymous
  records on a user's first login.
- Session management surface `ctx.auth()` with `clearSession` (#86): `ctx.auth().clearSession()`
  and `zigbase.auth.clearSession(ctx)` return the cleared `zb_auth`/`zb_csrf` cookies built
  from the framework's own cookie policy, so a logout handler is one line and can never drift
  from the built-in logout.
- TTL collections (`.ttl_field`) now exclude expired rows from **every read** (list, get, expand, `ctx.records()`). The predicate is ANDed with any filter, access rule, and keyset cursor automatically — no manual `expires_at > @now` filter needed. Semantics match the GC: `NULL` ttl = never expired; unparseable ttl = fail-safe visible; non-canonical date forms (offsets, space separator, date-only) compared correctly as instants via `strftime`.
- Typed TypeScript client for built-in auth methods: `zig build gen-client` now emits
  precise input/result types for the `client.auth.<collection>.<method>.initiate/complete`
  surface of the three built-in non-password methods, replacing the previous untyped
  `Record<string, unknown>` / `unknown` stubs. `magic_link` initiate takes `{ identity }`
  and resolves `void` (204); `otp` initiate takes `{ identity }` (→ `void`) and complete
  takes `{ identity, code }`; `webauthn` initiate takes `{ identity? }` and resolves
  `{ challenge, rpId, ceremonyId, timeout }`, complete takes
  `{ ceremonyId, credentialId, authenticatorData, clientDataJSON, signature }`. Every
  built-in `complete` resolves to `{ token }` (`AuthMethodResult`). Custom methods
  (`.custom` slugs) remain on the untyped stubs for now (a typed-I/O declaration API for
  custom methods is a planned follow-up).

### Fixes

- `before*` record hooks now run INSIDE the triggering write's transaction on the
  HTTP create/update/delete path. A before-hook's own `ctx.records()` side-writes
  and the primary row write now commit atomically, and a before-hook that returns
  an error — or a denied access-rule guard — rolls the whole transaction back, so
  a rejected write persists nothing (fail closed). Previously a before-hook
  side-write committed independently, before the triggering write.
- `ctx.records()` now allocates its results on a per-invocation arena instead of
  the long-lived process allocator. This fixes a heap leak that grew per request
  on routes and unboundedly for per-minute cron jobs. Route results live on the
  request arena; job, `App.submit`, and lifecycle-hook results live on a
  per-invocation arena freed when the invocation ends. No API change.
- **Unknown collection/field keys now fail the build.** A typo'd key in a comptime `.collections` spec — collection-level (e.g. `.ttl_filed`), under `.rules`/`.auth` (e.g. `.viewRul`), or on a field (e.g. `.requied`, `.encrypte`) — was silently ignored; it is now a `@compileError` that lists the recognized keys for that spec.
- `onError` / Sentry integration now fires only for server-side (5xx) errors; client errors (4xx) no longer trigger the error handler or Sentry reports.
- Auth methods configured with a custom `rate_limit` (`.{ .custom = .{ .max, .window_s } }`) now actually honor that `max`/`window_s` instead of silently falling back to the global limiter. Each method gets a dedicated bucket scoped by collection + method slug (keyed on the same IP/identity subject as the global limiter), so distinct methods and collections never share a budget, and a custom limit applies even when the global limiter is disabled (`ZIGBASE_RATE_LIMIT_MAX=0`).
- Uploaded files are now cleaned up when a record update fails validation, preventing orphaned files from accumulating in storage.

### Performance

- Skipped a redundant buffer duplication on the non-encrypted JSON field read path, reducing per-request allocations for records with JSON fields.

### Security

- Each key generation derives an independent AES-256 key via domain-separated HKDF (`zigbase-field-encryption-v<n>`), so generations never share key material; generation 1 keeps the original domain for backward compatibility. Reads remain strict and fail-closed: a value whose envelope version has no configured key (unknown/missing generation), a wrong key, or a tampered/malformed value never yields plaintext. `rewrap` is fail-closed too — a cell it cannot decrypt aborts the run with the offending row reported and that collection's transaction rolled back, so no data is lost. Rotation keys come only from the environment and are never persisted or logged.
- **Startup now fails closed for runtime-created encrypted fields.** A server with an `.encrypted` field added at runtime (via the collections API while a key was set) would previously start on a later restart *without* `ZIGBASE_FIELD_KEY`. Startup now scans the live database schema after provisioning and refuses to start (`error.FieldKeyRequired`) if any DB-resident collection declares an encrypted field while no key is configured — matching the existing comptime guard. (The value layer already failed closed on read/write, so plaintext never leaked; this just turns a silently half-broken server into a loud refusal.)
- Outstanding session tokens can now be invalidated server-side before they expire. A
  bumped token epoch causes verification to reject every prior `.auth` token for that
  principal (fail closed — the epoch is trusted only after signature verification). Use it
  on password change, suspected compromise, or an explicit "sign out of all devices".
- With `.session_store = .table`, a revoked or expired per-device session is rejected at
  verify time (fail closed), and per-session `revoke` is authorized to the owning user or a
  superuser (a user cannot revoke another user's session).
- Field encryption uses an authenticated AES-256-GCM envelope (`v1:` + base64url(nonce‖ciphertext‖tag)) with a fresh per-write nonce, sharing one audited primitive with OAuth-secret encryption via domain-separated key derivation. The key comes only from `ZIGBASE_FIELD_KEY` (HKDF-derived, never persisted or logged); the server refuses to start if an `.encrypted` field is declared without it. Reads are strict and fail-closed: a non-envelope (legacy plaintext), wrong key, or tampered value never yields plaintext.

### Internal

- Remove the deferred legacy `app`/`arena` fields from `Req(Input)` in `route_types.zig`
  (Theme A cleanup: examples/blog and examples/golfsim both already read `req.ctx.arena` /
  `req.ctx.app`; the fields were never needed and the migration comment is now moot).
- Update the stale `AuthApi` doc comment in `ctx.zig` that called `refresh`, `rotate`,
  `listActiveSessions`, and `revoke` "deferred" — all four were shipped in PRs #111/#112
  (session management, Variant B); the comment now documents the full surface including
  the `session_store = .table` requirement for per-device verbs.

## [0.6.0] - 2026-06-23

### Features

- **Auth-aware `Data.create`** — `Data.create` on an **auth** collection now runs the same credential transforms as the HTTP records handler (generates the per-record `tokenKey`, forces `verified=false`, hashes `password` when supplied), so a programmatically-created record works with `zigbase.auth.issueSession` / `mintLinkToken` immediately. `password` is **optional**, enabling passwordless (magic-link) sign-up to provision an account without hand-writing credential columns. Non-auth collections are unaffected; the lower-level engine `records.create` still does a raw insert for imports/migrations.
- `magic_link` and `otp` auth methods now honour `auto_create: true` — when an unknown identity calls `initiate`, a passwordless account is provisioned automatically (email set from the identity, `verified = false`) and the link or code is sent as usual. Enables "sign up or sign in" in one step. Accounts are created with `verified = false`; pair with `require_verified` only when a verification flow is in place.
- **`CommandMailer` (local-command / sendmail mailer)** — a built-in mailer that pipes the serialized RFC822 message to a local MTA's stdin (e.g. `sendmail -t -i` or `msmtp -t`) and treats exit 0 as success. The standard "delegate delivery to a local relay, hold no SMTP credentials in the app" setup. Selected via the new `ZIGBASE_SENDMAIL_COMMAND` env var (whitespace-split into argv; `From:` from `ZIGBASE_SMTP_FROM`), which takes precedence over SMTP in `DefaultMailerPlugin`. Re-exported as `zigbase.CommandMailer`.
- **Comptime `.indexes` on collection literals** — a `zigbase.App(.{ .collections = … })` collection may now declare `.indexes = .{ .{ .name, .fields, .unique?, .collation?, .where? }, … }`, lowered into the provisioned schema and emitted as `CREATE INDEX` DDL (case-insensitive via `.collation = .nocase`; conditional-unique via `.where`). Index `.fields` reference fields by their declared name.
- **`ZIGBASE_PUBLIC_URL` → clickable magic-link emails** — set `public_url` (env `ZIGBASE_PUBLIC_URL`) and the built-in `magic_link` method emails an absolute link to its consume endpoint (which sets the session cookie and redirects) instead of a bare token. Unset preserves the previous raw-token email. Lets a stock binary offer real magic-link login by configuration alone.
- Comptime OAuth2 providers: declare `.auth.oauth2 = .{ .enabled = true, .providers = .{ .{ .name = "google", .redirectUrls = .{…} } } }` on an auth collection in `.collections`. The runtime `clientId`/`clientSecret` are sourced from `ZIGBASE_OAUTH_<NAME>_CLIENT_ID` / `ZIGBASE_OAUTH_<NAME>_CLIENT_SECRET` at provisioning time and the secret is encrypted (AES-256-GCM) before it is persisted — secrets never live in the binary. (Applied on first creation only; rotate via the admin API.)
- **Dev-only injectable test clock (`ZIGBASE_FAKE_NOW`)** — freeze the framework's "now" to an ISO-8601 UTC instant (e.g. `2029-03-07T16:00:00Z`) so time-boundary scenarios (token expiry, scheduling, challenge/cursor TTLs) are deterministic in e2e suites. Every framework-controlled timestamp routes through one clock seam (`src/clock.zig`) that honors the override. **Gated off in production:** compiled in only on a `dev_clock` build (on in `Debug`, off in any release build / shipped binary), so a production binary never reads the env var and time can never be frozen. Scope and the production gate are documented in [Known limitations → Testing](./known-limitations). Closes #58.
- `golfsim` example: `require_verified = true` on the `users` auth collection — guests must verify their email before a session is minted (booking/payments justification).
- `golfsim` example: OTP passwordless login (`auto_create = false`) for existing verified accounts; first-time onboarding remains password signup + email verification.
- `golfsim` example: comptime indexes — `NOCASE` unique on `users.email` (prevents case-variant duplicate accounts) and a partial composite index on `bookings(listing, starts_at) WHERE status != 'cancelled'` (backs the double-booking overlap check and availability route).
- `golfsim` example: OAuth2 "Sign in with Google" via comptime `.auth.oauth2`; client credentials sourced from `ZIGBASE_OAUTH_GOOGLE_CLIENT_ID` / `ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET` at provision time; Google-verified accounts are created `verified=true`.
- `golfsim` frontend: multi-step `Auth` component covering password sign-in, OTP initiate/complete, signup, email-verification, and Google OAuth2 flows.
- Blog example: adds built-in `magic_link` auth on `users` (passwordless login via
  emailed link, `auto_create = true`, 1 h TTL, server-redirects to `/`).
- Blog example: `NOCASE` unique comptime index on `users.email` via `.indexes = .{...}`
  — prevents case-variant duplicate accounts.
- `examples/plugins` showcases the full advanced auth surface: `authors` auth collection with WebAuthn (passkeys) + a custom `ApiTokenMethod` plugin; `commenters` auth collection with magic-link (`auto_create=true`); `onAuth` hook logging all three methods; comptime `NOCASE` collation index on `authors.contact_email`; frontend magic-link comment flow; `beforeCreate` hook auto-populating `commenter` from session.
- **Comptime index collation + partial predicates** — `schema.Index` gains `collation` (`.binary` default / `.nocase`, applied per indexed column) and an optional `where: ?[]const u8` partial-index predicate. Case-insensitive indexes (`CREATE INDEX ... ("email" COLLATE NOCASE)`) and conditional-unique indexes (`... WHERE deleted_at IS NULL`) are now expressible in the comptime `.collections` schema and emitted in the generated `CREATE INDEX` DDL, instead of requiring an out-of-band raw-SQL bootstrap. Defaults preserve existing DDL and JSON round-trip behavior.
- **`mintLinkToken` opaque bound payload** — `zigbase.auth.mintLinkToken` takes a trailing `opts: MintOptions` arg whose `payload` (default `""`) binds a small opaque string into the single-use token's signed `pl` claim, returned by `verifyLinkToken` as `claims.pl`. Lets a magic-link flow carry tamper-proof bound state (e.g. a post-login redirect target) in the one token instead of an unsigned `&next=` URL param. Signed, not encrypted — readable-but-tamper-proof; keep it small. Existing call sites add `.{}`.
- **`GET .../auth/magic_link/consume` — browser-friendly email-link login** — `GET /api/collections/:col/auth/magic_link/consume?token=…&redirect=/app` verifies and consumes the single-use link token (same replay guard as `complete`), mints the session through the shared `issueSession` seam (so `onAuth(.magic_link)` fires and the `zb_auth`/`zb_csrf` cookies are set), honors the `require_verified` gate, and `302`s to the redirect target. Two new per-method `magic_link` options shape the redirect: `redirect_default` (fallback path when `?redirect=` is absent or rejected; defaults to `/`) and `redirect_allow` (allow-list of exact paths or `/`-suffixed prefixes; an empty list permits any safe relative path).

### Fixes

- **Comptime `.indexes` is no longer silently ignored** — the documented `.indexes` key on collection literals was never lowered by the provisioner; it is now applied.
- Corrected false claim in `examples/plugins` migration 0002 comment: provisioned collection columns are human-named (field.name), not id-named. Raw migrations targeting migration-owned tables remain valid; the rationale is now accurate.

### Changed

- **Documented the CSRF double-submit contract for cookie sessions** — the API reference now spells out that cookie-session clients must echo the readable `zb_csrf` cookie in the `X-CSRF-Token` header on unsafe methods (`POST`/`PUT`/`PATCH`/`DELETE`); `GET`/`HEAD`/`OPTIONS` are exempt. A failed CSRF check makes the request anonymous, so the response status follows the collection's access rules — `403` on a create denial, `404` on an update/delete denial against a protected record (existence-hiding) — not a flat `403`. Documentation only; no behavior change.

### Performance

- Trim unused subsystems from the vendored SQLite amalgamation (`OMIT_UTF16`, `OMIT_DECLTYPE`, `OMIT_DEPRECATED`, `OMIT_PROGRESS_CALLBACK`, `OMIT_TRACE`, `OMIT_SHARED_CACHE`, `DEFAULT_MEMSTATUS=0`). The framework uses only SQLite's UTF-8 prepare/step/bind/column/exec surface, so this is a pure build-cost/size win — a smaller shipped binary and ~10% faster SQLite C compile — with no behavior change. FTS5 is intentionally retained.

### Security

- **Server-side open-redirect guard on magic_link consume** — the `?redirect=` target is validated server-side so consumers never re-implement the guard: only same-origin relative paths are honored. Off-origin, protocol-relative (`//host`), scheme, CRLF/control-byte, backslash, `.`/`..` path-traversal segments, and still-encoded `%2e`/`%2f`/`%5c` payloads are all rejected and fall back to `redirect_default`.

### Internal

- **Changelog-fragments workflow** — changes now add a `changelog.d/<slug>.md` fragment (with one or more `### <Section>` headings) instead of editing `CHANGELOG.md`, so parallel PRs never conflict on the shared changelog. `scripts/assemble-changelog.sh` aggregates the fragments per section into a new version block in `CHANGELOG.md` (and its `site/` mirror) at release time (run from `scripts/release.sh`) and deletes them. See [`changelog.d/README.md`](changelog.d/README.md).
- Corrected the "provisioned columns are named by a stable field id" claim in `CLAUDE.md` and `docs/framework.md`: physical SQLite columns use the human field name; the stable field id only matches columns across additive rebuilds.
- Blog example frontend: new magic-link login form in `Editor.tsx` (email → initiate
  → "Check your email" state), cookie-session detection via `getMe()` on mount, and an
  `AuthStatus` nav island for logged-in display after consume redirect.
- Blog example README: document `ZIGBASE_PUBLIC_URL`, the fake `blog.test` URL, and
  the email index.
- Cache Zig's **local** cache dir (`ZIG_LOCAL_CACHE_DIR`) across CI runs, where the compiled SQLite object actually lives. The previous "global cache" step only persisted toolchain artifacts (compiler_rt/translate-c), so every CI run recompiled the SQLite amalgamation once per `zig build` invocation (~6×/run: main + each example + the unit job). All builds in a job now share one cached local dir, eliminating those recompiles on warm cache. Corrected the misleading comment on the global-cache step.
- Use deliberately weak argon2id parameters in **test builds only** (keyed on `builtin.is_test`). The unit suite hashes/verifies passwords across ~700 tests; at production cost (`interactive_2id`, 64 MiB) that KDF work alone was ~25 s of every `zig build test`. A warm `zig build test` now runs in ~6 s (was ~32 s). The shipped server binary and the Playwright browser suite (which drives the real binary) are unaffected and keep full-strength params.

## [0.5.0] - 2026-06-21

### Removed

- **BREAKING: legacy OAuth2 endpoints removed** — `GET .../oauth2-providers`, `POST .../oauth2-init`, and `POST .../auth-with-oauth2` no longer exist. OAuth2 is now exclusively the contract method: `POST .../auth/oauth2/initiate`, `POST .../auth/oauth2/complete`, and `GET .../auth/oauth2/providers` (discovery).

### Added

- **OAuth2 as a first-class `AuthMethod`** — exclusively at the contract endpoints `POST /auth/oauth2/initiate`, `POST /auth/oauth2/complete`, and `GET /auth/oauth2/providers` (discovery); all paths share one implementation and the single `onAuth` session seam. See [docs/api.md](docs/api.md#oauth2) for request/response shapes.
- **Pluggable auth-method system** — the `AuthMethod` contract (`initiate`/`complete` + `AuthCtx` blessed helpers + `Resolution`) lets the framework own session issuance while methods plug in verification logic. Built-ins implement the same contract with no privileged path.
- **Per-collection `.auth.methods` config** — enable and configure built-in methods per auth collection: `password` (backward-compat default when `.methods` is absent), `magic_link` (TTL, auto-create flag), `otp` (code length, TTL), `webauthn` (rp_id, rp_name, origin, credentials_collection). Each method has a `rate_limit` knob (`.default` | `.off` | `.{ .custom = .{ .max, .window_s } }`).
- **App-level `.auth_methods`** — register custom `AuthMethod` plugin TYPES at comptime (same pattern as `.storage`/`.mailer`); a type missing `create`/`method`/`deinit` is a compile error.
- **Auto-mounted auth endpoints** — for every enabled method, the framework auto-mounts `POST /api/collections/:col/auth/:method/initiate` and `.../complete`; the dispatch enforces enablement (404 for disabled/unknown methods) and default rate-limits.
- **`magic_link` built-in** — enumeration-safe `initiate` (always 204), single-use link token emailed via the configured mailer, `complete` verifies+consumes and mints the session.
- **`otp` built-in** — enumeration-safe `initiate` emails a 6-digit code stored in the `ChallengeStore`, `complete` verifies the code.
- **`webauthn` built-in** — passkey login via the two-phase contract (initiate returns `PublicKeyCredentialRequestOptions`; complete verifies the signed assertion). Passkey registration via two authed endpoints (`register/begin` / `register/finish`). ES256 (P-256, COSE -7) and Ed25519 (COSE -8) supported; attestation `fmt:"none"` (v1); signCount clone detection (fail-closed); credentials stored in `_webauthnCredentials`.
- **`ChallengeStore`** (`_authChallenges`) — TTL'd, GC'd single-use server-side challenge storage used by `otp` and `webauthn`, and accessible to custom plugins via `AuthCtx.challengeStore()`.
- **`onAuth` method tagging extended** — `AuthEvent.method` is an enum: `.password`, `.oauth2`, `.magic_link`, `.otp`, `.webauthn`, or `.custom` for custom plugins.
- **RPC client generation for auth endpoints** — the generated TypeScript client exposes non-password auth-method endpoints under an `auth` surface (initiate/complete stubs, currently untyped).
- **`zigbase.auth` consumer surface for custom auth flows** — `issueSession` (and `RouteEvent.issueSession`), single-use magic-link tokens (`mintLinkToken` / `verifyLinkToken` / `consumeLinkToken`), `deliverAuthMail`, and `rateLimit`. All session minting now funnels through one seam that always fires `onAuth`.

### Security

- **OAuth2 server-side CSRF `state` is now ON by default** (`ZIGBASE_OAUTH_STATE_SERVER` defaults to `true`). The `initiate` endpoint issues a `state` value and `complete` requires and consumes it before contacting the provider. **Behavior change:** OAuth2 clients must use the `initiate`→`complete` flow; bare `complete` calls without a valid `state` are rejected with `400`. Set `ZIGBASE_OAUTH_STATE_SERVER=false` to restore the previous client-driven mode.
- **New `require_verified` per-collection auth option** (default `false`). When `true`, any login attempt for an unverified record is rejected with `403`. This gate applies to **all** methods — including WebAuthn/passkey and OAuth2 accounts whose provider email was unverified (those are created `verified=false`). Enabling it will lock out such users until they complete email verification.
- **OAuth2 no longer claims unverified provider emails** — when a provider does not mark the email as verified, the new account is created with `verified=false` and the `email` field is left unpopulated. This prevents email-squatting via an OAuth2 provider that does not verify addresses.
- **WebAuthn credential binding** — a passkey is now bound to the collection it was registered on; presenting it on a different collection returns `401`.
- **WebAuthn `require_uv` option** (default `false`). When `true`, the server rejects assertions that do not set the user-verification bit (`UV=1`), requiring biometrics or PIN at the authenticator.
- **WebAuthn COSE key curve validation** — ES256 credentials must use the P-256 curve; EdDSA credentials must use Ed25519. A mismatched algorithm/curve is rejected.

### Performance

- **Auth I/O off the write lock.** `otp` and `magic_link` release the DB connection before the SMTP send. WebAuthn signature verification runs before acquiring the write lock (only the signCount update and challenge consume hold it). `oauth2Providers` uses a reader connection. The authenticated-request fast path no longer does a redundant collection lookup. No auth method holds the single writer across blocking I/O or CPU-heavy verification.

### Changed

- **Auth methods now manage their own DB connections** — each method holds one connection across its work; OAuth2 `complete` releases the writer during the provider HTTP exchange (no write-throughput stall); password `complete` uses a reader (argon2 is read-only). Neither method blocks writes during I/O.
- **Session issuance (password, refresh, OAuth2) routes through a single
  `issueSession`+`emitAuth` seam** — custom routes can no longer mint a session that
  skips the `onAuth` hook.

## [0.4.1] - 2026-06-19

### Added

- **`zigbase --version`** (and the `version` subcommand) prints build provenance —
  the `build.zig.zon` version, the git commit, the build mode, the target triple,
  and the Zig version. Implemented at the framework level, so every binary built
  on ZigBase (including the examples and downstream apps) inherits it.

### Changed

- **Prebuilt server binaries are now stripped** — release builds drop debug
  symbols, cutting each `@zigbase/server-<platform>` package and GitHub-release
  tarball from ~24 MiB to ~7 MiB (about 73% smaller) with no API or behavior
  change. `npm install @zigbase/server` and `npx @zigbase/typegen` download
  much less.

### Added

- **Untyped route handlers in framework mode.** `.routes` now accepts the raw
  `fn(*RouteEvent) anyerror!http.Response` handler form alongside typed
  `Req(Input)`/`Output` handlers. An untyped handler owns its full response, so it can
  set/clear a session cookie, return a redirect (`307`), or serve a non-JSON
  content-type (e.g. `text/calendar`, an HTML OAuth handoff) — things the typed JSON
  thunk cannot express. Untyped routes carry no typed `Input`/`Output` and are excluded
  from the generated TypeScript `zb.rpc.*` client, so they never produce a client method
  that would mis-parse their response.
- **`text.pattern` is now enforced on record writes** via a pure-Zig, linear-time
  (DoS-safe) Thompson-NFA matcher (`src/regex.zig`). Matching is unanchored (substring);
  anchor with `^…$` for a full-string match. Supported syntax: literals, `.` (any codepoint
  except `\n`), anchors `^`/`$`, character classes `[…]`/`[^…]`/ranges, predefined classes
  `\d \D \w \W \s \S` (ASCII), escapes `\t \n \r \f \v` and `\`-escaped metacharacters,
  alternation `|`, groups `(…)`/`(?:…)`, and quantifiers `* + ? {m} {m,} {m,n}`. Patterns
  are validated when a collection is saved (a bad regex is a `400` field error), and at build
  time (`@compileError`) for comptime schema literals.
- **`date` field `min`/`max` are now enforced** on record writes, with date normalization
  (`src/datetime.zig`) so mixed formats (e.g. `2026-06-10 08:00:00` vs
  `2026-06-10T08:00:00Z`) compare correctly. Malformed or out-of-range date values are
  rejected with `400` (`validation_date`). Bounds are validated at collection-save time
  and at build time (`@compileError`) for comptime schema literals.

### Fixed

- **The HTTP status line now matches the response body for *every* status a handler
  returns, not a hand-picked subset.** `setZapStatus` previously mapped a short list of
  codes and sent everything else as `500`, so a custom route's `401` auth rejection, a
  `307` magic-link redirect, `410`, `502`, and similar went out with a `500` status line
  even though the JSON body still said e.g. `401`. The mapping now derives from
  `zap.http.StatusCode`'s named values, so any standard code zap defines is passed through
  and only genuinely-unknown codes fall back to `500`.

## [0.4.0] - 2026-06-13

This round makes ZigBase **safe-by-default**: a security audit's findings were fixed and
the access-rule and deployment defaults were hardened. **It contains breaking changes** —
read the migration notes below before upgrading. The full audit is in
[`docs/security-audit.md`](docs/security-audit.md).

### ⚠ Breaking changes

- **Access rules are now safe-by-default.** A blank rule — `null` **or** the empty string
  `""` — now means **Locked (superusers only)**. Previously `""` meant **allow-all (public)**
  while `null` meant locked; that inverted-from-intuition default was the single easiest way
  to ship a collection wide open. The **only** way to make a rule public is now the explicit
  sentinel **`"@public"`**, and ZigBase logs a prominent startup warning for every `@public`
  rule so a wide-open collection is never silent.
  - **How to migrate:** audit every collection's `list`/`view`/`create`/`update`/`delete`
    rules. Any rule that was `""` *intending* "anyone" must become `"@public"`. Any rule that
    was `""` merely as a placeholder is now correctly Locked (superuser-only) — no change
    needed unless you relied on it being open. The admin UI rule editor is now a three-state
    selector (**Locked / Expression / Public**) and confirms before opening a rule to the public.
- **Secure-by-default deployment.**
  - **Bind defaults to `127.0.0.1:8090`** (loopback); was `0.0.0.0`. Expose all interfaces
    explicitly with `--http-host 0.0.0.0` (`ZIGBASE_HTTP_HOST`), behind a firewall / reverse proxy.
  - **`ZIGBASE_JWT_SECRET` is auto-generated and persisted** under the data dir on first run
    when unset. The shared `dev-insecure-secret-change-me` default is gone, and a provided
    secret shorter than 32 bytes is refused at startup.
  - **Auth cookies are `Secure` (HTTPS-only) by default.** For plain-HTTP local dev pass
    `--insecure-cookies` (`ZIGBASE_COOKIE_SECURE=false`).
  - **An empty `ZIGBASE_REALTIME_ORIGINS` now denies cross-origin browser WebSocket upgrades.**
    Same-origin upgrades (the embedded admin UI and any frontend served from the same binary)
    are always allowed; set `--realtime-origins` only for a *separate-origin* browser app.
  - **The rate limiter ignores `X-Forwarded-For` / `X-Real-IP` unless `--trust-proxy`**
    (`ZIGBASE_TRUST_PROXY=true`) is set. Direct exposure is now safe by default; enable
    `--trust-proxy` only behind a trusted reverse proxy.
- **`perPage` on record list queries is clamped to 500.**

### Security

- **SMTP/RFC5322 header injection** fixed — CR/LF/NUL rejected in mail `to`/`subject`/`from`
  and in the SMTP command path.
- **`email`-field validation** — rejects control characters and obviously-malformed addresses.
- **Realtime delete authorization** — delete events are authorized against a pre-delete
  snapshot, so owner-scoped collections no longer leak deleted record ids to other subscribers.
- **Realtime subscribe auth** — subscribing to a non-`@public` collection now requires auth.
- **Single-use tokens** — verification and password-reset tokens are now strictly single-use.
- **DoS caps** — a global WebSocket connection cap and a multipart part-count cap (plus the
  `perPage` clamp above).
- **Static symlink escapes refused** — served files are canonicalized and must resolve within
  the static root.
- **Optional server-side OAuth `state`** — an opt-in CSRF `state` store
  (`ZIGBASE_OAUTH_STATE_SERVER`); PKCE remains required in both modes.

### Added

- New CLI flags / env vars: `--http-host` (`ZIGBASE_HTTP_HOST`), `--insecure-cookies`
  (`ZIGBASE_COOKIE_SECURE`), `--trust-proxy` (`ZIGBASE_TRUST_PROXY`), `--realtime-origins`
  (`ZIGBASE_REALTIME_ORIGINS`), `ZIGBASE_OAUTH_STATE_SERVER`.
- Admin UI: a three-state API-rule editor (**Locked / Expression / Public**) that confirms
  before making a rule public.
- Framework: `zigbase.JobEvent` is re-exported at the top level (alongside `RecordEvent` /
  `RouteEvent` / `ErrorEvent`); comptime guards now give actionable compile errors for a
  mistyped `.migrations` value or a storage/mailer plugin missing a contract method.

### Fixed

- Large comptime `.collections` schemas (~5+ collections) no longer fail to build with
  "evaluation exceeded 1000 backwards branches" — the lowering raises its own eval-branch
  quota (a downstream `@setEvalBranchQuota` could not reach it).

## [0.3.0] - 2026-06-11

### Fixed
- **Multipart form values are no longer type-guessed by the HTTP layer.** The
  multipart parser was rewritten as a self-contained RFC 2046 parser over the
  raw request body. Previously, facil.io coerced form values at parse time
  (`45.00` → float, `"true"` → bool, `"123"` → int, `"007"` → `7` with the
  original text destroyed), so string-expecting fields failed validation and
  **fixed-mode number fields could not be set in a file-upload request at
  all**. Values now arrive byte-for-byte as sent, then a schema-aware coercion
  pass makes multipart input behave exactly like a well-formed JSON client.
- **Malformed multipart bodies return a clear `400` ("Invalid multipart
  body.")** instead of falling through to the JSON parser's misleading
  "Invalid JSON body."; out-of-memory during parsing propagates instead of
  masquerading as a 400.
- **Multipart parser edge cases:** boundary delimiters are validated per
  RFC 2046, so content containing a boundary-prefixed decoy can no longer
  truncate a value or smuggle extra form fields; flag-style (valueless)
  `Content-Disposition` parameters no longer drop the part; `name[]` bracket
  notation (PHP/jQuery convention) is normalized again; repeated `<field>-`
  removal keys delete all listed files; zero-byte file parts are skipped
  (matching the previous behavior); LWSP around `=` in the boundary parameter
  is tolerated.

### Added
- **Admin UI: a `scale` input for fixed-mode number fields** in the schema
  editor (shown when the mode dropdown is set to `fixed`). Together with the
  multipart fix above, fixed-point (money) fields are now fully usable from
  the admin UI — creatable in the editor and editable in the record drawer,
  file uploads included.

### Changed
- **`min`/`max` on text and number fields are now enforced** on record writes
  (previously stored but silently ignored). Violations return `400` with
  `validation_min` / `validation_max` on the offending field; text length is
  counted in unicode codepoints; number bounds are inclusive. **Note:**
  pre-existing records that violate their declared bounds will fail
  full-record re-saves (e.g. from the admin UI drawer) until corrected.
- **Multipart input semantics:** an empty value clears an optional non-text
  field to `null` (matching JSON `null`); a single occurrence of a multi-value
  field wraps into a one-element array (repeated keys already became arrays);
  repeated non-file keys are preserved as arrays instead of being dropped.

## [0.2.0] - 2026-06-10

### Fixed
- **Provisioning no longer leaks at shutdown:** `applySpecs` and `runMigrations`
  now wrap all internal allocations in a short-lived arena (backed by the
  caller's allocator), so intermediate allocations from `topoOrder`,
  `collections.create` / `ddl.quoteIdent`, `schema.indexesToJson`, and the
  `prov:` migration-name string are all freed before the call returns. The
  long-lived gpa accumulates nothing during startup provisioning.
- **Reserved field names in comptime `.collections` are rejected at compile
  time:** declaring a field whose name is reserved by the engine (`id`,
  `created`, `updated`, `email`, `username`, `passwordHash`, `tokenKey`,
  `verified`) now produces a clear `@compileError` at build time rather than an
  opaque validation failure at startup.

### Added
- **Static file serving:** root-path fallback with four comptime modes — runtime
  `--serve-static <dir>` flag (default), `.disabled`, comptime-hardcoded `.dir`, or
  assets fully `.embedded` in the binary via the new `embedStaticDir` build helper
  in `build.zig`. Embedded mode computes a CRC32 content `ETag` at build time and
  handles `If-None-Match`/304 itself. Dir mode (`--serve-static` or comptime `.dir`)
  delegates caching to facil.io's `sendFile` (`ETag`, `Last-Modified`,
  `Cache-Control: max-age=3600`, 304). All modes add `X-Content-Type-Options: nosniff`
  and lexical traversal protection (`..`, backslash, NUL). Static misses return
  plain-text 404; `/api/*` misses keep the JSON envelope.
- **Example frontends:** all three examples now ship an Astro + React-islands
  frontend (one per static mode: blog = runtime flag, golfsim = hardcoded dir,
  plugins = embedded). Blog and golfsim also gain comptime `.collections` schemas so
  the examples provision themselves at startup.

## [0.1.0] - 2026-06-10

First public release: a single-binary, PocketBase-inspired (not API-compatible)
backend-as-a-service in Zig 0.16, plus an embeddable Zig framework.

### Added
- **Collections & schema engine** with migrations and a `migrate` CLI command.
- **Records CRUD** with a typed query API: `filter` (comparison + `&&`/`||` + relation-path traversal + `@request.*` macros), `sort`, `expand`, and pagination.
- **Per-collection API access rules** (list/view/create/update/delete): superuser-only, public, or filter-expression.
- **Authentication** — argon2id password hashing, JWT sessions over an httpOnly cookie with double-submit CSRF (and bearer tokens), and a `superuser create` CLI command.
- **OAuth2** — client-driven PKCE with Google / GitHub / Microsoft / Discord presets; AES-GCM-encrypted client secrets at rest.
- **Realtime** over WebSocket — rule-filtered create/update/delete events, per-subscription filters.
- **File storage** — local-disk backend behind an S3-ready storage interface; protected files via short-lived tokens.
- **Embedded admin UI** at `/_/` — a no-build Preact SPA (collections, records, schema editor, realtime live-view, OAuth2 config).
- **Embeddable Zig framework** — extend ZigBase from your own Zig app via comptime configuration: record lifecycle hooks, custom HTTP routes (with `public`/`authed`/`superuser` gating), auth/file/lifecycle/error events, a cron/interval/reactive job scheduler with backoff-retry and a worker pool, and `app.submit` for ad-hoc background work. Events expose `writer()` / `reader()` RAII DB accessors. Misconfiguration (unknown config keys, typo'd hook phases) is a compile error.
- **Comptime schema definition** — declare collections in Zig via `App(.{ .collections = .{ ... } })`, provisioned at startup with **additive auto-migration** (creates missing collections, adds new fields, resolves relations by name); non-additive changes go through an explicit `.migrations` escape hatch.
- **Pluggable storage & mailer backends** — `App(.{ .storage = T, .mailer = T })` selects a comptime backend type; defaults are local-disk storage and a log/SMTP mailer.
- **SMTP mailer with TLS** — verification and password-reset email is delivered over SMTP (plaintext / STARTTLS / implicit TLS) when configured; logs the tokens in dev when SMTP is unset.
- **Auth rate limiting** — login, verification, and password-reset endpoints are rate limited (fixed window, configurable, disable-able), keyed on the proxy-supplied client IP with a per-identity fallback.
- **Comptime footprint levers** — `App(.{ .pools = .{ ... } })` tunes the warm-reader pool, job-worker pool, per-thread stack size, and SQLite page cache.
- **Performance** — a warm reader-connection pool and a blocking-mutex writer for higher write throughput under contention.
- **Apache-2.0 license** and cross-platform release binaries (Linux + macOS).

### Known limitations
See [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md) — notably: SMTP must be configured for email delivery in production (tokens are logged otherwise); rate limiting trusts proxy-supplied client IPs; auto-migration is additive-only; and the scheduler is single-process.

[0.4.1]: https://github.com/valthon/zigbase/releases/tag/v0.4.1
[0.2.0]: https://github.com/valthon/zigbase/releases/tag/v0.2.0
[0.1.0]: https://github.com/valthon/zigbase/releases/tag/v0.1.0
