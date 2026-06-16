# Enforce `text.pattern` and `date` min/max — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Actually enforce `text.pattern` (regex) and `date` `min`/`max` on record writes, validated at runtime and (where comptime-known) at build time, removing the two "accepted but not enforced" footguns.

**Architecture:** Two new pure-Zig modules — `src/regex.zig` (a Thompson-NFA boolean matcher, linear-time/DoS-safe, usable at comptime and runtime) and `src/datetime.zig` (a date→UTC-seconds normalizer, comptime-callable). They are wired into `records.validateFieldValue` (per-write enforcement), `schema.validate` (definition-time rejection of bad patterns/bounds), and `provision.buildOptions` (build-time `@compileError` for comptime schema literals). No `build.zig`/C/vendor changes.

**Tech Stack:** Zig 0.16.0, existing `src/schema.zig` field model, `std.json.Value` record values, Python/Playwright admin suite.

**Build/test commands (this repo):**
- Build: `mise exec zig@0.16.0 -- zig build`
- Unit tests: `mise exec zig@0.16.0 -- zig build test --summary all` (authoritative signal is the `Build Summary: N/N tests passed` line; a spurious `failed command:` line prints even on success)
- One browser test: `mise exec python@3.13 -- python -m pytest tests/admin/<file>::<test> -q`

> **Note for the executing agent:** The `src/regex.zig` implementation below is a complete reference. Drive it to green against the provided tests with TDD; if the Zig 0.16 compiler rejects a construct (especially in the comptime path), fix to satisfy the tests rather than abandoning the approach. The matcher is boolean-only and must remain backtracking-free (linear-time).

---

## File Structure

- **Create** `src/datetime.zig` — date/datetime parse+normalize to UTC seconds. One responsibility: turn an accepted date string into a comparable `i64` with strict validation. Owns its own tests.
- **Create** `src/regex.zig` — Thompson-NFA regex compile (`compile` runtime / `compileComptime`) + boolean `matches`. Owns its own tests.
- **Modify** `src/root.zig` — add both files to the unit-test root block (and only there; they stay internal).
- **Modify** `src/records.zig` — enforce pattern in the `.text` arm and date format/min/max in the `.date` arm of `validateFieldValue`; rewrite the two "NOT enforced" tests.
- **Modify** `src/schema.zig` — `validate` rejects an uncompilable `pattern` and an unparseable date `min`/`max`.
- **Modify** `src/provision.zig` — `buildOptions` `.text`/`.date` arms `@compileError` on a bad comptime pattern / date bound.
- **Modify** `tests/admin/<schema test>` — Playwright coverage for a pattern-rejected and a date-range-rejected record create.
- **Modify (docs)** `KNOWN_LIMITATIONS.md`, `site/src/content/docs/known-limitations.md`, `docs/fields.md`, `site/src/content/docs/fields.md`, `docs/framework.md`, `docs/security-audit.md`, `CHANGELOG.md`, `site/src/content/docs/changelog.md`.
- **Audit** `examples/golfsim/src/main.zig` — confirm its date field's data conforms; fix if it relied on non-enforcement.

---

## Task 1: Date normalizer (`src/datetime.zig`)

**Files:**
- Create: `src/datetime.zig`
- Modify: `src/root.zig` (test-root wiring happens in Task 3; do not wire yet)

- [ ] **Step 1: Write the module with its failing tests**

Create `src/datetime.zig`:

```zig
//! Minimal, dependency-free date/datetime parsing for `date` field min/max
//! enforcement. Pure Zig, so it runs at BOTH comptime (validating schema-literal
//! bounds via @compileError) and runtime (validating record values). Parses to
//! UTC seconds since the Unix epoch for ordered comparison.

const std = @import("std");

pub const ParseError = error{ InvalidFormat, OutOfRange };

/// Parse an accepted date/datetime string to UTC seconds since 1970-01-01T00:00:00Z.
/// Accepted grammar:
///   YYYY-MM-DD
///   YYYY-MM-DD( |T)HH:MM[:SS][.fff...]
///   ...optionally followed by 'Z' or ±HH:MM
/// A missing zone is treated as UTC. Components are range-checked (leap years
/// included); trailing garbage is rejected.
pub fn parse(s: []const u8) ParseError!i64 {
    var i: usize = 0;
    const year = try readN(s, &i, 4);
    try lit(s, &i, '-');
    const month = try readN(s, &i, 2);
    try lit(s, &i, '-');
    const day = try readN(s, &i, 2);

    if (month < 1 or month > 12) return error.OutOfRange;
    if (day < 1 or day > daysInMonth(year, month)) return error.OutOfRange;

    var hour: i64 = 0;
    var min: i64 = 0;
    var sec: i64 = 0;
    var offset: i64 = 0; // seconds east of UTC

    if (i < s.len) {
        if (s[i] != 'T' and s[i] != ' ') return error.InvalidFormat;
        i += 1;
        hour = try readN(s, &i, 2);
        try lit(s, &i, ':');
        min = try readN(s, &i, 2);
        if (i < s.len and s[i] == ':') {
            i += 1;
            sec = try readN(s, &i, 2);
            if (i < s.len and s[i] == '.') {
                i += 1;
                var any = false;
                while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) any = true;
                if (!any) return error.InvalidFormat;
            }
        }
        if (hour > 23 or min > 59 or sec > 59) return error.OutOfRange;
        if (i < s.len) {
            if (s[i] == 'Z') {
                i += 1;
            } else if (s[i] == '+' or s[i] == '-') {
                const sign: i64 = if (s[i] == '-') -1 else 1;
                i += 1;
                const oh = try readN(s, &i, 2);
                try lit(s, &i, ':');
                const om = try readN(s, &i, 2);
                if (oh > 23 or om > 59) return error.OutOfRange;
                offset = sign * (oh * 3600 + om * 60);
            }
        }
    }

    if (i != s.len) return error.InvalidFormat; // trailing garbage

    const days = daysFromCivil(year, month, day);
    return days * 86400 + hour * 3600 + min * 60 + sec - offset;
}

fn readN(s: []const u8, i: *usize, n: usize) ParseError!i64 {
    if (i.* + n > s.len) return error.InvalidFormat;
    var v: i64 = 0;
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const c = s[i.* + k];
        if (c < '0' or c > '9') return error.InvalidFormat;
        v = v * 10 + (c - '0');
    }
    i.* += n;
    return v;
}

fn lit(s: []const u8, i: *usize, c: u8) ParseError!void {
    if (i.* >= s.len or s[i.*] != c) return error.InvalidFormat;
    i.* += 1;
}

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

fn daysInMonth(y: i64, m: i64) i64 {
    const tbl = [_]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (m == 2 and isLeap(y)) return 29;
    return tbl[@intCast(m - 1)];
}

/// Howard Hinnant's days_from_civil: days since 1970-01-01 (negative before).
/// Uses floor division so it is correct for negative years too.
fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    const y = if (m <= 2) y_in - 1 else y_in;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = if (m > 2) m - 3 else m + 9; // Mar=0..Feb=11
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "parses date-only" {
    try std.testing.expectEqual(@as(i64, 0), try parse("1970-01-01"));
    try std.testing.expectEqual(@as(i64, 86400), try parse("1970-01-02"));
}

test "parses canonical stored form (T...Z)" {
    const a = try parse("2026-06-10T08:00:00Z");
    const b = try parse("2026-06-10 08:00:00"); // space form, no zone == UTC
    try std.testing.expectEqual(a, b);
}

test "fractional seconds accepted, truncated" {
    const a = try parse("2026-06-10T08:00:00.123Z");
    const b = try parse("2026-06-10T08:00:00Z");
    try std.testing.expectEqual(a, b);
}

test "numeric offset folds to UTC" {
    // 10:00+02:00 == 08:00Z
    try std.testing.expectEqual(try parse("2026-06-10T08:00:00Z"), try parse("2026-06-10T10:00:00+02:00"));
}

test "rejects garbage time components" {
    try std.testing.expectError(error.OutOfRange, parse("2026-06-10 25:99:99"));
    try std.testing.expectError(error.OutOfRange, parse("2026-13-01"));
    try std.testing.expectError(error.OutOfRange, parse("2026-02-29")); // 2026 not leap
    _ = try parse("2024-02-29"); // 2024 is leap -> ok
}

test "rejects malformed shapes and trailing garbage" {
    try std.testing.expectError(error.InvalidFormat, parse("2026/06/10"));
    try std.testing.expectError(error.InvalidFormat, parse("2026-6-10"));
    try std.testing.expectError(error.InvalidFormat, parse("2026-06-10T08:00:00Zextra"));
    try std.testing.expectError(error.InvalidFormat, parse(""));
}

test "ordering is correct across mixed formats" {
    try std.testing.expect((try parse("2025-12-31 23:59:59")) < (try parse("2026-01-01")));
    try std.testing.expect((try parse("2026-12-31 23:59:59")) < (try parse("2027-01-01 00:00:00")));
}

test "runs at comptime" {
    const v = comptime parse("2026-01-01") catch unreachable;
    try std.testing.expectEqual(v, try parse("2026-01-01"));
}
```

