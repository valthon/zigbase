const std = @import("std");
const http = @import("../http.zig");

/// A renderable API error. `status` is the HTTP status and the top-level
/// envelope `code`. Field-level validation errors (`data`) arrive in a later
/// sub-project; for now `data` is always an empty object.
pub const ApiError = struct {
    status: u16,
    message: []const u8,

    pub fn notFound() ApiError {
        return .{ .status = 404, .message = "Not found." };
    }

    pub fn internal() ApiError {
        return .{ .status = 500, .message = "Something went wrong." };
    }

    /// Serialize to the JSON error envelope. Allocates with `allocator`.
    pub fn renderBody(self: ApiError, allocator: std.mem.Allocator) ![]u8 {
        const Envelope = struct {
            code: u16,
            message: []const u8,
            data: struct {} = .{},
        };
        return std.json.Stringify.valueAlloc(
            allocator,
            Envelope{ .code = self.status, .message = self.message },
            .{},
        );
    }

    pub fn toResponse(self: ApiError, allocator: std.mem.Allocator) !http.Response {
        return .{ .status = self.status, .body = try self.renderBody(allocator) };
    }
};

test "renders the standard error envelope" {
    const body = try ApiError.notFound().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}",
        body,
    );
}
