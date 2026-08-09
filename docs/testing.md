# Testing a ZigBase app

> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/testing> — the site is the canonical reading experience.

There are two ways to test an app built on ZigBase, and they cover different
things. Pick deliberately.

| Surface | What it exercises | Cost |
| --- | --- | --- |
| **`zigbase.testing`** (in-process, Zig) | The real router, access rules, auth, hooks, custom routes, migrations, provisioning | Milliseconds. No socket, no port, no background threads. |
| **A spawned server** (any language) | Everything above **plus** the HTTP server, TLS/proxying, CORS, WebSocket upgrades, static files, and your client SDK | Seconds. Needs a port and a binary. |

If you are writing a Zig app on ZigBase, `zigbase.testing` is the default and
most of your tests belong there. Reach for a spawned server for the things
in-process testing structurally cannot see.

## The build wiring (copy this)

`zigbase.addTest` gives you a test artifact wired with ZigBase's `.simple`-mode
test runner. That runner matters: `zig build test` otherwise runs the test
binary in server mode (`--listen=-`), and an app booted by the harness does
enough work at process exit that Zig 0.16's build runner can mis-read a normal
exit as a crash — printing `failed command: … --listen=-` and intermittently
failing the build. The `.simple` runner rides the exit code instead, and fails
the build on a leaked allocation.

```zig
const std = @import("std");
const zigbase = @import("zigbase"); // the dependency's build.zig

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("zigbase", .{ .target = target, .optimize = optimize });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigbase.addTo(dep, app_mod); // adds the import AND sets link_libc

    const exe = b.addExecutable(.{ .name = "myapp", .root_module = app_mod });
    b.installArtifact(exe);

    const tests = zigbase.addTest(b, dep, .{ .root_module = app_mod });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
```

Two things people get wrong here:

- **Reuse `app_mod` for the test artifact.** Rooting a second module at
  `src/main.zig` puts one file in two modules, which Zig rejects.
- **Your app must be reachable from a test.** An `App(.{...})` literal inlined
  into `main` is not. Hoist it:

  ```zig
  pub const App = zigbase.App(.{ /* … */ });

  pub fn main(init: std.process.Init) !void {
      return App.runCli(init);
  }
  ```

`zigbase init --framework` scaffolds all of this already.

## A worked test

```zig
test "the list rule hides drafts from the public" {
    var t = try zigbase.testing.start(App, .{}); // migrations run, onBootstrap fires
    defer t.deinit();                            // tears down the app + the tempdir

    _ = try t.createRecord("posts", .{ .title = "Draft", .published = false });
    _ = try t.createRecord("posts", .{ .title = "Live", .published = true });

    const r = try t.request(.GET, "/api/collections/posts/records", .{});
    try std.testing.expectEqual(@as(u16, 200), r.status);

    const page = try r.json(struct { items: []struct { title: []const u8 } });
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("Live", page.items[0].title);
}
```

Authenticating is two calls, and they are not equivalent:

```zig
// Real endpoint, full fidelity: rate limiter, argon2 verify, verification gate,
// and the beforeAuthSuccess/onAuth hooks all run.
const user = try t.loginPassword("users", "u@example.com", "hunter2xyz");

// Direct JWT mint: deterministic, no HTTP, none of the above runs.
const sess = try t.mintSession("users", user_id);

const r = try t.request(.POST, "/api/collections/users/auth-refresh", .{ .auth = user });
```

Use `loginPassword` when the login path is part of what you are testing, and
`mintSession` when you just need an authenticated caller.

Mail and the clock are seams too:

```zig
var t = try zigbase.testing.start(App, .{ .fake_now_unix = 1_800_000_000 });
defer t.deinit();
const mail = try t.captureMail(); // install BEFORE the request that sends
```

The complete API — every `StartOptions` field, every `request` option, the
`Response` accessors, seeding helpers, and encrypted-field apps — is in
[framework.md §15](framework.md#15-testing-your-app-zigbasetesting).

## What in-process tests do NOT cover

A green `zig build test` says nothing about:

- the HTTP server itself, TLS, or a reverse proxy in front of it;
- CORS and browser cookie behavior (including the `Secure` flag — see
  `--insecure-cookies`);
- WebSocket upgrades and realtime delivery over a socket;
- static-file serving and your frontend;
- your client SDK's wire handling.

Cover those with a spawned server. `examples/blog` does both and its README
says which is which.

## Testing without Zig

If ZigBase is a backend-in-a-box for you — no `build.zig` anywhere — the test
story is a real server and your own language's test runner:

```sh
zigbase serve --data-dir "$(mktemp -d)" --http-port 8099 --insecure-cookies &
# ... wait for GET /api/health, run your suite against http://127.0.0.1:8099 ...
```

Bind an unused port per suite and give each run its own data directory, or two
suites will fight over the database. The example harnesses under
`examples/*/test/harness.ts` are a working reference for the wait-for-health and
free-port dance.

## See also

- [framework.md §15](framework.md#15-testing-your-app-zigbasetesting) — the full `zigbase.testing` API
- [framework.md §14](framework.md#14-test--dev-mode-determinism-seams) — determinism seams for a spawned server (`ZIGBASE_FAKE_NOW`, `ZIGBASE_FAKE_SEED`, `zigbase.testcapture`)
- [recipes.md](recipes.md) — task-oriented recipes, including a deterministic-test recipe
