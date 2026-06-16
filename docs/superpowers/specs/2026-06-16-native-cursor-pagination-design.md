# Native server-side cursor (keyset) pagination — design

**Status:** design (no code yet)
**Date:** 2026-06-16
**Scope:** `GET /api/collections/:col/records` — add opaque server-side `cursor` (keyset)
pagination alongside the existing offset (`page`/`perPage`) pagination, with forward +
backward navigation and an optional total count.

---

## 1. Context

### Why this exists

The records list endpoint today is pure **offset pagination**. The handler
(`src/api/records.zig:333` `list`) parses `page`/`perPage`/`filter`/`sort`/`expand`, calls
`records.list` (`src/records.zig:1027`), which:

1. compiles `filter` → WHERE via the query compiler (`src/query/compiler.zig:15`),
2. AND-s the collection's list **rule** clause (`src/records.zig:1040`),
3. compiles `sort` → ORDER BY (`src/query/sort.zig:8`), defaulting to `"<col>"."created" DESC`,
4. runs `COUNT(*)` for `totalItems`, then a second query with `LIMIT ? OFFSET ?`
   (`src/records.zig:1064`, `:1075`).

Offset pagination has two structural problems this feature fixes:

- **Deep-offset cost** — `LIMIT 50 OFFSET 100000` still walks 100050 rows in SQLite.
- **Drift under writes** — an insert/delete on an earlier page shifts every later page,
  duplicating or skipping rows during infinite scroll.

We just designed the **TypeScript SDK (SP1)** whose `CursorPage` API is *client-synthesized*
over the current offset+filter wire: it base64-encodes the boundary row's sort-key values into
an opaque token, then on the next request appends a keyset predicate to the user's `filter`,
reuses `sort`, and **auto-appends `id` as a final tiebreaker** (see
`2026-06-16-zigbase-ts-sdk-base-design.md:197`). The SDK spec explicitly states the public API
is "shaped so a **future native server cursor** can replace the client synthesis without
changing the SDK surface" (`:229`).

**This feature is that native server cursor.** A client passes an opaque `cursor` (plus
`limit`/`filter`/`sort`/`expand`) and the server does the keyset work itself.

### Target API (must back the SDK's `CursorPage` unchanged)

```ts
getPage(opts: { cursor?: string; limit?: number; filter?: string; sort?: string;
                expand?: string; withTotal?: boolean }): Promise<CursorPage<T>>

interface CursorPage<T> {
  items: T[];
  nextCursor: string | null;
  prevCursor: string | null;
  hasNext: boolean;
  hasPrev: boolean;
  totalItems?: number;   // only when withTotal
}
```

---

## 2. Principles

1. **Reuse the existing compiler binding path; never interpolate cursor values into SQL.**
   The keyset predicate is generated as a parameterized WHERE fragment whose values are bound
   exactly the way filter literals are — through `values.bindValue`
   (`src/values.zig:77`) / the compiler's `Param` union (`src/query/compiler.zig:10`). This
   inherits the existing injection-safety guarantees (see the injection test at
   `src/query/compiler.zig:266`).
2. **Rules and filters always apply.** A cursor only changes the *window*; the list rule and
   user filter are still AND-ed into the same query. A cursor can never widen visibility.
3. **Backward compatible.** Absent `cursor`, the endpoint behaves exactly as today. The new
   response fields are additive.
4. **Deterministic total order or it doesn't work.** Keyset requires a strict total order, so
   the server **always appends `id` ASC/DESC as a final tiebreaker** to whatever `sort` the
   client gave — matching the SDK's documented behavior.
5. **Opaque + self-describing tokens.** The token carries enough to (a) reconstruct the keyset
   predicate and (b) detect when the request's `sort`/`filter` no longer matches the token, so a
   stale/mismatched cursor fails loudly with a 400 instead of silently returning wrong rows.
6. **Cheap by default.** Skipping `COUNT(*)` is the default for cursor requests; the total is
   computed only on explicit opt-in.

---

## 3. Cursor token format

A cursor encodes: **the boundary row's ordered sort-key values**, the **direction** of travel
(forward/backward), and a **binding** to the sort/filter it was produced under so a mismatched
reuse is rejected.

