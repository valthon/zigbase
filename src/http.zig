const std = @import("std");

pub const Method = enum { GET, POST, PUT, PATCH, DELETE, OPTIONS, HEAD, UNKNOWN };

pub const RequestCtx = struct {
    method: Method,
    path: []const u8,
    query: []const u8 = "",
    body: []const u8 = "",
    allocator: std.mem.Allocator,
};

pub const Response = struct {
    status: u16,
    content_type: []const u8 = "application/json",
    body: []const u8, // allocated in the request arena
};

pub const Handler = *const fn (ctx: *RequestCtx) anyerror!Response;
