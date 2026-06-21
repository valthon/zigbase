# Milestone 2 — AuthMethod contract + auto-mounting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Introduce the comptime `AuthMethod` plugin contract (the generalization of the OAuth2 provider model), re-express built-in `password` as the first method on it, auto-mount `/api/collections/:col/auth/:method/{initiate,complete}` endpoints driven by per-collection `.auth.methods` config, and have the framework own session issuance (via the Milestone-1 seam), `onAuth`, and rate-limiting around every method phase.

**Architecture:** An `AuthMethod` is a `{ slug, ctx, vtable{ initiate, complete } }` vtable view (same shape as the Storage/Mailer plugins). The framework assembles a comptime registry of built-in methods + a consumer's `.auth_methods` types, instantiates them at startup, and stores them on the `App`. Two new static routes carry a `:method` path param; one handler pair resolves the `:col` collection, checks `.options.auth.methods` for the slug, runs the method, and on a `complete` returning a record id calls the M1 `issueSession` seam (mint + `onAuth`). `password` becomes a method whose `complete` verifies identity+password; the legacy `/auth-with-password` route delegates to it (no behavior change).

**Tech Stack:** Zig 0.16.0 (`mise exec zig@0.16.0`), vendored SQLite, zap.

## Global Constraints

- Build/test ONLY via `/home/valthon/.local/bin/mise exec zig@0.16.0 -- zig build test --summary all`; authoritative signal is `Build Summary: N/N tests passed` (the `failed command:` line is spurious). Current baseline: **544/544**.
- A new `src/*.zig` file's tests do NOT run until added to the `test { _ = @import("…"); }` block in `src/root.zig`.
- `src/root.zig` re-exports every consumer-nameable type. New consumer-facing types (`AuthMethod`, `AuthCtx`, `InitiateResult`, `Resolution`) must be re-exported there.
- Safe-by-default: a method endpoint is reachable ONLY if its slug is enabled on that collection; an unknown/disabled method → 404. Rate-limit is ON by default around every phase; opting out is explicit and logged.
- **Backward compatibility is mandatory:** an existing `.auth` collection with NO `.auth.methods` config must behave exactly as today — `password` implicitly enabled, `/auth-with-password` unchanged, all existing auth/oauth browser tests green.
- Mirror the existing plugin precedent: `framework.zig:assertPluginContract` (create/interface/deinit). The AuthMethod contract validation mirrors it.
- Docs sync: any `docs/*.md` change mirrors into `site/src/content/docs/`; `cd site && npm run build` must pass.

**Reference:** design spec `docs/superpowers/specs/2026-06-19-pluggable-auth-methods-design.md` §4 (tiers), §6 (multi-collection), §14 (two-layer rate-limit). Integration map: `.superpowers/sdd/m2-m3-integration-map.md` (exact file:line for routes, config, rate-limiter, app struct).

---

## File map (Milestone 2)

