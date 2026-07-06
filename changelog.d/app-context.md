### Breaking

- The `onBootstrap`/`onBeforeServe`/`onBeforeTerminate` lifecycle hooks now return `anyerror!void` (was `void`) — update existing hook signatures (a `fn (...) void` no longer coerces). A returned error from `onBootstrap`/`onBeforeServe` fails the boot; an `onBeforeTerminate` error is logged (it fires in a shutdown defer).

### Features

- App-scoped context: declare a context type at comptime with `App(.{ .app_context = T })`, install it once in `onBootstrap` via `ctx.setAppData(T, &value)`, and read it anywhere (handler/hook/job/cron) as a `*T` with `ctx.appData(T)` — one explicit, typed handle replacing module-level globals + bootstrap setter rituals. Declaring `.app_context` makes setting it a boot contract (the server refuses to start if `onBootstrap` never installs the handle); apps that don't declare it pay nothing.
