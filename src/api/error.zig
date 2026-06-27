const std = @import("std");
const http = @import("../http.zig");

pub const FieldError = struct { field: []const u8, code: []const u8, message: []const u8 };

/// A renderable API error. Envelope: {code, message, data:{<field>:{code,message}}}.
pub const ApiError = struct {
    status: u16,
    message: []const u8,
    fields: []const FieldError = &.{},

    pub fn notFound() ApiError {
        return .{ .status = 404, .message = "Not found." };
    }
    pub fn internal() ApiError {
        return .{ .status = 500, .message = "Something went wrong." };
    }
    pub fn badRequest(message: []const u8) ApiError {
        return .{ .status = 400, .message = message };
    }
    pub fn conflict(message: []const u8) ApiError {
        return .{ .status = 409, .message = message };
    }
    /// 410 Gone — the resource existed but is no longer available (e.g. an expired cursor).
    pub fn gone(message: []const u8) ApiError {
        return .{ .status = 410, .message = message };
    }
    pub fn validation(fields: []const FieldError) ApiError {
        return .{ .status = 400, .message = "Failed to validate the request.", .fields = fields };
    }
    pub fn forbidden() ApiError {
        return .{ .status = 403, .message = "Forbidden." };
    }
    pub fn unauthorized() ApiError {
        return .{ .status = 401, .message = "Unauthorized." };
    }

    pub fn renderBody(self: ApiError, alloc: std.mem.Allocator) ![]u8 {
        // Build the ObjectMap tree in a temporary arena; serialize into `alloc`.
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var data: std.json.ObjectMap = .empty;
        for (self.fields) |fe| {
            var fo: std.json.ObjectMap = .empty;
            try fo.put(aa, "code", .{ .string = fe.code });
            try fo.put(aa, "message", .{ .string = fe.message });
            try data.put(aa, fe.field, .{ .object = fo });
        }
        var root: std.json.ObjectMap = .empty;
        try root.put(aa, "code", .{ .integer = @intCast(self.status) });
        try root.put(aa, "message", .{ .string = self.message });
        try root.put(aa, "data", .{ .object = data });
        return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
    }

    pub fn toResponse(self: ApiError, alloc: std.mem.Allocator) !http.Response {
        return .{ .status = self.status, .body = try self.renderBody(alloc) };
    }
};

test "renders empty-data envelope" {
    const body = try ApiError.notFound().renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"code\":404,\"message\":\"Not found.\",\"data\":{}}",
        body,
    );
}

test "renders validation field errors" {
    const fields = [_]FieldError{.{ .field = "name", .code = "validation_invalid_name", .message = "Invalid." }};
    const body = try ApiError.validation(&fields).renderBody(std.testing.allocator);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings(
        "{\"code\":400,\"message\":\"Failed to validate the request.\",\"data\":{\"name\":{\"code\":\"validation_invalid_name\",\"message\":\"Invalid.\"}}}",
        body,
    );
}
