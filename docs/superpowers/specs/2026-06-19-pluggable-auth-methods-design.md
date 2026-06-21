# Pluggable auth methods — design

**Date:** 2026-06-19
**Status:** Design / brainstorm output (pre-implementation)
**Motivating PR:** #46 (`feat(auth): export issueSession for custom auth flows`)

## 1. Problem

A real app being ported to ZigBase framework mode uses **passwordless / magic-link
login**. ZigBase ships password auth, OAuth2+PKCE, email verification, and password
reset — all hardcoded in `src/api/auth.zig` and `src/api/oauth.zig` — but no
first-class way to add a *new* login method.

PR #46 works around this by re-exporting `issueSession()` (mint a native `.auth`
session for an arbitrary record id) so a consumer's custom route can validate its own
emailed token and then mint a real session. That unblocks magic-link, but it is the
wrong seam for the framework:

- **It exports the single most security-sensitive primitive** (mint a valid session for
  *any* record id) as a bare function, with no surrounding guarantees.
- **It silently bypasses `emitAuth`.** A custom route calling `issueSession` directly
  never fires the consumer's `onAuth` handler — so magic-link logins become invisible to
  observability/audit, creating a second, less-safe login path that sidesteps the
  framework's own contract.
- **It forces consumers to re-implement machinery the framework already has.** Token
  minting with a random `jti` (`mintToken`), single-use/replay protection via the
  `_consumedTokens` ledger (`consumeToken`), typed-token verification against the
  per-record `tokenKey` (`verifyTyped`), mailer delivery (`deliverToken`), and
  rate-limiting (`rateLimited`) are all present — but **private** to `api/auth.zig`. A
  magic-link consumer either reinvents them (likely insecurely) or the framework leaks
  one primitive at a time forever.

In short: **the framework already contains a magic-link implementation; it is just
welded shut inside `api/auth.zig`.** The task is to choose the right seam, not to export
a primitive.

### Three existing extension philosophies, and auth fits none

ZigBase already has three distinct extension styles:

1. **Custom routes** (`.routes`) — full power, typed I/O, DB access, can set cookies. The
   generic endpoint extension PR #46 leans on.
2. **Plugin vtables** (`.storage` / `.mailer`) — a comptime contract
   (`create` / `interface` / `deinit` → vtable) the consumer implements.
3. **Config-driven providers** (OAuth2 `.options.auth.oauth2.providers`) — a structured,
   data-driven extension point for a *family* of auth methods (presets + generic-endpoint
   override).

Auth doesn't cleanly belong to any of them yet. The key observation that resolves this:
**OAuth2's provider model is already a working prototype of the abstraction we want** —
it just isn't general, and the other methods can't reach it.

## 2. The unifying insight

Every method we want to support — magic-link, email/SMS OTP, WebAuthn/passkeys, OAuth2
(google / twitter / linkedin) — is the **same two-phase shape**:

1. **initiate** — the client offers an identity hint (email, username, or nothing for
   discoverable WebAuthn); the server produces a *challenge* (emails a link/code, returns
   a WebAuthn challenge, returns an OAuth2 redirect URL) and may store server-side state.
2. **complete** — the client returns *proof* (clicked token, typed code, signed
   assertion, OAuth2 `code` + `state`); the server verifies it, resolves it to a record in
   an auth collection (creating/linking if the method allows), and **the framework then
   mints the session and fires `onAuth`**.

OAuth2 already implements exactly this: `initiate` = build the authorize redirect + store
`state`; `complete` = exchange the code → fetch userinfo → `extractIdentity` → link a
record. So the design is not "invent an auth-plugin system" — it is "**extract the
lifecycle OAuth2 already implements, and let other methods plug into it.**"

## 3. Goals / non-goals

**Goals**

- One coherent way to add an auth method, from "flip a config flag" to "write a plugin."
- Security-sensitive machinery (replay ledger, rate-limit, cookie issuance, `onAuth`
  emission, record linking) owned by the framework, not re-implemented per consumer.
- **Multiple auth methods, scoped per user/resource type, mounted at distinct paths** —
  e.g. `members` log in by magic-link, `staff` by password + WebAuthn (see §6).
- A single audited seam where every session is minted and every `onAuth` fires.
- Backward compatible: existing `auth-with-password` / `auth-with-oauth2` endpoints keep
  working unchanged.

**Non-goals (this design)**

