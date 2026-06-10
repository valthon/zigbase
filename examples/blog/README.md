# ZigBase blog example

A minimal application built on **ZigBase as a library**. It imports the
`zigbase` module, then registers a single `before_create` record hook on the
`posts` collection that derives a URL `slug` from the post `title` when one
isn't supplied. Everything else (HTTP API, SQLite storage, auth, CLI) comes
straight from the framework.

This example exists primarily as a packaging proof: building it demonstrates
that the SQLite C sources and zap dependency travel transitively through the
published `zigbase` module into a downstream consumer package.

> **Pre-1.0:** ZigBase is pre-1.0 — the hook-config shape and module API may
> change between releases.

## The hook

```zig
const std = @import("std");
const zigbase = @import("zigbase");

fn slugify(ev: *zigbase.RecordEvent) anyerror!void {
    if (ev.record.* != .object) return;
    if (ev.record.object.get("slug") != null) return;
    const title = if (ev.record.object.get("title")) |t| switch (t) {
        .string => |s| s,
        else => return,
    } else return;

    // Record mutations MUST allocate with `ev.arena` (the request-scoped
    // allocator that owns `ev.record`), NOT `ev.app.allocator`.
    const buf = try ev.arena.alloc(u8, title.len);
    var len: usize = 0;
    var in_run = false;
    for (title) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            buf[len] = std.ascii.toLower(ch);
            len += 1;
            in_run = true;
        } else if (in_run) {
            buf[len] = '-';
            len += 1;
            in_run = false;
        }
    }
    if (len > 0 and buf[len - 1] == '-') len -= 1;
    try ev.record.object.put(ev.arena, "slug", .{ .string = buf[0..len] }); // "Hello, World!" -> "hello-world"
}

pub fn main(init: std.process.Init) !void {
    return zigbase.App(.{
        .hooks = .{ .posts = .{ .beforeCreate = slugify } },
    }).runCli(init);
}
```

## Using ZigBase in your own project

Add the dependency:

```sh
zig fetch --save git+https://github.com/<owner>/zigbase
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
./zig-out/bin/blog superuser create --email you@example.com --password <pw> --data-dir ./data
./zig-out/bin/blog serve --data-dir ./data
```

Then create a `posts` record without a `slug` and the hook fills it in from the
`title`.
