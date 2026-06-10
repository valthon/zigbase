# Building a Zig app on ZigBase

ZigBase is not only a standalone backend binary — it is an **embeddable Zig
framework**. You `zig fetch --save` it, `@import("zigbase")`, and configure
`zigbase.App(.{...})` with comptime hooks, custom routes, scheduled jobs, and
lifecycle/auth/file event handlers. Your app *is* the ZigBase server, plus your
extensions.

> For runnable, end-to-end usage of these APIs (hooks, a custom route with a path
> param, and a DB-touching cron job), see the [tutorial](tutorial.md) and the
> [recipes](recipes.md). This page is the framework reference.

## 1. Overview

The shipped binary is, in its entirety:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{}).runCli(init); // no extensions = the stock server
}
```

`App(cfg)` is a **comptime** application builder. Everything you register is
assembled and validated when your program compiles:

- An unknown config key (e.g. `.hook` instead of `.hooks`) is a **compile error**.
- A typo'd hook phase (e.g. `.beforeCreat`) is a **compile error**.
- A route or job spec missing a required field, or with a wrong-typed handler,
  is a **compile error**.

So a misconfigured extension never reaches runtime — it fails the build loudly.

`runCli(init)` parses argv and dispatches the usual CLI (`serve`, `migrate`,
superuser creation, help), wiring your assembled extensions into the running
server. (`App(...).run(init, cfg)` starts the HTTP server directly with an
explicit `zigbase.Config`, skipping CLI parsing.)

## 2. Add the dependency

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

In your `build.zig`:

```zig
const zb = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zb.module("zigbase"));
// exe_mod must link libc: zigbase carries the SQLite C source and zap transitively.
```

Your `exe_mod` must be created with `.link_libc = true` (the `zigbase` module
itself is built with `link_libc` and the bundled SQLite amalgamation + zap).

Minimal `src/main.zig`:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{}).runCli(init); // no extensions = the stock server
}
```

## 3. The `App(.{...})` config keys

`App(.{...})` accepts exactly these optional keys. **Any other key is a compile
error.**

| Key | Purpose |
| --- | --- |
| `hooks` | Per-collection record lifecycle hooks (before/after create/update/delete). |
| `onError` | Consumer error handler, runs before the built-in backstop. |
| `routes` | Custom HTTP routes. |
| `onAuth` | Fires after a successful login / oauth2. |
| `onFileServe` | Fires before serving a file download (may deny). |
| `onFileUpload` | Fires after a file upload. |
| `onBootstrap` | Lifecycle: after bootstrap. |
| `onBeforeServe` | Lifecycle: just before the server starts serving. |
| `onBeforeTerminate` | Lifecycle: just before shutdown. |
| `cron` | Scheduled job table. |
| `jobs` | Scheduler settings (e.g. `.pool_size`). |

## 4. Record hooks (`.hooks`)

Record hooks fire around collection record writes. The shape is a struct keyed
by collection name, plus an optional `any` wildcard group:

```zig
.hooks = .{
    .any = .{ // fires for EVERY collection (before the collection-specific group)
        .beforeCreate = auditCreate,
    },
    .posts = .{
        .beforeCreate = slugify,
        .afterUpdate  = reindex,
        .beforeDelete = guardDelete,
    },
},
```

The six valid phase fields are `beforeCreate`, `afterCreate`, `beforeUpdate`,
`afterUpdate`, `beforeDelete`, `afterDelete`. Within a triggered write, the
`any` group runs first, then the collection-specific group; only the field
matching the current phase runs.

Every hook has the signature:

```zig
fn (ev: *zigbase.RecordEvent) anyerror!void
```

`zigbase.RecordEvent` fields:

- `app: *Runtime` — the runtime app context.
- `ctx` — the request context.
- `data` — the `Data` facade for DB access (see below).
- `arena: std.mem.Allocator` — the **request-scoped** allocator that owns
  `record`'s JSON storage.
- `collection: []const u8` — the collection name.
- `record: *std.json.Value` — mutable in `before_*`; the persisted record in
  `after_*`.
- `phase: RecordPhase`.

### Semantics

- **`before*` hooks** may MUTATE `ev.record` and may return an error to REJECT
  the write (the request fails with `400`). They run AFTER access rules pass.
- **`after*` hooks** are post-commit. An error returned from an after-hook is
  swallowed and routed to the error backstop (it does not undo the committed
  write).

### CRITICAL: use `ev.arena`, not `ev.app.allocator`

