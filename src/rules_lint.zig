//! `zigbase schema check-rules`: lint every collection's access rules through the REAL
//! rule pipeline, BEFORE a request has to.
//!
//! Access rules are never validated at write time. `schema.parseCollectionInput` decodes
//! the five rule fields as opaque strings and `collections.create`/`update` bind them
//! straight into `_collections`; nothing calls the lexer. The first thing that parses a
//! rule is the request that has to evaluate it — and a rule that fails to parse fails
//! CLOSED (500, the write never runs). So a typo ships silently and breaks production on
//! the first request that touches the collection. This module is the preflight that
//! closes that gap.
//!
//! **It does not fork the parser.** The full/live check calls `rules.compileGuard` — the
//! exact function the request path calls (lexer -> parser -> joiner -> compiler). The
//! document check calls `query/lexer.lex` + `query/parser.parse`, the same two modules,
//! just stopping before the stages that need a live schema and a connection. There is no
//! second grammar here to drift.
//!
//! **Two depths, honestly labeled.** Field and relation resolution happens in the joiner,
//! which needs a live DB (it looks the target collection up). Offline, against a document,
//! that is simply not knowable — so document mode reports `"depth":"syntax"` and live mode
//! reports `"depth":"full"`, and the summary carries the distinction on every run. Syntax
//! depth catches malformed expressions; only full depth catches `UnknownField`.
//!
//! Rule POLICY lives above the parser (`rules.decide`): `null` and `""` both mean Locked
//! (superusers only) — the safe default, never a finding — and the exact string `"@public"`
//! is the only allow-all. None of those three ever reach the parser.

const std = @import("std");
const schema = @import("schema.zig");
const db = @import("db.zig");
const request = @import("request.zig");
const rules = @import("rules.zig");
const lexer = @import("query/lexer.zig");
const parser = @import("query/parser.zig");

/// How deep the check could go. `full` = the whole pipeline against a live database;
/// `syntax` = lexer + parser only, because a document has no schema to resolve against.
pub const Depth = enum { full, syntax };

/// Wire spelling of a depth. Frozen: agents key on these two strings.
pub fn depthName(d: Depth) []const u8 {
    return switch (d) {
        .full => "full",
        .syntax => "syntax",
    };
}

/// One emitted finding. Field order = declaration order = the NDJSON wire order, which is
/// frozen and append-only. `code` is the machine field: `@errorName` of whatever the real
/// pipeline returned, or `"PublicRule"` for the `@public` warning. `message` is a human
/// gloss and is NOT a contract.
///
/// There is deliberately no position/offset: every stage of the pipeline returns a bare
/// error enum with no location and no text, and inventing a column number would be a lie.
pub const Finding = struct {
    collection: []const u8,
    /// `listRule` | `viewRule` | `createRule` | `updateRule` | `deleteRule`. camelCase on
    /// purpose — these mirror the schema document's own field names, so a finding names
    /// the key you edit.
    rule: []const u8,
    severity: []const u8, // "error" | "warn"
    code: []const u8,
    message: []const u8,
};

/// The terminating NDJSON object. `summary: bool = true` is first so a line-skipping
/// consumer identifies it by content rather than by stream position (same discriminator
/// trick as `doctor`).
pub const Summary = struct {
    summary: bool = true,
    depth: []const u8, // "full" | "syntax"
    collections: usize,
    rules_checked: usize,
    errors: usize,
    warnings: usize,
};

/// What a check run produced. `findings` holds ONLY errors and warnings — there are no
/// per-rule "ok" lines, so a clean run prints nothing but the summary. `rules_checked`
/// is the coverage number a reader needs to know the silence meant something.
pub const Report = struct {
    findings: []const Finding,
    /// Non-system collections examined.
    collections: usize,
    /// Non-blank rules examined, `@public` included. Blank rules (`null`/`""`) are Locked,
    /// not rules, and are not counted.
    rules_checked: usize,
};

/// The five rule slots, in check order. Index matches `ruleAt`.
pub const rule_names = [_][]const u8{ "listRule", "viewRule", "createRule", "updateRule", "deleteRule" };

fn ruleAt(c: schema.Collection, i: usize) ?[]const u8 {
    return switch (i) {
        0 => c.listRule,
        1 => c.viewRule,
        2 => c.createRule,
        3 => c.updateRule,
        4 => c.deleteRule,
        else => unreachable,
    };
}

