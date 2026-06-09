# ZigBase Sub-Project 3: Records CRUD + Query — Design

**Date:** 2026-06-08
**Status:** Approved (design); two implementation plans (3a, 3b) to follow.
**Depends on:** SP1 (Foundation) + SP2 (Collections & schema engine + REST), both merged to `main`.
**Builds toward:** SP4 (access rules — will gate these endpoints), SP7 (realtime over record changes).

---

## 1. Overview & Goals

SP3 turns ZigBase's collections into a working data API: create, read, update, delete, and
query records in any collection's physical table, over REST. It implements per-field-type
value (de)serialization (including precise fixed-point), record validation against the
collection schema, a filter/sort/pagination query language compiled to parameterized SQL with
relation-path joins, and nested relation `expand`.

Record-level **access rules are NOT enforced here** — endpoints are unprotected, gated in SP4.

### Decomposition (two plans, each independently testable)
- **3a — Records core:** `values.zig` (de)serialization, record validation, record engine
  single-record `create`/`get`/`update`/`delete`, and the REST endpoints for those.
- **3b — Query & list:** the filter language (with relation-path traversal), sort, pagination,
  the list endpoint, and nested `expand`.

### In scope
- Value ↔ column conversion for every field type, with **precise string-based numerics** for
  `int`/`fixed` and exact decimal↔scaled-integer arithmetic.
- Record `create`/`get`/`update`/`delete`/`list`.
- Record validation (required, type-parse, select membership, relation existence, count limits).
- Filter language: `= != > >= < <= ~ !~`, `&& ||`, grouping, **relation-path operands**
  (`author.name`) via `LEFT JOIN` chains.
- Sort (incl. relation paths), pagination (`page`/`perPage`), top-level field selection.
- Nested relation `expand` (`author.profile,tags`) with cycle/depth guards.
- Reads use a read-only pool connection; writes use the serialized writer.

### Out of scope (later)
- Access rule enforcement (SP4) — endpoints carry `// TODO(SP4)`.
- Multi-relation array cleanup when a referenced record is deleted (single-relation FK cascade
  is automatic via SP2). Noted; deferred.
- Regex `pattern` and email/url **format** validation (basic type validation only here).
- Batched expand (N+1 fetch is acceptable now); auth/view/file-storage specifics.

---

## 2. Value (De)serialization — `src/values.zig`

The crux of SP3. Pure functions converting between a JSON `std.json.Value` and SQLite
bind/column operations, driven by a `schema.Field`. No DB cursor logic here beyond bind/read.

| Field type | JSON representation | SQLite storage | Conversion notes |
|---|---|---|---|
| `text`/`email`/`url`/`editor` | string | TEXT | passthrough |
| `bool` | `true`/`false` | INTEGER 0/1 | |
| `number` `float` | JSON number | REAL | `f64` |
| `number` `int` | **JSON string** | INTEGER | parse to `i64` (reject non-integer / overflow); format `i64`→string |
| `number` `fixed`(scale N) | **JSON string** e.g. `"10.50"` | INTEGER (unscaled, e.g. `1050`) | exact decimal-string↔scaled-integer (see below) |
| `date`/`autodate` | string (RFC3339) | TEXT | stored/returned verbatim; engine sets autodate |
| `json` | embedded JSON value | TEXT | `Stringify` on write, `parseFromSlice` on read |
| `select` single / multi | string / array of strings | TEXT / TEXT(JSON array) | multi (`maxSelect>1`) stored as JSON array |
| `relation` single / multi | id string / array | TEXT / TEXT(JSON array) | ids only here; resolution is `expand` |
| `file` single / multi | filename / array | TEXT / TEXT(JSON array) | stub (SP8) |

### Fixed-point conversion (exact, integer-only)
- **Parse** `decimalToScaledInt(str, scale) -> i64`: optional leading `-`; split on `.`; integer
  part and fraction part are digit strings. Fraction longer than `scale` → error
  (`validation_too_precise`); shorter is zero-padded to `scale`. Result =
  `sign * (intPart * 10^scale + fracPart)`, computed in `i64` with overflow checked. No `f64`.
- **Format** `scaledIntToDecimal(v, scale) -> string`: sign, `abs/10^scale` for the integer part,
  `abs % 10^scale` zero-padded to `scale` digits for the fraction; omit the `.` when `scale==0`.
