const std = @import("std");
const schema = @import("../schema.zig");
const db = @import("../db.zig");
const migrations = @import("../migrations.zig");
const provision = @import("../provision.zig");
const events = @import("../events.zig");
const gen_client = @import("gen_client.zig");
const acquire = @import("acquire.zig");
const acquire_datadir = @import("acquire_datadir.zig");
const acquire_http = @import("acquire_http.zig");

/// Provision `cols` into a fresh in-memory db, acquire them back through the
/// runtime data-dir adapter, and generate the typed TS client.
/// Intended for build-time generator tools that need the full runtime path
/// without touching a real data directory.
pub fn provisionAndGenerate(
    alloc: std.mem.Allocator,
    io: std.Io,
    cols: []const schema.Collection,
    in_repo: bool,
    client_name: []const u8,
    api_prefix: []const u8,
) ![]const u8 {
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try provision.applySpecs(alloc, io, &d, cols);
    const rt = try acquire_datadir.acquireFromDb(alloc, &d);
    return gen_client.generate(alloc, rt, &.{}, in_repo, authCollectionName(rt), client_name, api_prefix);
}

pub const Options = struct {
    data_dir: ?[]const u8 = null,
    url: ?[]const u8 = null,
    out: []const u8,
    api_prefix: []const u8 = "/api",
    client_name: []const u8 = "ZbClient",
    check: bool = false,
    in_repo: bool = false,
    admin_email: ?[]const u8 = null,
    admin_password: ?[]const u8 = null,
};

/// First auth collection's name (mirrors gen_client's private helper; computed
/// inline so gen_client stays untouched).
pub fn authCollectionName(cols: []const schema.Collection) []const u8 {
    for (cols) |c| if (c.type == .auth) return c.name;
    return "";
}

/// Pure content comparison: returns error.Stale if `existing` != `text`, no I/O or logging.
/// Call this from tests to exercise the stale-detection logic without triggering
/// std.log.err (which the Zig test runner counts as a failure).
pub fn checkContent(existing: []const u8, text: []const u8) error{Stale}!void {
    if (!std.mem.eql(u8, existing, text)) return error.Stale;
}

/// Write `text` to `out_path`, or (when check) compare and error on drift.
pub fn checkOrWrite(io: std.Io, out_path: []const u8, text: []const u8, check: bool) !void {
    if (check) {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const existing = std.Io.Dir.cwd().readFileAlloc(io, out_path, arena.allocator(), .limited(64 * 1024 * 1024)) catch |e| {
            std.log.err("typegen --check: cannot read '{s}': {s}", .{ out_path, @errorName(e) });
            return error.CheckReadFailed;
        };
        checkContent(existing, text) catch {
            std.log.err("typegen --check: '{s}' is STALE — re-run typegen to regenerate.", .{out_path});
            return error.Stale;
        };
        return;
    }
    if (std.fs.path.dirname(out_path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = text });
    std.log.info("typegen: wrote {s} ({d} bytes)", .{ out_path, text.len });
}

/// Orchestrate: acquire collections from the selected source, generate the
/// client, then write or check.
pub fn run(alloc: std.mem.Allocator, io: std.Io, opts: Options) !void {
    if ((opts.data_dir == null) == (opts.url == null)) {
        std.log.err("typegen: pass exactly one of --data-dir or --url", .{});
        return error.BadSource;
    }
    const cols = if (opts.data_dir) |dir|
        try acquire_datadir.acquire(alloc, dir)
    else
        try acquireHttp(alloc, io, opts); // implemented in Task 4

    const text = gen_client.generate(alloc, cols, &.{}, opts.in_repo, authCollectionName(cols), opts.client_name, opts.api_prefix) catch |e| {
        std.log.err("typegen: code generation failed: {s}", .{@errorName(e)});
        return e;
    };
    try checkOrWrite(io, opts.out, text, opts.check);
}

fn acquireHttp(alloc: std.mem.Allocator, io: std.Io, opts: Options) ![]schema.Collection {
    const email = opts.admin_email orelse {
        std.log.err("typegen: --url requires --admin-email", .{});
        return error.MissingAdminEmail;
    };
    const password = opts.admin_password orelse {
        std.log.err("typegen: --url requires --admin-password", .{});
        return error.MissingAdminPassword;
    };
    return acquire_http.acquire(alloc, io, opts.url.?, email, password);
}

test "equivalence: data-dir runtime path reproduces the comptime collection surface" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A representative app: auth + base + relation + number-mode + select + file.
    const specs = [_]schema.Collection{
        .{ .id = "", .name = "users", .type = .auth, .fields = &.{
            .{ .id = "", .name = "displayName", .options = .{ .text = .{} } },
        } },
        .{ .id = "", .name = "posts", .fields = &.{
            .{ .id = "", .name = "title", .options = .{ .text = .{} } },
            .{ .id = "", .name = "rank", .options = .{ .number = .{ .mode = .int } } },
            .{ .id = "", .name = "author", .options = .{ .relation = .{ .targetCollectionId = "users" } } },
            .{ .id = "", .name = "status", .options = .{ .select = .{ .values = &.{ "draft", "published" }, .maxSelect = 1 } } },
            .{ .id = "", .name = "cover", .options = .{ .file = .{ .maxSelect = 1 } } },
        } },
    };

    // Runtime path: provision -> read back -> sort.
    var d = try db.Db.openMemory();
    defer d.close();
    try migrations.run(&d);
    try provision.applySpecs(a, std.testing.io, &d, &specs);
    const rt_cols = try acquire_datadir.acquireFromDb(a, &d);

    // Comptime baseline: the same user-field specs, name-sorted.
    const ct_cols = try a.dupe(schema.Collection, &specs);
    acquire.sortByName(ct_cols);

    const rt = try gen_client.generate(a, rt_cols, &.{}, true, authCollectionName(rt_cols), "ZbClient", "/api");
    const ct = try gen_client.generate(a, ct_cols, &.{}, true, authCollectionName(ct_cols), "ZbClient", "/api");
    try std.testing.expectEqualStrings(ct, rt);
}

test "checkContent: match passes, mismatch returns Stale (no logging)" {
    // Pure helper — safe to call in tests because it never emits std.log.err.
    try checkContent("hello", "hello");
    try std.testing.expectError(error.Stale, checkContent("hello", "changed"));
}

test "checkOrWrite: write path creates file" {
    // Only covers the write (check=false) path to avoid triggering std.log.err
    // from the Stale/CheckReadFailed branches (which the Zig test runner counts
    // as failures). Stale detection is covered by the checkContent test above.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    const dir = try std.fmt.allocPrint(a, "zig-cache/typegen-test-{d}", .{std.testing.random_seed});
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    const path = try std.fmt.allocPrint(a, "{s}/out.ts", .{dir});

    try checkOrWrite(io, path, "hello", false); // writes
    // Verify the file was written by reading it back with the std.testing.io.
    const readback = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024));
    try std.testing.expectEqualStrings("hello", readback);
}
