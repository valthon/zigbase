### Features

- Session management verbs on `ctx.auth()` (#99): `revokeAllSessions()` ("log out
  everywhere"), `refresh()` (sliding re-mint, other sessions stay valid), and `rotate()`
  (bump + re-mint, keep this session and kill every other). Free-function forms
  `zigbase.auth.revokeAllSessions/refresh/rotate(ctx)`. Sessions remain stateless JWTs but
  are now **revocable** via a per-auth-record token epoch (the default
  `App(.{ .session_store = .epoch })` model) — no extra query on the verify hot path (the
  epoch is read alongside the signing key). Existing valid tokens keep working: tokens
  minted before the epoch existed and freshly created records both read as epoch 0.
- New comptime config key `.session_store` (`.epoch` default, or `.table`). The `.table`
  variant (a server-side `_sessions` store for per-device `listActiveSessions()` /
  `revoke(sessionId)`) is **designed but not yet implemented**: the config seam and the
  `_sessions` table ship now, and the two per-device verbs return
  `error.SessionTableNotImplemented` (or `error.SessionStoreNotEnabled` in `.epoch` mode).

### Security

- Outstanding session tokens can now be invalidated server-side before they expire. A
  bumped token epoch causes verification to reject every prior `.auth` token for that
  principal (fail closed — the epoch is trusted only after signature verification). Use it
  on password change, suspected compromise, or an explicit "sign out of all devices".