/// Human gloss per pipeline error name. This table is also the ALLOWLIST that separates a
/// rule defect from an infrastructure failure: an error whose name is absent here (OOM, a
/// DB error, a relation pointing at a collection that no longer exists) is NOT a finding —
/// it aborts the run, because the lint could not be performed rather than having found
/// something. Keeping one table for both jobs means a newly-added pipeline error can never
/// be silently mis-filed as "clean".
const Explanation = struct { code: []const u8, message: []const u8 };

const explanations = [_]Explanation{
    // query/lexer.zig — LexError
    .{ .code = "UnexpectedChar", .message = "the rule contains a character the filter grammar does not accept" },
    .{ .code = "UnterminatedString", .message = "a quoted string in the rule is never closed" },
    .{ .code = "InvalidEscape", .message = "a string in the rule contains an invalid backslash escape" },
    // query/parser.zig — ParseError
    .{ .code = "UnexpectedToken", .message = "the rule is not a well-formed expression (unexpected token)" },
    .{ .code = "BadOperand", .message = "an operator in the rule is missing an operand" },
    .{ .code = "Empty", .message = "the rule has no expression in it (use null to mean Locked, or \"@public\" to mean public)" },
    .{ .code = "TooDeep", .message = "the rule nests more deeply than the parser allows" },
    // query/compiler.zig — CompileError
    .{ .code = "BadFilter", .message = "the expression is not usable as a filter" },
    .{ .code = "BadValue", .message = "a literal in the rule is not a valid value for what it is compared against" },
    // query/values.zig — ValueError, reachable through the compiler
    .{ .code = "TypeMismatch", .message = "a literal in the rule has the wrong type for the field it is compared against" },
    .{ .code = "TooPrecise", .message = "a numeric literal in the rule has more precision than the field stores" },
    .{ .code = "Overflow", .message = "a numeric literal in the rule is out of range for the field" },
    .{ .code = "BadNumber", .message = "a literal in the rule is compared against a number field but is not a number" },
    .{ .code = "BadSelect", .message = "a literal in the rule is not one of the select field's allowed values" },
    .{ .code = "NotObject", .message = "a value in the rule is not the object shape the field expects" },
    // query/joiner.zig — JoinError (FULL depth only; needs the live schema)
    .{ .code = "UnknownField", .message = "the rule references a field this collection does not have" },
    .{ .code = "NotARelation", .message = "the rule traverses through a field that is not a relation" },
    .{ .code = "MultiRelationTraversal", .message = "the rule traverses more than one multi-valued relation, which the engine cannot join" },
    .{ .code = "EncryptedField", .message = "the rule filters on an encrypted field, whose ciphertext cannot be compared in SQL" },
    .{ .code = "HiddenField", .message = "the rule filters on a hidden field in a context that forbids it" },
    // rules.zig — RuleError
    .{ .code = "BadRule", .message = "the rule could not be compiled" },
};

/// The gloss for `code`, or null when `code` is not a rule defect (see `explanations`).
fn explain(code: []const u8) ?[]const u8 {
    for (explanations) |e| {
        if (std.mem.eql(u8, e.code, code)) return e.message;
    }
    return null;
}

const public_message = "the rule is \"@public\": this collection is open to everyone, unauthenticated included";

/// Run one non-blank, non-`@public` rule through the pipeline. `conn != null` selects FULL
/// depth (`rules.compileGuard` — the request path's own entry point); `conn == null` stops
/// after the parser, which is all a document can support.
///
/// Everything allocated here is scratch on `sa` (a per-rule arena owned by the caller) and
/// is consumed by this call: the tokens, the AST, the joiner's scratch, and — at full depth
/// — the compiled Guard, which `compileGuard` deep-clones onto `sa` before returning. The
/// explicit `g.deinit(sa)` makes that ownership visible even though the arena would reclaim
/// it regardless; nothing escapes, so there is no error path that can leak an owner.
fn checkOne(sa: std.mem.Allocator, conn: ?*db.Db, col: schema.Collection, rule: []const u8, rctx: *const request.RequestContext) !void {
    if (conn) |c| {
        // The same call `rules.decide` -> `check` leads to on a real request. `compileGuard`
        // sets `allow_hidden = true` internally: an access rule is operator-authored and is
        // allowed to gate on a hidden field (it is evaluated, never serialized), so linting
        // must not be stricter than evaluation or it would report rules that actually work.
        const g = try rules.compileGuard(sa, c, col, rule, rctx);
        g.deinit(sa);
        return;
    }
    const toks = try lexer.lex(sa, rule);
    _ = try parser.parse(sa, toks);
}