The decoded payload (before serialization/encoding):

```jsonc
{
  "v": 1,                       // token format version
  "d": "f",                     // direction: "f" = forward (after), "b" = backward (before)
  "k": ["2026-01-03T00:00:00Z", "r3"],  // boundary sort-key values, in sort order, id last
  "s": "-created,id",           // the *effective* sort (with id tiebreaker appended) — for validation
  "fh": "9c2b…"                 // fnv64 hash of the normalized filter+rule, hex — for validation
}
```

Then: `cursor = base64url( <serialization of the payload> )`.

`k` holds the values **as they appear in the JSON record** (the same canonical form the SDK
already encodes): RFC3339 strings for date/text/id, decimal **strings** for fixed/int numbers
(matching `values.scaledIntToDecimal`, `src/values.zig:50`), JSON numbers for float, booleans
for bool. These are re-bound to SQLite via `values.bindValue` using each sort term's resolved
field — so "10.50" for a fixed(2) column scales to the integer `1050` exactly as a filter
literal would (`src/values.zig:101`). For system columns `id`/`created`/`updated` (text), the
value binds as text.

### Validation on decode

- Structurally invalid base64 / malformed payload / unknown `v` → **400** (`"Invalid cursor."`).
- `len(cursor) > cursor_max_len` (e.g. 2048 bytes, before decode) → **400**, rejected *before*
  decode so a crafted oversized token can't drive allocation (mirrors the `max_filter_len` cap
  at `src/records.zig:54`).