- Implementing WebAuthn itself. WebAuthn is the *stress test* the contract must not
  preclude (§8); shipping it is later work.
- Multi-factor orchestration (chaining two methods into one login). The contract should
  not make it *impossible*, but step-up/MFA is explicitly deferred.
- Session storage redesign. We keep the existing native `.auth` JWT (`zb_auth` /
  `zb_csrf`) and the per-record `tokenKey` model.

## 4. Architecture: three tiers on one core

The whole design rests on one rule:

> **`issue()` + `emitAuth()` is the *only* place a session is minted and the *only* place
> `onAuth` fires.** Every tier below converges on it.

### The core seam

`issue()` (already in `api/auth.zig`) signs the native `.auth` JWT and returns the
`zb_auth` / `zb_csrf` cookies. We add one rule: **session issuance always routes through a
single `issueSession(ctx, conn, collection, record_id)` that calls `issue()` and then
`emitAuth(...)`.** PR #46's function is corrected to emit `onAuth` (with a `method` tag,
§9) rather than skip it. Nothing — built-in, plugin, or escape hatch — mints a session by
any other path.

### Tier 1 — config-driven built-in methods (the 90%)

The framework ships `password`, `magic_link`, `otp`, and `oauth2` as built-in methods.
You enable them **per auth-collection** with config; zero consumer code. They reuse the
machinery currently private in `api/auth.zig`.

```zig
.collections = .{
    .members = .{ .type = .auth, .auth = .{
        .methods = .{ .magic_link = .{ .ttl = .{ .minutes = 15 } } },
    } },
    .staff = .{ .type = .auth, .auth = .{
        .methods = .{ .password = .{}, .webauthn = .{} },
        .oauth2  = .{ .providers = .{ /* google, ... */ } },
    } },
},
```

