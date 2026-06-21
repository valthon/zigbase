# Milestone 3 — magic_link + otp built-ins, ChallengeStore, rpc generation

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Ship the `magic_link` and `otp` built-in auth methods on the M2 contract, add the TTL'd single-use `ChallengeStore` (a `_authChallenges` table) that OTP (and WebAuthn in M4) need, and extend the typed client generator so auth-method endpoints appear in the TS rpc client.

**Architecture:** `magic_link` reuses the M1 single-use link-token machinery via `AuthCtx` (initiate: mint+mail a token, enumeration-safe 204; complete: verify+consume → record). `otp` generates a short numeric code stored in `ChallengeStore` keyed by (collection, method, identity) with TTL + single-use; complete looks it up, checks the code, consumes it. The generator emits `zb.auth.<method>.initiate/complete(...)` for each collection × enabled built-in method.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0`), SQLite, the existing TS codegen under `src/codegen/`.

## Global Constraints

- Build/test ONLY via `/home/valthon/.local/bin/mise exec zig@0.16.0 -- zig build test --summary all`; signal `Build Summary: N/N tests passed`. Baseline at M3 start: **563/563**.
- New `src/*.zig` files → add to `src/root.zig` test block.
- Disk is tight on this host; KEEP temp-file usage minimal in every task.
- `ChallengeStore` single-use + TTL must be **atomic** (mirror `_consumedTokens`: a UNIQUE/PK constraint makes a second redemption fail under the writer lock). GC via `DELETE WHERE expires <= now`, mirroring `records.gcCursorStates`.
- Enumeration-safety: `initiate` for magic_link/otp returns a uniform success (204/200) whether or not the identity exists.
- Docs are deferred to the consolidated post-M4 docs pass (do NOT write docs in M3).

**Reference:** integration map `.superpowers/sdd/m2-m3-integration-map.md` §4 (codegen), §6 (`_consumedTokens`/`_cursorStates` precedent). M2 contract: `src/auth/method.zig`, `src/auth/methods/password.zig` (the pattern to copy). Config opts: `schema.MagicLinkMethodOpts{ ttl_s, auto_create, rate_limit }`, `schema.OtpMethodOpts{ length, ttl_s, auto_create, rate_limit }`.

---

## Task 1: `ChallengeStore` (`_authChallenges` table) — create, redeem-once, GC

**Files:**
- Modify: `src/migrations.zig` (new `init_00NN` creating `_authChallenges`)
- Create: `src/auth/challenge_store.zig` (put / take / gc)
- Modify: `src/root.zig` (test import)
- Modify: `src/records.zig` or wherever `gcCursorStates` lives (add `gcAuthChallenges` alongside, called by the same periodic GC)
- Test: `src/auth/challenge_store.zig`

**Interfaces:**
```zig
// _authChallenges schema (migration):
//   "id" TEXT PRIMARY KEY, "collectionRef" TEXT, "method" TEXT, "identity" TEXT,
//   "payload" TEXT NOT NULL, "expires" INTEGER NOT NULL, "consumed" INTEGER DEFAULT 0,
//   "created" TEXT NOT NULL  + index on (expires) and (collectionRef,method,identity)
pub const ChallengeStore = struct {
    conn: *db.Db,
    pub fn put(self: ChallengeStore, alloc, io, collection, method, identity, payload: []const u8, ttl_s: i64) ![]const u8; // returns the opaque id
    /// Atomically fetch-and-consume by id: returns the payload if present, unexpired, and not yet consumed; marks consumed. Null otherwise.
    pub fn take(self: ChallengeStore, alloc, id: []const u8) !?[]const u8;
    /// Fetch-and-consume the NEWEST unexpired unconsumed challenge for (collection,method,identity). For OTP where the client returns a code, not an id.
    pub fn takeByIdentity(self: ChallengeStore, alloc, collection, method, identity: []const u8) !?[]const u8;
};
pub fn gcAuthChallenges(w: *db.Db) !void; // DELETE WHERE expires <= unixepoch('now')
```

- [ ] **Step 1: Write the failing test** — over an in-memory DB with the table created: `put` a challenge, `take` it once → returns payload; `take` again → null (single-use). A second `put` for a different id with `ttl_s` in the past → `take` → null (expired). `takeByIdentity` returns and consumes the newest matching. `gcAuthChallenges` removes expired rows.

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement.** Migration: copy the `init_0006` (`_cursorStates`) pattern in `src/migrations.zig` exactly (next sequential `init_00NN`; read the file for the current highest number). `take`/`takeByIdentity` do SELECT-then-UPDATE-consumed under the writer (atomic like `consumeToken`: check `consumed=0 AND expires>now`, then set `consumed=1`; if the UPDATE affects 0 rows it was already taken → null). `put` generates a random id (`crypto.genToken`) like `_cursorStates` ids. Wire `gcAuthChallenges` into the same periodic GC call site as `gcCursorStates` (grep for `gcCursorStates`).

- [ ] **Step 4: Add test import to root.zig; run, verify pass.**

- [ ] **Step 5: Commit** — `feat(auth): _authChallenges ChallengeStore (TTL'd single-use challenge storage) + GC`

---

## Task 2: `magic_link` built-in method

**Files:**
- Create: `src/auth/methods/magic_link.zig`
- Modify: `src/auth/registry.zig` (add to built-ins list), `src/root.zig` (test import)
- Test: `src/auth/methods/magic_link.zig`

**Interfaces:** `MagicLinkMethod` (contract: create/method/deinit, slug "magic_link").
- `initiate`: parse `{email}` from `ac.ctx.body`; rate-limit via `ac.rateLimit("magic_link", email)`; resolve via `ac.findByIdentity(email)`; if found, `const tok = try ac.mintLinkToken(rid, ttl_s)` (ttl from `ac.collection.options.auth.methods.magic_link.?.ttl_s`, default 900) and `ac.deliverMail(email, "Your sign-in link", body_with_token)`. ALWAYS return `InitiateResult{ .status = 204, .body = null }` (enumeration-safe; also on missing/un-found email). On a rate-limit hit, return the 429 body via InitiateResult (status 429). 
- `complete`: parse `{token}`; `ac.verifyLinkToken(token) orelse return .fail{400,"Invalid or expired link."}`; `ac.consumeLinkToken(claims) catch return .fail{400,"Link already used."}`; return `Resolution{ .record = claims.id }`.

- [ ] **Step 1: Write the failing test** — over `TestEnv` with a magic_link-enabled collection + a user: call `initiate` with `{email}` → 204; mint isn't directly observable, so for `complete`, mint a link token via `ac.mintLinkToken` (or the helper) for the user, call `complete` with `{token}` → `.record == rid`; call `complete` again with the same token → `.fail` 400 (single-use). Bad token → `.fail` 400.

- [ ] **Step 2–4: TDD** (fail → implement → pass). The method body mirrors `password.zig`'s structure (ctx cast, vtable) and the M1 recipe's logic, but using the `AuthCtx` helpers. Read `src/auth/methods/password.zig` for the exact contract scaffolding.

- [ ] **Step 5: Register** in `registry.zig`'s built-ins list (`assembleTypes` → `.{ PasswordMethod, MagicLinkMethod, ... }`). Add the root.zig test import. Run full suite green.

- [ ] **Step 6: Commit** — `feat(auth): magic_link built-in method (passwordless email login on the contract)`

---

## Task 3: `otp` built-in method (uses ChallengeStore)

**Files:**
- Create: `src/auth/methods/otp.zig`
- Modify: `src/auth/registry.zig`, `src/root.zig`
- Test: `src/auth/methods/otp.zig`

**Interfaces:** `OtpMethod` (slug "otp").
- `initiate`: parse `{email}`; rate-limit; resolve `rid = ac.findByIdentity(email)`; if found, generate a random numeric code of `opts.length` digits (default 6) using `crypto.genToken`-style randomness reduced to digits (document the uniformity approach — rejection or modulo-with-care); store via `ChallengeStore.put(collection, "otp", email, code, opts.ttl_s)`; `ac.deliverMail(email, "Your sign-in code", code)`. ALWAYS return 204 (enumeration-safe).
- `complete`: parse `{email, code}`; `const stored = try ChallengeStore{.conn=ac.conn}.takeByIdentity(collection, "otp", email) orelse return .fail{400,"Invalid or expired code."}`; constant-time compare `stored` vs submitted `code` (use `std.crypto.timing_safe.eql` or `crypto.utils.timingSafeEql`); mismatch → `.fail{400,"Invalid or expired code."}` (the code was already consumed by `take` — single attempt per code; document this choice); on match resolve `rid = ac.findByIdentity(email)` → `Resolution{ .record = rid }` (or `.fail` if the user vanished).

- [ ] **Step 1: Write the failing test** — over `TestEnv` with an otp-enabled collection + user: call `initiate` with `{email}` → 204; since the code isn't returned, directly `ChallengeStore.put` a known code for the user (or expose a test seam), then `complete` with `{email, code}` → `.record == rid`; replay same code → `.fail` 400 (consumed); wrong code → `.fail` 400.

- [ ] **Step 2–4: TDD.** Build the method; reuse `ChallengeStore` from Task 1. Be careful with code generation uniformity and the constant-time compare.

- [ ] **Step 5: Register + test import + full suite green.**

- [ ] **Step 6: Commit** — `feat(auth): otp built-in method (email one-time codes via ChallengeStore)`

---

## Task 4: rpc-client generation for auth-method endpoints

**Files:**
- Modify: `src/codegen/rpc.zig` and/or `src/codegen/gen_client.zig` (read the integration map §4 for the exact comptime route-discovery + render path)
- Modify: the gen entry so it receives the comptime collections (it already gets `cols: []const schema.Collection`)
- Test: a generated-output snapshot assertion, or extend the existing `gen-*-client-check` fixture

**Interfaces:** for each collection whose `.options.auth.methods` enables a built-in method (or has `custom` slugs), emit a typed-ish rpc entry:
```ts
zb.auth.<collectionMethodName>.initiate(input): Promise<...>
zb.auth.<collectionMethodName>.complete(input): Promise<...>
```
named by collection + slug (e.g. `members.magicLink.initiate`). 

**Scope control (IMPORTANT):** full typed Initiate/Complete I/O per method is the ideal, but the generator is comptime-only and methods don't currently expose comptime I/O types. For THIS task, emit **untyped** stubs first — `initiate(input: Record<string, unknown>): Promise<unknown>` / `complete(input: Record<string, unknown>): Promise<unknown>` — POSTing to `/api/collections/<col>/auth/<slug>/{initiate,complete}`. This satisfies "auth endpoints appear in the rpc client" without the typed-I/O comptime machinery (which can be a later refinement once methods expose `pub const InitiateInput`/`CompleteInput` types). Clearly `// TODO(typed): emit typed I/O once methods declare comptime Initiate/Complete types` in the code.

- [ ] **Step 1:** Read `src/codegen/gen_client.zig:generate` and `src/codegen/rpc.zig:render` (per the integration map). Determine where collections are iterated for emission and where the rpc `Section` is assembled.

- [ ] **Step 2: Write the failing test/snapshot** — assert the generated client for a collection with `magic_link` enabled contains a `magicLink` (or `auth.magicLink`) entry hitting `/auth/magic_link/initiate`. Use the existing dating/golfsim fixture mechanism if practical, or a focused unit test calling the generator with a synthetic collection list.

- [ ] **Step 3: Implement** the emission: iterate `cols`, for each enabled method emit the initiate/complete stub pair under an `auth` namespace on the client. Mirror the existing rpc method-emission style (naming via camel-join). Keep it untyped per the scope-control note.

- [ ] **Step 4: Regenerate the committed client snapshots** that CI checks (`gen-dating-client-check`, golfsim `gen-client-check`) IF a fixture collection enables a method — if no fixture uses auth methods, the snapshots are unchanged and the checks stay green; verify with `mise exec zig@0.16.0 -- zig build gen-dating-client-check` and the golfsim one. If a fixture DOES need updating, regenerate and commit the new snapshot.

- [ ] **Step 5: Run full suite + the client-check build steps; all green.**

- [ ] **Step 6: Commit** — `feat(codegen): emit auth-method initiate/complete endpoints in the typed client`

---

## Self-Review

**Spec coverage (M3):** ChallengeStore (needed by otp + webauthn) → T1. magic_link built-in → T2. otp built-in → T3. rpc generation for auth endpoints (user-required) → T4 (untyped stubs; typed I/O noted as later refinement). **Deferred to M4:** oauth2-as-method, WebAuthn, consolidated docs.

**Risks/soft spots:** atomic single-use in `ChallengeStore.take` (mirror `consumeToken` exactly); OTP code uniformity + constant-time compare; the codegen path is comptime — the untyped-stub fallback is the de-risking move; regenerating CI-checked client snapshots without drifting unrelated output.