- [ ] **Step 2: Run the tests to confirm they execute and pass**

Because the module is not yet in the test root, run it directly:

Run: `mise exec zig@0.16.0 -- zig test src/datetime.zig`
Expected: `All N tests passed.` If any fail, fix `parse`/`daysFromCivil` until green.

- [ ] **Step 3: Commit**

```bash
git add src/datetime.zig
git commit -m "feat(datetime): comptime-callable date normalizer for date min/max"
```

---

## Task 2: Regex engine (`src/regex.zig`)

**Files:**
- Create: `src/regex.zig`

A Thompson-NFA boolean matcher. Recursive-descent parse → instruction program → Pike-VM simulation that advances a *set* of threads per input codepoint (no backtracking). Compilation is generic over an "emitter" so the same parser feeds a comptime fixed-buffer emitter and a runtime `ArrayList` emitter. Character classes are value types (fixed-capacity range arrays) to avoid nested allocation and work at comptime.

- [ ] **Step 1: Write the engine with its failing tests**

Create `src/regex.zig`:

```zig
//! A small Thompson-NFA regular-expression matcher for `text.pattern` field
//! validation. Linear-time (no backtracking) => no catastrophic-backtracking
//! DoS, even on a pathological pattern like (a+)+$. Pure Zig: `compileComptime`
//! validates schema-literal patterns at build time (@compileError on a bad
//! pattern); `compile` handles runtime/admin-UI patterns. Boolean match only
//! (validation needs match/no-match, not captures). Unanchored (substring)
//! semantics, consistent with PocketBase's MatchString and SQLite regexp().
//!
//! Supported: literals (UTF-8 codepoints), '.', anchors ^ $, classes [..] /
//! [^..] / ranges, \d \D \w \W \s \S, escapes (\t\n\r\f\v and \-escaped
//! metachars), alternation |, non-capturing groups ( ) and (?:..), quantifiers
//! * + ? and bounded {m} {m,} {m,n}. '.' does not match '\n'. \d\w\s are ASCII.

const std = @import("std");

pub const CompileError = error{ InvalidPattern, PatternTooComplex, OutOfMemory };

const MAX_INSTS: usize = 20000; // program-size cap (bounds {m,n} expansion)
const MAX_CLASSES: usize = 256;
const MAX_RANGES: usize = 64; // ranges per class

pub const Class = struct {
    negated: bool = false,
    n: usize = 0,
    ranges: [MAX_RANGES][2]u21 = undefined,

    fn add(self: *Class, lo: u21, hi: u21) CompileError!void {
        if (self.n >= MAX_RANGES) return error.PatternTooComplex;
        self.ranges[self.n] = .{ lo, hi };
        self.n += 1;
    }
    fn matches(self: Class, c: u21) bool {
        var hit = false;
        var k: usize = 0;
        while (k < self.n) : (k += 1) {
            if (c >= self.ranges[k][0] and c <= self.ranges[k][1]) {
                hit = true;
                break;
            }
        }
        return hit != self.negated;
    }
};

const Inst = union(enum) {
    char: u21,
    any,
    class: usize, // index into program classes
    match,
    jmp: usize,
    split: [2]usize,
    bol,
    eol,
};

pub const Program = struct {
    insts: []const Inst,
    classes: []const Class,

    pub fn deinit(self: Program, alloc: std.mem.Allocator) void {
        alloc.free(self.insts);
        alloc.free(self.classes);
    }
};

// ---- generic compiler over an emitter -------------------------------------

fn Parser(comptime Emit: type) type {
    return struct {
        src: []const u8,
        pos: usize = 0,
        e: *Emit,

        const Self = @This();

        fn peek(self: Self) ?u8 {
            return if (self.pos < self.src.len) self.src[self.pos] else null;
        }
        fn next(self: *Self) ?u8 {
            if (self.pos >= self.src.len) return null;
            const c = self.src[self.pos];
            self.pos += 1;
            return c;
        }
        fn eat(self: *Self, c: u8) bool {
            if (self.peek() == c) {
                self.pos += 1;
                return true;
            }
            return false;
        }

        // alternation := concat ('|' concat)*
        fn parseAlt(self: *Self) CompileError!void {
            // Emit: split L1,L2 ; L1: <a> ; jmp END ; L2: <b> ; END:
            const before = self.e.count();
            try self.parseConcat();
            if (self.peek() != '|') return;
            // We need to wrap the already-emitted concat. Easiest robust approach:
            // recompile alternation right-associatively using fragment markers.
            // Insert a split at `before` by shifting is complex; instead we use a
            // two-operand recursive scheme below.
            _ = before;
            while (self.eat('|')) {
                try self.parseConcat();
                // handled by parseAltRec; see note. This simple loop is replaced
                // by parseAltRec for correct wiring.
            }
        }

        // Correct alternation: build list of branch fragments, then chain splits.
        fn parseAltTop(self: *Self) CompileError!void {
            var starts: [64]usize = undefined;
            var ends: [64]usize = undefined; // index of trailing jmp to patch to END
            var count: usize = 0;

            while (true) {
                const s = self.e.count();
                try self.parseConcat();
                if (self.peek() == '|') {
                    // leave a jmp placeholder to END after this branch
                    const j = try self.e.add(.{ .jmp = 0 });
                    if (count >= 64) return error.PatternTooComplex;
                    starts[count] = s;
                    ends[count] = j;
                    count += 1;
                    _ = self.next(); // consume '|'
                    continue;
                } else {
                    if (count >= 64) return error.PatternTooComplex;
                    starts[count] = s;
                    ends[count] = std.math.maxInt(usize); // no trailing jmp on last
                    count += 1;
                    break;
                }
            }
            if (count == 1) return; // no alternation
            // Now weave splits: before branch i (i<last) insert nothing; instead we
            // prepend split instructions. Because instructions are already laid out
            // sequentially, we patch by inserting splits via the emitter's splice.
            try self.e.weaveAlternation(starts[0..count], ends[0..count]);
        }

        // concat := repeat*
        fn parseConcat(self: *Self) CompileError!void {
            while (true) {
                const c = self.peek() orelse return;
                if (c == '|' or c == ')') return;
                try self.parseRepeat();
            }
        }

        // repeat := atom ('*'|'+'|'?'|'{..}')?
        fn parseRepeat(self: *Self) CompileError!void {
            const atom_start = self.e.count();
            try self.parseAtom();
            const c = self.peek() orelse return;
            switch (c) {
                '*' => {
                    self.pos += 1;
                    try self.e.wrapStar(atom_start);
                },
                '+' => {
                    self.pos += 1;
                    try self.e.wrapPlus(atom_start);
                },
                '?' => {
                    self.pos += 1;
                    try self.e.wrapQuest(atom_start);
                },
                '{' => try self.parseBounded(atom_start),
                else => {},
            }
        }

        fn parseBounded(self: *Self, atom_start: usize) CompileError!void {
            // {m}, {m,}, {m,n}
            self.pos += 1; // consume '{'
            const m = try self.readInt();
            var n: ?usize = m;
            if (self.eat(',')) {
                if (self.peek() == '}') {
                    n = null; // {m,}
                } else {
                    n = try self.readInt();
                }
            }
            if (!self.eat('}')) return error.InvalidPattern;
            if (n) |nn| if (nn < m) return error.InvalidPattern;
            try self.e.wrapBounded(atom_start, m, n);
        }

        fn readInt(self: *Self) CompileError!usize {
            var v: usize = 0;
            var any = false;
            while (self.peek()) |c| {
                if (c < '0' or c > '9') break;
                v = v * 10 + (c - '0');
                if (v > 1_000_000) return error.PatternTooComplex;
                self.pos += 1;
                any = true;
            }
            if (!any) return error.InvalidPattern;
            return v;
        }

        // atom := '(' alt ')' | '[' class ']' | '.' | '^' | '$' | '\'esc | literal
        fn parseAtom(self: *Self) CompileError!void {
            const c = self.next() orelse return error.InvalidPattern;
            switch (c) {
                '(' => {
                    if (self.peek() == '?') { // (?:...) non-capturing
                        self.pos += 1;
                        if (!self.eat(':')) return error.InvalidPattern;
                    }
                    try self.parseAltTop();
                    if (!self.eat(')')) return error.InvalidPattern;
                },
                '[' => try self.parseClass(),
                '.' => _ = try self.e.add(.any),
                '^' => _ = try self.e.add(.bol),
                '$' => _ = try self.e.add(.eol),
                '\\' => try self.parseEscape(),
                ')' , '|' => return error.InvalidPattern,
                '*', '+', '?' => return error.InvalidPattern, // nothing to repeat
                else => {
                    // decode a UTF-8 codepoint starting at the byte just consumed
                    self.pos -= 1;
                    const cp = try self.readCodepoint();
                    _ = try self.e.add(.{ .char = cp });
                },
            }
        }

        fn readCodepoint(self: *Self) CompileError!u21 {
            const len = std.unicode.utf8ByteSequenceLength(self.src[self.pos]) catch return error.InvalidPattern;
            if (self.pos + len > self.src.len) return error.InvalidPattern;
            const cp = std.unicode.utf8Decode(self.src[self.pos .. self.pos + len]) catch return error.InvalidPattern;
            self.pos += len;
            return cp;
        }

        fn parseEscape(self: *Self) CompileError!void {
            const c = self.next() orelse return error.InvalidPattern;
            switch (c) {
                'd', 'D', 'w', 'W', 's', 'S' => {
                    var cls = Class{};
                    fillPredef(&cls, c) catch return error.PatternTooComplex;
                    const idx = try self.e.addClass(cls);
                    _ = try self.e.add(.{ .class = idx });
                },
                't' => _ = try self.e.add(.{ .char = '\t' }),
                'n' => _ = try self.e.add(.{ .char = '\n' }),
                'r' => _ = try self.e.add(.{ .char = '\r' }),
                'f' => _ = try self.e.add(.{ .char = 0x0C }),
                'v' => _ = try self.e.add(.{ .char = 0x0B }),
                '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '^', '$' => _ = try self.e.add(.{ .char = c }),
                else => return error.InvalidPattern,
            }
        }

        fn parseClass(self: *Self) CompileError!void {
            var cls = Class{};
            if (self.eat('^')) cls.negated = true;
            var first = true;
            while (true) {
                const c = self.peek() orelse return error.InvalidPattern;
                if (c == ']' and !first) {
                    self.pos += 1;
                    break;
                }
                first = false;
                if (c == '\\') {
                    self.pos += 1;
                    const e = self.next() orelse return error.InvalidPattern;
                    switch (e) {
                        'd', 'D', 'w', 'W', 's', 'S' => {
                            // merge a predefined class's ranges (only when non-negated forms)
                            var sub = Class{};
                            try fillPredef(&sub, e);
                            if (sub.negated) return error.InvalidPattern; // \D etc. inside [] unsupported
                            var k: usize = 0;
                            while (k < sub.n) : (k += 1) try cls.add(sub.ranges[k][0], sub.ranges[k][1]);
                        },
                        't' => try cls.add('\t', '\t'),
                        'n' => try cls.add('\n', '\n'),
                        'r' => try cls.add('\r', '\r'),
                        '\\', ']', '^', '-', '[' => try cls.add(e, e),
                        else => try cls.add(e, e),
                    }
                    continue;
                }
                // a literal codepoint, maybe a range a-z
                const lo = try self.readCodepoint();
                if (self.peek() == '-' and self.pos + 1 < self.src.len and self.src[self.pos + 1] != ']') {
                    self.pos += 1; // consume '-'
                    const hi = try self.readCodepoint();
                    if (hi < lo) return error.InvalidPattern;
                    try cls.add(lo, hi);
                } else {
                    try cls.add(lo, lo);
                }
            }
            const idx = try self.e.addClass(cls);
            _ = try self.e.add(.{ .class = idx });
        }
    };
}

fn fillPredef(cls: *Class, c: u8) CompileError!void {
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
        's' => {
            try cls.add(' ', ' ');
            try cls.add('\t', '\t');
            try cls.add('\n', '\n');
            try cls.add('\r', '\r');
            try cls.add(0x0C, 0x0C);
            try cls.add(0x0B, 0x0B);
        },
        'S' => {
            cls.negated = true;
            try cls.add(' ', ' ');
            try cls.add('\t', '\t');
            try cls.add('\n', '\n');
            try cls.add('\r', '\r');
            try cls.add(0x0C, 0x0C);
            try cls.add(0x0B, 0x0B);
        },
        else => unreachable,
    }
}

// ---- emitter: a fixed-capacity buffer that works at comptime AND runtime ----
// We always build into fixed buffers (cap MAX_INSTS). compile() then copies the
// used prefix into an exact heap allocation; compileComptime() returns const
// slices of comptime arrays. wrap*/weaveAlternation perform in-place splicing
// using a scratch copy, which is simplest to keep correct.

const Builder = struct {
    insts: [MAX_INSTS]Inst = undefined,
    n: usize = 0,
    classes: [MAX_CLASSES]Class = undefined,
    nc: usize = 0,

    fn count(self: *Builder) usize {
        return self.n;
    }
    fn add(self: *Builder, inst: Inst) CompileError!usize {
        if (self.n >= MAX_INSTS) return error.PatternTooComplex;
        self.insts[self.n] = inst;
        self.n += 1;
        return self.n - 1;
    }
    fn addClass(self: *Builder, cls: Class) CompileError!usize {
        if (self.nc >= MAX_CLASSES) return error.PatternTooComplex;
        self.classes[self.nc] = cls;
        self.nc += 1;
        return self.nc - 1;
    }

    // Insert `slice` of instructions at index `at`, shifting the tail right and
    // fixing up every jmp/split target that pointed at >= at. Targets inside the
    // inserted slice must already be absolute (callers pass +at-adjusted values).
    fn spliceIn(self: *Builder, at: usize, slice: []const Inst) CompileError!void {
        const k = slice.len;
        if (self.n + k > MAX_INSTS) return error.PatternTooComplex;
        var i: usize = self.n;
        while (i > at) : (i -= 1) self.insts[i + k - 1] = self.insts[i - 1];
        for (slice, 0..) |s, j| self.insts[at + j] = s;
        self.n += k;
        // fix existing targets (those outside the inserted region)
        var idx: usize = 0;
        while (idx < self.n) : (idx += 1) {
            if (idx >= at and idx < at + k) continue; // inserted insts already absolute
            self.insts[idx] = shiftTargets(self.insts[idx], at, k);
        }
    }

    fn appendRaw(self: *Builder, slice: []const Inst) CompileError!void {
        for (slice) |s| _ = try self.add(s);
    }

    // X* :  L: split L+1, END ; <atom@atom_start..now> ; jmp L ; END:
    fn wrapStar(self: *Builder, atom_start: usize) CompileError!void {
        // prepend split, append jmp back
        try self.spliceIn(atom_start, &[_]Inst{.{ .split = .{ atom_start + 1, 0 } }});
        const back = try self.add(.{ .jmp = atom_start });
        const end = back + 1;
        self.insts[atom_start] = .{ .split = .{ atom_start + 1, end } };
    }

    // X+ :  <atom> ; split atom_start, END:
    fn wrapPlus(self: *Builder, atom_start: usize) CompileError!void {
        const sp = try self.add(.{ .split = .{ atom_start, 0 } });
        const end = sp + 1;
        self.insts[sp] = .{ .split = .{ atom_start, end } };
    }

    // X? :  split atom_start+1, END ; <atom> ; END:
    fn wrapQuest(self: *Builder, atom_start: usize) CompileError!void {
        try self.spliceIn(atom_start, &[_]Inst{.{ .split = .{ atom_start + 1, 0 } }});
        const end = self.n;
        self.insts[atom_start] = .{ .split = .{ atom_start + 1, end } };
    }

    // X{m,n}: copy the atom's instruction block m..n times. Implemented by
    // capturing the atom block, truncating back to atom_start, then re-emitting.
    fn wrapBounded(self: *Builder, atom_start: usize, m: usize, n: ?usize) CompileError!void {
        var block: [MAX_INSTS]Inst = undefined;
        const blen = self.n - atom_start;
        for (self.insts[atom_start..self.n], 0..) |inst, j| block[j] = inst;
        self.n = atom_start; // remove the original atom

        if (m == 0 and n != null and n.? == 0) return; // {0,0} == empty
        // m mandatory copies
        var c: usize = 0;
        while (c < m) : (c += 1) try self.emitBlock(block[0..blen]);
        if (n) |nn| {
            // (nn - m) optional copies, each wrapped in '?'
            var k: usize = 0;
            while (k < nn - m) : (k += 1) {
                const s = self.n;
                try self.emitBlock(block[0..blen]);
                try self.wrapQuest(s);
            }
        } else {
            // {m,} : if m==0, a star; else a trailing star on one more copy
            if (m == 0) {
                const s = self.n;
                try self.emitBlock(block[0..blen]);
                try self.wrapStar(s);
            } else {
                const s = self.n;
                try self.emitBlock(block[0..blen]);
                try self.wrapStar(s);
            }
        }
    }

    // Re-emit a captured block at the current end, rebasing internal targets.
    fn emitBlock(self: *Builder, block: []const Inst) CompileError!void {
        const base = self.n;
        // The block was captured starting at some old base; its internal targets
        // are absolute to that old base. Rebase by (new_base - old_base). We do
        // not know old_base here, so callers must have captured a block whose
        // internal targets are relative. To keep this correct, we recompute: the
        // block's instructions reference absolute indices from when atom_start was
        // its base; emitBlock is only used right after truncating to atom_start, so
        // old_base == atom_start. We pass delta via a wrapper.
        _ = base;
        @compileError("emitBlock requires rebasing; replaced by emitBlockRebased");
    }
};
```

