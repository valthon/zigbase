# OAuth2 onto the AuthMethod contract — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** Refactor OAuth2 onto the `AuthMethod` contract (spec §9, the "proof obligation"): one copy of the OAuth2 logic, exposed BOTH at the existing legacy endpoints (unchanged) AND as the `oauth2` built-in method auto-mounted at `/api/collections/:col/auth/oauth2/{initiate,complete}`, firing `onAuth(.oauth2)` through the shared session seam.

**Architecture:** Extract the security-critical OAuth2 core (body+provider+secret prep; the CSRF `state` consume; the link/create decision tree) into shared functions in `src/api/oauth.zig`. The legacy `authWithOAuth2Impl` keeps its connection-management optimization (reader to load, writer released during provider HTTP, writer to resolve) and its rich `{token,record,meta:{isNew}}` response. A new `OAuth2Method` (`src/auth/methods/oauth2.zig`) reuses the same shared functions; its `complete` runs on the dispatch-held `ac.conn` (so it holds the writer across the provider HTTP — a bounded, documented tradeoff on the NEW endpoint only; legacy is unaffected). The generic dispatch already maps slug `oauth2` → `onAuth(.oauth2)`.

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0`), vendored SQLite, zap.

## Global Constraints

- Build/test ONLY via `/home/valthon/.local/bin/mise exec zig@0.16.0 -- zig build test --summary all`; authoritative signal `Build Summary: N/N tests passed` (the `failed command:` line is spurious). Current baseline: **668/668**.
- New `src/*.zig` files' tests don't run until added to `src/root.zig`'s `test { _ = @import(...) }` block.
- **Backward compatibility is mandatory:** the legacy endpoints `/oauth2-providers`, `/oauth2-init`, `/auth-with-oauth2` MUST behave EXACTLY as today (response bytes, status codes, CSRF state semantics, account-linking decisions). The existing oauth unit tests AND the `tests/admin -k oauth` browser test must stay green.
- **Security parity:** the refactor must not weaken: server-side `state` is single-use + TTL'd + consumed BEFORE burning the auth code; PKCE `codeVerifier` still required; `redirectUrl` allow-list enforced; provider URLs must be https; the link/create decision tree (existing-link → reuse; authed user → link with the "already linked to another account" 409 guard; else create+link with the "email already registered" 409) is preserved bit-for-bit.
- **Writer-during-HTTP tradeoff** applies ONLY to the new `/auth/oauth2/complete` endpoint and must be documented; the legacy endpoint keeps releasing the writer during provider HTTP.
- Docs sync: `docs/*.md` ↔ `site/src/content/docs/`; `cd site && npm run build` passes.

**Reference:** design spec `docs/superpowers/specs/2026-06-19-pluggable-auth-methods-design.md` §9. Current code: `src/api/oauth.zig` (`authWithOAuth2Impl` lines ~218-293 is the flow to factor; `resolveProvider`/`findProviderConfig`/`redirectAllowed`/`consumeState`/`createOAuthRecord`/`findLink`/`insertLink`/`respondSession` are the existing pieces). Dispatch: `src/api/auth_methods.zig` (`methodEnabled`, `rateLimitOptFor`, the `.oauth2` tag at line 139). Registry builtins: `src/auth/registry.zig`.

---

## Task 1: Extract shared OAuth2 core (pure refactor, no behavior change)

**Files:**
- Modify: `src/api/oauth.zig`
- Test: existing oauth unit tests must stay green (no new behavior).

**Interfaces — Produces (all `pub` for the method to reuse):**
```zig
pub const Prepared = struct {
    provider_name: []const u8,
    code: []const u8,
    verifier: []const u8,
    redirect_url: []const u8,
    state: ?[]const u8,          // present iff body had it
    cfg: schema.OAuth2Provider,
    provider: providers.Provider,
    secret: []const u8,          // decrypted client secret
};
pub const PrepareResult = union(enum) { ok: Prepared, fail: struct { status: u16, message: []const u8 } };
pub const Outcome = union(enum) {
    record: struct { rid: []const u8, is_new: bool },
    fail: struct { status: u16, message: []const u8 },
};

/// Body parse + provider config resolve + redirect allow-list + secret decrypt. NO DB, NO HTTP.
pub fn prepareOAuth(ctx: *http.RequestCtx, col: schema.Collection) !PrepareResult;

/// The link/create decision tree (currently inline at authWithOAuth2Impl lines ~264-292),
/// given a fetched provider identity. Uses `conn` (writer). Returns the resolved record id
/// + is_new, or a fail. Does NOT mint a session.
pub fn resolveRecordFromIdentity(
    ctx: *http.RequestCtx, conn: *db.Db, col: schema.Collection,
    provider_name: []const u8, identity: providers.Identity,
) !Outcome;
```

- [ ] **Step 1:** Read `authWithOAuth2Impl` (oauth.zig ~218-293) and the helpers it calls. Identify the three slices: (a) parse+provider+secret (222-256), (b) state consume (241-250), (c) HTTP (259-262), (d) decision tree (264-292).

- [ ] **Step 2:** Implement `prepareOAuth` = slice (a): parse body (`provider`/`code`/`codeVerifier`/`redirectUrl`, optional `state`), `findProviderConfig` (→ `.fail{404}` on miss), `resolveProvider` (→ `.fail{400,"Provider misconfigured."}`), `redirectAllowed` (→ `.fail{400,"redirectUrl not allowed."}`), `secrets.decryptSecret` (→ `.fail{500}` ... use `ApiError.internal` status 500). Return `.ok{...}`. Pure (reads `col` + body only).

- [ ] **Step 3:** Implement `resolveRecordFromIdentity` = slice (d): exactly the existing decision tree (findLink → existing-link reuse with the authed-mismatch 409; authed_rid → insertLink+reuse; else createOAuthRecord+insertLink with the two 409 guards), but returning `Outcome.record{rid,is_new}` instead of calling `respondSession`. Preserve the `auth.authenticate(...) catch null` authed-user detection and every 409 message verbatim.

- [ ] **Step 4: Refactor `authWithOAuth2Impl` to USE the new helpers** while keeping its connection optimization and `respondSession` call:
  - phase 1: load col (reader) — unchanged.
  - `const prep = switch (try prepareOAuth(ctx, col)) { .fail => |f| return ApiError{...f}.toResponse(...), .ok => |p| p };` — replaces 222 + 252-256. (Note: prepareOAuth now also does the body parse that lines 220-225 did; reconcile so the col_name/param handling still works — col_name comes from `ctx.param("col")` as before.)
  - state consume: if `app.oauth_state_server`, require `prep.state` (→400 "state is required.") and `consumeState` (writer, brief) — unchanged logic, now using `prep.state`.
  - HTTP: `exchangeCode`/`fetchIdentity` using `prep.provider`/`prep.cfg.clientId`/`prep.secret` — unchanged, no lock.
  - phase 3: `const outcome = try resolveRecordFromIdentity(ctx, w, col, prep.provider_name, identity);` then `switch (outcome) { .fail => |f| return ApiError{...}.toResponse, .record => |r| return respondSession(ctx, w, col, r.rid, r.is_new) }`.
  - **The externally observable behavior (responses, statuses, CSRF, linking) must be identical.**

- [ ] **Step 5: Run the oauth unit tests + the full suite.**
  Run: `/home/valthon/.local/bin/mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | tail -10`
  Expected: `Build Summary: 668/668` (no count change — pure refactor; the existing oauth tests at oauth.zig:352+ exercise resolveProvider/the full flow). Then `timeout 200 mise exec python@3.13 -- python -m pytest tests/admin -k oauth -q 2>&1 | tail -8` → pass.

- [ ] **Step 6: Commit** — `refactor(oauth): extract prepareOAuth + resolveRecordFromIdentity shared core (no behavior change)`

---

## Task 2: `OAuth2Method` on the contract + registry + dispatch enablement

**Files:**
- Create: `src/auth/methods/oauth2.zig`
- Modify: `src/auth/registry.zig` (add `OAuth2Method` to builtins; update the builtin-count test)
- Modify: `src/api/auth_methods.zig` (`methodEnabled` + `rateLimitOptFor` recognize `"oauth2"`)
- Modify: `src/root.zig` (test import)
- Test: `src/auth/methods/oauth2.zig`

**Interfaces:**
- `OAuth2Method` (stateless): `create(gpa,io,cfg)!OAuth2Method` / `method(*OAuth2Method) AuthMethod` (slug `"oauth2"`) / `deinit`.
- `initiate(ctx, ac)`: parse `{provider}` from body; `findProviderConfig`(via the collection's oauth2 options) → 404 if absent/not enabled; `resolveProvider` → 400 if misconfigured; if `ac.app.oauth_state_server`, mint a `state` via the existing `issueState`-equivalent (it's `fn` in oauth.zig — make it `pub` or expose a wrapper); return `InitiateResult{ .status=200, .body = JSON {authURL, clientId, scopes:[...], state?} }`.
- `complete(ctx, ac)` (vtable): build the real transport (`oauth_client.httpContext` + `httpTransport`, mirroring `authWithOAuth2` at oauth.zig:296-300) and call `completeImpl(ac, transport)`.
- `completeImpl(ac, transport)` (testable): `prepareOAuth(ac.ctx, ac.collection)` (→ map `.fail` to `Resolution.fail`); if `ac.app.oauth_state_server` require+`consumeState(ac.conn, ...)` (→ `.fail{400,"Invalid or expired state."}`/"state is required."); `exchangeCode`/`fetchIdentity` (transport); `resolveRecordFromIdentity(ac.ctx, ac.conn, ac.collection, prep.provider_name, identity)` → map `Outcome.record` to `Resolution{ .record = rid }`, `Outcome.fail` to `Resolution.fail`. (The dispatch mints the session + fires `onAuth(.oauth2)`.)

- [ ] **Step 1:** In `src/api/auth_methods.zig`, teach `methodEnabled`: add `if (std.mem.eql(u8, slug, "oauth2")) return col.options.auth.oauth2.enabled;` (BEFORE the `methods.custom` loop; oauth2 is gated by the EXISTING oauth2.enabled config, NOT `.methods`). In `rateLimitOptFor`, leave oauth2 → `.default` (no per-method opt; it falls through to the existing default branch already). Build to confirm no break (`668/668`).

- [ ] **Step 2: Write the failing test** in `oauth2.zig`: reuse `src/api/oauth.zig`'s test harness/stub (`OAuthStub`/`TestEnv`) — read how the existing `authWithOAuth2Impl` tests build a collection with an enabled provider + a stub transport that returns a known identity. Build an `AuthCtx` over a writer conn + that collection. Call `OAuth2Method.completeImpl(&ac, stubTransport)` and assert it returns `Resolution{ .record = <the linked/created rid> }`. Add a negative: a stub whose exchange fails → `.fail`. (If the oauth `TestEnv`/`OAuthStub` are not `pub`, make them `pub` minimally, OR build a local harness.)

- [ ] **Step 2b:** Run, verify FAIL (oauth2.zig not imported / method undefined).

- [ ] **Step 3: Implement `oauth2.zig`** per Interfaces, delegating to the Task-1 shared helpers (`prepareOAuth`, `resolveRecordFromIdentity`) + existing `consumeState`/`exchangeCode`/`fetchIdentity`/`issueState`. Mirror `authWithOAuth2`/`authWithOAuth2Impl` split for testability (`complete` builds real transport → `completeImpl(ac, transport)`).

- [ ] **Step 4:** Register `OAuth2Method` in `registry.zig` builtins (`&.{ PasswordMethod, MagicLinkMethod, OtpMethod, WebAuthnMethod, OAuth2Method }`); update the builtin-count/contents test. Add the `oauth2.zig` test import to `root.zig`.

- [ ] **Step 5: Run the full suite + oauth browser test.**
  `… zig build test --summary all` → `Build Summary: N/N` (≥ 668 + your new tests). Then `timeout 200 mise exec python@3.13 -- python -m pytest tests/admin -k oauth -q` → pass.

- [ ] **Step 6: Commit** — `feat(auth): OAuth2 as a built-in AuthMethod (initiate/complete) reusing the shared core`

---

## Task 3: Docs + changelog

**Files:** `docs/framework.md` + `docs/api.md` (+ site mirrors), `CHANGELOG.md` (+ site mirror).

- [ ] **Step 1:** In `docs/framework.md` (the auth-methods section) + `docs/api.md`: document that OAuth2 is now ALSO available as a contract method at `/api/collections/:col/auth/oauth2/{initiate,complete}` (gated by `.auth.oauth2.enabled`), alongside the unchanged legacy `/oauth2-init` / `/auth-with-oauth2` / `/oauth2-providers` endpoints. Show the `initiate` response shape ({authURL, clientId, scopes, state?}) and the `complete` body ({provider, code, codeVerifier, redirectUrl, state?}) → {token} + cookies. **Document the writer-during-HTTP note** for the new `complete` endpoint (the legacy endpoint remains the lock-optimized path for high-concurrency OAuth). Update the spec §9 "OAuth2 NOT refactored" note wherever it appears in docs to reflect that it now IS on the contract.

- [ ] **Step 2:** Mirror to `site/src/content/docs/`.

- [ ] **Step 3:** CHANGELOG `[Unreleased]` (both copies): "OAuth2 is now a first-class `AuthMethod` — available at the auto-mounted `/auth/oauth2/{initiate,complete}` endpoints in addition to the existing dedicated endpoints; both share one implementation and the single session seam."

- [ ] **Step 4:** `cd site && npm run build` passes.

- [ ] **Step 5: Commit** — `docs(auth): OAuth2 as a contract method (endpoints, initiate/complete, writer-during-HTTP note)`

---

## Self-Review

**Spec coverage:** §9 (OAuth2 onto the contract: `initiate`=authorize/state, `complete`=exchange→userinfo→link→record, legacy as aliases, `onAuth(.oauth2)` via the seam) → Tasks 1-2. Docs → Task 3. **Deviation from §9:** `state` stays in the dedicated `_oauthStates` table (not migrated to `ChallengeStore`) — lower-risk, the existing store is purpose-built/single-use/TTL'd; note in the report.

**No placeholders:** real interfaces; the one reconciliation note (prepareOAuth absorbing the body-parse that authWithOAuth2Impl did inline) is explicit.

**Type consistency:** `Prepared`/`PrepareResult`/`Outcome` defined in Task 1, consumed in Task 2. `resolveRecordFromIdentity(ctx, conn, col, provider_name, identity)` signature stable across both. The dispatch's `.oauth2` tag (auth_methods.zig:139) already exists — Task 2 only adds `methodEnabled` recognition.

**Soft spots (compiler/tests are ground truth):** the exact `OAuthStub`/`TestEnv` visibility in oauth.zig (Task 2 test — may need `pub`); `issueState` is currently `fn` (make `pub` for the method's initiate); preserving `authWithOAuth2Impl`'s exact response/status bytes through the extraction (Task 1 — guarded by the existing oauth tests + browser test).

## Security review (after Task 2)

Dispatch a security reviewer (OAuth-aware): confirm the refactor preserves — single-use/TTL `state` consumed before code burn; PKCE required; redirect allow-list; https-only provider URLs; the link/create decision tree's account-takeover guards (the two 409s); no secret logged; and that the new `complete` path enforces the SAME `state`/PKCE checks as legacy (a method that skipped `state` when `oauth_state_server` is on would be a CSRF regression). Confirm the writer-during-HTTP hold is the only behavioral delta and is not a correctness/deadlock issue (it uses `ac.conn`, no re-acquire).
