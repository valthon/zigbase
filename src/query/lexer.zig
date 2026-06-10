const std = @import("std");

pub const TokKind = enum { ident, string, number, eq, ne, gt, ge, lt, le, like, nlike, l_and, l_or, lparen, rparen, eof };
pub const Token = struct { kind: TokKind, text: []const u8 };
pub const LexError = error{ UnexpectedChar, UnterminatedString } || std.mem.Allocator.Error;

/// Tokenize a filter expression. Identifiers may contain '.' (relation paths).
/// Strings are single- or double-quoted; numbers are -?digits(.digits)?.
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
                var j = start;
                while (j < input.len and input[j] != quote) : (j += 1) {}
                if (j >= input.len) return error.UnterminatedString;
                try toks.append(alloc, .{ .kind = .string, .text = input[start..j] });
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

test "lex an @request macro path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lex(arena.allocator(), "owner = @request.auth.id");
    try std.testing.expectEqual(TokKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokKind.eq, toks[1].kind);
    try std.testing.expectEqual(TokKind.ident, toks[2].kind);
    try std.testing.expectEqualStrings("@request.auth.id", toks[2].text);
}
