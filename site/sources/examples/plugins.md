---
title: Plugins & comptime config
summary: The comptime-config surface a framework integrator uses — custom mailer, comptime schema, explicit migration, pool levers, and a fully embedded Zigapagos frontend.
rung: Advanced framework surface
order: 3
repoPath: examples/plugins
---





# Plugins & comptime config

This is the **advanced framework** example. It is a standalone package with a path
dependency on the repo root (`../..`) and exercises — using **only public
`zigbase.*` exports**, no reaching into ZigBase internals — the comptime-config
features a consumer configures in code.


  ![The plugins example's 'Everything in one binary' page: an Authors panel listing two authors and a Published posts panel listing three posts with their authors resolved via relation expand — all HTML, JS, and CSS served from assets embedded in the executable](../../assets/screenshots/example-plugins-browser.png)


## What it proves

1. **Custom storage plugin** (`AuditStorage`) wrapping `zigbase.LocalStorage`.
   Implements the plugin contract `create(gpa, io, cfg) !Self` /
   `interface(*Self) zigbase.Storage` / `deinit(*Self) void`, returning a
   `zigbase.Storage` vtable whose four methods log each operation before
   delegating to the inner `LocalStorage` backend. Registered via
   `App(.{ .storage = AuditStorage })`.

2. **Custom mailer plugin** (`AuditMailer`). Implements the same plugin
   contract for `zigbase.Mailer` / `zigbase.Email`, logging and counting every
   outbound email. Registered via `App(.{ .mailer = AuditMailer })`, replacing
   the built-in `DefaultMailerPlugin`.

3. **Comptime schema** via `.collections`. Four related collections:
   `authors` (auth: webauthn + api_token), `commenters` (auth: magic_link),
   `posts` (relation → `authors`), and `comments` (relation → `posts` +
   `commenters`), each with `.target` set **by name** so ZigBase resolves the
   relation at provisioning time (create-missing + additive field-add).
   Access rules are applied per-collection.

4. **Explicit migrations** via `.migrations`. Two `zigbase.Migration` entries:
   `0001_create_audit_log` creates a side table via `w.exec`, and
   `0002_index_audit_note` is a multi-statement migration that creates an
   index on the migration-owned `plugin_audit_log` table *and* seeds a
   metadata row (DDL + DML in one transaction) — the escape hatch for
   non-additive changes the additive auto-provisioner won't make.

5. **`onError` handler** (`.onError = handleError`), receiving a
   `*zigbase.ErrorEvent` whose `.phase` field identifies where the error
   originated (`.request` / `.cron` / `.job` / `.file_serve` / ...).

6. **A DB-touching cron job** (`* * * * *`, every minute) that reads the DB via
   `ctx.records()` to count published posts, then writes an audit log row to a
   migration-owned table with raw SQL on the pooled writer (`ctx.app.pool`).

7. **Pool levers** via `.pools` (`.readers` / `.jobs` / `.cache_kib`) to tune
   the warm-reader pool, scheduler worker count, and per-connection SQLite
   page-cache budget — i.e. the runtime footprint.

8. **Fully embedded static frontend** via `embedStaticDir`. The Zigapagos frontend
   build output in `frontend/dist` is compiled into the binary at build time via
   `.static_files = .{ .embedded = &@import("static_assets").files }` — there is
   no runtime dependency on the `frontend/dist` directory.

9. **`onAuth` hook** logging collection + method for every successful session
   mint. With two auth collections and three methods in use, log lines show
   `[onAuth] collection=authors method=webauthn`, `method=custom` (api_token),
   and `collection=commenters method=magic_link`.

10. **Custom `AuthMethod` plugin** (`ApiTokenMethod`) via `.auth_methods`,
    demonstrating the auth-method plugin contract alongside storage + mailer.
    Enabled on `authors` via `.auth.methods.custom = .{"api_token"}`.

11. **Comptime `.indexes`** with `.collation = .nocase` on
    `authors.contact_email` — the correct way to index a comptime-managed
    collection, since its physical column is named by the human field name,
    not the field id.

12. **Tier-2 SPA fallback routing** via `.static_routes` ([#183](https://github.com/valthon/zigbase/issues/183)):
    a `/app/**` catch-all serves the embedded frontend shell for any static
    miss below `/app/`. The serve target is validated against the embedded
    manifest **at comptime**. Declaring routes flips the Tier-1 `.spa` marker
    default off — see [Framework → Static files](../docs/framework#13-serve-a-frontend-static-files).

The fact that this package **compiles against the published `zigbase` module**
is the proof that the documented plugin / schema / migration / pool features are
usable by an external consumer.

> **Pre-1.0:** ZigBase is pre-1.0 — these comptime-config shapes may change
> between releases.

## The ladder

The three examples form a ladder:

| Example | What it proves |
| --- | --- |
| `examples/blog` | bare packaging proof (ZigBase as a dependency) |
| `examples/golfsim` | a realistic app built on ZigBase (hooks, routes, cron) |
| **`examples/plugins`** | the comptime-config surface a framework integrator uses |

## Frontend (Zigapagos frontend)

`frontend/` is a single-page Zigapagos site with targeted Preact islands that browse the `authors` and
published `posts` collections. The HTML, JS, and CSS are **compiled into the executable**
via `embedStaticDir` + `.static_files = .{ .embedded = ... }`. There is no runtime
dependency on the `frontend/dist` directory — delete it after building and the site still
serves.

This demonstrates the **embedded** static-files mode: The Zigapagos frontend is compiled into
the binary by `embedStaticDir` in `build.zig`. `--serve-static` is rejected as an unknown
flag because the mode is comptime-hardcoded. The other modes are shown by the blog (runtime
flag) and golfsim (hardcoded dir) examples.

## Building and running

This example needs **Zig 0.16**, which you can get via [mise](https://mise.jdx.dev)
(`mise exec zig@0.16.0 -- zig ...`). From `examples/plugins/`:

```sh
cd frontend && ./build.sh && cd ..
zig build       # embeds frontend/dist into the binary
./zig-out/bin/plugins help
# --insecure-cookies: local dev is over plain HTTP, and auth cookies are Secure by default.
# A strong JWT secret is auto-generated and persisted under the data dir on first run.
./zig-out/bin/plugins serve --insecure-cookies   # provisions authors/posts + runs the migration
# open http://127.0.0.1:8090/  — same-origin frontend, so no --realtime-origins needed
```

---

[View source on GitHub →](https://github.com/valthon/zigbase/tree/main/examples/plugins)
