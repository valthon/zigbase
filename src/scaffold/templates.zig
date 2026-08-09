//! File bodies emitted by `zigbase init`. `AGENTS.md`/`CLAUDE.md` live next door in
//! agents_md.zig; everything else is here.
//!
//! Rule for this file: a template must WORK against the shipped binary. No
//! aspirational commands, no flags from an unreleased sub-project.

const std = @import("std");

pub const box_compose =
    \\# Local ZigBase server. See https://valthon.github.io/zigbase/docs/docker
    \\services:
    \\  zigbase:
    \\    image: ghcr.io/valthon/zigbase:latest
    \\    restart: unless-stopped
    \\    ports:
    \\      - "8090:8090"
    \\    volumes:
    \\      - zigbase_data:/data
    \\      # Read-only: schema/collections.json is applied with `zigbase schema
    \\      # apply`, not written to, so no chown dance is needed for this one.
    \\      - ./schema:/schema:ro
    \\    environment:
    \\      # Plain-HTTP local use only — auth cookies are Secure by default and a
    \\      # browser on http://127.0.0.1 will silently refuse to store them.
    \\      # Remove this once you are behind TLS.
    \\      ZIGBASE_COOKIE_SECURE: "false"
    \\    healthcheck:
    \\      # The image is distroless (no shell, no curl), so the liveness probe runs
    \\      # the binary itself rather than curling /api/health.
    \\      test: ["CMD", "/zigbase", "version"]
    \\      interval: 30s
    \\      timeout: 5s
    \\      retries: 3
    \\
    \\volumes:
    \\  zigbase_data:
    \\
;

/// Starting-point schema document for `zigbase schema apply` (see AGENTS.md and
/// docs/migration-tools.md §2). Deliberately shows all three rule shapes: `@public`,
/// an owner-scoped expression, and an omitted (= locked) rule.
///
/// Every field carries `"id": ""` (required key on input — `schema.parseCollectionInput`
/// rejects an object with the key entirely absent) and the server assigns the real
/// stable id when it sees an empty one (`collections.create`). The `author` relation's
/// `targetCollectionId` is set to the target collection's NAME ("users") rather than an
/// id nobody can know ahead of time — `collections.get`'s lookup is `id = ?1 OR name =
/// ?1`, so a name resolves exactly like an id. `apply` topologically sorts the document
/// itself (with cycle detection), so collection order in this array does not matter.
pub const box_schema_json =
    \\{
    \\  "zigbaseSchema": 1,
    \\  "collections": [
    \\    {
    \\      "name": "users",
    \\      "type": "auth",
    \\      "fields": [
    \\        { "id": "", "name": "name", "type": "text", "options": { "max": 100 } }
    \\      ],
    \\      "listRule": "@public",
    \\      "viewRule": "@public",
    \\      "createRule": "@public",
    \\      "updateRule": "@request.auth.id = id",
    \\      "deleteRule": "@request.auth.id = id"
    \\    },
    \\    {
    \\      "name": "posts",
    \\      "type": "base",
    \\      "fields": [
    \\        { "id": "", "name": "title", "type": "text", "options": { "max": 200 } },
    \\        { "id": "", "name": "body", "type": "editor", "options": {} },
    \\        { "id": "", "name": "published", "type": "bool", "options": {} },
    \\        { "id": "", "name": "author", "type": "relation", "options": { "targetCollectionId": "users", "maxSelect": 1 } }
    \\      ],
    \\      "listRule": "published = true",
    \\      "viewRule": "published = true",
    \\      "createRule": "@request.auth.id != ''",
    \\      "updateRule": "@request.auth.id = author",
    \\      "deleteRule": "@request.auth.id = author"
    \\    }
    \\  ]
    \\}
    \\
;

pub const box_gitignore =
    \\zb_data/
    \\*.db
    \\*.db-wal
    \\*.db-shm
    \\.env
    \\
;

