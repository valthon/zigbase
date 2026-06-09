# ZigBase blog example

A minimal application built on **ZigBase as a library**. It imports the
`zigbase` module, then registers a single `before_create` record hook on the
`posts` collection that derives a URL `slug` from the post `title` when one
isn't supplied. Everything else (HTTP API, SQLite storage, auth, CLI) comes
straight from the framework.

This example exists primarily as a packaging proof: building it demonstrates
that the SQLite C sources and zap dependency travel transitively through the
published `zigbase` module into a downstream consumer package.

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
    const buf = try ev.app.allocator.alloc(u8, title.len);
    for (title, 0..) |ch, i| buf[i] = if (std.ascii.isAlphanumeric(ch)) std.ascii.toLower(ch) else '-';
    try ev.record.object.put(ev.app.allocator, "slug", .{ .string = buf });
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