> **Implementation note (read before coding):** The instruction-splicing / block-copy
> approach above is fiddly to keep correct (target rebasing on `{m,n}` and `*`/`?`
> splices). The executing agent should implement the emitter so that **every test in
> Step 1b passes**, using whichever concrete representation is cleanest in Zig 0.16.
> A proven simpler route is to **parse to an AST first, then emit** — emission of a
> fresh subtree for each `{m,n}` copy needs no rebasing because targets are produced
> fresh. If you take the AST route, keep the public API (`compile`, `compileComptime`,
> `matches`, `Program`, `CompileError`) and the semantics identical. Do not ship the
> `@compileError` stub above; it marks where the naive block-copy breaks.

- [ ] **Step 1b: Append the matcher, public API, and full test suite**

Add to `src/regex.zig`:

```zig
// ---- public API -----------------------------------------------------------

/// Compile a runtime pattern. Caller owns the returned Program (`deinit`).
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8) CompileError!Program {
    var b = try alloc.create(Builder);
    defer alloc.destroy(b);
    b.* = .{};
    var p = Parser(Builder){ .src = pattern, .e = b };
    try p.parseAltTop();
    if (p.pos != pattern.len) return error.InvalidPattern;
    _ = try b.add(.match);

    const insts = try alloc.dupe(Inst, b.insts[0..b.n]);
    errdefer alloc.free(insts);
    const classes = try alloc.dupe(Class, b.classes[0..b.nc]);
    return .{ .insts = insts, .classes = classes };
}

/// Compile a comptime pattern. @compileError on a malformed pattern.
pub fn compileComptime(comptime pattern: []const u8) Program {
    comptime {
        var b: Builder = .{};
        var p = Parser(Builder){ .src = pattern, .e = &b };
        p.parseAltTop() catch |e| @compileError("invalid regex pattern \"" ++ pattern ++ "\": " ++ @errorName(e));
        if (p.pos != pattern.len) @compileError("invalid regex pattern \"" ++ pattern ++ "\": trailing characters");
        _ = b.add(.match) catch |e| @compileError("regex pattern too complex \"" ++ pattern ++ "\": " ++ @errorName(e));
        const insts = b.insts[0..b.n].*;
        const classes = b.classes[0..b.nc].*;
        const final_insts = insts;
        const final_classes = classes;
        return .{ .insts = &final_insts, .classes = &final_classes };
    }
}

/// Boolean, unanchored match. Allocation-free; linear in haystack length.
pub fn matches(prog: Program, haystack: []const u8) bool {
    const nins = prog.insts.len;
    // two visited-bitsets reused per step (bounded by program size)
    var clist_buf: [MAX_INSTS]usize = undefined;
    var nlist_buf: [MAX_INSTS]usize = undefined;
    var seen_c: [MAX_INSTS]bool = undefined;
    var seen_n: [MAX_INSTS]bool = undefined;
    @memset(seen_c[0..nins], false);

    var clist: []usize = clist_buf[0..0];
    var nlist: []usize = nlist_buf[0..0];

    var pos: usize = 0;
    var view = haystack;
    // iterate over codepoints; sp tracks byte position for ^/$ checks
    var matched = false;

    // helper as a closure-free inline function via local struct
    const Add = struct {
        fn go(prog2: Program, list: *[]usize, buf: []usize, seen: []bool, pc: usize, at: usize, len: usize) bool {
            if (seen[pc]) return false;
            seen[pc] = true;
            switch (prog2.insts[pc]) {
                .jmp => |t| return go(prog2, list, buf, seen, t, at, len),
                .split => |t| {
                    if (go(prog2, list, buf, seen, t[0], at, len)) return true;
                    return go(prog2, list, buf, seen, t[1], at, len);
                },
                .bol => {
                    if (at == 0) return go(prog2, list, buf, seen, pc + 1, at, len);
                    return false;
                },
                .eol => {
                    if (at == len) return go(prog2, list, buf, seen, pc + 1, at, len);
                    return false;
                },
                .match => return true, // accept (unanchored)
                else => {
                    const k = list.len;
                    buf[k] = pc;
                    list.* = buf[0 .. k + 1];
                    return false;
                },
            }
        }
    };

    while (true) {
        // seed a fresh start thread at every position (unanchored search)
        if (!matched) {
            if (Add.go(prog, &clist, &clist_buf, &seen_c, 0, pos, haystack.len)) matched = true;
        }
        if (matched) return true;
        if (pos >= haystack.len) break;

        // decode current codepoint
        const blen = std.unicode.utf8ByteSequenceLength(view[0]) catch return false;
        if (blen > view.len) return false;
        const cp = std.unicode.utf8Decode(view[0..blen]) catch return false;

        @memset(seen_n[0..nins], false);
        nlist = nlist_buf[0..0];
        for (clist) |pc| {
            const consume = switch (prog.insts[pc]) {
                .char => |ch| ch == cp,
                .any => cp != '\n',
                .class => |ci| prog.classes[ci].matches(cp),
                else => false,
            };
            if (consume) {
                if (Add.go(prog, &nlist, &nlist_buf, &seen_n, pc + 1, pos + blen, haystack.len)) {
                    return true;
                }
            }
        }
        // swap lists
        @memcpy(clist_buf[0..nlist.len], nlist[0..nlist.len]);
        clist = clist_buf[0..nlist.len];
        @memcpy(seen_c[0..nins], seen_n[0..nins]);
        pos += blen;
        view = view[blen..];
    }
    return matched;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

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
    // A backtracking engine hangs on this; a Thompson NFA returns promptly.
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
```

