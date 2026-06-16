const std = @import("std");

pub const TokKind = enum { ident, string, number, eq, ne, gt, ge, lt, le, like, nlike, l_and, l_or, lparen, rparen, eof };
pub const Token = struct { kind: TokKind, text: []const u8 };
pub const LexError = error{ UnexpectedChar, UnterminatedString, InvalidEscape } || std.mem.Allocator.Error;

/// Tokenize a filter expression. Identifiers may contain '.' (relation paths).
/// Strings are single- or double-quoted; numbers are -?digits(.digits)?.
///
/// Inside a quoted string a backslash starts an escape. The supported escapes are
/// `\\` -> `\`, `\'` -> `'`, `\"` -> `"`, `\n` -> newline, `\t` -> tab, `\r` -> CR.
/// A backslash followed by any other byte is a hard `error.InvalidEscape`; a string
/// ending in a trailing backslash is `error.UnterminatedString`. Escaped strings are
/// unescaped into an owned buffer (allocated with `alloc`) so the parser/compiler see
/// the real value; strings with no escapes keep the zero-copy slice into `input`.
pub fn lex(alloc: std.mem.Allocator, input: []const u8) LexError![]Token {
    var toks: std.ArrayList(Token) = .empty;
    errdefer toks.deinit(alloc);
    var i: usize = 0;
    while (i < input.len) {
        const c = input[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') { i += 1; continue; }
        switch (c) {
            '(' => { try toks.append(alloc, .{ .kind = .lparen, .text = "(" }); i += 1; },
            ')' => { try toks.append(alloc, .{ .kind = .rparen, .text = ")" }); i += 1; },
            '=' => { try toks.append(alloc, .{ .kind = .eq, .text = "=" }); i += 1; },
            '~' => { try toks.append(alloc, .{ .kind = .like, .text = "~" }); i += 1; },
            '>' => { if (i + 1 < input.len and input[i + 1] == '=') { try toks.append(alloc, .{ .kind = .ge, .text = ">=" }); i += 2; } else { try toks.append(alloc, .{ .kind = .gt, .text = ">" }); i += 1; } },
            '<' => { if (i + 1 < input.len and input[i + 1] == '=') { try toks.append(alloc, .{ .kind = .le, .text = "<=" }); i += 2; } else { try toks.append(alloc, .{ .kind = .lt, .text = "<" }); i += 1; } },
            '!' => {
                if (i + 1 < input.len and input[i + 1] == '=') { try toks.append(alloc, .{ .kind = .ne, .text = "!=" }); i += 2; }
                else if (i + 1 < input.len and input[i + 1] == '~') { try toks.append(alloc, .{ .kind = .nlike, .text = "!~" }); i += 2; }
                else return error.UnexpectedChar;
            },
            '&' => { if (i + 1 < input.len and input[i + 1] == '&') { try toks.append(alloc, .{ .kind = .l_and, .text = "&&" }); i += 2; } else return error.UnexpectedChar; },
            '|' => { if (i + 1 < input.len and input[i + 1] == '|') { try toks.append(alloc, .{ .kind = .l_or, .text = "||" }); i += 2; } else return error.UnexpectedChar; },
            '"', '\'' => {
                const quote = c;
                const start = i + 1;
                // First pass: find the closing quote (respecting escapes) and note
                // whether any backslash escape is present. Strings without escapes stay
                // zero-copy; only escaped strings need an owned, unescaped buffer.
                var j = start;
                var has_escape = false;
                while (j < input.len and input[j] != quote) : (j += 1) {
                    if (input[j] == '\\') {
                        has_escape = true;
                        j += 1; // skip the escaped byte
                        if (j >= input.len) return error.UnterminatedString; // trailing backslash
                    }
                }
                if (j >= input.len) return error.UnterminatedString;
                const text = if (has_escape) try unescape(alloc, input[start..j]) else input[start..j];
                try toks.append(alloc, .{ .kind = .string, .text = text });
                i = j + 1;
            },
            else => {
                if (c == '-' or (c >= '0' and c <= '9')) {
                    const start = i;
                    i += 1;
                    // a lone '-' is not a number
                    if (c == '-' and (i >= input.len or input[i] < '0' or input[i] > '9')) return error.UnexpectedChar;
                    while (i < input.len and ((input[i] >= '0' and input[i] <= '9') or input[i] == '.')) : (i += 1) {}
                    try toks.append(alloc, .{ .kind = .number, .text = input[start..i] });
                } else if (isIdentStart(c)) {
                    const start = i;
                    while (i < input.len and isIdentChar(input[i])) : (i += 1) {}
                    try toks.append(alloc, .{ .kind = .ident, .text = input[start..i] });
                } else return error.UnexpectedChar;
            },
        }
    }
    try toks.append(alloc, .{ .kind = .eof, .text = "" });
    return toks.toOwnedSlice(alloc);
}

fn isIdentStart(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '@'; }
fn isIdentChar(c: u8) bool { return isIdentStart(c) or (c >= '0' and c <= '9') or c == '.'; }

/// Decode the backslash escapes in a quoted-string body into a freshly allocated
/// buffer owned by `alloc`. `body` is the slice between the quotes and is known to
/// contain at least one well-formed backslash (the closing quote was already located
/// with escape-awareness, so no trailing backslash can reach here). An unknown escape
/// (`\` followed by anything outside the supported set) is `error.InvalidEscape`.
fn unescape(alloc: std.mem.Allocator, body: []const u8) LexError![]const u8 {
    // The decoded form is never longer than the source, so one allocation suffices.
    var out = try alloc.alloc(u8, body.len);
    errdefer alloc.free(out);
    var n: usize = 0;
    var k: usize = 0;
    while (k < body.len) : (k += 1) {
        if (body[k] != '\\') {
            out[n] = body[k];
            n += 1;
            continue;
        }
        // body never ends in a backslash (guaranteed by the caller's scan).
        k += 1;
        out[n] = switch (body[k]) {
            '\\' => '\\',
            '\'' => '\'',
            '"' => '"',
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            else => return error.InvalidEscape,
        };
        n += 1;
    }
    // Shrink the over-allocation so callers can free the returned slice directly
    // (freeing a sub-slice of a larger allocation is an invalid free).
    if (n != out.len) out = try alloc.realloc(out, n);
    return out;
}

test "lex a relation-path comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try lex(a, "author.name ~ \"ab\" && price >= 10.5");
    const kinds = [_]TokKind{ .ident, .like, .string, .l_and, .ident, .ge, .number, .eof };
    try std.testing.expectEqual(kinds.len, toks.len);
    for (kinds, 0..) |k, i| try std.testing.expectEqual(k, toks[i].kind);
    try std.testing.expectEqualStrings("author.name", toks[0].text);
    try std.testing.expectEqualStrings("ab", toks[2].text);
    try std.testing.expectEqualStrings("10.5", toks[6].text);
}

