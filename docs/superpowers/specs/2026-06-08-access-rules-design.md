# ZigBase Sub-Project 4: API Access Rules — Design

**Date:** 2026-06-08
**Status:** Approved (design); implementation plan to follow.
**Depends on:** SP1–SP3 (Foundation, Collections, Records + query) — all merged to `main`.
**Builds toward:** SP5 (Auth) fills the `RequestContext` auth seam this sub-project establishes.

---

## 1. Overview & Goals

SP4 enforces per-collection access rules on every record operation. Each collection already
carries five rule columns (`listRule`, `viewRule`, `createRule`, `updateRule`, `deleteRule`,
stored since SP2, unused until now). A rule is a **filter expression** (the SP3 filter
language, extended with `@request.*` macros). Semantics per rule value:

- **`null`** → superuser-only (locked).
- **`""`** (empty string) → public (always allowed).
- **non-empty** → the expression must match.

A **superuser** request bypasses all rules. The authenticated identity comes from SP5; SP4
establishes the seam (`RequestContext`) and builds the entire rule engine against it. With no
auth yet, auth-gated rules evaluate as "unauthenticated" (deny), while public, data-based, and
method-based rules work and are tested end-to-end.

### In scope
- `RequestContext` seam (auth/superuser/data/method).
- `@request.*` macro extension to the filter compiler (auth/data/method).
- Per-op rule enforcement on the five record endpoints, with the deny semantics below.
- The minimal engine changes to support atomic create/update rule guards.

### Out of scope (deferred)
- `@collection.<name>.<field>` correlated-subquery rules (later pass).
- Auth itself (SP5) — `RequestContext.auth`/`is_superuser` stay empty here.
- Superuser-gating of the collection-management endpoints (`/api/collections`) — those remain
  open with their existing `// TODO(SP5)` markers; SP4 enforces **record** rules only.

---

## 2. The Unifying Model

Every rule check reduces to a parameterized SQL guard, reusing the SP3 `joiner` + `compiler`:

- **Single-record ops (view/create/update/delete):** `SELECT 1 FROM "<col>" <joins> WHERE
  "<col>"."id" = ? AND (<ruleWhere>);` — a row comes back iff the record satisfies the rule.
- **list:** the `<ruleWhere>` (plus its joins/params) is AND-ed into the list query's WHERE.

`<ruleWhere>` + its bound params + its joins are produced by compiling the rule string through
the existing filter pipeline, with macro operands resolved from the `RequestContext`. **Every
literal (rule constant or macro value) is a bound `?`; every identifier comes from validated
schema or generated aliases** — the SP3 injection-safety invariant carries over unchanged.

---

## 3. `RequestContext` — the auth seam

`src/rules.zig`:
```zig
pub const RequestContext = struct {
    auth: ?std.json.Value = null,   // the authenticated record object; null = unauthenticated
    is_superuser: bool = false,
    data: ?std.json.Value = null,   // request body (for create/update rules)
    method: []const u8 = "",
};
```
SP4 handlers build an empty context (`auth = null`, `is_superuser = false`, `data = body`,
`method = <verb>`). SP5's auth middleware will populate `auth`/`is_superuser` from the verified
token; nothing else changes.

---

## 4. `@request.*` Macros (filter-language extension)

### Lexer
`src/query/lexer.zig`: allow `@` as an identifier character so `@request.auth.id` lexes as one
`ident` token. (Path segments still split on `.`.)

### Compiler
`src/query/compiler.zig`: the compile entry gains an optional `rctx: ?*const RequestContext`.
Operand resolution:
- A `.path` operand **starting with `@request.`** is a macro → resolved to a **bound literal
  Param** from `rctx` (the SQL side is `?`), NOT a column ref:
  - `@request.auth.id` → `rctx.auth.?.object.get("id")` as text, or `""` when `auth == null`.
  - `@request.auth.<field>` → that field's value (text), or `""` when unauth/missing.
  - `@request.data.<field>` → `rctx.data.?.object.get(field)` (text), or `""` if absent.
  - `@request.method` → `rctx.method` (text).
  - Any other `@…` → `error.BadFilter`.
- A `.path` operand **not** starting with `@` resolves as a column via the `Joiner` (existing
  behavior).
- When `rctx == null` (a normal user `?filter=`), a `@`-prefixed path → error (users cannot use
  macros in their own filters).

Result: `owner = @request.auth.id` compiles to `"posts"."owner" = ?` with the param being the
authed id string (`""` when unauthenticated). Macro values are bound as **text** params
(sufficient for ids/strings in SP4).

---

## 5. Enforcement per Operation

`src/rules.zig` provides the decision + guard helpers; `src/api/records.zig` wires them in. A
pure decision precedes any SQL:

```zig
pub const Decision = enum { allow, deny_locked, check };
pub fn decide(rule: ?[]const u8, rctx: *const RequestContext) Decision; // null→(superuser?allow:deny_locked); ""→allow; else→check
```
(`is_superuser` short-circuits to `allow` for every op before `decide` is consulted.)