`.auth.methods` is a struct literal keyed by built-in method name; each value is that
method's config (TTLs, code length, etc.). OAuth2 keeps its existing
`.auth.oauth2.providers` shape (it is just the OAuth2 method's config), so no breaking
change to current configs. An auth collection with no `.methods` defaults to
`password` for backward compatibility.

### Tier 2 — custom `AuthMethod` plugin (the bespoke)

For WebAuthn, corporate SSO, API keys, or anything the built-ins don't cover, a consumer
provides a comptime `AuthMethod` plugin in the **same Storage/Mailer plugin style**. The
crucial discipline: **the built-in methods implement this exact same contract** — they
are just methods ZigBase happens to ship. No privileged private path.

```zig
// App-level registration of custom method TYPES (comptime, like .storage / .mailer):
.auth_methods = .{ WebAuthnMethod, CorpSsoMethod },

// then referenced by slug in a collection's .methods:
.staff = .{ .type = .auth, .auth = .{
    .methods = .{ .password = .{}, .webauthn = .{} }, // "webauthn" resolves to WebAuthnMethod.slug
} },
```

#### The contract

```zig
pub const AuthMethod = struct {
    /// URL slug → /api/collections/:col/auth/<slug>/initiate | /complete
    slug: []const u8,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Phase 1. May send mail/SMS, store server-side challenge state, and/or
        /// return data the client needs next (WebAuthn challenge JSON, an OAuth2
        /// redirect URL). Returns a status + optional JSON body for the client.
        initiate: *const fn (ctx: *anyopaque, ac: *AuthCtx) anyerror!InitiateResult,

        /// Phase 2. Verify the proof in the request, then resolve to a record in the
        /// auth collection. The framework mints the session + fires onAuth from the
        /// returned record id — the method NEVER mints a session itself.
        complete: *const fn (ctx: *anyopaque, ac: *AuthCtx) anyerror!Resolution,
    };

    // Plugin contract (mirrors storage/mailer), validated at comptime:
    //   pub fn create(gpa, io, cfg) !Self
    //   pub fn method(self: *Self) AuthMethod   // returns the vtable view
    //   pub fn deinit(self: *Self) void
};

/// What the framework hands a method on each phase: the resolved auth collection,
/// the request, a pooled DB connection, and the BLESSED helpers so a method composes
/// from safe building blocks instead of reinventing them.
pub const AuthCtx = struct {
    app: *Runtime,
    ctx: *http.RequestCtx,        // body / query / cookies / remote_ip
    collection: schema.Collection, // the :col auth collection, already validated .type == .auth
    conn: *db.Db,                  // pooled connection (writer for complete, reader for initiate)

    // Blessed helpers (today private in api/auth.zig), exposed only through AuthCtx:
    pub fn rateLimit(ac: *AuthCtx, scope: []const u8, ident: []const u8) !?http.Response;
    pub fn mintToken(ac: *AuthCtx, record_id: []const u8, tt: TokenType, ttl: i64) ![]const u8;
    pub fn consumeToken(ac: *AuthCtx, claims: Claims) !void;          // single-use ledger
    pub fn verifyTyped(ac: *AuthCtx, token: []const u8, want: TokenType) !?Claims;
    pub fn deliverMail(ac: *AuthCtx, to: []const u8, subject: []const u8, body: []const u8) !void;
    pub fn findByIdentity(ac: *AuthCtx, identity: []const u8) !?[]const u8;
    pub fn challengeStore(ac: *AuthCtx) ChallengeStore; // §8, for multi-roundtrip methods
};

pub const InitiateResult = struct { status: u16 = 200, body: ?[]const u8 = null };

/// Phase-2 outcome. The framework turns `record_id` into a session.
pub const Resolution = union(enum) {
    record: []const u8,                 // resolved record id → framework issues session + onAuth
    create_and_link: NewRecord,         // method vouches for a new identity (policy-gated, §7)
    fail: struct { status: u16, message: []const u8 },
};
```

#### Route auto-mounting

For every auth collection that enables a method (built-in or custom), the framework
registers two routes under the collection namespace:

```
POST /api/collections/:col/auth/<slug>/initiate
POST /api/collections/:col/auth/<slug>/complete
```

The framework validates `:col` is a real auth collection that has `<slug>` enabled (else
404), runs the method's `initiate` / `complete`, and on a `complete` that returns a record
id, calls the core `issueSession` (mint + `onAuth`). A method that only needs one phase
(e.g. a pure "accept this externally-minted JWT") may leave `initiate` a no-op.

Built-in legacy paths (`auth-with-password`, `auth-with-oauth2`, `oauth2-init`) are kept
as aliases for backward compatibility; new methods use the `auth/<slug>/...` shape.

### Tier 3 — hardened escape hatch (the truly exotic)

For a flow that doesn't even fit the two-phase lifecycle, a custom route can mint a
session directly — but through the **corrected** primitive that emits `onAuth`:

```zig
fn myExoticLogin(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    // ... you verified something the framework can't model ...
    var w = ev.writer(); defer w.deinit();
    const issued = try zigbase.auth.issueSession(ev.ctx, w.conn, "members", record_id); // routes through issue() + emitAuth; uses w.conn to avoid double-acquiring the writer
    return .{ .status = 200, .body = "...", .cookies = &issued.cookies };
}
```

This is PR #46's `issueSession`, repositioned as the sanctioned low-level door and fixed
to fire `onAuth`. It also enables **vanity mount paths** outside `/api/collections/...`
(e.g. a route at `/login/magic`) when a consumer wants them.

## 5. How the tiers relate

```
Tier 1 (config)     enable a built-in method per collection ─┐
Tier 2 (plugin)     implement AuthMethod (built-ins do too) ─┤→ complete() returns a record id
Tier 3 (escape)     custom route calls ev.issueSession() ────┘
                                                              │
                                                  ┌───────────▼───────────┐
                                                  │  issueSession()        │  ← THE ONE SEAM
                                                  │   = issue() + emitAuth()│
                                                  └────────────────────────┘
```

Easy path and powerful path are the *same machinery at different altitudes* — the
property that makes the framework coherent rather than a pile of escape hatches.

## 6. Multi-method, multi-collection mounting (hard requirement)

This is already the *natural* shape, because ZigBase namespaces every auth endpoint by
the `:col` auth collection (`src/server.zig:37-46`). The **auth collection is the
user/resource type.** "Different users authenticate different ways" = "different auth
collections enable different method sets," and they are at distinct paths by construction.

```zig
.members = .{ .type = .auth, .auth = .{ .methods = .{ .magic_link = .{ .ttl = .{ .minutes = 15 } } } } },
.staff   = .{ .type = .auth, .auth = .{ .methods = .{ .password = .{}, .webauthn = .{} } } },
```

yields, with no route code:

```
/api/collections/members/auth/magic-link/initiate   ← members' only door
/api/collections/members/auth/magic-link/complete
/api/collections/staff/auth-with-password            ← staff's doors
/api/collections/staff/auth/webauthn/initiate
/api/collections/staff/auth/webauthn/complete
```

Each `AuthMethod` instance is **collection-scoped**, so the same method type can run twice
with different config (magic-link at 15-min TTL for `members`, 5-min for an `admins`
collection). No method instance is shared across collections.

## 7. Record creation / linking policy

`complete` may resolve to an existing record (`.record`) or vouch for a new identity
(`.create_and_link`). Auto-provisioning a user is a policy decision, so it is gated by
collection config (mirroring how OAuth2 decides whether to create on first login):

```zig
.auth = .{ .methods = .{ .magic_link = .{ .auto_create = false } } }
```

When `auto_create = false`, a `.create_and_link` from an unknown identity fails closed.
The framework owns the actual insert (hashing N/A for passwordless, `tokenKey` generation,
`verified` defaulting) so a method never writes auth system fields directly.

## 8. WebAuthn as the stress test

WebAuthn is the method that most stresses the contract, for two reasons; the design
accommodates both without contorting the common case:

1. **Multi-roundtrip challenge state.** `initiate` must mint a random challenge nonce,
   return it to the client, and remember it for `complete` to verify the signed assertion
   against. We add a generic, GC'd **`ChallengeStore`** (a `_authChallenges` table keyed by
   an opaque id, TTL'd like `_cursorStates` / `_consumedTokens`) exposed via
   `AuthCtx.challengeStore()`. Magic-link/OTP don't need it (their challenge *is* the
   single-use token); WebAuthn and any future challenge-response method do.