- `int` mode uses the same parse/format with `scale==0` (i.e. plain integer string).

These are tiny, pure, and unit-tested across sign, padding, over-precision, zero, and
round-trip cases.

### Interface
```
bindValue(stmt, idx, field, value)   -> binds the JSON value as the right SQLite type
readValue(alloc, stmt, idx, field)   -> produces the JSON value from the column
```
`values.zig` returns typed errors (`ValueError{ TypeMismatch, TooPrecise, Overflow, BadSelect, ... }`)
that the validation/engine layer maps to field-level API errors.

---

## 3. Record Engine — `src/records.zig`

Operates on a `*db.Db` (a writer for mutations, a reader for queries) plus a `schema.Collection`.

- `create(alloc, io, w, col, data) -> RecordJson`: generate 15-char `id`; set `created`/`updated`
  (RFC3339 via `strftime('%Y-%m-%dT%H:%M:%SZ','now')`); set autodate fields with `onCreate`;
  validate (§4); INSERT with bound values; return the stored record.
- `get(alloc, r, col, id) -> ?RecordJson`: SELECT by id; map each column via `values.readValue`.
- `update(alloc, w, col, id, data) -> RecordJson`: 404 if absent; merge provided fields
  (partial update); set `updated` + autodate `onUpdate`; validate; UPDATE bound; return record.
- `delete(w, col, id) -> void`: DELETE by id (single-relation FK cascade is automatic).
- `list(alloc, r, col, query) -> ListResult`: §5 (3b).

A **record** serializes to JSON as `{ "id", "created", "updated", <field>: <value>, ... }`,
with an optional `"expand": { ... }` (§5). All SQL is built from validated schema identifiers
with every value bound.

---

## 4. Record Validation

On `create`/`update`, before writing:
- **required:** required field missing/empty → `validation_required`.
- **type-parse:** value must convert via `values.zig`; parse failures (bad number string,
  over-precise fixed, non-bool, malformed json) → the corresponding field error.
- **select:** each value ∈ `options.values`; count ≤ `maxSelect` → `validation_select`.
- **relation:** each referenced id exists in the target collection; count ≤ `maxSelect` →
  `validation_relation` / `validation_not_found`.
- Unknown keys in the input that aren't schema fields are ignored (lenient).
- **Deferred:** regex `pattern`, email/url format.

Errors accumulate into the same `[]FieldError` envelope used by collections (`{code,message,
data:{<field>:{code,message}}}`), surfaced as HTTP 400.

---

## 5. Query & List (3b)

### Filter language — `src/query/`
Recursive-descent parser → AST → SQL `WHERE` fragment + bound params. Grammar:
```
expr    := or
or      := and ( '||' and )*
and     := cmp ( '&&' cmp )*
cmp     := '(' expr ')' | operand OP operand
OP      := '=' | '!=' | '>' | '>=' | '<' | '<=' | '~' | '!~'
operand := path | string | number | bool | null
path    := ident ( '.' ident )*
```
- Comparisons compile to `col OP ?` with the literal bound; `~`/`!~` →
  `col LIKE ?` / `col NOT LIKE ?` with the param wrapped `%term%`.
- **Relation paths** (`author.name`): each non-terminal segment is a relation field; the
  compiler emits a `LEFT JOIN "<targetTable>" AS j<k> ON "<prev>"."<field>" = j<k>."id"` and the
  final segment becomes `j<k>."<field>"`. Joins are de-duplicated per distinct path prefix.
  Only single-value relations are traversable in filters (multi-relation traversal → error).
- **Identifiers** (field/relation names, target table names) come from the validated schema —
  never from raw filter text beyond matching known field names; an unknown field/path →
  `400 validation_filter`. **Every literal is bound**; the compiler never interpolates user
  values.

### Sort
`sort=-created,author.name` → `ORDER BY "created" DESC, j<k>."name" ASC`. Relation paths reuse
the join machinery. Unknown sort field → 400.

### Pagination & list response
`page` (1-based, default 1), `perPage` (default 30, max 500). The engine runs a `COUNT(*)`
with the same FROM/JOIN/WHERE for `totalItems`, then the page query with `LIMIT/OFFSET`.
```
{ "page": N, "perPage": M, "totalItems": T, "totalPages": ceil(T/M), "items": [ <record>... ] }
```
`fields=id,title` (optional) trims each item's top-level keys after serialization.

