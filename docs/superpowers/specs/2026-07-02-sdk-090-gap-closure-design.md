# ZigBase TS SDK — SP2: 0.9.0 Gap Closure (`@zigbase/client` 0.3.0 + codegen + server 0.10.0 wire fixes)

**Status:** Draft design (2026-07-02, rev 2 — pre-1.0 breaking-changes policy applied)
**Policy:** ZigBase is pre-1.0 and deliberately aggressive about breaking changes — where a wire format or API is wrong we fix it now, with a `### Breaking` changelog entry and a minor bump (server → **0.10.0**), rather than contorting the client around it. Rev 2 replaces rev 1's client-side compat heuristics with two server-side wire fixes (§9, §10.0).
**Tier scope:** All three tiers — base `@zigbase/client`, the comptime-generated `zbase.gen.ts`, and the runtime `zigbase typegen` tier. Both generated tiers flow through the ONE emitter (`src/codegen/gen_client.zig` + `emit.zig`), so every emitter change in this spec benefits both automatically (verified: `typegen_cli.provisionAndGenerate` and the HTTP/data-dir adapters converge on `[]schema.Collection`, and `fieldsFromJson`/`optionsFromJson` already round-trip `searchable` and `tenant`).
**Predecessors:** SP1 base client · SP2.1/2.2 typed core + comptime codegen · SP3a/b runtime typegen (see `docs/superpowers/specs/2026-06-16-zigbase-ts-sdk-base-design.md`, `2026-06-18-zigbase-ts-sdk-sp3-runtime-introspection-design.md`).
**Server floor:** most features below exist as of server **0.9.0**; the two wire-format fixes (senders `{items}`, unified `__features` signal) exist only as of **0.10.0**. See §3 for the per-feature matrix.

---

## 1. Goal

Server 0.9.0 shipped six feature areas the TS SDK cannot express: full-text/vector search, native `in` filters, multi-tenancy (account scoping), per-record abilities, analytics read APIs, and verified sender identities — plus realtime custom-topic frames the client silently drops. Close all of them in `@zigbase/client` **0.3.0**, extend the Zig code generator so both generated tiers surface the new schema metadata (`searchable`, `tenant`) and endpoints, and fix two server wire formats (senders list envelope, `__features` signal frame) in **0.10.0** so the client API can be clean instead of special-cased.

## 2. Non-goals

- **No playground / demo app.** Examples land in docs only.
- **No new server endpoints.** Every gap is closed against endpoints that already exist at commit `e71eac5`. Server-side **wire-format changes** are, however, in scope where they yield the better API (pre-1.0 policy) — two are made: the senders list envelope (§9) and the `__features` signal frame (§10.0). Both are `### Breaking` entries in server 0.10.0.
- **No realtime tenant scoping.** Browser WebSockets cannot carry `X-Account-Id`; delivery authorization stays whatever the server's connection-level resolution does. Documented limitation.
- **No membership/invitation sugar.** `_memberships` etc. are ordinary collections; the existing collection/typed-service surface already covers them. An `accounts` service with more verbs can come later without breaking this design.
- **No client-side re-implementation of server validation** (vector dims, FTS syntax, ability rules). The server is the authority; the client maps its 400s.

## 3. Compatibility & versioning

**Package versions.** `@zigbase/client` `0.2.0 → 0.3.0` (additive minor). `TYPED_CORE_VERSION` `"0.1.0" → "0.2.0"`. `@zigbase/typegen` (npm launcher) needs no code change — it shells into the server binary; its next publish just tracks the server release.

**Client ↔ server matrix.** Client 0.3.0's new surfaces have **two server floors**, stated per feature in doc-comments:

| client 0.3.0 feature | server < 0.9.0 | 0.9.0 | ≥ 0.10.0 |
|---|---|---|---|
| existing (0.2.x) API surface | works | works | works |
| search/vector, `withAccount`/activate, abilities, analytics, typed sort, `subscribeTopic` (signals + `message` broadcasts) | 404 / 400, loudly | works | works |
| native `in` where-DSL | 400 parse error | works | works |
| `senders.*` (`{items}` envelope) | 404 | **shape mismatch** (bare array) — do not use | works |
| `subscribeTopic("__features")` feature-change signals | nothing delivered | nothing delivered (old `features.changed` frame is dropped) | works |
| client 0.2.x against ≥ 0.9.0 / 0.10.0 | — | works | works (it never consumed the two changed wire shapes) |

