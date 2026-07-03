### Breaking

- `zigbase.Server` is now a generic `pub fn Server(comptime gates: Gates) type` instead of a concrete struct — the built-in route table is assembled per-app from `Gates` (R2-3). Framework consumers reach it exclusively through `App(cfg).runCli`/`serve`, which thread the new `gates` config automatically; only code that named `zigbase.Server` directly (bypassing `App`) needs an update, e.g. `server.Server(.{})` for the historical all-on table.

### Features

- New comptime `.admin = .disabled` key: headless/embedded consumers can drop the admin SPA (dispatch + ~58 KiB embedded assets) from their binary. Default unchanged — the admin UI serves at `/_/`.

### Changed

- Built-in routes are now comptime-assembled from your `App(.{…})` config: analytics, senders, the inbound mail webhook, one-click unsubscribe, and `accounts/:id/activate` are registered (and compiled) only when `.analytics`, `.mail`, or `.tenancy` is configured. Previously these routes always existed and answered 404/fail-closed when unconfigured; now they 404 as unknown routes. The standalone `zigbase serve` binary opts into `.mail = .{}`, so its mail routes (verified senders, the inbound webhook, RFC 8058 unsubscribe) stay registered and behave exactly as before; only the still-unconfigured analytics and tenancy routes now 404 uniformly.