### Nested expand
`expand=author.profile,tags`. Parse into a path tree. For each result record and each top-level
expand key (a relation field): fetch the related record(s) by stored id(s), recurse into the
sub-tree, and nest the result under `record.expand.<field>` (single → object, multi → array).
Guards: a max depth (e.g. 6) and a visited `(collection,id)` set per chain to break cycles.
Fetches are per-record (N+1) now; batching is a later optimization.

---

## 6. REST Endpoints — `src/api/records.zig`

All **unprotected** (`// TODO(SP4): enforce <op>Rule`). Routes added to `server.zig`.

| Method & path | Behavior | Success |
|---|---|---|
| `GET /api/collections/:col/records` | list (filter/sort/page/perPage/expand/fields) | 200 list envelope |
| `GET /api/collections/:col/records/:id` | view (expand/fields) | 200 / 404 |
| `POST /api/collections/:col/records` | create | 201 record |
| `PATCH /api/collections/:col/records/:id` | partial update | 200 / 404 |
| `DELETE /api/collections/:col/records/:id` | delete | 204 / 404 |

The handler resolves `:col` via the collections engine (404 if no such collection), then
delegates to the record engine. Reads acquire a reader connection (`pool.openReader()`, closed
after); writes acquire the writer.

### Status mapping additions
`setZapStatus` already covers 200/201/204/400/404/409/422/500 — no change needed.

---

## 7. Module / File Plan

New: `src/values.zig`, `src/records.zig`, `src/api/records.zig`, and the query package
`src/query/filter.zig` (lexer+parser+compiler — kept in one focused file unless it grows),
`src/query/sort.zig`, `src/query/list.zig` (assembles FROM/JOIN/WHERE/ORDER/LIMIT + COUNT), and
`src/query/expand.zig`.
Modified: `src/server.zig` (record routes), `src/main.zig` (test aggregator), possibly small
additions to `src/db.zig` (a `bindDouble`/`bindNull` if missing) and `src/schema.zig` (a helper
to find a field by name).

Each unit keeps one responsibility: `values` = conversion, `records` = row orchestration,
`query/*` = read-path SQL building, `api/records` = HTTP shape.

---

## 8. Concurrency, Security, Errors

- **Reads** use `pool.openReader()` (WAL allows concurrent readers); **writes** serialize on the
  writer mutex. The record engine takes a `*db.Db` so it's agnostic.
- **Security:** every value bound (filter literals included); identifiers only from validated
  schema. The filter compiler validates each path segment against the schema before emitting
  SQL; unknown → 400, never raw passthrough.
- **Errors:** field-level validation envelope for bad input; 404 for missing collection/record;
  400 `validation_filter`/`validation_sort` for malformed query params; 500 fallback unchanged.

---

## 9. Testing Strategy

TDD throughout; `zig build test` green at each step.
- **values:** round-trips for every type; fixed-point edge cases (sign, zero, padding,
  over-precision error, large `i64` near overflow); int string round-trip.
- **records (temp DB):** create→row exists & returns stored values; get; partial update merges;
  delete; required/type/select/relation validation failures.
- **filter compiler:** representative expressions → expected SQL + params; precedence/grouping;
  `~`→LIKE param wrapping; relation-path join generation + de-dup; injection-attempt literal is
  bound (not interpolated); unknown path → error.
- **list:** pagination math (totalPages), sort direction, COUNT matches WHERE.
- **expand:** single + nested + cycle guard.
- **handlers (temp App):** each endpoint status + JSON for success and error paths.
- **manual smoke:** create a collection with a `fixed(2)` money field + a relation; create
  records; list with a filter on a relation path; expand; confirm precise money round-trip.

---

## 10. Risks & Notes

- **Filter parser correctness** is the main risk — recursive descent with operator precedence
  and relation-join resolution. Mitigated by a thorough compilation test table.
- **Reader connections** are opened per read request (no reader pool yet) — acceptable; a pooled
  reader is a later optimization.
- **N+1 expand** — acceptable at current scale; batching deferred.
- **Multi-relation cascade on delete** is deferred; a deleted record's id may linger in other
  records' multi-relation arrays until that work lands.
- The filter language deliberately omits PocketBase's `@request.*`/`@collection.*` macros (those
  belong to access rules, SP4).
