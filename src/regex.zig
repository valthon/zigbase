//! Pure-Zig Thompson-NFA regular-expression matcher.
//!
//! A small, dependency-free regex engine used for `text` field `pattern`
//! validation. It is deliberately a BOOLEAN matcher (no captures) with
//! UNANCHORED substring semantics, consistent with PocketBase's MatchString /
//! SQLite's `regexp()`. The defining property is LINEAR-TIME matching: it runs a
//! Pike/Thompson VM that advances a set of thread PCs once per input codepoint
//! with a per-step visited set, so pathological patterns like `(a+)+` cannot
//! trigger catastrophic backtracking.
//!
//! The same parser+emitter runs at runtime (`compile`, caller owns the
//! `Program` and frees via `deinit`) and at comptime (`compileComptime`,
//! `@compileError` on a malformed pattern). Both build into a single bounded
//! `Builder` value type backed by fixed arrays, which keeps one code path that
//! is comptime-friendly (no runtime allocator at comptime).
//!
//! Supported syntax: UTF-8 literals, `.` (any codepoint except `\n`), anchors
//! `^`/`$`, classes `[...]`/`[^...]`/ranges, predefined classes
//! `\d \D \w \W \s \S` (ASCII), escapes `\t \n \r \f \v` and `\`-escaped
//! metacharacters, alternation `X|Y`, non-capturing groups `(...)`/`(?:...)`,
//! and quantifiers `* + ?` plus bounded `{m}` `{m,}` `{m,n}` (greedy; greediness
//! is irrelevant to a boolean match).

const std = @import("std");

pub const CompileError = error{ InvalidPattern, PatternTooComplex, OutOfMemory };

// Size caps. A pattern whose compiled program or expanded repetition exceeds
// these is rejected as `PatternTooComplex` (a DoS guard against e.g. `a{9}{9}`
// style blowups or huge `{m,n}` bounds).
const MAX_INSTS = 16384;
const MAX_CLASSES = 1024;
const MAX_NODES = 8192;
const MAX_RANGES = 256; // ranges per class
const MAX_SEQ = 2048; // concat pieces / alt branches at a single nesting level

// ---- Character class --------------------------------------------------------

/// A character class is a value type with a fixed-capacity range array, so it
/// nests inside the fixed-array `Builder` with no secondary allocation.
pub const Class = struct {
    negated: bool = false,
    /// Inclusive [lo, hi] codepoint ranges; a single char is lo==hi.
    ranges: [MAX_RANGES][2]u21 = undefined,
    len: usize = 0,

    fn add(self: *Class, lo: u21, hi: u21) CompileError!void {
        if (self.len >= MAX_RANGES) return error.PatternTooComplex;
        self.ranges[self.len] = .{ lo, hi };
        self.len += 1;
    }

    fn contains(self: *const Class, cp: u21) bool {
        var hit = false;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (cp >= self.ranges[i][0] and cp <= self.ranges[i][1]) {
                hit = true;
                break;
            }
        }
        return if (self.negated) !hit else hit;
    }
};

// ---- Instruction set --------------------------------------------------------

const OpTag = enum { char, any, class, match, jmp, split, bol, eol };

const Inst = union(OpTag) {
    char: u21,
    any,
    class: usize, // index into the class table
    match,
    jmp: usize,
    split: [2]usize,
    bol,
    eol,
};

/// A compiled program: a flat instruction list plus the class table it indexes.
/// Returned by `compile`/`compileComptime`; the runtime form owns its slices and
/// must be released via `deinit`.
pub const Program = struct {
    insts: []const Inst,
    classes: []const Class,

    pub fn deinit(self: Program, alloc: std.mem.Allocator) void {
        alloc.free(self.insts);
        alloc.free(self.classes);
    }
};

// ---- AST --------------------------------------------------------------------

const NodeTag = enum { empty, char, any, class, concat, alt, star, plus, quest, repeat, bol, eol };

const Node = struct {
    tag: NodeTag,
    // char
    cp: u21 = 0,
    // class
    class_idx: usize = 0,
    // unary children (star/plus/quest/repeat operand)
    child: ?usize = null,
    // concat/alt children: indices into the node list, [kids_start, kids_end)
    kids_start: usize = 0,
    kids_end: usize = 0,
    // repeat bounds
    min: usize = 0,
    max: ?usize = null,
};

