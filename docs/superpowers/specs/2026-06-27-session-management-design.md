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

## Variant B — server-side `_sessions` table (comptime opt-in; IMPLEMENTED)

`App(.{ .session_store = .table })` selects a model where each issued session is a row in the
`_sessions` system table (migration `0011_sessions`: `id`, `collectionRef`, `recordRef`,
`created`, `lastSeen`, `expires` (nullable), `userAgent`, `ip`; indexed on the owner ref).
`issue()` records a row keyed by a random session id (the record id generator) and embeds it in
the JWT as the optional `sid` claim; verify, **table mode only**, checks the row exists +
unexpired (`expires IS NULL OR expires > now`) — one extra indexed read per authenticated
request, the accepted cost. This enables `listActiveSessions()` and per-session
`revoke(sessionId)` ("log out THIS device") on top of revoke-all.

### Zero epoch-mode overhead (the user's hard constraint)
Everything table-mode is gated on `if (app.session_store == .table)`:
- `issue()` records a row and sets `sid` ONLY in table mode; in `.epoch` mode `sid` stays
  null and `sign()` (with `emit_null_optional_fields = false`) **omits it**, so an epoch token
  is byte-identical to a pre-Variant-B token (no format change).
- The verify session lookup is added AFTER the existing epoch read, behind the same gate — so
  `.epoch` mode issues exactly the queries it did before (the existing single `tokenKey,
  token_epoch` read). A test asserts an epoch-mode login writes **no** `_sessions` row.

### Writer-on-login (the constraint flagged in the prior pass)
`issue()` is the single mint seam, and it does the INSERT using its `conn`. Every login path
except password already holds the **writer** (refresh / unified `complete` (otp/webauthn/
oauth2/magic-link) / `ctx.issueSession` / `ctx.auth()` verbs), so they "just work". Password
login keeps the **reader** for the costly argon2 verify, then — table mode only — acquires the
**writer** AFTER verification, purely for the session-row INSERT, so logins still never
serialize on argon2. INSERT/DELETE are single statements (writer autocommit), or joined to an
existing transaction (refresh) that already carries `errdefer w.rollback()`.

### Fail-closed verify + authz
Verify rejects a table-mode `.auth` token whose `sid` row is absent/expired (same discipline as
the epoch mismatch). `revoke(sessionId)` is owner-or-superuser only; a non-owner gets the SAME
`error.NotFound` as an absent row (no existence oracle on other users' session ids). Logout
deletes the current `sid` row; `revokeAllSessions` clears all the principal's rows (and still
bumps the epoch); `refresh`/`rotate` rotate the current device's row (delete-old-then-insert-new
— wrapped in one `beginImmediate`/`commit` with `errdefer rollback` on the non-bound writer
path, so a failed reissue never silently logs the device out).

### `last_seen` semantics (deliberately NOT per-request)
`created` = true session start, `last_seen` = last token **refresh**. On rotate the original
`created` is carried forward (RETURNING from the delete → UPDATE the new row) while `last_seen`
is stamped `now`. Verify NEVER writes the session table — updating `last_seen` on every
authenticated request would add a single-writer write to the hot path (write amplification /
contention), violating the "one extra indexed READ per request" budget. So `last_seen` advances
on refresh, not on every request.

A token minted under `.epoch` (no `sid`) skips the per-device check if `.table` is later
enabled — switching modes is not retroactive; `revokeAllSessions` (epoch bump) clears them.

Zero epoch-mode overhead is preserved on LOGIN too: `issue()` takes the epoch as a parameter,
folded into the single `tokenKey` SELECT every mint path already runs (`tokenKeyAndEpochFor`) —
it no longer runs a separate `tokenEpochFor` query. So epoch-mode login keeps the same query
count as before #99.

### Deferred (small)
A periodic GC sweep of expired `_sessions` rows (verify already ignores them; they are inert).

## Surface summary

| verb | epoch mode (default) | table mode |
|---|---|---|
| `clearSession()` | clears cookies | same |
| `revokeAllSessions()` | bump epoch | bump epoch + delete the principal's rows |
| `refresh()` | re-mint, same epoch | + rotate this device's row |
| `rotate()` | bump epoch + re-mint | + rotate this device's row |
| `listActiveSessions()` | `error.SessionStoreNotEnabled` | the principal's active sessions (`is_current` set) |
| `revoke(sessionId)` | `error.SessionStoreNotEnabled` | delete one row (owner/superuser only) |
| login / logout | epoch token, cookie clear | + write / delete the session row |

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