- **Create `src/auth/method.zig`** — the contract: `AuthMethod`, `AuthMethod.VTable`, `AuthCtx`, `InitiateResult`, `Resolution`, `assertAuthMethodContract`. Pure types + the comptime validator; no business logic.
- **Create `src/auth/registry.zig`** — comptime assembly of the built-in + custom method TYPE list, runtime instantiation (`create`/`interface`/`deinit`), slug→instance lookup. The list of built-ins for M2 is just `password` (magic_link/otp/oauth2/webauthn arrive in M3/M4).
- **Create `src/auth/methods/password.zig`** — `password` built-in `AuthMethod` (complete: verify identity+password → record id; initiate: no-op). Reuses `api/auth.zig` helpers.
- **Modify `src/schema.zig`** — add `methods: MethodsOptions` to `AuthOptions`; define `MethodsOptions`, per-method opts structs, `RateLimitOpt`. Extend options JSON serialize/deserialize.
- **Modify `src/provision.zig`** — lower `.auth.methods` from the comptime `.collections` literal (in `buildCollection`).
- **Modify `src/framework.zig`** — add `auth_methods` to the allowed cfg-key whitelist; comptime-validate each custom method type; assemble the registry; instantiate at startup; store on `App`.
- **Modify `src/app.zig`** — add an `auth_methods` runtime field (slug→instance registry handle) + a `rate_limit_window_s` if not present.
- **Modify `src/server.zig`** — add the two static routes `/api/collections/:col/auth/:method/initiate` and `/complete`.
- **Create `src/api/auth_methods.zig`** — the auto-mount dispatch handlers (`initiate`, `complete`): resolve collection, check enablement, build `AuthCtx`, default rate-limit + override, run the method, on `Resolution.record` call `issueSession`. 
- **Modify `src/api/auth.zig`** — `authWithPassword` delegates to the password method's `complete` (keep the endpoint + response shape identical).
- **Modify `src/root.zig`** — re-exports + test-root imports for the four new files.
- **Docs:** `docs/framework.md` (new "Auth methods" section), `CHANGELOG.md`, + site mirrors.

---

## Task 1: The `AuthMethod` contract types + comptime validator

**Files:**
- Create: `src/auth/method.zig`
- Modify: `src/root.zig` (re-export + test import)
- Test: `src/auth/method.zig` (in-file `test {}`)

**Interfaces:**
- Produces (consumer- and framework-facing):
```zig
pub const InitiateResult = struct { status: u16 = 200, body: ?[]const u8 = null };
pub const Resolution = union(enum) {
    record: []const u8,                              // resolved record id → framework mints session + onAuth
    fail: struct { status: u16, message: []const u8 },
};
pub const AuthCtx = struct {                         // FIELDS ONLY in this task; helper methods land in Task 3
    app: *@import("../app.zig").App,
    ctx: *@import("../http.zig").RequestCtx,
    conn: *@import("../db.zig").Db,
    collection: @import("../schema.zig").Collection,
    config: std.json.Value,                          // this method's per-collection config (object; .null if none)
};
pub const AuthMethod = struct {
    slug: []const u8,
    ctx: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        initiate: *const fn (ctx: *anyopaque, ac: *AuthCtx) anyerror!InitiateResult,
        complete: *const fn (ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution,
    };
};
/// Mirrors framework.assertPluginContract: a method TYPE must declare create/method/deinit.
pub fn assertAuthMethodContract(comptime P: type) void { ... }
```

- [ ] **Step 1: Write the failing test** in `src/auth/method.zig`:

```zig
const std = @import("std");
test "assertAuthMethodContract accepts a well-formed method type and a Resolution round-trips" {
    const Good = struct {
        pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !@This() { return .{}; }
        pub fn method(self: *@This()) AuthMethod { return .{ .slug = "x", .ctx = self, .vtable = &vt }; }
        pub fn deinit(_: *@This()) void {}
        const vt = AuthMethod.VTable{ .initiate = undefined, .complete = undefined };
    };
    assertAuthMethodContract(Good); // compiles ⇒ pass
    const r: Resolution = .{ .record = "rec123" };
    try std.testing.expectEqualStrings("rec123", r.record);
    const f: Resolution = .{ .fail = .{ .status = 400, .message = "no" } };
    try std.testing.expectEqual(@as(u16, 400), f.fail.status);
}
```

- [ ] **Step 2: Run, verify fail** — `… zig build test --summary all 2>&1 | tail -8` → FAIL (file not imported / types undefined).

- [ ] **Step 3: Implement `src/auth/method.zig`** with the types above. `assertAuthMethodContract` mirrors `framework.zig:assertPluginContract` (read it first):
```zig
pub fn assertAuthMethodContract(comptime P: type) void {
    inline for (.{ "create", "method", "deinit" }) |decl| {
        if (!@hasDecl(P, decl))
            @compileError("'.auth_methods' type '" ++ @typeName(P) ++ "' is missing '" ++ decl ++
                "'; a method must declare create(gpa, io, cfg) !Self / method(*Self) AuthMethod / deinit(*Self) void");
    }
}
```

