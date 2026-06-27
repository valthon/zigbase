# Theme D — Auth Lifecycle & Session Management

**Status:** Design approved 2026-06-27. Implemented in the same branch.

## Background

Themes A–D regroup issues #80–#88 (agents porting a real app onto ZigBase). Theme A
(the unified `*Ctx` capability layer) is merged: handlers/hooks/jobs receive `*Ctx`,
before-record-hooks run *inside* the write transaction, and there is a
`ctx.issueSession(collection, record_id)` shim plus a `zigbase.auth` helper namespace
(`src/auth_helpers.zig`). Theme A explicitly deferred the `ctx.auth` session verbs
(`clearSession`, refresh/rotate/list/revoke) and the writable auth hook to **Theme D**.

This spec covers Theme D: the **auth lifecycle hook** (#80) and the **session-management
surface** of which `clearSession` (#86) is the first verb. It ships those two solidly
and frames the broader uniform lifecycle (the rest is deferred, designed here).

## Goals

- A **post-verify, writable, abortable** auth hook that runs *under the request* with a
  DB connection bound to the writer, **inside a transaction** around session issuance, so
  a hook's side-writes commit atomically with the login and an aborting hook fails closed
  (no session, side-writes rolled back). Motivating use case: claim anonymous records on
  first login (`UPDATE posts SET author=:id WHERE guest_email=:email AND author IS NULL`).
- A **`clearSession` helper** mirroring `issueSession`: one line in a logout handler,
  returning the cleared `zb_auth`/`zb_csrf` cookies with the framework's *own* cookie
  policy (secure/http_only/same_site), factored so the built-in logout and the helper can
  never drift.
- Frame a uniform auth lifecycle (before/after hooks across register/login/consume/
  logout/refresh/password-change) and a `ctx.auth` session surface; ship the first
  concrete pieces, design the rest as deferred.

## Non-goals (this cycle)

- `ctx.auth` refresh/rotate/list-active/revoke verbs (designed, deferred).
- Firing the lifecycle hook on the legacy `/auth-with-password` and `/auth-refresh`
  endpoints, or on register/logout/password-change phases (designed, deferred — see
  "Deferred" below). The hook fires on the **unified method endpoints** and **magic-link
  consume**, which is the documented, recommended auth surface.
- An after-issuance writable hook. The existing notify-only `onAuth` remains as the
  post-issuance notification (the future `afterAuthSuccess`); Theme D adds only the
  *before*-issuance writable seam.

## Current state (grounding)

- **`onAuth`** (`events.zig` `AuthEvent`/`AuthHandler`) is notify-only: `fn(ev) void`, no
  DB write, fires *after* the session is minted (inside `issueSessionExt` →`emitAuth`).
  It cannot abort and cannot transactionally write.
- **Session issuance** (`api/auth.zig` `issue`/`issueSession`/`issueSessionExt`) signs a
  stateless `.auth` JWT and returns 2 cookies; it performs no durable DB write itself.
  Thus "atomic with the session" means: the hook's writes + (for magic-link) the
  single-use **token consumption** commit together, and roll back together on abort.
- **Consume endpoints:**
  - `api/auth_methods.zig` `complete` (`POST /api/collections/:col/auth/:method/complete`)
    — drives password/otp/webauthn/oauth2/custom. The method's `complete` vtable runs and
    releases its own connection; dispatch then acquires the writer and mints the session.
  - `api/magic_link_consume.zig` `consume` (`GET …/auth/magic_link/consume`) — verifies +
    consumes the link token under the writer, then mints the session.
- **Cookie policy** lives twice: `api/auth.zig` `issue()` builds the set-cookies; `authLogout()`
  builds the cleared cookies. Both hardcode names/attributes — exactly the drift #86 wants
  factored.
- **Cookie attributes:** `zb_auth` (http_only=true), `zb_csrf` (http_only=false), both
  `secure=app.cookie_secure`, `same_site=.strict`, `path=/`.

## Design

### 1. The `beforeAuthSuccess` hook (#80)

A new dispatch slot, config key, event, and handler type:

```zig
// events.zig
pub const AuthSuccessEvent = struct {
    app: *App,
    collection: []const u8,        // auth collection name
    record_id: []const u8,         // the authenticated record's id
    method: AuthMethod,            // .password/.magic_link/.otp/.webauthn/.oauth2/.custom
    record: std.json.Value,        // the authenticated record (always provided)
};
pub const AuthSuccessHandler = *const fn (ctx: *Ctx, ev: *AuthSuccessEvent) anyerror!void;
// Dispatch gains: before_auth_success: ?AuthSuccessHandler = null
```

Config: `App(.{ .beforeAuthSuccess = myHook })` (added to the allowed-keys guard).

**Semantics (committed):**

- **When:** after credentials/token are verified (and, for magic-link, the link token is
  *consumed*), the verification gate has passed, and the record is fetched — but **before**
  the session JWT is issued. Pairs with the existing notify-only `onAuth`, which still
  fires *after* issuance.
- **Where:** the unified `complete` endpoint (password/otp/webauthn/oauth2/custom) and the
  magic-link `consume` GET. One shared helper (`api/auth.zig:fireBeforeAuthSuccess`) is
  called from both sites, so all methods behave identically.
- **Writable + bound:** the hook receives a `*Ctx` whose `bound_conn` is the
  in-transaction writer. `ctx.records().create/update/delete` and `ctx.records().get`
  all reuse that connection and therefore participate in the login transaction. The hook's
  `ctx.user()` reflects the just-authenticated identity (`rctx.auth = record`,
  `rctx.collection = collection`). `ctx.tx` is rejected (`error.NestedTransaction`) — the
  hook is already inside a transaction; use `ctx.records` directly.
- **Transactional + atomic:** the consume path is wrapped in `BEGIN IMMEDIATE … COMMIT`.
  Hook writes + (magic-link) token consumption + session issuance commit together.
- **Abortable, fail-closed:** the hook returning *any* error → `ROLLBACK` (token
  un-consumed, side-writes discarded) and **no session is issued**. The response is mapped
  via the same `Ctx` error model used elsewhere: `ctx.fail(status, msg)` renders the
  chosen status; `error.Forbidden`→403, `error.Unauthorized`→401; any other error→500
  (details logged, never leaked). Recommended veto: `ctx.fail(403, "…")` or
  `return error.Forbidden`.

**Why `beforeAuthSuccess` and not extend `onAuth`:** `onAuth` is deliberately notify-only
(void, post-issue) and several flows depend on it firing exactly once after a session
exists. Overloading it with abort/transaction semantics would be a silent breaking change.
A distinct *before* slot gives the clean lifecycle pair (`beforeAuthSuccess` writable+
abortable; `onAuth` ≈ `afterAuthSuccess` notify) and keeps `onAuth`'s contract intact.

**Atomicity boundary (documented limitation):** for methods that consume a single-use
artifact *inside their own* `complete` vtable (otp code, webauthn challenge), that
consumption commits on the method's own connection *before* dispatch issues the session,
so an aborting `beforeAuthSuccess` cannot un-consume it. The rollback always covers the
hook's own side-writes (the #80 use case) and, for magic-link, the link-token consumption
(which happens on the same writer inside the login transaction). This is acceptable and
noted; tightening per-method artifact consumption into the login transaction is a future
refinement.

### 2. `clearSession` + factored cookie policy (#86)

Factor the session-cookie policy into one module both the framework and consumers use:

```zig
// session.zig (new)
pub const auth_cookie = "zb_auth";
pub const csrf_cookie = "zb_csrf";
pub fn sessionCookies(secure: bool, token: []const u8, csrf: []const u8, max_age_s: i32) [2]http.Cookie;
pub fn clearedCookies(secure: bool) [2]http.Cookie; // = sessionCookies(secure, "", "", -1)
```

- `api/auth.zig:issue()` now returns `session.sessionCookies(app.cookie_secure, token, csrf, max_age)`.
- `api/auth.zig:authLogout()` now returns `session.clearedCookies(app.cookie_secure)`.
- **Consumer surface:**
  - `ctx.auth().clearSession() ![]const http.Cookie` — arena-owned cookies that slot
    directly into `Response.cookies`.
  - `zigbase.auth.clearSession(ctx: *Ctx) ![]const http.Cookie` — delegates to the above.

A logout route handler is one line:

```zig
fn logout(ctx: *zigbase.Ctx) !zigbase.http.Response {
    return .{ .status = 204, .body = "", .cookies = try ctx.auth().clearSession() };
}
```

Because both the built-in `authLogout` and `clearSession` go through
`session.clearedCookies`, the cleared cookies are byte-for-byte identical — no drift.

### 3. Lifecycle/session framing (designed, mostly deferred)

The uniform target, plugged in incrementally:

| Phase | Hook (writable/abortable/txn) | Status |
|-------|-------------------------------|--------|
| login/consume | `beforeAuthSuccess` | **shipped (this cycle)** |
| login (notify, post-issue) | `onAuth` (≈ `afterAuthSuccess`) | exists |
| register | `beforeRegister` / `afterRegister` | deferred |
| logout | `beforeLogout` / `afterLogout` | deferred |
| refresh | `beforeRefresh` / `afterRefresh` | deferred |
| password-change | `beforePasswordChange` / `afterPasswordChange` | deferred |

`ctx.auth` session surface (first verb shipped):

| Verb | Status |
|------|--------|
| `ctx.auth().clearSession()` | **shipped** |
| `ctx.auth().refresh()` / `rotate()` | deferred (mint a new session for the current principal) |
| `ctx.auth().listActive()` / `revoke(id)` | deferred (needs a server-side session table — today's `.auth` JWT is stateless; revocation would require a session/jti store) |

When built, the deferred hooks reuse the `beforeAuthSuccess` machinery: a bound,
in-transaction `*Ctx`, fail-closed abort, and the same `Ctx` error mapping. The session
verbs land under the `ctx.auth()` namespace introduced here.

## Testing

- **Unit (Zig):**
  - `beforeAuthSuccess` fires on a built-in `complete` (password) with the right
    method tag/record id, and its `ctx.records()` write is visible after the login (commit).
  - An aborting `beforeAuthSuccess` blocks the session (mapped status, no cookies) **and**
    its side-write is rolled back (atomicity proof) — the core #80 guarantee.
  - magic-link `consume`: an aborting hook leaves the link **token un-consumed** (rollback)
    so a retry still works; a passing hook consumes it (replay still rejected).
  - `session.sessionCookies`/`clearedCookies` shapes; `ctx.auth().clearSession()` returns
    arena cookies matching `authLogout`'s policy (same names/secure/http_only/same_site).
- **Browser/pytest (`tests/admin/`):** the admin login + logout + access-rule paths must
  still pass (the real regression net for auth). `authLogout` now routes through the shared
  policy; the hook is null in the admin app (no-op).

## Docs & changelog

- `docs/framework.md` (+ `site/src/content/docs/framework.md` mirror): document
  `beforeAuthSuccess` in the hooks table and an auth-lifecycle subsection; document
  `clearSession` / `ctx.auth()` in the auth section; add a logout-handler one-liner.
- `examples/golfsim`: add a `beforeAuthSuccess` hook (claim-on-first-login) + a logout
  route using `ctx.auth().clearSession()` to demonstrate both, keeping the example building.
- `changelog.d/theme-d-auth-lifecycle.md`: `### Features` (the hook + clearSession +
  ctx.auth namespace).

## Committed defaults (decision record)

- New hook is named **`beforeAuthSuccess`** (distinct from notify-only `onAuth`).
- It fires on the unified `complete` endpoint + magic-link `consume`; NOT on legacy
  `/auth-with-password` or `/auth-refresh` (deferred).
- The consume path runs in `BEGIN IMMEDIATE … COMMIT`; hook abort → `ROLLBACK`, fail closed.
- Hook abort response uses the `Ctx` error model (`ctx.fail`/known errors/else 500).
- Session-cookie policy is factored into `session.zig`; `issue`, `authLogout`, and
  `clearSession` all use it.
- `clearSession` returns arena-owned `[]const http.Cookie` (slots into `Response.cookies`).
