### Features

- Session management verbs on `ctx.auth()` (#99): `revokeAllSessions()` ("log out
  everywhere"), `refresh()` (sliding re-mint, other sessions stay valid), and `rotate()`
  (bump + re-mint, keep this session and kill every other). Free-function forms
  `zigbase.auth.revokeAllSessions/refresh/rotate(ctx)`. Sessions remain stateless JWTs but
  are now **revocable** via a per-auth-record token epoch (the default
  `App(.{ .session_store = .epoch })` model) — **no extra query on either the verify hot path
  or login**: the epoch is folded into the single `tokenKey` SELECT each already performs.
  Existing valid tokens keep working: tokens minted before the epoch existed and freshly
  created records both read as epoch 0.
- New comptime config key `.session_store` (`.epoch` default, or `.table`). The `.table`
  variant adds a server-side `_sessions` store for full **per-device** management:
  `ctx.auth().listActiveSessions()` (with `is_current`) and `ctx.auth().revoke(sessionId)`
  ("log out THIS device", owner-or-superuser authorized). In table mode each token carries an
  opaque `sid` and verification additionally requires a live (unexpired) session row — one
  extra indexed read per authenticated request. `.epoch` stays the default and is unchanged:
  **zero extra DB work and byte-identical tokens** (the `sid` claim is omitted entirely). In
  `.epoch` mode the per-device verbs return `error.SessionStoreNotEnabled`.

### Security

- Outstanding session tokens can now be invalidated server-side before they expire. A
  bumped token epoch causes verification to reject every prior `.auth` token for that
  principal (fail closed — the epoch is trusted only after signature verification). Use it
  on password change, suspected compromise, or an explicit "sign out of all devices".
- With `.session_store = .table`, a revoked or expired per-device session is rejected at
  verify time (fail closed), and per-session `revoke` is authorized to the owning user or a
  superuser (a user cannot revoke another user's session).