- [ ] **Step 2: Run the regex tests directly until green**

Run: `mise exec zig@0.16.0 -- zig test src/regex.zig`
Expected: `All N tests passed.`
If the emitter splicing is hard to get correct, switch to the AST-then-emit route described in the implementation note (same API, same tests). The `no catastrophic backtracking` test must complete in well under a second.

- [ ] **Step 3: Commit**

```bash
git add src/regex.zig
git commit -m "feat(regex): pure-Zig Thompson-NFA matcher (comptime + runtime, DoS-safe)"
```

---

## Task 3: Wire both modules into the unit-test root

**Files:**
- Modify: `src/root.zig`

- [ ] **Step 1: Add imports to the test block**

Find the `test { _ = @import(...); ... }` block in `src/root.zig` and add:

```zig
    _ = @import("datetime.zig");
    _ = @import("regex.zig");
```

(Place them alphabetically among the existing entries. Do NOT add public re-exports — these modules stay internal.)

- [ ] **Step 2: Run the full unit suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: the `Build Summary: N/N tests passed` line, with the new datetime/regex tests included in the count.

- [ ] **Step 3: Commit**

```bash
git add src/root.zig
git commit -m "test: discover datetime and regex unit tests from the test root"
```

---

## Task 4: Enforce in record validation (`src/records.zig`)

