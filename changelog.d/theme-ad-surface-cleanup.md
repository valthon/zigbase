### Internal

- Remove the deferred legacy `app`/`arena` fields from `Req(Input)` in `route_types.zig`
  (Theme A cleanup: examples/blog and examples/golfsim both already read `req.ctx.arena` /
  `req.ctx.app`; the fields were never needed and the migration comment is now moot).
- Update the stale `AuthApi` doc comment in `ctx.zig` that called `refresh`, `rotate`,
  `listActiveSessions`, and `revoke` "deferred" — all four were shipped in PRs #111/#112
  (session management, Variant B); the comment now documents the full surface including
  the `session_store = .table` requirement for per-device verbs.