- `k.len != number_of_effective_sort_terms` → **400** (token shape doesn't match the sort).
- `s` (effective sort in the token) **must equal** the request's effective sort string. If the
  caller changed `sort` between pages, the keyset is meaningless → **400**
  (`"Cursor does not match the requested sort."`).
- `fh` must equal the hash of the current normalized filter+rule. If the caller changed
  `filter`, the window is incoherent → **400** (`"Cursor does not match the requested filter."`).

Rejecting on mismatch (rather than silently re-deriving) is the safe choice: it prevents a
client from accidentally walking an inconsistent sequence and prevents a cursor minted under one
filter from being replayed under another.

### Three approaches considered

**A. Opaque base64 of values + embedded sort/filter binding (no signature).** *(recommended)*
The structure above. Validated **structurally** and against the request's sort/filter — not
cryptographically signed.

- Pros: zero key management; stateless; transparent to the SDK (which already builds the same
  value list and base64-encodes it — the native server just becomes the canonical encoder);
  cheap to mint/parse; the sort/filter binding gives clear 400s on misuse; values still flow
  through the parameterized compiler so a tampered token can only ever produce a *different but
  still safe* parameterized query (never injection).
- Cons: a tampered token can address a different boundary within the *same* collection+sort —
  but that's exactly equivalent to the client choosing a different legitimate cursor, and rules
  still gate every row, so there is no privilege gain. No tamper-evidence (we don't need it).

**B. HMAC-signed token (server-secret keyed).** Same payload, plus an HMAC over it; reject if the
signature doesn't verify.

- Pros: tamper-evident; cursors can't be hand-crafted.
- Cons: needs a server signing secret in config + rotation story; couples cursor minting to that
  secret (breaks the SDK's "encode it yourself" symmetry — the SDK could no longer synthesize a
  token the server would accept, which *hurts* the SP1→native migration); and it buys no real
  security because rules already constrain every returned row and values are parameterized.
  Over-engineered for the threat model.

**C. Server-side stored cursor (opaque id → server-held state).** Token is a random id; the
keyset state lives in a server table/cache.

- Pros: smallest token; total server control of validity/expiry.
- Cons: introduces statefulness (storage, GC, expiry), breaks the stateless/CDN-friendly
  property, and is wholly incompatible with the SDK's client-synthesized cursors. Rejected.

**Recommendation: Approach A.** It is stateless, requires no secrets, gives precise 400s on
misuse, and — crucially — is **byte-compatible with what the SP1 SDK already encodes**, so the
SDK migrates from "synthesize the token + the keyset filter" to "forward the same token to the
server" with no token-format change. Security is provided by *rules + parameterization*, not by
signing the cursor.

---

## 4. Keyset predicate generation

### The lexicographic comparison

Given an effective sort `t1 dir1, t2 dir2, …, id dirN` and boundary values `v1, v2, …, vN`,
"rows strictly after the boundary in sort order" is the row-value comparison expanded into the
standard OR-of-AND ladder (SQLite has no portable `(a,b) > (x,y)` tuple comparison across mixed
directions, so we expand it):

```
(t1 OP1 v1)
OR (t1 = v1 AND t2 OP2 v2)
OR (t1 = v1 AND t2 = v2 AND t3 OP3 v3)
...
OR (t1 = v1 AND ... AND t{N-1} = v{N-1} AND tN OPN vN)
```

where each `OPi` is `>` if term *i* is ASC, `<` if DESC, **for forward travel**. For backward
travel every `OPi` flips (`>`↔`<`). Equality rungs use `=` regardless of direction.

This whole fragment is wrapped in parentheses and AND-ed onto the existing `where_clause`
(filter AND rule), exactly where `records.list` already composes clauses
(`src/records.zig:1062`).

Each `ti` is the **already-resolved column SQL** for that sort term (`j.resolve(path).sql`,
`src/query/joiner.zig:24`) — the same resolution `sort.compile` performs — so relation-path
sort terms reuse the joins the joiner already registered. Each `vi` is appended as a bound
`Param` via the same field-aware path as filter literals.

### NULL handling

SQLite's `<`/`>`/`=` all yield NULL (falsey) when either side is NULL, so a naive ladder drops
rows with NULL sort values and never advances past a NULL boundary. We make NULLs explicit and
**deterministic**, matching SQLite's default `ORDER BY` NULL placement (NULLs sort **first** in
ASC, **last** in DESC):

- **Equality rung** `ti = vi` becomes NULL-aware: when `vi` is NULL, the rung is
  `ti IS NULL`; otherwise `ti = vi` (a row whose `ti` is NULL does not equal a non-NULL `vi`,
  which is already the SQL behavior, but the boundary-is-NULL case needs `IS NULL`).
- **Comparison rung** `ti OPi vi` is rewritten so NULL ordering is respected. For an **ASC**
  term (NULLs first), "strictly after `vi`" is:
  - if `vi IS NULL`: `ti IS NOT NULL`  (anything non-NULL comes after a leading NULL)
  - else: `(ti > vi OR ti IS NULL_is_impossible)` → just `ti > vi` (NULLs already passed)

  For a **DESC** term (NULLs last) it mirrors. The generator emits the correct branch per term
  from the (direction, boundary-value-is-NULL) pair. The unit tests pin every combination.

This is the subtle part; §8 (testing) enumerates the cases as the TDD spec.

### Type coercion (reuse, don't reinvent)

The boundary values arrive as JSON (from the decoded token). For each sort term we have the
resolved `schema.Field` (`ColumnRef.field`, `src/query/joiner.zig:8`). Binding goes through
`values.bindValue(alloc, &stmt, idx, field, json_value)` (`src/values.zig:77`), which already:

- scales fixed/int decimal **strings** to integers (`:101`, `:97`),
- binds floats as doubles (`:88`),
- binds text/date/id as text (`:80`),
- binds bool as 0/1 (`:84`).

For **system columns** (`id`, `created`, `updated`) there is no `schema.Field`
(`ColumnRef.field == null`); these are text columns and bind as text directly. The generator
carries a small `bindCursorValue(field: ?Field, json)` shim: `field` present → `values.bindValue`;
`field` null → `bindText`. This keeps the cursor on the exact same parameterization as filters,
so the injection-safety test class (`src/query/compiler.zig:266`) covers it by construction.

### Always-append `id` tiebreaker

After compiling the client `sort` to ORDER BY terms, the generator appends `"<col>"."id" <dir>`
where `<dir>` matches the **last** client sort term's direction (or ASC if the only sort is the
default `created DESC` → then `id DESC`, to keep the tiebreaker consistent with the primary
key's correlation to insertion order). The default-sort case (`created DESC`, the
`records.list` default at `:1054`) becomes effective sort `created DESC, id DESC`. The effective
sort string is what gets stored in the token's `s` field and re-validated.

