# Native server-side cursor pagination — implementation plan

Companion to `2026-06-16-native-cursor-pagination-design.md`. Ordered, independently-testable
steps suitable for subagent-driven execution. Each step is TDD: write the failing test(s) named
below first, then implement until green. Run `zig build test` after each step.

**Branch from origin/main.** All paths are repo-relative.

**Build/test:** plain `zig` on PATH is 0.15.2 and will NOT build this repo. Use
`mise exec zig@0.16.0 -- zig build` and `mise exec zig@0.16.0 -- zig build test --summary all`.

---

## ADDENDUM — user-approved additions (2026-06-16)

The base design (`...-design.md`) recommends **Approach A only** (stateless unsigned). The user
approved THREE additions on top of that, which this plan now incorporates. The implementation
must satisfy all of them; the design's §11 "out of scope" for B/C is **superseded by this
addendum** (B and C are now in scope, behind a comptime selector, with A still the default).

### Addition 1 — comptime-selectable token format (all three of A/B/C)

A new comptime `.pagination` block on `App(cfg)` selects the token codec:

```zig
.pagination = .{
    .offset = true,                 // enable offset pagination (page/perPage) — default true
    .cursor = true,                 // enable cursor pagination                — default true
    .cursor_token = .stateless,     // .stateless | .signed | .stateful        — default .stateless
},
```

- **`.stateless`** (default) — design Approach A: base64url JSON payload `{v,d,k,s,fh}`,
  validated structurally + against the request's effective sort & filter hash. No secret.
- **`.signed`** — design Approach B: the same Approach-A payload with an appended HMAC-SHA256 tag
  over the payload bytes, keyed by the **server's existing JWT secret** (`app.jwt_secret`, the
  same secret `src/jwt.zig` uses). Token shape: `base64url(payload) ++ "." ++ base64url(mac)`.
  A bad/absent MAC → `error.BadCursorSig` → 400 "Invalid cursor signature.". Verification uses a
  constant-time compare (`std.crypto.utils.timingSafeEql`).
- **`.stateful`** — design Approach C: the token is a random opaque id; the server stores the
  Approach-A payload in a new `_cursorStates` table keyed by that id, with a unix-seconds
  `expires` TTL. On use, look up by id (unexpired) → reconstruct the payload; unknown/expired →
  `error.BadCursorState` → **410 Gone** (distinct from 400 to signal "expired, re-fetch"). A
  periodic GC sweeps expired rows. This mode is **stateful** (DB writes per minted cursor) and
  is NOT byte-compatible with the SDK's client-synthesized cursors (documented tradeoff).

All three share the SAME internal `Cursor` payload + the SAME keyset SQL; only the
encode/decode wrapper differs. The selector lives behind a `comptime token_format` so the stock
binary (no `.pagination`) gets `.stateless` with zero overhead.

### Addition 2 — comptime enable/disable of each pagination mode

`.offset` and `.cursor` booleans, **both default true**.