- [ ] **Step 4: Wire into `src/root.zig`** — re-export the consumer types and add the test import:
```zig
pub const AuthMethod = @import("auth/method.zig").AuthMethod;
pub const AuthCtx = @import("auth/method.zig").AuthCtx;
pub const InitiateResult = @import("auth/method.zig").InitiateResult;
pub const Resolution = @import("auth/method.zig").Resolution;
// in the test block:
test { _ = @import("auth/method.zig"); }
```

- [ ] **Step 5: Run, verify pass** — `Build Summary: 545/545` (or current+1).

- [ ] **Step 6: Commit** — `git add src/auth/method.zig src/root.zig && git commit -m "feat(auth): AuthMethod plugin contract types + comptime validator"`

---

## Task 2: Per-collection `.auth.methods` config (schema + lowering + JSON)

**Files:**
- Modify: `src/schema.zig` (`AuthOptions` + new structs + options JSON in/out)
- Modify: `src/provision.zig` (`buildCollection` lowers `.auth.methods`)
- Test: `src/schema.zig` (round-trip serialize/deserialize) + `src/provision.zig` (lowering)

**Interfaces:**
- Produces, in `schema.zig`:
```zig
pub const RateLimitOpt = union(enum) { default, off, custom: struct { max: u32, window_s: i64 } };
pub const PasswordMethodOpts = struct { rate_limit: RateLimitOpt = .default };
pub const MagicLinkMethodOpts = struct { ttl_s: i64 = 900, auto_create: bool = false, rate_limit: RateLimitOpt = .default };
pub const OtpMethodOpts = struct { length: u8 = 6, ttl_s: i64 = 300, auto_create: bool = false, rate_limit: RateLimitOpt = .default };
pub const WebAuthnMethodOpts = struct { rp_id: []const u8 = "", rp_name: []const u8 = "", origin: []const u8 = "", credentials_collection: []const u8 = "", rate_limit: RateLimitOpt = .default };
pub const MethodsOptions = struct {
    password: ?PasswordMethodOpts = null,
    magic_link: ?MagicLinkMethodOpts = null,
    otp: ?OtpMethodOpts = null,
    webauthn: ?WebAuthnMethodOpts = null,
    custom: []const []const u8 = &.{}, // slugs of .auth_methods to enable on this collection
};
// added to AuthOptions:
methods: MethodsOptions = .{},
```
- Backward-compat rule (Produces a helper): `pub fn passwordEnabled(col: Collection) bool` — true if `col.type == .auth` AND (`methods.password != null` OR the whole `methods` is default/empty). Used by the dispatcher and the legacy endpoint.

- [ ] **Step 1: Write the failing test** in `src/schema.zig` test block — options JSON round-trips the methods config:
```zig
test "AuthOptions.methods serializes + parses (magic_link ttl, password default)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const opts = CollectionOptions{ .auth = .{ .methods = .{
        .password = .{},
        .magic_link = .{ .ttl_s = 1200, .auto_create = true },
    } } };
    const json = try optionsToJson(a, opts);          // EXACT fn name: read schema.zig for the real serializer
    const back = try optionsFromJson(a, json);         // EXACT fn name: read schema.zig for the real parser
    try std.testing.expect(back.auth.methods.password != null);
    try std.testing.expect(back.auth.methods.magic_link != null);
    try std.testing.expectEqual(@as(i64, 1200), back.auth.methods.magic_link.?.ttl_s);
    try std.testing.expect(back.auth.methods.magic_link.?.auto_create);
}
```
> Implementer: the real serializer/parser fn names are NOT guaranteed to be `optionsToJson`/`optionsFromJson` — read `src/schema.zig` (the map cited `optionsToJson` near line 136) and how `.auth.oauth2` is currently serialized/parsed, and EXTEND those exact functions for `.methods`. Match the existing JSON shape conventions.

