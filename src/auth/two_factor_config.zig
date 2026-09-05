//! Compile-time feature selection. This module deliberately does not import any
//! factor implementation: consumers import implementations only in selected arms.
const std = @import("std");

pub const Factor = enum { totp, webauthn };

pub const Selection = struct {
    enabled: bool = false,
    totp: bool = false,
    webauthn: bool = false,
    recovery_codes: bool = false,
};

/// Omit `.auth.two_factor` or use `.disabled` to exclude the subsystem. Enabling
/// it requires an explicit factor list, keeping binary cost visible to consumers.
/// Runtime enrollment and policy data cannot enable a factor omitted here.
pub fn select(comptime config: anytype) Selection {
    const T = @TypeOf(config);
    if (T == @TypeOf(.enum_literal)) {
        if (config == .disabled) return .{};
        @compileError(".auth.two_factor: expected .disabled or .{ .factors = .{ .totp, .webauthn } }");
    }
    if (@typeInfo(T) != .@"struct")
        @compileError(".auth.two_factor must be a config struct or .disabled");
    for (std.meta.fields(T)) |field| {
        if (!std.mem.eql(u8, field.name, "factors") and !std.mem.eql(u8, field.name, "recovery_codes") and !std.mem.eql(u8, field.name, "policy"))
            @compileError(".auth.two_factor: unknown key '." ++ field.name ++ "'");
    }
    if (!@hasField(T, "factors"))
        @compileError(".auth.two_factor.factors is required; select at least one factor");
    const F = @TypeOf(config.factors);
    if (@typeInfo(F) != .@"struct" or !@typeInfo(F).@"struct".is_tuple)
        @compileError(".auth.two_factor.factors must be a tuple of factor names");
    if (std.meta.fields(F).len == 0)
        @compileError(".auth.two_factor.factors must contain at least one factor");
    var result = Selection{ .enabled = true, .recovery_codes = true };
    for (std.meta.fields(F)) |field| {
        const value = @field(config.factors, field.name);
        if (@TypeOf(value) != @TypeOf(.enum_literal) and @TypeOf(value) != Factor)
            @compileError(".auth.two_factor.factors entries must be .totp or .webauthn");
        const name = @tagName(value);
        if (std.mem.eql(u8, name, "totp")) {
            if (result.totp) @compileError(".auth.two_factor.factors: duplicate .totp");
            result.totp = true;
        } else if (std.mem.eql(u8, name, "webauthn")) {
            if (result.webauthn) @compileError(".auth.two_factor.factors: duplicate .webauthn");
            result.webauthn = true;
        } else @compileError(".auth.two_factor.factors: unknown factor '." ++ name ++ "'");
    }
    if (@hasField(T, "recovery_codes")) {
        if (@TypeOf(config.recovery_codes) != bool)
            @compileError(".auth.two_factor.recovery_codes must be bool");
        result.recovery_codes = config.recovery_codes;
    }
    return result;
}

test "two-factor selection tracks explicit factor and recovery choices" {
    const disabled = comptime select(.disabled);
    try std.testing.expect(!disabled.enabled and !disabled.totp and !disabled.webauthn and !disabled.recovery_codes);
    const totp = comptime select(.{ .factors = .{.totp} });
    try std.testing.expect(totp.enabled and totp.totp and !totp.webauthn and totp.recovery_codes);
    const webauthn = comptime select(.{ .factors = .{.webauthn}, .recovery_codes = false });
    try std.testing.expect(webauthn.enabled and !webauthn.totp and webauthn.webauthn and !webauthn.recovery_codes);
    const both = comptime select(.{ .factors = .{ .totp, .webauthn } });
    try std.testing.expect(both.totp and both.webauthn);
}
