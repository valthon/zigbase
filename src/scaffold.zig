//! `zigbase init` and `zigbase agents-md`: write a starting-point project, or just
//! the agent files, into a directory.
//!
//! Exclusive-create is the whole safety story. Every write goes through
//! `createFile(.{ .exclusive = true })`, so an existing file is REPORTED and left
//! byte-for-byte alone. There is no --force: a scaffolder that can overwrite is a
//! scaffolder an agent can lose work to.

const std = @import("std");
const agents_md = @import("scaffold/agents_md.zig");
const templates = @import("scaffold/templates.zig");
const entropy = @import("entropy.zig");

pub const Mode = agents_md.Mode;

pub const Outcome = enum { created, skipped };
pub const Entry = struct { path: []const u8, outcome: Outcome };

pub const Report = struct {
    entries: []const Entry,
    created: usize,
    skipped: usize,
};

pub const Options = struct {
    mode: Mode,
    dir: []const u8,
    /// Package/executable name. Defaults to `packageName(basename(dir))`.
    name: ?[]const u8 = null,
};

pub const AgentsOptions = struct {
    /// `null` infers from the directory (see `detectMode`).
    mode: ?Mode = null,
    dir: []const u8 = ".",
    to_stdout: bool = false,
};

/// Turn an arbitrary directory name into a legal, lowercase Zig identifier.
/// Non-alphanumerics collapse to `_`; a leading digit gets an `app_` prefix;
/// an empty result becomes `app`.
pub fn packageName(a: std.mem.Allocator, dir: []const u8) ![]u8 {
    const base = std.fs.path.basename(dir);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(a);
    var last_us = true; // suppresses a leading underscore
    for (base) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            try buf.append(a, lower);
            last_us = false;
        } else if (!last_us) {
            try buf.append(a, '_');
            last_us = true;
        }
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '_') _ = buf.pop();
    if (buf.items.len == 0) try buf.appendSlice(a, "app");
    if (std.ascii.isDigit(buf.items[0])) try buf.insertSlice(a, 0, "app_");
    return buf.toOwnedSlice(a);
}

/// build.zig.zon's fingerprint: `(crc32(name) << 32) | id`, where `id` is random
/// and may be neither 0 nor 0xffffffff. Verified against this repo's own manifest
/// (`.name = .zigbase`, `.fingerprint = 0x306d84a90c011454`, crc32("zigbase") ==
/// 0x306d84a9).
///
/// DEVIATION FROM BRIEF: the brief specified `fingerprint(name) u64`, sourcing the
/// id from `std.crypto.random` — which does not exist in Zig 0.16 (randomness moved
/// behind `std.Io`, same migration documented for the rest of this codebase; see
/// `src/entropy.zig` / `src/id.zig`, which already only ever draw randomness via an
/// `io: std.Io` parameter). There is no ambient/global RNG left to call from a
/// no-argument function. Threading `io` through here — and drawing bytes via
/// `entropy.fill` exactly like every other ID in this codebase — is the smallest
/// change that both compiles against the pinned toolchain and matches house
/// convention, so the call sites (including this file's own test) pass
/// `std.testing.io` / the caller's `io`.
pub fn fingerprint(io: std.Io, name: []const u8) u64 {
    var id: u32 = 0;
    while (id == 0 or id == 0xffff_ffff) {
        var buf: [4]u8 = undefined;
        entropy.fill(io, &buf);
        id = std.mem.readInt(u32, &buf, .little);
    }
    return (@as(u64, std.hash.Crc32.hash(name)) << 32) | id;
}

/// `framework` when the directory already carries a Zig package manifest.
pub fn detectMode(io: std.Io, dir: std.Io.Dir) Mode {
    _ = dir.statFile(io, "build.zig.zon", .{}) catch return .box;
    return .framework;
}

