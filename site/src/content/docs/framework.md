---
title: Framework
description: Embed ZigBase as a Zig library — comptime record hooks, custom routes, scheduled jobs, a comptime schema with additive auto-migration, pluggable storage/mailer backends, and footprint levers.
order: 2
group: guides
---

# Building a Zig app on ZigBase

ZigBase is not only a standalone backend binary — it is an **embeddable Zig framework**.
You `zig fetch --save` it, `@import("zigbase")`, and configure `zigbase.App(.{...})` with
comptime hooks, custom routes, scheduled jobs, and lifecycle/auth/file event handlers.
Your app *is* the ZigBase server, plus your extensions.

> For runnable, end-to-end usage of these APIs (hooks, a custom route with a path param,
> and a DB-touching cron job), see the [Tutorial](./tutorial) and the [Recipes](./recipes).
> This page is the framework reference.

## 1. Overview

The shipped binary is, in its entirety:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{}).runCli(init); // no extensions = the stock server
}
```

`App(cfg)` is a **comptime** application builder. Everything you register is assembled and
validated when your program compiles:

- An unknown config key (e.g. `.hook` instead of `.hooks`) is a **compile error**.
- A typo'd hook phase (e.g. `.beforeCreat`) is a **compile error**.
- A route or job spec missing a required field, or with a wrong-typed handler, is a
  **compile error**.

So a misconfigured extension never reaches runtime — it fails the build loudly.

`runCli(init)` parses argv and dispatches the usual CLI (`serve`, `migrate`, superuser
creation, help), wiring your assembled extensions into the running server.
(`App(...).run(init, cfg)` starts the HTTP server directly with an explicit
`zigbase.Config`, skipping CLI parsing.)

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

Your `exe_mod` must be created with `.link_libc = true` (the `zigbase` module itself is
built with `link_libc` and the bundled SQLite amalgamation + zap).

Minimal `src/main.zig`:

```zig
const std = @import("std");
const zigbase = @import("zigbase");

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{}).runCli(init); // no extensions = the stock server
}
```

## 3. The `App(.{...})` config keys

`App(.{...})` accepts exactly these optional keys. **Any other key is a compile error.**

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
| `collections` | Comptime schema: collections provisioned at startup (additive auto-migration). |
| `migrations` | Explicit migrations (the escape hatch for non-additive schema changes). |
| `static_files` | Comptime static-file mode: absent (default flag), `.disabled`, `.{ .dir = "..." }`, `.{ .embedded = ... }`. |
| `storage` | Storage plugin TYPE (defaults to local-disk storage). |
| `mailer` | Mailer plugin TYPE (defaults to log/SMTP mailer). |
| `pools` | Footprint levers: reader pool, job pool, thread stack size, SQLite page cache. |

## 4. Record hooks (`.hooks`)

Record hooks fire around collection record writes. The shape is a struct keyed by
collection name, plus an optional `any` wildcard group:

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
`afterUpdate`, `beforeDelete`, `afterDelete`. Within a triggered write, the `any` group
runs first, then the collection-specific group; only the field matching the current phase
runs.

Every hook has the signature:

```zig
fn (ev: *zigbase.RecordEvent) anyerror!void
```

`zigbase.RecordEvent` fields:

- `app: *Runtime` — the runtime app context.
- `ctx` — the request context.
- `data` — the `Data` facade for DB access (see below).
- `arena: std.mem.Allocator` — the **request-scoped** allocator that owns `record`'s JSON
  storage.
- `collection: []const u8` — the collection name.
- `record: *std.json.Value` — mutable in `before_*`; the persisted record in `after_*`.
- `phase: RecordPhase`.

### Semantics

- **`before*` hooks** may MUTATE `ev.record` and may return an error to REJECT the write
  (the request fails with `400`). They run AFTER access rules pass.
- **`after*` hooks** are post-commit. An error returned from an after-hook is swallowed and
  routed to the error backstop (it does not undo the committed write).

### CRITICAL: use `ev.arena`, not `ev.app.allocator`

Any allocation that becomes part of `ev.record` MUST use `ev.arena` (the request allocator
that owns the record's JSON map), **not** `ev.app.allocator` (the long-lived gpa). Mixing
allocators on the arena-backed JSON map is undefined behavior.

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

- `findById(collection, id) !?std.json.Value` — returns `null` for both an unknown
  collection and a missing record.
- `create(collection, value) !std.json.Value`
- `update(collection, id, value) !?std.json.Value`
- `delete(collection, id) !bool`
- `list(collection, query) !ListResult`

`create`/`update`/`delete`/`list` return `error.UnknownCollection` when the collection name
does not resolve.

> **Atomicity caveat:** a `before*` hook's `ev.data` writes are **NOT** atomic with the
> triggering write. The triggering write opens its transaction *after* the before-hook
> returns, so side-writes a hook issues via `ev.data` commit independently of (and before)
> the triggering write. See [Known limitations](./known-limitations).

## 5. Custom HTTP routes (`.routes`)

```zig
.routes = .{
    .{ .method = .GET, .path = "/api/blog/ping", .handler = ping, .auth = .public },
},
```

Each spec needs `.method`, `.path`, and `.handler` (a missing field or wrong-typed handler
is a compile error). `.auth` is optional and **defaults to `.superuser`** (the safe
default) when omitted. The three auth levels are:

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

`RouteEvent` carries `app`, `ctx` (the `http.RequestCtx`), and `rctx` — the resolved
request/auth identity (auth identity, `is_superuser`, method), built by the framework
before your handler runs. The framework **enforces `.auth` before** calling the handler.
**Built-in routes always win** over custom routes that would match the same method + path.

### DB access from a route (`ev.writer()` / `ev.reader()`)

Unlike `RecordEvent` (whose `ev.data` is already bound to the in-transaction writer), a
`RouteEvent` has no ambient connection. Use the RAII accessors to check a connection out of
the pool and hand it back — both `RouteEvent` and `JobEvent` / `LifecycleEvent` expose
them:

```zig
// writes — acquires the shared, mutex-guarded pool writer
var w = ev.writer();
defer w.deinit();                 // releases the writer back to the pool (no leak)
const created = try w.data().create("posts", value);