// ---- Builder (shared comptime+runtime, fixed-array backed) -------------------

const Builder = struct {
    // Program output
    insts: [MAX_INSTS]Inst = undefined,
    ninsts: usize = 0,
    classes: [MAX_CLASSES]Class = undefined,
    nclasses: usize = 0,

    // AST storage
    nodes: [MAX_NODES]Node = undefined,
    nnodes: usize = 0,
    // child-index pool for concat/alt
    kids: [MAX_NODES]usize = undefined,
    nkids: usize = 0,

    // Parser cursor over the pattern
    pat: []const u8 = &.{},
    pos: usize = 0,

    fn emit(self: *Builder, inst: Inst) CompileError!usize {
        if (self.ninsts >= MAX_INSTS) return error.PatternTooComplex;
        const at = self.ninsts;
        self.insts[at] = inst;
        self.ninsts += 1;
        return at;
    }

    fn newNode(self: *Builder, node: Node) CompileError!usize {
        if (self.nnodes >= MAX_NODES) return error.PatternTooComplex;
        const at = self.nnodes;
        self.nodes[at] = node;
        self.nnodes += 1;
        return at;
    }

    fn newClass(self: *Builder) CompileError!usize {
        if (self.nclasses >= MAX_CLASSES) return error.PatternTooComplex;
        const at = self.nclasses;
        self.classes[at] = .{};
        self.nclasses += 1;
        return at;
    }

    // -- UTF-8 decode of the pattern itself -----------------------------------

    fn peekByte(self: *const Builder) ?u8 {
        if (self.pos >= self.pat.len) return null;
        return self.pat[self.pos];
    }

    /// Decode one codepoint from the pattern at `pos`, advancing past it.
    fn nextCp(self: *Builder) CompileError!u21 {
        if (self.pos >= self.pat.len) return error.InvalidPattern;
        const first = self.pat[self.pos];
        const n = std.unicode.utf8ByteSequenceLength(first) catch return error.InvalidPattern;
        if (self.pos + n > self.pat.len) return error.InvalidPattern;
        const cp = std.unicode.utf8Decode(self.pat[self.pos .. self.pos + n]) catch return error.InvalidPattern;
        self.pos += n;
        return cp;
    }

    // ---- Recursive-descent parser ---------------------------------------
    // Grammar: alt -> concat ('|' concat)*
    //          concat -> repeat*
    //          repeat -> atom quantifier?
    //          atom -> '(' alt ')' | '[' class ']' | '.' | '^' | '$' | literal

    fn parseAlt(self: *Builder) CompileError!usize {
        const first = try self.parseConcat();
        if (self.peekByte() != '|') return first;

        // Collect branch node indices into a local buffer first; the shared
        // `kids` pool is appended to by nested parseConcat calls, so we cannot
        // reserve a contiguous range until all branches are parsed.
        var local: [MAX_SEQ]usize = undefined;
        var nlocal: usize = 0;
        local[nlocal] = first;
        nlocal += 1;
        while (self.peekByte() == '|') {
            self.pos += 1; // consume '|'
            const branch = try self.parseConcat();
            if (nlocal >= local.len) return error.PatternTooComplex;
            local[nlocal] = branch;
            nlocal += 1;
        }
        const ks = self.nkids;
        var i: usize = 0;
        while (i < nlocal) : (i += 1) try self.pushKid(local[i]);
        const ke = self.nkids;
        return self.newNode(.{ .tag = .alt, .kids_start = ks, .kids_end = ke });
    }

    fn pushKid(self: *Builder, idx: usize) CompileError!void {
        if (self.nkids >= MAX_NODES) return error.PatternTooComplex;
        self.kids[self.nkids] = idx;
        self.nkids += 1;
    }

    fn parseConcat(self: *Builder) CompileError!usize {
        // Collect pieces into a local buffer (nested parses may append to the
        // shared `kids` pool), then reserve one contiguous range at the end.
        var local: [MAX_SEQ]usize = undefined;
        var nlocal: usize = 0;
        while (true) {
            const b = self.peekByte();
            if (b == null or b == '|' or b == ')') break;
            const piece = try self.parseRepeat();
            if (nlocal >= local.len) return error.PatternTooComplex;
            local[nlocal] = piece;
            nlocal += 1;
        }
        if (nlocal == 0) {
            return self.newNode(.{ .tag = .empty });
        }
        if (nlocal == 1) {
            return local[0];
        }
        const ks = self.nkids;
        var i: usize = 0;
        while (i < nlocal) : (i += 1) try self.pushKid(local[i]);
        const ke = self.nkids;
        return self.newNode(.{ .tag = .concat, .kids_start = ks, .kids_end = ke });
    }

    fn parseRepeat(self: *Builder) CompileError!usize {
        const atom = try self.parseAtom();
        const b = self.peekByte() orelse return atom;
        switch (b) {
            '*' => {
                self.pos += 1;
                return self.newNode(.{ .tag = .star, .child = atom });
            },
            '+' => {
                self.pos += 1;
                return self.newNode(.{ .tag = .plus, .child = atom });
            },
            '?' => {
                self.pos += 1;
                return self.newNode(.{ .tag = .quest, .child = atom });
            },
            '{' => return self.parseBrace(atom),
            else => return atom,
        }
    }

    fn parseBrace(self: *Builder, atom: usize) CompileError!usize {
        // pos points at '{'. Parse {m}, {m,}, or {m,n}.
        self.pos += 1; // consume '{'
        const min = try self.parseInt();
        var max: ?usize = min;
        if (self.peekByte() == ',') {
            self.pos += 1;
            if (self.peekByte() == '}') {
                max = null; // {m,}
            } else {
                max = try self.parseInt();
            }
        }
        if (self.peekByte() != '}') return error.InvalidPattern;
        self.pos += 1; // consume '}'

        if (max) |mx| {
            if (mx < min) return error.InvalidPattern;
        }
        return self.newNode(.{ .tag = .repeat, .child = atom, .min = min, .max = max });
    }

    fn parseInt(self: *Builder) CompileError!usize {
        const start = self.pos;
        var val: usize = 0;
        while (self.peekByte()) |c| {
            if (c < '0' or c > '9') break;
            val = val * 10 + (c - '0');
            if (val > MAX_INSTS) return error.PatternTooComplex;
            self.pos += 1;
        }
        if (self.pos == start) return error.InvalidPattern;
        return val;
    }

    fn parseAtom(self: *Builder) CompileError!usize {
        const b = self.peekByte() orelse return error.InvalidPattern;
        switch (b) {
            '(' => {
                self.pos += 1;
                // Optional non-capturing group prefix "(?:"
                if (self.peekByte() == '?') {
                    if (self.pos + 1 < self.pat.len and self.pat[self.pos + 1] == ':') {
                        self.pos += 2;
                    } else {
                        return error.InvalidPattern;
                    }
                }
                const inner = try self.parseAlt();
                if (self.peekByte() != ')') return error.InvalidPattern;
                self.pos += 1;
                return inner;
            },
            ')' => return error.InvalidPattern,
            '[' => return self.parseClass(),
            '.' => {
                self.pos += 1;
                return self.newNode(.{ .tag = .any });
            },
            '^' => {
                self.pos += 1;
                return self.newNode(.{ .tag = .bol });
            },
            '$' => {
                self.pos += 1;
                return self.newNode(.{ .tag = .eol });
            },
            '*', '+', '?' => return error.InvalidPattern, // dangling quantifier
            '\\' => {
                self.pos += 1; // consume backslash
                return self.parseEscape();
            },
            else => {
                const cp = try self.nextCp();
                return self.newNode(.{ .tag = .char, .cp = cp });
            },
        }
    }

    /// Parse an escape sequence after a consumed backslash, returning a node.
    fn parseEscape(self: *Builder) CompileError!usize {
        const c = self.peekByte() orelse return error.InvalidPattern;
        // Predefined classes
        switch (c) {
            'd', 'D', 'w', 'W', 's', 'S' => {
                self.pos += 1;
                const idx = try self.buildPredefined(c);
                return self.newNode(.{ .tag = .class, .class_idx = idx });
            },
            else => {},
        }
        const cp = try self.escapeCp(c);
        return self.newNode(.{ .tag = .char, .cp = cp });
    }

    /// Resolve a single escaped char (after backslash) to its codepoint value.
    fn escapeCp(self: *Builder, c: u8) CompileError!u21 {
        const cp: u21 = switch (c) {
            't' => '\t',
            'n' => '\n',
            'r' => '\r',
            'f' => 0x0C,
            'v' => 0x0B,
            '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$', '\\', '-' => c,
            else => return error.InvalidPattern,
        };
        self.pos += 1;
        return cp;
    }

    fn buildPredefined(self: *Builder, c: u8) CompileError!usize {
        const idx = try self.newClass();
        const cls = &self.classes[idx];
        switch (c) {
            'd' => try cls.add('0', '9'),
            'D' => {
                cls.negated = true;
                try cls.add('0', '9');
            },
            'w' => {
                try cls.add('a', 'z');
                try cls.add('A', 'Z');
                try cls.add('0', '9');
                try cls.add('_', '_');
            },
            'W' => {
                cls.negated = true;
                try cls.add('a', 'z');
                try cls.add('A', 'Z');
                try cls.add('0', '9');
                try cls.add('_', '_');
            },
            's' => try self.addWhitespace(cls),
            'S' => {
                cls.negated = true;
                try self.addWhitespace(cls);
            },
            else => unreachable,
        }
        return idx;
    }

    fn addWhitespace(self: *Builder, cls: *Class) CompileError!void {
        _ = self;
        try cls.add(' ', ' ');
        try cls.add('\t', '\t');
        try cls.add('\n', '\n');
        try cls.add('\r', '\r');
        try cls.add(0x0C, 0x0C); // \f
        try cls.add(0x0B, 0x0B); // \v
    }

    /// Parse `[...]` starting at '['.
    fn parseClass(self: *Builder) CompileError!usize {
        self.pos += 1; // consume '['
        const idx = try self.newClass();
        const cls = &self.classes[idx];
        if (self.peekByte() == '^') {
            cls.negated = true;
            self.pos += 1;
        }
        // A leading ']' is a literal in many regex flavors, but we keep it
        // strict: empty class is invalid; ']' closes.
        var count: usize = 0;
        while (true) {
            const b = self.peekByte() orelse return error.InvalidPattern; // unterminated
            if (b == ']') {
                self.pos += 1;
                break;
            }
            // A predefined class member (\d \w \s) folds whole ranges into the
            // class and cannot be a range endpoint; handle it separately.
            if (b == '\\' and self.pos + 1 < self.pat.len and isPredefinedClassChar(self.pat[self.pos + 1])) {
                self.pos += 1; // consume '\'
                const c = self.peekByte().?;
                self.pos += 1; // consume the class letter
                try self.foldPredefinedInto(cls, c);
                count += 1;
                continue;
            }
            const lo = try self.classChar();
            // Range?  lo '-' hi  (but a trailing '-' before ']' is literal)
            if (self.peekByte() == '-' and self.pos + 1 < self.pat.len and self.pat[self.pos + 1] != ']') {
                self.pos += 1; // consume '-'
                const hi = try self.classChar();
                if (hi < lo) return error.InvalidPattern;
                try cls.add(lo, hi);
            } else {
                try cls.add(lo, lo);
            }
            count += 1;
        }
        if (count == 0) return error.InvalidPattern;
        return self.newNode(.{ .tag = .class, .class_idx = idx });
    }

    fn isPredefinedClassChar(c: u8) bool {
        return c == 'd' or c == 'w' or c == 's';
    }

    /// Fold a predefined class (only the lowercase, non-negated forms are valid
    /// inside `[...]`) into an existing class's ranges.
    fn foldPredefinedInto(self: *Builder, cls: *Class, c: u8) CompileError!void {
        switch (c) {
            'd' => try cls.add('0', '9'),
            'w' => {
                try cls.add('a', 'z');
                try cls.add('A', 'Z');
                try cls.add('0', '9');
                try cls.add('_', '_');
            },
            's' => try self.addWhitespace(cls),
            else => unreachable,
        }
    }

    /// Read one (possibly escaped) literal member codepoint inside a class.
    fn classChar(self: *Builder) CompileError!u21 {
        const b = self.peekByte() orelse return error.InvalidPattern;
        if (b == '\\') {
            self.pos += 1;
            const c = self.peekByte() orelse return error.InvalidPattern;
            return self.escapeCp(c);
        }
        return self.nextCp();
    }

    // ---- Emit: AST -> Thompson program ----------------------------------

    fn emitNode(self: *Builder, idx: usize) CompileError!void {
        const node = self.nodes[idx];
        switch (node.tag) {
            .empty => {},
            .char => _ = try self.emit(.{ .char = node.cp }),
            .any => _ = try self.emit(.any),
            .class => _ = try self.emit(.{ .class = node.class_idx }),
            .bol => _ = try self.emit(.bol),
            .eol => _ = try self.emit(.eol),
            .concat => {
                var i = node.kids_start;
                while (i < node.kids_end) : (i += 1) {
                    try self.emitNode(self.kids[i]);
                }
            },
            .alt => try self.emitAlt(node.kids_start, node.kids_end),
            .star => try self.emitStar(node.child.?),
            .plus => try self.emitPlus(node.child.?),
            .quest => try self.emitQuest(node.child.?),
            .repeat => try self.emitRepeat(node.child.?, node.min, node.max),
        }
    }

    fn emitAlt(self: *Builder, ks: usize, ke: usize) CompileError!void {
        // split L1,L2; L1: <a>; jmp END; L2: <rest...>; END:
        // Chain for >2 branches.
        if (ke - ks == 1) {
            try self.emitNode(self.kids[ks]);
            return;
        }
        const split_at = try self.emit(.{ .split = .{ 0, 0 } });
        const l1 = self.ninsts;
        try self.emitNode(self.kids[ks]);
        const jmp_at = try self.emit(.{ .jmp = 0 });
        const l2 = self.ninsts;
        try self.emitAlt(ks + 1, ke);
        const end = self.ninsts;
        self.insts[split_at] = .{ .split = .{ l1, l2 } };
        self.insts[jmp_at] = .{ .jmp = end };
    }

    fn emitStar(self: *Builder, child: usize) CompileError!void {
        // L1: split L2,END; L2: <x>; jmp L1; END:
        const l1 = try self.emit(.{ .split = .{ 0, 0 } });
        const l2 = self.ninsts;
        try self.emitNode(child);
        _ = try self.emit(.{ .jmp = l1 });
        const end = self.ninsts;
        self.insts[l1] = .{ .split = .{ l2, end } };
    }

    fn emitPlus(self: *Builder, child: usize) CompileError!void {
        // L1: <x>; split L1,END; END:
        const l1 = self.ninsts;
        try self.emitNode(child);
        const split_at = try self.emit(.{ .split = .{ 0, 0 } });
        const end = self.ninsts;
        self.insts[split_at] = .{ .split = .{ l1, end } };
    }

    fn emitQuest(self: *Builder, child: usize) CompileError!void {
        // split L1,END; L1: <x>; END:
        const split_at = try self.emit(.{ .split = .{ 0, 0 } });
        const l1 = self.ninsts;
        try self.emitNode(child);
        const end = self.ninsts;
        self.insts[split_at] = .{ .split = .{ l1, end } };
    }

    fn emitRepeat(self: *Builder, child: usize, min: usize, max: ?usize) CompileError!void {
        // Emit <x> min times, then the optional tail.
        var i: usize = 0;
        while (i < min) : (i += 1) {
            try self.emitNode(child);
        }
        if (max) |mx| {
            // (mx - min) quest-wrapped copies.
            var j: usize = min;
            while (j < mx) : (j += 1) {
                try self.emitQuest(child);
            }
        } else {
            // {m,} : a star of <x> for the unbounded tail.
            try self.emitStar(child);
        }
    }

    /// Parse the whole pattern and emit the final program (terminated by match).
    fn build(self: *Builder, pattern: []const u8) CompileError!void {
        self.pat = pattern;
        self.pos = 0;
        const root = try self.parseAlt();
        if (self.pos != self.pat.len) return error.InvalidPattern; // trailing junk e.g. unmatched ')'
        try self.emitNode(root);
        _ = try self.emit(.match);
    }
};