**Files:**
- Modify: `src/records.zig` (imports near top; `.text` and `.date` arms of `validateFieldValue`, lines ~134 and ~161; rewrite the test at ~805)

- [ ] **Step 1: Rewrite the two "NOT enforced" tests to assert enforcement**

Replace the test at `src/records.zig:805` (`"date min/max are accepted but NOT enforced ..."`) with:

```zig
test "date values are validated and min/max enforced" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a); // "when": min 2026-01-01, max 2026-12-31
    // garbage is rejected
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "when", .{ .string = "2026-06-10 25:99:99" }));
    try expectFieldCode("when", "validation_date");
    // below min / above max rejected, across mixed formats
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "when", .{ .string = "2025-12-31 23:59:59" }));
    try expectFieldCode("when", "validation_min");
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "when", .{ .string = "2027-01-01T00:00:00Z" }));
    try expectFieldCode("when", "validation_max");
    // an in-range value in the canonical stored form is accepted
    _ = try createOne(a, &d, col, "when", .{ .string = "2026-06-10T08:00:00Z" });
}
```

Add a new test for pattern enforcement (place it right after the date test). First extend `seedConstrained` (`src/records.zig:635`) to include a patterned field — add this line to its `fields` array:

```zig
        .{ .id = "f6", .name = "slug", .options = .{ .text = .{ .pattern = "^[a-z0-9-]+$" } } },
```

