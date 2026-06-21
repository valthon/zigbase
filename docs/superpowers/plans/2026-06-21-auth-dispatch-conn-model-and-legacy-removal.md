# Auth dispatch connection-model refactor + legacy OAuth removal — Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** (1) Refactor the auth-method dispatch so methods manage their own DB connections (no writer held across a method's potentially-slow work — OAuth releases the writer during provider HTTP; password uses a reader so argon2 doesn't block writes). (2) Remove the legacy OAuth endpoints (`/oauth2-init`, `/auth-with-oauth2`) now that the contract method supersedes them, folding provider discovery into the contract surface. Keep `unlinkProvider`.

**Architecture:** `AuthCtx` drops its `conn` field and gains `writer()`/`reader()` RAII accessors (delegating to `app.pool`, same handles `RouteEvent` uses); its DB helper methods take an explicit `conn`. The dispatch no longer pre-acquires a writer: it loads the collection under a brief reader, runs the method (which acquires its own connection), and on `Resolution.record` acquires a writer just to mint the session. Each method holds ONE connection across its `complete` for atomicity (password→reader; magic_link/otp/webauthn→writer), except OAuth2 whose `complete` releases the writer around the HTTP exchange.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0`), vendored SQLite (WAL, single writer), zap; TypeScript client under `clients/typescript`; Python/Playwright browser suite.

## Global Constraints

- Build/test ONLY `/home/valthon/.local/bin/mise exec zig@0.16.0 -- zig build test --summary all`; signal `Build Summary: N/N tests passed` (`failed command:` line is spurious). Baseline: **679/679**.
- **The single pool writer is NON-REENTRANT.** A thread that holds the writer and acquires it again deadlocks. Tests must NEVER hold the writer (`env.pool.acquireWriter()`) across a call to a method/dispatch that acquires the writer — scope-release first. (This already bit us once.) ALWAYS run tests TIMEOUT-GUARDED: `timeout 300 … zig build test …`; a hang = exit 124, investigate the deadlock.
- **Per-method atomicity:** within a single `complete`/`initiate`, a method holds ONE connection (acquire at top, `defer deinit`) so its DB ops are on one connection — EXCEPT OAuth2.complete, which intentionally releases between the state-consume and the resolve (around HTTP), exactly as the legacy path did. Do not split a method's writes across acquisitions except where explicitly noted (OAuth2).
- New `src/*.zig` files' tests must be added to `src/root.zig`'s test block.
- Removing legacy endpoints is a BREAKING API change: the shipped TypeScript client + `test_oauth.py` MUST be migrated in the same PR.
- Docs sync `docs/*.md` ↔ `site/src/content/docs/`; `cd site && npm run build` passes.

**Reference:** `src/api/auth_methods.zig` (dispatch), `src/auth/method.zig` (AuthCtx), `src/auth/methods/*.zig` (the 5 methods), `src/events.zig` (`WriterData`/`ReaderData` RAII + how `RouteEvent.writer()`/`reader()` build them), `src/api/oauth.zig` (legacy handlers + the shared `prepareOAuth`/`resolveRecordFromIdentity`/`consumeState`/`issueState`/`oauth2Providers` logic), `src/server.zig` (routes), `clients/typescript/src/collection.ts`, `tests/admin/test_oauth.py`.

---

## Task 1: Connection-model flip (atomic — AuthCtx + dispatch + all 5 methods + tests)

This is ONE coherent change; it will not compile until all parts land. Work part-by-part, building (timeout-guarded) at the end.

**Files:**
- Modify: `src/auth/method.zig` (AuthCtx: drop `conn`; add `writer()`/`reader()`; helpers take `conn`)
- Modify: `src/api/auth_methods.zig` (dispatch: no pre-held writer)
- Modify: `src/auth/methods/{password,magic_link,otp,webauthn,oauth2}.zig` (acquire own conn)
- Modify: tests in all of the above + any other AuthCtx constructor

**Interfaces — `AuthCtx` becomes:**
```zig
pub const AuthCtx = struct {
    app: *App,
    ctx: *http.RequestCtx,
    collection: schema.Collection,
    config: std.json.Value,
    // RAII connection accessors (mirror RouteEvent.writer()/reader() — read events.zig):
    pub fn writer(ac: *AuthCtx) events.WriterData { ... }       // acquire pool writer
    pub fn reader(ac: *AuthCtx) events.DbError!events.ReaderData { ... }  // acquire pooled reader
    // DB helpers now take an explicit conn (were: used ac.conn):
    pub fn findByIdentity(ac: *AuthCtx, conn: *db.Db, identity: []const u8) !?[]const u8;
    pub fn mintLinkToken(ac: *AuthCtx, conn: *db.Db, record_id: []const u8, ttl_s: i64) ![]const u8;
    pub fn verifyLinkToken(ac: *AuthCtx, conn: *db.Db, token: []const u8) !?jwt.Claims;
    pub fn consumeLinkToken(ac: *AuthCtx, conn: *db.Db, claims: jwt.Claims) !void;
    pub fn deliverMail(ac: *AuthCtx, to: []const u8, subject: []const u8, body: []const u8) !void; // no conn
    pub fn rateLimit(ac: *AuthCtx, scope: []const u8, ident: []const u8) !?http.Response; // no conn
};
```
> Read `src/events.zig` for the exact `WriterData`/`ReaderData` types and the constructor `RouteEvent.writer()`/`reader()` use (around events.zig:39-95, 138-145). `WriterData.conn` is a `*db.Db`; `WriterData.deinit()` releases the writer; `ReaderData.deinit()` returns the reader. Build `AuthCtx.writer()` the same way (`return .{ .app = ac.app, .pool = ac.app.pool, .conn = <acquired> }` — match the real shape).

**Dispatch (`auth_methods.zig`) becomes:**
```zig
fn dispatch(ctx, phase) !http.Response {
    const app = ...;
    // load collection under a BRIEF reader (was: held writer)
    const col = blk: {
        var r = app.pool.acquireReader() catch return internal;
        defer app.pool.releaseReader(&r);
        break :blk (try collections.get(ctx.allocator, &r, col_name)) orelse return notFound;
    };
    if (col.type != .auth) return notFound;
    // slug enablement + registry resolve + rate-limit — unchanged (no DB conn needed; methodEnabled/rateLimitOptFor read col in memory)
    var ac = AuthCtx{ .app = app, .ctx = ctx, .collection = col, .config = .null };  // NO .conn
    switch (phase) {
        .initiate => { const result = try am.vtable.initiate(am.ctx, &ac); return Response{...result}; },
        .complete => {
            const resolution = try am.vtable.complete(am.ctx, &ac);  // method manages its own conn
            switch (resolution) {
                .fail => |f| return ApiError{f}.toResponse,
                .record => |rid| {
                    // mint the session under a writer acquired HERE (method already released its conn)
                    var w = app.pool.acquireWriter(); ... wait: acquireWriter returns void+holds; use the pattern:
                    const w = app.pool.acquireWriter(); defer app.pool.releaseWriter();
                    const issued = try auth.issueSession(ctx, w, col.name, rid, auth_tag);
                    return Response{ token + cookies };
                },
            }
        },
    }
}
```
> NOTE the existing code uses `app.pool.acquireWriter()` returning the `*db.Db` directly with `defer app.pool.releaseWriter()` (no handle) — match the existing dispatch's exact acquire/release API (it currently does `const w = app.pool.acquireWriter(); defer app.pool.releaseWriter();`). For the AuthCtx RAII helpers, prefer the `WriterData`/`ReaderData` handle style so methods get `var w = ac.writer(); defer w.deinit();`.

**Each method converts** (acquire own conn; one conn per call for atomicity, except oauth2):
- `password.completeImpl`: `var r = try ac.reader(); defer r.deinit();` → use `r.conn` for `findByIdentity`/`passwordHashFor`/`verifyPassword` (READ-ONLY — reader, so argon2 doesn't block writes). `initiate` stays a no-op (no conn).
- `magic_link`: `complete` → `var w = ac.writer(); defer w.deinit();` use `w.conn` for verify+consume. `initiate` → reader for `findByIdentity` (mintLinkToken is a JWT, deliverMail is the mailer — no writer needed; use a reader).
- `otp`: `complete` → writer (takeByIdentity). `initiate` → writer (store code in ChallengeStore) — read the file for which conn each currently needs.
- `webauthn`: `complete` → writer held for the WHOLE call (read cred + verify + updateSignCount + take challenge — keep atomic under ONE writer). `initiate` → writer (store challenge).
- `oauth2.completeImpl(ac, transport)`: `prepareOAuth(ac.ctx, ac.collection)` (no conn); state-consume in a SCOPED writer block `{ var w = ac.writer(); defer w.deinit(); consumeState(w.conn, ...) }`; HTTP (exchangeCode/fetchIdentity — NO conn held); resolve in a SECOND SCOPED writer block `{ var w = ac.writer(); defer w.deinit(); resolveRecordFromIdentity(w.conn, ...) }` → `.record`. `oauth2.initiate` → scoped writer for `issueState` (when server-state on); the rest (provider config) is in `ac.collection`.

**Tests** in each method file + auth_methods.zig: they currently build `AuthCtx{ .conn = w, ... }` while HOLDING `w` (a writer the test acquired). Convert each to:
- Build `AuthCtx{ .app = &env.app, .ctx = ..., .collection = col, .config = .null }` (no `.conn`).
- Do all setup that needs a writer (createUser, mint token/state, pre-insert credential, store challenge) inside a SCOPED `{ const w = env.pool.acquireWriter(); defer env.pool.releaseWriter(); ... }` block that RELEASES before the method/dispatch call.
- Call the method/dispatch with NO writer held (the method acquires its own).
- Post-verify in another scoped writer/reader block.
- The dispatch tests (auth_methods.zig) already build a registry + call `complete(&ctx)`; those didn't pass `.conn` (the dispatch acquired it) — they should still work, but verify they don't hold a writer across the call.

- [ ] **Step 1:** Read `events.zig` (WriterData/ReaderData + RouteEvent.writer/reader), `auth/method.zig` (current AuthCtx + helpers + test), and all 5 method files + `auth_methods.zig` (current `ac.conn` uses + their tests). Map every `ac.conn` use and every test that holds a writer across a method call.
- [ ] **Step 2:** Implement the `AuthCtx` change (drop `conn`, add `writer()`/`reader()`, helpers take `conn`) + its own test.
- [ ] **Step 3:** Implement the dispatch change (no pre-held writer; reader for load; writer only to mint after `.record`).
- [ ] **Step 4:** Convert the 5 methods (per the per-method notes above), one at a time.
- [ ] **Step 5:** Fix ALL the tests (method tests + dispatch tests) to not hold the writer across the call (scoped setup/verify blocks).
- [ ] **Step 6: Build TIMEOUT-GUARDED** — `timeout 300 mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -15`. Expected `Build Summary: N/N tests passed` (≈679, possibly ±a few if test structure changed). If it TIMES OUT (124) → a test holds the writer across a method call; find + fix.
- [ ] **Step 7: Run the auth/oauth browser subset** — `timeout 300 mise exec python@3.13 -- python -m pytest tests/admin -k "oauth or auth or login" -q 2>&1 | tail -8` → pass.
- [ ] **Step 8: Commit** — `refactor(auth): methods manage their own DB connections (no writer held across method work; password→reader, oauth releases during HTTP)`

---

## Task 2: Remove legacy OAuth endpoints + fold provider discovery into the contract

**Files:** `src/server.zig`, `src/api/oauth.zig`, `src/api/auth_methods.zig` (or a small oauth-discovery route), `docs`/clients handled in later tasks.

- [ ] **Step 1:** In `src/server.zig`, REMOVE the routes for `/oauth2-init` and `/auth-with-oauth2`. ADD a discovery route `GET /api/collections/:col/auth/oauth2/providers` → a handler that runs the existing `oauth2Providers` logic. KEEP the `unlinkProvider` route (`DELETE .../records/:id/external-auths/:provider`). REMOVE the `/oauth2-providers` route (replaced by the new path).
- [ ] **Step 2:** In `src/api/oauth.zig`, DELETE `oauth2Init`, `authWithOAuth2`, `authWithOAuth2Impl`, `respondSession`, and `issueState`'s legacy-only caller if now unused (KEEP `issueState`/`consumeState`/`prepareOAuth`/`resolveRecordFromIdentity` — used by the method; KEEP `oauth2Providers` logic, now reached via the new discovery route handler — rename/move it to fit `/auth/oauth2/providers` if cleaner). KEEP `unlinkProvider`, `findLink`/`insertLink`/`createOAuthRecord`/`resolveProvider`/`findProviderConfig`. Delete the now-dead legacy tests (the `authWithOAuth2Impl`/F11-on-legacy tests) — their coverage moved to the `OAuth2Method` tests (the CSRF tests added earlier cover state on the contract path).
- [ ] **Step 3:** Make the discovery route reachable: the new `GET /auth/oauth2/providers` handler returns `{ providers: [{name, authURL, clientId, scopes}] }` (the old `oauth2Providers` body) for the collection's enabled+resolved providers. Gate on `col.options.auth.oauth2.enabled` (404 otherwise) — same as before.
- [ ] **Step 4: Build + tests TIMEOUT-GUARDED** — `timeout 300 … zig build test …` green (count drops by the deleted legacy tests; that's expected — note the delta). Confirm no dangling references to the removed handlers (`git grep oauth2Init|authWithOAuth2|respondSession src/` → only comments/none).
- [ ] **Step 5: Commit** — `feat(auth)!: remove legacy oauth2-init/auth-with-oauth2 endpoints; provider discovery at /auth/oauth2/providers`

---

## Task 3: Migrate the TypeScript client + its tests

**Files:** `clients/typescript/src/collection.ts`, `clients/typescript/test/auth.test.ts` (+ any other refs).

- [ ] **Step 1:** In `collection.ts`: repoint `authWithOAuth2(...)` to `POST .../auth/oauth2/complete` (body `{provider, code, codeVerifier, redirectUrl, state?}`, response `{token}` + cookies — note the response no longer has `record`/`meta`; adjust the return type/usage accordingly or fetch the record separately if the client needs it). Repoint `oauth2Providers()` to `GET .../auth/oauth2/providers`. Repoint `oauth2Init(...)` to `POST .../auth/oauth2/initiate` (body `{provider}`, returns `{authURL, clientId, scopes, state?}`). Update the `skipAuth` path list (line ~50) for the new complete path.
- [ ] **Step 2:** Update `test/auth.test.ts` (and any snapshot/expectation) to the new URLs + shapes.
- [ ] **Step 3:** Build/test the TS client per its own toolchain (read `clients/typescript/package.json` — likely `npm run build` + `npm test` via node@24): `cd clients/typescript && /home/valthon/.local/bin/mise exec node@24 -- npm ci && npm test` (or the repo's CI invocation — check `.github/workflows/ci.yml` `ts-sdk` job for the exact commands). Green.
- [ ] **Step 4: Commit** — `feat(client)!: TypeScript client uses the contract oauth endpoints (/auth/oauth2/*)`

---

## Task 4: Migrate the browser test

**Files:** `tests/admin/test_oauth.py`.

- [ ] **Step 1:** Read `tests/admin/test_oauth.py` — it drives the legacy oauth endpoints. Repoint it to the contract endpoints (`/auth/oauth2/initiate`, `/auth/oauth2/complete`, `/auth/oauth2/providers`) with the new request/response shapes. Preserve the test's INTENT (provider listing, the auth flow, state/CSRF if covered).
- [ ] **Step 2: Run it** — `timeout 300 mise exec python@3.13 -- python -m pytest tests/admin/test_oauth.py -q 2>&1 | tail -10` → pass. (The harness builds the binary + launches a server.)
- [ ] **Step 3: Commit** — `test(oauth): browser test drives the contract /auth/oauth2/* endpoints`

---

## Task 5: Docs

**Files:** `docs/framework.md`, `docs/api.md` (+ site mirrors), `CHANGELOG.md` (+ site mirror).

- [ ] **Step 1:** `docs/api.md` + `docs/framework.md`: REMOVE the legacy `/oauth2-init`, `/auth-with-oauth2`, `/oauth2-providers` endpoint docs. Document the contract surface: `/auth/oauth2/initiate`, `/auth/oauth2/complete`, `GET /auth/oauth2/providers` (discovery). UPDATE the writer-during-HTTP note → the OAuth `complete` now RELEASES the writer during the provider HTTP (no write-throughput stall); explain methods manage their own connections. Mention the breaking change.
- [ ] **Step 2:** Mirror into `site/src/content/docs/`.
- [ ] **Step 3:** `CHANGELOG.md` `[Unreleased]` (both copies) — under a `### Removed` / `### Changed`: "BREAKING: removed legacy `oauth2-init` / `auth-with-oauth2` / `oauth2-providers` endpoints; OAuth2 is now exclusively the contract method (`/auth/oauth2/{initiate,complete}` + `/auth/oauth2/providers`). Auth methods now manage their own DB connections; OAuth no longer holds the write lock during the provider HTTP exchange." Update the earlier `[Unreleased]` OAuth bullets that described legacy coexistence.
- [ ] **Step 4:** `cd site && npm run build` passes.
- [ ] **Step 5: Commit** — `docs(auth)!: legacy oauth endpoints removed; contract-only oauth + connection-model note`

---

## Security re-review (after Task 2)

Dispatch an OAuth/concurrency-aware reviewer: confirm the connection-model flip introduced NO atomicity/security regression — specifically (1) OAuth `complete` still consumes the CSRF `state` (single-use) BEFORE the code exchange even though state-consume and resolve are now SEPARATE writer acquisitions (a window between them is acceptable iff state is already consumed — confirm an attacker can't reuse a state in the gap); (2) WebAuthn `complete` keeps its read-cred → verify → updateSignCount → consume-challenge sequence atomic under ONE writer acquisition (clone-detection must not race); (3) password now uses a READER — confirm it only reads (no write) so a reader is correct; (4) the dispatch minting the session in a separate writer acquisition after the method returns `.record` is fine (session mint is independent); (5) no method holds the writer across blocking I/O anymore; (6) removed endpoints leave no reachable dead auth path. Plus the standard OAuth checks (PKCE, redirect allow-list, linking guards) still hold via the shared helpers.

## Self-Review

**Spec coverage:** Option A (connection model) → Task 1. Legacy removal + discovery → Task 2. Client/test/docs migration → Tasks 3-5. Security → review. **Atomicity** is the key risk, addressed by "one connection per method call except OAuth2" + the security review's checks 1-2.

**Soft spots:** the exact `WriterData`/`ReaderData` constructor + `acquireReader` error type (Task 1 — read events.zig); the precise set of legacy tests to delete vs keep (Task 2 — keep anything testing shared helpers/the method; delete only `authWithOAuth2Impl`/legacy-endpoint tests); the TS client's exact build/test commands (Task 3 — read the ci.yml `ts-sdk` job); whether `test_oauth.py` needs server-side-state env (Task 4).