/// The shared core of both modes: identical collection/rule selection and identical policy
/// handling, differing only in how deep `checkOne` goes. One code path so document mode can
/// never disagree with live mode about WHICH rules are rules.
///
/// Contract 4 (arena): `findings` and its backing are allocated on `arena` and freed with
/// it; the finding strings are all either static literals or borrowed from `cols`, so none
/// of them outlive their source. Per-rule pipeline scratch lives on a nested arena torn
/// down at the end of each iteration.
fn run(arena: std.mem.Allocator, cols: []const schema.Collection, conn: ?*db.Db) !Report {
    var out: std.ArrayList(Finding) = .empty;
    // The findings themselves borrow (static messages, names from `cols`), so only the
    // backing buffer is owned here. Released on every abort path — an OOM, or an
    // infrastructure error that ends the run mid-collection — so `run` is leak-correct
    // under a raw allocator too, not merely under the arena the CLI passes.
    errdefer out.deinit(arena);
    var ncols: usize = 0;
    var checked: usize = 0;

    // The most neutral context the type allows: anonymous, non-superuser, no request body.
    // A rule's `@request.*` macros compile to bound parameters whose VALUES come from this
    // context, so an empty one still compiles every macro the real request would — we are
    // checking that the rule compiles, not what it would decide for a particular caller.
    // (`rules.decide`'s superuser bypass is deliberately not consulted: a superuser skips
    // rule evaluation entirely, which would make the lint check nothing.)
    const rctx = request.RequestContext{};

    for (cols) |c| {
        if (c.system) continue;
        ncols += 1;
        for (rule_names, 0..) |slot, i| {
            const rule = ruleAt(c, i) orelse continue; // null == Locked
            if (rule.len == 0) continue; // "" == Locked too (NOT public)
            checked += 1;

            if (rules.isPublic(rule)) {
                // Deliberately overlaps `doctor`'s `public-rules-enumerated` check, at a
                // different lifecycle stage: doctor asks "what is this running server
                // exposing right now?", check-rules asks "is this document/schema about to
                // expose something?". Same judgment call, surfaced before and after the
                // change lands. doctor's frozen ledger is untouched by this.
                try out.append(arena, .{
                    .collection = c.name,
                    .rule = slot,
                    .severity = "warn",
                    .code = "PublicRule",
                    .message = public_message,
                });
                continue;
            }

            var scratch = std.heap.ArenaAllocator.init(arena);
            defer scratch.deinit();

            checkOne(scratch.allocator(), conn, c, rule, &rctx) catch |e| {
                const code = @errorName(e);
                // Not a rule defect (OOM, DB failure, a dangling relation target): the lint
                // could not run, so say so by failing rather than by reporting "clean".
                const message = explain(code) orelse return e;
                try out.append(arena, .{
                    .collection = c.name,
                    .rule = slot,
                    .severity = "error",
                    .code = code,
                    .message = message,
                });
            };
        }
    }

    return .{ .findings = try out.toOwnedSlice(arena), .collections = ncols, .rules_checked = checked };
}

/// FULL depth: every rule through `rules.compileGuard` against `conn`, so field and
/// relation resolution is checked too. `cols` is what `collections.list` returned.
pub fn checkLive(arena: std.mem.Allocator, conn: *db.Db, cols: []const schema.Collection) !Report {
    return run(arena, cols, conn);
}

/// SYNTAX depth: lexer + parser only. Field/relation names are NOT resolved — that needs a
/// live schema and a connection, which a document does not carry.
pub fn checkDocument(arena: std.mem.Allocator, cols: []const schema.Collection) !Report {
    return run(arena, cols, null);
}

pub fn summarize(r: Report, depth: Depth) Summary {
    var s: Summary = .{
        .depth = depthName(depth),
        .collections = r.collections,
        .rules_checked = r.rules_checked,
        .errors = 0,
        .warnings = 0,
    };
    for (r.findings) |f| {
        if (std.mem.eql(u8, f.severity, "error")) s.errors += 1;
        if (std.mem.eql(u8, f.severity, "warn")) s.warnings += 1;
    }
    return s;
}

