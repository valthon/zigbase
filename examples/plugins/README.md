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

3. **Comptime schema** via `.collections`. **Four** related collections:

   | Collection  | Type | Auth methods                   | Relations                           | Access rules |
   |-------------|------|-------------------------------|-------------------------------------|---|
   | `authors`   | auth | webauthn (passkey) + api_token | —                                   | list/view: public |

   `authors.private_notes` is an **encrypted-at-rest** field (`.encrypted = true`):
   stored AES-256-GCM-encrypted in SQLite, transparent plaintext to the API. It
   requires the `ZIGBASE_FIELD_KEY` env var (see Build & run) — the server refuses
   to start without it. Encrypted fields can't be indexed/`unique`/filtered/sorted.
   | `commenters`| auth | magic_link (auto_create=true)  | —                                   | list: public; view: authed |
   | `posts`     | base | —                              | `author → authors` (cascade-delete) | list: `status = "published"` |
   | `comments`  | base | —                              | `post → posts`, `commenter → commenters` | list/view: `approved=true`; create: authed |

4. **Explicit migrations** via `.migrations`. Two `zigbase.Migration` entries
   run once each (recorded in `_migrations`):
   - `0001_create_audit_log` — creates a `plugin_audit_log` side table outside
     the comptime-managed schema (the classic escape hatch).
   - `0002_index_audit_note` — a more realistic multi-statement migration:
     creates `idx_audit_note` on `plugin_audit_log` **and** seeds a metadata row
     in the same transaction. It targets the **migration-owned** table on
     purpose: the migration is demonstrating the escape-hatch pattern for
     non-additive DDL on tables the migration itself creates. For comptime-managed
     collections, use `.indexes = .{ ... }` in the collection spec instead —
     physical columns are named by their human field name (not an internal id),
     so `CREATE INDEX ... ON posts (status)` would work fine in a raw migration
     too. See the `authors` collection for a working `.indexes` example.

5. **`onError` handler** via `.onError`. Receives `*zigbase.ErrorEvent` with
   `.phase` (`.request` / `.before_hook` / `.after_hook` / `.cron` / `.job` /
   `.file_serve`) and `.message`. Logs a structured one-liner so operators can
   distinguish request errors from background-job failures.

6. **Cron job** (`audit-sweep`) via `.cron`. Fires every minute
   (`"* * * * *"`, UTC, 5-field numeric). Demonstrates the full ctx-first job
   DB-access pattern: collection reads use `ctx.records()` (the pooled reader is
   managed for you); raw SQL on the migration-owned `plugin_audit_log` table uses
   the pooled writer via `ctx.app.pool` (`acquireWriter` / `releaseWriter`), since
   it is not a comptime collection. Counts published posts, then INSERTs an audit
   row into `plugin_audit_log`.

7. **Pool levers** via `.pools` (`.readers` / `.jobs` / `.cache_kib`) to tune
   the warm-reader pool, scheduler worker count, and per-connection SQLite
   page-cache budget.

8. **Fully embedded static frontend** via `embedStaticDir`. The Astro + React
   build output in `frontend/dist` is compiled into the binary at build time via
   `.static_files = .{ .embedded = &@import("static_assets").files }` — there is
   no runtime dependency on the `frontend/dist` directory. The frontend shows
   authors, published posts, approved comments, and a magic-link comment flow.

9. **`onAuth` hook** via `.onAuth` — logs `collection + method` for every
   successful session mint. With two auth collections and three methods in use,
   the log shows the three distinct paths:
   ```
   [onAuth] collection=authors   method=webauthn   record=<id>
   [onAuth] collection=authors   method=custom     record=<id>
   [onAuth] collection=commenters method=magic_link record=<id>
   ```

10. **Custom `AuthMethod` plugin** (`ApiTokenMethod`) via `.auth_methods = .{ApiTokenMethod}`.
    Enabled on `authors` via `.auth.methods.custom = .{"api_token"}`. Implements the
    plugin contract `create(gpa, io, cfg) !Self` / `method(*Self) zigbase.AuthMethod` /
    `deinit(*Self) void`, using `zigbase.AuthCtx` helpers (`findByIdentity`, `rateLimit`,
    `reader`). Returns a `zigbase.Resolution` (`.record` or `.fail`).
    - Initiate: `POST /api/collections/authors/auth/api_token/initiate` → `{"flow":"direct"}`
    - Complete: `POST /api/collections/authors/auth/api_token/complete` with
      `{ "identity": "author@example.com", "token": "<bio-value>" }`

11. **Comptime `.indexes`** on `authors.contact_email` with `.collation = .nocase`
    (case-insensitive lookup). This demonstrates the correct tool for indexing
    comptime-managed collections — `.indexes` in the collection spec, because
    physical columns ARE named by their human field name (`contact_email`), not an
    internal id.