- [ ] **Step 2: Run, verify fail** — undefined `methods` field / fn behavior.

- [ ] **Step 3: Implement** — add the structs to `schema.zig`; add `methods` to `AuthOptions`; extend the options serializer to emit a `"methods"` object (only non-null members; encode `RateLimitOpt` as `{"mode":"default|off|custom","max":N,"window_s":N}`) and the parser to read it back. Add `passwordEnabled`. Mirror precisely how `oauth2` is handled in the same functions.

- [ ] **Step 4: Lower in provision** — in `src/provision.zig:buildCollection`, ensure `.auth.methods` from the comptime literal flows into the built `schema.Collection.options.auth.methods` (read how `.auth.oauth2.providers` is lowered there and mirror it; likely it already copies `.options` structurally — confirm and add `methods` if needed). Add a comptime test or extend an existing provision test asserting a collection literal with `.auth = .{ .methods = .{ .magic_link = .{} } }` lowers with `magic_link != null`.

- [ ] **Step 5: Run, verify pass.**

- [ ] **Step 6: Commit** — `git commit -m "feat(schema): per-collection .auth.methods config (enable/config built-in + custom auth methods)"`

---

## Task 3: `AuthCtx` blessed helpers

**Files:**
- Modify: `src/auth/method.zig` (add methods to `AuthCtx`)
- Test: `src/auth/method.zig`

**Interfaces:**
- Produces, on `AuthCtx` (thin delegations to `api/auth.zig` / `auth_helpers.zig`, all using `ac.conn`):
```zig
pub fn findByIdentity(ac: *AuthCtx, identity: []const u8) !?[]const u8;     // → api_auth.findByIdentity(.., ac.collection, ..)
pub fn mintLinkToken(ac: *AuthCtx, record_id: []const u8, ttl_s: i64) ![]const u8; // → auth_helpers.mintLinkToken → .token
pub fn verifyLinkToken(ac: *AuthCtx, token: []const u8) !?@import("../jwt.zig").Claims;
pub fn consumeLinkToken(ac: *AuthCtx, claims: anytype) !void;
pub fn deliverMail(ac: *AuthCtx, to: []const u8, subject: []const u8, body: []const u8) !void;
pub fn rateLimit(ac: *AuthCtx, scope: []const u8, ident: []const u8) !?@import("../http.zig").Response;
```

