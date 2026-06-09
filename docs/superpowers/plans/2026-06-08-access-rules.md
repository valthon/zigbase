# ZigBase SP4: API Access Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Enforce per-collection list/view/create/update/delete rules on the record endpoints, reusing the SP3 filter compiler extended with `@request.*` macros, against a `RequestContext` auth seam (empty until SP5).

**Architecture:** A rule is a filter expression; every check reduces to a parameterized guarded `SELECT 1 … WHERE id=? AND (rule)` (or AND-ed into list). `request.zig` holds the auth-context seam + macro resolution; `query/compiler.zig` gains an optional context so `@request.*` operands become bound literals; `records.zig` gains an optional rule `Guard` (run atomically in create/update) and an optional list rule clause; `rules.zig` is the policy layer; `api/records.zig` enforces per handler with hide-style codes.

**Tech Stack:** Zig 0.16.0 (mise), the SP3 query pipeline (`query/lexer`,`parser`,`compiler`,`joiner`), `records`, `collections`, `std.json`.

---

## Toolchain (read once)
Run zig via the pinned toolchain from repo root: `mise exec zig@0.16.0 -- zig <args>`. Do NOT use `mise -C`. On `main`; 87 tests pass.

## Verified current signatures (grounding)
- `query/lexer.zig`: `fn isIdentStart(c) = a-z/A-Z/_`; `isIdentChar = isIdentStart or 0-9 or '.'`.
- `query/compiler.zig`: `pub fn compile(alloc, *joiner.Joiner, *parser.Node) CompileError!Compiled{where_sql,params}`; `Param = union(enum){text:[]const u8,int:i64,double:f64}`; `const Cmp = @TypeOf(@as(parser.Node,undefined).cmp)`; `fn emitCmp(alloc,*Joiner,Cmp,*ArrayList(Param)) ![]u8`; helpers `opSql`, `likeAllowed(?Field)`, `literalToText(Operand)`, `literalToParam(?Field,Operand)`. `parser.Operand = union(enum){path,str,num,boolean,nul}`.
- `records.zig`: `create(alloc,io,*db.Db,col,data) RecordError!Value`; `update(alloc,*db.Db,col,id,data) RecordError!?Value`; `delete(alloc,*db.Db,col,id) RecordError!bool`; `get(alloc,*db.Db,col,id) !?Value`; `list(alloc,*db.Db,col,ListQuery) !ListResult`; `ListQuery{filter,sort,page,perPage}`; `bindParams(*db.Stmt, []const compiler.Param, c_int) !c_int` (exists); `rowToObject`, `baseColumnList`, `RecordError`.
- `api/records.zig` handlers `view/create/update/delete/list`; imports include `records`, `collections`, `schema`, `ApiError`, `FieldError`, `params_mod`, `expand_mod`. Has a `TestEnv` seeding a `posts` collection (default null rules) + `ctxFor`.
- `collections.get(alloc,*db.Db,idOrName) !?schema.Collection`. `schema.Collection` has `listRule/viewRule/createRule/updateRule/deleteRule: ?[]const u8`.
- `std.ArrayList(T)` unmanaged; `std.fmt.allocPrintSentinel(alloc,fmt,args,0)`; `std.mem.startsWith(u8,s,prefix)`.

## File Structure
| File | Change |
|---|---|
| `src/request.zig` | NEW — `RequestContext` + `resolveMacro` |
| `src/query/lexer.zig` | allow `@` in identifiers |
| `src/query/compiler.zig` | optional `rctx`; `@request.*` operands → bound text params |
| `src/records.zig` | `error.Forbidden`; `Guard`; `createGuarded`/`updateGuarded` (txn); `ListQuery` gains `rule`/`rctx` |
| `src/rules.zig` | NEW — `Decision`/`decide`, `compileGuard`, `matches` |
| `src/api/records.zig` | enforce rules in all 5 handlers; fixtures→public; deny tests; smoke |
| `src/main.zig` | test aggregator |

---

## Task 1: `request.zig` (auth seam) + lexer `@`

**Files:** Create `src/request.zig`; Modify `src/query/lexer.zig`, `src/main.zig`.

- [ ] **Step 1: Create `src/request.zig`**