---

## 5. API surface + response shape

### Request

`GET /api/collections/:col/records` gains:

| param      | meaning |
|------------|---------|
| `cursor`   | opaque token. When present, the endpoint runs in **cursor mode**. |
| `limit`    | page size for cursor mode (alias of `perPage`; reuses the **500 clamp** at `src/records.zig:1071`). If both `limit` and `perPage` are given in cursor mode, `limit` wins. |
| `skipTotal`| `true`/`false`. In **cursor mode the default is to skip** `COUNT(*)`. Set `skipTotal=false` (the SDK's `withTotal:true`) to include `totalItems`. |
| `filter`/`sort`/`expand` | unchanged; `sort` defines the keyset order (with `id` auto-appended). |

**Coexistence with `page`:** if `cursor` is present, the endpoint is in cursor mode and `page`
is **ignored** (an explicit `page` alongside `cursor` is allowed but has no effect — documented).
If `cursor` is absent, behavior is **identical to today** (offset mode). This is a clean
either/or so existing offset clients are untouched.

### Response (cursor mode)

```jsonc
{
  "items": [ ... ],
  "page": 0,                 // 0 sentinel = "cursor mode" (page is not meaningful)
  "perPage": 30,             // the effective limit
  "nextCursor": "…" | null,  // null when hasNext == false
  "prevCursor": "…" | null,  // null when hasPrev == false
  "hasNext": true,
  "hasPrev": false,
  "totalItems": 142,         // present only when skipTotal=false
  "totalPages": 5            // present only when skipTotal=false (derived from totalItems/limit)
}
```

The SDK's `CursorPage` reads `items/nextCursor/prevCursor/hasNext/hasPrev/totalItems?` — every
one of those is present, so the native response **drives `CursorPage` unchanged**. `page`/
`perPage` are extra fields the SDK ignores; including them keeps a single response struct shape
and lets non-SDK clients still read `perPage`.

**Offset mode response is byte-for-byte unchanged** (`{page,perPage,totalItems,totalPages,items}`,
built at `src/api/records.zig:367`). The cursor fields are only added in cursor mode.

### `hasNext` / `nextCursor` derivation (fetch N+1)

Standard keyset trick: request `limit + 1` rows. If `limit + 1` come back, `hasNext = true`,
**drop the extra row**, and mint `nextCursor` from the last *kept* row's sort-key values
(direction `f`). If `≤ limit` rows come back, `hasNext = false`, `nextCursor = null`.

`hasPrev` is `true` whenever the request itself carried a `cursor` (you came from somewhere) **or**
backward navigation is possible; for a forward page minted from a cursor, `hasPrev = true`. For
the very first page (no cursor), `hasPrev = false`, `prevCursor = null`. `prevCursor` is minted
from the **first** kept row's values with direction `b` (see §6).

---

## 6. Backward pagination

`prevCursor` lets the client walk toward the start. Implementation when a `d:"b"` cursor arrives:

1. **Reverse every comparison operator** in the keyset ladder (forward `>`/`<` flip), so the
   predicate selects rows strictly *before* the boundary.
2. **Reverse the ORDER BY** (every term's ASC↔DESC, including the `id` tiebreaker) so the DB
   returns the `limit (+1)` rows *closest to* the boundary going backward.
3. **Re-reverse the page in memory** before returning, so `items` is in the same forward order
   the client expects.

`hasPrev` for a backward page = "did we get the extra (N+1) row going backward". `nextCursor` on a
backward page is minted from the last (in forward order) kept row; `prevCursor` from the first.
The mint logic is symmetric — a single helper takes (row, direction) and produces a token.

Empty backward result (you were already at the start) → `hasPrev = false`, `prevCursor = null`.

---

## 7. Forward-compat with the SDK

The SP1 SDK ships **client-synthesized** cursors and a `CursorPage` API. Native support lets the
SDK forward a `cursor` param instead of synthesizing the keyset filter. Migration path:

- **Response shape:** already matches (§5) — no SDK type changes.
- **Token compatibility:** because the recommended token (Approach A) encodes the same ordered
  sort-key values + direction the SDK already encodes, the SDK can keep its own encoder *or*
  adopt the server's verbatim. To be safe across versions, the SDK should treat the token as
  **fully opaque** (it already does) and simply round-trip whatever the server returned.
- **Feature detection / version gate:** the server advertises native cursor support so the SDK
  knows whether to forward `cursor` (native) or fall back to client synthesis:
  - Preferred: a capability flag in a lightweight meta endpoint (e.g. `GET /api/health` or a
    `/api/meta` returning `{ "features": ["cursorPagination"] }`), checked once and cached.
  - Fallback: the SDK sends `cursor` + `skipTotal`; a server that doesn't understand `cursor`
    ignores it and returns an offset page (no `nextCursor`). The SDK detects the **absence** of
    `nextCursor`/`hasNext` in the response and transparently reverts to client synthesis for that
    connection. (Documented as the graceful-degradation path.)
- **`getFullList`/`iterate`:** the SDK's keyset iterator just forwards `nextCursor` until
  `hasNext=false`; identical control flow whether the cursor is native or synthesized.

This keeps the SDK's public surface frozen while the backend takes over the keyset work.

---

## 8. Edge cases

| case | behavior |
|------|----------|
| **Empty result** | `items: []`, `hasNext:false`, `hasPrev:false`, both cursors `null`. |
| **Last page** | fewer than `limit+1` rows → `hasNext:false`, `nextCursor:null`. |
| **Boundary row deleted** | keyset is value-based, not id-based-offset: a deleted boundary just means no row equals it; the ladder still selects the correct "strictly after" window. **No error, no skip.** This is the headline advantage over offset. |
| **Sort by a non-unique column** | the always-appended `id` tiebreaker makes the order strict, so the boundary is never ambiguous; duplicate sort values are disambiguated by `id`. |
| **Very large `limit`** | clamped to **500** via the same `@min(perPage, 500)` at `src/records.zig:1071`. `limit+1` fetch therefore caps at 501 rows. |
| **`expand`** | applied to the page rows after fetch, exactly as offset mode does (`src/api/records.zig:362`). Expansion is orthogonal to keyset. |
| **Cursor + changed `sort`** | 400 (`s` mismatch, §3). |
| **Cursor + changed `filter`** | 400 (`fh` mismatch, §3). |
| **Default sort (no `sort` given)** | effective sort `created DESC, id DESC`; token records that, so a later request that *adds* a `sort` is correctly rejected as a mismatch. |
| **Float/NULL sort values** | handled by the NULL-aware ladder (§4) and float binding; pinned by unit tests. |
| **`page` and `cursor` both present** | cursor wins; `page` ignored. |
| **Malformed/oversized cursor** | 400, rejected before/at decode (§3, §9). |

---

## 9. Security & limits

1. **Rules are never bypassed.** The list rule clause is AND-ed into the same query in cursor
   mode exactly as offset mode (`src/records.zig:1040`). A cursor only narrows the window; it
   cannot reveal a row the rule would hide. View/list rule semantics are unchanged.
2. **No injection.** Cursor values are bound parameters through `values.bindValue` /the compiler
   `Param` path — never string-interpolated into SQL. The injection test class at
   `src/query/compiler.zig:266` applies by construction. The keyset SQL *structure* is generated
   from the server-controlled sort spec, not from token content; the token only supplies *values*.
3. **Size cap before work.** `cursor` length is checked against `cursor_max_len` (≈2048 B)
   **before** base64-decode; `filter`/`sort` keep their `max_filter_len` cap
   (`src/records.zig:54`). A crafted huge cursor can't drive allocation or CPU.
4. **Structural validation rejects crafted payloads.** Wrong `v`, wrong arity (`k.len`), or a
   value that fails field coercion (`bindValue` → `error.BadValue`/`TypeMismatch`) → **400**, not
   a 500. No panic, no partial query.
5. **No DoS via deep keyset.** The ladder has exactly `N` rungs for `N` sort terms; sort is
   already capped by `max_filter_len`, bounding `N`. `limit` is clamped to 500.
6. **Stateless / no secret.** Approach A needs no signing key, so there's no key-leak or
   rotation risk; tamper-resistance is unnecessary because rules gate every row (§3, Approach A
   cons).

---

## 10. Testing strategy

### Unit tests (keyset SQL generation) — `src/query/keyset.zig` (new), pure & table-driven

These are the TDD heart of the feature. For a synthetic collection (text `created`, fixed
`price`, a `rank` int, a nullable `score` float, plus `id`):

- **single ASC term + id**: predicate is `(c > ?) OR (c = ? AND id > ?)`; params bound in order.
- **single DESC term + id**: operators flip to `<`.
- **mixed ASC/DESC** (`-created,price` → `created DESC, price ASC, id ASC`): each rung uses the
  per-term operator; equality rungs use `=`.
- **NULL boundary value, ASC** (NULLs-first): comparison rung → `ti IS NOT NULL`; equality rung
  → `ti IS NULL`.
- **NULL boundary value, DESC** (NULLs-last): the mirrored branch.
- **non-NULL boundary over a nullable column**: ordinary `>`/`<`, NULLs already ordered out.
- **forward vs backward**: backward flips every comparison op and the test asserts the reversed
  ORDER BY is emitted.
- **type coercion**: a fixed(2) sort value `"10.50"` binds as int `1050`; a float binds as
  double; id/text binds as text (assert the `Param` union variants, mirroring
  `src/query/compiler.zig:189`).
- **id always appended**, with the right direction, including the default-sort case.
- **injection**: a sort value containing SQL metacharacters appears only in `params`, never in
  the generated SQL (mirror `src/query/compiler.zig:266`).

### Unit tests (token codec) — in the same module

- encode→decode round-trips values, direction, effective sort, filter hash.
- oversized token → rejected pre-decode; malformed base64 → 400-class error; unknown `v` → error;
  arity mismatch → error; `s`/`fh` mismatch → the dedicated mismatch errors.

### Unit tests (records.list cursor path) — extend `src/records.zig` tests

- forward page over seeded rows returns the right window + correct `hasNext`/`nextCursor`
  (`limit+1` trick), reusing the seed style of the existing `"list filters, sorts, and
  paginates"` test (`src/records.zig:1100`).
- backward page returns the prior window, re-reversed into forward order.
- deleted-boundary row still paginates correctly.
- rule clause still AND-ed (extend `"list applies a rule clause"` at `src/records.zig:1157`).
- `skipTotal` default skips `COUNT(*)`; opt-in includes `totalItems`.

### Integration tests (against a real `zigbase serve`)

Add to the existing HTTP/integration suite (a real server + SQLite):

- create N records, walk forward with `cursor` to exhaustion; assert no dup/skip and
  `hasNext=false` on the last page.
- insert a row *between* page fetches; assert keyset doesn't duplicate/skip (the offset-drift
  scenario).
- forward to page 3, then `prevCursor` back to page 2; assert identical membership/order.
- `cursor` + changed `sort` → 400; `cursor` + changed `filter` → 400; garbage `cursor` → 400.
- `expand` works in cursor mode.
- list rule hides rows in cursor mode (auth as a restricted user).
- `skipTotal=false` returns `totalItems`/`totalPages`.

---

## 11. Out of scope

- **Cursor pagination for non-record endpoints** (logs, collections list, etc.). Records only.
- **Random access "page N"** in cursor mode (keyset is inherently sequential; offset mode stays
  for that).
- **HMAC/signed or server-stored cursors** (Approaches B/C) — explicitly rejected; revisit only
  if a concrete tamper-evidence requirement appears.
- **Changing the offset response shape** or removing offset pagination. Offset stays, unchanged.
- **Encrypted/compressed tokens.**
- **Cross-collection / joined cursors** beyond the single-relation sort paths the joiner already
  supports.
- **SDK code changes** (covered by the SDK spec; this spec only guarantees response compatibility
  + a feature-detection contract).
```
