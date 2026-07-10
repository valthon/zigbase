# Kotlin Client SDK KSP1 (Base Client) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `clients/kotlin/` — Maven artifact `io.github.valthon:zigbase-client` 0.1.0, the base tier of the fourth ZigBase SDK: a coroutines-first Kotlin/JVM port of `@zigbase/client` (auth incl. OAuth2/PKCE + sessions, records CRUD, offset+cursor pagination, injection-safe filters, multipart files, ancillary services) with unit + live-integration tests, a CI job, a deferred Maven release lane, and synced docs. Realtime is KSP2; typed codegen KSP3.

**Architecture:** Single suspend surface (no sync/async fork — coroutines are Kotlin's one idiom). A pure request-spec core consumed by one `Transport` over an injectable ktor `HttpClient` (MockEngine in tests) owning the 401 single-flight refresh (Mutex) and 429 backoff state machines. Services mirror the sibling SDKs; records are `JsonObject`/`Map`-like (`ZbRecord` value wrapper like Dart's).

**Tech Stack:** Kotlin 2.x (Gradle plugin), JDK 17 single toolchain (`jvmToolchain(17)`, mise-pinned launcher/daemon JVM too — no second-JDK auto-download), Gradle 9.6 via mise, ktor-client 3.x (CIO default engine, content-negotiation + kotlinx-json), kotlinx.serialization, kotlinx-coroutines, JUnit 5 + kotlinx-coroutines-test, Spotless+ktlint (version-pinned) as the format gate.

**Normative reference:** The TypeScript SDK (`clients/typescript/src/`) is authoritative on wire behavior; Dart (`clients/dart/lib/src/`) and Python (`clients/python/src/zigbase/`) are worked ports — Python is the NEWEST and carries every accumulated hardening; when this plan says "port X", read the TS file for wire truth and the Python module for the hardened shape. The design spec is `docs/superpowers/specs/2026-07-10-kotlin-sdk-design.md`.

## Global Constraints