- [ ] **Step 1: Write the failing test** — build an `AuthCtx` over the `api/auth.zig` `TestEnv` (now `pub`), seed a user, and assert `ac.findByIdentity(email)` returns the rid and `ac.mintLinkToken(rid, 900)` returns a non-empty token. (Read `api/auth.zig`'s TestEnv for how to get an app+conn+collection; construct `AuthCtx{ .app=…, .ctx=…, .conn=…, .collection=…, .config=.null }`.)

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** the helper methods as delegations (import `api/auth.zig` and `auth_helpers.zig`; each is 1–3 lines). Match the real signatures (e.g. `auth_helpers.mintLinkToken(ctx, conn, collection_name, rid, ttl)` returns `LinkToken{ .token }`).

- [ ] **Step 4: Run, verify pass.**

- [ ] **Step 5: Commit** — `git commit -m "feat(auth): AuthCtx blessed helpers (identity/link-token/mail/rate-limit) bound to the request connection"`

---

## Task 4: Built-in `password` AuthMethod

**Files:**
- Create: `src/auth/methods/password.zig`
- Modify: `src/root.zig` (test import)
- Test: `src/auth/methods/password.zig`

**Interfaces:**
- Produces: `PasswordMethod` type satisfying the contract (`create`/`method`/`deinit`), `slug = "password"`. `initiate` returns `InitiateResult{ .status = 200, .body = null }` (no challenge). `complete` reads `{identity, password}` from `ac.ctx.body`, verifies via the existing `api/auth.zig` machinery (`findByIdentity`, `passwordHashFor`, `crypto.verifyPassword`, the dummy-verify timing defense), returns `Resolution{ .record = rid }` on success or `Resolution{ .fail = .{ .status = 400, .message = "Invalid credentials." } }` otherwise.

- [ ] **Step 1: Write the failing test** — over `TestEnv`, seed a user, build an `AuthCtx` with body `{"identity":"u@x.io","password":"longenough"}`, call `PasswordMethod`'s `complete` (via its vtable) and assert `.record` == the user's rid; with a wrong password assert `.fail` with status 400. (Make the method instance: `var m = try PasswordMethod.create(...); const am = m.method(); const res = try am.vtable.complete(am.ctx, &ac);`.)

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** `password.zig`. Reuse `api/auth.zig`'s now-`pub` `findByIdentity`, `passwordHashFor` (make `pub` if needed), `crypto.verifyPassword`, `crypto.dummyVerify`. Preserve the account-enumeration timing defense (dummy-verify on unknown identity / missing hash). The method is stateless (`create` returns `.{}`, `deinit` no-op).

- [ ] **Step 4: Add the test import to `src/root.zig`** (`test { _ = @import("auth/methods/password.zig"); }`).

- [ ] **Step 5: Run, verify pass.**

- [ ] **Step 6: Commit** — `git commit -m "feat(auth): built-in password AuthMethod (verifies identity+password → record)"`

---

## Task 5: The method registry + App wiring + `.auth_methods` comptime validation

**Files:**
- Create: `src/auth/registry.zig`
- Modify: `src/framework.zig` (allowed-key whitelist + validate + assemble + instantiate)
- Modify: `src/app.zig` (runtime field)
- Test: `src/auth/registry.zig`

**Interfaces:**
- Produces: `Registry` = a runtime slug→`AuthMethod` lookup. `pub fn get(self: *const Registry, slug: []const u8) ?AuthMethod`. Built-ins (M2: just `password`) are always registered; consumer `.auth_methods` types are appended. A comptime `assembleTypes(cfg)` returns the ordered TYPE list (built-ins ++ custom). Instances are created at startup (`create`→stored→`method()` view collected into the Registry; `deinit` on shutdown).
- `framework.zig`: add `"auth_methods"` to the `allowed` whitelist; for each custom type call `auth.method.assertAuthMethodContract(T)` at comptime; instantiate alongside storage/mailer in `serveImpl`; pass the assembled `Registry` to the `App`.
- `app.zig`: add `auth_method_registry: ?*const @import("auth/registry.zig").Registry = null` (opaque-free is fine since app.zig can import the registry; if it causes an import cycle, store `?*const anyopaque` and cast in the handler).

- [ ] **Step 1: Write the failing test** in `registry.zig` — a `Registry` built with the built-in password method returns it for slug `"password"` and `null` for `"nope"`. (Construct the registry the same way the framework will: instantiate `PasswordMethod`, collect its `.method()` view.)

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** `registry.zig` (the slug→AuthMethod array + `get`), and the comptime `assembleTypes`. Then wire `framework.zig`: whitelist key, comptime-validate each `.auth_methods` type, instantiate in `serveImpl` (mirror storage/mailer at framework.zig:687–696), build the Registry, set it on `App`. Update `app.zig` with the field.
> Implementer: watch for import cycles (app.zig ↔ registry.zig ↔ method.zig). If `app.zig` importing `registry.zig` cycles, hold the registry as `*const anyopaque` on `App` and `@ptrCast` in `api/auth_methods.zig`. Read how `dispatch`/`rate_limiter` pointers are held on `App` and mirror that lifetime pattern.

- [ ] **Step 4: Run, verify pass** — and confirm a no-`.auth_methods` build still compiles (the key is optional).

- [ ] **Step 5: Commit** — `git commit -m "feat(framework): auth-method registry + .auth_methods custom-type validation/instantiation"`

---

## Task 6: Auto-mounted `:method` routes + dispatch handler (mint via the seam + rate-limit)

**Files:**
- Create: `src/api/auth_methods.zig`
- Modify: `src/server.zig` (two routes)
- Modify: `src/root.zig` (test import)
- Test: `src/api/auth_methods.zig`

**Interfaces:**
- Produces handlers `initiate(ctx) !http.Response` and `complete(ctx) !http.Response`. Shared logic:
  1. `col` = `ctx.param("col")`; load collection; if `col.type != .auth` → 404.
  2. `slug` = `ctx.param("method")`; if not enabled on `col` (per `.options.auth.methods`, with the `passwordEnabled` backward-compat rule for `password`) → 404.
  3. Resolve the `AuthMethod` from `app.auth_method_registry.get(slug)` → 404 if absent.
  4. **Rate-limit** (default ON): apply the method's `RateLimitOpt` (`default` → the global limiter with scope `"auth:<slug>"`; `off` → skip, logged once; `custom` → a per-method limiter) and the optional override fn if the method type exposes one. On limit → 429.
  5. Build `AuthCtx` (acquire writer for `complete`, reader is fine for `initiate` but use writer for simplicity/single connection; load the method config object from `col.options`).
  6. Run `initiate`/`complete` via the vtable.
  7. `initiate` → return its `InitiateResult` as an `http.Response`. `complete` → on `.record` call `api/auth.zig:issueSession(ctx, conn, col.name, rid, .custom)` (mint + onAuth) and return 200 `{token, record}` + cookies; on `.fail` return that status/message.
- `server.zig`: add
```zig
.{ .method = .POST, .pattern = "/api/collections/:col/auth/:method/initiate", .handler = auth_methods_api.initiate },
.{ .method = .POST, .pattern = "/api/collections/:col/auth/:method/complete", .handler = auth_methods_api.complete },
```
  Place them so they do NOT shadow the existing single-segment auth routes (they won't — different segment counts).

- [ ] **Step 1: Write the failing test** — over `TestEnv` with a collection that has `password` enabled, drive `complete` with params `{col, method=password}` and body `{"identity","password"}`; assert 200 + 2 cookies + `onAuth` fired once. Then a disabled/unknown method slug → 404. (Set `env.app.auth_method_registry` to a registry containing the password method; install an onAuth counter as in M1 tests.)

- [ ] **Step 2: Run, verify fail.**

- [ ] **Step 3: Implement** `auth_methods.zig` per Interfaces. For the method-config lookup, read `col.options.auth.methods` for the slug's opts (and its `rate_limit`). For `password` use the `passwordEnabled` rule. Reuse `api/auth.zig:rateLimited` for the `default` rate-limit mode (scope `"auth:" ++ slug`).

- [ ] **Step 4: Wire routes in `server.zig`; add the test import to `root.zig`.**

- [ ] **Step 5: Run, verify pass** — full suite green; confirm the new routes don't break existing route matching (run an existing router/server test if present).

- [ ] **Step 6: Commit** — `git commit -m "feat(api): auto-mounted /auth/:method/{initiate,complete} dispatch through the session seam + rate-limit"`

---

## Task 7: Legacy `/auth-with-password` delegates to the password method

**Files:**
- Modify: `src/api/auth.zig` (`authWithPassword` delegates)
- Test: existing auth tests must stay green; add a parity assertion if useful.

**Interfaces:** no new surface. `authWithPassword` builds an `AuthCtx` and calls the registry's `password` method `complete`, then on `.record` calls `issueSession(.., .password)` (note: `.password` tag here, preserving the existing `onAuth` method tag for this endpoint) and returns the SAME JSON `{token, record}` + cookies as today. If the registry/method is somehow absent (e.g. tests without a registry), fall back to the current inline logic so unit tests without a wired registry still pass — OR ensure the test harness wires a default registry. Keep the endpoint's response bytes identical.

- [ ] **Step 1:** Read the current `authWithPassword`. Decide the delegation that preserves the `.password` onAuth tag and the response shape. (The method's `complete` returns only a record id; `authWithPassword` keeps ownership of the `issueSession(.., .password)` call so the tag stays `.password`, not `.custom`.)

- [ ] **Step 2:** Add a test asserting `authWithPassword` still returns 200 + token + record + 2 cookies and fires `onAuth(.password)` once (this likely already exists from M1 — extend/confirm it covers the delegated path).

- [ ] **Step 3: Implement** the delegation with the registry-absent fallback.

- [ ] **Step 4: Run the full unit suite + the auth/login browser subset** (`mise exec python@3.13 -- python -m pytest tests/admin -k "auth or login" -q`). Both green.

- [ ] **Step 5: Commit** — `git commit -m "refactor(auth): authWithPassword delegates to the password AuthMethod (no behavior change)"`

---

## Task 8: Docs + changelog for the auth-method contract

**Files:** `docs/framework.md` (+ site mirror), `CHANGELOG.md` (+ site mirror).

- [ ] **Step 1:** Add an "Auth methods" section to `docs/framework.md` documenting: the `.auth.methods` per-collection config (enable password/magic_link/otp/webauthn + rate-limit knobs), the auto-mounted `/api/collections/:col/auth/:method/{initiate,complete}` endpoints, the multi-collection example from spec §6 (members=magic_link, staff=password+webauthn), and the `.auth_methods` custom-type contract (`create`/`method`/`deinit` → `AuthMethod`). State that `complete` returns a record id and the framework mints the session + fires `onAuth`.

- [ ] **Step 2:** Mirror into `site/src/content/docs/framework.md`.

- [ ] **Step 3:** CHANGELOG `[Unreleased]` (both copies) — Added: the `AuthMethod` contract, `.auth.methods` config, auto-mounted method endpoints, default rate-limiting per phase.

- [ ] **Step 4:** `cd site && npm run build` passes.

- [ ] **Step 5: Commit** — `git commit -m "docs(auth): AuthMethod contract + .auth.methods config + auto-mounted endpoints"`

---

## Self-Review

**Spec coverage (M2):** §4 Tier-2 contract → T1,T3,T4,T5. §4 Tier-1 config → T2. §6 multi-collection auto-mount → T6 (and docs T8). §14 two-layer rate-limit → T6 (default + per-method `RateLimitOpt`; the full override-fn surface is exercised here and completed for custom methods in T5/T6). Backward-compat (password default + legacy endpoint) → T2 (`passwordEnabled`) + T7. **Deferred to M3/M4:** magic_link/otp method bodies, rpc generation, oauth2-as-method refactor, webauthn, ChallengeStore — those are separate plans.

**Placeholder scan:** real Zig in every code step; the few "read the real fn name in schema.zig" notes are explicit reconciliation instructions (the serializer name is the one thing I can't guarantee without the file), not placeholders.

**Type consistency:** `AuthMethod`/`AuthCtx`/`Resolution`/`InitiateResult` defined in T1 and used unchanged in T3–T7. `MethodsOptions`/`RateLimitOpt` defined T2, consumed T6. Registry `get(slug) ?AuthMethod` defined T5, consumed T6/T7. `issueSession(.., method)` is the M1 seam (5-arg), used with `.custom` in T6 and `.password` in T7.

**Soft spots for implementers (compiler is ground truth):** the exact options serialize/parse fn names + JSON shape in `schema.zig` (T2); possible app.zig↔registry import cycle (T5, fallback to `*const anyopaque`); ensuring the new 3-segment routes don't shadow existing auth routes (T6 — different segment counts, but run the router tests).
