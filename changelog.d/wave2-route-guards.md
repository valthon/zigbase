### Features

- Custom routes gain a declarative guard pipeline that runs before the handler. `.auth` now accepts either an `AuthLevel` (`.public`/`.authed`/`.superuser`) **or** a guard struct — `.auth = .{ .path_secret = .{ .param = "token", .source = .{ .kv = "deploy_secret" }, .in = .path, .on_mismatch = .not_found } }` gates a route on a shared secret presented in the path (`.in = .path|.query|.header`) and resolved from `.kv`/`.settings`/`.config`. A new `.rate_limit = .{ .custom = .{ .max = N, .window_s = S } }` (plus optional `.rate_limit_key = fn(*Ctx) ?[]const u8`) adds a per-route rate-limit bucket; both compose on one route.
- `ctx.verifyPathSecret(param, stored)` — a constant-time escape hatch for handlers that gate themselves on a secret resolved by hand.

### Security

- The `path_secret` guard compares the submitted secret to the stored value in **constant time** (`crypto.timingSafeEql`), so a wrong secret leaks no byte-position timing oracle, and a mismatch returns a **bare 404** by default (`.on_mismatch = .not_found`) — indistinguishable from a non-existent route, with no existence oracle. Rotation is immediate: write a new secret to the source and every link carrying the old one stops working (404). An empty/absent stored secret fails closed (never matches).
- Per-route rate-limit buckets key on the trust-proxy-honored client IP (`ZIGBASE_TRUST_PROXY`): when proxies are untrusted a spoofed `X-Forwarded-For` resolves to an empty IP, so it cannot evade or poison another client's bucket. A denied request returns `429` with a `Retry-After` header.
- The shared one-time-code timing-safe comparison was promoted to `crypto.timingSafeEql` (the OTP auth method now calls it) so every secret comparison in the codebase uses one audited, constant-time primitive.