```zig
const std = @import("std");

/// The per-request context rules evaluate against. SP4 builds an empty one (no auth yet);
/// SP5's auth middleware fills `auth`/`is_superuser`.
pub const RequestContext = struct {
    auth: ?std.json.Value = null, // authenticated record object; null = unauthenticated
    is_superuser: bool = false,
    data: ?std.json.Value = null, // request body (create/update rules)
    method: []const u8 = "",

    /// Resolve a `@request.*` macro path to a text value. Returns null for an unknown macro.
    /// `@request.auth.<field>` and `@request.data.<field>` yield "" when absent/unauthenticated.
    pub fn resolveMacro(self: *const RequestContext, path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "@request.method")) return self.method;
        if (std.mem.startsWith(u8, path, "@request.auth.")) {
            const field = path["@request.auth.".len..];
            return objField(self.auth, field);
        }
        if (std.mem.startsWith(u8, path, "@request.data.")) {
            const field = path["@request.data.".len..];
            return objField(self.data, field);
        }
        return null;
    }
};

/// Read a string-ish field from an optional JSON object; "" when the object is null/absent or
/// the field is missing; non-string values render as "" (SP4 macros are text-only).
fn objField(obj: ?std.json.Value, field: []const u8) []const u8 {
    const o = obj orelse return "";
    if (o != .object) return "";
    const v = o.object.get(field) orelse return "";
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

test "resolveMacro: auth absent -> empty, present -> value; data; method" {
    var ctx = RequestContext{ .method = "GET" };
    try std.testing.expectEqualStrings("", ctx.resolveMacro("@request.auth.id").?);
    try std.testing.expectEqualStrings("GET", ctx.resolveMacro("@request.method").?);
    try std.testing.expect(ctx.resolveMacro("@request.bogus") == null);

    var auth_obj: std.json.ObjectMap = .empty;
    try auth_obj.put(std.testing.allocator, "id", .{ .string = "u1" });
    defer auth_obj.deinit(std.testing.allocator);
    ctx.auth = .{ .object = auth_obj };
    try std.testing.expectEqualStrings("u1", ctx.resolveMacro("@request.auth.id").?);
}
```

- [ ] **Step 2: Lexer `@`** — in `src/query/lexer.zig`, change `isIdentStart` to also accept `@`:

```zig
fn isIdentStart(c: u8) bool { return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '@'; }
```
Add a lexer test:
```zig
test "lex an @request macro path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const toks = try lex(arena.allocator(), "owner = @request.auth.id");
    try std.testing.expectEqual(TokKind.ident, toks[0].kind);
    try std.testing.expectEqual(TokKind.eq, toks[1].kind);
    try std.testing.expectEqual(TokKind.ident, toks[2].kind);
    try std.testing.expectEqualStrings("@request.auth.id", toks[2].text);
}
```

- [ ] **Step 3: Aggregate + run** — add `_ = @import("request.zig");` to `src/main.zig`'s `test {}`. Run `mise exec zig@0.16.0 -- zig build test` (expect 89). Commit:
```bash
git add src/request.zig src/query/lexer.zig src/main.zig
git commit -m "feat(rules): RequestContext + macro resolution; lexer @ support"
```

---

## Task 2: compiler `@request.*` macro resolution

**Files:** Modify `src/query/compiler.zig`; Modify any caller that breaks (records.list, compiler tests pass `null`).

The compile entry gains an optional `rctx`. A `.path` operand starting with `@` becomes a bound text param (resolved from `rctx`); a non-`@` path stays a column; literals unchanged. When `rctx == null` an `@`-path errors.

- [ ] **Step 1: Add the rctx parameter + macro-aware operand helpers.** Replace `compile`/`emit`/`emitCmp` and add helpers in `src/query/compiler.zig`:

```zig
const request = @import("../request.zig");

pub fn compile(alloc: std.mem.Allocator, j: *joiner.Joiner, node: *parser.Node, rctx: ?*const request.RequestContext) CompileError!Compiled {
    var params: std.ArrayList(Param) = .empty;
    const sql = try emit(alloc, j, node, &params, rctx);
    return .{ .where_sql = sql, .params = try params.toOwnedSlice(alloc) };
}

fn emit(alloc: std.mem.Allocator, j: *joiner.Joiner, node: *parser.Node, params: *std.ArrayList(Param), rctx: ?*const request.RequestContext) CompileError![]u8 {
    switch (node.*) {
        .logic => |lg| {
            const l = try emit(alloc, j, lg.l, params, rctx);
            const r = try emit(alloc, j, lg.r, params, rctx);
            const conj = if (lg.op == .l_and) "AND" else "OR";
            return std.fmt.allocPrint(alloc, "({s} {s} {s})", .{ l, conj, r });
        },
        .cmp => |c| return emitCmp(alloc, j, c, params, rctx),
    }
}

/// True for a column path: a `.path` operand NOT starting with '@'.
fn isColPath(op: parser.Operand) bool {
    return op == .path and (op.path.len == 0 or op.path[0] != '@');
}

/// Resolve a non-column operand (macro or literal) to its text form.
fn operandToText(op: parser.Operand, rctx: ?*const request.RequestContext) CompileError![]const u8 {
    switch (op) {
        .path => |p| {
            if (p.len > 0 and p[0] == '@') {
                const rc = rctx orelse return error.BadFilter;
                return rc.resolveMacro(p) orelse return error.BadFilter;
            }
            return error.BadFilter; // a column path where a value was expected
        },
        else => return literalToText(op),
    }
}

/// Resolve a non-column operand to a bound Param. Numeric literals convert per `field`;
/// macros and string/bool literals bind as text.
fn operandToParam(field: ?schema.Field, op: parser.Operand, rctx: ?*const request.RequestContext) CompileError!Param {
    switch (op) {
        .path => |p| {
            if (p.len > 0 and p[0] == '@') {
                const rc = rctx orelse return error.BadFilter;
                return .{ .text = rc.resolveMacro(p) orelse return error.BadFilter };
            }
            return error.BadFilter;
        },
        else => return literalToParam(field, op),
    }
}

fn emitCmp(alloc: std.mem.Allocator, j: *joiner.Joiner, c: Cmp, params: *std.ArrayList(Param), rctx: ?*const request.RequestContext) CompileError![]u8 {
    const l_col = isColPath(c.lhs);
    const r_col = isColPath(c.rhs);

    if (l_col and r_col) {
        const lc = try j.resolve(c.lhs.path);
        const rc = try j.resolve(c.rhs.path);
        return std.fmt.allocPrint(alloc, "{s} {s} {s}", .{ lc.sql, opSql(c.op), rc.sql });
    }

    if (l_col or r_col) {
        const col = if (l_col) try j.resolve(c.lhs.path) else try j.resolve(c.rhs.path);
        const val_op = if (l_col) c.rhs else c.lhs;
        if (c.op == .like or c.op == .nlike) {
            if (!likeAllowed(col.field)) return error.BadValue;
            const term = try operandToText(val_op, rctx);
            try params.append(alloc, .{ .text = try std.fmt.allocPrint(alloc, "%{s}%", .{term}) });
            return std.fmt.allocPrint(alloc, "{s} {s} ?", .{ col.sql, opSql(c.op) });
        }
        try params.append(alloc, try operandToParam(col.field, val_op, rctx));
        if (l_col) return std.fmt.allocPrint(alloc, "{s} {s} ?", .{ col.sql, opSql(c.op) });
        return std.fmt.allocPrint(alloc, "? {s} {s}", .{ opSql(c.op), col.sql });
    }

    // neither side is a column: both are macros/literals -> bind both as text
    if (c.op == .like or c.op == .nlike) {
        const lt = try operandToText(c.lhs, rctx);
        const rt = try operandToText(c.rhs, rctx);
        try params.append(alloc, .{ .text = lt });
        try params.append(alloc, .{ .text = try std.fmt.allocPrint(alloc, "%{s}%", .{rt}) });
        return std.fmt.allocPrint(alloc, "? {s} ?", .{opSql(c.op)});
    }
    try params.append(alloc, .{ .text = try operandToText(c.lhs, rctx) });
    try params.append(alloc, .{ .text = try operandToText(c.rhs, rctx) });
    return std.fmt.allocPrint(alloc, "? {s} ?", .{opSql(c.op)});
}
```
Keep the existing `opSql`, `likeAllowed`, `literalToText`, `literalToParam` unchanged.

- [ ] **Step 2: Fix the existing compiler tests' `compile` calls** — every existing `compile(a, &j, ast)` becomes `compile(a, &j, ast, null)`. (The `compileFilter` test helper calls `compile`; add the `null` arg.)

- [ ] **Step 3: Fix `records.list`'s `compile` call** — `records.zig`'s `list` calls `compiler.compile(alloc, &j, ast)`; change to `compiler.compile(alloc, &j, ast, null)` (user filters get no macro context). (Task 3 will add the rule path.)

- [ ] **Step 4: Add macro tests** to `src/query/compiler.zig`:

```zig
test "compile a macro rule binds the auth id as a param" {
    var d = try db.Db.openMemory(); defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a); // posts has title/price/author; add an owner-like text field? title works
    var auth: std.json.ObjectMap = .empty;
    try auth.put(a, "id", .{ .string = "u1" });
    const rctx = request.RequestContext{ .auth = .{ .object = auth } };
    const toks = try lexer.lex(a, "title = @request.auth.id");
    const ast = try parser.parse(a, toks);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compile(a, &j, ast, &rctx);
    try std.testing.expectEqualStrings("\"posts\".\"title\" = ?", c.where_sql);
    try std.testing.expectEqualStrings("u1", c.params[0].text);
}

test "compile @ path without a context errors" {
    var d = try db.Db.openMemory(); defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    const toks = try lexer.lex(a, "title = @request.auth.id");
    const ast = try parser.parse(a, toks);
    var j = joiner.Joiner.init(a, &d, posts);
    try std.testing.expectError(error.BadFilter, compile(a, &j, ast, null));
}

test "compile a method-vs-literal rule binds both as text" {
    var d = try db.Db.openMemory(); defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const posts = try setup(&d, a);
    const rctx = request.RequestContext{ .method = "GET" };
    const toks = try lexer.lex(a, "@request.method = \"GET\"");
    const ast = try parser.parse(a, toks);
    var j = joiner.Joiner.init(a, &d, posts);
    const c = try compile(a, &j, ast, &rctx);
    try std.testing.expectEqualStrings("? = ?", c.where_sql);
    try std.testing.expectEqualStrings("GET", c.params[0].text);
    try std.testing.expectEqualStrings("GET", c.params[1].text);
}
```
(Add `const request = @import("../request.zig");` to the compiler test imports if not already imported at file top — it is added in Step 1.)

