//! PostgreSQL v3 Frontend/Backend protocol: message-type tags, common type OIDs, and a
//! small `MsgBuilder` for assembling length-prefixed frontend messages. Reference: the
//! PostgreSQL "Frontend/Backend Protocol — Message Formats" documentation.

const std = @import("std");

/// Backend (server → client) message type tags.
pub const Backend = struct {
    pub const authentication: u8 = 'R';
    pub const backend_key_data: u8 = 'K';
    pub const bind_complete: u8 = '2';
    pub const close_complete: u8 = '3';
    pub const command_complete: u8 = 'C';
    pub const data_row: u8 = 'D';
    pub const empty_query: u8 = 'I';
    pub const error_response: u8 = 'E';
    pub const no_data: u8 = 'n';
    pub const notice_response: u8 = 'N';
    pub const notification_response: u8 = 'A';
    pub const parameter_description: u8 = 't';
    pub const parameter_status: u8 = 'S';
    pub const parse_complete: u8 = '1';
    pub const portal_suspended: u8 = 's';
    pub const ready_for_query: u8 = 'Z';
    pub const row_description: u8 = 'T';
};

/// Frontend (client → server) message type tags.
pub const Frontend = struct {
    pub const bind: u8 = 'B';
    pub const close: u8 = 'C';
    pub const describe: u8 = 'D';
    pub const execute: u8 = 'E';
    pub const flush: u8 = 'H';
    pub const parse: u8 = 'P';
    pub const password: u8 = 'p'; // also SASLInitialResponse / SASLResponse
    pub const query: u8 = 'Q';
    pub const sync: u8 = 'S';
    pub const terminate: u8 = 'X';
};

/// `AuthenticationXxx` sub-codes (first int32 of an 'R' message).
pub const Auth = struct {
    pub const ok: i32 = 0;
    pub const cleartext_password: i32 = 3;
    pub const md5_password: i32 = 5;
    pub const sasl: i32 = 10;
    pub const sasl_continue: i32 = 11;
    pub const sasl_final: i32 = 12;
};

/// A subset of built-in type OIDs — enough to classify a column as integer/float/bool/text
/// for `columnType`. Everything decodes from TEXT result format, so unknowns fall back to text.
pub const Oid = struct {
    pub const bool_: u32 = 16;
    pub const int8: u32 = 20;
    pub const int2: u32 = 21;
    pub const int4: u32 = 23;
    pub const float4: u32 = 700;
    pub const float8: u32 = 701;
    pub const numeric: u32 = 1700;
};

/// Assembles a single length-prefixed frontend message in a reusable scratch buffer, then
/// writes it to a `std.Io.Writer`. The 4-byte length (covering the length field + body, per
/// the protocol) is back-patched in `finish`.
pub const MsgBuilder = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    /// Offset of the 4-byte length placeholder, set by `start`.
    len_at: usize = 0,

    pub fn init(allocator: std.mem.Allocator, buf: *std.ArrayList(u8)) MsgBuilder {
        return .{ .buf = buf, .allocator = allocator };
    }

    /// Begin a message with type tag `tag` (pass 0 for the untagged startup/SSL messages).
    pub fn start(self: *MsgBuilder, tag: u8) !void {
        self.buf.clearRetainingCapacity();
        if (tag != 0) try self.buf.append(self.allocator, tag);
        self.len_at = self.buf.items.len;
        try self.buf.appendSlice(self.allocator, &[_]u8{ 0, 0, 0, 0 }); // length placeholder
    }

    pub fn int32(self: *MsgBuilder, v: i32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(i32, &b, v, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn int16(self: *MsgBuilder, v: i16) !void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(i16, &b, v, .big);
        try self.buf.appendSlice(self.allocator, &b);
    }

    pub fn byte(self: *MsgBuilder, v: u8) !void {
        try self.buf.append(self.allocator, v);
    }

    /// Append raw bytes (no length prefix, no terminator).
    pub fn bytes(self: *MsgBuilder, v: []const u8) !void {
        try self.buf.appendSlice(self.allocator, v);
    }

    /// Append a C string (bytes + NUL terminator).
    pub fn cstr(self: *MsgBuilder, v: []const u8) !void {
        try self.buf.appendSlice(self.allocator, v);
        try self.buf.append(self.allocator, 0);
    }

    /// Back-patch the length field (length counts itself + the body, NOT the type tag)
    /// and write the finished message to `w`.
    pub fn finish(self: *MsgBuilder, w: *std.Io.Writer) !void {
        const body_len: i32 = @intCast(self.buf.items.len - self.len_at);
        std.mem.writeInt(i32, self.buf.items[self.len_at..][0..4], body_len, .big);
        try w.writeAll(self.buf.items);
    }
};

test "msgbuilder length prefix counts length+body, excludes the type tag" {
    const a = std.testing.allocator;
    var scratch: std.ArrayList(u8) = .empty;
    defer scratch.deinit(a);
    var mb = MsgBuilder.init(a, &scratch);
    try mb.start(Frontend.query);
    try mb.cstr("SELECT 1");
    // finish() back-patches the length and writes the message; capture it in a fixed buffer.
    var out_buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&out_buf);
    try mb.finish(&w);
    const msg = w.buffered();
    // type byte + len(4) + "SELECT 1"(8) + NUL(1) = 14 total; length field = 13.
    try std.testing.expectEqual(@as(usize, 14), msg.len);
    try std.testing.expectEqual(@as(u8, 'Q'), msg[0]);
    const len = std.mem.readInt(i32, msg[1..5], .big);
    try std.testing.expectEqual(@as(i32, 13), len);
}