pub const box_readme =
    \\# Backend
    \\
    \\A [ZigBase](https://github.com/valthon/zigbase) backend — REST + WebSocket +
    \\an admin UI, one binary. No Zig toolchain required.
    \\
    \\## Run it
    \\
    \\```sh
    \\docker compose up -d
    \\docker compose exec zigbase /zigbase superuser create \
    \\  --email you@example.com --password 'change-me-please' --data-dir /data
    \\```
    \\
    \\Admin UI: <http://127.0.0.1:8090/_/>. API: <http://127.0.0.1:8090/api/>.
    \\
    \\## Apply the starting schema
    \\
    \\```sh
    \\docker compose exec zigbase /zigbase schema apply /schema/collections.json
    \\```
    \\
    \\Idempotent — re-applying an already-applied document reports `applied: []`.
    \\`schema/collections.json` (bind-mounted read-only at `/schema`) is the source
    \\of truth for a fresh environment. If you change the schema through the admin
    \\UI, update that file too — and if a server is already running against this
    \\data dir, restart it afterward (see AGENTS.md).
    \\
    \\## Talk to it from a frontend
    \\
    \\```sh
    \\npm install @zigbase/client
    \\```
    \\
    \\```js
    \\import { createClient } from "@zigbase/client";
    \\
    \\const zb = createClient("http://127.0.0.1:8090");
    \\await zb.collection("users").authWithPassword("you@example.com", "…");
    \\const { items } = await zb.collection("posts").getList(1, 20, { filter: "published = true" });
    \\```
    \\
    \\SDKs also exist for Python, Dart, and Kotlin — see
    \\<https://valthon.github.io/zigbase/docs/agents>.
    \\
    \\## Before you ship
    \\
    \\Read `AGENTS.md`. The short version: blank access rules mean *locked*, not
    \\*public*; drop `ZIGBASE_COOKIE_SECURE=false` once you are behind TLS; and the
    \\data volume holds `.jwt_secret`, so losing it logs everyone out.
    \\
;

pub const framework_build_zig =
    \\const std = @import("std");
    \\// The dependency's own build.zig — this is where addTo/addTest come from.
    \\const zigbase = @import("zigbase");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    const dep = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
    \\
    \\    const app_mod = b.createModule(.{
    \\        .root_source_file = b.path("src/main.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\    // Adds the "zigbase" import AND links libc, which ZigBase requires (it
    \\    // carries the SQLite C amalgamation and zap). Doing this by hand and
    \\    // forgetting to link libc is the classic first-build failure.
    \\    zigbase.addTo(dep, app_mod);
    \\
    \\    const exe = b.addExecutable(.{ .name = "APP_NAME", .root_module = app_mod });
    \\    b.installArtifact(exe);
    \\
    \\    const run = b.addRunArtifact(exe);
    \\    run.step.dependOn(b.getInstallStep());
    \\    if (b.args) |args| run.addArgs(args);
    \\    b.step("run", "Run the server").dependOn(&run.step);
    \\
    \\    // `zig build test` — in-process tests through the real router, rules, auth,
    \\    // and hooks (zigbase.testing). The test artifact reuses app_mod on purpose:
    \\    // rooting a second module at src/main.zig would put one file in two modules.
    \\    const tests = zigbase.addTest(b, dep, .{ .root_module = app_mod });
    \\    const run_tests = b.addRunArtifact(tests);
    \\    b.step("test", "Run the app's tests").dependOn(&run_tests.step);
    \\}
    \\
;

pub const framework_gitignore =
    \\.zig-cache/
    \\zig-out/
    \\zb_data/
    \\*.db
    \\*.db-wal
    \\*.db-shm
    \\.env
    \\
;

pub const framework_readme =
    \\# Backend
    \\
    \\A [ZigBase](https://github.com/valthon/zigbase) app: ZigBase is the server, and
    \\this package adds the schema, hooks, and routes on top of it.
    \\
    \\## First run
    \\
    \\```sh
    \\zig fetch --save git+https://github.com/valthon/zigbase
    \\zig build test
    \\zig build run -- superuser create --email you@example.com --password 'change-me-please'
    \\zig build run -- serve --insecure-cookies
    \\```
    \\
    \\`zig fetch --save` is what writes the `zigbase` dependency (URL **and** the
    \\content hash) into `build.zig.zon`. Do not hand-write it.
    \\
    \\Admin UI: <http://127.0.0.1:8090/_/>. The Zig toolchain is pinned to 0.16.0.
    \\
    \\## Where things go
    \\
    \\Everything is in `src/main.zig`: the comptime schema, hooks, custom routes, and
    \\the tests. Split it up when it stops fitting.
    \\
    \\## Before you ship
    \\
    \\Read `AGENTS.md`. The short version: blank access rules mean *locked*, not
    \\*public*; schema provisioning is additive only, so renames and drops need a
    \\migration; and a green `zig build test` says nothing about the socket layer.
    \\
    \\Full framework reference: <https://valthon.github.io/zigbase/docs/framework>.
    \\
;

/// `build.zig.zon` with no dependency block — `zig fetch --save` writes that, with
/// the correct hash. `fingerprint` is minted by the caller (see scaffold.zig).
pub fn frameworkBuildZigZon(a: std.mem.Allocator, name: []const u8, fingerprint: u64) ![]u8 {
    return std.fmt.allocPrint(a,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.0.0",
        \\    .fingerprint = 0x{x:0>16},
        \\    .minimum_zig_version = "0.16.0",
        \\    // Run: zig fetch --save git+https://github.com/valthon/zigbase
        \\    // It writes the URL and the content hash here. Never hand-write either,
        \\    // and never use a relative `.path` — that only works inside the zigbase
        \\    // repo's own examples.
        \\    .dependencies = .{{}},
        \\    .paths = .{{ "build.zig", "build.zig.zon", "src" }},
        \\}}
        \\
    , .{ name, fingerprint });
}

/// The whole app. `App` is a `pub const` so the test block can reach it — an
/// `App(.{...})` literal inlined into `main` cannot be tested.
pub fn frameworkMainZig(a: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a,
        \\const std = @import("std");
        \\const zigbase = @import("zigbase");
        \\
        \\// Structured logging: routes std.log through the same encoder request logs use
        \\// (--log-format json / --log-level). std_options is resolved from the root
        \\// source file, so ZigBase cannot set this for you — every consumer needs it.
        \\pub const std_options = zigbase.std_options;
        \\
        \\/// The application. Every access rule below is explicit: a blank or missing
        \\/// rule means SUPERUSERS ONLY, and "@public" is the only allow-all value.
        \\pub const App = zigbase.App(.{{
        \\    .collections = .{{
        \\        .users = .{{
        \\            .type = .auth,
        \\            .fields = .{{
        \\                .{{ .name = "name", .type = .text, .max = 100 }},
        \\            }},
        \\            .rules = .{{
        \\                .list = "@public",
        \\                .view = "@public",
        \\                .create = "@public",
        \\                .update = "@request.auth.id = id",
        \\                .delete = "@request.auth.id = id",
        \\            }},
        \\        }},
        \\        .posts = .{{
        \\            .fields = .{{
        \\                .{{ .name = "title", .type = .text, .required = true, .max = 200 }},
        \\                .{{ .name = "body", .type = .editor }},
        \\                .{{ .name = "published", .type = .bool }},
        \\                .{{ .name = "author", .type = .relation, .target = "users", .maxSelect = 1 }},
        \\            }},
        \\            .rules = .{{
        \\                .list = "published = true",
        \\                .view = "published = true",
        \\                .create = "@request.auth.id != ''",
        \\                .update = "@request.auth.id = author",
        \\                .delete = "@request.auth.id = author",
        \\            }},
        \\        }},
        \\    }},
        \\}});
        \\
        \\pub fn main(init: std.process.Init) !void {{
        \\    return App.runCli(init);
        \\}}
        \\
        \\// ---------------------------------------------------------------------------
        \\// Tests. `zigbase.testing` boots {s} in-process against a throwaway data dir
        \\// and injects requests through the REAL router, access rules, auth, and hooks
        \\// — no socket, no port. Run with `zig build test`.
        \\
        \\test "an unpublished post is invisible to the public list" {{
        \\    var t = try zigbase.testing.start(App, .{{}});
        \\    defer t.deinit();
        \\
        \\    _ = try t.createRecord("posts", .{{ .title = "draft", .published = false }});
        \\
        \\    const r = try t.request(.GET, "/api/collections/posts/records", .{{}});
        \\    try std.testing.expectEqual(@as(u16, 200), r.status);
        \\    const page = try r.json(struct {{ items: []struct {{ title: []const u8 }} }});
        \\    try std.testing.expectEqual(@as(usize, 0), page.items.len);
        \\}}
        \\
        \\test "creating a post requires authentication" {{
        \\    var t = try zigbase.testing.start(App, .{{}});
        \\    defer t.deinit();
        \\
        \\    const anon = try t.request(.POST, "/api/collections/posts/records", .{{
        \\        .json = .{{ .title = "hello" }},
        \\    }});
        \\    try std.testing.expect(anon.status == 401 or anon.status == 403);
        \\
        \\    _ = try t.createRecord("users", .{{ .email = "u@example.com", .password = "hunter2xyz" }});
        \\    const token = try t.loginPassword("users", "u@example.com", "hunter2xyz");
        \\
        \\    const authed = try t.request(.POST, "/api/collections/posts/records", .{{
        \\        .json = .{{ .title = "hello" }},
        \\        .auth = token,
        \\    }});
        \\    try std.testing.expectEqual(@as(u16, 201), authed.status);
        \\}}
        \\
    , .{name});
}

test "framework build.zig teaches addTo/addTest and never .path" {
    try std.testing.expect(std.mem.indexOf(u8, framework_build_zig, "zigbase.addTo(dep, app_mod)") != null);
    try std.testing.expect(std.mem.indexOf(u8, framework_build_zig, "zigbase.addTest(b, dep") != null);
    try std.testing.expect(std.mem.indexOf(u8, framework_build_zig, ".path = \"..") == null);
    // link_libc is set BY the helper, so the template must not also set it by hand.
    try std.testing.expect(std.mem.indexOf(u8, framework_build_zig, "link_libc") == null);
}

test "build.zig.zon is rendered with the package name and fingerprint, and has no dependency block" {
    const a = std.testing.allocator;
    const zon = try frameworkBuildZigZon(a, "my_app", 0xdead_beef_0000_0001);
    defer a.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".name = .my_app,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".fingerprint = 0xdeadbeef00000001,") != null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".minimum_zig_version = \"0.16.0\"") != null);
    // The dependency is written by `zig fetch --save`, never by us: we cannot know
    // the package hash, and a hand-written one goes stale silently.
    try std.testing.expect(std.mem.indexOf(u8, zon, "zigbase = .{") == null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".dependencies = .{},") != null);
}