- `offset == false` → a request carrying `page` or `perPage` is rejected **400** ("Offset
  pagination is disabled; use `cursor`."). Only cursor paging is allowed.
- `cursor == false` → a request carrying `cursor` is rejected **400** ("Cursor pagination is
  disabled."). Only offset paging is allowed.
- **Both false** → `@compileError` at `App(cfg)` instantiation (the stricter choice; documented).
  Rationale: a list endpoint with no pagination mode is always a misconfiguration; failing at
  comptime is safer than silently serving an unbounded/unwindowed list.
- **Stock binary** (no `.pagination` block) → both enabled, `cursor_token = .stateless`.

### Threading the comptime config to the runtime handler

Handlers read runtime state off `app.*` (see `src/app.zig`), not the comptime `cfg`. So the
resolved pagination knobs are threaded onto the `App` runtime struct in `framework.serveImpl`
(exactly like `static_source`/`jwt_secret`):

- `App(cfg)` exposes `pub const pagination: PaginationConfig` (resolved at comptime, with the
  compile-error guard for both-false).
- `serveImpl` copies `.offset_enabled` / `.cursor_enabled` / `.cursor_token` onto `app`.
- `src/app.zig` gains `pagination: PaginationRuntime = .{}` (defaults: both enabled, stateless),
  so tests/CLI that build an `App` literal get stock defaults.
- The `.stateful` codec also needs the DB writer + `app.io` (for the random id) + `app.jwt_secret`
  is needed by `.signed`; both are already on `app`.

`PaginationConfig` (comptime) + `PaginationRuntime` (runtime mirror) + the `CursorToken` enum
live in a small shared module (e.g. `src/pagination.zig`) imported by both `framework.zig` and
`app.zig`, and re-exported from `root.zig` so consumers can name the enum if they wish.

### How the addendum reshapes the steps below

- **Step 3** grows from "one codec" to "three codecs behind `CursorToken`": a stateless codec
  (A), a signed wrapper (B) over it, and a stateful store (C). Each gets its own round-trip +
  rejection tests (tamper for signed; unknown/expired for stateful).
- **Step 4/5** gain the enable/disable gating (400s) and pass the selected token format +
  (for stateful) the writer/io into the mint/decode calls.
- A **new migration** `0006_cursor_states` adds `_cursorStates` (for the stateful mode) and a
  GC sweep (Step 4a) consistent with `_oauthStates`/`_consumedTokens`.

---

## Step 0 — Recon checkpoint (no code)

Confirm the integration points haven't drifted from the design's `file:line` references:

- `src/records.zig:1027` `list` (compose WHERE/ORDER BY/joins, COUNT, LIMIT/OFFSET).
- `src/records.zig:1054` default ORDER BY (`created DESC`); `:1062` `where_clause` composition;
  `:1071` the 500 clamp; `:1087` `bindParams`.
- `src/query/sort.zig:8` `compile` (sort spec → ORDER BY fragment; resolves columns via joiner).
- `src/query/joiner.zig:24` `resolve` → `ColumnRef{ sql, field }`.
- `src/query/compiler.zig:10` `Param` union; `src/values.zig:77` `bindValue`; `:50`
  `scaledIntToDecimal`.
- `src/api/records.zig:333` `list` handler; `:345` query parse; `:367` response build; `:378`
  `parseU32`.

Output: a short note confirming or correcting these anchors. No commit.

---

## Step 1 — Sort introspection: expose the resolved sort terms

**Why:** keyset generation needs, per sort term, the **resolved column SQL**, its **direction**,
and its **`schema.Field`** (for value binding). Today `sort.compile` only returns the joined
ORDER BY *string* (`src/query/sort.zig:8`) and discards the per-term metadata.

**Change:** `src/query/sort.zig`

- Add `pub const SortTerm = struct { col_sql: []const u8, field: ?schema.Field, desc: bool };`
- Add `pub fn compileTerms(alloc, j, spec) SortError![]SortTerm` that resolves each term via
  `j.resolve(path)` (reusing the existing parse of `+`/`-` prefixes) and returns the structured
  terms. Refactor `compile` to build its string from `compileTerms` (so behavior is identical and
  the existing tests at `src/query/sort.zig:28`/`:47` still pass).

**Tests (sort.zig):**
- `compileTerms` returns the right `(col_sql, desc, field?)` for `"-created,price"` (system col
  `created` → `field == null`; `price` → its fixed field).
- existing string-output tests unchanged.

**Independently testable:** yes (pure, against an in-memory DB like the existing sort tests).

---

## Step 2 — Keyset predicate generator (new module)

**New file:** `src/query/keyset.zig`

**API:**

```zig
pub const KeysetError = error{ BadCursor } || values.ValueError || db.DbError || std.mem.Allocator.Error;

/// Build the keyset WHERE fragment + ordered params for a boundary.
/// `terms` is the EFFECTIVE sort (caller has already appended the id tiebreaker).
/// `values_json` are the boundary values (one per term), already decoded from the token.
/// `forward` selects the travel direction.
pub const Keyset = struct { where_sql: []const u8, params: []const compiler.Param };
pub fn build(alloc, terms: []const sort.SortTerm, values_json: []const std.json.Value, forward: bool) KeysetError!Keyset;
```

- Emits the OR-of-AND ladder from the design §4, per-term operator from
  `(term.desc, forward)`, NULL-aware equality/comparison rungs from the design §4 NULL rules.
- Binds each value as a `compiler.Param` via a `bindCursorValue(field: ?Field, json)` shim that
  delegates to `values.bindValue` when `field != null`, else binds text (system columns). Because
  `values.bindValue` writes to a `db.Stmt`, factor the JSON→`Param` mapping into a small pure
  helper (`jsonToParam(field, json) !compiler.Param`) reused by both `keyset` and tests — or, if
  simpler, have keyset emit `Param`s directly mirroring `compiler.literalToParam`
  (`src/query/compiler.zig:135`) plus the fixed/int scaling from `values.decimalToScaledInt`.
  **Prefer reusing `values`/`compiler` helpers over duplicating scale logic.**
- `where_sql` is wrapped in one set of parens, ready to AND onto the existing clause.

**Tests (keyset.zig):** the full table from design §10 (single ASC/DESC, mixed, NULL-first,
NULL-last, forward/backward operator flip, fixed/float/text coercion into the right `Param`
variant, injection-safety: metacharacter value stays in params).

**Independently testable:** yes (pure given `SortTerm`s; build `SortTerm`s via Step 1 against an
in-memory collection).

---

## Step 3 — Cursor token codec (in `src/query/keyset.zig` or `src/query/cursor.zig`)

**API:**

```zig
pub const Cursor = struct {
    forward: bool,
    keys: []std.json.Value,
    sort_str: []const u8,     // effective sort, for validation
    filter_hash: u64,         // fnv64 of normalized filter+rule
};
pub const max_cursor_len = 2048;
pub fn encode(alloc, c: Cursor) ![]u8;                 // -> base64url token
pub fn decode(alloc, token: []const u8) error{BadCursor}!Cursor;  // validates v, arity-agnostic
```

- `encode`: serialize `{v,d,k,s,fh}` (JSON is fine; it's opaque) then base64url.
- `decode`: enforce `token.len <= max_cursor_len` **first**; base64url-decode; JSON-parse;
  require `v == 1`; map every structural failure to `error.BadCursor`.
- `filter_hash`: `std.hash.Fnv1a_64` over the *normalized* (trimmed) `filter` string AND the rule
  expression string, in a fixed order. Provide `pub fn filterHash(filter: ?[]const u8, rule:
  ?[]const u8) u64`.

**Tests:** round-trip; oversized → `BadCursor` before decode; bad base64 → `BadCursor`; unknown
`v` → `BadCursor`; `filterHash` stable & order-independent of irrelevant whitespace.

**Independently testable:** yes (pure).

---

## Step 4 — `records.list` cursor mode

**Change:** `src/records.zig`

- Extend `ListQuery` (`src/records.zig:1007`): add `cursor: ?[]const u8 = null`,
  `skipTotal: bool = false`. Keep `page`/`perPage` for offset mode.
- Extend `ListResult` (`src/records.zig:1015`): add `mode: enum { offset, cursor }`,
  `next_cursor: ?[]const u8`, `prev_cursor: ?[]const u8`, `has_next: bool`, `has_prev: bool`,
  and make `totalItems` optional-by-convention (use `total_items: ?i64`; offset mode always sets
  it, cursor mode sets it only when `!skipTotal`). Keep `items`.
- In `list`:
  1. Build `where_sql` + `params` (filter + rule) **exactly as today** (`:1033`–`:1053`).
  2. Compute **effective sort terms** via `sort.compileTerms`, then append the `id` tiebreaker
     term (direction per design §4). Build the ORDER BY string from these terms (replaces the
     ad-hoc default at `:1054`).
  3. **If `q.cursor == null` → offset mode:** unchanged COUNT + LIMIT/OFFSET path, but populate
     the new `ListResult` fields as `mode=.offset`, cursors `null`, `has_*` derived from
     page math (so the handler can still answer offset clients identically).
  4. **If `q.cursor != null` → cursor mode:**
     - `decode` the token (`error.BadCursor` → propagate; handler maps to 400). Validate
       `cursor.sort_str == effective_sort_string` and
       `cursor.filter_hash == cursor.filterHash(filter, rule)`; mismatch → `error.BadCursor`
       (handler maps to a specific 400 message — see Step 5).
     - For backward (`!cursor.forward`): reverse the effective terms' directions for the SQL
       ORDER BY (re-reverse rows after fetch).
     - `keyset.build(effective_terms, cursor.keys, forward)` → AND its `where_sql` onto the
       composed clause; concatenate its `params` after the existing `params`.
     - Fetch `LIMIT (per + 1)` (no OFFSET). Determine `has_more` from the extra row; drop it.
     - For a backward page, reverse `items` into forward order.
     - Mint `next_cursor`/`prev_cursor` from first/last kept rows via `cursor.encode` (helper
       `mintCursor(row, terms, forward, sort_str, filter_hash)` reading the row's sort-key
       values out of the already-built `std.json.Value` object — they're in `items`).
     - `has_next`/`has_prev` per design §5/§6.
     - `COUNT(*)` only when `!q.skipTotal`.
- Keep the 500 clamp (`:1071`) for `per` in both modes.

**Tests (records.zig):** design §10 "records.list cursor path" bullets — forward window +
`has_next`/`next_cursor`; backward re-reversal; deleted-boundary; rule still AND-ed; `skipTotal`
default vs opt-in. Seed like `src/records.zig:1100`.

**Independently testable:** yes (direct `records.list` calls, no HTTP).

---

## Step 5 — Handler wiring + response shape

**Change:** `src/api/records.zig` `list` (`:333`)

- Parse new params from `qp`: `cursor` (`qp.get("cursor")`), `limit` (alias of `perPage`,
  `limit` wins in cursor mode), `skipTotal` (`qp.get("skipTotal")` parsed as bool; **default
  true in cursor mode, false in offset mode**). Add a `parseBool` helper next to `parseU32`
  (`:378`).
- Pass `cursor`/`skipTotal` into `records.list`.
- Map `error.BadCursor` to a **400** with a clear message; if the implementation distinguishes
  sort- vs filter-mismatch vs malformed (recommended: a small error set
  `error{BadCursor, CursorSortMismatch, CursorFilterMismatch}`), map each to its message
  ("Invalid cursor." / "Cursor does not match the requested sort." / "Cursor does not match the
  requested filter."). Fold these into the existing `catch |e| switch` at `src/api/records.zig:356`.
- Build the response:
  - **offset mode:** unchanged `{page,perPage,totalItems,totalPages,items}` (`:367`).
  - **cursor mode:** `{items, page:0, perPage, nextCursor, prevCursor, hasNext, hasPrev}` plus
    `totalItems`/`totalPages` **only when** `total_items != null`. Null cursors serialize as JSON
    `null`.
- `expand` block (`:362`) is unchanged and runs in both modes.

**Tests (api/records.zig):** extend the handler tests (style of `:457` `"list handler returns
the page envelope"`):
- cursor mode forward returns `hasNext`/`nextCursor` and **omits** `totalItems` by default.
- `skipTotal=false` includes `totalItems`.
- garbage `cursor` → 400; `cursor`+different `sort` → 400 (mismatch message).
- offset mode response byte-shape unchanged (regression guard).

---

## Step 6 — Integration tests against `zigbase serve`

**Change:** the existing integration/HTTP test harness (locate the real-server suite;
e.g. a `tests/` or `*_integration` target). Implement design §10 integration bullets:

- forward walk to exhaustion (no dup/skip, `hasNext=false` last page);
- insert between fetches → no drift;
- forward then `prevCursor` back → identical membership/order;
- `cursor`+changed sort/filter → 400; garbage cursor → 400;
- `expand` in cursor mode;
- list rule hides rows for a restricted auth;
- `skipTotal=false` returns totals.

**Run the browser/integration CI job locally** (per repo memory: parallel workstreams pass unit
tests but break the pytest/Playwright `browser` job) before declaring done.

---

## Step 7 — Docs + examples sync (REQUIRED)

Per repo policy ("keep published docs and examples in sync" — every PR):

- Update the records list API reference: new `cursor`/`limit`/`skipTotal` params, the cursor-mode
  response fields, and the offset-vs-cursor either/or. Find the published mirror under `site/`
  and the `docs/*.md` records/REST pages; update both.
- Update READMEs / examples that demonstrate listing if they should showcase cursor pagination.
- Note the SDK feature-detection contract (design §7) wherever SDK↔server compatibility is
  documented, so the SP1 SDK's migration path is discoverable.
- Do **not** edit historic plan/spec docs (only current published docs + examples).

---

## Framework / query-compiler changes required (summary)

- **`src/query/sort.zig`** — new `SortTerm` + `compileTerms` (Step 1). The single most important
  enabling change: the keyset generator needs structured sort terms, which the compiler doesn't
  currently surface.
- **`src/query/keyset.zig`** (new) — predicate generator + token codec (Steps 2–3); reuses
  `joiner.ColumnRef`, `compiler.Param`, `values.bindValue`/`decimalToScaledInt`.
- **`src/records.zig`** — `ListQuery`/`ListResult` extensions + cursor branch in `list` (Step 4).
- **`src/api/records.zig`** — param parsing, error mapping, response shape (Step 5).
- No DB-layer (`src/db.zig`) changes: existing `bind*`/`step`/`column*` are sufficient.

## Suggested execution order for subagents

Steps 1→2→3 are independent enough to parallelize after Step 1 lands (2 and 3 both depend on
Step 1 only for `SortTerm`; 3 is fully independent). Step 4 depends on 1–3; Step 5 on 4; Steps
6–7 last. Recommend: **Step 1 solo**, then **2 & 3 in parallel**, then **4 → 5 → 6 → 7** serial.
```