2. **Per-credential storage.** A user has N passkeys, each a (credentialId, publicKey,
   signCount). This is ordinary collection data the plugin owns — it lives in a
   consumer-defined relation collection, not in the auth system fields. The contract does
   not need to know about it; the plugin reads/writes it via `AuthCtx.conn`.

So WebAuthn = `initiate` stores a challenge + returns options JSON; `complete` verifies the
assertion against the stored challenge and the credential's public key, then returns the
owning record id. No new core concept beyond `ChallengeStore`.

## 9. OAuth2 refactor onto the contract

OAuth2 becomes the **reference built-in `AuthMethod`**, proving the contract against a
method that already exists in production:

- `initiate` ← today's `oauth2Init` (build authorize URL + store `state`; `state` moves
  into `ChallengeStore`).
- `complete` ← today's `authWithOAuth2` (exchange code → userinfo → `extractIdentity` →
  resolve/link record), returning a `Resolution` instead of minting the session itself.
- `providers` config stays exactly where it is (`.auth.oauth2.providers`); it is just this
  method's config. Adding twitter/linkedin = adding presets to `oauth/providers.zig`,
  unchanged by this design.
- Legacy paths kept as aliases. The `emitAuth(method = .oauth2)` call moves into the core
  seam, so it fires identically whether reached via the legacy path or the new one.

This refactor is the proof obligation for the whole design: if OAuth2 doesn't fit the
contract cleanly, the contract is wrong.

## 10. `onAuth` method tagging

`AuthMethod` (events.zig) currently has `method: enum { password, oauth2 }`. Generalize to
carry the method slug so handlers can distinguish magic-link from password from a custom
SSO:

```zig
pub const AuthMethod = enum_or_tagged { password, oauth2, magic_link, otp, webauthn, custom: []const u8 };
```

Every login — every tier — fires `onAuth` with the correct tag, because it is emitted in
the one seam. This is the concrete fix for PR #46's observability gap.

## 11. Security considerations

- **One mint, one audit.** No code path mints a session except `issueSession`, and it
  always emits `onAuth`. The PR #46 bypass becomes structurally impossible.
- **Replay.** Single-use tokens keep flowing through `_consumedTokens`; `ChallengeStore`
  entries are single-use + TTL'd. Methods get these via `AuthCtx`, never hand-rolled.
- **Rate-limiting.** `AuthCtx.rateLimit` is the same limiter the built-in endpoints use;
  the framework can also apply a default limit to every `initiate`/`complete` so a
  careless plugin is still protected.
- **Account enumeration.** `initiate` should return a uniform response whether or not the
  identity exists (as `requestVerification` / `requestPasswordReset` already do). Document
  this as a contract expectation and provide a helper.