// reads — checks out a warm pooled read-only connection
var r = try ev.reader();
defer r.deinit();                 // returns the connection to the warm pool
const rec = try r.data().findById("posts", id);
```

`ev.writer()` returns a `WriterData` and `ev.reader()` returns `!ReaderData`; each handle's
`data()` yields a `zigbase.Data` bound to that connection (same facade as `RecordEvent.data`:
`findById` / `create` / `update` / `delete` / `list`). **Always `defer <handle>.deinit()`**
— the writer is a single shared connection, so hold it no longer than necessary.

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

`AuthEvent` carries `app`, `ctx`, `collection`, `record: ?std.json.Value`, and `method`
(`.password` | `.oauth2`). `FileEvent` carries `app`, `ctx`, `collection`, `record_id`, and
`filename`. `LifecycleEvent` carries `app`.

## 7. Scheduled jobs (`.cron` + `.jobs`)

```zig
.jobs = .{ .pool_size = 2 }, // worker pool size; defaults to 2 when unset
.cron = .{
    .{ .name = "heartbeat", .schedule = zigbase.schedule.Schedule{ .interval = .hourly }, .handler = heartbeat },
},
```

Each `cron` spec needs `.name`, `.schedule`, and `.handler` (missing/wrong-typed → compile
error). The three schedule modes (`zigbase.schedule.Schedule`):

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

It returns either `.{ .after = <Interval> }` (re-run after that interval, e.g. `.{ .after =
.{ .minutes = 5 } }` or `.{ .after = .daily }`) or `.stop` (retire the job). `JobEvent`
carries `app` and `name`, and exposes the same `ev.writer()` / `ev.reader()` DB accessors
as `RouteEvent` (see
[DB access from a route](#db-access-from-a-route-evwriter--evreader)) — use them to touch
the database from a job rather than hand-building a `Data` from the pool.

### Caveats

The scheduler is intentionally simple (see [Known limitations](./known-limitations)):

- **Single-process** — no distributed coordination.
- **UTC** — all cron/interval evaluation is in UTC.
- **Numeric-only cron** — no `JAN`/`MON` names; supports `*`, `a`, `a,b,c`, `a-b`, `*/n`. A
  malformed numeric sub-part is silently skipped rather than rejected, so a typo'd field may
  match unexpectedly.
- **Day-of-month and day-of-week are ANDed** (not Vixie cron's OR semantics).
- **Minute granularity** — the smallest schedule resolution is one minute.
- **Interval drift** — interval schedules measure the next fire from the previous run's
  *completion*, not a fixed wall clock, so long-running jobs drift.
- **Single-flight** — a job never overlaps itself.

### Ad-hoc background work: `app.submit`

To offload one-off background work from a route or hook onto the worker pool:

```zig
try ev.app.submit("reindex", reindexTask);
// reindexTask: fn (ev: *zigbase.events.JobEvent) anyerror!void
```

`submit` returns `error.SchedulerUnavailable` if no scheduler is running (e.g.
CLI/tests/no jobs configured).

> **Caveat:** ad-hoc submitted tasks currently run on a **detached thread that is NOT
> joined at shutdown**. A task submitted near shutdown may outlive the scheduler's
> stop/deinit and must not assume `app` (or its pool/storage) outlives it indefinitely.
> Cron/interval jobs, by contrast, use the bounded, cleanly-joined worker pool.

## 8. Define your schema in code (`.collections` + `.migrations`)

Instead of provisioning collections over the REST API (see
[Recipes → Provisioning your schema](./recipes#recipe-provisioning-your-schema)), you can
declare them at **comptime** and have ZigBase provision them at startup:

```zig
zigbase.App(.{
    .collections = .{
        .users = .{ .type = .auth, .fields = .{
            .{ .name = "display_name", .type = .text },
        } },
        .posts = .{ .fields = .{
            .{ .name = "title",  .type = .text, .required = true },
            .{ .name = "author", .type = .relation, .target = "users" }, // by NAME
            .{ .name = "status", .type = .select, .values = .{ "draft", "published" } },
        }, .rules = .{ .list = "status = \"published\"" } },
    },
}).runCli(init);
```

### The `.collections` shape

`.collections` is a struct literal whose **field name is the collection name**. Each value
is a struct with:

- `.type` — `.base` (default) / `.auth` / `.view` (a `schema.CollectionType`).
- `.fields` — a **tuple** of field literals (see below).
- `.rules` — optional `.{ .list, .view, .create, .update, .delete }` (any subset; each is a
  filter-expression string).

Each field literal needs `.name` and `.type`, plus optional `.required`, `.unique`,
`.hidden`, and type-specific options:

```zig
.{ .name = "title",  .type = .text, .required = true, .min = 1, .max = 200 }
.{ .name = "price",  .type = .number, .mode = .fixed, .scale = 2 }   // .float (default) / .int / .fixed
.{ .name = "owner",  .type = .relation, .target = "users", .maxSelect = 1, .cascadeDelete = false }
.{ .name = "status", .type = .select, .values = .{ "draft", "published" }, .maxSelect = 1 }
.{ .name = "avatar", .type = .file, .maxSelect = 1, .mimeTypes = .{ "image/png" } }
.{ .name = "meta",   .type = .json }
```

The full field-type catalog (text / email / url / editor / date / autodate / bool / number
/ json / select / relation / file) and their options is in [Fields](./fields). A relation
field's `.target` is the **target collection name** — provisioning resolves it to the
target's id (no need to capture ids as you would over the REST API). Mistakes are caught at
compile time: an unknown field type, a `select` without `.values`, a `fixed` number without
a valid `.scale = 1..8`, or a relation without `.target` is a **compile error**.
Field names reserved by the engine (`id`, `created`, `updated`, `email`,
`username`, `passwordHash`, `tokenKey`, `verified`) are also rejected at compile
time with a clear error message. A malformed `text` field `.pattern` (invalid regex
syntax) or a malformed `date` field `.min`/`.max` bound in a comptime `.collections`
literal is likewise a `@compileError` at build time — consistent with the rest of the
comptime-validated surface.

### Startup provisioning + additive auto-migration

On every startup, ZigBase diffs each declared collection against the live database and
applies the **minimal safe change set** (running it twice is a clean no-op):

- A collection that doesn't exist yet is **created**.
- A field present in the spec but missing from the live collection is **added**, rebuilding
  the table while **preserving existing data** (the new column is null for old rows).
- A **non-additive** change — a field rename, drop, or type/storage-class change — is
  **detected, logged, and SKIPPED** (never applied, so no data loss). Relation targets must
  reference a known collection (a comptime collection or a pre-existing live one such as
  `_superusers`); an unknown target is a startup error.

For the changes auto-migration won't do, use the `.migrations` escape hatch.

### Explicit migrations (`.migrations`)

`.migrations` is a **typed slice** of `zigbase.Migration` records, each run **once**
(recorded in `_migrations` under a `prov:` prefix) **before** provisioning. The field is
`[]const zigbase.Migration`, so it must be a typed slice (`&[_]zigbase.Migration{ ... }`) —
a bare anonymous tuple does **not** coerce:

```zig
.migrations = &[_]zigbase.Migration{
    .{ .id = "0001_rename_title", .up = renameTitle },
},
// .up signature: fn (alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void
//   (zigbase.Db is the writer connection; it exposes exec/prepare/begin/commit/rollback.)
fn renameTitle(alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void {
    _ = alloc; _ = io;
    try w.exec("ALTER TABLE \"posts\" RENAME COLUMN \"headline\" TO \"title\";");
}
```

Each migration has an `.id` (used for the once-only record) and an `.up` function `fn
(alloc: std.mem.Allocator, io: std.Io, w: *zigbase.Db) anyerror!void` run inside a
transaction (rolled back on error). Use migrations for renames, drops, type changes, and
data backfills.

## 9. Pluggable storage & mailer backends (`.storage` / `.mailer`)

`.storage` and `.mailer` each select a comptime **plugin type**. The defaults reproduce the
built-in wiring:

- `.storage` defaults to **`zigbase`'s `DefaultStoragePlugin`** — local-disk storage rooted
  at `<data_dir>/storage`.
- `.mailer` defaults to **`DefaultMailerPlugin`** — a `LogMailer` (logs the email) when no
  SMTP is configured, or an `SmtpMailer` (STARTTLS / implicit TLS / plaintext) when
  `ZIGBASE_SMTP_HOST` is set. Switching is config-driven; no code change is needed to
  upgrade from logging to real SMTP.

A plugin is a type with this uniform contract (built from the runtime `zigbase.Config`):

```zig
pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !Self;
pub fn interface(self: *Self) zigbase.Storage; // or zigbase.Mailer — the type-erased vtable view
pub fn deinit(self: *Self) void;               // release owned resources
```

`create` builds the backend from config; `interface` returns the type-erased vtable handle
stored on the app; `deinit` tears it down (the instance outlives the server). Supply your
own to back storage or mail with a different system. A custom mailer hands back a
`zigbase.Mailer` view built from a static `VTable` whose `send` receives a `zigbase.Email`:

```zig
const AuditMailer = struct {
    sent: usize = 0,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, cfg: zigbase.Config) !AuditMailer {
        _ = gpa; _ = io; _ = cfg;
        return .{};
    }
    pub fn interface(self: *AuditMailer) zigbase.Mailer {
        return .{ .ptr = self, .vtable = &vtable };
    }
    pub fn deinit(self: *AuditMailer) void { _ = self; }

    const vtable = zigbase.Mailer.VTable{ .send = send };

    fn send(ptr: *anyopaque, io: std.Io, alloc: std.mem.Allocator, email: zigbase.Email) anyerror!void {
        _ = io; _ = alloc;
        const self: *AuditMailer = @ptrCast(@alignCast(ptr));
        self.sent += 1;
        std.log.info("to={s} subject={s}", .{ email.to, email.subject });
    }
};