test "main.zig names the executable and exposes App for tests" {
    const a = std.testing.allocator;
    const main = try frameworkMainZig(a, "my_app");
    defer a.free(main);
    try std.testing.expect(std.mem.indexOf(u8, main, "pub const App = zigbase.App(.{") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "return App.runCli(init);") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "zigbase.testing.start(App, .{})") != null);
    try std.testing.expect(std.mem.indexOf(u8, main, "my_app") != null);
    // Required for --log-format json / --log-level to also cover the consumer's own
    // std.log calls — std_options is resolved from the root source file, so ZigBase
    // cannot set it on the consumer's behalf.
    try std.testing.expect(std.mem.indexOf(u8, main, "pub const std_options = zigbase.std_options;") != null);
}

test "box schema is a zigbaseSchema envelope and locks nothing open by accident" {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, box_schema_json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(@as(i64, 1), parsed.value.object.get("zigbaseSchema").?.integer);
    const collections = parsed.value.object.get("collections").?;
    try std.testing.expect(collections == .array);
    for (collections.array.items) |c| {
        try std.testing.expect(c.object.get("name") != null);
        try std.testing.expect(c.object.get("fields") != null);
        // Every rule that is present is either @public or an expression — never "".
        for ([_][]const u8{ "listRule", "viewRule", "createRule", "updateRule", "deleteRule" }) |k| {
            if (c.object.get(k)) |v| {
                if (v == .string) try std.testing.expect(v.string.len > 0);
            }
        }
    }
}