// ---- Public compile entry points -------------------------------------------

pub fn compile(alloc: std.mem.Allocator, pattern: []const u8) CompileError!Program {
    // Build into a heap-allocated scratch Builder (it is large for the stack).
    const b = try alloc.create(Builder);
    defer alloc.destroy(b);
    b.* = .{};
    try b.build(pattern);

    const insts = try alloc.dupe(Inst, b.insts[0..b.ninsts]);
    errdefer alloc.free(insts);
    const classes = try alloc.dupe(Class, b.classes[0..b.nclasses]);
    return .{ .insts = insts, .classes = classes };
}

pub fn compileComptime(comptime pattern: []const u8) Program {
    comptime {
        var b: Builder = .{};
        b.build(pattern) catch |err| {
            @compileError("invalid regex pattern \"" ++ pattern ++ "\": " ++ @errorName(err));
        };
        const insts = b.insts[0..b.ninsts].*;
        const classes = b.classes[0..b.nclasses].*;
        const insts_final = insts;
        const classes_final = classes;
        return .{ .insts = &insts_final, .classes = &classes_final };
    }
}

// ---- Matcher: Pike/Thompson VM ---------------------------------------------

const ThreadList = struct {
    pcs: []usize,
    len: usize,
    // visited[pc] generation stamp; a pc is added once per step.
    seen: []u32,
    gen: u32,

    fn clear(self: *ThreadList, generation: u32) void {
        self.len = 0;
        self.gen = generation;
    }
};

