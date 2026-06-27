### Fixes

- Auth methods configured with a custom `rate_limit` (`.{ .custom = .{ .max, .window_s } }`) now actually honor that `max`/`window_s` instead of silently falling back to the global limiter. Each method gets a dedicated bucket scoped by collection + method slug (keyed on the same IP/identity subject as the global limiter), so distinct methods and collections never share a budget, and a custom limit applies even when the global limiter is disabled (`ZIGBASE_RATE_LIMIT_MAX=0`).