/// One exclusive write. Returns the outcome; never truncates, never partially writes
/// over an existing file.
/// NOTE (verified against Zig 0.16.0): `std.Io.File.Mode` and `File.default_mode` DO NOT
/// EXIST, and `Dir.CreateFileOptions` has no `mode` field — it carries only `read`,
/// `truncate`, `exclusive`, and lock options (`std/Io/Dir.zig:585`). Permission bits are
/// `std.Io.File.Permissions`, an `enum(std.posix.mode_t)` with `.fromMode(0o755)`
/// (`std/Io/File.zig:335`), applied AFTER creation via `Dir.setFilePermissions`
/// (`std/Io/Dir.zig:1959`). The repo already uses exactly this idiom at
/// `src/static_files.zig:1204`. So the execute bit is a second call, not a create flag.
fn writeOne(
    io: std.Io,
    root: std.Io.Dir,
    sub_path: []const u8,
    data: []const u8,
    perms: ?std.Io.File.Permissions,
) !Outcome {
    if (std.fs.path.dirname(sub_path)) |d| try root.createDirPath(io, d);
    var f = root.createFile(io, sub_path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => return .skipped,
        else => return err,
    };
    defer f.close(io);
    // A failing write/flush below would otherwise leave a truncated file that a LATER
    // run's exclusive-create sees as "already exists" and silently skips forever. Clean
    // it up so the next run gets a real retry instead of a permanently-poisoned file.
    errdefer root.deleteFile(io, sub_path) catch {};
    var buf: [4096]u8 = undefined;
    var w = f.writer(io, &buf);
    try w.interface.writeAll(data);
    try w.interface.flush();
    if (perms) |p| try root.setFilePermissions(io, sub_path, p, .{});
    return .created;
}

/// A file to emit. `data` is borrowed; owned buffers are freed by the caller.
const Planned = struct { path: []const u8, data: []const u8, perms: ?std.Io.File.Permissions = null };

fn emit(a: std.mem.Allocator, io: std.Io, dir: []const u8, planned: []const Planned) !Report {
    try std.Io.Dir.cwd().createDirPath(io, dir);
    var root = try std.Io.Dir.cwd().openDir(io, dir, .{});
    defer root.close(io);

    const entries = try a.alloc(Entry, planned.len);
    // `initialized` tracks how many leading slots of `entries` hold a real,
    // caller-owned `.path` dupe. On a mid-loop error only those need freeing —
    // freeing the bare `entries` array is not enough, since each `.path` is a
    // separate allocation the array does not own.
    var initialized: usize = 0;
    errdefer {
        for (entries[0..initialized]) |e| a.free(e.path);
        a.free(entries);
    }
    var created: usize = 0;
    var skipped: usize = 0;
    for (planned, 0..) |p, i| {
        const outcome = try writeOne(io, root, p.path, p.data, p.perms);
        entries[i] = .{ .path = try a.dupe(u8, p.path), .outcome = outcome };
        initialized = i + 1;
        switch (outcome) {
            .created => created += 1,
            .skipped => skipped += 1,
        }
    }
    return .{ .entries = entries, .created = created, .skipped = skipped };
}

pub fn freeReport(a: std.mem.Allocator, r: Report) void {
    for (r.entries) |e| a.free(e.path);
    a.free(r.entries);
}

pub fn run(a: std.mem.Allocator, io: std.Io, opts: Options) !Report {
    switch (opts.mode) {
        .box => return emit(a, io, opts.dir, &.{
            .{ .path = "docker-compose.yml", .data = templates.box_compose },
            .{ .path = "schema/collections.json", .data = templates.box_schema_json },
            .{ .path = "AGENTS.md", .data = agents_md.text(.box) },
            .{ .path = "CLAUDE.md", .data = agents_md.claude_md },
            .{ .path = ".gitignore", .data = templates.box_gitignore },
            .{ .path = "README.md", .data = templates.box_readme },
        }),
        .framework => {
            const name = if (opts.name) |n| try a.dupe(u8, n) else try packageName(a, opts.dir);
            defer a.free(name);
            const zon = try templates.frameworkBuildZigZon(a, name, fingerprint(io, name));
            defer a.free(zon);
            const main_zig = try templates.frameworkMainZig(a, name);
            defer a.free(main_zig);
            const build_zig = try std.mem.replaceOwned(u8, a, templates.framework_build_zig, "APP_NAME", name);
            defer a.free(build_zig);
            return emit(a, io, opts.dir, &.{
                .{ .path = "build.zig", .data = build_zig },
                .{ .path = "build.zig.zon", .data = zon },
                .{ .path = "src/main.zig", .data = main_zig },
                .{ .path = "AGENTS.md", .data = agents_md.text(.framework) },
                .{ .path = "CLAUDE.md", .data = agents_md.claude_md },
                .{ .path = ".gitignore", .data = templates.framework_gitignore },
                .{ .path = "README.md", .data = templates.framework_readme },
            });
        },
    }
}