- Path `clients/kotlin/`, package root `dev.zigbase.client`? NO — package namespace matches coordinates: **`io.github.valthon.zigbase`**. Artifact `io.github.valthon:zigbase-client:0.1.0`.
- Toolchain: root `mise.toml` gains `java = "openjdk-17"` and `gradle = "9.6"` (additive; Task 1). All Gradle commands: `mise exec gradle@9.6 -- gradle -p clients/kotlin <task>` from the worktree root (or `working-directory` in CI). Commit the standard Gradle wrapper with `distributionUrl` matching 9.6 (regenerable artifact, not a vendored dep).
- Version catalog `clients/kotlin/gradle/libs.versions.toml`; library versions from the toolchain report are knowledge-cutoff-bound — the scaffold task verifies real latest-stable at implementation time and pins exactly.
- **Gates at every commit** (from worktree root): `mise exec gradle@9.6 -- gradle -p clients/kotlin spotlessCheck build` (build = compile + unit tests; integration tests are a separate `integrationTest` source set/task, excluded from `build`).
- Wire rules (identical to the sibling SDKs): paths `<base>/api/...`; `Authorization: Bearer` only (no cookies/CSRF); PATCH updates; 204 → Unit; error envelope `{code,message,data}` → `ZigbaseException(status, message, data, url)` with malformed-`data` entries SKIPPED; cursor tokens opaque; 404-hides-existence semantics respected in docs/tests.
- **Hardenings are day-one requirements, not retrofits** (they were review findings in prior SDKs): non-object 2xx body → clear `ZigbaseException(status=0, "Expected a JSON object response (<context>)")`; mandatory `token` fields → `requireStringField` (never default to ""); 429 retried for ALL methods (Retry-After verbatim else `min(30s, 200ms * 2^attempt)`, injectable delay); 401 single-flight refresh (Mutex; per-exchange retry-once; refresh-401 propagates; empty/null refresh body → original 401 + store preserved, parsed-but-malformed → clears store — the JS-semantics split); GET sends no body; transport Authorization/Accept-Language overwrite per-request headers while X-Account-Id fills-if-absent; FileAuthStore writes 0600 with per-call-unique temp + atomic move, unreadable/corrupt = start empty (incl. non-UTF8); logout/revokeAllSessions clear the store even on failure; changePassword re-auths when self (email→username fallback); `verify()` returns Boolean from `{verified}`; getFirstListItem synthesized 404 uses TS's exact message; iterate/getFullList raise status-0 on non-advancing cursors.
- **Filter safety:** `filterValue` is the single escaping chokepoint (escape set `\`, `'`, newline, tab, CR; numbers via the ECMA-262 shortest-round-trip notation algorithm — port Python's `_format_number` two-stage approach, this is the hardest byte-parity piece and gets its own fixture tests incl. `1e20/1e21/1e-6/1e-7/0.1+0.2`; ms-clamped UTC ISO dates; bools bare; null; REJECT lists/maps/non-finite with `IllegalArgumentException`). `zbFilter("... {:key}", mapOf(...))` named placeholders (unknown → error, unused → error).
- Documented divergences (match Python's, for cross-new-SDK consistency): no requestKey dedup (use ktor timeouts/cancellation), realtime KSP2, typed KSP3. Kotlin-specific: suspend-only API (document that Android callers use lifecycle scopes; blocking bridge = `runBlocking`, consumer-side).
- Every source file's KDoc names its TS counterpart (`Port of clients/typescript/src/transport.ts`), like Dart/Python.
- mise.toml is the ONLY file outside `clients/kotlin/` + `.github/workflows/` + docs/changelog paths this program may touch in KSP1 (plus root `.gitignore` JVM patterns).
- Commits `feat(kotlin-sdk): ...` style ending with the Claude co-author trailer. TDD (RED before GREEN) on every task; JUnit5 tests fully annotated; no wall-clock sleeps (injectable delay + `runTest` virtual time).
- Changelog: `clients/kotlin/CHANGELOG.md` with `[Unreleased]` (client convention); repo fragment in Task 13.

---

### Task 1: Toolchain pins + Gradle scaffold

**Files:**
- Modify: `mise.toml` (add java/gradle), `.gitignore` (JVM patterns scoped to clients/kotlin + `.idea/`, `*.iml`)
- Create: `clients/kotlin/settings.gradle.kts`, `build.gradle.kts`, `gradle/libs.versions.toml`, `gradle/wrapper/*` (standard wrapper, dist matching mise pin), `gradle.properties`, `LICENSE` (byte-copy of `clients/typescript/LICENSE` — `cmp` must be clean; a prior SDK's scaffold FAILED review for regenerating it), `README.md` stub, `src/main/kotlin/io/github/valthon/zigbase/Version.kt` (`const val ZIGBASE_CLIENT_VERSION = "0.1.0"`), `src/test/kotlin/.../SmokeTest.kt`

Steps: verify live latest-stable versions (`mise ls-remote gradle | tail`, plugin portal metadata via gradle itself on first resolve) and pin the catalog; `mise install`; configure kotlin-jvm + serialization plugins, `jvmToolchain(17)`, Spotless+ktlint pinned, JUnit5 + `integrationTest` source set + task (excluded from `build`, tagged/`@Tag("integration")` or source-set split — pick source-set split, it's cleaner for CI); smoke test asserts the version constant.
- [ ] Write scaffold → [ ] `mise exec gradle@9.6 -- gradle -p clients/kotlin spotlessCheck build` PASS (1 test) → [ ] `cmp clients/typescript/LICENSE clients/kotlin/LICENSE` clean → [ ] Commit `feat(kotlin-sdk): scaffold zigbase-client Gradle project`

### Task 2: Errors + JWT
**Create:** `errors/Errors.kt` (`FieldError`, `ZigbaseException(status, message, data: Map<String,FieldError>, url)`, `parseErrorResponse` with malformed-entry skipping + reason-phrase→generic fallbacks), `jwt/Jwt.kt` (`decodeJwtPayload` null on ANY malformed input incl. base64/UTF-8/non-object; `isTokenExpired(leewaySeconds)` true on missing exp; bool-vs-number exp edge tested). Port of errors.ts/jwt.ts via Python's errors.py/_jwt.py shapes. TDD per the SP1 case list.
- [ ] RED → [ ] implement → [ ] gates → [ ] Commit `feat(kotlin-sdk): error model and jwt utilities`

### Task 3: Query helpers (byte-parity critical)
**Create:** `query/Query.kt` — `filterValue`, `zbFilter`, `formatDate` (ms-clamped UTC `Z`; `Instant`/`OffsetDateTime` in, naive-equivalent = require `Instant`), `vectorSpec(field, embedding, metric: String? = null)` (metric cosine|l2, JS-JSON bare integral floats), `buildListParams` (wire names `perPage`/`skipTotal`; omit absent — never empty cursor/limit), and the ECMA-262 number formatter (`formatJsNumber`) with the full boundary fixture set. Injection tests: closing quote never unescaped; O'Brien fixture; reject list/map/NaN/±Inf.
- [ ] RED → [ ] implement → [ ] gates → [ ] Commit `feat(kotlin-sdk): injection-safe filter builder and query helpers`

### Task 4: Auth stores
**Create:** `auth/AuthStore.kt` — `AuthStore` interface (`token`, `record: JsonObject?`, `isValid`, `save`, `clear`, `onChange(cb: (String?, JsonObject?) -> Unit): () -> Unit`), `MemoryAuthStore`, `FileAuthStore(path)` (eager load; missing/corrupt/non-UTF8/unreadable = empty; saves `{"token","record"}` via unique-suffix temp file created with POSIX 0600 + `Files.move(..., ATOMIC_MOVE)`; parent dirs created; listener exceptions isolated; concurrent-writer stress test like Python's). KDoc notes thread-safety expectations (synchronize state mutation — services may touch it from multiple coroutines).
- [ ] RED → [ ] implement → [ ] gates → [ ] Commit `feat(kotlin-sdk): auth stores with change notification`

### Task 5: Body encoding
**Create:** `internal/Body.kt` — `hasFile` (top-level values/lists; file = `FileArg` sealed type: `Bytes(filename, content, contentType?)` | `Source(...)`? keep minimal: Bytes + java.io.File), `encodeBody` → JSON object (loud reject of non-encodable/non-finite naming the key) or multipart parts (null→"", datetime→formatDate, nested→JSON string, element-wise lists, bools lowercase; bytes buffered once for retry). Maps to ktor `MultiPartFormDataContent`.
- [ ] RED → [ ] implement → [ ] gates → [ ] Commit `feat(kotlin-sdk): body encoding with multipart auto-detection`

### Task 6: Transport (the linchpin)
**Create:** `internal/RequestSpec.kt` (pure; `encodePathSegment`), `internal/Transport.kt` — ctor `(baseUrl, authStore, authCollection?, autoRefresh, accountId?, lang?, maxRetries, httpClient: HttpClient?)` (self-created CIO client owned/closed; injected not); `suspend fun request(spec): JsonElement?`; `rawRequest`. The 7-rule contract from Python SP1 Task 6 verbatim (header assembly/priorities; 204/empty→null; non-2xx→parseErrorResponse; 429 all methods w/ injectable `delayFn`; 401 single-flight via `Mutex` + shared `Deferred` flight, retry-once per exchange, refresh-401 propagates, empty-body-refresh preserves store vs malformed-clears (JS split); multipart never hand-sets Content-Type; ktor/IO exceptions propagate unwrapped) + `ensureObjectBody`/`requireStringField` helpers here from day one. Concurrency test: two coroutines 401 → exactly one refresh (deterministic via a gated MockEngine, `runTest`).
- [ ] RED (rule-per-test) → [ ] implement → [ ] gates + 5x flake loop on the transport test class → [ ] Commit `feat(kotlin-sdk): transport with refresh and backoff state machines`

### Task 7: Collection service — CRUD + pagination
**Create:** `CollectionService.kt` + result types `ListResult`/`CursorPage` (wire parse via kotlinx JsonObject; totals default 0 offset / null cursor). Methods (suspend): `getList(page=1, perPage=30, opts...)`, `getOne`, `getFirstListItem` (skipTotal, synthesized TS-message 404), `create`/`update`(PATCH)/`delete`, `getAbilities`, `getPage(cursor?, limit?, withTotal=false)`, `iterate(batch=100): Flow<ZbRecord>`, `getFullList`. Non-advancing-cursor guard (both modes tested). Opts as default-args, unknown-opt impossible (typed). `ZbRecord` = thin `JsonObject` wrapper with typed accessors (Dart's shape).
- [ ] RED → [ ] implement → [ ] gates → [ ] Commit `feat(kotlin-sdk): collection CRUD and cursor pagination`

### Task 8: Auth methods + PKCE
**Modify:** `CollectionService.kt`; **Create:** `auth/Pkce.kt` (`generateCodeVerifier` SecureRandom unreserved charset; `codeChallengeS256` unpadded base64url; RFC 7636 vector test). Full auth surface per the SP1 list (authWithPassword/authRefresh(isRefresh)/listAuthProviders/oauth2Init/authWithOAuth2(token-only save)/logout(try-finally clear)/verification+reset x4/changePassword(self-reauth)/sessions x3 snake_case passthrough). Store side effects tested on EVERY path incl. failure clears.
- [ ] RED → [ ] implement → [ ] gates → [ ] Commit `feat(kotlin-sdk): collection auth, sessions, and pkce`

### Task 9: Files + ancillary services
**Create:** `FilesService.kt` (`getUrl(record, filename, download/thumb/token)` + `getUrlFor`; missing collection keys → IllegalArgumentException; `getToken()` requireStringField), `AccountsService.kt` (activate), `AnalyticsService.kt` (events→CursorPage reusing the parser, rollup→items; `from`→wire "from"), `SendersService.kt` (list/create/verify→Boolean). Param order/names byte-match TS.
- [ ] RED → [ ] implement → [ ] gates → [ ] Commit `feat(kotlin-sdk): files, accounts, analytics, senders services`

### Task 10: Client facade
**Create:** `ZigbaseClient.kt` — ctor `(baseUrl, authStore=Memory, autoRefresh=false, authCollection?, accountId?, lang?, maxRetries=3, httpClient?)`; trailing-slash strip; `collection(name)`, `files/accounts/analytics/senders`, `send`/`rawRequest`, `health()`, `withAccount(id)` sibling (shares authStore + underlying ktor client via explicit `httpClient` pass — ownership falls out, sibling never owns), `close()` (AutoCloseable; only self-created client), exports/public-API surface finalized. Ownership matrix tests (double-close idempotent; injected survives; sibling isolation; post-close ktor error propagates).
- [ ] RED → [ ] implement → [ ] gates → [ ] Commit `feat(kotlin-sdk): ZigbaseClient facade`

### Task 11: Live integration suite
**Create:** `src/integrationTest/kotlin/...` — harness launching `ZIGBASE_TEST_BINARY` (free port, temp dir, `--insecure-cookies`, health poll, superuser bootstrap via CLI; port the Python conftest mechanics; clean SKIP when env unset via JUnit `assumeTrue` in a base class). Coverage = Python SP1 Task 12's list (password auth; CRUD w/ zbFilter incl. apostrophe; cursor iterate >2 pages w/ order+completeness asserts; PATCH; delete→404; abilities; anon-locked 403; multipart upload + fetch-back byte compare; authRefresh proof against a genuinely auth-gated read WITH anonymous negative control; logout clears) — **discriminating assertions with negative controls from day one** (two prior SDKs got review findings for this; don't repeat). Run twice for flakes.
- [ ] harness+smoke → [ ] coverage (fix SDK bugs found as own commits) → [ ] 2x green + unit suite green → [ ] Commit `test(kotlin-sdk): live-server integration suite`

### Task 12: CI + release lane + packaging polish
**Modify:** `.github/workflows/ci.yml` (add `kotlin-sdk` job: needs build, mise-action (reads new pins), zigbase-binaries artifact + env exports (copy dart/python blocks verbatim incl. dating binary for KSP3-readiness), Gradle cache per the toolchain report, spotlessCheck → unit (`build -x integrationTest`... verify source-set task names) → integrationTest).
**Create:** `.github/workflows/release-kotlin-sdk.yml` (tags `kotlin-client-v*`; verify job: gates + version==tag assert + `publishToMavenLocal` sanity; publish job: vanniktech maven-publish → Central Portal, token+GPG from secrets — NO id-token (no OIDC on Maven Central); do NOT tag), `clients/kotlin/CHANGELOG.md` ([Unreleased] KSP1 set), `RELEASING.md` (one-time setup: namespace verification, user token, GPG key, four secrets; "first publish pending — do not push kotlin-client-v* until secrets exist" banner), full `README.md` (arc from clients/python/README.md, coroutines-first noted).
- [ ] write → [ ] YAML sanity + local end-to-end of the CI job's command sequence → [ ] gates → [ ] Commit `ci(kotlin-sdk): CI job and deferred Maven release lane`

### Task 13: Docs + changelog fragment + site sync
**Create:** `docs/kotlin-sdk.md` (model on docs/python-sdk.md's structure; suspend/Flow idioms; snippet-audit against real code), register in `site/scripts/docs-registry.json` + `gen-docs-mirror.mjs` PUBLISHED + `site/.gitignore` (the GENERATED-mirror regime — never hand-copy), sidebar entry, `changelog.d/kotlin-sdk-base.md`:
```markdown
### Features

- Kotlin client SDK (`clients/kotlin`, Maven `io.github.valthon:zigbase-client` 0.1.0): coroutines-first `ZigbaseClient` covering auth (password, refresh, OAuth2/PKCE, sessions), records CRUD with offset + cursor pagination and an injection-safe filter builder, multipart file uploads, file URLs/tokens, and accounts/analytics/senders services. Realtime and typed codegen tiers follow.
```
**Modify:** root `README.md` SDK list; grep for real cross-SDK lists (typescript-sdk.md's --lang table is KSP3's concern, not this task's — codegen doesn't exist yet).
- [ ] write + site build green + snippet audit → [ ] grep check → [ ] unit suite once more → [ ] Commit `docs(kotlin-sdk): consumer guide, site registration, changelog fragment`

---

## Self-review notes (applied)
- Spec coverage: platform/stack/coordinates (T1), full base-tier surface (T2-T10), hardenings-as-requirements distributed into their owning tasks (T4 store, T6 transport, T7 cursor, T8 auth flows, T9 verify-Boolean, T11 discriminating e2e), CI/release-deferred (T12), docs w/ generated-mirror regime (T13). Realtime/typed explicitly out (KSP2/KSP3).
- Type consistency: `ZbRecord` (T7) consumed by T9 files/getUrl + T11; `FileArg` (T5) by T7 create/update + T11 upload; `requireStringField`/`ensureObjectBody` (T6) by T8/T9; store interface (T4) by T6/T10.
- Knowledge-cutoff versions are pinned AT scaffold time from live sources (T1 step), not from this plan.