Then the test:

```zig
test "text pattern is enforced" {
    var d = try db.Db.openMemory();
    defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const col = try seedConstrained(&d, a);
    try std.testing.expectError(error.Validation, createOne(a, &d, col, "slug", .{ .string = "Has Spaces" }));
    try expectFieldCode("slug", "validation_pattern");
    _ = try createOne(a, &d, col, "slug", .{ .string = "ok-slug-1" });
}
```

- [ ] **Step 2: Run the tests to verify they FAIL (enforcement not implemented yet)**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: the two new tests fail (values that should be rejected are accepted; no `validation_pattern`/`validation_date` codes).

- [ ] **Step 3: Add module imports**

Near the other `const ... = @import(...)` lines at the top of `src/records.zig`, add:

```zig
const regex = @import("regex.zig");
const datetime = @import("datetime.zig");
```

- [ ] **Step 4: Enforce the text pattern**

In `validateFieldValue`, extend the `.text` arm (currently `src/records.zig:134-141`) to check the pattern after the min/max checks. Replace the `.text` arm body with:

```zig
        .text => |o| if (v == .string and v.string.len > 0) {
            // min/max are documented as length in unicode codepoints (docs/fields.md).
            const n = std.unicode.utf8CountCodepoints(v.string) catch v.string.len;
            if (o.min) |mn| if (n < mn)
                try errs.append(alloc, .{ .field = f.name, .code = "validation_min", .message = "Value is too short." });
            if (o.max) |mx| if (n > mx)
                try errs.append(alloc, .{ .field = f.name, .code = "validation_max", .message = "Value is too long." });
            if (o.pattern) |pat| {
                // Compile per-write (patterns are small). Fail closed: a stored
                // pattern that won't compile rejects the write rather than
                // silently passing. schema.validate rejects bad patterns at
                // definition time, so this is defense in depth.
                const prog = regex.compile(alloc, pat) catch {
                    try errs.append(alloc, .{ .field = f.name, .code = "validation_pattern", .message = "Field pattern is invalid." });
                    return;
                };
                if (!regex.matches(prog, v.string))
                    try errs.append(alloc, .{ .field = f.name, .code = "validation_pattern", .message = "Value does not match the required pattern." });
            }
        },
```

(`alloc` here is the request arena; the compiled program is freed with it. No explicit `deinit` needed.)

- [ ] **Step 5: Enforce the date format + min/max**

Replace the no-op `.date` comment block (`src/records.zig:161-163`) with an actual `.date` arm. Place it as a real switch case (not the `else`):

```zig
        // Date values are normalized to UTC seconds for a sound comparison across
        // mixed formats (e.g. "2026-06-10 08:00:00" vs "2026-06-10T08:00:00Z").
        // A non-empty value must parse (rejects garbage like "25:99:99").
        .date => |o| if (v == .string and v.string.len > 0) {
            const secs = datetime.parse(v.string) catch {
                try errs.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Invalid date." });
                return;
            };
            if (o.min) |mn| {
                const b = datetime.parse(mn) catch {
                    try errs.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Invalid date bound." });
                    return;
                };
                if (secs < b) try errs.append(alloc, .{ .field = f.name, .code = "validation_min", .message = "Date is before the minimum." });
            }
            if (o.max) |mx| {
                const b = datetime.parse(mx) catch {
                    try errs.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Invalid date bound." });
                    return;
                };
                if (secs > b) try errs.append(alloc, .{ .field = f.name, .code = "validation_max", .message = "Date is after the maximum." });
            }
        },
```