- [ ] **Step 5: Run + commit** — `mise exec zig@0.16.0 -- zig build test` (expect 92). Commit:
```bash
git add src/query/compiler.zig src/records.zig
git commit -m "feat(rules): @request.* macro resolution in the filter compiler"
```

---

## Task 3: engine support — `Guard` + atomic create/update + list rule clause

**Files:** Modify `src/records.zig`.

- [ ] **Step 1: Add `error.Forbidden` + `Guard`** — in `src/records.zig` extend `RecordError` to include `Forbidden`, and add:

```zig
const request = @import("request.zig");

/// A compiled rule constraint to enforce atomically on create/update.
pub const Guard = struct {
    where_sql: []const u8,
    joins: []const []const u8 = &.{},
    params: []const compiler.Param = &.{},
};

fn joinsSql(alloc: std.mem.Allocator, joins: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (joins) |jn| { try out.append(alloc, ' '); try out.appendSlice(alloc, jn); }
    return out.toOwnedSlice(alloc);
}

/// Run `SELECT 1 FROM col <joins> WHERE col.id=?1 AND (where)` bound with id + guard params.
fn guardPasses(alloc: std.mem.Allocator, w: *db.Db, col: schema.Collection, id: []const u8, g: Guard) !bool {
    const js = try joinsSql(alloc, g.joins);
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM \"{s}\"{s} WHERE \"{s}\".\"id\"=?1 AND ({s});", .{ col.name, js, col.name, g.where_sql }, 0);
    var st = try w.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    _ = try bindParams(&st, g.params, 2);
    return try st.step();
}
```

- [ ] **Step 2: Guarded create** — refactor `create` into `createImpl` taking `guard: ?Guard`, keep `create` as the null-guard wrapper, add `createGuarded`:

```zig
pub fn create(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, col: schema.Collection, data: std.json.Value) RecordError!std.json.Value {
    return createImpl(alloc, io, w, col, data, null);
}
pub fn createGuarded(alloc: std.mem.Allocator, io: std.Io, w: *db.Db, col: schema.Collection, data: std.json.Value, guard: Guard) RecordError!std.json.Value {
    return createImpl(alloc, io, w, col, data, guard);
}
```
Rename the existing `create` body to `fn createImpl(alloc, io, w, col, data, guard: ?Guard) RecordError!std.json.Value` and, AT THE END (after the `INSERT ... RETURNING` step produces the row), wrap the guard check around the commit. The existing body does the validation + INSERT RETURNING + `rowToObject`. Change the tail so that when `guard != null` it runs inside a transaction with a rollback on failure:

```zig
    // ... existing: validation, build cols/vals/binds, generate gen_id ...
    if (guard != null) try w.begin();
    errdefer if (guard != null) (w.rollback() catch {});
    // ... existing: prepare INSERT ... RETURNING, bind id + values, st.step() ...
    if (!try st.step()) return error.NotFound;
    const rec = try rowToObject(alloc, &st, col);
    if (guard) |g| {
        st.finalize(); // release before the guard query on the same connection
        if (!try guardPasses(alloc, w, col, &gen_id, g)) { w.rollback() catch {}; return error.Forbidden; }
        try w.commit();
    }
    return rec;
```
(If the existing code uses `defer st.finalize()`, restructure so the guard query runs after the INSERT statement is finalized but before commit — finalize the INSERT stmt explicitly, then run `guardPasses`, then commit. Make the tests pass.)

- [ ] **Step 3: Guarded update** — same pattern: `update` → `updateImpl(.., guard: ?Guard)`; add `updateGuarded`. After the `UPDATE ... RETURNING` yields the row (and the record exists), run the guard; on failure rollback → `error.Forbidden`; if `UPDATE RETURNING` yields no row → return `null` (record absent). Wrap in `begin`/`commit` when `guard != null`.

- [ ] **Step 4: List rule clause** — extend `ListQuery` and `list`:

```zig
pub const ListQuery = struct {
    filter: ?[]const u8 = null,
    sort: ?[]const u8 = null,
    page: u32 = 1,
    perPage: u32 = 30,
    rule: ?[]const u8 = null, // a listRule expression to AND in (compiled with macro context)
    rctx: ?*const request.RequestContext = null,
};
```
In `list`, AFTER compiling the user filter on joiner `j` (with `null` rctx), compile the rule on the SAME `j` with `q.rctx`, and AND it into `where_sql`:

```zig
    // (existing) compile user filter -> where_sql, params  (compile(..., null))
    if (q.rule) |rstr| if (rstr.len > 0) {
        const rtoks = try lexer.lex(alloc, rstr);
        const rast = try parser.parse(alloc, rtoks);
        const rc = try compiler.compile(alloc, &j, rast, q.rctx);
        // combine wheres + params (rule joins already accumulated in j)
        if (where_sql.len > 0) {
            where_sql = try std.fmt.allocPrint(alloc, "({s}) AND ({s})", .{ where_sql, rc.where_sql });
        } else {
            where_sql = rc.where_sql;
        }
        var merged = std.ArrayList(compiler.Param).empty;
        try merged.appendSlice(alloc, params);
        try merged.appendSlice(alloc, rc.params);
        params = try merged.toOwnedSlice(alloc);
    };
    // (existing) build order_sql, joins_sql from j.joins, COUNT, page query...
```
Because the rule compiles on the same `j`, its joins are appended to `j.joins` and its aliases continue past the filter's — no collision. Params are concatenated in WHERE order (filter params first, then rule params), matching the `(filter) AND (rule)` text order.

- [ ] **Step 5: Tests** — add to `src/records.zig`:

```zig
test "createGuarded rolls back when the guard fails" {
    var d = try db.Db.openMemory(); defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a); // title text, price fixed
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "hi" });
    // guard that never matches: title = 'nope'
    const guard = Guard{ .where_sql = "\"posts\".\"title\" = ?", .params = &.{.{ .text = "nope" }} };
    try std.testing.expectError(error.Forbidden, createGuarded(a, std.testing.io, &d, col, .{ .object = data }, guard));
    // table is empty (rolled back)
    var st = try d.prepare("SELECT COUNT(*) FROM posts;");
    defer st.finalize();
    _ = try st.step();
    try std.testing.expectEqual(@as(i64, 0), st.columnInt(0));
}

test "createGuarded commits when the guard passes" {
    var d = try db.Db.openMemory(); defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    var data: std.json.ObjectMap = .empty;
    try data.put(a, "title", .{ .string = "hi" });
    const guard = Guard{ .where_sql = "\"posts\".\"title\" = ?", .params = &.{.{ .text = "hi" }} };
    const rec = try createGuarded(a, std.testing.io, &d, col, .{ .object = data }, guard);
    try std.testing.expectEqualStrings("hi", rec.object.get("title").?.string);
}

test "list applies a rule clause AND-ed with the filter" {
    var d = try db.Db.openMemory(); defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const col = try seedPosts(&d, a);
    try d.exec("INSERT INTO posts (id,created,updated,title,price) VALUES ('r1','t','t','keep',100),('r2','t','t','drop',100);");
    const res = try list(a, &d, col, .{ .rule = "title = \"keep\"" });
    try std.testing.expectEqual(@as(i64, 1), res.totalItems);
    try std.testing.expectEqualStrings("r1", res.items[0].object.get("id").?.string);
}
```

- [ ] **Step 6: Run + commit** — `mise exec zig@0.16.0 -- zig build test` (expect ~95). Commit:
```bash
git add src/records.zig
git commit -m "feat(records): atomic create/update guard + list rule clause"
```

---

## Task 4: `rules.zig` — policy layer

**Files:** Create `src/rules.zig`; Modify `src/main.zig`.

- [ ] **Step 1: Create `src/rules.zig`**

```zig
const std = @import("std");
const db = @import("db.zig");
const schema = @import("schema.zig");
const request = @import("request.zig");
const records = @import("records.zig");
const lexer = @import("query/lexer.zig");
const parser = @import("query/parser.zig");
const compiler = @import("query/compiler.zig");
const joiner = @import("query/joiner.zig");

pub const Decision = enum { allow, deny_locked, check };

/// Pure policy: superuser -> allow; null rule -> deny_locked; "" -> allow; else -> check.
pub fn decide(rule: ?[]const u8, rctx: *const request.RequestContext) Decision {
    if (rctx.is_superuser) return .allow;
    const r = rule orelse return .deny_locked;
    if (r.len == 0) return .allow;
    return .check;
}

pub const RuleError = error{ BadRule } || compiler.CompileError || db.DbError || std.mem.Allocator.Error || @typeInfo(@typeInfo(@TypeOf(joiner.Joiner.resolve)).@"fn".return_type.?).error_union.error_set;

/// Compile a `check`-state rule into a records.Guard (its own joiner; standalone guarded query).
pub fn compileGuard(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, rule: []const u8, rctx: *const request.RequestContext) RuleError!records.Guard {
    const toks = try lexer.lex(alloc, rule);
    const ast = try parser.parse(alloc, toks);
    var j = joiner.Joiner.init(alloc, conn, col);
    const c = try compiler.compile(alloc, &j, ast, rctx);
    return .{ .where_sql = c.where_sql, .joins = j.joins.items, .params = c.params };
}

/// True if `id`'s row satisfies a `check`-state rule (guarded SELECT 1). Caller handles
/// the allow/deny_locked decisions; this is only for the `check` branch.
pub fn matches(alloc: std.mem.Allocator, conn: *db.Db, col: schema.Collection, id: []const u8, rule: []const u8, rctx: *const request.RequestContext) RuleError!bool {
    const g = try compileGuard(alloc, conn, col, rule, rctx);
    var joins: std.ArrayList(u8) = .empty;
    for (g.joins) |jn| { try joins.append(alloc, ' '); try joins.appendSlice(alloc, jn); }
    const sql = try std.fmt.allocPrintSentinel(alloc, "SELECT 1 FROM \"{s}\"{s} WHERE \"{s}\".\"id\"=?1 AND ({s});", .{ col.name, joins.items, col.name, g.where_sql }, 0);
    var st = try conn.prepare(sql);
    defer st.finalize();
    try st.bindText(1, id);
    _ = try records.bindParams(&st, g.params, 2);
    return try st.step();
}

test "decide: superuser/allow/null/empty/expr" {
    const su = request.RequestContext{ .is_superuser = true };
    const anon = request.RequestContext{};
    try std.testing.expectEqual(Decision.allow, decide(null, &su));
    try std.testing.expectEqual(Decision.deny_locked, decide(null, &anon));
    try std.testing.expectEqual(Decision.allow, decide("", &anon));
    try std.testing.expectEqual(Decision.check, decide("title = \"x\"", &anon));
}

test "matches runs a guarded select" {
    var d = try db.Db.openMemory(); defer d.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator); defer arena.deinit();
    const a = arena.allocator();
    const migrations = @import("migrations.zig");
    const collections = @import("collections.zig");
    try migrations.run(&d);
    const col = try collections.create(a, std.testing.io, &d, .{ .id = "", .name = "posts", .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }} });
    try d.exec("INSERT INTO posts (id,created,updated,title) VALUES ('r1','t','t','ok');");
    const anon = request.RequestContext{};
    try std.testing.expect(try matches(a, &d, col, "r1", "title = \"ok\"", &anon));
    try std.testing.expect(!try matches(a, &d, col, "r1", "title = \"no\"", &anon));
}
```

