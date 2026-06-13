# zigbase plugins example — the advanced framework surface

This is the **advanced framework** example. The three examples form a ladder:

| Example | What it proves |
| --- | --- |
| `examples/blog` | bare packaging proof (ZigBase as a dependency) |
| `examples/golfsim` | a realistic app built on ZigBase (hooks, routes, cron) |
| **`examples/plugins`** | the full comptime-config surface a framework integrator uses |

It is a standalone package with a path dependency on the repo root
(`../..`) and exercises — using **only public `zigbase.*` exports**, no reaching
into ZigBase internals — the comptime-config features a serious consumer
configures in code:

1. **Custom storage plugin** (`AuditStorage`). The headline addition. Implements
   the plugin contract `create(gpa, io, cfg) !Self` /
   `interface(*Self) zigbase.Storage` / `deinit(*Self) void`, wrapping a
   `zigbase.LocalStorage` backend with a logging intercept layer. The wrapper
   holds `LocalStorage` by value, obtains `inner = local.storage()` in
   `interface()` (where `self` is stable), then builds a static
   `zigbase.Storage.VTable` with all four methods:
   - `put(ctx, io, col, record_id, filename, bytes)`
   - `localPath(ctx, alloc, col, record_id, filename) ?[]const u8`
   - `delete(ctx, io, col, record_id, filename)`
   - `deleteRecord(ctx, io, col, record_id)`

   Each wrapper function `@ptrCast/@alignCast`s `ctx` → `*AuditStorage`, logs
   the operation, then delegates to `self.inner.vtable.<method>(self.inner.ctx, ...)`.
   Registered via `App(.{ .storage = AuditStorage })`.

2. **Custom mailer plugin** (`AuditMailer`). Implements the same plugin contract
   for `zigbase.Mailer` / `zigbase.Email`, logging every outbound email and
   counting sends. Registered via `App(.{ .mailer = AuditMailer })`.

3. **Comptime schema** via `.collections`. **Three** related collections:

   | Collection | Relations | Access rules |
   | --- | --- | --- |
   | `authors` | — | list/view public |
   | `posts` | `author → authors` (cascade-delete) | list: `status = "published"` only |
   | `comments` | `post → posts` (cascade-delete) | list/view: `approved = true`; create: open |

   `posts.author` and `comments.post` are both `.relation` fields whose
   `.target` names are resolved to collection ids at provision time. The
   `comments` collection demonstrates a second cross-collection relation and
   a `.bool` field with a comptime list/view rule.

4. **Explicit migrations** via `.migrations`. Two `zigbase.Migration` entries
   run once each (recorded in `_migrations`):
   - `0001_create_audit_log` — creates a `plugin_audit_log` side table outside
     the comptime-managed schema (the classic escape hatch).
   - `0002_seed_status_index` — a more realistic multi-statement migration:
     creates `idx_posts_status` (speeds up the cron filter) **and** seeds a
     metadata row in the same transaction.

5. **`onError` handler** via `.onError`. Receives `*zigbase.ErrorEvent` with
   `.phase` (`.request` / `.before_hook` / `.after_hook` / `.cron` / `.job` /
   `.file_serve`) and `.message`. Logs a structured one-liner so operators can
   distinguish request errors from background-job failures.

6. **Cron job** (`audit-sweep`) via `.cron`. Fires every minute
   (`"* * * * *"`, UTC, 5-field numeric). Demonstrates the full job DB-access
   pattern: reads via `ev.reader()` (pooled reader), writes via `ev.writer()`
   (mutex-guarded writer). Counts published posts, then INSERTs an audit row
   into `plugin_audit_log`.

7. **Pool levers** via `.pools` (`.readers` / `.jobs` / `.cache_kib`) to tune
   the warm-reader pool, scheduler worker count, and per-connection SQLite
   page-cache budget.

8. **Fully embedded static frontend** via `embedStaticDir`. The Astro + React
   build output in `frontend/dist` is compiled into the binary at build time via
   `.static_files = .{ .embedded = &@import("static_assets").files }` — there is
   no runtime dependency on the `frontend/dist` directory. The frontend shows
   authors, published posts, and approved comments (three relations live).

## Build & run

```sh
cd examples/plugins
cd frontend && npm install && npm run build && cd ..
mise exec zig@0.16.0 -- zig build
./zig-out/bin/plugins help
./zig-out/bin/plugins serve     # provisions authors/posts/comments + runs both migrations
# open http://127.0.0.1:8090/
```

This demonstrates the **embedded** static-files mode: the Astro frontend is
compiled into the binary by `embedStaticDir` in `build.zig`. Delete
`frontend/dist` after building — the site still serves from the binary.
`--serve-static` is rejected as an unknown flag because the mode is
comptime-hardcoded. The other modes are shown by the blog (runtime flag) and
golfsim (hardcoded dir) examples.

The fact that this package **compiles against the published `zigbase` module**
is the proof that the documented plugin / schema / migration / cron / error
features are usable by an external consumer.
