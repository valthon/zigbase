# ZigBase blog example

A minimal real-world application built on **ZigBase as a library**. It imports
the `zigbase` module, declares a comptime schema, and registers record hooks and
a custom route — everything else (HTTP API, SQLite storage, auth, realtime,
CLI) comes straight from the framework.

This example is also a packaging proof: building it demonstrates that the SQLite
C sources and zap dependency travel transitively through the published `zigbase`
module into a downstream consumer package.

> **Pre-1.0:** ZigBase is pre-1.0 — the hook-config shape and module API may
> change between releases.

## What the blog example demonstrates

| ZigBase feature | How it's used |
|---|---|
| Comptime schema | `users` (auth) + `posts` with 7 fields, provisioned on startup |
| `beforeCreate` hook | `slugify` — derives URL slug from title |
| `beforeCreate` hook | `setAuthor` — stamps author from auth identity |
| `beforeCreate` + `beforeUpdate` hook | `computeReadingTime` — words/200, min 1 |
| Relation field | `author` → `users` with `maxSelect = 1` |
| Autodate field | `updated_at` stamped on create and every update |
| Access rules | Author-scoped update/delete (`@request.auth.id = author`) |
| Custom route | `GET /api/blog/posts/:slug` returns one published post |
| Cron job | Hourly heartbeat log (background scheduling demo) |
| Realtime WebSocket | `PostList` subscribes to live post create/update/delete events |
| Static-files mode | `--serve-static frontend/dist` serves the Astro build |
| Pagination config | `.pagination = .{ .cursor_token = .signed }` — HMAC-signed cursor tokens for the post feed (offset still on) |

## Schema

```zig
.posts = .{
    .fields = .{
        .{ .name = "title",        .type = .text,     .required = true, .max = 200 },
        .{ .name = "slug",         .type = .text,     .max = 220 },
        .{ .name = "body",         .type = .text,     .max = 20000 },
        .{ .name = "status",       .type = .select,   .values = .{ "draft", "published" } },
        .{ .name = "author",       .type = .relation, .target = "users", .maxSelect = 1 },
        .{ .name = "updated_at",   .type = .autodate, .onCreate = true, .onUpdate = true },
        .{ .name = "reading_time", .type = .number,   .mode = .int },
    },
    .rules = .{
        .list   = "status = 'published'",
        .view   = "status = 'published'",
        .create = "@request.auth.id != ''",
        .update = "@request.auth.id = author",
        .delete = "@request.auth.id = author",
    },
},
```

## Hooks

The framework accepts one handler per phase. Multiple hooks are composed in a
chain function:

```zig
/// beforeCreate chain: slugify -> setAuthor -> computeReadingTime
fn postsBeforeCreate(ev: *zigbase.RecordEvent) anyerror!void {
    try slugify(ev);
    try setAuthor(ev);
    try computeReadingTime(ev);
}
```

**Allocator discipline**: hook mutations MUST use `ev.arena` (the
request-scoped allocator that owns `ev.record`). Using `ev.app.allocator` (the
long-lived GPA) produces undefined behavior.

### `slugify` (beforeCreate)
Derives a URL slug from the post title when one isn't supplied.
`"Hello, World!"` → `"hello-world"`.

### `setAuthor` (beforeCreate)
Stamps the `author` field with the authenticated user's id from `ev.ctx.auth`.
Creates the ownership link that the access rules rely on.

### `computeReadingTime` (beforeCreate + beforeUpdate)
Counts words in `body`, computes `ceil(words / 200)`, minimum 1. Stored in
`reading_time` and displayed in the post list as "N min read".

## Custom route

```zig
fn getPostBySlug(ev: *zigbase.RouteEvent) anyerror!zigbase.http.Response {
    const slug = ev.ctx.param("slug") orelse return .{ .status = 404, .body = "..." };
    var r = try ev.reader();
    defer r.deinit();
    const result = try r.data().list("posts", .{
        .filter = try std.fmt.allocPrint(ev.ctx.allocator,
            "slug = '{s}' && status = 'published'", .{slug}),
        .perPage = 1,
    });
    if (result.items.len == 0) return .{ .status = 404, .body = "..." };
    const json = try std.json.Stringify.valueAlloc(ev.ctx.allocator, result.items[0], .{});
    return .{ .status = 200, .body = json };
}
```