The **behavior change against old servers** is the where-DSL `in` operator switching to native emission (§5): a `{ in: [...] }` where-clause sent to a pre-0.9.0 server now 400s instead of working via the `||` desugar. No gating, no server-version sniff (would add a request to every client start); the typed tier has always tracked the current server release. Per the pre-1.0 policy the client also ships **no shims for the pre-0.10.0 wire shapes** — it speaks only the fixed formats; the two affected surfaces simply require 0.10.0.

**Generated-code ↔ core coupling.** Generated files from the 0.9.0 codegen reference new typed-core exports and new optional `CollectionMeta` keys; against `@zigbase/client` 0.2.0 they fail typecheck with opaque excess-property errors. Make the failure self-explaining: the typed core exports a marker type per compatibility level —

```ts
// src/typed/index.ts
export type CoreSupports_0_3 = true;
```

— and the generator emits, right under the header:

```ts
// requires @zigbase/client >= 0.3.0
type _RequiresCore = import("@zigbase/client/typed").CoreSupports_0_3;
```

On 0.2.0 the error literally names `CoreSupports_0_3`. **Old generated files on the new core keep working** (every core change is additive; new `CollectionMeta` keys are optional).

**schema-hash.** The generated header's `schema-hash` (FNV-1a in `gen_client.schemaHash`) exists for drift detection (`typegen --check`). Fold the new schema inputs into it — per field a `"?"` marker when `searchable`, and per collection the tenant field name — so toggling `searchable` or `tenant` flags regeneration. Every hash changes once; goldens are regenerated in the same PR (expected — the emitter output changes anyway).

**Release coupling.** The Zig emitter changes AND the two wire fixes ship together in server **0.10.0** (breaking → minor bump). `@zigbase/client` 0.3.0 publishes **with** the 0.10.0 release, not before — rev 1's "client first" ordering no longer holds because `senders.*` and the `__features` signal would be typed lies against a 0.9.0-only fleet. Release notes state both couplings: files generated by the 0.10.0 binary need client ≥ 0.3.0 (enforced by the `CoreSupports_0_3` marker), and client 0.3.0's senders/feature-signal surfaces need server ≥ 0.10.0.

## 4. Search & vector

### 4.1 Base tier

`ListOpts` (src/records.ts) gains one field; `CollectionService.getList`/`getPage`/`iterate`/`getFullList` forward it:

```ts
export interface ListOpts {
  /* existing: filter, sort, expand, fields, skipTotal, signal, requestKey */
  /** Full-text search terms (FTS5 / Postgres FTS). Requires ZigBase >= 0.9.0. */
  search?: string;
}
```

Wire: `?search=<terms>` (the server also accepts alias `q`; the SDK always sends `search`). Search composes (AND) with `filter` and works in both offset and cursor mode (the term is folded into the cursor hash server-side); relevance ranking applies in offset mode — documented, not enforced.

Vector is **offset-only** (`error.VectorCursorUnsupported`) so it goes on `getList` only, as a structured option plus an exported builder mirroring the `filter` tag:

```ts
// src/query.ts
export interface VectorQuery { field: string; metric?: "cosine" | "l2"; values: number[] }
/** Serialize to the `<field>[:metric]:<json-embedding>` wire spec. Throws on non-finite values. */
export function vectorSpec(q: VectorQuery): string;

// src/records.ts — getList only (server rejects vector + cursor)
export interface ListOpts { vector?: VectorQuery; ... }
```

`vectorSpec` validates `values` are finite numbers (same posture as `filterValue`) and JSON-encodes them; `field` is passed through verbatim (the server gates identifiers). Rationale for structured-over-string: the spec's `field:metric:[...]` mini-grammar is exactly the kind of string a client library exists to build.

