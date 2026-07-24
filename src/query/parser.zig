const std = @import("std");
const lexer = @import("lexer.zig");

pub const Operand = union(enum) {
    path: []const u8,
    str: []const u8,
    num: []const u8,
    boolean: bool,
    nul,
    /// A `?` bound-value placeholder. The payload is the 0-based, left-to-right index of the
    /// caller-supplied `filter_args` value the compiler binds here (never re-parsed as grammar).
    placeholder: usize,
    /// The right-hand side of `in (…)` — a parenthesized list of scalar/macro operands.
    list: []const Operand,
    /// The right-hand side of `in @request.*.ids` — a list-valued macro path.
    list_macro: []const u8,
};

pub const Node = union(enum) {
    cmp: struct { lhs: Operand, op: lexer.TokKind, rhs: Operand },
    logic: struct { op: lexer.TokKind, l: *Node, r: *Node }, // op is .l_and or .l_or
};

pub const ParseError = error{ UnexpectedToken, BadOperand, Empty, TooDeep } || std.mem.Allocator.Error;

/// Cap on paren-nesting recursion. `?filter=` is attacker-controlled on public-list
/// collections; without a bound a few thousand `(` overflows the stack and crashes the worker.
const max_depth = 32;

const Parser = struct {
    alloc: std.mem.Allocator,
    toks: []const lexer.Token,
    pos: usize = 0,
    depth: usize = 0,
    /// Running count of `?` placeholders seen so far; each placeholder operand captures the
    /// current value as its 0-based index, then this increments. The final value is the total
    /// placeholder count the compiler validates against `filter_args.len`.
    ph_count: usize = 0,

    fn peek(self: *Parser) lexer.TokKind {
        return self.toks[self.pos].kind;
    }
    fn next(self: *Parser) lexer.Token {
        const t = self.toks[self.pos];
        self.pos += 1;
        return t;
    }

    fn parseOr(self: *Parser) ParseError!*Node {
        var left = try self.parseAnd();
        // Everything built below hangs off `left` once `mk` folds it in; on any later error the
        // whole partial subtree must be freed (parse() must not leak on a mid-string failure).
        errdefer freeNode(self.alloc, left);
        while (self.peek() == .l_or) {
            _ = self.next();
            const right = try self.parseAnd();
            // `right` is not yet owned by a node until `mk` succeeds; free it if `mk` OOMs.
            errdefer freeNode(self.alloc, right);
            left = try self.mk(.{ .logic = .{ .op = .l_or, .l = left, .r = right } });
        }
        return left;
    }
    fn parseAnd(self: *Parser) ParseError!*Node {
        var left = try self.parsePrimary();
        errdefer freeNode(self.alloc, left);
        while (self.peek() == .l_and) {
            _ = self.next();
            const right = try self.parsePrimary();
            errdefer freeNode(self.alloc, right);
            left = try self.mk(.{ .logic = .{ .op = .l_and, .l = left, .r = right } });
        }
        return left;
    }
    fn parsePrimary(self: *Parser) ParseError!*Node {
        if (self.peek() == .lparen) {
            if (self.depth >= max_depth) return error.TooDeep;
            self.depth += 1;
            defer self.depth -= 1;
            _ = self.next();
            const inner = try self.parseOr();
            errdefer freeNode(self.alloc, inner);
            if (self.peek() != .rparen) return error.UnexpectedToken;
            _ = self.next();
            return inner;
        }
        const lhs = try self.operand();
        const op = self.next().kind;
        const rhs = switch (op) {
            .eq, .ne, .gt, .ge, .lt, .le, .like, .nlike => try self.operand(),
            .in => try self.inOperand(),
            else => return error.UnexpectedToken,
        };
        // `rhs` may own an `in (...)` list slice; free it if the enclosing `mk` OOMs. (`lhs` is
        // always a scalar operand borrowing token text, so it owns nothing.)
        errdefer if (rhs == .list) self.alloc.free(rhs.list);
        return self.mk(.{ .cmp = .{ .lhs = lhs, .op = op, .rhs = rhs } });
    }
    /// Parse the right-hand side of an `in` operator: either a list-valued macro
    /// (`@request.account.ids`) or a parenthesized, comma-separated list of scalar operands
    /// (`("a", "b", 3)`). An empty list `()` is allowed and compiles to a constant-false predicate.
    fn inOperand(self: *Parser) ParseError!Operand {
        // A bare `@…` path on the RHS of `in` is a list-valued macro.
        if (self.peek() == .ident) {
            const t = self.toks[self.pos];
            if (t.text.len > 0 and t.text[0] == '@') {
                _ = self.next();
                return .{ .list_macro = t.text };
            }
        }
        if (self.peek() != .lparen) return error.UnexpectedToken;
        _ = self.next();
        var items: std.ArrayList(Operand) = .empty;
        // Elements borrow token text; only the backing array is owned. Free it on any error before
        // `toOwnedSlice` transfers ownership out.
        errdefer items.deinit(self.alloc);
        if (self.peek() != .rparen) {
            while (true) {
                try items.append(self.alloc, try self.operand());
                if (self.peek() == .comma) {
                    _ = self.next();
                    continue;
                }
                break;
            }
        }
        if (self.peek() != .rparen) return error.UnexpectedToken;
        _ = self.next();
        return .{ .list = try items.toOwnedSlice(self.alloc) };
    }
    fn operand(self: *Parser) ParseError!Operand {
        const t = self.next();
        return switch (t.kind) {
            .string => .{ .str = t.text },
            .number => .{ .num = t.text },
            .placeholder => blk: {
                const idx = self.ph_count;
                self.ph_count += 1;
                break :blk Operand{ .placeholder = idx };
            },
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
    // A trailing token rejects the whole parse; free the AST built so far rather than leak it.
    errdefer freeNode(alloc, node);
    if (p.peek() != .eof) return error.UnexpectedToken;
    return node;
}

/// Recursively free an AST returned by `parse` (or a partial subtree during error unwinding).
/// Frees every `*Node` and each owned `in (...)` list slice. Operand payloads (`.str`/`.num`/
/// `.path`/`.list_macro`, and the elements inside a `.list`) BORROW lexer token text and are NOT
/// freed here — free the tokens separately (order-independent: this never dereferences that text).
/// The AST is a strict tree with no shared nodes, so a single top-down walk frees each node once.
pub fn freeNode(alloc: std.mem.Allocator, node: *Node) void {
    switch (node.*) {
        .logic => |lg| {
            freeNode(alloc, lg.l);
            freeNode(alloc, lg.r);
        },
        // Only the RHS of a cmp can own memory (the `in (...)` list slice); the LHS is always a
        // scalar operand that borrows token text.
        .cmp => |c| if (c.rhs == .list) alloc.free(c.rhs.list),
    }
    alloc.destroy(node);
}

test "parse precedence: a = 1 && b = 2 || c = 3" {
    const a = std.testing.allocator;
    const input = "a = 1 && b = 2 || c = 3";
    const toks = try lexer.lex(a, input);
    defer lexer.freeTokens(a, input, toks);
    const root = try parse(a, toks);
    defer freeNode(a, root);
    try std.testing.expectEqual(lexer.TokKind.l_or, root.logic.op);
    try std.testing.expectEqual(lexer.TokKind.l_and, root.logic.l.logic.op);
    try std.testing.expectEqualStrings("c", root.logic.r.cmp.lhs.path);
}

test "parse a parenthesized relation comparison" {
    const a = std.testing.allocator;
    const input = "(author.name = \"x\")";
    const toks = try lexer.lex(a, input);
    defer lexer.freeTokens(a, input, toks);
    const root = try parse(a, toks);
    defer freeNode(a, root);
    try std.testing.expectEqualStrings("author.name", root.cmp.lhs.path);
    try std.testing.expectEqualStrings("x", root.cmp.rhs.str);
}

test "parse the `in` operator with a literal list" {
    const a = std.testing.allocator;
    const input = "status in (\"a\", \"b\", \"c\")";
    const toks = try lexer.lex(a, input);
    defer lexer.freeTokens(a, input, toks);
    const root = try parse(a, toks);
    defer freeNode(a, root);
    try std.testing.expectEqual(lexer.TokKind.in, root.cmp.op);
    try std.testing.expectEqualStrings("status", root.cmp.lhs.path);
    try std.testing.expectEqual(@as(usize, 3), root.cmp.rhs.list.len);
    try std.testing.expectEqualStrings("a", root.cmp.rhs.list[0].str);
    try std.testing.expectEqualStrings("c", root.cmp.rhs.list[2].str);
}

test "parse the `in` operator with a list macro" {
    const a = std.testing.allocator;
    const input = "account in @request.account.ids";
    const toks = try lexer.lex(a, input);
    defer lexer.freeTokens(a, input, toks);
    const root = try parse(a, toks);
    defer freeNode(a, root);
    try std.testing.expectEqual(lexer.TokKind.in, root.cmp.op);
    try std.testing.expectEqualStrings("account", root.cmp.lhs.path);
    try std.testing.expectEqualStrings("@request.account.ids", root.cmp.rhs.list_macro);
}

test "parse an empty `in ()` list" {
    const a = std.testing.allocator;
    const input = "x in ()";
    const toks = try lexer.lex(a, input);
    defer lexer.freeTokens(a, input, toks);
    const root = try parse(a, toks);
    defer freeNode(a, root);
    try std.testing.expectEqual(@as(usize, 0), root.cmp.rhs.list.len);
}

test "parse rejects a trailing token" {
    // The partial AST built before the trailing token is detected must be freed by `parse` itself
    // (its errdefer), so this runs leak-clean on the raw testing allocator.
    const a = std.testing.allocator;
    const input = "a = 1 b = 2";
    const toks = try lexer.lex(a, input);
    defer lexer.freeTokens(a, input, toks);
    try std.testing.expectError(error.UnexpectedToken, parse(a, toks));
}

test "parse rejects pathologically deep nesting (no stack overflow)" {
    const a = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    for (0..100) |_| try buf.append(a, '(');
    try buf.appendSlice(a, "a = 1");
    for (0..100) |_| try buf.append(a, ')');
    const toks = try lexer.lex(a, buf.items);
    defer lexer.freeTokens(a, buf.items, toks);
    try std.testing.expectError(error.TooDeep, parse(a, toks));
}

test "parse assigns `?` placeholders sequential 0-based indices left-to-right" {
    const a = std.testing.allocator;
    const input = "a = ? && b = ? || c = ?";
    const toks = try lexer.lex(a, input);
    defer lexer.freeTokens(a, input, toks);
    const root = try parse(a, toks);
    defer freeNode(a, root);
    // ((a = ?0) AND (b = ?1)) OR (c = ?2)
    try std.testing.expectEqual(@as(usize, 0), root.logic.l.logic.l.cmp.rhs.placeholder);
    try std.testing.expectEqual(@as(usize, 1), root.logic.l.logic.r.cmp.rhs.placeholder);
    try std.testing.expectEqual(@as(usize, 2), root.logic.r.cmp.rhs.placeholder);
}

test "parse still accepts moderate nesting (depth 5)" {
    const a = std.testing.allocator;
    const input = "(((((a = 1)))))";
    const toks = try lexer.lex(a, input);
    defer lexer.freeTokens(a, input, toks);
    const root = try parse(a, toks);
    defer freeNode(a, root);
    try std.testing.expectEqualStrings("a", root.cmp.lhs.path);
}
