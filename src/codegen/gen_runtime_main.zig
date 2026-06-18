//! Build-time tool: provision the `app` fixture's collections into a temp
//! in-memory db, read them back through the runtime data-dir adapter, and
//! generate/check the runtime golden. Proves the committed runtime client is
//! a true product of the data-dir acquisition path (not a hand copy).
//!
//! Imports only `zigbase` (the module) and `app` (the dating fixture module),
//! so all shared source files remain owned by `zigbase` — avoiding the Zig 0.16
//! "file in two modules" constraint.
const std = @import("std");
const zigbase = @import("zigbase");
const app = @import("app");

const typegen_cli = zigbase.codegen.typegen_cli;

const Args = struct {
    out: ?[]const u8 = null,
    check: bool = false,
    api_prefix: []const u8 = "/api",
};

pub fn main(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const argv = try init.minimal.args.toSlice(a);
    var args = Args{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            if (i >= argv.len) return error.MissingOut;
            args.out = argv[i];
        } else if (std.mem.eql(u8, arg, "--api-prefix")) {
            i += 1;
            if (i >= argv.len) return error.MissingApiPrefix;
            args.api_prefix = argv[i];
        } else if (std.mem.eql(u8, arg, "--check")) {
            args.check = true;
        }
    }
    const out = args.out orelse return error.MissingOut;

    const in_repo = init.environ_map.contains("ZBASE_INREPO");
    const text = try typegen_cli.provisionAndGenerate(a, init.io, app.App.collections, in_repo, "ZbClient", args.api_prefix);
    try typegen_cli.checkOrWrite(init.io, out, text, args.check);
}