test "lex rejects malformed input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Unterminated string literal.
    try std.testing.expectError(error.UnterminatedString, lex(a, "title = \"abc"));
    // A lone '&' (not '&&') is invalid.
    try std.testing.expectError(error.UnexpectedChar, lex(a, "a & b"));
    // A lone '|' (not '||') is invalid.
    try std.testing.expectError(error.UnexpectedChar, lex(a, "a | b"));
    // A lone '-' with no following digit is not a number.
    try std.testing.expectError(error.UnexpectedChar, lex(a, "x = -"));
    // A stray character outside the grammar.
    try std.testing.expectError(error.UnexpectedChar, lex(a, "a = %"));
}

test "lex unescapes backslash escapes in string literals" {
    // Use the testing allocator directly (not an arena) so Zig's leak detector flags
    // any owned-buffer leak. We free the slice of tokens and each owned string text.
    const a = std.testing.allocator;
    const Case = struct { input: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .input = "name = 'O\\'Brien'", .want = "O'Brien" }, // same-quote escape
        .{ .input = "v = \"say \\\"hi\\\"\"", .want = "say \"hi\"" }, // escaped double quotes
        .{ .input = "v = 'a\\\\b'", .want = "a\\b" }, // escaped backslash
        .{ .input = "v = 'both \\' and \\\"'", .want = "both ' and \"" }, // both quotes via escape
        .{ .input = "v = 'line\\nbreak\\ttab'", .want = "line\nbreak\ttab" }, // \n and \t
    };
    inline for (cases) |cs| {
        const toks = try lex(a, cs.input);
        defer a.free(toks);
        // toks: ident, eq, string, eof -> the value is at index 2.
        try std.testing.expectEqual(TokKind.string, toks[2].kind);
        try std.testing.expectEqualStrings(cs.want, toks[2].text);
        // Free any owned (escaped) string buffers so the leak detector is satisfied.
        for (toks) |t| if (t.kind == .string) a.free(t.text);
    }
}

test "lex keeps unescaped strings zero-copy (slice into input)" {
    const a = std.testing.allocator;
    const input = "title = \"plain value\"";
    const toks = try lex(a, input);
    defer a.free(toks);
    try std.testing.expectEqualStrings("plain value", toks[2].text);
    // No escapes -> text must be a sub-slice of the original input, not an allocation.
    const base = @intFromPtr(input.ptr);
    const ptr = @intFromPtr(toks[2].text.ptr);
    try std.testing.expect(ptr >= base and ptr < base + input.len);
}

test "lex rejects bad and unterminated escapes" {
    const a = std.testing.allocator;
    // Unknown escape sequence.
    try std.testing.expectError(error.InvalidEscape, lex(a, "v = 'a\\xb'"));
    // Trailing backslash before EOF must not read out of bounds.
    try std.testing.expectError(error.UnterminatedString, lex(a, "v = 'a\\"));
    // A bare escaped quote that then runs off the end is unterminated.
    try std.testing.expectError(error.UnterminatedString, lex(a, "v = 'a\\'"));
}

test "lex an @request macro path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lex(arena.allocator(), "owner = @request.auth.id");
    try std.testing.expectEqual(TokKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokKind.eq, toks[1].kind);
    try std.testing.expectEqual(TokKind.ident, toks[2].kind);
    try std.testing.expectEqualStrings("@request.auth.id", toks[2].text);
}