- **`create_and_link` is policy-gated** (§7) and fails closed by default.
- **The escape hatch is the sharp tool.** `ev.issueSession` mints a session for any record
  id; it is documented as "you own the verification; the framework owns issuance." It is
  strictly better than PR #46 (emits `onAuth`) but still the most dangerous door — kept
  deliberately small and explicit.

## 12. Backward compatibility & migration

- Existing `.auth` collections with no `.methods` default to `password` — current configs
  compile and behave unchanged.
- Legacy endpoints (`auth-with-password`, `auth-with-oauth2`, `oauth2-init`,
  `request-verification`, etc.) remain as aliases.
- `.options.auth.oauth2.providers` is unchanged.
- New surface (`.auth.methods`, `.auth_methods`, `ev.issueSession`, `AuthMethod`,
  `AuthCtx`, `ChallengeStore`) is purely additive.

## 13. Disposition of PR #46

Don't merge as-is. Its `issueSession` is the seed of Tier 3 but must (a) route through
`emitAuth` and (b) be exposed as `ev.issueSession` on `RouteEvent` (and a top-level
`zigbase.auth.issueSession`) rather than a bare re-export that bypasses the framework's
guarantees. Credit the PR; supersede its mechanism.

## 14. Resolved decisions & remaining open questions

**Resolved (owner approved 2026-06-19):**

- **Typed-route / `rpc` surface — YES, include auth endpoints.** The `auth/<slug>/...`
  `initiate` / `complete` endpoints **must appear in the generated TypeScript client**.
  Each built-in and custom method declares typed `Initiate`/`Complete` input/output structs
  (the bounded Zig→TS subset, §3b of framework.md) so the comptime generator can emit
  `zb.auth.<method>.initiate(...)` / `.complete(...)` methods named by collection + slug.
  A method whose phase carries no structured payload uses `void`. This is the reason
  `InitiateResult` / the `complete` proof are typed rather than raw JSON.
- **Default rate-limit on plugin endpoints — YES, on by default, two-layer.** Every
  `initiate` / `complete` is rate-limited by default. Two override layers:
  1. **Simple adjustable rate** — per-method config knob, e.g.
     `.magic_link = .{ .rate_limit = .{ .max = 5, .window = .{ .minutes = 1 } } }`, with a
     safe framework default when omitted. Setting it to `.off` opts out (logged, like
     `@public` rules).
  2. **Full override function** — an optional consumer hook
     `.rate_limit_fn = fn (ac: *AuthCtx, scope: []const u8, ident: []const u8) bool` that
     replaces the built-in limiter entirely for that method (return `true` = allow). When
     present it wins over the simple rate. Exposed on `AuthCtx` so a method body can also
     invoke it explicitly if it needs a non-endpoint-granularity decision.

  The framework applies the limiter *around* `initiate`/`complete` (before the method body
  runs), so a careless plugin is protected even if it never calls `AuthCtx.rateLimit`
  itself.

**Remaining open (resolve during planning, not blocking):**

- **`.methods` config typing.** Struct-literal-keyed-by-name (compile error on unknown
  method) vs. a tuple of method specs. Leaning struct-literal for the same compile-time
  validation the rest of `App(.{...})` gives.
- **Custom method config passing.** How a Tier-2 plugin receives its per-collection config
  (the `webauthn = .{ ... }` value) — via `create(cfg)` vs. a per-collection init.
- **Step-up / MFA.** Out of scope here, but confirm the contract doesn't preclude a later
  "complete returns `needs_second_factor` instead of a record."

## 15. Implementation order (for the plan)

1. Core seam: funnel all session minting through `issueSession` + `emitAuth`; generalize
   the `onAuth` method tag. (No behavior change; pure refactor + the PR #46 fix.)
2. `AuthMethod` contract + comptime plugin validation + route auto-mounting, with
   **password** re-expressed as the first built-in `AuthMethod` (proves the contract on the
   simplest method).
3. `magic_link` + `otp` built-ins on the blessed `AuthCtx` helpers (delivers the
   motivating use case).
4. OAuth2 refactored onto the contract (proves it on the hardest *existing* method;
   `ChallengeStore` lands here).
5. Tier 3 `ev.issueSession` + docs (supersedes PR #46).
6. WebAuthn as a separate, later effort against the now-proven contract.

Docs to update on the way (CLAUDE.md convention): `docs/framework.md` §6, `docs/api.md`,
the `site/src/content/` mirror, and an `examples/` instance (a magic-link collection is the
natural addition to the example ladder).
