# Session management — refresh / rotate / revoke-all / (list-active / per-device revoke)

Issue #99 — Theme D follow-up. Security-sensitive.

## Problem

Sessions are **stateless** HS256 JWTs (`api/auth.zig issue()` signs id/collection/csrf/iat/exp
with a key derived from the record's `tokenKey`; `auth.zig verifyTokenOfTypes` verifies). The
only way to invalidate an outstanding token before its `exp` was to rotate the record's
`tokenKey` (a side effect of a password change). There was no first-class "log out everywhere"
and no per-device session inventory. `ctx.auth().clearSession()` only clears the cookie on the
current browser — it does nothing server-side.

## Decision

- **Variant A (token epoch) is the DEFAULT and is fully implemented.**
- **Variant B (server-side `_sessions` table) is gated behind a comptime config flag
  `App(.{ .session_store = .table })` and is DESIGNED-but-STUBBED** — see "Variant B status".
- Epoch stays the default (`.session_store = .epoch`).

## Variant A — token epoch / version (DEFAULT, shipped)

### Data
- A per-auth-record integer column **`token_epoch`** (default 0). Added as a hidden auth
  *system field* (`schema.authSystemFields()`), so every auth collection table — and
  `_superusers` — carries it. Migration `0010_token_epoch` ALTERs the column onto pre-existing
  auth tables and `_superusers` (`NOT NULL DEFAULT 0`).
- A new JWT claim **`token_epoch: i64 = 0`** (`jwt.Claims`). It is covered by the HMAC
  signature like every other claim.

### Issue
`issue()` reads the record's current `token_epoch` (`COALESCE(token_epoch,0)`) and embeds it in
the minted `.auth` token. One small SELECT per login/issue (issuing is rare vs. verifying).

### Verify (the crux)
`verifyTokenOfTypes` already loads the record's `tokenKey` with a single SELECT. We fold the
epoch into that same SELECT (`SELECT tokenKey, COALESCE(token_epoch,0) …`) — **no extra query
on the hot path**. After `jwt.verify` validates the signature + expiry, we compare the
**verified** claim's `token_epoch` against the DB value. For `.auth` tokens only: mismatch →
reject (return null, fail closed). File tokens (`.file`, ≤120 s, separately minted) are not
epoch-gated.

### Back-compat (must-not-break)
- Tokens issued before this change carry no `token_epoch` claim → JSON parse fills the struct
  default `0`. The signature still validates (verify recomputes the HMAC over the **raw**
  payload bytes, not a re-serialization).
- Fresh rows created by `applyCreate`/`applyProvision` don't set `token_epoch` → column is NULL
  → treated as `0` via `COALESCE`. Migration-added columns default to `0`. Both equal the
  default claim `0`, so **every existing valid token still verifies**.

### Revoke / refresh / rotate (epoch verbs)
- `ctx.auth().revokeAllSessions()` — `UPDATE … SET token_epoch = COALESCE(token_epoch,0)+1`
  for the current principal. Every outstanding token (every device) is invalidated at once.
- `ctx.auth().refresh()` — re-mint a token for the current principal (new `exp`, **same**
  epoch). Other sessions stay valid (sliding refresh).
- `ctx.auth().rotate()` — bump the epoch **then** mint a fresh token carrying the new epoch.
  Invalidates all prior tokens (including the request's own old token) and returns the
  replacement. "Rotate my credentials, keep me logged in here, kill everyone else."
- Free-function form `zigbase.auth.revokeAllSessions(ctx)`.

Per-device revoke is **not** possible in Variant A (the epoch is per-principal, not
per-session) — documented.

## Variant B — server-side `_sessions` table (comptime opt-in; DESIGNED, STUBBED)

`App(.{ .session_store = .table })` selects a model where each issued session is a row in a
`_sessions` system table (migration `0011_sessions`: `id`, `collectionRef`, `recordRef`,
`csrf`, `userAgent`, `created`, `lastSeen`, `revoked`, `expires`). Issue records a row keyed by
a random session id embedded in the JWT (`sid` claim); verify checks the row exists + not
revoked + not expired (one DB read per request — the accepted cost). This enables
`listActiveSessions()` and per-session `revoke(sessionId)` ("log out THIS device") on top of
revoke-all.

### Why STUBBED (the specific blocker)
The current login path (`authWithPassword`) intentionally runs on a **reader** connection so
the expensive argon2 verify never serializes behind the single global writer lock. Variant B's
issue-time `INSERT INTO _sessions` requires the **writer**. Wiring B correctly means
restructuring login's connection model (or adding a second writer hop) on a security-critical
path — exactly the kind of subtle interaction #99 says to stop and flag rather than guess. So:

- The comptime seam ships: `.session_store` config key → `App.session_store: SessionStore`.
- The table ships: migration `0011_sessions` (schema locked in).
- The verbs ship as **stubs**: `listActiveSessions()` / `revoke(sessionId)` return
  `error.SessionTableNotImplemented` (and `error.SessionStoreNotEnabled` when called in
  `.epoch` mode). `revokeAllSessions`/`refresh`/`rotate` work in **both** modes via the epoch
  mechanism (epoch is always active).

Completing B = (1) `sid` claim + issue-time row insert on the writer (login restructure),
(2) per-request session lookup in `verifyTokenOfTypes` gated on `app.session_store == .table`,
(3) implement the two stubbed verbs against `_sessions`, (4) a GC sweep for expired rows.

## Surface summary

| verb | epoch mode (default) | table mode (stub) |
|---|---|---|
| `clearSession()` | clears cookies (existing) | same |
| `revokeAllSessions()` | bump epoch | bump epoch (works) |
| `refresh()` | re-mint, same epoch | same |
| `rotate()` | bump epoch + re-mint | same |
| `listActiveSessions()` | `error.SessionStoreNotEnabled` | `error.SessionTableNotImplemented` |
| `revoke(sessionId)` | `error.SessionStoreNotEnabled` | `error.SessionTableNotImplemented` |

## Tests (Variant A, must-have)
- token rejected after `revokeAllSessions`/epoch bump (revoke-all works);
- `refresh`/`rotate` issue a valid new token that verifies;
- a normal token still verifies; a pre-epoch token (no claim) still verifies (back-compat);
- migration adds `token_epoch` without breaking existing auth;
- browser auth path (login/logout) still passes.

## Security invariants
Fail closed (epoch mismatch / unverifiable → reject). Epoch claim is trusted only **after**
signature verification. CSRF double-submit unchanged. No tokens/secrets logged. `token_epoch`
is a hidden field — never serialized in API responses.
