const std = @import("std");
const method_mod = @import("method.zig");
const AuthMethod = method_mod.AuthMethod;
const PasswordMethod = @import("methods/password.zig").PasswordMethod;
const MagicLinkMethod = @import("methods/magic_link.zig").MagicLinkMethod;
const OtpMethod = @import("methods/otp.zig").OtpMethod;
const WebAuthnMethod = @import("methods/webauthn.zig").WebAuthnMethod;
const OAuth2Method = @import("methods/oauth2.zig").OAuth2Method;

// ---------------------------------------------------------------------------
// Registry — slug → AuthMethod lookup
// ---------------------------------------------------------------------------

pub const Registry = struct {
    methods: []const AuthMethod,

    pub fn get(self: *const Registry, slug: []const u8) ?AuthMethod {
        for (self.methods) |m| {
            if (std.mem.eql(u8, m.slug, slug)) return m;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// assembleTypes — comptime list of method TYPES (built-ins ++ consumer types)
// ---------------------------------------------------------------------------

/// Comptime `[]const type` of auth methods. Three accepted forms for `cfg.auth_methods`:
///   absent                        → all five built-ins (back-compat)
///   .{ CustomT, ... } (tuple)     → all five built-ins ++ customs (back-compat)
///   .{ .builtins = .{ .password, ... }, .custom = .{ CustomT, ... } }
///                                 → EXACTLY the named built-ins (in the order given)
///                                   ++ customs. Omitting .builtins keeps all five;
///                                   .builtins = .{} drops every built-in. R2-4: a
///                                   deselected built-in (e.g. .webauthn, ~3.2k LOC)
///                                   is never analyzed → absent from the binary.
pub fn assembleTypes(comptime cfg: anytype) []const type {
    const all_builtins: []const type = &.{ PasswordMethod, MagicLinkMethod, OtpMethod, WebAuthnMethod, OAuth2Method };
    if (!@hasField(@TypeOf(cfg), "auth_methods")) return all_builtins;
    const am = cfg.auth_methods;
    const AM = @TypeOf(am);
    const info = @typeInfo(AM);
    if (info != .@"struct")
        @compileError(".auth_methods must be a tuple of method types or '.{ .builtins = .{ ... }, .custom = .{ ... } }'");

    if (!info.@"struct".is_tuple) {
        // New named form.
        for (std.meta.fields(AM)) |f| {
            if (!std.mem.eql(u8, f.name, "builtins") and !std.mem.eql(u8, f.name, "custom"))
                @compileError(".auth_methods: unknown key '." ++ f.name ++ "' (recognized: .builtins, .custom)");
        }
        comptime var result: []const type = &.{};
        if (@hasField(AM, "builtins")) {
            inline for (std.meta.fields(@TypeOf(am.builtins))) |bf| {
                const lit = @field(am.builtins, bf.name);
                const name = @tagName(lit);
                const T: type = blk: {
                    if (std.mem.eql(u8, name, "password")) break :blk PasswordMethod;
                    if (std.mem.eql(u8, name, "magic_link")) break :blk MagicLinkMethod;
                    if (std.mem.eql(u8, name, "otp")) break :blk OtpMethod;
                    if (std.mem.eql(u8, name, "webauthn")) break :blk WebAuthnMethod;
                    if (std.mem.eql(u8, name, "oauth2")) break :blk OAuth2Method;
                    @compileError(".auth_methods.builtins: unknown built-in '." ++ name ++ "' (expected .password/.magic_link/.otp/.webauthn/.oauth2)");
                };
                for (result) |seen| if (seen == T) @compileError(".auth_methods.builtins: duplicate '." ++ name ++ "'");
                result = result ++ &[_]type{T};
            }
        } else {
            result = all_builtins;
        }
        if (@hasField(AM, "custom")) {
            inline for (std.meta.fields(@TypeOf(am.custom))) |f| {
                result = result ++ &[_]type{@field(am.custom, f.name)};
            }
        }
        return result;
    }

    // Legacy bare tuple: all built-ins ++ customs (unchanged).
    comptime var result: []const type = all_builtins;
    inline for (info.@"struct".fields) |f| {
        result = result ++ &[_]type{@field(am, f.name)};
    }
    return result;
}

// ---------------------------------------------------------------------------
// Instances — comptime-generated holder struct for heterogeneous instances
// ---------------------------------------------------------------------------

/// Generates a std.meta.Tuple type with one element per entry in `types`.
/// Field names are "0", "1", ..., "N-1". Enables stack-storage of
/// heterogeneous instances without heap allocation.
/// Note: @Type with .@"struct" is not supported in Zig 0.16; std.meta.Tuple
/// is used instead — it produces a tuple with the same field layout.
pub fn Instances(comptime types: []const type) type {
    comptime var tuple_types: [types.len]type = undefined;
    for (types, 0..) |T, i| tuple_types[i] = T;
    return std.meta.Tuple(&tuple_types);
}

// ---------------------------------------------------------------------------
// build — instantiate all method types, collect views, return Registry
// ---------------------------------------------------------------------------

/// Instantiate each type in `types`, store instances in `insts`, collect
/// AuthMethod views into `views`, and return a Registry pointing at `views`.
/// `insts` and `views` must outlive the returned Registry (typically stack vars
/// in serveImpl that live for the lifetime of the server).
pub fn build(
    comptime types: []const type,
    insts: *Instances(types),
    views: *[types.len]AuthMethod,
    gpa: std.mem.Allocator,
    io: std.Io,
    cfg: anytype,
) !Registry {
    inline for (types, 0..) |T, i| {
        const name = std.fmt.comptimePrint("{}", .{i});
        @field(insts.*, name) = try T.create(gpa, io, cfg);
        views[i] = @field(insts.*, name).method();
    }
    return Registry{ .methods = views };
}

// ---------------------------------------------------------------------------
// deinit — tear down all instances in reverse order
// ---------------------------------------------------------------------------

pub fn deinit(comptime types: []const type, insts: *Instances(types)) void {
    // Deinit in reverse order (mirror defer semantics).
    comptime var i = types.len;
    inline while (i > 0) {
        i -= 1;
        const name = std.fmt.comptimePrint("{}", .{i});
        @field(insts.*, name).deinit();
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Registry: built-in methods are found by slug, unknown slug returns null" {
    // assembleTypes with an empty cfg (no .auth_methods field) → built-in methods
    const types = comptime assembleTypes(.{});

    var insts: Instances(types) = undefined;
    var views: [types.len]AuthMethod = undefined;

    var reg = try build(types, &insts, &views, std.testing.allocator, std.testing.io, .{});
    defer deinit(types, &insts);

    const found = reg.get("password");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("password", found.?.slug);

    const found_ml = reg.get("magic_link");
    try std.testing.expect(found_ml != null);
    try std.testing.expectEqualStrings("magic_link", found_ml.?.slug);

    const found_otp = reg.get("otp");
    try std.testing.expect(found_otp != null);
    try std.testing.expectEqualStrings("otp", found_otp.?.slug);

    const found_wa = reg.get("webauthn");
    try std.testing.expect(found_wa != null);
    try std.testing.expectEqualStrings("webauthn", found_wa.?.slug);

    const found_oa = reg.get("oauth2");
    try std.testing.expect(found_oa != null);
    try std.testing.expectEqualStrings("oauth2", found_oa.?.slug);

    const missing = reg.get("nope");
    try std.testing.expect(missing == null);
}

test "Registry: assembleTypes with no .auth_methods key returns built-in methods" {
    const types = comptime assembleTypes(.{});
    try std.testing.expectEqual(@as(usize, 5), types.len);
    // Type identity must be checked at comptime.
    comptime std.debug.assert(types[0] == PasswordMethod);
    comptime std.debug.assert(types[1] == MagicLinkMethod);
    comptime std.debug.assert(types[2] == OtpMethod);
    comptime std.debug.assert(types[3] == WebAuthnMethod);
    comptime std.debug.assert(types[4] == OAuth2Method);
}

test "Registry: assembleTypes with .auth_methods appends custom types" {
    const FakeMethod = struct {
        pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !@This() { return .{}; }
        pub fn method(self: *@This()) AuthMethod {
            return .{ .slug = "fake", .ctx = self, .vtable = &vt };
        }
        pub fn deinit(_: *@This()) void {}
        const vt = AuthMethod.VTable{ .initiate = undefined, .complete = undefined };
    };

    const types = comptime assembleTypes(.{ .auth_methods = .{FakeMethod} });
    try std.testing.expectEqual(@as(usize, 6), types.len);
    comptime std.debug.assert(types[0] == PasswordMethod);
    comptime std.debug.assert(types[1] == MagicLinkMethod);
    comptime std.debug.assert(types[2] == OtpMethod);
    comptime std.debug.assert(types[3] == WebAuthnMethod);
    comptime std.debug.assert(types[4] == OAuth2Method);
    comptime std.debug.assert(types[5] == FakeMethod);

    var insts: Instances(types) = undefined;
    var views: [types.len]AuthMethod = undefined;
    var reg = try build(types, &insts, &views, std.testing.allocator, std.testing.io, .{});
    defer deinit(types, &insts);

    try std.testing.expect(reg.get("password") != null);
    try std.testing.expect(reg.get("magic_link") != null);
    try std.testing.expect(reg.get("otp") != null);
    try std.testing.expect(reg.get("fake") != null);
    try std.testing.expect(reg.get("nope") == null);
}

test "R2-4: assembleTypes .builtins selects an exact subset" {
    const types = comptime assembleTypes(.{ .auth_methods = .{ .builtins = .{ .password, .otp } } });
    try std.testing.expectEqual(@as(usize, 2), types.len);
    comptime std.debug.assert(types[0] == PasswordMethod);
    comptime std.debug.assert(types[1] == OtpMethod);
}

test "R2-4: assembleTypes .builtins + .custom composes" {
    const FakeMethod = struct {
        pub fn create(_: std.mem.Allocator, _: std.Io, _: anytype) !@This() { return .{}; }
        pub fn method(self: *@This()) AuthMethod {
            return .{ .slug = "fake", .ctx = self, .vtable = &vt };
        }
        pub fn deinit(_: *@This()) void {}
        const vt = AuthMethod.VTable{ .initiate = undefined, .complete = undefined };
    };
    const types = comptime assembleTypes(.{ .auth_methods = .{ .builtins = .{ .webauthn }, .custom = .{FakeMethod} } });
    try std.testing.expectEqual(@as(usize, 2), types.len);
    comptime std.debug.assert(types[0] == WebAuthnMethod);
    comptime std.debug.assert(types[1] == FakeMethod);
}

test "R2-4: legacy bare tuple still means all builtins ++ customs" {
    // (mirror of the existing ".auth_methods appends custom types" test — keep both green)
    const types = comptime assembleTypes(.{ .auth_methods = .{} }); // empty tuple
    try std.testing.expectEqual(@as(usize, 5), types.len);
}