zigbase.App(.{ .mailer = AuditMailer }).runCli(init);
```

A custom storage plugin follows the same shape, returning a `zigbase.Storage` view from
`interface()`. The `zigbase.Storage` vtable backs file storage (the default
`zigbase.DefaultStoragePlugin` wraps `zigbase.LocalStorage`); the `zigbase.Mailer` vtable —
a single `send(io, alloc, zigbase.Email)` — backs mail (the default
`zigbase.DefaultMailerPlugin` selects `zigbase.LogMailer` or `zigbase.SmtpMailer` from
config). See the [plugins example](../examples/plugins) for the full, compiling
custom-mailer plugin.

## 10. Footprint levers (`.pools`)

`.pools` tunes ZigBase's memory/connection footprint at comptime. All fields are optional;
each defaults to the historical value:

| Field | Default | Meaning |
| --- | --- | --- |
| `.readers` | `16` | warm reader-connection pool cap — shrink to reduce the connection footprint. |
| `.jobs` | `2` | scheduler worker-pool size (same as `.jobs.pool_size`). |
| `.stack_size` | `1 MiB` | per-thread stack for scheduler/job/`submit` threads (vs `std.Thread`'s 16 MiB default). **Clamped up** to a safe floor — the lever can only *raise* the stack, e.g. for unusually deep job handlers. |
| `.cache_kib` | `1024` | SQLite per-connection page cache (KiB), across the writer + warm readers — shrink to save memory, raise for large working sets. |

```zig
zigbase.App(.{
    .pools = .{ .readers = 4, .jobs = 2, .stack_size = 2 << 20, .cache_kib = 256 },
}).runCli(init);
```

`.pools.jobs` is the unified job-pool lever; the legacy `.jobs = .{ .pool_size = N }` still
works (and `.pools.jobs` takes precedence when both are set).

## 11. Errors + Sentry

```zig
.onError = handleError, // fn (ev: *zigbase.ErrorEvent) void
```

When the framework catches an error, your `onError` handler (if any) runs **first**, then a
built-in backstop reports the error to Sentry when `ZIGBASE_SENTRY_DSN` is set, otherwise
logs it. `ErrorEvent` carries `app`, `ctx` (optional), `err`, `phase` (`request` /
`before_hook` / `after_hook` / `cron` / `job` / `file_serve`), and `message`. The backstop
never propagates.

## 12. The worked example

Three buildable examples form a ladder: the [blog example](../examples/blog) is the basic
packaging proof (hooks + route + cron + Astro/React frontend served via `--serve-static`),
the [golfsim example](../examples/golfsim) is a realistic app (hooks, routes, cron, and a
comptime-hardcoded `.dir` static mode), and the [plugins example](../examples/plugins) is
the advanced framework-feature reference (custom mailer plugin + `.collections` schema +
typed `.migrations` + `.pools` levers + fully embedded static assets via `embedStaticDir`).

The blog `App(.{...})` block is the canonical basics reference (hooks + route + job):

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

## 13. Serve a frontend: static files

Anything that misses `/_/`, the built-in API, and your custom routes falls through to the
static-file server (GET/HEAD only; `/api/*` misses keep the JSON 404 envelope; static
misses return a plain-text 404). `/` and directory paths resolve to `index.html`. In
**embedded** mode, each asset carries a precomputed CRC32 content `ETag` and zigbase
handles `If-None-Match`/304 itself. In **dir** mode (`--serve-static` or comptime `.dir`),
caching is delegated to facil.io's `sendFile`, which emits its own `ETag`, `Last-Modified`,
`Cache-Control: max-age=3600`, and handles `If-None-Match`/304. All modes add
`X-Content-Type-Options: nosniff`.

Pick a mode at comptime with `.static_files`:

| Mode | Config | `--serve-static` flag |
|---|---|---|
| runtime flag (default) | *(field absent)* | enabled |
| disabled | `.static_files = .disabled` | rejected |
| hardcoded dir | `.static_files = .{ .dir = "frontend/dist" }` | rejected |
| embedded | `.static_files = .{ .embedded = &@import("static_assets").files }` | rejected |

In **embedded** mode, assets are compiled into the binary. Generate the manifest from your
`build.zig` using the helper exported by zigbase's `build.zig`:

```zig
// build.zig
const zigbase_build = @import("zigbase");
const assets = zigbase_build.embedStaticDir(b, "frontend/dist");
exe_mod.addImport("static_assets", assets);

// main.zig
.static_files = .{ .embedded = &@import("static_assets").files }
```

The build fails with a clear error when `frontend/dist` is missing — build the frontend
first (e.g. `npm run build`). A hardcoded or `--serve-static` directory that is missing or
unreadable at startup is a **fatal startup error** naming the path.

See the [blog example](../examples/blog) (runtime flag), [golfsim example](../examples/golfsim)
(hardcoded dir), and [plugins example](../examples/plugins) (embedded).

## Exported names reference

The public surface (from `src/root.zig`):

- `zigbase.App` — the comptime application builder.
- `zigbase.Runtime` — the runtime app context type (the `*App` you receive on events).
- `zigbase.Config`, `zigbase.Server`.
- `zigbase.http` — HTTP types (`http.Response`, `http.Method`, ...).
- `zigbase.Data` — the DB facade.
- `zigbase.events` — all event/handler types (`events.AuthEvent`, `events.FileEvent`,
  `events.LifecycleEvent`, `events.JobEvent`, ...).
- `zigbase.schedule` — `schedule.Schedule`, `schedule.Interval`, `schedule.Reactive`.
- `zigbase.RecordEvent`, `zigbase.ErrorEvent`, `zigbase.RouteEvent` — re-exported directly
  for convenience.
- `zigbase.Migration` — the `.migrations` slice element type; `zigbase.Db` — the writer
  connection passed to a migration's `.up`.
- `zigbase.StaticFile` — the embedded manifest entry type (path, bytes, etag); used by
  `.static_files = .{ .embedded = ... }`.
- `zigbase.Storage` / `zigbase.Mailer` / `zigbase.Email` — the storage & mailer plugin
  vtable types; `zigbase.DefaultStoragePlugin` / `zigbase.DefaultMailerPlugin` — the
  built-in defaults; `zigbase.LocalStorage`, `zigbase.LogMailer`, `zigbase.SmtpMailer`,
  `zigbase.SmtpTls` — the concrete backends.

## See also

- [Tutorial](./tutorial) — build an app on ZigBase, end to end.
- [Recipes](./recipes) — copy-pasteable hook / route / job patterns (computed fields, owner
  rules, path-param routes, DB access in cron).
- [Fields](./fields) — the field-type & options catalog.
- [API](./api) — the HTTP REST + WebSocket reference.