/// Add `pc` to `list`, following epsilon transitions (jmp/split/bol/eol).
/// `pos` is the current byte offset into the haystack (for `^`/`$`).
/// `at_start`/`at_end` flags describe the position for anchors.
fn addThread(
    prog: Program,
    list: *ThreadList,
    pc: usize,
    at_start: bool,
    at_end: bool,
) void {
    if (list.seen[pc] == list.gen) return;
    list.seen[pc] = list.gen;
    switch (prog.insts[pc]) {
        .jmp => |target| addThread(prog, list, target, at_start, at_end),
        .split => |targets| {
            addThread(prog, list, targets[0], at_start, at_end);
            addThread(prog, list, targets[1], at_start, at_end);
        },
        .bol => if (at_start) addThread(prog, list, pc + 1, at_start, at_end),
        .eol => if (at_end) addThread(prog, list, pc + 1, at_start, at_end),
        else => {
            // char/any/class/match: a "real" thread that consumes (or matches).
            list.pcs[list.len] = pc;
            list.len += 1;
        },
    }
}

/// Boolean, UNANCHORED (substring) match. Allocation-free, linear-time.
pub fn matches(prog: Program, haystack: []const u8) bool {
    const n = prog.insts.len;
    var clist_pcs: [MAX_INSTS]usize = undefined;
    var nlist_pcs: [MAX_INSTS]usize = undefined;
    var clist_seen: [MAX_INSTS]u32 = [_]u32{0} ** MAX_INSTS;
    var nlist_seen: [MAX_INSTS]u32 = [_]u32{0} ** MAX_INSTS;

    var clist = ThreadList{ .pcs = clist_pcs[0..n], .len = 0, .seen = clist_seen[0..n], .gen = 0 };
    var nlist = ThreadList{ .pcs = nlist_pcs[0..n], .len = 0, .seen = nlist_seen[0..n], .gen = 0 };
    var cur = &clist;
    var next = &nlist;
    var generation: u32 = 0;

    var pos: usize = 0;
    var matched = false;

    // Seed initial generation at pos 0 with the start thread.
    generation += 1;
    cur.clear(generation);
    addThread(prog, cur, 0, pos == 0, pos >= haystack.len);

    while (true) {
        const at_end = pos >= haystack.len;

        // Check for a match in the current thread set; also detect dead set.
        {
            var i: usize = 0;
            while (i < cur.len) : (i += 1) {
                if (prog.insts[cur.pcs[i]] == .match) {
                    matched = true;
                    break;
                }
            }
        }
        if (matched) return true;

        if (at_end) break;

        // Decode current codepoint.
        const first = haystack[pos];
        var seqlen = std.unicode.utf8ByteSequenceLength(first) catch 1;
        if (pos + seqlen > haystack.len) seqlen = 1;
        const cp: u21 = blk: {
            if (seqlen == 1) break :blk first;
            break :blk std.unicode.utf8Decode(haystack[pos .. pos + seqlen]) catch {
                seqlen = 1;
                break :blk first;
            };
        };

        const next_pos = pos + seqlen;
        const next_at_start = false; // never at start after consuming
        const next_at_end = next_pos >= haystack.len;

        generation += 1;
        next.clear(generation);

        var i: usize = 0;
        while (i < cur.len) : (i += 1) {
            const pc = cur.pcs[i];
            const inst = prog.insts[pc];
            const consumes = switch (inst) {
                .char => |want| cp == want,
                .any => cp != '\n',
                .class => |ci| prog.classes[ci].contains(cp),
                else => false, // .match handled above
            };
            if (consumes) {
                addThread(prog, next, pc + 1, next_at_start, next_at_end);
            }
        }

        // Unanchored: also seed a fresh start thread at the next position.
        addThread(prog, next, 0, next_at_start, next_at_end);

        // Swap.
        const tmp = cur;
        cur = next;
        next = tmp;
        pos = next_pos;
    }

    return matched;
}