Any allocation that becomes part of `ev.record` MUST use `ev.arena` (the
request allocator that owns the record's JSON map), **not** `ev.app.allocator`
(the long-lived gpa). Mixing allocators on the arena-backed JSON map is
undefined behavior.

From the worked example's `slugify` (`before_create` on `posts`):

```zig
fn slugify(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return;
    if (ev.record.object.get("slug") != null) return;
    const title = if (ev.record.object.get("title")) |t| switch (t) {
        .string => |s| s,
        else => return,
    } else return;

    const buf = try ev.arena.alloc(u8, title.len); // <-- ev.arena, NOT ev.app.allocator
    var len: usize = 0;
    // ... build the slug into buf ...
    try ev.record.object.put(ev.arena, "slug", .{ .string = buf[0..len] }); // <-- ev.arena
}
```

### The `ev.data` facade

`ev.data` (a `zigbase.Data`) gives a hook curated DB access:

- `findById(collection, id) !?std.json.Value` — returns `null` for both an
  unknown collection and a missing record.
- `create(collection, value) !std.json.Value`
- `update(collection, id, value) !?std.json.Value`
- `delete(collection, id) !bool`
- `list(collection, query) !ListResult`

`create`/`update`/`delete`/`list` return `error.UnknownCollection` when the
collection name does not resolve.

> **Atomicity caveat:** a `before*` hook's `ev.data` writes are **NOT** atomic
> with the triggering write. The triggering write opens its transaction *after*
> the before-hook returns, so side-writes a hook issues via `ev.data` commit
> independently of (and before) the triggering write. See
> [../KNOWN_LIMITATIONS.md](../KNOWN_LIMITATIONS.md).

## 5. Custom HTTP routes (`.routes`)

```zig
.routes = .{
    .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public },
},
```

Each spec needs `.method`, `.path`, and `.handler` (a missing field or
wrong-typed handler is a compile error). `.auth` is optional and **defaults to
`.superuser`** (the safe default) when omitted. The three auth levels are:

- `.public` — anyone (anonymous identity still provided).
- `.authed` — any authenticated user.
- `.superuser` — superusers only.

The handler signature is:

```zig
fn (ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response
```

```zig
fn ping(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    _ = ev;
    return .{ .status = 200, .body = "{\"pong\":true}" };
}
```

`RouteEvent` carries `app`, `ctx` (the `http.RequestCtx`), and `rctx` — the
resolved request/auth identity (auth identity, `is_superuser`, method), built by
the framework before your handler runs. The framework **enforces `.auth`
before** calling the handler. **Built-in routes always win** over custom routes
that would match the same method + path.

## 6. Auth / file / lifecycle events

One handler each, registered by the matching config key:

| Key | Signature | When |
| --- | --- | --- |
| `onAuth` | `fn (ev: *zigbase.events.AuthEvent) void` | After a successful login / oauth2. |
| `onFileServe` | `fn (ev: *zigbase.events.FileEvent) anyerror!void` | Before serving a download; **return an error to deny** (framework → `404`). |
| `onFileUpload` | `fn (ev: *zigbase.events.FileEvent) void` | After a successful upload. |
| `onBootstrap` | `fn (ev: *zigbase.events.LifecycleEvent) void` | After bootstrap. |
| `onBeforeServe` | `fn (ev: *zigbase.events.LifecycleEvent) void` | Just before serving starts. |
| `onBeforeTerminate` | `fn (ev: *zigbase.events.LifecycleEvent) void` | Just before shutdown. |

`AuthEvent` carries `app`, `ctx`, `collection`, `record: ?std.json.Value`, and
`method` (`.password` | `.oauth2`). `FileEvent` carries `app`, `ctx`,
`collection`, `record_id`, and `filename`. `LifecycleEvent` carries `app`.

## 7. Scheduled jobs (`.cron` + `.jobs`)

```zig
.jobs = .{ .pool_size = 2 }, // worker pool size; defaults to 2 when unset
.cron = .{
    .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat },
},
```

Each `cron` spec needs `.name`, `.schedule`, and `.handler` (missing/wrong-typed
→ compile error). The three schedule modes (`zigbase.schedule.Schedule`):

```zig
.{ .cron = "0 3 * * *" }              // 5-field cron, UTC, numeric-only
.{ .interval = .hourly }              // also .daily / .weekly
.{ .interval = .{ .minutes = 15 } }   // every N minutes
.reactive                             // handler decides its own next fire
```

**Handler signatures depend on the mode.** Cron and interval jobs use:

```zig
fn (ev: *zigbase.events.JobEvent) anyerror!void
```

```zig
fn heartbeat(ev: *zigbase.events.JobEvent) anyerror!void {
    std.log.info("blog heartbeat job '{s}' ran", .{ev.name});
}
```

A `.reactive` job's handler instead **returns its next schedule**:

```zig
fn (ev: *zigbase.events.JobEvent) anyerror!zigbase.schedule.Reactive
```

It returns either `.{ .after = <Interval> }` (re-run after that interval, e.g.
`.{ .after = .{ .minutes = 5 } }` or `.{ .after = .daily }`) or `.stop` (retire
the job). `JobEvent` carries `app` and `name`.

### Caveats

The scheduler is intentionally simple (see
[../KNOWN_LIMITATIONS.md](../KNOWN_LIMITATIONS.md)):

- **Single-process** — no distributed coordination.
- **UTC** — all cron/interval evaluation is in UTC.
- **Numeric-only cron** — no `JAN`/`MON` names; supports `*`, `a`, `a,b,c`,
  `a-b`, `*/n`. A malformed numeric sub-part is silently skipped rather than
  rejected, so a typo'd field may match unexpectedly.
- **Day-of-month and day-of-week are ANDed** (not Vixie cron's OR semantics).
- **Minute granularity** — the smallest schedule resolution is one minute.
- **Interval drift** — interval schedules measure the next fire from the
  previous run's *completion*, not a fixed wall clock, so long-running jobs drift.
- **Single-flight** — a job never overlaps itself.

### Ad-hoc background work: `app.submit`

To offload one-off background work from a route or hook onto the worker pool:

```zig
try ev.app.submit("reindex", reindexTask);
// reindexTask: fn (ev: *zigbase.events.JobEvent) anyerror!void
```

`submit` returns `error.SchedulerUnavailable` if no scheduler is running (e.g.
CLI/tests/no jobs configured).

> **Caveat:** ad-hoc submitted tasks currently run on a **detached thread that
> is NOT joined at shutdown**. A task submitted near shutdown may outlive the
> scheduler's stop/deinit and must not assume `app` (or its pool/storage)
> outlives it indefinitely. Cron/interval jobs, by contrast, use the bounded,
> cleanly-joined worker pool.

## 8. Errors + Sentry

```zig
.onError = handleError, // fn (ev: *zigbase.ErrorEvent) void
```

When the framework catches an error, your `onError` handler (if any) runs
**first**, then a built-in backstop reports the error to Sentry when
`ZIGBASE_SENTRY_DSN` is set, otherwise logs it. `ErrorEvent` carries `app`,
`ctx` (optional), `err`, `phase` (`request` / `before_hook` / `after_hook` /
`cron` / `job` / `file_serve`), and `message`. The backstop never propagates.

## 9. The worked example

See [`examples/blog/`](../examples/blog/) for a complete, buildable app. Its
`App(.{...})` block is the canonical reference (hooks + route + job):

```zig
pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
        .routes = .{
            .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public },
        },
        .jobs = .{ .pool_size = 2 },
        .cron = .{
            .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat },
        },
    }).runCli(init);
}
```

## Exported names reference

The public surface (from `src/root.zig`):

- `zigbase.App` — the comptime application builder.
- `zigbase.Runtime` — the runtime app context type (the `*App` you receive on
  events).
- `zigbase.Config`, `zigbase.Server`.
- `zigbase.http` — HTTP types (`http.Response`, `http.Method`, ...).
- `zigbase.Data` — the DB facade.
- `zigbase.events` — all event/handler types (`events.AuthEvent`,
  `events.FileEvent`, `events.LifecycleEvent`, `events.JobEvent`, ...).
- `zigbase.schedule` — `schedule.Schedule`, `schedule.Interval`,
  `schedule.Reactive`.
- `zigbase.RecordEvent`, `zigbase.ErrorEvent`, `zigbase.RouteEvent` —
  re-exported directly for convenience.

---

## See also

- [tutorial.md](tutorial.md) — build an app on ZigBase, end to end.
- [recipes.md](recipes.md) — copy-pasteable hook / route / job patterns (computed
  fields, owner rules, path-param routes, DB access in cron).
- [fields.md](fields.md) — the field-type & options catalog.
- [api.md](api.md) — the HTTP REST + WebSocket reference.
