# SP3 Theme F — Auth round 2 (design spec)

Baseline: `origin/main @ 1bd02c4`. Grounded in `docs/framework.md` (auth lifecycle hooks +
"Deferred (designed, not wired)" ~line 1421, §6 `ctx.auth()` session verbs ~line 1831,
OAuth2 providers ~line 1607), `src/api/auth.zig`, `src/api/auth_methods.zig`,
`src/api/records.zig`, `src/auth.zig` (`applyUpdate`), `src/oauth/providers.zig`,
`src/api/oauth.zig` (`resolveProvider`), `docs/ideas.md` A6/A7/A8, `KNOWN_LIMITATIONS.md`.

## Goal

Close the two "designed, not wired" auth gaps (self-service password change via
`PATCH /records`; `beforeAuthSuccess` on the legacy `/auth-with-password` and
`/auth-refresh` routes), and ship the two right-sized bigger items: a **generic
OIDC-discovery OAuth provider** and a **per-device session REST + SDK surface** for
`.session_store = .table`. Defer global RBAC with a written rationale.

## Non-goals

- **Global RBAC / role ladders (A7)** — deferred; see F5 for the rationale.
- Flipping the `session_store` default from `.epoch` to `.table` — needs perf data on the
  documented one-extra-read-per-request cost; the default stays `.epoch`.
- Admin SPA "sessions" tab — REST+SDK only this round; SPA UX is a follow-up.
- New named OAuth presets (Apple/GitLab/Twitch/Facebook). Generic OIDC covers the
  compliant ones; Apple's form_post + client-secret-as-JWT is its own future item.
- `id_token` signature validation / JWKS. The flow keeps verifying identity via the
  `userinfo` endpoint over TLS (current model, documented).
- Custom claim-mapping overrides for generic providers (mapping stays the fixed OIDC
  standard set; revisit only on demand).
- MFA (A3), API keys (A5) — out of theme.

## Default-build impact

**All four in-scope items extend the default auth stack — nothing here is behind a build flag,
and nothing here introduces one.** `src/api/auth.zig`, `src/api/records.zig`, `src/oauth/`, and
`ctx.auth()` are already compiled into every binary; this theme adds routes, hook call sites, and
one new provider-resolution path to code that already ships unconditionally.

- **F1 (password change via PATCH) / F2 (`beforeAuthSuccess` on legacy routes):** no new routes,
  no new tables — existing endpoints gain a request-time branch (`oldPassword` check,
  `hasAuthLifecycle`-gated writer acquisition) and a rate-limit bucket (`"pwchange"`, reusing the
  existing global limiter). Code-size delta is a few new functions, comparable to any other
  request-handling branch already in these files.