Registered alongside the existing ping route:

```zig
.routes = .{
    .{ .method = .GET, .path = "/api/blog/ping",          .handler = ping,           .auth = .public },
    .{ .method = .GET, .path = "/api/blog/posts/:slug",   .handler = getPostBySlug,  .auth = .public },
},
```

## Realtime live-updating post list

`PostList.tsx` subscribes to `ws://<host>/api/realtime` on mount:

```ts
const unsub = subscribePosts((ev) => {
  if (ev.action === 'create') setPosts((prev) => [ev.record, ...prev!]);
  if (ev.action === 'update') setPosts((prev) => prev!.map(p => p.id === ev.record.id ? ev.record : p));
  if (ev.action === 'delete') setPosts((prev) => prev!.filter(p => p.id !== ev.record.id));
});
return unsub; // cleanup on unmount
```

New posts appear immediately without a page refresh.

## Using ZigBase in your own project

Add the dependency:

```sh
zig fetch --save git+https://github.com/valthon/zigbase
```

Wire the module into your `build.zig`:

```zig
const zigbase = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
exe_mod.addImport("zigbase", zigbase.module("zigbase"));
```

Your executable module must `.link_libc = true` (SQLite needs libc).

## Building and running this example

From `examples/blog/`:

```sh
mise exec zig@0.16.0 -- zig build           # produces ./zig-out/bin/blog
./zig-out/bin/blog superuser create --email you@example.com --password <pw> --data-dir ./zb_data
# --insecure-cookies: local dev over plain HTTP (auth cookies are Secure by default).
# A random JWT secret is generated + persisted at zb_data/.jwt_secret on first run.
./zig-out/bin/blog serve --insecure-cookies --data-dir ./zb_data
```

Then create a `posts` record without a `slug` and the hook fills it in from the
`title`; `reading_time` is computed from the `body` word count.

## Using the base TypeScript SDK (`@zigbase/client`)

This example demonstrates **Tier 1 — the base dynamic client**: address collections by
name (`zb.collection("posts")`), bring your own types. No code generation required.

Install:

```sh
npm install @zigbase/client
```

```ts
import { createClient } from "@zigbase/client";

const zb = createClient("http://127.0.0.1:8090");

// Sign up and authenticate against the `users` auth collection.
await zb.collection("users").create({
  email: "writer@example.com",
  password: "my-password",
  passwordConfirm: "my-password",
  name: "Ada",
});
await zb.collection("users").authWithPassword("writer@example.com", "my-password");

// Create a published post (the server hooks derive slug, author, and reading_time).
const post = await zb.collection("posts").create({
  title: "Hello from the base SDK",
  body: "Dynamic client, no codegen.",
  status: "published",
});

// List published posts.
const list = await zb.collection("posts").getList(1, 20, { filter: "status = 'published'" });

// Read, update, delete.
const one = await zb.collection("posts").getOne(post.id);
await zb.collection("posts").update(post.id, { title: "Edited title" });
await zb.collection("posts").delete(post.id);
```

For a fully-typed client, see golfsim (comptime-generated) and the
[TypeScript SDK docs](../../docs/typescript-sdk.md).

To run the committed e2e test:

```sh
mise exec node@24 -- npm install && npm run test:e2e
```

## Frontend (Astro + React islands)

`frontend/` is an Astro site with React islands: a public post list with live
updates, post detail, and a login + "write a post" island.

```sh
cd frontend && npm install && npm run build && cd ..
mise exec zig@0.16.0 -- zig build
# --insecure-cookies for plain-HTTP local dev. The frontend is served from this same
# binary, so the live post-list WebSocket is same-origin and allowed by default; only a
# separate-origin browser app needs --realtime-origins.
./zig-out/bin/blog serve --insecure-cookies \
  --data-dir ./zb_data --serve-static frontend/dist
# open http://127.0.0.1:8090/
```

This demonstrates ZigBase's **default static-files mode**: the binary serves
`frontend/dist` at the root path because you passed `--serve-static`. The other
modes (comptime-hardcoded dir, fully embedded) are shown by the golfsim and
plugins examples.
