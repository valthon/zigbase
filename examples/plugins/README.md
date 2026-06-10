# zigbase plugins example — the advanced framework surface

This is the **advanced framework** example. The three examples form a ladder:

| Example | What it proves |
| --- | --- |
| `examples/blog` | bare packaging proof (ZigBase as a dependency) |
| `examples/golfsim` | a realistic app built on ZigBase (hooks, routes, cron) |
| **`examples/plugins`** | the comptime-config surface a framework integrator uses |

It is a standalone package with a path dependency on the repo root
(`../..`) and exercises — using **only public `zigbase.*` exports**, no reaching
into ZigBase internals — the comptime-config features a consumer configures in
code:

1. **Custom mailer plugin** (`AuditMailer`). Implements the plugin contract
   `create(gpa, io, cfg) !Self` / `interface(*Self) zigbase.Mailer` /
   `deinit(*Self) void`, returning a `zigbase.Mailer` vtable whose `send`
   receives a `zigbase.Email`. Registered via `App(.{ .mailer = AuditMailer })`,
   replacing the built-in `DefaultMailerPlugin`. (Pair it with a custom
   `.storage = ...` plugin the same way, returning a `zigbase.Storage` vtable.)

2. **Comptime schema** via `.collections`. Two collections, `authors` and
   `posts`, where `posts.author` is a `.relation` referencing `authors`
   **by name** (`.target = "authors"`). ZigBase provisions these at startup
   (create-missing + additive field-add + name→id relation resolution).

3. **Explicit migration** via `.migrations`. A `zigbase.Migration` whose
   `up = fn(alloc, io, w: *zigbase.Db) anyerror!void` runs `w.exec(...)` — the
   escape hatch for non-additive changes the additive auto-provisioner won't
   make. It runs once and is recorded in `_migrations`.

4. **Pool levers** via `.pools` (`.readers` / `.jobs` / `.cache_kib`) to tune
   the warm-reader pool, scheduler worker count, and per-connection SQLite
   page-cache budget — i.e. the runtime footprint.

## Build & run

```sh
cd examples/plugins
mise exec zig@0.16.0 -- zig build
./zig-out/bin/plugins help
./zig-out/bin/plugins serve     # provisions authors/posts + runs the migration
```

The fact that this package **compiles against the published `zigbase` module**
is the proof that the documented plugin / schema / migration / pool features are
usable by an external consumer.
