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
   - `0002_index_audit_note` — a more realistic multi-statement migration:
     creates `idx_audit_note` on `plugin_audit_log` **and** seeds a metadata row
     in the same transaction. It targets the **migration-owned** table on
     purpose: comptime `.collections` names each collection's SQLite columns by
     its *stable field id* (8-char hex), not the human field name, so a raw
     migration like `CREATE INDEX ... ON posts (status)` fails — there is no
     literal `status` column. Raw SQL migrations should target tables the
     migration itself owns (or resolve the field id first).

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

## Generate a typed client at runtime — no Zig toolchain (SDK Tier 3)

This example sets `.enable_typegen = true` in its `App(.{…})` config, so its
binary carries the `typegen` subcommand.

**End-user command (published tool, no Zig required):**

```sh
# against a live URL (compiles a client from the running server's schema):
npx @zigbase/typegen --url http://localhost:8090 --out src/zbase.gen.ts

# offline form — reads the data directory directly (no server needed):
npx @zigbase/typegen --data-dir ./pb_data --out src/zbase.gen.ts
```

Runtime introspection generates the **db / realtime / files** surface for the
three collections (`authors`, `posts`, `comments`). It does NOT produce typed
`rpc.*` methods — for that, use the comptime tier (see `examples/golfsim`).

**How it is verified here:** the e2e in `test/typegen.e2e.test.ts` starts the
plugins server to provision a data dir, then runs:

```sh
./zig-out/bin/plugins typegen --data-dir <provisioned dir> --out <tmp>/zbase.gen.ts
```

…and asserts the generated file contains `// generated by zigbase`, `createClient`,
and all three collection names. Run it locally with:

```sh
cd examples/plugins
mise exec node@24 -- npm install
mise exec node@24 -- npm run typecheck
mise exec node@24 -- npm run test:e2e
```

See the [TypeScript SDK docs](../../docs/typescript-sdk.md) for the full
three-tier strategy.

## Build & run

```sh
cd examples/plugins
cd frontend && npm install && npm run build && cd ..
mise exec zig@0.16.0 -- zig build
./zig-out/bin/plugins help
# --insecure-cookies: local dev over plain HTTP (auth cookies are Secure by default).
# A random JWT secret is generated + persisted on first run; the embedded frontend is
# served same-origin, so realtime needs no --realtime-origins.
./zig-out/bin/plugins serve --insecure-cookies   # provisions authors/posts/comments + runs both migrations
# open http://127.0.0.1:8090/  (admin UI at /_/)
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