// ============================================================================
// Tests
// ============================================================================

const t = std.testing;

fn isMatch(comptime pat: []const u8, hay: []const u8) bool {
    const prog = compile(t.allocator, pat) catch unreachable;
    defer prog.deinit(t.allocator);
    return matches(prog, hay);
}

test "literals and unanchored substring" {
    try t.expect(isMatch("abc", "xxabcyy"));
    try t.expect(!isMatch("abc", "ab"));
}
test "anchors" {
    try t.expect(isMatch("^abc$", "abc"));
    try t.expect(!isMatch("^abc$", "xabc"));
    try t.expect(!isMatch("^abc$", "abcx"));
}
test "dot excludes newline" {
    try t.expect(isMatch("a.c", "abc"));
    try t.expect(!isMatch("^a.c$", "a\nc"));
}
test "classes and ranges and negation" {
    try t.expect(isMatch("^[a-z]+$", "hello"));
    try t.expect(!isMatch("^[a-z]+$", "Hello"));
    try t.expect(isMatch("^[^0-9]+$", "abc"));
    try t.expect(!isMatch("^[^0-9]+$", "ab3"));
}
test "predefined classes" {
    try t.expect(isMatch("^\\d{3}-\\d{4}$", "123-4567"));
    try t.expect(!isMatch("^\\d{3}-\\d{4}$", "12-4567"));
    try t.expect(isMatch("^\\w+$", "a_b9"));
    try t.expect(isMatch("^\\s$", " "));
}
test "alternation and groups" {
    try t.expect(isMatch("^(cat|dog|fish)$", "dog"));
    try t.expect(!isMatch("^(cat|dog)$", "cow"));
    try t.expect(isMatch("^(ab)+$", "ababab"));
}
test "quantifiers" {
    try t.expect(isMatch("^a*$", ""));
    try t.expect(isMatch("^a+$", "aaa"));
    try t.expect(!isMatch("^a+$", ""));
    try t.expect(isMatch("^colou?r$", "color"));
    try t.expect(isMatch("^colou?r$", "colour"));
    try t.expect(isMatch("^a{2,4}$", "aaa"));
    try t.expect(!isMatch("^a{2,4}$", "a"));
    try t.expect(!isMatch("^a{2,4}$", "aaaaa"));
    try t.expect(isMatch("^a{2,}$", "aaaaa"));
    try t.expect(isMatch("^a{3}$", "aaa"));
    try t.expect(!isMatch("^a{3}$", "aa"));
}
test "escaped metacharacters" {
    try t.expect(isMatch("^a\\.b$", "a.b"));
    try t.expect(!isMatch("^a\\.b$", "axb"));
}
test "utf8 literals and ranges" {
    try t.expect(isMatch("^λ+$", "λλ"));
}
test "invalid patterns are rejected" {
    try t.expectError(error.InvalidPattern, compile(t.allocator, "("));
    try t.expectError(error.InvalidPattern, compile(t.allocator, "a{2,1}"));
    try t.expectError(error.InvalidPattern, compile(t.allocator, "*abc"));
}
test "no catastrophic backtracking (linear time)" {
    const prog = try compile(t.allocator, "^(a+)+$");
    defer prog.deinit(t.allocator);
    const hay = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!"; // 36 a's then mismatch
    try t.expect(!matches(prog, hay));
}
test "compiles and matches at comptime" {
    const prog = comptime compileComptime("^\\d+$");
    try t.expect(matches(prog, "12345"));
    try t.expect(!matches(prog, "12a45"));
}
