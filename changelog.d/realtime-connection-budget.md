### Features

- Tune the shared WebSocket/SSE connection cap with comptime `.realtime.max_connections` (positive `u32`, default 10,000). Realtime stats and `resources --json` report the configured cap; saturated upgrades are rejected without incrementing the reserved count.