pub fn agentsMd(a: std.mem.Allocator, io: std.Io, opts: AgentsOptions) !Report {
    const mode = opts.mode orelse blk: {
        var d = std.Io.Dir.cwd().openDir(io, opts.dir, .{}) catch break :blk Mode.box;
        defer d.close(io);
        break :blk detectMode(io, d);
    };
    const body = switch (mode) {
        .box => agents_md.text(.box),
        .framework => agents_md.text(.framework),
    };
    return emit(a, io, opts.dir, &.{
        .{ .path = "AGENTS.md", .data = body },
        .{ .path = "CLAUDE.md", .data = agents_md.claude_md },
    });
}

/// The `AGENTS.md` body for `mode`, for `--stdout`.
pub fn agentsMdText(mode: Mode) []const u8 {
    return switch (mode) {
        .box => agents_md.text(.box),
        .framework => agents_md.text(.framework),
    };
}

test "packageName sanitizes a directory name into a Zig identifier" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "myapp", "myapp" },
        .{ "my-app", "my_app" },
        .{ "My App 2", "my_app_2" },
        .{ "9lives", "app_9lives" },
        .{ "", "app" },
        .{ "...", "app" },
    };
    for (cases) |c| {
        const got = try packageName(a, c[0]);
        defer a.free(got);
        try std.testing.expectEqualStrings(c[1], got);
    }
}

test "fingerprint puts crc32(name) in the high half and a legal id in the low half" {
    const fp = fingerprint(std.testing.io, "zigbase");
    try std.testing.expectEqual(@as(u32, std.hash.Crc32.hash("zigbase")), @as(u32, @truncate(fp >> 32)));
    const id: u32 = @truncate(fp);
    try std.testing.expect(id != 0 and id != 0xffff_ffff);
}

test "run scaffolds box mode, and re-running skips every file instead of clobbering" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir);

    const first = try run(a, std.testing.io, .{ .mode = .box, .dir = dir });
    defer freeReport(a, first);
    try std.testing.expectEqual(@as(usize, 0), first.skipped);
    try std.testing.expect(first.created >= 6);

    // Prove a scaffolded file is real and non-empty.
    const compose = try tmp.dir.readFileAlloc(std.testing.io, "docker-compose.yml", a, .limited(64 * 1024));
    defer a.free(compose);
    try std.testing.expect(std.mem.indexOf(u8, compose, "ghcr.io/valthon/zigbase") != null);

    // Poison one file, re-run, and prove it survived untouched.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = "MINE\n" });
    const second = try run(a, std.testing.io, .{ .mode = .box, .dir = dir });
    defer freeReport(a, second);
    try std.testing.expectEqual(@as(usize, 0), second.created);
    try std.testing.expectEqual(first.created, second.skipped);

    const agents = try tmp.dir.readFileAlloc(std.testing.io, "AGENTS.md", a, .limited(1024));
    defer a.free(agents);
    try std.testing.expectEqualStrings("MINE\n", agents);
}

test "run scaffolds framework mode with a build.zig.zon naming the directory" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir);

    const rep = try run(a, std.testing.io, .{ .mode = .framework, .dir = dir, .name = "my_app" });
    defer freeReport(a, rep);

    const zon = try tmp.dir.readFileAlloc(std.testing.io, "build.zig.zon", a, .limited(8 * 1024));
    defer a.free(zon);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".name = .my_app,") != null);

    const main = try tmp.dir.readFileAlloc(std.testing.io, "src/main.zig", a, .limited(64 * 1024));
    defer a.free(main);
    try std.testing.expect(std.mem.indexOf(u8, main, "pub const App") != null);
}

test "detectMode reads build.zig.zon presence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectEqual(Mode.box, detectMode(std.testing.io, tmp.dir));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "build.zig.zon", .data = ".{}\n" });
    try std.testing.expectEqual(Mode.framework, detectMode(std.testing.io, tmp.dir));
}

test "agentsMd writes only the two agent files" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(dir);

    const rep = try agentsMd(a, std.testing.io, .{ .dir = dir });
    defer freeReport(a, rep);
    try std.testing.expectEqual(@as(usize, 2), rep.created);
    try std.testing.expectEqualStrings("AGENTS.md", rep.entries[0].path);
    try std.testing.expectEqualStrings("CLAUDE.md", rep.entries[1].path);
}
