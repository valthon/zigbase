//! Policy composition shared by login and authenticated-session checks.
//! Application authorization owns role/group policy writes; the framework only
//! combines their evaluated requirement with collection and enrollment policy.
const std = @import("std");

pub const Mode = enum { disabled, optional, required };
pub const Decision = enum { authenticated, factor_required, enrollment_required };

pub const Input = struct {
    mode: Mode,
    /// True when any application rule (role, group, account policy) requires 2FA.
    application_required: bool = false,
    /// Enrollment represents the user's voluntary protection as well as factors
    /// enrolled to satisfy a requirement. Only verified enrollment counts.
    enrolled: bool = false,
    /// A server-verified proof or signed session assurance, never request JSON.
    factor_verified: bool = false,
};

/// Requirements compose monotonically: a less restrictive source cannot waive
/// another source's requirement. Disabled configuration combined with a runtime
/// requirement is a configuration failure, never permission to skip the factor.
pub fn evaluate(input: Input) error{TwoFactorUnavailable}!Decision {
    if (input.mode == .disabled) {
        if (input.application_required or input.enrolled) return error.TwoFactorUnavailable;
        return .authenticated;
    }
    const required = input.mode == .required or input.application_required or input.enrolled;
    if (!required) return .authenticated;
    if (!input.enrolled) return .enrollment_required;
    return if (input.factor_verified) .authenticated else .factor_required;
}

test "collection, application and voluntary requirements compose without opt-out bypass" {
    try std.testing.expectEqual(Decision.authenticated, try evaluate(.{ .mode = .optional }));
    try std.testing.expectEqual(Decision.enrollment_required, try evaluate(.{ .mode = .required }));
    try std.testing.expectEqual(Decision.enrollment_required, try evaluate(.{ .mode = .optional, .application_required = true }));
    try std.testing.expectEqual(Decision.factor_required, try evaluate(.{ .mode = .optional, .enrolled = true }));
    try std.testing.expectEqual(Decision.factor_required, try evaluate(.{ .mode = .required, .enrolled = true }));
    try std.testing.expectEqual(Decision.authenticated, try evaluate(.{ .mode = .optional, .enrolled = true, .factor_verified = true }));
    try std.testing.expectEqual(Decision.authenticated, try evaluate(.{ .mode = .required, .enrolled = true, .factor_verified = true }));
    try std.testing.expectEqual(Decision.enrollment_required, try evaluate(.{ .mode = .required, .factor_verified = true }));
}

test "group or role requirement changes apply to an existing primary-only session" {
    var input = Input{ .mode = .optional };
    try std.testing.expectEqual(Decision.authenticated, try evaluate(input));
    input.application_required = true;
    try std.testing.expectEqual(Decision.enrollment_required, try evaluate(input));
    input.enrolled = true;
    try std.testing.expectEqual(Decision.factor_required, try evaluate(input));
    input.factor_verified = true;
    try std.testing.expectEqual(Decision.authenticated, try evaluate(input));
    input.application_required = false;
    input.factor_verified = false;
    try std.testing.expectEqual(Decision.factor_required, try evaluate(input));
}

test "disabled factors cannot silently waive an applicable requirement" {
    try std.testing.expectEqual(Decision.authenticated, try evaluate(.{ .mode = .disabled }));
    try std.testing.expectError(error.TwoFactorUnavailable, evaluate(.{ .mode = .disabled, .application_required = true }));
    try std.testing.expectError(error.TwoFactorUnavailable, evaluate(.{ .mode = .disabled, .enrolled = true }));
}