- [ ] **Step 6: Run the tests to verify they PASS**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed`, including the rewritten date test and the new pattern test, and the pre-existing `text min/max` and `update enforces the same constraints` tests still green.

- [ ] **Step 7: Commit**

```bash
git add src/records.zig
git commit -m "feat(records): enforce text.pattern and date min/max on writes"
```

---

## Task 5: Reject bad patterns/bounds at schema-definition time (`src/schema.zig`)

**Files:**
- Modify: `src/schema.zig` (`validate`, lines ~280-288; imports near top)

- [ ] **Step 1: Write the failing test**

Add to `src/schema.zig` (near the existing `validate` tests; if none, add a new test):

```zig
test "validate rejects an uncompilable pattern and an unparseable date bound" {
    var errs: std.ArrayList(ValidationError) = .empty;
    defer errs.deinit(std.testing.allocator);
    const fields = [_]Field{
        .{ .id = "f1", .name = "slug", .options = .{ .text = .{ .pattern = "(" } } },
        .{ .id = "f2", .name = "when", .options = .{ .date = .{ .min = "nope" } } },
    };
    const c = Collection{ .id = "c", .name = "things", .fields = &fields };
    try validate(std.testing.allocator, c, &errs);
    var saw_pattern = false;
    var saw_date = false;
    for (errs.items) |e| {
        if (std.mem.eql(u8, e.code, "validation_pattern")) saw_pattern = true;
        if (std.mem.eql(u8, e.code, "validation_date")) saw_date = true;
    }
    try std.testing.expect(saw_pattern);
    try std.testing.expect(saw_date);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: the new test fails (no such error codes produced).

- [ ] **Step 3: Add imports and the checks**

Add near the top imports of `src/schema.zig`:

```zig
const regex = @import("regex.zig");
const datetime = @import("datetime.zig");
```

In `validate`, extend the per-field `switch (f.options)` (currently `src/schema.zig:280-288`) by adding two arms (replace the existing `.relation` arm grouping by inserting these cases alongside it):

```zig
            .text => |o| if (o.pattern) |pat| {
                if (regex.compile(alloc, pat)) |prog| {
                    prog.deinit(alloc);
                } else |_| {
                    try errors.append(alloc, .{ .field = f.name, .code = "validation_pattern", .message = "Field pattern is not a valid regular expression." });
                }
            },
            .date => |o| {
                if (o.min) |mn| if (datetime.parse(mn) == error.InvalidFormat or datetime.parse(mn) == error.OutOfRange)
                    try errors.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Date min is not a valid date." });
                if (o.max) |mx| if (datetime.parse(mx) == error.InvalidFormat or datetime.parse(mx) == error.OutOfRange)
                    try errors.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Date max is not a valid date." });
            },
```

> Note: `datetime.parse(mn) == error.InvalidFormat or ...` calls parse twice; prefer a clean form:
> ```zig
>             .date => |o| {
>                 if (o.min) |mn| { _ = datetime.parse(mn) catch try errors.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Date min is not a valid date." }); }
>                 if (o.max) |mx| { _ = datetime.parse(mx) catch try errors.append(alloc, .{ .field = f.name, .code = "validation_date", .message = "Date max is not a valid date." }); }
>             },
> ```
> Use the `catch` form.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed`.

- [ ] **Step 5: Commit**

```bash
git add src/schema.zig
git commit -m "feat(schema): reject bad text.pattern and date bounds at definition time"
```

---

## Task 6: Build-time validation of comptime schema literals (`src/provision.zig`)

**Files:**
- Modify: `src/provision.zig` (`buildOptions` `.text`/`.date` arms, lines ~163-174; imports near top)

- [ ] **Step 1: Add imports**

Near the top imports of `src/provision.zig`, add:

```zig
const regex = @import("regex.zig");
const datetime = @import("datetime.zig");
```

- [ ] **Step 2: Validate the comptime pattern in the `.text` arm**

Replace the `.text` arm of `buildOptions` (`src/provision.zig:163-167`) with:

```zig
            .text => blk: {
                const pat = optStr(f, "pattern");
                if (pat) |p| _ = regex.compileComptime(p); // @compileError on a bad pattern
                break :blk .{ .text = .{
                    .min = optU32(f, "min"),
                    .max = optU32(f, "max"),
                    .pattern = pat,
                } };
            },
```

- [ ] **Step 3: Validate comptime date bounds in the `.date` arm**

Replace the `.date` arm (`src/provision.zig:171-174`) with:

```zig
            .date => blk: {
                const dmin = optStr(f, "min");
                const dmax = optStr(f, "max");
                if (dmin) |b| _ = datetime.parse(b) catch @compileError(where ++ ": date .min is not a valid date \"" ++ b ++ "\"");
                if (dmax) |b| _ = datetime.parse(b) catch @compileError(where ++ ": date .max is not a valid date \"" ++ b ++ "\"");
                break :blk .{ .date = .{ .min = dmin, .max = dmax } };
            },
```

- [ ] **Step 4: Add a comptime smoke test**

Add to `src/provision.zig` (near the other tests):

```zig
test "buildOptions accepts a valid comptime pattern and date bounds" {
    const cols = buildCollections(.{
        .events = .{
            .fields = .{
                .{ .name = "slug", .type = .text, .pattern = "^[a-z-]+$" },
                .{ .name = "happens", .type = .date, .min = "2026-01-01", .max = "2026-12-31 23:59:59" },
            },
        },
    });
    try std.testing.expectEqual(@as(usize, 1), cols.len);
}
```

(We cannot unit-test the `@compileError` path — that is intentional; a bad literal would fail the build. Verify it manually once in Step 5.)

- [ ] **Step 5: Run unit tests, then manually confirm the @compileError fires**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed`.

Manual check (do once, then revert): temporarily change the smoke test's pattern to `"("` and run the test build; expect a compile error mentioning `invalid regex pattern "("`. Revert the change with Edit (do NOT `git checkout`).

- [ ] **Step 6: Commit**

```bash
git add src/provision.zig
git commit -m "feat(provision): @compileError on bad comptime text.pattern / date bounds"
```

---

## Task 7: Browser-suite coverage (`tests/admin/`)

**Files:**
- Modify: the schema-validation Playwright test file (identify with the search below)

- [ ] **Step 1: Find the right test file and a record-create helper**

Run: `ls tests/admin/ && grep -rln "validation\|create.*record\|data-test" tests/admin/*.py | head`
Pick the file that already exercises field validation on record create (e.g. `test_records.py` or `test_schema.py`). Read it to learn the existing fixtures/selectors (`data-test=` hooks in `src/admin/app.js`).

- [ ] **Step 2: Add a test that a pattern-violating create is rejected**

Following the existing file's patterns (collection setup → open record editor → fill field → submit → assert error), add a test that:
1. Creates a collection with a text field whose `pattern` is `^[a-z0-9-]+$`.
2. Attempts to create a record with that field set to `"Bad Value"`.
3. Asserts the create is rejected and a field error is shown (match the existing assertion style for validation errors).

Add a sibling test for a date field with `min`/`max` where an out-of-range value is rejected. (Write the actual test code mirroring the chosen file's helpers — do not leave it as prose.)

- [ ] **Step 3: Run the new browser tests**

Run: `mise exec python@3.13 -- python -m pytest tests/admin/<file>::<new_test> -q`
Expected: PASS (the harness builds the binary and drives headless Chromium).

- [ ] **Step 4: Commit**

```bash
git add tests/admin/<file>
git commit -m "test(admin): cover text.pattern and date min/max enforcement end-to-end"
```

---

## Task 8: Documentation sync

**Files:**
- Modify: `KNOWN_LIMITATIONS.md`, `site/src/content/docs/known-limitations.md`, `docs/fields.md`, `site/src/content/docs/fields.md`, `docs/framework.md`, `docs/security-audit.md`, `CHANGELOG.md`, `site/src/content/docs/changelog.md`

- [ ] **Step 1: Remove the two "not enforced" limitations**

In `KNOWN_LIMITATIONS.md`, delete the two bullets at lines 13-14 (the `text.pattern` bullet and the date `min`/`max` bullet). Make the same deletion in `site/src/content/docs/known-limitations.md` (the matching bullets there).

- [ ] **Step 2: Document the now-enforced behavior in `docs/fields.md` (+ site mirror)**

In `docs/fields.md`, update the `text` field section to state that `pattern` is enforced, documenting:
- It is a regular expression matched with **unanchored (substring)** semantics — anchor with `^…$` for a full-string match.
- Supported syntax: literals, `.` (excludes `\n`), `^` `$`, classes `[...]`/`[^...]`/ranges, `\d \D \w \W \s \S` (**ASCII**), escapes, alternation `|`, non-capturing groups, quantifiers `* + ? {m} {m,} {m,n}`.
- Linear-time matching (no catastrophic backtracking); patterns are validated when the collection is saved and at build time for comptime schemas.
Update the `date` field section to state `min`/`max` are enforced, and document the accepted input formats (`YYYY-MM-DD`, optional `T`/space + `HH:MM[:SS][.fff]`, optional `Z`/`±HH:MM`; missing zone = UTC) and that malformed dates are rejected.
Make the equivalent edits in `site/src/content/docs/fields.md`.

- [ ] **Step 3: Note the comptime validation in `docs/framework.md`**

Add a sentence to the comptime-schema/validation discussion in `docs/framework.md` that a malformed `text.pattern` or `date` `min`/`max` in a comptime `.collections` literal is now a `@compileError` (consistent with the rest of the comptime-validated surface).

- [ ] **Step 4: Update `docs/security-audit.md`**

At the two references (lines ~106 and ~424) noting `text.pattern` non-enforcement, update them: `pattern` is now enforced via an in-repo Thompson-NFA matcher (`src/regex.zig`) that is **linear-time / DoS-safe** (no catastrophic backtracking), and date bounds are enforced with normalization (`src/datetime.zig`).

- [ ] **Step 5: Changelog entries**

Add under the `[Unreleased]` heading in both `CHANGELOG.md` and `site/src/content/docs/changelog.md` (match the existing entry style):

```markdown
### Added
- `text.pattern` is now enforced on record writes via a pure-Zig, linear-time
  (DoS-safe) Thompson-NFA matcher. Patterns are validated when a collection is
  saved, and at build time (`@compileError`) for comptime schema literals.
- `date` field `min`/`max` are now enforced, with date normalization so mixed
  formats compare correctly; malformed date values are rejected.
```

- [ ] **Step 6: Build the site to confirm docs compile**

Run: `cd site && mise exec node@24 -- npm run build`
Expected: a successful Astro build (no broken content errors). Return to the repo root afterward.

- [ ] **Step 7: Commit**

```bash
git add KNOWN_LIMITATIONS.md site/src/content/docs/known-limitations.md docs/fields.md site/src/content/docs/fields.md docs/framework.md docs/security-audit.md CHANGELOG.md site/src/content/docs/changelog.md
git commit -m "docs: text.pattern and date min/max are now enforced"
```

---

## Task 9: Audit the examples

**Files:**
- Inspect/Modify: `examples/golfsim/src/main.zig` (and any other example using `date`/`pattern`)

- [ ] **Step 1: Find date/pattern field usage in examples**

Run: `grep -rn "\.date\|pattern" examples/*/src/*.zig`

- [ ] **Step 2: Confirm conformance**

For each `date` field found, confirm any literal `min`/`max` bounds and any seeded/sample date values conform to the accepted format (otherwise the build/seed now fails). For any `text.pattern`, confirm it compiles under the supported subset. Fix any non-conforming literal in the example (keep the complexity ladder intact: `blog` simplest, `plugins` most advanced).

- [ ] **Step 3: Build the affected example(s)**

Run: `cd examples/golfsim && mise exec zig@0.16.0 -- zig build` (and any other touched example)
Expected: a clean build. Return to the repo root afterward.

- [ ] **Step 4: Commit (only if a change was needed)**

```bash
git add examples/
git commit -m "examples: conform date/pattern field literals to enforced validation"
```

---

## Task 10: Full verification

- [ ] **Step 1: Full unit suite**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: `Build Summary: N/N tests passed` (note the `failed command:` line is spurious — trust the summary).

- [ ] **Step 2: Full binary build**

Run: `mise exec zig@0.16.0 -- zig build`
Expected: builds `zig-out/bin/zigbase` with no errors.

- [ ] **Step 3: Relevant browser tests**

Run: `mise exec python@3.13 -- python -m pytest tests/admin/ -q`
Expected: green (or at minimum the schema/records files plus the new tests). Investigate any failure — unit-green has historically hidden end-to-end regressions.

- [ ] **Step 4: Confirm the main checkout is clean (worktree hygiene)**

Run: `git -C /home/valthon/nothlav/zigbase status --short`
Expected: empty (no drift leaked into the main checkout).

- [ ] **Step 5: Final summary commit / branch ready**

Ensure all work is committed on the worktree branch. The branch is then ready for the finishing-a-development-branch step (PR).

---

## Self-Review (completed by plan author)

- **Spec coverage:** regex engine (Task 2), date normalizer (Task 1), records enforcement (Task 4), schema-time rejection (Task 5), comptime `@compileError` (Task 6), test-root wiring (Task 3), browser coverage (Task 7), full docs sync incl. site mirror + security-audit + changelog (Task 8), examples audit (Task 9), final verification incl. worktree hygiene (Task 10). All spec sections map to a task.
- **Placeholder scan:** No TBD/TODO. The one `@compileError("emitBlock requires rebasing ...")` in the Task 2 reference is deliberately flagged as the spot the naive approach breaks, with an explicit instruction to take the AST route; it must not ship.
- **Type consistency:** Public API names (`compile`, `compileComptime`, `matches`, `Program`, `Program.deinit`, `CompileError`, `Class`) and error codes (`validation_pattern`, `validation_date`, `validation_min`, `validation_max`) are used consistently across Tasks 2/4/5/6. `datetime.parse`/`ParseError` consistent across Tasks 1/4/5/6.