- **F3 (per-device session REST + SDK):** three new routes in `.table` mode
  (`GET/DELETE …/auth/sessions[/:sid]`), 404 in `.epoch` mode — no new tables (`_sessions` already
  exists from #99), no new authz predicate (ownership is a plain `WHERE` clause, not a rule). The
  routes are live in every binary but inert (404) unless the app opts into `.session_store =
  .table`, which is itself an existing, already-default-compiled config surface.
- **F4 (generic OIDC discovery):** one new comptime provider field
  (`discoveryURL: ?[]const u8`) and a startup-time HTTPS fetch when a consumer configures it.
  **Quantified:** the fetch reuses the *existing* injectable OAuth HTTP transport
  (`src/oauth/client.zig`, already wrapping `std.http.Client`/`std.crypto.tls` for every OAuth
  token/userinfo call today) — this is zero new networking code, zero new TLS stack, just one more
  call site through a transport already linked and already exercised by every OAuth-configured
  app. The fetch runs **once, at startup**, only for apps that configure a `discoveryURL`
  provider; apps with zero OAuth providers, or only named-preset providers, never invoke it. No
  new dependency, no new build option.

**Why comptime-gating would be the wrong call here:** none of these four items are an *alternative*
to something else in the codebase (the way Postgres is an alternative to SQLite, or a hypothetical
alternative HTTP library would be an alternative to facil.io) — they're incremental surface on the
one auth system every ZigBase app already links. Splitting auth into "auth" and "auth-plus-
sessions-and-oidc" behind a flag would fragment a subsystem with no natural seam, mirroring the
email-round-2 default-build call: extend the thing consumers already opted into, don't fork it.

## Facil.io-first check

**None of these items replace a facil.io capability.** Password-change, legacy-route hooks, and
session-REST all ride the existing router/request-handling path that already sits on facil.io/zap
— no new transport, no new protocol handling. OIDC discovery is a client-side outbound HTTPS fetch
using `std.http.Client`/`std.crypto.tls` (Zig std, already the transport for every other OAuth
call in this codebase) — it does not touch facil.io's server-side HTTP handling at all, so there
is nothing facil.io-shaped for it to replace.

## SDK / package surface check

**No new npm/package implications beyond the existing `@zigbase/client` surface already specced.**
`changePassword`, `listSessions`, `revokeSession`, and `revokeAllSessions` are new typed methods on
the auth collection service within the existing `@zigbase/client` package (§F1 SDK, §F3 SDK) — no
new package, no new publish target, no new OIDC-trusted-publisher setup. The generic OIDC provider
(F4) is server-side comptime config (`discoveryURL` on `.providers`) with no client-side surface at
all — the SDK's OAuth flow (redirect + callback) is provider-agnostic already and needs no change.

---

## F1. Self-service password change via `PATCH /records`

### Today (the gap)

`PATCH /api/collections/:col/records/:id` on an auth collection already accepts
`password`: `records.zig` routes it through `auth.applyUpdate`, which hashes it and
**rotates `tokenKey`** (killing every outstanding token, including the caller's own — in
both session modes, since token keys are derived from `tokenKey`). But:
- No current-password verification — anything the `updateRule` admits can silently take
  over the account.
- `beforePasswordChange`/`afterPasswordChange` lifecycle hooks (#98) fire only on
  `confirm-password-reset`, not on the PATCH path.
- No rate limit on the PATCH-with-password path.
- The caller is logged out of their own just-authenticated session (bad UX, and in
  `.table` mode the now-dead `_sessions` rows leak until GC).

### Design

**Route:** unchanged — `PATCH /api/collections/:col/records/:id` with `password` in the
JSON (or multipart) body. New optional body field: `oldPassword`.

**Authorization ladder (all fail closed):**
1. The normal `updateRule` gate runs first, unchanged (blank rule = superuser only).
2. If the body contains `password` and the caller is **not a superuser**, `oldPassword`
   is **required** and must verify (argon2id, cost params untouched) against the
   **target record's** current `passwordHash`. Wrong/missing `oldPassword`, or a target
   with no `passwordHash` (passwordless/OAuth-only account) → `400 "Invalid credentials."`
   — same message/shape as login (non-oracle). Passwordless targets: a non-superuser
   cannot bootstrap a password via PATCH; the verified channel is the password-reset
   email flow (or a superuser). Superusers bypass `oldPassword` (admin reset).
3. Consequence: in practice only the record owner (knows the password) or a superuser can
   change a password, regardless of how permissive `updateRule` is. This is deliberate.

**Timing discipline:** mirror `authWithPassword` — the argon2 verify runs on a **reader**
before the writer lock is acquired (never serialize writes behind argon2), and the
missing-hash / missing-record branches call `crypto.dummyVerify` so response time does not
distinguish them.

**Rate limiting:** new scope `"pwchange"` through the existing `rateLimited(ctx, scope,
ident)` gate (per client IP, falling back to the target identity), checked **before** the
argon2 verify and before any lock. Uses the global env-var limiter budget
(`ZIGBASE_RATE_LIMIT_MAX`/`_WINDOW`), same as `"login"`/`"verify"`/`"reset"`.

**Hook firing (order, inside the update transaction):**
1. record `beforeUpdate` hooks (unchanged, writable, transactional),
2. `beforePasswordChange` lifecycle hook — fires **only when the prepared data contains a
   password change**, with the same contract as on `confirm-password-reset`: in-txn,
   `ev.record` is a read-only pre-change snapshot, abort ⇒ rollback ⇒ password unchanged,
   mapped via the `Ctx` error model.
3. UPDATE commits; post-commit: record `afterUpdate` hooks, then `afterPasswordChange`
   (both notify-only).

**Session semantics on success (per `session_store` mode):** "keep this device, log out
everywhere else" for self-change; "log out everywhere" for admin change — i.e. the
`ctx.auth().rotate()` semantics, achieved by the `tokenKey` rotation `applyUpdate` already
performs:
- `.epoch` (default): the `tokenKey` rotation alone invalidates every outstanding token
  (epoch untouched — no schema change). If the **caller is the target record** (self-service),
  the handler re-issues a session under the new `tokenKey` post-commit and sets fresh
  `zb_auth`/`zb_csrf` cookies on the 200 response. Admin-changing-someone-else: no
  re-issue; all target sessions die.
- `.table`: additionally `deleteSessionsForPrincipal(w, col, rid)` runs **inside** the
  transaction (no dead-row leak), and the self-service re-issue writes one fresh
  `_sessions` row for the caller's new token.

**Response shape:** unchanged — the updated record JSON (secrets stripped as today). The
new session for a self-change travels **only** in the `Set-Cookie` headers; the JSON body
is not forked into an auth-response shape (keeps the typed SDK `update()` return type
stable). Bearer-token (non-cookie) clients re-authenticate; see SDK below.

**SDK (`@zigbase/client`):** new typed helper on the auth collection service:
`collection(col).changePassword(id, oldPassword, newPassword): Promise<void>` — issues the
PATCH; in cookie mode the store is already refreshed by `Set-Cookie`; in token mode it
transparently re-runs `authWithPassword(identity, newPassword)` using the identity from
the auth store and updates the store. `oldPassword` is also accepted as a passthrough
field on plain `update()` (typed optional).

**Docs prose to update:** the `docs/framework.md` deferred paragraph (~1421) — move
password-change-via-PATCH from "designed, not wired" to the lifecycle-hooks table (the
`password-change` row gains a second "Fires on" entry: `PATCH …/records/:id` with a
password). `docs/api.md` records section gains the `oldPassword` contract.

---

## F2. `beforeAuthSuccess` on the legacy routes

### Routes gaining the hook (exhaustive)

| Route | Today | After |
|---|---|---|
| `POST /api/collections/:col/auth-with-password` (`api/auth.zig authWithPassword`) | never fires | fires, tag `.password` |
| `POST /api/collections/:col/auth-refresh` (`api/auth.zig authRefresh`) | never fires | fires, tag `.refresh` (new) |

No other route changes: `auth/:method/complete`, magic-link consume already fire it;
`auth-logout` has its own lifecycle hooks; OAuth callback goes through the unified seam.

### Semantics (identical to `api/auth_methods.zig` complete)

`authWithPassword`: credential verification stays on the **reader** (argon2 outside any
lock, `dummyVerify` timing padding unchanged). Then:
- **Fast path preserved:** if no `beforeAuthSuccess` hook is registered **and**
  `session_store == .epoch`, issuance stays on the reader exactly as today — zero new
  writer acquisition for hook-free apps (same pattern as `authLogout`'s
  `hasAuthLifecycle` gate).
- Hook path: acquire writer → `beginImmediate` → `fireBeforeAuthSuccess` (writable
  `ev.record`, `ctx.records()` writes join the txn, abort ⇒ rollback ⇒ **no session**,
  mapped status) → `issueSessionNoEmit` → commit → `emitAuth` post-commit.

`authRefresh` already runs `beforeRefresh` in a `BEGIN IMMEDIATE` txn; `beforeAuthSuccess`
slots into the **same transaction, after `before_refresh`** (lifecycle first, then the
issuance hook — matching "surrounding phase, then seam" layering). Either abort rolls back
the whole refresh (old session/row intact — fail closed).

### New `events.AuthMethod` tag: `.refresh`

`authRefresh` currently emits `onAuth` with `.password` (a mislabel). Add `.refresh` and
use it for both `beforeAuthSuccess` and `emitAuth` on the refresh path.

### Breaking implications (pre-1.0, fragment under **Breaking**)

1. Consumers with a registered `beforeAuthSuccess` now see it fire on legacy logins —
   including the **admin SPA superuser login** (`src/admin/app.js` posts to
   `_superusers/auth-with-password`). A hook that errors unconditionally will lock
   superusers out of the admin UI; this is consistent fail-closed behavior (the unified
   path already fires for `_superusers`), and recovery is fixing the hook and rebuilding
   (the hook is comptime-compiled — operator == developer). Document loudly.
2. Exhaustive `switch`es on `events.AuthMethod` must add a `.refresh` arm (compile error —
   the good kind).
3. `onAuth` on refresh now reports `.refresh` instead of `.password`.

---

## F3. Per-device session REST + SDK surface (A6 — **in**, right-sized)

`.session_store = .table` and the `ctx.auth()` verbs (`listActiveSessions`, `revoke`,
`revokeAllSessions`, `refresh`, `rotate`) shipped in #99 — but only as Zig-side APIs; a
consumer must write custom routes to expose them. This round adds the canonical REST
surface + SDK. **The `.epoch` default stays** (flip needs measurement, not vibes; the
KNOWN_LIMITATIONS trade-off note remains accurate).

### Wire API

| Route | Auth | Mode | Behavior |
|---|---|---|---|
| `GET /api/collections/:col/auth/sessions` | authed, own principal | `.table` only | `200 {"sessions":[{"id","created","last_seen","user_agent","ip","is_current"}]}` newest-first (mirrors `listSessions`) |
| `DELETE /api/collections/:col/auth/sessions/:sid` | authed | `.table` only | `204`; non-owned or absent `sid` → `404` (indistinguishable — no probing, matches `ctx.auth().revoke`) |
| `DELETE /api/collections/:col/auth/sessions` | authed | **both** modes | "log out everywhere": epoch bump (+ delete all `_sessions` rows in table mode) → `204` with **cleared** cookies (the current session dies too, by design) |

In `.epoch` mode the two per-device routes return `404` (feature not enabled — same
policy as a disabled auth-method slug; non-oracle). The `:col` must match the caller's
authenticated collection (else `401`, matching `authRefresh`). All three acquire the
writer only for the mutating verbs; `GET` uses a reader. No new authz *predicate* is
introduced (ownership is `WHERE collection = ? AND record = ?` on `_sessions`, not a rule)
— so the records.list/realtime chokepoint discipline is not implicated; the pre-delete
snapshot / per-record `viewRule` re-check in the realtime hub is untouched.

### SDK (`@zigbase/client`)

On the auth collection service: `listSessions(): Promise<SessionInfo[]>`,
`revokeSession(id: string): Promise<void>`, `revokeAllSessions(): Promise<void>` (the
last also clears the local auth store). `SessionInfo` is a typed interface. Typegen: no
per-collection variance — these live on the base service (available when the server has
`.table`; a 404 surfaces as the standard `ClientResponseError`).

---

## F4. Generic OIDC-discovery provider (A8 — **in**; highest-leverage single item)

### What the current table hardcodes

`src/oauth/providers.zig` presets exactly **four** providers (google, github, microsoft,
discord), each pinning `authURL`/`tokenURL`/`userinfoURL`/`scopes` and a per-provider
claim `mapping`. A "generic" provider today (`src/api/oauth.zig resolveProvider`) requires
the operator to hand-copy all three endpoint URLs (https-enforced) and gets a **fixed**
OIDC-standard mapping (`sub`/`email`/`email_verified`/`name`/`picture`) with default
scopes. There is no discovery, no issuer validation, no JWKS/`id_token` path.

### Design

New comptime provider field: `discoveryURL: ?[]const u8` (mutually exclusive with
explicit `authURL`/`tokenURL`/`userinfoURL` — both set is a `@compileError`).

```zig
.providers = .{
    .{ .name = "okta",
       .discoveryURL = "https://acme.okta.com/.well-known/openid-configuration",
       .redirectUrls = .{"https://app.acme.com/oauth/callback"} },
},
```

- **Resolution at startup** (first boot, alongside env-secret injection): HTTPS-only
  fetch of the discovery document; extract `authorization_endpoint`, `token_endpoint`,
  `userinfo_endpoint` (all three required, all must be `https://`); verify the
  document's `issuer` is a prefix-match origin of `discoveryURL` (RFC 8414 §3.3-style
  sanity check). Failure = **startup error, loud and fatal** (fail closed — a
  half-configured IdP must not silently disable login). Resolved endpoints are persisted
  into the collection's oauth2 options exactly as literal generic endpoints are today, so
  the existing provisioning caveat applies unchanged (re-resolution requires a
  `.migrations` entry or admin-API PATCH; no per-request fetch, no runtime dependency on
  the IdP's discovery endpoint).
- Scopes default to `openid email profile` (overridable via `.scopes`). Mapping: the
  fixed standard-claims set (same as today's generic path). PKCE: already unconditional.
- Covers Auth0/Okta/Keycloak/Entra-custom-tenant/Zitadel etc. with one config line each.
- **CI/e2e:** discovery is testable without real credentials — unit tests parse a fixture
  discovery document + a stub fetcher; the existing "no live e2e for OAuth" caveat in
  framework.md stays for the full authorization dance.

---

## F5. Global RBAC (A7) — **deferred**, rationale

What already exists covers most of A7's ask:
- The rule compiler resolves **any** auth-record field via `@request.auth.<field>`
  (`docs/api.md` §macros) — so `role = "editor"` on the auth collection plus a rule
  `@request.auth.role = "editor"` works **today with zero framework code**.
- Tenancy ships a real, ordered, per-account role system: `_memberships.role`, the
  configurable ladder (`.tenancy.roles`, default `viewer < editor < admin < owner`),
  `@request.account.role` / `@request.account.ids` macros, and `.abilities`
  `.{ .relationship = .{ .via = …, .min_role = … } }` with comptime ladder validation
  (`docs/tenancy.md`, `docs/abilities.md`).

What a *global* role system would genuinely add: (a) an **ordered** comparison
(`role >= editor`) over a validated global ladder — new rule-language surface (the
grammar has no ladder-ordering operator; adding one is exactly the "rule-language surface
growth" risk A7 itself flags); (b) a server-managed `role` column protected from
self-escalation. (b) is achievable today with a one-line `beforeUpdate` hook or a
field-guarding `updateRule`, and (a) is only worth grammar growth with demonstrated
demand. Equality-composition with the existing macros already works, but the thin surface
that would clear the "composes with existing rule macros" bar is the *ordered* form — and
that is not thin. **Call: defer.** In-round action: add a `docs/recipes.md` entry
("global roles with a select field + `@request.auth.role` + an escalation-guard hook")
that references the tenancy ladder for per-account needs, and note the deferral in
`docs/ideas.md` A7. Revisit post-1.0 if the recipe proves insufficient in the field.

---

## Security analysis

- **Non-oracle responses preserved.** `oldPassword` failures return the login-identical
  `400 "Invalid credentials."`; passwordless targets and missing records take the
  `dummyVerify` timing-padding path. Session revoke of a non-owned/absent id is `404` in
  both cases. Epoch-mode per-device routes 404 like disabled method slugs.
- **Constant-time comparisons.** Password verification is argon2id via
  `crypto.verifyPassword` (inherently non-reversible compare); any raw secret compare
  added (none is currently needed — session ids are looked up by keyed SELECT, not
  compared in code) must use `crypto.timingSafeEql`. Argon2id cost parameters untouched.
- **Fail closed everywhere.** `beforeAuthSuccess`/`beforePasswordChange` aborts roll back
  the whole transaction (no session / password unchanged); OIDC discovery failure aborts
  startup; rule/authz errors keep their existing closed behavior.
- **Locks.** Argon2 never runs under the writer lock (F1 mirrors `authWithPassword`'s
  reader-verify pattern; F2 keeps it). The hook-free epoch login path acquires no writer
  (unchanged perf).
- **Token/session lifecycle.** F1 keeps `applyUpdate`'s rotate-on-password-change (all
  outstanding tokens die); the self-service re-issue happens only post-commit and only
  for the authenticated owner. `_sessions` rows are purged in-txn (no zombie rows).
  Revoke-all bumps the epoch, so it also kills long-lived tokens minted before `.table`
  mode was enabled (the documented `revoke()` gap stays documented).
- **New attack surface reviewed:** `"pwchange"` rate-limit bucket prevents argon2-verify
  DoS and oldPassword brute-forcing; discovery fetch is startup-only, HTTPS-only,
  issuer-checked (no SSRF at request time; the URL is comptime operator input, not user
  input). CSRF: password-change rides the existing PATCH path and its `zb_csrf`
  double-submit protections unchanged.

## Test plan

**Zig unit** (files already in `root.zig`'s test block; new files must be added there):
- `api/records.zig`: PATCH+password happy path (owner w/ correct `oldPassword` → 200,
  hash replaced, tokenKey rotated, cookies re-issued); wrong/missing `oldPassword` → 400
  non-oracle body; superuser bypass; passwordless target → 400; `beforePasswordChange`
  abort → password + tokenKey unchanged (read back); `.table` mode: old rows gone, exactly
  one fresh row for caller; rate-limit 429 before any argon2 work.
- `api/auth.zig`: `beforeAuthSuccess` fires on `authWithPassword` (writable rec, side-write
  committed) and aborts → 4xx + no token + side-write rolled back; hook-free epoch login
  never acquires the writer (assert via test hook/counter); `authRefresh` fires
  `before_refresh` **then** `beforeAuthSuccess` in one txn, abort rolls back both
  (old sid row intact in table mode); `onAuth` tag is `.refresh` on refresh.
- Sessions REST: list/revoke/revoke-all in `.table`; 404s in `.epoch`; cross-collection
  401; non-owner revoke 404; revoke-all clears cookies + bumps epoch (old token stops
  verifying).
- OIDC: discovery-document parse fixtures (good / missing endpoint / http endpoint /
  issuer mismatch → error); comptime mutual-exclusion `@compileError` test (temp
  compile-error harness, reverted via Edit); `resolveProvider` equivalence between a
  discovered and a hand-configured generic provider.

**Browser e2e (`tests/admin/`, run locally before PR — unit green is not enough):**
- `test_password_change.py`: user changes own password via PATCH from the SPA/API →
  old token dead, current cookie session still valid, second browser context logged out;
  wrong oldPassword rejected; superuser reset flow.
- `test_auth_hooks_legacy.py` (fixture app with a registered `beforeAuthSuccess` that
  writes a side row / aborts on a marker identity): legacy login blocked+clean rollback;
  admin SPA superuser login still works with a passing hook.
- `test_sessions.py` (server launched with a `.table`-mode fixture config in
  `conftest.py`): login on two contexts → list shows 2 with `is_current`; revoke other →
  it 401s on next call; revoke-all → both dead, cookies cleared.

**SDK integration (`clients/typescript`):** `changePassword` in cookie + token modes
(store refreshed / re-authed); `listSessions`/`revokeSession`/`revokeAllSessions` against
a table-mode server; typed error on epoch-mode 404; `AuthMethod`-tag surfaces unchanged
for `zb.auth.*` typegen (no generated-surface diff expected — assert snapshot).

## Docs checklist (every item has a `site/src/content/` mirror — update both)

- [ ] `docs/framework.md`: deferred paragraph (~1421) rewritten (both items wired);
      lifecycle table `password-change` row gains the PATCH trigger; `beforeAuthSuccess`
      "Where it fires" prose updated (+ `_superusers` lockout warning); §6 session verbs
      gains the REST table; OAuth2 section gains `discoveryURL`; `events.AuthMethod`
      gains `.refresh`.
- [ ] `docs/api.md`: `oldPassword` contract on auth-record PATCH; sessions endpoints;
      macros section untouched (no new predicates).
- [ ] `docs/typescript-sdk.md`: `changePassword`, session methods, `SessionInfo`.
- [ ] `KNOWN_LIMITATIONS.md`: session bullet updated (REST surface now exists; default
      still `.epoch`); password-change limitation removed.
- [ ] `docs/ideas.md`: A6 → shipped-surface note; A7 → deferral rationale; A8 → generic
      OIDC shipped, named presets remain opportunistic.
- [ ] `docs/recipes.md`: global-roles recipe (F5).
- [ ] Examples: `examples/golfsim` gains a `beforeAuthSuccess` or session-list touchpoint
      only if it stays mid-ladder; blog stays minimal; plugins unchanged.
- [ ] `changelog.d/` fragments: `auth-password-change.md` (Features + Security),
      `before-auth-success-legacy.md` (**Breaking** — hook now fires on legacy routes +
      `.refresh` enum arm; Fixes — onAuth mislabel), `sessions-rest.md` (Features),
      `oidc-discovery.md` (Features). SDK client gets its own
      `clients/typescript/CHANGELOG.md` entry per its release process.
- [ ] `cd site && npm run build` after doc edits.