- [ ] **Step 2: Aggregate + run + commit** — add `_ = @import("rules.zig");` to `src/main.zig`'s `test {}`. Run tests (expect ~97). Commit:
```bash
git add src/rules.zig src/main.zig
git commit -m "feat(rules): decide/compileGuard/matches policy layer"
```

---

## Task 5: wire enforcement into the handlers + smoke

**Files:** Modify `src/api/records.zig`, `src/main.zig`.

- [ ] **Step 1: Update `TestEnv` to seed PUBLIC rules** — in `src/api/records.zig`'s `TestEnv.init`, the seeded `posts` collection must have public rules so the existing happy-path handler tests still pass under enforcement. Change the seeded collection definition to set all five rules to `""`:

```zig
            _ = try collections.create(std.testing.allocator, std.testing.io, w, .{
                .id = "", .name = "posts",
                .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
                .listRule = "", .viewRule = "", .createRule = "", .updateRule = "", .deleteRule = "",
            });
```

- [ ] **Step 2: Add a context builder + enforcement to the handlers.** Add imports and a helper:

```zig
const rules = @import("../rules.zig");
const request = @import("../request.zig");

/// SP4: an empty request context (SP5 fills auth/superuser from the verified token).
fn buildContext(ctx: *http.RequestCtx, data: ?std.json.Value) request.RequestContext {
    return .{ .auth = null, .is_superuser = false, .data = data, .method = @tagName(ctx.method) };
}

fn forbidden(ctx: *http.RequestCtx) !http.Response {
    return ApiError{ .status = 403, .message = "Forbidden." }.toResponse(ctx.allocator);
}
```
Then enforce in each handler (full replacements):

**view** — after resolving `col`:
```zig
pub fn view(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.openReader();
    defer r.close();
    const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, null);
    switch (rules.decide(col.viewRule, &rctx)) {
        .deny_locked => return ApiError.notFound().toResponse(ctx.allocator), // hide
        .allow => {},
        .check => if (!try rules.matches(ctx.allocator, &r, col, rid, col.viewRule.?, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }
    var rec = (try records.get(ctx.allocator, &r, col, rid)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    if (qp.get("expand")) |exp| if (exp.len > 0) try expand_mod.expand(ctx.allocator, &r, col, &rec, exp, 0);
    return jsonResponse(ctx, 200, rec);
}
```

**create** — decide on `createRule`; on `check`, compile a guard and use `records.createGuarded`:
```zig
pub fn create(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const data = (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
        return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator)).value;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, data);
    const rec = switch (rules.decide(col.createRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => records.create(ctx.allocator, app.io, w, col, data),
        .check => records.createGuarded(ctx.allocator, app.io, w, col, data, try rules.compileGuard(ctx.allocator, w, col, col.createRule.?, &rctx)),
    } catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.NotObject => return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator),
        error.Forbidden => return forbidden(ctx),
        else => return e,
    };
    return jsonResponse(ctx, 201, rec);
}
```