test "gitignores cover the state that must never be committed" {
    for ([_][]const u8{ box_gitignore, framework_gitignore }) |gi| {
        try std.testing.expect(std.mem.indexOf(u8, gi, "zb_data/") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, framework_gitignore, ".zig-cache/") != null);
    try std.testing.expect(std.mem.indexOf(u8, framework_gitignore, "zig-out/") != null);
}

test "no template names a command the binary does not have" {
    // Same "named implies exists" invariant as agents_md.zig's own scan (see
    // findUnknownCommand there), applied to every file `zigbase init` scaffolds —
    // those are unguarded by the AGENTS.md-only scan.
    const agents_md = @import("agents_md.zig");
    const templates = [_][]const u8{
        box_compose,         box_schema_json,  box_gitignore,       box_readme,
        framework_gitignore, framework_readme, framework_build_zig,
    };
    for (templates) |tpl| {
        if (agents_md.findUnknownCommand(tpl)) |bad| {
            std.debug.print("template names unknown command '{s}'\n", .{bad});
            try std.testing.expect(false);
        }
    }

    // The two templates above are baked-in `const`s; `frameworkBuildZigZon` and
    // `frameworkMainZig` instead build their text via `std.fmt.allocPrint` at
    // scaffold time, so an unknown command hiding in THEIR format string would slip
    // past a scan of only the static consts. Render both and scan the output too.
    const a = std.testing.allocator;
    const zon = try frameworkBuildZigZon(a, "probe_name", 0x1234567890abcdef);
    defer a.free(zon);
    const main_zig = try frameworkMainZig(a, "probe_name");
    defer a.free(main_zig);
    const rendered = [_][]const u8{ zon, main_zig };
    for (rendered) |tpl| {
        if (agents_md.findUnknownCommand(tpl)) |bad| {
            std.debug.print("rendered template names unknown command '{s}'\n", .{bad});
            try std.testing.expect(false);
        }
    }
}