/// The testable core: the exact bytes `render` writes. NDJSON only — one compact object
/// per finding in `Finding`'s declaration order, then exactly one summary object.
/// Stringifying the structs directly (rather than hand-building JSON) is what keeps the
/// wire order from drifting away from the declared field order.
///
/// Self-contained (contract 2): the caller owns only the returned slice. The growing buffer
/// is released on every error path (`errdefer`), so this is leak-correct under a raw
/// allocator, not merely under the arena the CLI happens to pass.
pub fn renderToSlice(alloc: std.mem.Allocator, findings: []const Finding, summary: Summary) error{OutOfMemory}![]u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    errdefer aw.deinit();
    const w = &aw.writer;
    for (findings) |f| {
        std.json.Stringify.value(f, .{}, w) catch return error.OutOfMemory;
        w.writeAll("\n") catch return error.OutOfMemory;
    }
    std.json.Stringify.value(summary, .{}, w) catch return error.OutOfMemory;
    w.writeAll("\n") catch return error.OutOfMemory;
    return aw.toOwnedSlice() catch error.OutOfMemory;
}

/// `renderToSlice` + a streaming write to stdout. Streaming (not positional) for the same
/// reason `doctor_run.render` is: under `cmd >f 2>&1` both fds share one open file
/// description, and a positional flush from offset zero would stomp what stderr committed.
pub fn render(io: std.Io, arena: std.mem.Allocator, findings: []const Finding, summary: Summary) void {
    const bytes = renderToSlice(arena, findings, summary) catch return;
    var buf: [4096]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(io, &buf);
    fw.interface.writeAll(bytes) catch return;
    fw.interface.flush() catch return;
}