**Error surfacing:** no client pre-flight. `-Dvector` builds are unknowable client-side; the server's clean 400s (`Vector search is not enabled in this build.`, `This collection has no searchable fields…`, dimension-mismatch, pgvector-missing hint) already arrive as `ZigbaseError{status: 400}` through the existing transport path. The SDK docs list the messages; the client adds nothing.

### 4.2 Typed tier (generated)

`CollectionMeta` gains `searchable?: string[]` (§11). The **generated concrete service interfaces** include `search?: string` in the `getList`/`getFirstListItem`/`getPage`/`iterate`/`getFullList` opts objects **only when the collection has ≥ 1 searchable field** — a collection with none simply lacks the key, so `zb.db.tags.getList({ search: "x" })` is a compile error (mirroring the server's 400). `vector` appears in `getList` opts **only when the collection has ≥ 1 `json` field**, with the field name narrowed:

```ts
// emitted only for searchable collections
search?: string;
// emitted only when json fields exist (union of json field names)
vector?: { field: "embedding" | "metadata"; metric?: "cosine" | "l2"; values: number[] };
```

`RawTypedService`'s loose option types (`TypedListOptions`) gain `search?: string` and `vector?: VectorQuery`; `makeRecordService` forwards them (compiling `vector` via `vectorSpec`). The runtime does **not** gate on `meta.searchable` — the generated types are the gate; the raw service stays permissive like `where` today.

## 5. Native `in` + typed sort

### 5.1 Native `in`

Server 0.9.0's filter grammar accepts `field in ('a', 'b', 3)` and `in ()` (constant-false). `compileIn` (src/typed/where.ts) switches from the `||`-chain desugar to native emission:

```ts
export function compileIn(field: string, values: unknown[]): string {
  return `${field} in (${values.map(quoteFilterValue).join(", ")})`;
}
```

Empty list emits `field in ()` — the parser compiles it to constant-false, replacing the `1 = 2` sentinel. Quoting is unchanged and injection-safe: each element goes through `quoteFilterValue` (single-quoted, backslash-escaped — the same string-literal form the lexer unescapes). The fluent builder's `FieldExpr.in()` already delegates to `compileIn`, so it switches for free. The public signature, `OP_MAP`, and all `*Ops.in?: T[]` operator types are untouched. (Compat consequence: §3.)

### 5.2 Typed sort

Today every generated `sort` is `sort?: string`. The typed core gains one type + the service gains array normalization:

```ts
// src/typed/index.ts
export type SortExpr<F extends string> = F | `-${F}`;

// TypedListOptions / TypedPageOptions (runtime, loose)
sort?: string | string[];   // widened; joined with "," before hitting SP1
```

The generator emits a per-collection sortable-field union and a sort alias, and narrows every `sort` in the concrete interfaces:

```ts
export type ProfileSortField = "email" | "username" | "verified" | "name" | "bio"
  | "website" | "age" | "gender" | "id" | "created" | "updated";
export type ProfileSort = SortExpr<ProfileSortField>;
// in every opts object that had `sort?: string`:
sort?: ProfileSort | ProfileSort[];
```

**Sortable set:** every field that appears in the `*Fields` fluent accessors (id/created/updated + visible scalars) **minus** `json` fields, multi-value fields, and `file` fields — matching what the server can meaningfully ORDER BY and what cursor mode accepts. Chosen form: the `-` prefix union (not `{field, dir}`) — it is the wire syntax, needs zero runtime mapping beyond `join(",")`, and reads like PocketBase; the array form covers multi-key sorts. This narrows the type in **newly generated files only** (regeneration is the ship vehicle; a typo'd sort becoming a compile error is the feature). The base tier's `ListOpts.sort` stays `string`.

## 6. Tenancy: accounts, `withAccount`, tenant metadata

### 6.1 Base client

Two additions to `src/client.ts` (+ a new `src/accounts.ts`):

```ts
export interface ClientOptions {
  /** Send `X-Account-Id: <id>` on every request (multi-tenant scoping). */
  accountId?: string;
}

export interface AccountScope { account: string; role: string }

export interface AccountsService {
  /** POST /api/accounts/:id/activate — verifies ACTIVE membership, sets the signed
   *  zb_account cookie (browser apps), returns the scope. 403 when not a member. */
  activate(accountId: string, opts?: { signal?: AbortSignal; requestKey?: string }): Promise<AccountScope>;
}

export interface Client {
  readonly accounts: AccountsService;          // lazy getter, like `files`
  /** A view of this client whose every request carries `X-Account-Id: <id>`.
   *  Shares the AuthStore (login/logout propagate both ways). */
  withAccount(accountId: string): Client;
}
```

**Mechanism.** `TransportConfig` gains `accountId?: string`; `Transport.buildRequestInit` sets `X-Account-Id` (server: `src/api/records.zig requestedAccount` — header wins over cookie) unless the caller's per-request `headers` already set it. `withAccount(id)` calls `createClient`-internals to build a sibling client: **same `AuthStore`, same fetch/WS impls, a new `Transport` with `accountId` baked in**. Sharing the AuthStore is the key decision — a login on either view updates both, which matches the server model (one principal, many account scopes). The header is safe to send unauthenticated or wrong: the server grants scope only via a verified ACTIVE membership (fail closed), so the client does no validation.

**Cookie path.** `activate()` sets `zb_account` for same-origin browser apps (default `credentials: "same-origin"` keeps it). API/SSR clients should prefer `withAccount`/`accountId` — the docs say so explicitly. The SDK never reads the cookie.

### 6.2 Generated tier

Collection-level `tenant: { field }` metadata (already in `GET /api/collections` options and `schema.CollectionOptions.tenant_field`) flows into codegen:

- `CollectionMeta` gains `tenant?: string` (the tenant field name, §11).
- **Generated `*Create`/`*Update` payload types omit the tenant field entirely.** The server stamps it on create ("a client can never set/spoof `tenant_field`", records.zig:315) and rejects cross-tenant moves on update — so offering the key would only invite dead writes. It stays in the record interface (readable) and the `*Where`/`*Fields`/sort types (filterable), with a doc comment: `/** Tenant-owned: \`account\` is server-stamped from the active account. */` on the record interface.
- The generated `ZbClient` gains `withAccount(accountId: string): ZbClient` — it rebuilds the thin typed facade over `base.withAccount(id)` (all facades are stateless wrappers; cost is negligible). This gives `zb.withAccount(acct).db.notes.create(...)` end-to-end.
- The generated client also exposes `accounts: AccountsService` (pass-through re-export of `base.accounts`).

## 7. Abilities

Base `CollectionService` gains:

```ts
export interface RecordAbilities { view: boolean; update: boolean; delete: boolean }

/** GET /api/collections/:col/records/:id/abilities — the actions the current principal
 *  may perform on this record. 404 (ZigbaseError) when the record is not viewable —
 *  the endpoint never reveals existence. `view` is always true on a 200. */
getAbilities(id: string, opts?: { signal?: AbortSignal; requestKey?: string }): Promise<RecordAbilities>;
```

(Verified shape against `src/api/records.zig abilities()`.) `RawTypedService` and `emitService` add the same method to every generated concrete interface — abilities apply to all collections (rules/tenancy answer even without `.abilities` config), so it is emitted unconditionally; `makeRecordService` delegates to `inner.getAbilities`.

**Abilities metadata → doc comments only.** When a collection's options carry `abilities`, the emitter prefixes the service interface with `/** Row abilities configured for: update, delete. Check per record via getAbilities(). */` (action names only — the rule ASTs are server business). No runtime `CollectionMeta` entry: nothing in the client executes ability rules, so shipping them would be dead weight. Close call vs. emitting nothing; the one-line comment is free and makes the generated file self-documenting.

## 8. Analytics

New `src/analytics.ts`, exposed as a lazy `client.analytics` getter (same pattern as `files`):

```ts
export interface AnalyticsEvent {
  id: string; created: string; name: string;
  payload: unknown;                       // JSON value; null when unparseable/empty
  actor_collection: string; actor: string; account: string;
  occurred_at: string;
}
export interface RollupBucket {
  bucket: string; account: string; actor: string;
  value: number; computed_at: string;
}

export interface AnalyticsService {
  /** GET /api/analytics/events — tenant-scoped activity feed (401 anonymous;
   *  empty items with no active account; superuser sees all). */
  events(opts?: { name?: string; actor?: string; since?: string | Date; limit?: number;
                  signal?: AbortSignal; requestKey?: string }): Promise<{ items: AnalyticsEvent[] }>;
  /** GET /api/analytics/rollups/:name — 404 undeclared name, 403 non-account-grouped
   *  rollup for non-superusers. */
  rollup(name: string, opts?: { from?: string | Date; to?: string | Date;
                                signal?: AbortSignal; requestKey?: string }): Promise<{ items: RollupBucket[] }>;
}
```

Field names stay snake_case as the wire sends them (verified in `src/analytics/api.zig`) — the SDK does not rename server fields anywhere else and won't start here. `Date` params serialize via `toISOString()` (matching `filterValue`); `name` in `rollup()` is `encodeURIComponent`-ed into the path. The `{ items }` envelope is preserved (room for future paging keys). No codegen involvement — rollup names are runtime config, not schema; consumers pass strings.

## 9. Senders

New `src/senders.ts`, lazy `client.senders` getter:

```ts
export interface SenderIdentity { id: string; email: string; status: string; verified_at: string }

export interface SendersService {
  /** GET /api/senders — the active account's sender identities. Requires ZigBase >= 0.10.0. */
  list(opts?: { signal?: AbortSignal; requestKey?: string }): Promise<{ items: SenderIdentity[] }>;
  /** POST /api/senders — request verification; the token is EMAILED, never returned.
   *  201 pending / 200 already-verified; 429 ZigbaseError when throttled. */
  create(email: string, opts?: { signal?: AbortSignal; requestKey?: string }):
    Promise<{ id: string; email: string; status: string }>;
  /** POST /api/senders/:id/verify — 404 for wrong token/account/id (deliberate non-oracle). */
  verify(id: string, token: string, opts?: { signal?: AbortSignal; requestKey?: string }):
    Promise<{ verified: boolean }>;
}
```

**Server wire fix (0.10.0, Breaking).** As of 0.9.0, `GET /api/senders` returns a **bare JSON array** while analytics returns `{ items }` — exactly the wire inconsistency the pre-1.0 policy exists to kill. Change `src/api/senders.zig list()` to wrap in `{"items": […]}` (one `ObjectMap` around the existing array; matches analytics and leaves room for paging keys). In-repo consumers to update: senders.zig's own unit tests — the admin UI and Python suites don't call `/api/senders` (verified) — plus the documented shape in `docs/api.md:865` and `docs/framework.md:634` (and both site mirrors). The SDK types only the fixed shape (§3: `senders.*` floor is 0.10.0). All three verbs inherit account scoping from §6 (`withAccount` / cookie / superuser header), since the endpoints resolve scope identically to the record API.

## 10. Realtime custom topics

### 10.0 Server side: the envelope already exists; unify the one stray frame (0.10.0)

**Audit correction.** Rev 1 (following the audit) treated broadcasts as verbatim, envelope-less frames. In fact the only consumer-reachable broadcast API, `ctx.realtime().broadcast(topic, payload)` (src/ctx.zig:1064), **already wraps every payload** in `{"type":"message","topic":"<topic>","data":<payload>}` — shipped in 0.9.0 and documented in `docs/framework.md:834`. The verbatim contract lives only on the low-level `realtime_ws.broadcastTopic(topic, bytes)`, whose sole caller is ctx.zig itself and which is **not** re-exported through `src/root.zig` — no consumer can publish an unenveloped frame. So no new envelope is invented and `"message"` stays the frame type (renaming it to `"broadcast"` would be a gratuitous break with zero API gain).

Two server changes, both in 0.10.0:

1. **Make the envelope structural (internal refactor, not breaking).** Move the envelope construction from ctx.zig into `realtime_ws.broadcastTopic(topic, data_json: []const u8)`: it splices the pre-serialized payload bytes into `{"type":"message","topic":<json-escaped>,"data":<bytes>}` and publishes that. `ctx.realtime().broadcast` shrinks to `Stringify(payload)` + the call (dropping today's stringify→parse→rebuild round-trip). **Non-JSON payloads are impossible by construction**: the public API takes `anytype` and serializes via `std.json.Stringify`, so an unserializable value fails with an error at the `broadcast()` call site (the "reject at the call site" behavior — already the status quo, now guaranteed by the narrower `broadcastTopic` signature). The ws.zig doc comments dropping the "VERBATIM" language, and the `broadcastTopic` test at ws.zig:623, update accordingly.
2. **Unify `features.changed` (Breaking).** `broadcastFeaturesChanged` (ws.zig:544) currently publishes the bespoke, topic-less `{"type":"features.changed"}` on `__features`. Replace it with the standard signal frame — i.e. make it exactly `signalTopic(FEATURES_CHANNEL)` → `{"type":"signal","topic":"__features"}`. One frame grammar for all topic pushes; the client special-case disappears. Consumers to update (verified — the admin SPA does **not** consume it): `docs/framework.md` §"Realtime signal (`__features`)" + `site/src/content/docs/framework.md` (the `m.type === "features.changed"` JS examples), and the Playwright test `tests/admin/test_realtime.py` (asserts `features.changed` in the raw frames). Historic changelog entries mentioning the old frame are left untouched (changelog is never edited).

### 10.1 Client frame handling (src/realtime.ts)

`onMessage` currently switches on `connect|auth|ack|event|error` and drops everything else. New routing — two rules, no heuristics:

1. Existing five frame types: unchanged (record subscriptions untouched).
2. `type === "signal"` or `type === "message"` → deliver to the subscribers of `frame.topic` (`kind: "signal"` with no data, or `kind: "message"` with `data: frame.data`).

Anything else (unknown type, missing topic, non-JSON) is dropped, as today — after 0.10.0 no reachable server path produces such frames on a subscribed channel. Rev 1's fan-out heuristic, payload-`"topic"` convention, and raw-string delivery are all deleted; this is precisely what the server-side envelope buys.

### 10.2 Public API

```ts
export interface TopicMessage {
  topic: string;
  /** "signal" = re-fetch hint (no payload); "message" = payload-carrying broadcast. */
  kind: "signal" | "message";
  /** The envelope's `data` value; absent for signals. */
  data?: unknown;
}

// RealtimeService + RealtimeClient (realtime-entry.ts)
subscribeTopic(topic: string, cb: (msg: TopicMessage) => void): Promise<() => void>;
unsubscribeTopic(topic: string, cb?: (msg: TopicMessage) => void): void;
```

`kind` values mirror the wire `type` verbatim. Feature-change notifications are now just `subscribeTopic("__features", cb)` receiving a standard signal — no dedicated API. Implementation reuses the existing subscription machinery — same `{action:"subscribe",topic}` wire frame, same ack/pending/resubscribe/backoff paths — via a `kind: "records" | "topic"` discriminant on the internal `Subscription` (topic and collection names are disjoint server-side: `canSubscribeTopic` only runs when the name is not a collection). Topic subs take no `filter`. A rejected subscribe (non-`canSubscribe` topic → server `error` frame) rejects the `subscribeTopic` promise through the existing `onErrorFrame` path. `close()`/reconnect behavior is inherited. Feature-flag sugar (`zb.flags.onChanged`) stays **deferred** — one line of `subscribeTopic` keeps 0.3.0's codegen scope bounded.

## 11. Codegen & metadata design (Zig side)

**`CollectionMeta` (src/typed/meta.ts)** — two optional keys; absent means "feature not present", so every existing meta literal remains valid:

```ts
export interface CollectionMeta {
  name: string;
  fields: Record<string, FieldMeta>;
  fileFields: string[];
  expandable: string[];
  isAuth: boolean;
  /** Field names with full-text search enabled (server >= 0.9.0). */
  searchable?: string[];
  /** Tenant-owning field name; the server stamps it on create. */
  tenant?: string;
}
```

**Emitter changes (all in `src/codegen/emit.zig` + `gen_client.zig`, shared by both tiers):**

- `emitMeta`: emit `searchable: ["bio", …],` when any field has `f.searchable`; emit `tenant: "account",` when `c.options.tenant_field` is set.
- `emitService`: add `search?: string;` to the five list-ish opts blocks when the collection is searchable; add the narrowed `vector?: {…}` to `getList` when json fields exist; add `getAbilities(...)` unconditionally; replace `sort?: string;` with `sort?: {N}Sort | {N}Sort[];`; prepend the abilities doc comment when `c.options.abilities != null`.
- New `emitSortUnion` (per collection, in the "Fluent accessor types" section): `export type {N}SortField = …; export type {N}Sort = SortExpr<{N}SortField>;`.
- `emitCreate`/`emitUpdate`: skip the field named by `tenant_field`.
- `emitImports`: import `SortExpr` (type) and emit the `_RequiresCore` guard line (§3).
- `gen_client.schemaHash`: fold in `f.searchable` (`"?"`) and `c.options.tenant_field`.
- Generated `createClient`: wire `accounts`, `withAccount` (§6.2). Also expose `analytics: base.analytics` and `senders: base.senders` as pass-throughs on `ZbClient` — one line each; consumers shouldn't need to drop down a tier for them.

**Both tiers verified:** the runtime tier's acquisition path (`acquire_datadir`, `acquire_http.parseCollections`) already parses `searchable` (schema.zig:1054) and `tenant.field` (schema.zig:427) into the same `schema.Collection` structs, and `GET /api/collections` emits both (`fieldToValue` line 834, `optionsToJson` line 352). The existing equivalence test (`typegen_cli.zig`, "data-dir runtime path reproduces the comptime collection surface") is extended with a searchable + tenant collection so comptime/runtime output stays byte-identical.

## 12. Testing strategy

**Fixture:** extend `fixtures/dating/schema.zig` — mark `profiles.bio` and `messages.body` `searchable`, enable `.tenancy` and add ONE new tenant-owned collection (`notes`, `tenant_field: "account"`) plus one `analytics` rollup and one `.abilities` rule. Tenancy only affects tenant-owned collections (scopePredicate is null without `tenant_field`), so every existing dating integration test is unaffected. Goldens (`zbase.gen.ts`, `zbase.runtime.gen.ts`) regenerate in the same PR (`zig build` gen step + `--check` keeps them honest in CI).

Per area, mirroring the existing three layers:

| Area | Zig unit (emit.zig/gen_client.zig tests) | TS unit (vitest, mock fetch / FakeWebSocket) | Type-level (`test/codegen/dating/*.test-d.ts`) | Integration (harness, live server — runs in the ts-sdk CI e2e job) |
|---|---|---|---|---|
| search/vector | emitMeta searchable, emitService gating | `vectorSpec` serialization + finite-check; ListOpts pass-through query params | `search` rejected on non-searchable collection; `vector.field` narrowed | FTS hit/miss + 400-on-unsearchable via dating `messages` |
| native `in` / sort | emitSortUnion; sort in emitService | `compileIn` native emission incl. empty list + escaping (extend `query-filter.test.ts`/typed where tests) | `sort: "-age"` ok, `sort: "nope"` error; `in` operand types unchanged | where-`in` round-trip against live server (proves grammar match) |
| tenancy | tenant in emitMeta; Create omits tenant field | Transport sets `X-Account-Id`; `withAccount` shares AuthStore; header override precedence | `NoteCreate` lacks `account`; `withAccount` returns `ZbClient` | activate → 200 scope; cross-account create denied; scoped list isolation |
| abilities | getAbilities in emitService; doc comment | request shape + `RecordAbilities` parse | method present on every generated service | owner vs. stranger ability sets; 404 non-viewable |
| analytics | — | query-param mapping incl. `Date` → ISO; envelope parse | — | events feed after seeded writes; rollup 404-undeclared, 401-anon |
| senders | **server:** senders.zig list-envelope test updated to `{items}` | `{items}` `list`, 201/200 `create`, 429 mapping | — | list/create shapes; `verify` wrong-token → 404 (happy-path verify skipped: token only travels by email) |
| topics | **server:** ws.zig — `broadcastTopic` envelope splice (shape + topic escaping), `broadcastFeaturesChanged` emits the standard signal frame, inactive-reactor no-ops (extend ws.zig:623); ctx.zig — `broadcast()` error on unserializable payload | `signal`/`message` routing by topic, unknown-frame drop, record subs unaffected (extend `realtime-subscribe.test.ts`) | — | `ctx.realtime().signal`/`.broadcast` fired via a dating custom route → client receives both kinds; flag-override write → `subscribeTopic("__features")` signal |

Plus: `exports.test.ts`/`typed-exports.test.ts` updated for new exports and `TYPED_CORE_VERSION === "0.2.0"`; the Zig equivalence + golden `--check` tests as above. **The `__features` frame change touches the Playwright suite:** update `tests/admin/test_realtime.py` to assert the new `{"type":"signal","topic":"__features"}` frame and run the browser suite locally before merge (a green `zig build test` has repeatedly hidden exactly this class of regression). Note for the executor: the ts-sdk CI job has a known `ListenError` port-race flake — rerun, don't chase, if only that job fails.

## 13. Docs & release checklist

- `docs/typescript-sdk.md` **and mirror** `site/src/content/docs/typescript-sdk.md`: new sections — Search & vector; Account scoping (`withAccount`, `activate`, cookie caveat); Abilities; Analytics; Senders; Custom topics (`subscribeTopic`, signal vs. message); typed sort + native `in` note; the per-feature server-floor matrix (§3).
- `clients/typescript/README.md`: feature bullets + version bump note.
- Wire-fix doc updates: `docs/api.md:865` + `docs/framework.md:634` (senders `{items}`), `docs/framework.md` §"Realtime signal (`__features`)" JS example — **and all three site mirrors**.
- `changelog.d/sdk-090-gap-closure.md`: `### Breaking` — `GET /api/senders` now returns `{"items":[…]}`; the `__features` channel now emits the standard `{"type":"signal","topic":"__features"}` frame instead of `{"type":"features.changed"}`. `### Features` (six SDK areas + `subscribeTopic`). `### Changed` — typed-tier `in` compiles to the native operator (requires server ≥ 0.9.0); regenerated clients require `@zigbase/client` ≥ 0.3.0. The internal `broadcastTopic` refactor is invisible to consumers → no fragment line.
- `cd site && npm run build` before merge.
- Release order: server **0.10.0** (wire fixes + codegen) and `@zigbase/client` **0.3.0** ship as one release train — publish the npm package when the 0.10.0 GitHub release goes out (§3 Release coupling). The publish workflow filename must not change (npm OIDC trusted-publisher binding).

## 14. File map

**TS (clients/typescript/src/):** `records.ts` (+search/vector opts), `query.ts` (+`vectorSpec`), `collection.ts` (+forwarding, `getAbilities`), `client.ts` (+`accounts`, `withAccount`, `accountId`), `transport.ts` (+account header), new `accounts.ts`, new `analytics.ts`, new `senders.ts`, `realtime.ts` (+topic frames/API), `realtime-entry.ts` (+re-exports), `typed/meta.ts` (+2 keys), `typed/where.ts` (native `compileIn`), `typed/service.ts` (+search/vector/sort-array/getAbilities), `typed/index.ts` (+`SortExpr`, `CoreSupports_0_3`, version bump), `index.ts` (exports), `package.json` (0.3.0).
**Zig codegen (src/codegen/):** `emit.zig` (meta/service/sort/create-omit/imports/doc-comment), `gen_client.zig` (schemaHash, section wiring, generated-client accounts/withAccount/analytics/senders), tests in both.
**Zig server (0.10.0 wire fixes):** `src/realtime/ws.zig` (`broadcastTopic` envelope + `broadcastFeaturesChanged` → standard signal, comments/tests), `src/ctx.zig` (`RealtimeApi.broadcast` simplification), `src/api/senders.zig` (`{items}` envelope + test).
**Fixtures/tests/docs:** `fixtures/dating/schema.zig`, regenerated `clients/typescript/test/codegen/dating/*`, new/extended vitest + `.test-d.ts` + `test/integration/*` per §12, `tests/admin/test_realtime.py`, `docs/framework.md`/`docs/api.md` + site mirrors per §13.
