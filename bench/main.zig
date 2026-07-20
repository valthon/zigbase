const std = @import("std");
const harness = @import("harness.zig");
const zigbase = @import("zigbase");
const jwt = zigbase.jwt;
const crypto = zigbase.crypto;

fn benchNoop(_: void, a: std.mem.Allocator) anyerror!void {
    const b = try a.alloc(u8, 16);
    defer a.free(b);
}

const JwtCtx = struct { key: [32]u8, token: []const u8 };

fn benchJwtSign(c: JwtCtx, a: std.mem.Allocator) anyerror!void {
    const claims = jwt.Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 9999999999 };
    const t = try jwt.sign(a, claims, &c.key);
    defer a.free(t);
}

fn benchJwtVerify(c: JwtCtx, _: std.mem.Allocator) anyerror!void {
    var scratch: [jwt.scratch_size]u8 = undefined;
    _ = try jwt.verifyInto(&scratch, c.token, &c.key, 2000);
}

/// Zig 0.16 entry point: argv comes from `init.minimal.args` (NOT `std.process.argsAlloc`,
/// which this Zig does not provide), and stdout is `std.Io.File.stdout()` written through
/// an `Io` writer — the same shape `src/framework.zig:1838` and its `emit` helper use.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    var json = false;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json = true;
    }

    var results: std.ArrayList(harness.Result) = .empty;
    defer results.deinit(alloc);
    try results.append(alloc, try harness.run("smoke/alloc-16", 100, 1000, init.io, {}, benchNoop));

    const key = crypto.deriveKey("bench-secret", "tk1");
    const jwt_claims = jwt.Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 9999999999 };
    const jwt_token = try jwt.sign(alloc, jwt_claims, &key);
    defer alloc.free(jwt_token);
    const jctx = JwtCtx{ .key = key, .token = jwt_token };

    try results.append(alloc, try harness.run("jwt/sign", 100, 2000, init.io, jctx, benchJwtSign));
    try results.append(alloc, try harness.run("jwt/verify", 100, 2000, init.io, jctx, benchJwtVerify));

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try harness.report(results.items, json, &w.interface);
    try w.interface.flush();
}