/// Exactly `doctor`'s mapping: 1 on any error, 2 on warnings-only, 0 when clean. Errors
/// win over warnings, so a script can treat `>=1` as "stop" and `2` as "a human decides".
pub fn exitCode(summary: Summary) u8 {
    if (summary.errors > 0) return 1;
    if (summary.warnings > 0) return 2;
    return 0;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A borrowed (NOT owned) collection literal for the document-mode tests: every string is
/// a static literal, so nothing here may be passed to `Collection.deinit`.
fn testCollection(name: []const u8, rules_in: [5]?[]const u8) schema.Collection {
    return .{
        .id = "c1",
        .name = name,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = rules_in[0],
        .viewRule = rules_in[1],
        .createRule = rules_in[2],
        .updateRule = rules_in[3],
        .deleteRule = rules_in[4],
    };
}

const no_rules = [5]?[]const u8{ null, null, null, null, null };

test "checkDocument: a clean schema produces no findings, only coverage" {
    const cols = [_]schema.Collection{
        testCollection("posts", .{ "title != \"\"", null, null, null, null }),
        testCollection("notes", .{ null, "title = \"x\"", null, null, null }),
    };
    const r = try checkDocument(testing.allocator, &cols);
    defer testing.allocator.free(r.findings);

    try testing.expectEqual(@as(usize, 0), r.findings.len);
    try testing.expectEqual(@as(usize, 2), r.collections);
    try testing.expectEqual(@as(usize, 2), r.rules_checked);

    const s = summarize(r, .syntax);
    try testing.expectEqualStrings("syntax", s.depth);
    try testing.expectEqual(@as(u8, 0), exitCode(s));
}

test "checkDocument: a malformed rule is one error finding carrying the parser's own error name" {
    // `title = ` lexes fine and dies in the parser — a bare operator with no right operand.
    const cols = [_]schema.Collection{testCollection("posts", .{ "title = ", null, null, null, null })};
    const r = try checkDocument(testing.allocator, &cols);
    defer testing.allocator.free(r.findings);

    try testing.expectEqual(@as(usize, 1), r.findings.len);
    try testing.expectEqualStrings("posts", r.findings[0].collection);
    try testing.expectEqualStrings("listRule", r.findings[0].rule);
    try testing.expectEqualStrings("error", r.findings[0].severity);
    // The code is the REAL parser's error name, not a code this module invented.
    try testing.expectEqualStrings("BadOperand", r.findings[0].code);
    try testing.expect(r.findings[0].message.len > 0);

    const s = summarize(r, .syntax);
    try testing.expectEqual(@as(usize, 1), s.errors);
    try testing.expectEqual(@as(usize, 0), s.warnings);
    try testing.expectEqual(@as(u8, 1), exitCode(s));
}

test "checkDocument: an unterminated string is a LexError finding" {
    const cols = [_]schema.Collection{testCollection("posts", .{ null, "title = \"oops", null, null, null })};
    const r = try checkDocument(testing.allocator, &cols);
    defer testing.allocator.free(r.findings);

    try testing.expectEqual(@as(usize, 1), r.findings.len);
    try testing.expectEqualStrings("viewRule", r.findings[0].rule);
    try testing.expectEqualStrings("UnterminatedString", r.findings[0].code);
}

test "checkDocument: null and empty rules are Locked, not findings, and are not counted" {
    const cols = [_]schema.Collection{
        testCollection("locked_null", no_rules),
        testCollection("locked_blank", .{ "", "", "", "", "" }),
    };
    const r = try checkDocument(testing.allocator, &cols);
    defer testing.allocator.free(r.findings);

    try testing.expectEqual(@as(usize, 0), r.findings.len);
    try testing.expectEqual(@as(usize, 2), r.collections);
    // Neither `null` nor `""` is a rule to check — the blank collection contributes zero.
    try testing.expectEqual(@as(usize, 0), r.rules_checked);
    try testing.expectEqual(@as(u8, 0), exitCode(summarize(r, .syntax)));
}

test "checkDocument: @public is exactly one warn finding per rule, and exits 2" {
    const cols = [_]schema.Collection{testCollection("posts", .{ "@public", null, null, null, null })};
    const r = try checkDocument(testing.allocator, &cols);
    defer testing.allocator.free(r.findings);

    try testing.expectEqual(@as(usize, 1), r.findings.len);
    try testing.expectEqualStrings("listRule", r.findings[0].rule);
    try testing.expectEqualStrings("warn", r.findings[0].severity);
    try testing.expectEqualStrings("PublicRule", r.findings[0].code);
    // It IS a rule we examined, so it counts toward coverage.
    try testing.expectEqual(@as(usize, 1), r.rules_checked);

    const s = summarize(r, .syntax);
    try testing.expectEqual(@as(usize, 0), s.errors);
    try testing.expectEqual(@as(usize, 1), s.warnings);
    try testing.expectEqual(@as(u8, 2), exitCode(s));
}

test "checkDocument: @publicx is an expression, not the sentinel" {
    // Guards the exact-match policy: a near-miss must be compiled, not waved through.
    const cols = [_]schema.Collection{testCollection("posts", .{ "@publicx", null, null, null, null })};
    const r = try checkDocument(testing.allocator, &cols);
    defer testing.allocator.free(r.findings);
    try testing.expectEqual(@as(usize, 1), r.findings.len);
    try testing.expectEqualStrings("error", r.findings[0].severity);
}

test "checkDocument: system collections are skipped entirely" {
    var sys = testCollection("_superusers", .{ "title = ", null, null, null, null });
    sys.system = true;
    const cols = [_]schema.Collection{sys};
    const r = try checkDocument(testing.allocator, &cols);
    defer testing.allocator.free(r.findings);
    try testing.expectEqual(@as(usize, 0), r.findings.len);
    try testing.expectEqual(@as(usize, 0), r.collections);
    try testing.expectEqual(@as(usize, 0), r.rules_checked);
}

test "errors that are not rule defects abort the run instead of being reported as findings" {
    // `explain` doubles as the allowlist: only a name in the table becomes a finding.
    try testing.expect(explain("UnknownField") != null);
    try testing.expect(explain("BadOperand") != null);
    try testing.expect(explain("OutOfMemory") == null);
    try testing.expect(explain("NotFound") == null);
    try testing.expect(explain("SqlError") == null);
}

test "exitCode: errors beat warnings beat clean" {
    const clean = Summary{ .depth = "full", .collections = 1, .rules_checked = 1, .errors = 0, .warnings = 0 };
    const warned = Summary{ .depth = "full", .collections = 1, .rules_checked = 1, .errors = 0, .warnings = 3 };
    const broken = Summary{ .depth = "full", .collections = 1, .rules_checked = 1, .errors = 1, .warnings = 3 };
    try testing.expectEqual(@as(u8, 0), exitCode(clean));
    try testing.expectEqual(@as(u8, 2), exitCode(warned));
    try testing.expectEqual(@as(u8, 1), exitCode(broken));
}

test "render: one object per finding, then exactly one summary whose first key is summary" {
    const findings = [_]Finding{
        .{ .collection = "posts", .rule = "listRule", .severity = "error", .code = "BadOperand", .message = "nope" },
        .{ .collection = "posts", .rule = "viewRule", .severity = "warn", .code = "PublicRule", .message = "open" },
    };
    const s = Summary{ .depth = "syntax", .collections = 1, .rules_checked = 2, .errors = 1, .warnings = 1 };
    const out = try renderToSlice(testing.allocator, &findings, s);
    defer testing.allocator.free(out);

    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    const l1 = it.next().?;
    const l2 = it.next().?;
    const l3 = it.next().?;
    try testing.expect(it.next() == null);
    // Field order IS the contract.
    try testing.expectEqualStrings(
        "{\"collection\":\"posts\",\"rule\":\"listRule\",\"severity\":\"error\",\"code\":\"BadOperand\",\"message\":\"nope\"}",
        l1,
    );
    try testing.expect(std.mem.indexOf(u8, l2, "\"PublicRule\"") != null);
    try testing.expect(std.mem.startsWith(u8, l3, "{\"summary\":true,\"depth\":\"syntax\","));
    try testing.expect(std.mem.indexOf(u8, l3, "\"rules_checked\":2") != null);
}

test "checkLive resolves fields against the live schema — the check syntax depth cannot make" {
    // The honesty of the two-depth design, asserted directly: ONE rule, TWO depths, two
    // different verdicts. `nope = "x"` is perfectly well-formed syntax, so the parser is
    // happy; only the joiner — which needs the connection to know what columns exist —
    // can say the field is not there.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = testing.allocator;
    const migrations = @import("migrations.zig");
    const collections = @import("collections.zig");
    try migrations.run(&d);
    const col = try collections.create(a, testing.io, &d, .{
        .id = "",
        .name = "posts",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = "nope = \"x\"",
        .viewRule = "title != \"\"",
    });
    defer col.deinit(a);
    const cols = [_]schema.Collection{col};

    const full = try checkLive(a, &d, &cols);
    defer a.free(full.findings);
    try testing.expectEqual(@as(usize, 1), full.findings.len);
    try testing.expectEqualStrings("listRule", full.findings[0].rule);
    try testing.expectEqualStrings("UnknownField", full.findings[0].code);
    try testing.expectEqual(@as(usize, 2), full.rules_checked);
    const fs = summarize(full, .full);
    try testing.expectEqualStrings("full", fs.depth);
    try testing.expectEqual(@as(u8, 1), exitCode(fs));

    // Same collection, syntax depth: the broken reference is INVISIBLE. This is exactly
    // why document mode must label itself "syntax" instead of claiming a clean bill.
    const syn = try checkDocument(a, &cols);
    defer a.free(syn.findings);
    try testing.expectEqual(@as(usize, 0), syn.findings.len);
    try testing.expectEqual(@as(usize, 2), syn.rules_checked);
    try testing.expectEqual(@as(u8, 0), exitCode(summarize(syn, .syntax)));
}

test "checkLive: a rule the request path accepts is not reported" {
    // Negative control for the test above — proves `UnknownField` came from the bad field
    // reference and not from `checkLive` failing on every rule it is handed.
    var d = try db.Db.openMemory();
    defer d.close();
    const a = testing.allocator;
    const migrations = @import("migrations.zig");
    const collections = @import("collections.zig");
    try migrations.run(&d);
    const col = try collections.create(a, testing.io, &d, .{
        .id = "",
        .name = "posts",
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = "title != \"\" && @request.auth.id != \"\"",
        .viewRule = "@public",
    });
    defer col.deinit(a);
    const cols = [_]schema.Collection{col};

    const r = try checkLive(a, &d, &cols);
    defer a.free(r.findings);
    // Only the @public warning; the macro-bearing expression compiles under an anonymous
    // context, which is what makes an empty RequestContext a usable lint context.
    try testing.expectEqual(@as(usize, 1), r.findings.len);
    try testing.expectEqualStrings("PublicRule", r.findings[0].code);
    try testing.expectEqual(@as(u8, 2), exitCode(summarize(r, .full)));
}
