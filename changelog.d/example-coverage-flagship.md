### Fixes
- Exported `zigbase.Tx` — the transaction scope passed to a `ctx.tx(T, fn(*Tx) ...)` callback. It was referenced in the docs but never re-exported from the public API, so consumers could not name the callback's parameter type.
- The comptime per-auth-method `.rate_limit = .{ .custom = .{ .max = …, .window_s = … } }` config form now compiles (it previously failed with a `@tagName`-on-a-struct error; only the `.default`/`.off` enum-literal forms worked).
- The TypeScript client generator (`zig build gen-client`) no longer hits the comptime branch-quota limit on apps with larger custom-route tables.

### Internal
- golfsim example: added demos for per-device session management (`.session_store = .table` + `ctx.auth().revokeAllSessions`/`listActiveSessions`/`revoke`), an atomic hold→booking convert via `ctx.tx()`, a best-effort booking-confirmation webhook via `ctx.http()`, and KV write-side seeding from `onBootstrap`. Added a deterministic e2e suite that freezes time with `ZIGBASE_FAKE_NOW` and captures the outbound webhook. Fixed a latent date-formatting bug in golfsim's `isoFromEpoch` (signed-integer `{d:0>N}` emitted a `+` sign, breaking hold creation).
- plugins example: demonstrates the comptime `.rate_limit = .{ .custom = … }` per-method config, and documents field-key rotation (`ZIGBASE_FIELD_KEY_V<n>` + `zigbase rewrap`) in its README.