**update** — record existence → 404; then decide/guard:
```zig
pub fn update(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const data = (std.json.parseFromSlice(std.json.Value, ctx.allocator, ctx.body, .{}) catch
        return ApiError.badRequest("Invalid JSON body.").toResponse(ctx.allocator)).value;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    if ((try records.get(ctx.allocator, w, col, rid)) == null) return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, data);
    const updated = switch (rules.decide(col.updateRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => records.update(ctx.allocator, w, col, rid, data),
        .check => records.updateGuarded(ctx.allocator, w, col, rid, data, try rules.compileGuard(ctx.allocator, w, col, col.updateRule.?, &rctx)),
    } catch |e| switch (e) {
        error.Validation => return validationResponse(ctx),
        error.NotObject => return ApiError.badRequest("Body must be a JSON object.").toResponse(ctx.allocator),
        error.Forbidden => return ApiError.notFound().toResponse(ctx.allocator), // hide
        else => return e,
    };
    return jsonResponse(ctx, 200, updated orelse return ApiError.notFound().toResponse(ctx.allocator));
}
```

**delete** — existence → 404; decide; guarded `matches`:
```zig
pub fn delete(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    const w = app.pool.acquireWriter();
    defer app.pool.releaseWriter();
    const col = (try resolveCollection(ctx, w)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rid = ctx.param("id") orelse return ApiError.notFound().toResponse(ctx.allocator);
    if ((try records.get(ctx.allocator, w, col, rid)) == null) return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, null);
    switch (rules.decide(col.deleteRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => {},
        .check => if (!try rules.matches(ctx.allocator, w, col, rid, col.deleteRule.?, &rctx)) return ApiError.notFound().toResponse(ctx.allocator),
    }
    if (!try records.delete(ctx.allocator, w, col, rid)) return ApiError.notFound().toResponse(ctx.allocator);
    return .{ .status = 204, .body = "" };
}
```

**list** — decide on `listRule`; pass it (and rctx) into `records.list`:
```zig
pub fn list(ctx: *http.RequestCtx) anyerror!http.Response {
    const app = ctx.app.?;
    var r = try app.pool.openReader();
    defer r.close();
    const col = (try resolveCollection(ctx, &r)) orelse return ApiError.notFound().toResponse(ctx.allocator);
    const rctx = buildContext(ctx, null);
    var rule_expr: ?[]const u8 = null;
    switch (rules.decide(col.listRule, &rctx)) {
        .deny_locked => return forbidden(ctx),
        .allow => {},
        .check => rule_expr = col.listRule,
    }
    const qp = try params_mod.parse(ctx.allocator, ctx.query);
    const result = records.list(ctx.allocator, &r, col, .{
        .filter = qp.get("filter"), .sort = qp.get("sort"),
        .page = parseU32(qp.get("page"), 1), .perPage = parseU32(qp.get("perPage"), 30),
        .rule = rule_expr, .rctx = &rctx,
    }) catch |e| switch (e) {
        error.UnknownField, error.NotARelation, error.MultiRelationTraversal, error.BadFilter, error.BadSort, error.BadValue, error.UnexpectedToken, error.BadOperand, error.Empty, error.UnexpectedChar, error.UnterminatedString =>
            return ApiError.badRequest("Invalid filter or sort.").toResponse(ctx.allocator),
        else => return e,
    };
    // (existing expand + envelope assembly unchanged)
    ...
}
```
Keep the rest of `list` (expand loop + `{page,perPage,totalItems,totalPages,items}` envelope) exactly as it is now.

- [ ] **Step 3: Add deny-path handler tests** to `src/api/records.zig`. Add a helper to seed a collection with specific rules, then:

```zig
fn seedRuled(env: *TestEnv, name: []const u8, listR: ?[]const u8, viewR: ?[]const u8, createR: ?[]const u8) !void {
    const w = env.pool.acquireWriter();
    defer env.pool.releaseWriter();
    _ = try collections.create(std.testing.allocator, std.testing.io, w, .{
        .id = "", .name = name,
        .fields = &[_]schema.Field{.{ .id = "f1", .name = "title", .options = .{ .text = .{} } }},
        .listRule = listR, .viewRule = viewR, .createRule = createR,
    });
}

test "locked (null) collection: list 403, create 403" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedRuled(env, "locked", null, null, null);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "locked" }};
    var lctx = http.RequestCtx{ .method = .GET, .path = "/", .query = "", .allocator = a, .app = &env.app, .params = &p };
    try std.testing.expectEqual(@as(u16, 403), (try list(&lctx)).status);
    var cctx = ctxFor(env, a, .POST, "{\"title\":\"x\"}", &p);
    try std.testing.expectEqual(@as(u16, 403), (try create(&cctx)).status);
}

test "createRule on request data: empty title -> 403, nonempty -> 201" {
    var env = try TestEnv.init();
    defer env.deinit();
    try seedRuled(env, "guarded", "", "", "@request.data.title != \"\"");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = [_]http.Param{.{ .key = "col", .value = "guarded" }};
    var bad = ctxFor(env, a, .POST, "{\"title\":\"\"}", &p);
    try std.testing.expectEqual(@as(u16, 403), (try create(&bad)).status);
    var ok = ctxFor(env, a, .POST, "{\"title\":\"hello\"}", &p);
    try std.testing.expectEqual(@as(u16, 201), (try create(&ok)).status);
}
```
Note: `@request.data.title != ""` — when `title` is `""`, the macro resolves to `""`, so `"" != ""` is false → guard fails → the INSERT row (title="") doesn't match → rollback → 403. When title="hello", `"hello" != ""` true → commit → 201. (The guard SQL is `? != ?` bound `["hello",""]` evaluated against the new row — since it references no column, it's a constant predicate AND-ed with `id=?`, which the new row's id satisfies, so the row matches iff the predicate is true.)