## Auth methods in this example

Three collections use four auth methods, all disambiguated by `onAuth`:

| Collection   | Method       | How it works |
|--------------|--------------|---|
| `authors`    | `webauthn`   | Passkey registration + authentication via browser WebAuthn API. See [WebAuthn endpoints](#webauthn-endpoints-passkeys-for-authors) below. |
| `authors`    | `api_token`  | Custom plugin: `POST .../auth/api_token/complete` with `{ "identity": "...", "token": "..." }`. Token is verified against the record's `bio` field (demo only — use a dedicated hashed-token field in production). |
| `commenters` | `magic_link` | `POST .../auth/magic_link/initiate` with `{ "identity": "..." }`. Server emails a link. Set `ZIGBASE_PUBLIC_URL` for a clickable URL; otherwise look in the server log for the raw token. Account auto-created on first login (`auto_create = true`). |

### WebAuthn endpoints (passkeys for authors)

```text
POST /api/collections/authors/auth/webauthn/register/begin     -- start registration
POST /api/collections/authors/auth/webauthn/register/finish    -- complete registration
POST /api/collections/authors/auth/webauthn/authenticate/begin   -- start login
POST /api/collections/authors/auth/webauthn/authenticate/finish  -- complete login, mint session
```

Building a full passkey UI requires `navigator.credentials.create()` / `.get()`, CBOR
encoding, and careful error handling — a substantial frontend project. The Zig/schema
wiring is complete; the UI implementation is left as a reader exercise. See the
[WebAuthn spec](https://www.w3.org/TR/webauthn-2/) and the `src/auth/webauthn/` directory.

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
four collections (`authors`, `commenters`, `posts`, `comments`). It does NOT
produce typed `rpc.*` methods — for that, use the comptime tier (see `examples/golfsim`).

**How it is verified here:** the e2e in `test/typegen.e2e.test.ts` starts the
plugins server to provision a data dir, then runs:

```sh
./zig-out/bin/plugins typegen --data-dir <provisioned dir> --out <tmp>/zbase.gen.ts
```

…and asserts the generated file contains `// generated by zigbase`, `createClient`,
and all collection names. Run it locally with:

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
# ZIGBASE_PUBLIC_URL makes magic-link emails contain a real clickable URL.
# In local dev the token also appears in the server log (look for "magic_link token=").
# ZIGBASE_FIELD_KEY is REQUIRED here because authors.private_notes is .encrypted —
# the server refuses to start without it. Use a strong, persistent value in prod
# (losing it makes the encrypted data unrecoverable); it is never auto-generated.
ZIGBASE_FIELD_KEY=dev-only-field-key \
ZIGBASE_PUBLIC_URL=http://localhost:8090 ./zig-out/bin/plugins serve --insecure-cookies
# open http://127.0.0.1:8090/  (admin UI at /_/)
```

### Rotating the field-encryption key (`zigbase rewrap`)

`ZIGBASE_FIELD_KEY` is the primary key (generation 1 by default). To rotate it without
losing access to data already written under the old key, keep the old key available as a
read-only older generation and run `rewrap` to re-encrypt every cell under the new key:

```sh
# 1. Restart writing under the new key (generation 2); old v1: rows still decrypt via _V1.
ZIGBASE_FIELD_KEY=new-strong-key ZIGBASE_FIELD_KEY_GENERATION=2 ZIGBASE_FIELD_KEY_V1=dev-only-field-key \
  ./zig-out/bin/plugins serve --insecure-cookies

# 2. Re-encrypt every v1: cell as v2: (idempotent, fail-closed; --dry-run reports counts only).
ZIGBASE_FIELD_KEY=new-strong-key ZIGBASE_FIELD_KEY_GENERATION=2 ZIGBASE_FIELD_KEY_V1=dev-only-field-key \
  ./zig-out/bin/plugins rewrap --data-dir ./zb_data
```

`ZIGBASE_FIELD_KEY_GENERATION` (1–64) is the generation stamped on new writes (the `v<N>:`
prefix); `ZIGBASE_FIELD_KEY_V<M>` supplies a read-only key for an older generation `M`. See
[docs/recipes.md](../../docs/recipes.md) ("encrypt a field at rest + key rotation") and
[docs/framework.md](../../docs/framework.md) for the full rotation playbook.

This demonstrates the **embedded** static-files mode: the Astro frontend is
compiled into the binary by `embedStaticDir` in `build.zig`. Delete
`frontend/dist` after building — the site still serves from the binary.
`--serve-static` is rejected as an unknown flag because the mode is
comptime-hardcoded. The other modes are shown by the blog (runtime flag) and
golfsim (hardcoded dir) examples.

The fact that this package **compiles against the published `zigbase` module**
is the proof that the documented plugin / schema / migration / cron / error
features are usable by an external consumer.
