const std = @import("std");
const lexer = @import("lexer.zig");

pub const Operand = union(enum) {
    path: []const u8,
    str: []const u8,
    num: []const u8,
    boolean: bool,
    nul,
};

pub const Node = union(enum) {
    cmp: struct { lhs: Operand, op: lexer.TokKind, rhs: Operand },
    logic: struct { op: lexer.TokKind, l: *Node, r: *Node }, // op is .l_and or .l_or
};

pub const ParseError = error{ UnexpectedToken, BadOperand, Empty } || std.mem.Allocator.Error;

const Parser = struct {
    alloc: std.mem.Allocator,
    toks: []const lexer.Token,
    pos: usize = 0,

    fn peek(self: *Parser) lexer.TokKind { return self.toks[self.pos].kind; }
    fn next(self: *Parser) lexer.Token { const t = self.toks[self.pos]; self.pos += 1; return t; }

    fn parseOr(self: *Parser) ParseError!*Node {
        var left = try self.parseAnd();
        while (self.peek() == .l_or) {
            _ = self.next();
            const right = try self.parseAnd();
            left = try self.mk(.{ .logic = .{ .op = .l_or, .l = left, .r = right } });
        }
        return left;
    }
    fn parseAnd(self: *Parser) ParseError!*Node {
        var left = try self.parsePrimary();
        while (self.peek() == .l_and) {
            _ = self.next();
            const right = try self.parsePrimary();
            left = try self.mk(.{ .logic = .{ .op = .l_and, .l = left, .r = right } });
        }
        return left;
    }
    fn parsePrimary(self: *Parser) ParseError!*Node {
        if (self.peek() == .lparen) {
            _ = self.next();
            const inner = try self.parseOr();
            if (self.peek() != .rparen) return error.UnexpectedToken;
            _ = self.next();
            return inner;
        }
        const lhs = try self.operand();
        const op = self.next().kind;
        switch (op) {
            .eq, .ne, .gt, .ge, .lt, .le, .like, .nlike => {},
            else => return error.UnexpectedToken,
        }
        const rhs = try self.operand();
        return self.mk(.{ .cmp = .{ .lhs = lhs, .op = op, .rhs = rhs } });
    }
    fn operand(self: *Parser) ParseError!Operand {
        const t = self.next();
        return switch (t.kind) {
            .string => .{ .str = t.text },
            .number => .{ .num = t.text },
            .ident => if (std.mem.eql(u8, t.text, "true")) .{ .boolean = true } else if (std.mem.eql(u8, t.text, "false")) .{ .boolean = false } else if (std.mem.eql(u8, t.text, "null")) .nul else .{ .path = t.text },
            else => error.BadOperand,
        };
    }
    fn mk(self: *Parser, n: Node) !*Node {
        const p = try self.alloc.create(Node);
        p.* = n;
        return p;
    }
};

pub fn parse(alloc: std.mem.Allocator, toks: []const lexer.Token) ParseError!*Node {
    if (toks.len == 0 or toks[0].kind == .eof) return error.Empty;
    var p = Parser{ .alloc = alloc, .toks = toks };
    const node = try p.parseOr();
    if (p.peek() != .eof) return error.UnexpectedToken;
    return node;
}

test "parse precedence: a = 1 && b = 2 || c = 3" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try lexer.lex(a, "a = 1 && b = 2 || c = 3");
    const root = try parse(a, toks);
    try std.testing.expectEqual(lexer.TokKind.l_or, root.logic.op);
    try std.testing.expectEqual(lexer.TokKind.l_and, root.logic.l.logic.op);
    try std.testing.expectEqualStrings("c", root.logic.r.cmp.lhs.path);
}

test "parse a parenthesized relation comparison" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try lexer.lex(a, "(author.name = \"x\")");
    const root = try parse(a, toks);
    try std.testing.expectEqualStrings("author.name", root.cmp.lhs.path);
    try std.testing.expectEqualStrings("x", root.cmp.rhs.str);
}

test "parse rejects a trailing token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toks = try lexer.lex(a, "a = 1 b = 2");
    try std.testing.expectError(error.UnexpectedToken, parse(a, toks));
}