- [ ] **Step 4: Build + unit tests** — `mise exec zig@0.16.0 -- zig build && mise exec zig@0.16.0 -- zig build test`. Expect clean build + all pass (~101).

- [ ] **Step 5: Manual smoke (public vs locked vs data-rule).**
```bash
rm -rf ./zb_data
mise exec zig@0.16.0 -- zig build
./zig-out/bin/zigbase serve --http-port 8090 --data-dir ./zb_data >/tmp/zb_sp4.log 2>&1 &
SP=$!; sleep 1.5
echo "--- public collection: full CRUD works ---"
curl -s -X POST http://127.0.0.1:8090/api/collections -H 'content-type: application/json' -d '{"name":"pub","listRule":"","viewRule":"","createRule":"","updateRule":"","deleteRule":"","fields":[{"id":"","name":"title","type":"text","options":{}}]}' >/dev/null
curl -s -o /dev/null -w "create on public: %{http_code}\n" -X POST http://127.0.0.1:8090/api/collections/pub/records -H 'content-type: application/json' -d '{"title":"hi"}'
echo "--- locked collection (default null rules): list/create denied ---"
curl -s -X POST http://127.0.0.1:8090/api/collections -H 'content-type: application/json' -d '{"name":"locked","fields":[{"id":"","name":"title","type":"text","options":{}}]}' >/dev/null
curl -s -o /dev/null -w "list locked: %{http_code}\n" "http://127.0.0.1:8090/api/collections/locked/records"
curl -s -o /dev/null -w "create locked: %{http_code}\n" -X POST http://127.0.0.1:8090/api/collections/locked/records -H 'content-type: application/json' -d '{"title":"x"}'
echo "--- data-rule collection: createRule @request.data.title != '' ---"
curl -s -X POST http://127.0.0.1:8090/api/collections -H 'content-type: application/json' -d '{"name":"req","listRule":"","createRule":"@request.data.title != \"\"","fields":[{"id":"","name":"title","type":"text","options":{}}]}' >/dev/null
curl -s -o /dev/null -w "create empty title: %{http_code}\n" -X POST http://127.0.0.1:8090/api/collections/req/records -H 'content-type: application/json' -d '{"title":""}'
curl -s -o /dev/null -w "create with title: %{http_code}\n" -X POST http://127.0.0.1:8090/api/collections/req/records -H 'content-type: application/json' -d '{"title":"ok"}'
kill $SP 2>/dev/null; wait $SP 2>/dev/null
```
Expected: public create → 201; locked list → 403, locked create → 403; data-rule create empty → 403, with title → 201. **Always kill the server.**

- [ ] **Step 6: Commit**
```bash
git add src/api/records.zig src/main.zig
git commit -m "feat(api): enforce per-collection access rules on record endpoints"
```

---

## Self-Review (completed by plan author)

**Spec coverage (SP4 design §2-§9):**
- `RequestContext` seam + macro resolution → Task 1 ✓
- `@`-lexer + compiler macro resolution (bound literals; null-context rejects `@`) → Tasks 1,2 ✓
- guarded-SELECT model, atomic create/update guard (rollback), list rule clause → Task 3 ✓
- `decide` policy + `compileGuard`/`matches` → Task 4 ✓
- per-op enforcement with hide codes (list 403/filter, view 404, create 403, update/delete 404, locked 403) → Task 5 ✓
- default-locked handling: TestEnv fixtures → public; deny-path tests → Task 5 ✓
- collection-management endpoints unchanged (record rules only) → not touched ✓
- **Deferred per spec:** `@collection.*`; auth population (SP5).

**Type consistency:** `request.RequestContext{auth,is_superuser,data,method}`+`resolveMacro`; `compiler.compile(...,rctx)`+`operandToText`/`operandToParam`/`isColPath`; `records.{Guard,createGuarded,updateGuarded,error.Forbidden}`+`ListQuery{rule,rctx}`+`bindParams`(pub); `rules.{Decision,decide,compileGuard,matches}`; handler `buildContext`/`forbidden`. Consistent.

**Placeholder scan:** Tasks 1, 4 complete code; Task 2 complete compiler code; Task 3 gives complete `Guard`/`guardPasses`/list-clause code with explicit structural notes for splicing the guard into the existing create/update tails (the tests pin commit-vs-rollback behavior); Task 5 gives complete handler replacements. No vague steps; every deny path maps to a concrete status.