| Op | Behavior on each rule state |
|---|---|
| **list** | superuser → no rule filter. `null` → **403**. `""` → no filter. else → compile `listRule` and AND its `where`/joins/params into `records.list`. |
| **view** | superuser → ok. `null` → **404**. `""` → return record. else → guarded `SELECT 1`; miss → **404**. |
| **create** | superuser → ok. `null` → **403**. `""` → ok. else → engine runs the INSERT + the createRule guard inside one transaction; guard miss → rollback → **403**. |
| **update** | record absent → **404**. superuser → ok. `null` → **403**. `""` → ok. else → engine runs the UPDATE + updateRule guard in one transaction; guard miss → rollback → **404**. |
| **delete** | record absent → **404**. superuser → ok. `null` → **403**. `""` → ok. else → guarded `SELECT 1`; miss → **404**. |

Rationale for codes (the "hide" choice): a record you may not see returns **404** (no existence
leak) for view/update/delete rule-misses; an outright-locked collection (`null` rule,
non-superuser) returns **403**; a rejected create returns **403** (nothing to hide).

### Engine guard (`src/records.zig`)
`create`/`update` gain an optional `guard: ?Guard` where
`Guard = struct { sql: []const u8, params: []const compiler.Param }`. When present, the engine
wraps the mutation in a transaction, and after the INSERT/UPDATE `RETURNING` (which yields the
new/updated id) runs `SELECT 1 FROM "<col>" <guard joins already in sql> WHERE "<col>"."id"=?1
AND (<guard.sql>)` bound with the id + guard params; **no row → rollback → `error.Forbidden`**;
row → commit. When `guard == null`, behavior is exactly as today (engine-direct callers and
existing tests unaffected). `list` gains optional `rule_where`/`rule_params`/`rule_joins`
inputs that compose with the user filter (AND).

View/delete guards are pre-checks performed by `rules.zig` via a guarded `SELECT 1` on the
reader (view) / writer (delete) connection — no engine change needed for those.

---

## 6. Files

New: `src/rules.zig` — `RequestContext`, `Decision`/`decide`, rule compilation (wrapping the
filter lexer/parser/compiler with a context), and the per-op guard helpers
(`listClause`, `allowView`, `allowDelete`, and the `Guard` builders for create/update).
Modified:
- `src/query/lexer.zig` — `@` in identifiers.
- `src/query/compiler.zig` — optional `rctx`; macro operand resolution.
- `src/records.zig` — `create`/`update` optional `guard`; `list` optional rule clause.
- `src/api/records.zig` — build `RequestContext`, enforce rules per handler, map deny → 403/404.

Each unit keeps one responsibility: `rules` = policy + guard composition; `compiler` = SQL +
macro resolution; `records` = execution with an optional guard; `api/records` = HTTP wiring.

---

## 7. Concurrency, Security, Errors

- **Atomicity:** create/update guards run inside the engine's existing writer transaction
  (single-writer mutex), so a failed rule leaves no trace. view/delete pre-checks run on the
  held connection.
- **Security:** rule literals and macro values are bound `?` params; identifiers come only from
  validated schema / generated aliases — same invariant SP3's holistic review verified. The
  `@`-macro path is reachable ONLY with a `RequestContext` (rules), never from user `?filter=`.
- **Errors:** `error.Forbidden` (new) → 403; rule-miss hides → 404; record-absent → 404; bad
  rule expression (shouldn't happen for stored rules, but) → 500 fallback, logged.

---

## 8. Default-locked note (important for usability in SP4)

New collections created via the API default every rule to `null` (locked) unless the creator
sets them. So **with no auth yet, a default collection's record endpoints are all locked**
(403/404) — correct PocketBase semantics. To exercise records in SP4, create collections with
explicit `""` (public) or macro/data-based rules. SP5's superuser will unlock `null`-ruled
collections. The existing record handler-test fixtures (which seed collections with default
`null` rules and then CRUD) are updated to seed **public** rules; new tests cover the deny
paths.

---

## 9. Testing Strategy

TDD throughout; `zig build test` green at each step.
- **Macro resolution:** `@request.auth.id` with auth present vs `null` (→ `""`);
  `@request.data.<f>`; `@request.method`; unknown `@…` → error; `@` in a user filter (no
  context) → error.
- **`decide`:** null→deny_locked / superuser→allow; ""→allow; expr→check.
- **Rule compilation:** a rule like `owner = @request.auth.id` → expected guarded SQL + bound
  params; a relation-path rule emits joins.
- **Engine guard:** `create`/`update` with a passing guard commits; with a failing guard
  rolls back (row absent afterward) and returns `error.Forbidden`.
- **Handlers:** for each op, allow vs deny across `null` (403/404), `""` (allow), a data rule
  (`@request.data.title != ""`), and an auth rule (`owner = @request.auth.id`, which denies
  while unauthenticated). Confirm exact status codes.
- **Manual smoke:** a public collection (full CRUD works), a `null`-ruled collection
  (list→403, view→404, create→403), and a `createRule:"@request.data.title != ''"` collection
  (create with a title succeeds, create with empty title → 403).

---

## 10. Risks & Notes

- **Macro typing:** macro values bind as text; comparing a macro to a numeric column relies on
  SQLite's dynamic typing. Acceptable for SP4 (ids/strings); revisit if numeric macro
  comparisons are needed.
- **Empty-string macro semantics:** unauthenticated `@request.auth.id` → `""`, so
  `owner = @request.auth.id` matches only records whose owner is literally `""` — effectively
  deny for real data. This is the intended PocketBase behavior.
- **`@collection.*` deferred:** the `@`-token grammar added here is the foundation; correlated
  subqueries are a deliberate later extension and must stay off the raw-identifier path to
  preserve injection-safety.
