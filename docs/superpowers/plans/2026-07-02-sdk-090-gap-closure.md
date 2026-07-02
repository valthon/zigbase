# @zigbase/client 0.3.0 + Server 0.10.0 Wire Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Close the six server-0.9.0 feature gaps (search/vector, native `in`, tenancy, abilities, analytics, senders) plus realtime custom topics in `@zigbase/client` 0.3.0, extend the Zig codegen emitter so both generated tiers surface the new schema metadata, and ship the two server wire-format fixes (senders `{items}` envelope, unified `__features` signal frame) for server 0.10.0.

**Architecture:** Server-side wire fixes land first (src/realtime/ws.zig envelope refactor + `__features` unification, src/api/senders.zig `{items}` envelope), then the TS base/typed-core client areas (clients/typescript/src/**), then the ONE shared emitter (src/codegen/emit.zig + gen_client.zig — both generated tiers flow through it), then the dating fixture + regenerated goldens, type-level tests, live-server integration tests, and finally docs/changelog/version bumps. The spec is `/home/valthon/.claude/jobs/85efdf24/tmp/spec-sdk-gap-closure.md`; baseline is `main` @ `e71eac5`.

**Tech Stack:** Zig 0.16 (mise-pinned), TypeScript (vitest + tsd-style `.test-d.ts` via `tsc --noEmit`), live-server integration harness (`clients/typescript/test/integration/harness.ts`), Playwright browser suite (`tests/admin/`).

## Global Constraints

- **Zig build/test:** `mise exec zig@0.16.0 -- zig build` and `mise exec zig@0.16.0 -- zig build test --summary all`. The authoritative signal is the `Build Summary: N/N tests passed` line — a spurious `failed command: …` line appears even on success. There is no per-test filter.
- **`zig build test` includes the byte-exact golden test** (`gen-test` step compares `generate()` output against `clients/typescript/test/codegen/dating/zbase.gen.ts`). Any task that changes emitter output or the dating fixture MUST regenerate goldens in the same task (`mise exec zig@0.16.0 -- zig build gen-dating-client gen-dating-runtime-client`) or `zig build test` fails. Goldens are NEVER hand-edited.
- **TS commands** (run from `clients/typescript/`): unit `mise exec node@24 -- npm test`; typecheck (also validates all `.test-d.ts` and the goldens) `mise exec node@24 -- npm run typecheck`; integration (builds server + dating-server itself via mise) `mise exec node@24 -- npm run test:integration`. Run `mise exec node@24 -- npm ci || mise exec node@24 -- npm install` once if `node_modules` is missing.
- **New `src/*.zig` files** must be added to the `test { _ = @import(...); }` block in `src/root.zig` or their tests never run (this plan adds no new Zig files — all Zig edits are to existing files already wired in).
- **Never edit `CHANGELOG.md`** or `site/src/content/docs/changelog.md`. This work adds ONE fragment `changelog.d/sdk-090-gap-closure.md` (Task 15) leading with two `### Breaking` entries per spec §13.
- **Docs mirrors:** every `docs/*.md` change must be mirrored to `site/src/content/docs/*.md`; `cd site && npm run build` must pass before the final task completes.
- **Browser suite:** the `__features` frame change must pass `mise exec python@3.13 -- python -m pytest tests/admin/test_realtime.py -q` (the conftest harness builds and launches the server itself; run from repo root). A green `zig build test` does NOT cover this.
- **Server version stays as-is in `build.zig.zon`** during this work — the 0.10.0 bump happens via `scripts/release.sh` at release time (spec §3/§13: the wire fixes + codegen ship in the 0.10.0 release train; this plan only adds the changelog fragment).
- **`@zigbase/client` `package.json` version → `0.3.0`** (Task 15); **`TYPED_CORE_VERSION` → `"0.2.0"`** in `src/typed/index.ts` (Task 4). The `VERSION` const in `src/index.ts` stays `"0.1.0"` (spec is silent; package.json is the version of record — flag to the repo owner at review).
- **No client shims for pre-0.10.0 wire shapes** (spec §3): the client speaks only `{items}` senders and `{"type":"signal","topic":"__features"}`.
- Commit after each task with the message given in the task. All paths below are relative to the repo root.

---

### Task 1: Server — realtime message envelope refactor + `__features` signal unification (0.10.0, Breaking)

**Files:**
- Modify: `src/realtime/ws.zig` (envelope construction moves here; `broadcastFeaturesChanged` → standard signal frame; doc comments; tests)
- Modify: `src/ctx.zig` (`RealtimeApi.broadcast` simplification + new test)
- Modify: `tests/admin/test_realtime.py` (assert the new frame)
- Modify: `docs/framework.md` §"Realtime signal (`__features`)" (~lines 1240–1255) and `site/src/content/docs/framework.md` (~lines 1210–1225)

**Interfaces:**
- Produces: `realtime_ws.broadcastTopic(topic: []const u8, data_json: []const u8) void` — now takes a **pre-serialized JSON payload** and wraps it in `{"type":"message","topic":…,"data":…}` itself. `broadcastFeaturesChanged()` publishes `{"type":"signal","topic":"__features"}`. Wire contract consumed by Tasks 8/14 (client topic routing + integration tests).

- [ ] Read `src/realtime/ws.zig` lines 20–35 and 530–630, and `src/ctx.zig` lines 1042–1075 to confirm the current shapes match the baseline described here.
- [ ] In `src/realtime/ws.zig`, delete the `FEATURES_CHANGED_FRAME` const (line ~33) and update the `FEATURES_CHANNEL` doc comment (lines 24–30) to:
  ```zig
  /// Fixed PUBLIC realtime channel for the feature-management "changed" signal
  /// (#128/#129/#130). It is signal-only: the STANDARD signal frame
  /// `{"type":"signal","topic":"__features"}` is published whenever any flag/experiment
  /// override changes (0.10.0 — the bespoke `{"type":"features.changed"}` frame is gone);
  /// clients re-`GET /api/state` on receipt. No per-subject state or experiment assignment
  /// is ever pushed. It is NOT a collection — the subscribe path allows anonymous
  /// subscription to it explicitly and the delivery path forwards its frames unchanged.
  pub const FEATURES_CHANNEL = "__features";
  ```
- [ ] Add two pure frame-builder helpers to `src/realtime/ws.zig` (place them just above `broadcastFeaturesChanged`):
  ```zig
  /// Build the standard signal frame `{"type":"signal","topic":"<json-escaped topic>"}`.
  fn signalFrameAlloc(a: std.mem.Allocator, topic: []const u8) ![]const u8 {
      var o: std.json.ObjectMap = .empty;
      try o.put(a, "type", .{ .string = "signal" });
      try o.put(a, "topic", .{ .string = topic });
      return std.json.Stringify.valueAlloc(a, std.json.Value{ .object = o }, .{});
  }

  /// Splice pre-serialized payload bytes into the standard message envelope:
  /// `{"type":"message","topic":"<json-escaped topic>","data":<data_json>}`.
  /// `data_json` MUST already be valid JSON (ctx.RealtimeApi.broadcast produces it via
  /// std.json.Stringify) — it is spliced verbatim, never re-parsed or re-serialized.
  fn messageEnvelopeAlloc(a: std.mem.Allocator, topic: []const u8, data_json: []const u8) ![]const u8 {
      var w: std.ArrayList(u8) = .empty;
      try w.appendSlice(a, "{\"type\":\"message\",\"topic\":");
      try w.appendSlice(a, try std.json.Stringify.valueAlloc(a, std.json.Value{ .string = topic }, .{}));
      try w.appendSlice(a, ",\"data\":");
      try w.appendSlice(a, data_json);
      try w.appendSlice(a, "}");
      return w.toOwnedSlice(a);
  }
  ```
- [ ] Replace `broadcastFeaturesChanged` (ws.zig ~544):
  ```zig
  /// Signal-only feature-management push (#128/#129/#130): publish the STANDARD signal frame
  /// `{"type":"signal","topic":"__features"}` on the public `FEATURES_CHANNEL` so subscribed
  /// clients re-`GET /api/state`. One frame grammar for every topic push (0.10.0, Breaking:
  /// replaces the bespoke `{"type":"features.changed"}` frame). Called from every override
  /// write path (`ctx.setFlag`/`App.setFlag` and the admin settings verbs). A no-op when the
  /// reactor isn't running (tests/CLI). NEVER pushes per-subject state or experiment
  /// assignments — those stay behind the authenticated `/api/state` projection.
  pub fn broadcastFeaturesChanged() void {
      signalTopic(FEATURES_CHANNEL);
  }
  ```
  (`signalTopic` already early-returns on `!active`, preserving the no-op guarantee.)
- [ ] Replace `broadcastTopic` (ws.zig ~549–560) — narrowed contract, envelope applied structurally:
  ```zig
  /// #143: consumer broadcast. Wrap `data_json` — an ALREADY-SERIALIZED JSON value — in the
  /// standard `{"type":"message","topic":…,"data":…}` envelope and publish it to every
  /// subscriber of a custom `topic`. The envelope is structural (0.10.0): no consumer-reachable
  /// path can publish an unenveloped frame, and a non-JSON payload is impossible by
  /// construction (the public `ctx.realtime().broadcast` serializes via std.json.Stringify and
  /// errors at the call site). There is NO per-record viewRule on delivery — subscription
  /// authorization is enforced once, at subscribe time, by `canSubscribeTopic`. EXPLICIT
  /// opt-in: `data_json` must be safe for every subscriber of `topic` (gate private channels
  /// with `.realtime = .{ .canSubscribe = fn }`; prefer `signalTopic` + an authenticated
  /// re-fetch for per-subject state). A no-op when the reactor isn't running (tests/CLI).
  /// `topic` is a consumer channel name, not a collection name. Callable from any thread
  /// (incl. a background job): `fio_publish` is a non-blocking enqueue that copies the frame.
  pub fn broadcastTopic(topic: []const u8, data_json: []const u8) void {
      if (!active) return; // reactor not running (tests/CLI): no-op
      var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
      defer arena.deinit();
      const frame = messageEnvelopeAlloc(arena.allocator(), topic, data_json) catch return;
      WS.publish(.{ .channel = topic, .message = frame });
  }
  ```
- [ ] Simplify `signalTopic` (ws.zig ~565) to reuse the helper (behavior unchanged):
  ```zig
  pub fn signalTopic(topic: []const u8) void {
      if (!active) return; // reactor not running (tests/CLI): no-op
      var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
      defer arena.deinit();
      const frame = signalFrameAlloc(arena.allocator(), topic) catch return;
      WS.publish(.{ .channel = topic, .message = frame });
  }
  ```
- [ ] In `src/ctx.zig` replace the body of `RealtimeApi.broadcast` (~1064–1074) — drop the stringify→parse→rebuild round-trip; the ws layer owns the envelope now. Update its doc comment's "VERBATIM" wording:
  ```zig
  /// Payload-carrying broadcast (EXPLICIT opt-in): subscribers of `topic` receive
  /// `{"type":"message","topic":"<topic>","data":<payload>}`. `payload` is any
  /// JSON-serializable value (an unserializable value errors HERE, at the call site —
  /// the envelope itself is applied structurally by the realtime layer). Only broadcast
  /// data that is safe for EVERY subscriber of `topic`; gate private channels with
  /// `.realtime = .{ .canSubscribe = fn }`, or prefer `signal` + an authenticated
  /// re-fetch for per-subject state.
  pub fn broadcast(self: RealtimeApi, topic: []const u8, payload: anytype) !void {
      const data_json = try std.json.Stringify.valueAlloc(self.ctx.arena, payload, .{});
      realtime_ws.broadcastTopic(topic, data_json);
  }
  ```
- [ ] Update the existing inactive-no-op test at ws.zig ~623 (the argument is now a payload, not a full frame) and ADD the two frame-shape tests:
  ```zig
  test "broadcastTopic/signalTopic are no-ops when inactive (#143)" {
      // Like broadcast/broadcastFeaturesChanged, the consumer publish entry points must early-return
      // when the reactor isn't running so ctx.realtime() is safe to call from tests/CLI/background jobs.
      try std.testing.expect(!active);
      broadcastTopic("orders", "{\"n\":1}"); // pre-serialized payload; enveloped internally
      signalTopic("availability"); // builds + would publish a signal frame; must early-return
  }

  test "messageEnvelopeAlloc splices the standard message envelope + JSON-escapes the topic" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      try std.testing.expectEqualStrings(
          "{\"type\":\"message\",\"topic\":\"orders\",\"data\":{\"id\":\"r1\"}}",
          try messageEnvelopeAlloc(a, "orders", "{\"id\":\"r1\"}"),
      );
      // topic escaping: a quote in the topic must not break the frame
      try std.testing.expectEqualStrings(
          "{\"type\":\"message\",\"topic\":\"a\\\"b\",\"data\":1}",
          try messageEnvelopeAlloc(a, "a\"b", "1"),
      );
  }

  test "broadcastFeaturesChanged uses the standard signal frame (0.10.0 wire fix)" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      // broadcastFeaturesChanged delegates to signalTopic(FEATURES_CHANNEL); this pins the frame.
      try std.testing.expectEqualStrings(
          "{\"type\":\"signal\",\"topic\":\"__features\"}",
          try signalFrameAlloc(a, FEATURES_CHANNEL),
      );
  }
  ```
- [ ] Add a ctx.zig test (near the other `#143`/capability tests at the file bottom, mirroring the minimal-Ctx pattern used in `src/route_types.zig` tests — `Ctx{ .app = undefined, .arena = …, .rctx = .{} }`; if that literal needs more fields to compile, mirror `CtxTestEnv` instead):
  ```zig
  test "#143 ctx.realtime(): signal + broadcast serialize and are safe no-ops when the reactor is inactive" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      var cx = Ctx{ .app = undefined, .arena = arena.allocator(), .rctx = .{} };
      cx.realtime().signal("availability");
      // Serialization happens at the call site; the publish itself is a no-op (inactive reactor).
      try cx.realtime().broadcast("orders", .{ .kind = "order.shipped", .id = "r1" });
  }
  ```
  NOTE: the spec's "error on unserializable payload" cannot be a runtime test — an unserializable `anytype` payload is a Zig *compile* error, which is exactly the "reject at the call site" guarantee; this test pins the serialize-then-publish path instead.
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect `Build Summary: … N/N tests passed` (ignore the spurious `failed command:` line). All new ws/ctx tests pass.
- [ ] Update `tests/admin/test_realtime.py` — docstring and both `features.changed` assertions become the standard signal frame:
  ```python
  def test_features_changed_signal_on_override(page):
      """The signal-only feature channel: an ANONYMOUS client may subscribe to the
      public `__features` channel, and writing a flag/experiment override broadcasts
      the standard signal frame `{"type":"signal","topic":"__features"}` on it
      (clients then re-GET /api/state)."""
  ```
  and replace BOTH `wait_for_function` calls that check `f.includes('features.changed')` with:
  ```python
      page.wait_for_function(
          "window.__featFrames && window.__featFrames.some(f => f.includes('\"type\":\"signal\"') && f.includes('\"topic\":\"__features\"'))",
          timeout=8000,
      )
  ```
- [ ] Run the browser test: from the repo root, `mise exec zig@0.16.0 -- zig build && mise exec python@3.13 -- python -m pytest tests/admin/test_realtime.py -q` — expect `2 passed`.
- [ ] Update `docs/framework.md` §"Realtime signal (`__features`)" (~1240–1255): replace `{"type":"features.changed"}` with `{"type":"signal","topic":"__features"}` in the prose and change the JS example's condition to:
  ```js
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.type === "signal" && m.topic === "__features") refetchState();
  };
  ```
  Add one sentence: `Changed in 0.10.0: this channel previously emitted a bespoke {"type":"features.changed"} frame; it now uses the same standard signal frame as every custom topic.` Apply the identical edit to `site/src/content/docs/framework.md` (~1210–1225).
- [ ] `git add -A && git commit -m "feat(realtime)!: structural message envelope + standard __features signal frame (0.10.0 wire fix)"`

---

### Task 2: Server — senders `GET /api/senders` returns `{items:[…]}` (0.10.0, Breaking)

**Files:**
- Modify: `src/api/senders.zig` (list envelope + new unit test)
- Modify: `docs/api.md` (line ~865), `docs/framework.md` (line ~634), `site/src/content/docs/api.md` (~863), `site/src/content/docs/framework.md` (senders bullet)

**Interfaces:**
- Produces: `GET /api/senders` body `{"items":[{id,email,status,verified_at},…]}` — consumed by Task 7 (`SendersService.list`) and Task 14 (integration).

- [ ] Read `src/api/senders.zig` (225 lines) and `src/mail/senders.zig`'s `Identity`/`listForAccount` (confirm the field names `id`, `email`, `status`, `verified_at`).
- [ ] In `src/api/senders.zig`, extract the body construction from `list()` into a pure, testable helper and wrap in `{items}`:
  ```zig
  /// Build the `{"items":[{id,email,status,verified_at},…]}` list envelope. 0.10.0, Breaking:
  /// was a bare JSON array in 0.9.0 — unified with the analytics endpoints' `{items}` shape
  /// (and leaves room for future paging keys).
  fn listBody(alloc: std.mem.Allocator, ids: []const senders.Identity) ![]const u8 {
      var arr = std.json.Array.init(alloc);
      for (ids) |it| {
          var o: std.json.ObjectMap = .empty;
          try o.put(alloc, "id", .{ .string = it.id });
          try o.put(alloc, "email", .{ .string = it.email });
          try o.put(alloc, "status", .{ .string = it.status });
          try o.put(alloc, "verified_at", .{ .string = it.verified_at });
          try arr.append(.{ .object = o });
      }
      var root: std.json.ObjectMap = .empty;
      try root.put(alloc, "items", .{ .array = arr });
      return std.json.Stringify.valueAlloc(alloc, std.json.Value{ .object = root }, .{});
  }
  ```
  and shrink `list()`'s tail (replacing the inline array build at lines ~88–101) to:
  ```zig
      const ids = try senders.listForAccount(ctx.allocator, &r, scope.account);
      return .{
          .status = 200,
          .content_type = "application/json",
          .body = try listBody(ctx.allocator, ids),
      };
  ```
  Also update the module doc comment at the top of the file (line 4): `GET /api/senders — list the active account's sender identities → {"items":[…]}.`
- [ ] Add the envelope unit test (below the existing `verify requires authentication` test):
  ```zig
  test "list envelope: {items:[...]} wraps the identities (0.10.0 wire shape)" {
      var arena = std.heap.ArenaAllocator.init(testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const ids = [_]senders.Identity{
          .{ .id = "s1", .email = "a@x.io", .status = "verified", .verified_at = "2026-01-01 00:00:00" },
      };
      try testing.expectEqualStrings(
          "{\"items\":[{\"id\":\"s1\",\"email\":\"a@x.io\",\"status\":\"verified\",\"verified_at\":\"2026-01-01 00:00:00\"}]}",
          try listBody(a, &ids),
      );
      // Empty account -> empty items array, still enveloped.
      try testing.expectEqualStrings("{\"items\":[]}", try listBody(a, &.{}));
  }
  ```
  If `senders.Identity` has extra fields or different defaults, adapt the literal (Read `src/mail/senders.zig` first); the assertion strings are the contract.
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect all tests pass (`Build Summary:` line).
- [ ] Docs: in `docs/api.md` line ~865 change the GET row to:
  `| GET | \`/api/senders\` | List the active account's identities: \`{ "items": [{ id, email, status, verified_at }, …] }\` (changed in 0.10.0 — was a bare array). |`
  In `docs/framework.md` line ~634 change the bullet to: `- \`GET /api/senders\` — list the active account's identities: \`{ "items": [ … ] }\`.` Apply the same two edits to `site/src/content/docs/api.md` and `site/src/content/docs/framework.md`.
- [ ] `git add -A && git commit -m "feat(senders)!: GET /api/senders returns {items:[...]} envelope (0.10.0 wire fix)"`

---

### Task 3: TS base — full-text `search` + structured `vector` (`vectorSpec`)

**Files:**
- Modify: `clients/typescript/src/query.ts` (+`VectorQuery`, `vectorSpec`), `src/records.ts` (`ListOpts`), `src/collection.ts` (forwarding), `src/typed/service.ts` (loose option pass-through), `src/index.ts` (exports)
- Test: `clients/typescript/test/vector.test.ts` (new), extend `test/records.test.ts`, `test/exports.test.ts`

**Interfaces:**
- Produces: `export interface VectorQuery { field: string; metric?: "cosine" | "l2"; values: number[] }` and `export function vectorSpec(q: VectorQuery): string` in `src/query.ts`; `ListOpts.search?: string` + `ListOpts.vector?: VectorQuery`; `TypedListOptions.search?/vector?`, `TypedPageOptions.search?`. Consumed by Task 9 (generated interfaces) and Task 13 (integration).

- [ ] Read `clients/typescript/src/query.ts`, `src/records.ts`, `src/collection.ts`, `src/typed/service.ts` in the current tree.
- [ ] Write the failing tests first — `clients/typescript/test/vector.test.ts`:
  ```ts
  import { describe, it, expect, vi } from "vitest";
  import { vectorSpec } from "../src/query.js";
  import { createClient } from "../src/index.js";

  function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  }

  describe("vectorSpec", () => {
    it("serializes to <field>[:metric]:<json-embedding>", () => {
      expect(vectorSpec({ field: "embedding", values: [0.12, 0.04] })).toBe("embedding:[0.12,0.04]");
      expect(vectorSpec({ field: "embedding", metric: "cosine", values: [1, 2] })).toBe(
        "embedding:cosine:[1,2]",
      );
      expect(vectorSpec({ field: "embedding", metric: "l2", values: [0.5] })).toBe("embedding:l2:[0.5]");
    });

    it("throws on non-finite values (same posture as filterValue)", () => {
      expect(() => vectorSpec({ field: "e", values: [Number.NaN] })).toThrow(/non-finite/);
      expect(() => vectorSpec({ field: "e", values: [Infinity] })).toThrow(/non-finite/);
    });
  });

  describe("search/vector list options", () => {
    it("getList forwards ?search= and compiled ?vector=", async () => {
      const fetchMock = vi.fn(async (url: string) => {
        const u = new URL(url);
        expect(u.searchParams.get("search")).toBe("zig database");
        expect(u.searchParams.get("vector")).toBe("embedding:cosine:[0.1,0.2]");
        return jsonResponse({ page: 1, perPage: 30, totalItems: 0, totalPages: 0, items: [] });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      await zb.collection("docs").getList(1, 30, {
        search: "zig database",
        vector: { field: "embedding", metric: "cosine", values: [0.1, 0.2] },
      });
      expect(fetchMock).toHaveBeenCalledTimes(1);
    });

    it("getPage forwards ?search= (cursor mode supports search, not vector)", async () => {
      const fetchMock = vi.fn(async (url: string) => {
        const u = new URL(url);
        expect(u.searchParams.get("search")).toBe("hello");
        expect(u.searchParams.get("vector")).toBeNull();
        return jsonResponse({ items: [], nextCursor: null, prevCursor: null, hasNext: false, hasPrev: false });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      await zb.collection("docs").getPage({ search: "hello", limit: 5 });
    });
  });
  ```
- [ ] Run `cd clients/typescript && mise exec node@24 -- npm test` — expect the new file FAILS (vectorSpec not exported).
- [ ] Implement `src/query.ts` (append after `quoteFilterValue`):
  ```ts
  /** A structured nearest-neighbor query for `getList` (server `-Dvector` builds only). */
  export interface VectorQuery {
    /** The json field holding the stored embeddings. Passed through verbatim (the server gates identifiers). */
    field: string;
    /** Distance metric; the server defaults to cosine when omitted. */
    metric?: "cosine" | "l2";
    /** The query embedding. Every element must be a finite number. */
    values: number[];
  }

  /**
   * Serialize a {@link VectorQuery} to the `<field>[:metric]:<json-embedding>` wire spec of
   * `GET /api/collections/:col/records?vector=…`. Requires ZigBase >= 0.9.0 built with
   * `-Dvector=true` (a default build answers 400 "Vector search is not enabled in this build.").
   * Vector search is offset-only — the server rejects it in cursor mode. Throws on non-finite
   * values (same posture as `filterValue`).
   */
  export function vectorSpec(q: VectorQuery): string {
    for (const v of q.values) {
      if (typeof v !== "number" || !Number.isFinite(v)) {
        throw new Error(`vectorSpec: non-finite embedding value: ${v}`);
      }
    }
    const metric = q.metric ? `:${q.metric}` : "";
    return `${q.field}${metric}:${JSON.stringify(q.values)}`;
  }
  ```
- [ ] Implement `src/records.ts`: add `import type { VectorQuery } from "./query.js";` at the top and extend `ListOpts`:
  ```ts
  /** Options accepted by list reads. */
  export interface ListOpts {
    filter?: string;
    sort?: string;
    expand?: string;
    fields?: string;
    skipTotal?: boolean;
    /** Full-text search terms (FTS5 / Postgres FTS); AND-composes with `filter`. Requires ZigBase >= 0.9.0. */
    search?: string;
    /** Nearest-neighbor search (server `-Dvector` builds only; offset mode only — the server
     *  rejects vector + cursor). Requires ZigBase >= 0.9.0. */
    vector?: VectorQuery;
    signal?: AbortSignal;
    /** Opt-in de-duplication key; a new request aborts any in-flight one with the same key. */
    requestKey?: string;
  }
  ```
- [ ] Implement `src/collection.ts`: add `import { vectorSpec } from "./query.js";` and forward — in `getList`'s `query` object add:
  ```ts
          search: opts.search,
          vector: opts.vector ? vectorSpec(opts.vector) : undefined,
  ```
  Add `search?: string;` to the inline opts of `getPage`, `iterate`, and `getFullList`, and forward it: `getPage` adds `search: opts.search` to its `query`; `iterate` passes `search: opts.search` into both `getPage` calls; `getFullList` passes it into `iterate` via its existing opts spread-through (it forwards each named opt — add `search: opts.search` alongside `filter`). `getFirstListItem` needs no change (it spreads `opts` into `getList`).
- [ ] Implement `src/typed/service.ts` pass-through (loose tier — the generated types are the gate, per spec §4.2): add `import type { VectorQuery } from "../query.js";`; add to `TypedListOptions`: `search?: string;` and `vector?: VectorQuery;`; add to `TypedPageOptions`: `search?: string;`. In `makeRecordService`: `listOpts` gains `search: opts?.search, vector: opts?.vector,` (the base `getList` compiles it via `vectorSpec`); `getPage` forwards `search: opts?.search`; `iterate` and `getFullList` forward `search: opts?.search`; `getFirstListItem`'s `listOpts2` gains `search: opts?.search,`.
- [ ] `src/index.ts`: change the query export line to `export { filter, filterValue, quoteFilterValue, vectorSpec, parseSort, compareBySort } from "./query.js";` and add `export type { SortTerm, VectorQuery } from "./query.js";` (replacing the existing `SortTerm` type export line).
- [ ] Extend `test/exports.test.ts` with `expect(typeof zb.vectorSpec).toBe("function");` inside the query-helpers test.
- [ ] Run `mise exec node@24 -- npm test` and `mise exec node@24 -- npm run typecheck` — expect PASS.
- [ ] `git add -A && git commit -m "feat(sdk): full-text search opt + structured vector queries (vectorSpec)"`

---

### Task 4: TS typed — native `in`, `SortExpr`, typed-core 0.2.0 markers

**Files:**
- Modify: `clients/typescript/src/typed/where.ts` (`compileIn`), `src/typed/index.ts` (`SortExpr`, `CoreSupports_0_3`, `TYPED_CORE_VERSION`), `src/typed/meta.ts` (`CollectionMeta.searchable?/tenant?`), `src/typed/service.ts` (sort widening + join)
- Test: `clients/typescript/test/typed/where.test.ts`, `test/typed/fluent.test.ts`, `test/typed/service.test.ts`, `test/typed-exports.test.ts`

**Interfaces:**
- Produces: `compileIn(field, values)` emits `field in ('a', 'b')` / `field in ()`; `export type SortExpr<F extends string> = F | \`-${F}\``; `export type CoreSupports_0_3 = true`; `TYPED_CORE_VERSION === "0.2.0"`; `CollectionMeta.searchable?: string[]` + `tenant?: string`; `TypedListOptions.sort?/TypedPageOptions.sort?: string | string[]` (joined with `,`). Consumed by Task 9 goldens.

- [ ] Read `clients/typescript/src/typed/where.ts`, `src/typed/index.ts`, `src/typed/meta.ts`, `src/typed/service.ts`, and the current expectations in `test/typed/where.test.ts` (~line 67–75) and `test/typed/fluent.test.ts` (grep for `in(`).
- [ ] Update the `in` expectations FIRST (TDD) in `test/typed/where.test.ts`:
  ```ts
    it("`in` compiles to the native operator; empty `in` is constant-false `in ()`", () => {
      expect(compile({ status: { in: ["a", "b"] } })).toBe("status in ('a', 'b')");
      expect(compile({ tags: { in: ["t1", "t2"] } })).toBe("tags in ('t1', 't2')");
      expect(compile({ price: { in: [1, 2, 3] } })).toBe("price in (1, 2, 3)");
      expect(compile({ status: { in: [] } })).toBe("status in ()");
      // injection-safe: elements go through quoteFilterValue
      expect(compile({ status: { in: ["a'b"] } })).toBe("status in ('a\\'b')");
    });
  ```
  Update any `fluent.test.ts` assertion expecting the `||`-chain form (`f.<field>.in([...])` compiles through the same `compileIn`) to the native form the same way. Run `mise exec node@24 -- npm test` — expect FAIL.
- [ ] Implement `src/typed/where.ts` — replace `compileIn` (public signature unchanged):
  ```ts
  /** Compile a native `in` clause: `field in ('a', 'b', 3)`. An empty list emits `field in ()`
   *  — the server parser compiles it to constant-false. Requires ZigBase >= 0.9.0 (the native
   *  `in` filter operator); each element is quoted via `quoteFilterValue` (injection-safe:
   *  single-quoted + backslash-escaped, the same string-literal form the server lexer unescapes). */
  export function compileIn(field: string, values: unknown[]): string {
    return `${field} in (${values.map(quoteFilterValue).join(", ")})`;
  }
  ```
  Also update the `compileWhere` doc-comment bullet: `` - `in`: `{ status: { in: ['a','b'] } }` -> `status in ('a', 'b')` (native operator; server >= 0.9.0) ``.
- [ ] Implement `src/typed/index.ts` — change the version const and add the two new exports right below it:
  ```ts
  export const TYPED_CORE_VERSION = "0.2.0";

  /** A sortable-field expression: the field name for ascending, `-field` for descending. */
  export type SortExpr<F extends string> = F | `-${F}`;

  /** Compatibility marker: present iff this typed core supports files generated by
   *  ZigBase >= 0.10.0 (requires `@zigbase/client` >= 0.3.0). Generated clients reference
   *  it so an old core fails typecheck with an error that names this type. */
  export type CoreSupports_0_3 = true;
  ```
- [ ] Implement `src/typed/meta.ts` — extend `CollectionMeta`:
  ```ts
  export interface CollectionMeta {
    name: string;
    fields: Record<string, FieldMeta>;
    fileFields: string[];
    expandable: string[];
    isAuth: boolean;
    /** Field names with full-text search enabled (server >= 0.9.0). Absent = no FTS. */
    searchable?: string[];
    /** Tenant-owning field name; the server stamps it on create. Absent = not tenant-owned. */
    tenant?: string;
  }
  ```
- [ ] Implement `src/typed/service.ts` sort widening: change `sort?: string;` to `sort?: string | string[];` in BOTH `TypedListOptions` and `TypedPageOptions` (comment: `/** Sort expression(s); an array is joined with "," (multi-key sort). */`). Add one helper above `makeRecordService`:
  ```ts
  const sortJoin = (s: string | string[] | undefined): string | undefined =>
    Array.isArray(s) ? (s.length > 0 ? s.join(",") : undefined) : s;
  ```
  and replace every `sort: opts?.sort` forward inside `makeRecordService` (in `listOpts`, `getFirstListItem`'s `listOpts2`, `getPage`, `iterate`, `getFullList`) with `sort: sortJoin(opts?.sort)`.
- [ ] Tests: in `test/typed/service.test.ts` add (mirroring that file's existing mock conventions — read it first):
  ```ts
  it("joins an array sort with commas before hitting SP1", async () => {
    // arrange a makeRecordService over a mock client capturing the inner getList sort opt,
    // call svc.getList({ sort: ["-age", "created"] }),
    // assert the captured sort === "-age,created"
  });
  ```
  (Write it concretely against the file's existing mock-client fixture.) In `test/typed-exports.test.ts` change `expect(typed.TYPED_CORE_VERSION).toBe("0.1.0")` to `"0.2.0"`.
- [ ] Run `mise exec node@24 -- npm test && mise exec node@24 -- npm run typecheck` — expect PASS. NOTE: the committed goldens/fixtures (`test/codegen/dating/*`, `test/fixtures/blog.gen.ts`) still typecheck — every change here is additive.
- [ ] `git add -A && git commit -m "feat(typed): native in operator, SortExpr, typed-core 0.2.0 markers (CoreSupports_0_3, CollectionMeta searchable/tenant)"`

---

### Task 5: TS base — tenancy: `accountId`, `withAccount`, `accounts.activate`

**Files:**
- Create: `clients/typescript/src/accounts.ts`
- Modify: `src/transport.ts`, `src/client.ts`, `src/index.ts`
- Test: `clients/typescript/test/accounts.test.ts` (new)

**Interfaces:**
- Produces: `ClientOptions.accountId?: string`; `Client.withAccount(accountId: string): Client`; `Client.accounts: AccountsService` with `activate(accountId, opts?): Promise<AccountScope>`; `AccountScope { account: string; role: string }`; `TransportConfig.accountId?: string` (sets `X-Account-Id` unless per-request headers already set it). Consumed by Tasks 7, 10, 13.

- [ ] Read `clients/typescript/src/transport.ts` and `src/client.ts` current state.
- [ ] Write failing tests — `clients/typescript/test/accounts.test.ts`:
  ```ts
  import { describe, it, expect, vi } from "vitest";
  import { createClient } from "../src/index.js";

  function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  }

  describe("account scoping", () => {
    it("accountId option sends X-Account-Id on every request", async () => {
      const fetchMock = vi.fn(async (_url: string, init?: RequestInit) => {
        expect(new Headers(init?.headers).get("X-Account-Id")).toBe("acct1");
        return jsonResponse({ items: [], page: 1, perPage: 30, totalItems: 0, totalPages: 0 });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock, accountId: "acct1" });
      await zb.collection("notes").getList();
      expect(fetchMock).toHaveBeenCalledTimes(1);
    });

    it("per-request headers win over the baked-in accountId", async () => {
      const fetchMock = vi.fn(async (_url: string, init?: RequestInit) => {
        expect(new Headers(init?.headers).get("X-Account-Id")).toBe("override");
        return jsonResponse({ ok: true });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock, accountId: "acct1" });
      await zb.send("GET", "/api/health", { headers: { "X-Account-Id": "override" } });
    });

    it("withAccount builds a sibling client sharing the AuthStore", async () => {
      const seen: Array<string | null> = [];
      const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
        seen.push(new Headers(init?.headers).get("X-Account-Id"));
        if (String(url).includes("auth-with-password")) {
          return jsonResponse({ token: "tok1", record: { id: "u1" } });
        }
        return jsonResponse({ ok: true });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      const scoped = zb.withAccount("acct9");
      // login through the SCOPED view updates the shared store...
      await scoped.collection("users").authWithPassword("a@b.c", "pw");
      expect(zb.authStore.token).toBe("tok1"); // ...visible on the original
      await zb.send("GET", "/x");
      await scoped.send("GET", "/x");
      expect(seen).toContain("acct9");
      // the unscoped view sent NO account header
      expect(seen.filter((h) => h === null).length).toBeGreaterThan(0);
    });

    it("accounts.activate POSTs /api/accounts/:id/activate and returns the scope", async () => {
      const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
        expect(url).toBe("http://api.test/api/accounts/a%2F1/activate");
        expect(init?.method).toBe("POST");
        return jsonResponse({ account: "a/1", role: "editor" });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      const scope = await zb.accounts.activate("a/1");
      expect(scope).toEqual({ account: "a/1", role: "editor" });
    });
  });
  ```
  Run `mise exec node@24 -- npm test` — expect FAIL.
- [ ] Implement `src/transport.ts`: add `accountId?: string;` to `TransportConfig` (doc: `/** Send X-Account-Id on every request (multi-tenant scoping); per-request headers win. */`). In `buildRequestInit`, after the `Accept-Language` line add:
  ```ts
      if (this.cfg.accountId && !headers.has("X-Account-Id")) {
        headers.set("X-Account-Id", this.cfg.accountId);
      }
  ```
- [ ] Create `src/accounts.ts`:
  ```ts
  import type { Transport } from "./transport.js";

  /** The active account scope returned by `POST /api/accounts/:id/activate`. */
  export interface AccountScope {
    account: string;
    role: string;
  }

  /** Multi-tenancy account operations (requires ZigBase >= 0.9.0 with `.tenancy` enabled). */
  export class AccountsService {
    constructor(private readonly transport: Transport) {}

    /**
     * POST /api/accounts/:id/activate — verifies an ACTIVE membership, sets the signed
     * `zb_account` cookie (same-origin browser apps; the default `credentials: "same-origin"`
     * keeps it), and returns the scope. 403 when not a member; 404 when tenancy is disabled.
     * API/SSR clients should prefer `client.withAccount(id)` / the `accountId` option —
     * the SDK never reads the cookie.
     */
    activate(
      accountId: string,
      opts: { signal?: AbortSignal; requestKey?: string } = {},
    ): Promise<AccountScope> {
      return this.transport.send<AccountScope>(
        `/api/accounts/${encodeURIComponent(accountId)}/activate`,
        { method: "POST", signal: opts.signal, requestKey: opts.requestKey },
      );
    }
  }
  ```
- [ ] Implement `src/client.ts`:
  - Add `import { AccountsService } from "./accounts.js";`
  - `ClientOptions` gains: `/** Send \`X-Account-Id: <id>\` on every request (multi-tenant scoping; server >= 0.9.0). The server grants scope only via a verified ACTIVE membership — fail closed — so no client-side validation. */ accountId?: string;`
  - `Client` interface gains:
    ```ts
    readonly accounts: AccountsService;
    /** A view of this client whose every request carries `X-Account-Id: <id>`. Shares the
     *  AuthStore (login/logout propagate both ways) and the fetch/WebSocket implementations. */
    withAccount(accountId: string): Client;
    ```
  - In `createClient`: pass `accountId: opts.accountId,` into the `new Transport({...})` config; add `let accountsService: AccountsService | undefined;` next to `filesService`; add to the `client` literal (mirroring the `files` lazy-getter pattern):
    ```ts
      get accounts() {
        return (accountsService ??= new AccountsService(transport));
      },
      withAccount(accountId: string) {
        // Sibling client: SAME AuthStore instance (explicitly forwarded), same fetch/WS impls,
        // a new Transport with the account header baked in.
        return createClient(baseUrl, { ...opts, authStore, accountId });
      },
    ```
- [ ] `src/index.ts`: add
  ```ts
  export { AccountsService } from "./accounts.js";
  export type { AccountScope } from "./accounts.js";
  ```
- [ ] Run `mise exec node@24 -- npm test && mise exec node@24 -- npm run typecheck` — expect PASS.
- [ ] `git add -A && git commit -m "feat(sdk): account scoping — accountId option, withAccount views, accounts.activate"`

---

### Task 6: TS — record abilities (`getAbilities`)

**Files:**
- Modify: `clients/typescript/src/collection.ts` (+`RecordAbilities`, `getAbilities`), `src/typed/service.ts` (+`RawTypedService.getAbilities` + delegation), `src/index.ts` (exports)
- Test: `clients/typescript/test/abilities.test.ts` (new)

**Interfaces:**
- Produces: `export interface RecordAbilities { view: boolean; update: boolean; delete: boolean }` (exported from the base index — Task 9's generated imports reference it); `CollectionService.getAbilities(id, opts?)`; `RawTypedService.getAbilities(id, opts?)`. Consumed by Tasks 9, 12, 13.

- [ ] Write failing test `clients/typescript/test/abilities.test.ts`:
  ```ts
  import { describe, it, expect, vi } from "vitest";
  import { createClient } from "../src/index.js";
  import { isZigbaseError } from "../src/errors.js";

  function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  }

  describe("getAbilities", () => {
    it("GETs /records/:id/abilities and parses the boolean set", async () => {
      const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
        expect(url).toBe("http://api.test/api/collections/notes/records/r%201/abilities");
        expect(init?.method ?? "GET").toBe("GET");
        return jsonResponse({ view: true, update: false, delete: false });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      const ab = await zb.collection("notes").getAbilities("r 1");
      expect(ab).toEqual({ view: true, update: false, delete: false });
    });

    it("maps a non-viewable record to a 404 ZigbaseError", async () => {
      const fetchMock = vi.fn(async () =>
        jsonResponse({ status: 404, message: "Not found." }, 404),
      ) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      try {
        await zb.collection("notes").getAbilities("ghost");
        expect.unreachable();
      } catch (e) {
        expect(isZigbaseError(e)).toBe(true);
        expect((e as { status: number }).status).toBe(404);
      }
    });
  });
  ```
  Run `mise exec node@24 -- npm test` — expect FAIL.
- [ ] Implement `src/collection.ts` — add above the `CollectionService` class:
  ```ts
  /** The actions the current principal may perform on a specific record (#155). */
  export interface RecordAbilities {
    view: boolean;
    update: boolean;
    delete: boolean;
  }
  ```
  and add the method to `CollectionService` (after `delete`):
  ```ts
    /**
     * GET /api/collections/:col/records/:id/abilities — the actions the current principal
     * may perform on this record (requires ZigBase >= 0.9.0). Rejects with a 404
     * `ZigbaseError` when the record is not viewable — the endpoint never reveals a
     * record's existence, so `view` is always `true` on a success.
     */
    getAbilities(
      id: string,
      opts: { signal?: AbortSignal; requestKey?: string } = {},
    ): Promise<RecordAbilities> {
      return this.transport.send<RecordAbilities>(
        `${this.recordsBase()}/${encodeURIComponent(id)}/abilities`,
        { method: "GET", signal: opts.signal, requestKey: opts.requestKey },
      );
    }
  ```
- [ ] Implement `src/typed/service.ts`: add `import type { RecordAbilities } from "../collection.js";` (extend the existing `collection.js` type import); add to `RawTypedService`:
  ```ts
    getAbilities(id: string, opts?: { signal?: AbortSignal; requestKey?: string }): Promise<RecordAbilities>;
  ```
  and to the object returned by `makeRecordService` (after `delete(id)`):
  ```ts
      getAbilities(id, opts) {
        return inner.getAbilities(id, opts);
      },
  ```
- [ ] `src/index.ts`: add `RecordAbilities` to the collection exports: `export type { RecordAbilities, AuthResponse, ... } from "./collection.js";` — read the current export line for `collection.js` first and extend it (if only the class is exported today, add `export type { RecordAbilities } from "./collection.js";`).
- [ ] Run `mise exec node@24 -- npm test && mise exec node@24 -- npm run typecheck` — expect PASS.
- [ ] `git add -A && git commit -m "feat(sdk): per-record abilities — getAbilities on base + typed services"`

---

### Task 7: TS base — analytics + senders services

**Files:**
- Create: `clients/typescript/src/analytics.ts`, `clients/typescript/src/senders.ts`
- Modify: `src/client.ts` (lazy getters), `src/index.ts` (exports)
- Test: `clients/typescript/test/analytics.test.ts`, `test/senders.test.ts` (new), extend `test/exports.test.ts`

**Interfaces:**
- Produces: `Client.analytics: AnalyticsService` (`events(opts?)`, `rollup(name, opts?)` — both `Promise<{ items: … }>`), `Client.senders: SendersService` (`list`, `create(email)`, `verify(id, token)`), wire types `AnalyticsEvent`, `RollupBucket`, `SenderIdentity` exactly as spec §8/§9. Consumed by Tasks 10, 14.

- [ ] Write failing tests. `clients/typescript/test/analytics.test.ts`:
  ```ts
  import { describe, it, expect, vi } from "vitest";
  import { createClient } from "../src/index.js";

  function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  }

  describe("analytics", () => {
    it("events() maps name/actor/since/limit query params (Date -> ISO)", async () => {
      const fetchMock = vi.fn(async (url: string) => {
        const u = new URL(url);
        expect(u.pathname).toBe("/api/analytics/events");
        expect(u.searchParams.get("name")).toBe("user.signup");
        expect(u.searchParams.get("actor")).toBe("u1");
        expect(u.searchParams.get("since")).toBe("2026-01-02T03:04:05.000Z");
        expect(u.searchParams.get("limit")).toBe("10");
        return jsonResponse({ items: [] });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      const out = await zb.analytics.events({
        name: "user.signup",
        actor: "u1",
        since: new Date("2026-01-02T03:04:05Z"),
        limit: 10,
      });
      expect(out.items).toEqual([]);
    });

    it("rollup() hits /api/analytics/rollups/:name with from/to (name URL-encoded)", async () => {
      const fetchMock = vi.fn(async (url: string) => {
        const u = new URL(url);
        expect(u.pathname).toBe("/api/analytics/rollups/signups%20daily");
        expect(u.searchParams.get("from")).toBe("2026-01-01");
        expect(u.searchParams.get("to")).toBe("2026-02-01");
        return jsonResponse({ items: [{ bucket: "2026-01-01", account: "a", actor: "", value: 3, computed_at: "x" }] });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      const out = await zb.analytics.rollup("signups daily", { from: "2026-01-01", to: "2026-02-01" });
      expect(out.items[0]?.value).toBe(3);
    });
  });
  ```
  `clients/typescript/test/senders.test.ts`:
  ```ts
  import { describe, it, expect, vi } from "vitest";
  import { createClient } from "../src/index.js";
  import { isZigbaseError } from "../src/errors.js";

  function jsonResponse(body: unknown, status = 200): Response {
    return new Response(JSON.stringify(body), {
      status,
      headers: { "content-type": "application/json" },
    });
  }

  describe("senders", () => {
    it("list() parses the {items} envelope (server >= 0.10.0)", async () => {
      const fetchMock = vi.fn(async (url: string) => {
        expect(url).toBe("http://api.test/api/senders");
        return jsonResponse({ items: [{ id: "s1", email: "a@x.io", status: "verified", verified_at: "t" }] });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      const out = await zb.senders.list();
      expect(out.items[0]?.email).toBe("a@x.io");
    });

    it("create() POSTs the email; 201 pending parses like 200", async () => {
      const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
        expect(url).toBe("http://api.test/api/senders");
        expect(JSON.parse(String(init?.body))).toEqual({ email: "from@acct.io" });
        return jsonResponse({ id: "s2", email: "from@acct.io", status: "pending" }, 201);
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      const out = await zb.senders.create("from@acct.io");
      expect(out.status).toBe("pending");
    });

    it("create() surfaces a 429 throttle as a ZigbaseError", async () => {
      const fetchMock = vi.fn(async () =>
        jsonResponse({ status: 429, message: "Verification email already sent recently; try again later." }, 429),
      ) as unknown as typeof fetch;
      // maxRetries: 0 disables the transport's 429 backoff so the error surfaces immediately.
      const zb = createClient("http://api.test", { fetch: fetchMock, maxRetries: 0 });
      try {
        await zb.senders.create("x@y.io");
        expect.unreachable();
      } catch (e) {
        expect(isZigbaseError(e)).toBe(true);
        expect((e as { status: number }).status).toBe(429);
      }
    });

    it("verify() POSTs the token to /api/senders/:id/verify", async () => {
      const fetchMock = vi.fn(async (url: string, init?: RequestInit) => {
        expect(url).toBe("http://api.test/api/senders/s2/verify");
        expect(JSON.parse(String(init?.body))).toEqual({ token: "tok" });
        return jsonResponse({ verified: true });
      }) as unknown as typeof fetch;
      const zb = createClient("http://api.test", { fetch: fetchMock });
      expect(await zb.senders.verify("s2", "tok")).toEqual({ verified: true });
    });
  });
  ```
  Run `mise exec node@24 -- npm test` — expect FAIL.
- [ ] Create `src/analytics.ts`:
  ```ts
  import type { Transport } from "./transport.js";

  /** One row of the tenant-scoped activity feed (`_events`). Field names are the wire's snake_case. */
  export interface AnalyticsEvent {
    id: string;
    created: string;
    name: string;
    /** JSON value; null when unparseable/empty. */
    payload: unknown;
    actor_collection: string;
    actor: string;
    account: string;
    occurred_at: string;
  }

  /** One summary row of a declared rollup. */
  export interface RollupBucket {
    bucket: string;
    account: string;
    actor: string;
    value: number;
    computed_at: string;
  }

  const iso = (d: string | Date | undefined): string | undefined =>
    d instanceof Date ? d.toISOString() : d;

  /** Product-analytics read APIs (requires ZigBase >= 0.9.0). Tenant-scoped, fail closed. */
  export class AnalyticsService {
    constructor(private readonly transport: Transport) {}

    /**
     * GET /api/analytics/events — the tenant-scoped activity feed. 401 anonymous; empty
     * `items` with no active account; a superuser sees everything.
     */
    events(
      opts: {
        name?: string;
        actor?: string;
        since?: string | Date;
        limit?: number;
        signal?: AbortSignal;
        requestKey?: string;
      } = {},
    ): Promise<{ items: AnalyticsEvent[] }> {
      return this.transport.send<{ items: AnalyticsEvent[] }>("/api/analytics/events", {
        method: "GET",
        query: { name: opts.name, actor: opts.actor, since: iso(opts.since), limit: opts.limit },
        signal: opts.signal,
        requestKey: opts.requestKey,
      });
    }

    /**
     * GET /api/analytics/rollups/:name — a declared rollup's summary rows. 404 for an
     * undeclared name; 403 for a non-account-grouped rollup queried by a non-superuser.
     */
    rollup(
      name: string,
      opts: {
        from?: string | Date;
        to?: string | Date;
        signal?: AbortSignal;
        requestKey?: string;
      } = {},
    ): Promise<{ items: RollupBucket[] }> {
      return this.transport.send<{ items: RollupBucket[] }>(
        `/api/analytics/rollups/${encodeURIComponent(name)}`,
        {
          method: "GET",
          query: { from: iso(opts.from), to: iso(opts.to) },
          signal: opts.signal,
          requestKey: opts.requestKey,
        },
      );
    }
  }
  ```
- [ ] Create `src/senders.ts`:
  ```ts
  import type { Transport } from "./transport.js";

  /** One verified-sender identity of the active account. */
  export interface SenderIdentity {
    id: string;
    email: string;
    status: string;
    verified_at: string;
  }

  /** Verified sender-identity management. `list` requires ZigBase >= 0.10.0 (the `{items}`
   *  envelope); `create`/`verify` exist as of 0.9.0. All three verbs are account-scoped
   *  exactly like the record API (`withAccount` / the `zb_account` cookie / superuser header). */
  export class SendersService {
    constructor(private readonly transport: Transport) {}

    /** GET /api/senders — the active account's sender identities. Requires ZigBase >= 0.10.0. */
    list(
      opts: { signal?: AbortSignal; requestKey?: string } = {},
    ): Promise<{ items: SenderIdentity[] }> {
      return this.transport.send<{ items: SenderIdentity[] }>("/api/senders", {
        method: "GET",
        signal: opts.signal,
        requestKey: opts.requestKey,
      });
    }

    /**
     * POST /api/senders — request verification of a From address. The token is EMAILED to
     * that address, never returned. 201 pending / 200 already-verified; rejects with a 429
     * `ZigbaseError` when a re-send is throttled.
     */
    create(
      email: string,
      opts: { signal?: AbortSignal; requestKey?: string } = {},
    ): Promise<{ id: string; email: string; status: string }> {
      return this.transport.send("/api/senders", {
        method: "POST",
        body: { email },
        signal: opts.signal,
        requestKey: opts.requestKey,
      });
    }

    /** POST /api/senders/:id/verify — 404 for a wrong token/account/id (deliberate non-oracle). */
    verify(
      id: string,
      token: string,
      opts: { signal?: AbortSignal; requestKey?: string } = {},
    ): Promise<{ verified: boolean }> {
      return this.transport.send(`/api/senders/${encodeURIComponent(id)}/verify`, {
        method: "POST",
        body: { token },
        signal: opts.signal,
        requestKey: opts.requestKey,
      });
    }
  }
  ```
- [ ] Wire into `src/client.ts` (same lazy-getter pattern as `files`/`accounts`): imports for both services, `readonly analytics: AnalyticsService;` + `readonly senders: SendersService;` on the `Client` interface, `let analyticsService/sendersService` locals, and the two getters in the client literal (`get analytics() { return (analyticsService ??= new AnalyticsService(transport)); }`, same for senders). Because `withAccount` builds siblings via `createClient`, scoped views get scoped analytics/senders for free.
- [ ] `src/index.ts`:
  ```ts
  export { AnalyticsService } from "./analytics.js";
  export type { AnalyticsEvent, RollupBucket } from "./analytics.js";
  export { SendersService } from "./senders.js";
  export type { SenderIdentity } from "./senders.js";
  ```
  Extend `test/exports.test.ts`: `expect(typeof zb.AnalyticsService).toBe("function"); expect(typeof zb.SendersService).toBe("function"); expect(typeof zb.AccountsService).toBe("function");`
- [ ] Run `mise exec node@24 -- npm test && mise exec node@24 -- npm run typecheck` — expect PASS.
- [ ] `git add -A && git commit -m "feat(sdk): analytics + senders services (lazy client getters)"`

---

### Task 8: TS realtime — custom-topic frames (`subscribeTopic`)

**Files:**
- Modify: `clients/typescript/src/realtime.ts`, `src/realtime-entry.ts`
- Test: extend `clients/typescript/test/realtime-subscribe.test.ts`, `test/realtime-entry.test.ts`

**Interfaces:**
- Produces (spec §10.2): `TopicMessage { topic: string; kind: "signal" | "message"; data?: unknown }`, `RealtimeService.subscribeTopic(topic, cb): Promise<() => void>` / `unsubscribeTopic(topic, cb?)`, mirrored on `RealtimeClient`; `type TopicCallback = (msg: TopicMessage) => void`. Frame routing: `type === "signal" | "message"` delivered by `frame.topic`; everything unknown dropped. Consumed by Task 14.

- [ ] Read `clients/typescript/src/realtime.ts` and `src/realtime-entry.ts`; read `test/support/fake-websocket.ts` for `emitMessage` semantics.
- [ ] Write failing tests — append to `test/realtime-subscribe.test.ts` (uses the existing `makeService` helper; add `import type { TopicMessage } from "../src/realtime.js";` at the top):
  ```ts
  describe("RealtimeService.subscribeTopic", () => {
    it("subscribes with the standard frame and delivers signal + message frames by topic", async () => {
      const { service, factory } = makeService();
      const got: TopicMessage[] = [];
      const p = service.subscribeTopic("orders", (m) => got.push(m));
      const ws = factory.last;
      ws.emitOpen();
      expect(ws.sentFrames).toContainEqual({ action: "subscribe", topic: "orders" });
      ws.emitMessage({ type: "ack", action: "subscribe", topic: "orders" });
      await p;

      ws.emitMessage({ type: "signal", topic: "orders" });
      ws.emitMessage({ type: "message", topic: "orders", data: { n: 1 } });
      ws.emitMessage({ type: "message", topic: "other", data: { n: 2 } }); // other topic -> dropped
      ws.emitMessage({ type: "bogus", topic: "orders" }); // unknown type -> dropped
      ws.emitMessage({ type: "signal" }); // missing topic -> dropped

      expect(got).toEqual([
        { topic: "orders", kind: "signal" },
        { topic: "orders", kind: "message", data: { n: 1 } },
      ]);
    });

    it("topic frames do not reach record subscriptions (and record events do not reach topic subs)", async () => {
      const { service, factory } = makeService();
      const recordCb = vi.fn();
      const topicCb = vi.fn();
      const p1 = service.subscribe("posts", recordCb);
      const ws = factory.last;
      ws.emitOpen();
      ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
      await p1;
      const p2 = service.subscribeTopic("posts", topicCb); // same name, disjoint delivery
      ws.emitMessage({ type: "ack", action: "subscribe", topic: "posts" });
      await p2;

      ws.emitMessage({ type: "signal", topic: "posts" });
      ws.emitMessage({ type: "event", topic: "posts", action: "create", record: { id: "p1" } });
      expect(topicCb).toHaveBeenCalledTimes(1);
      expect(topicCb).toHaveBeenCalledWith({ topic: "posts", kind: "signal" });
      expect(recordCb).toHaveBeenCalledTimes(1); // only the event frame
    });

    it("unsubscribeTopic drops delivery and sends one unsubscribe frame when the topic empties", async () => {
      const { service, factory } = makeService();
      const cb = vi.fn();
      const p = service.subscribeTopic("orders", cb);
      const ws = factory.last;
      ws.emitOpen();
      ws.emitMessage({ type: "ack", action: "subscribe", topic: "orders" });
      await p;
      service.unsubscribeTopic("orders", cb);
      ws.emitMessage({ type: "signal", topic: "orders" });
      expect(cb).not.toHaveBeenCalled();
      expect(ws.sentFrames).toContainEqual({ action: "unsubscribe", topic: "orders" });
    });

    it("a server error frame rejects a pending subscribeTopic (non-canSubscribe topic)", async () => {
      const { service, factory } = makeService();
      const p = service.subscribeTopic("private", vi.fn());
      const ws = factory.last;
      ws.emitOpen();
      ws.emitMessage({ type: "error", message: "authentication required to subscribe" });
      await expect(p).rejects.toThrow("authentication required to subscribe");
    });

    it("topic subscriptions resubscribe after reconnect", async () => {
      const { service, factory } = makeService();
      const p = service.subscribeTopic("orders", vi.fn());
      const ws1 = factory.last;
      ws1.emitOpen();
      ws1.emitMessage({ type: "ack", action: "subscribe", topic: "orders" });
      await p;
      ws1.emitClose();
      // backoff sleep is a no-op in makeService; a new socket is created
      await Promise.resolve();
      const ws2 = factory.last;
      expect(ws2).not.toBe(ws1);
      ws2.emitOpen();
      expect(ws2.sentFrames).toContainEqual({ action: "subscribe", topic: "orders" });
    });
  });
  ```
  (If `fake-websocket.ts` names its close-emitter differently than `emitClose`, read it and use its API; the resubscribe path is the assertion.) Run `mise exec node@24 -- npm test` — expect FAIL (no `subscribeTopic`).
- [ ] Implement `src/realtime.ts`:
  - Add the public types after `RealtimeCallback`:
    ```ts
    /** A frame delivered on a custom (non-collection) topic (server >= 0.10.0 for `__features`;
     *  custom `ctx.realtime()` topics exist as of 0.9.0). */
    export interface TopicMessage {
      topic: string;
      /** "signal" = re-fetch hint (no payload); "message" = payload-carrying broadcast. */
      kind: "signal" | "message";
      /** The envelope's `data` value; absent for signals. */
      data?: unknown;
    }

    export type TopicCallback = (msg: TopicMessage) => void;
    ```
  - Extend the internal `Subscription` with a kind discriminant + a second callback set:
    ```ts
    interface Subscription {
      topic: string;
      /** "records" = collection subscription (event frames); "topic" = custom topic (signal/message). */
      kind: "records" | "topic";
      filter?: string;
      callbacks: Set<RealtimeCallback>;
      topicCallbacks: Set<TopicCallback>;
      pending: Array<{ resolve: () => void; reject: (e: Error) => void }>;
      acked: boolean;
    }
    ```
    In `subscribe()`, the created sub becomes `{ topic, kind: "records", filter: opts.filter, callbacks: new Set(), topicCallbacks: new Set(), pending: [], acked: false }`.
  - Add a distinct key namespace so a topic sub and a record sub of the same name never collide (names are disjoint server-side, but the map must stay coherent):
    ```ts
    function topicKey(topic: string): string {
      return ` topic:${topic}`;
    }
    ```
  - Public methods (after `unsubscribe`), mirroring `subscribe`'s pending/ack flow — topic subs take no filter:
    ```ts
    /**
     * Subscribe to a custom (non-collection) topic. Delivers the standard topic frames:
     * `{"type":"signal","topic"}` (kind "signal", no payload — re-fetch hint) and
     * `{"type":"message","topic","data"}` (kind "message" — `ctx.realtime().broadcast`
     * payloads). Feature-change notifications are `subscribeTopic("__features", cb)`
     * (server >= 0.10.0). Same wire frame, ack, resubscribe and backoff machinery as
     * record subscriptions; a server-rejected subscribe rejects the returned promise.
     */
    async subscribeTopic(topic: string, cb: TopicCallback): Promise<() => void> {
      const key = topicKey(topic);
      let sub = this.subscriptions.get(key);
      if (!sub) {
        sub = { topic, kind: "topic", callbacks: new Set(), topicCallbacks: new Set(), pending: [], acked: false };
        this.subscriptions.set(key, sub);
      }
      sub.topicCallbacks.add(cb);

      this.ensureConnected();

      if (sub.acked) {
        return () => this.unsubscribeTopic(topic, cb);
      }
      await new Promise<void>((resolve, reject) => {
        sub!.pending.push({ resolve, reject });
        if (this.opened) this.sendSubscribe(sub!);
      });
      return () => this.unsubscribeTopic(topic, cb);
    }

    /** Remove a topic callback (all of them when `cb` is omitted); sends one unsubscribe
     *  frame when the topic has no live subscription variants left. */
    unsubscribeTopic(topic: string, cb?: TopicCallback): void {
      const sub = this.subscriptions.get(topicKey(topic));
      if (!sub) return;
      if (cb) sub.topicCallbacks.delete(cb);
      else sub.topicCallbacks.clear();
      if (sub.topicCallbacks.size === 0) {
        this.subscriptions.delete(topicKey(topic));
        if (this.opened && this.ws && !this.hasTopic(topic)) {
          this.send({ action: "unsubscribe", topic });
        }
      }
    }
    ```
  - Frame routing — extend the `onMessage` switch with exactly two new cases (rule 2 of spec §10.1; anything else keeps falling through to the drop):
    ```ts
        case "signal":
        case "message":
          this.onTopicFrame(frame);
          break;
    ```
    and add:
    ```ts
    private onTopicFrame(frame: Record<string, unknown>): void {
      const topic = frame.topic;
      if (typeof topic !== "string") return; // malformed (missing topic) -> dropped
      const kind = frame.type as "signal" | "message";
      const msg: TopicMessage =
        kind === "message" ? { topic, kind, data: frame.data } : { topic, kind };
      for (const sub of this.subscriptions.values()) {
        if (sub.kind !== "topic" || sub.topic !== topic) continue;
        for (const cb of sub.topicCallbacks) cb(msg);
      }
    }
    ```
    (`onAck`/`onErrorFrame`/`resubscribeAll`/`close()` need no change — they iterate all subscriptions by `topic`/pending and therefore cover both kinds; `sendSubscribe` sends no `filter` key because topic subs never set one.)
- [ ] Implement `src/realtime-entry.ts`: extend the re-export line — `export type { RealtimeEvent, RealtimeCallback, RealtimeAction, TopicMessage, TopicCallback } from "./realtime.js";`; add to the `RealtimeClient` interface:
  ```ts
    subscribeTopic(topic: string, cb: (msg: TopicMessage) => void): Promise<() => void>;
    unsubscribeTopic(topic: string, cb?: (msg: TopicMessage) => void): void;
  ```
  (add `TopicMessage` to the type-import from `./realtime.js`), and to the `realtime` literal in `withRealtime`:
  ```ts
      subscribeTopic: (topic, cb) => getService().subscribeTopic(topic, cb),
      unsubscribeTopic: (topic, cb) => getService().unsubscribeTopic(topic, cb),
  ```
- [ ] Extend `test/realtime-entry.test.ts` with a delegation smoke test (read the file's existing fixture; assert `zb.realtime.subscribeTopic` is a function and resolves through the fake WS ack like the existing subscribe test does).
- [ ] Run `mise exec node@24 -- npm test && mise exec node@24 -- npm run typecheck` — expect PASS.
- [ ] `git add -A && git commit -m "feat(sdk): custom-topic realtime frames — subscribeTopic/unsubscribeTopic, signal/message routing"`

---

### Task 9: Zig emitter — metadata, sort unions, service opts, tenant omission, imports, schemaHash

**Files:**
- Modify: `src/codegen/emit.zig` (emitMeta, emitSortUnion (new), emitService (rework), emitCreate, emitRecord, emitImports + tests), `src/codegen/gen_client.zig` (schemaHash, section wiring + tests)
- Regenerate: `clients/typescript/test/codegen/dating/zbase.gen.ts`, `zbase.runtime.gen.ts` (generator-produced, NEVER hand-edited)

**Interfaces:**
- Consumes: `CoreSupports_0_3`, `SortExpr`, `CollectionMeta.searchable/tenant` (Task 4), `RecordAbilities` export from base index (Task 6).
- Produces: generated files with `search?`/`vector?` gating, `{N}SortField`/`{N}Sort` unions, `sort?: {N}Sort | {N}Sort[]`, unconditional `getAbilities`, tenant-omitting `*Create`, `searchable`/`tenant` meta keys, `export type _RequiresCore = …CoreSupports_0_3` guard, searchable/tenant folded into `schema-hash`. Consumed by Tasks 10–14.

- [ ] Read `src/codegen/emit.zig` and `src/codegen/gen_client.zig` fully before editing (the format-string arg indices below must match what you find).
- [ ] TDD: add the new emit tests to `src/codegen/emit.zig` first (they reference helpers/functions added below; expect compile failure → then implement):
  ```zig
  test "emitMeta emits searchable + tenant keys when configured" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const fields = [_]schema.Field{
          .{ .id = "a", .name = "title", .options = .{ .text = .{} }, .searchable = true },
          .{ .id = "b", .name = "account", .options = .{ .text = .{} } },
      };
      const col = schema.Collection{ .id = "", .name = "notes", .fields = &fields, .options = .{ .tenant_field = "account" } };
      var w: std.ArrayList(u8) = .empty;
      try emitMeta(a, &w, col);
      try std.testing.expect(contains(w.items, "searchable: [\"title\"],"));
      try std.testing.expect(contains(w.items, "tenant: \"account\","));
      // A collection without either feature emits NEITHER key (absent = feature not present).
      var w2: std.ArrayList(u8) = .empty;
      try emitMeta(a, &w2, blogPosts());
      try std.testing.expect(!contains(w2.items, "searchable:"));
      try std.testing.expect(!contains(w2.items, "tenant:"));
  }

  test "emitSortUnion: visible scalars minus json/multi/file, plus system fields" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      var w: std.ArrayList(u8) = .empty;
      try emitSortUnion(a, &w, blogPosts());
      const out = w.items;
      // blogPosts: title(text) status(select) price(number) author(single rel) tags(multi rel)
      //            cover(file) created(user autodate, deduped into system fields)
      try std.testing.expect(contains(out,
          "export type PostSortField = \"title\" | \"status\" | \"price\" | \"author\" | \"id\" | \"created\" | \"updated\";"));
      try std.testing.expect(contains(out, "export type PostSort = SortExpr<PostSortField>;"));
      try std.testing.expect(!contains(out, "\"tags\"")); // multi-value excluded
      try std.testing.expect(!contains(out, "\"cover\"")); // file excluded
  }

  test "emitService: search/vector gating, narrowed sort, unconditional getAbilities" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      // Searchable + json collection
      const fields = [_]schema.Field{
          .{ .id = "a", .name = "body", .options = .{ .text = .{} }, .searchable = true },
          .{ .id = "b", .name = "embedding", .options = .{ .json = .{} } },
          .{ .id = "c", .name = "metadata", .options = .{ .json = .{} } },
      };
      const docs = schema.Collection{ .id = "", .name = "docs", .fields = &fields };
      var w: std.ArrayList(u8) = .empty;
      try emitService(a, &w, docs);
      const out = w.items;
      try std.testing.expect(contains(out, "search?: string;"));
      try std.testing.expect(contains(out,
          "vector?: { field: \"embedding\" | \"metadata\"; metric?: \"cosine\" | \"l2\"; values: number[] };"));
      try std.testing.expect(contains(out, "sort?: DocSort | DocSort[];"));
      try std.testing.expect(contains(out,
          "getAbilities(id: string, opts?: { signal?: AbortSignal; requestKey?: string }): Promise<RecordAbilities>;"));
      // vector appears ONLY in getList (one occurrence)
      try std.testing.expectEqual(@as(usize, 1), countOccurrences(out, "vector?:"));
      // search appears in all five list-ish blocks
      try std.testing.expectEqual(@as(usize, 5), countOccurrences(out, "search?: string;"));

      // A collection with neither searchable nor json fields gets neither key, still getAbilities.
      var w2: std.ArrayList(u8) = .empty;
      try emitService(a, &w2, blogPosts());
      try std.testing.expect(!contains(w2.items, "search?:"));
      try std.testing.expect(!contains(w2.items, "vector?:"));
      try std.testing.expect(contains(w2.items, "getAbilities(id: string"));
      try std.testing.expect(contains(w2.items, "sort?: PostSort | PostSort[];"));
  }

  test "emitService: abilities doc comment lists configured actions" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const Abilities = @import("../authz/abilities.zig");
      const fields = [_]schema.Field{
          .{ .id = "a", .name = "account", .options = .{ .relation = .{ .targetCollectionId = "accounts", .maxSelect = 1 } } },
      };
      const col = schema.Collection{ .id = "", .name = "notes", .fields = &fields, .options = .{ .abilities = .{
          .update = .{ .relationship = .{ .via = "account", .min_role = "editor" } },
          .delete = .{ .relationship = .{ .via = "account", .min_role = "admin" } },
      } } };
      var w: std.ArrayList(u8) = .empty;
      try emitService(a, &w, col);
      try std.testing.expect(contains(w.items,
          "/** Row abilities configured for: update, delete. Check per record via getAbilities(). */"));
      _ = Abilities;
  }

  test "emitCreate omits the tenant field (server-stamped); emitRecord keeps + documents it" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const fields = [_]schema.Field{
          .{ .id = "a", .name = "title", .required = true, .options = .{ .text = .{} } },
          .{ .id = "b", .name = "account", .options = .{ .text = .{} } },
      };
      const col = schema.Collection{ .id = "", .name = "notes", .fields = &fields, .options = .{ .tenant_field = "account" } };
      var w: std.ArrayList(u8) = .empty;
      try emitCreate(a, &w, col);
      try std.testing.expect(!contains(w.items, "account"));
      try std.testing.expect(contains(w.items, "title: string;"));
      var w2: std.ArrayList(u8) = .empty;
      try emitRecord(a, &w2, col);
      try std.testing.expect(contains(w2.items, "account: string;"));
      try std.testing.expect(contains(w2.items, "Tenant-owned: `account` is server-stamped"));
  }
  ```
  If the `Abilities` field literal does not compile, read `src/authz/abilities.zig`'s `Abilities`/`Ability`/`Relationship` types and adjust the literal (the lowered `min_role` is `[]const u8`).
  Add to `src/codegen/gen_client.zig` tests:
  ```zig
  test "schemaHash changes when searchable or tenant_field toggles" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const cols = try miniBlog(a);
      const base = schemaHash(cols);
      // Toggle searchable on one field.
      var cols2 = try a.dupe(schema.Collection, cols);
      var f2 = try a.dupe(schema.Field, cols2[0].fields);
      f2[0].searchable = true;
      cols2[0].fields = f2;
      try std.testing.expect(base != schemaHash(cols2));
      // Set a tenant field.
      var cols3 = try a.dupe(schema.Collection, cols);
      cols3[0].options.tenant_field = "account";
      try std.testing.expect(base != schemaHash(cols3));
  }

  test "generate emits sort unions, the _RequiresCore guard, and SortExpr/RecordAbilities imports" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const cols = try miniBlog(a);
      const out = try generate(a, cols, &.{}, &.{}, &.{}, &.{}, true, "users", "BlogClient", "/api");
      inline for (.{
          "export type PostSortField =",
          "export type PostSort = SortExpr<PostSortField>;",
          "export type _RequiresCore = import(\"../../../src/typed/index.js\").CoreSupports_0_3;",
          "type SortExpr,",
          "type RecordAbilities",
      }) |needle| try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
      // Non-in-repo emission uses the package path.
      const pkg = try generate(a, cols, &.{}, &.{}, &.{}, &.{}, false, "users", "BlogClient", "/api");
      try std.testing.expect(std.mem.indexOf(u8, pkg,
          "export type _RequiresCore = import(\"@zigbase/client/typed\").CoreSupports_0_3;") != null);
  }
  ```
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect FAILURE (new tests / missing symbols).
- [ ] Implement in `src/codegen/emit.zig` — add helpers near `hasSingleFileFields`:
  ```zig
  /// True when any visible field is full-text searchable (#157) — gates the generated
  /// `search?: string` option and the meta `searchable` key.
  fn isSearchableCollection(c: schema.Collection) bool {
      for (c.fields) |f| if (!f.hidden and f.searchable) return true;
      return false;
  }

  /// True when any visible field is a json field — gates the generated `vector` option.
  fn hasJsonFields(c: schema.Collection) bool {
      for (c.fields) |f| if (!f.hidden and f.options == .json) return true;
      return false;
  }

  /// The `search?: string;` opts line for searchable collections ("" otherwise).
  fn searchLine(c: schema.Collection) []const u8 {
      return if (isSearchableCollection(c)) "    search?: string;\n" else "";
  }

  /// The narrowed `vector?: { field: "a" | "b"; … };` opts line for json-bearing
  /// collections ("" otherwise). getList-only (the server rejects vector + cursor).
  fn vectorLine(alloc: std.mem.Allocator, c: schema.Collection) ![]const u8 {
      if (!hasJsonFields(c)) return "";
      var u: std.ArrayList(u8) = .empty;
      var first = true;
      for (c.fields) |f| {
          if (f.hidden or f.options != .json) continue;
          if (!first) try u.appendSlice(alloc, " | ");
          first = false;
          try u.append(alloc, '"');
          try u.appendSlice(alloc, f.name);
          try u.append(alloc, '"');
      }
      return std.fmt.allocPrint(alloc,
          "    vector?: {{ field: {s}; metric?: \"cosine\" | \"l2\"; values: number[] }};\n", .{u.items});
  }
  ```
- [ ] Add `emitSortUnion` (new section helper, after `emitFields`):
  ```zig
  /// Per-collection sortable-field union + sort alias (spec §5.2): every field in the
  /// *Fields fluent accessors MINUS json, multi-value and file fields — what the server
  /// can meaningfully ORDER BY and what cursor mode accepts (dotted relation paths are
  /// deliberately not included).
  pub fn emitSortUnion(alloc: std.mem.Allocator, w: *W, c: schema.Collection) !void {
      const rec = try ident.recordName(alloc, c.name);
      try putf(alloc, w, "export type {s}SortField =", .{rec});
      var first = true;
      if (c.type == .auth) {
          inline for (.{ "email", "username", "verified" }) |n| {
              try put(alloc, w, if (first) " " else " | ");
              first = false;
              try putf(alloc, w, "\"{s}\"", .{n});
          }
      }
      for (c.fields) |f| {
          if (f.hidden) continue;
          if (c.type == .auth and isAuthSynthesized(f.name)) continue;
          if (isSystemFieldName(f.name)) continue; // synthesized below
          if (tt.kindOf(f) == .file_name) continue;
          if (f.options == .json) continue;
          if (f.isMultiValue()) continue;
          try put(alloc, w, if (first) " " else " | ");
          first = false;
          try putf(alloc, w, "\"{s}\"", .{f.name});
      }
      inline for (.{ "id", "created", "updated" }) |n| {
          try put(alloc, w, if (first) " " else " | ");
          first = false;
          try putf(alloc, w, "\"{s}\"", .{n});
      }
      try put(alloc, w, ";\n");
      try putf(alloc, w, "export type {s}Sort = SortExpr<{s}SortField>;\n", .{ rec, rec });
  }
  ```
- [ ] Rework `emitService`: compute at the top (after the existing `svc/rec/wn/fld` locals):
  ```zig
      const sort_ty = try std.fmt.allocPrint(alloc, "{s}Sort | {s}Sort[]", .{ rec, rec });
      const search = searchLine(c);
      const vector = try vectorLine(alloc, c);
      // Row-abilities doc comment (#155): action names only — the rule ASTs are server business.
      if (c.options.abilities) |ab| {
          var names: std.ArrayList(u8) = .empty;
          if (ab.view != null) try names.appendSlice(alloc, "view, ");
          if (ab.create != null) try names.appendSlice(alloc, "create, ");
          if (ab.update != null) try names.appendSlice(alloc, "update, ");
          if (ab.delete != null) try names.appendSlice(alloc, "delete, ");
          const trimmed = std.mem.trimRight(u8, names.items, ", ");
          try putf(alloc, w, "/** Row abilities configured for: {s}. Check per record via getAbilities(). */\n", .{trimmed});
      }
  ```
  (place the doc comment emission BEFORE the `export interface {s} {` line). Then in BOTH multiline format literals:
  - replace every `sort?: string;` with `sort?: {7s};` (relations branch) / `sort?: {5s};` (non-relations branch) and append `sort_ty` to the arg tuples;
  - directly under each `sort?:` line insert `{8s}` (search, relations) / `{6s}` (search, non-relations) — in `getList` insert `{8s}{9s}` / `{6s}{7s}` (search then vector) — appending `search` and `vector` to the tuples. The lines carry their own indentation + trailing newline, so place the placeholder at column 0 of the literal line, immediately followed by the next option line, e.g. the relations `getList` block becomes:
    ```
    \\  getList<K extends {0s} = never>(opts?: {{
    \\    where?: {3s};
    \\    sort?: {7s};
    \\{8s}{9s}    expand?: K[];
    \\    page?: number;
    ```
    and `getFirstListItem`/`getPage`/`iterate`/`getFullList` get only `{8s}` in the same position. Final relations tuple: `.{ exp, rec, rel, wn, createName, updateName, fld, sort_ty, search, vector }`; non-relations tuple: `.{ rec, wn, createName, updateName, fld, sort_ty, search, vector }` (search=`{6s}`, vector=`{7s}` used only in getList).
  - After the branch `if/else` and BEFORE the auth block, add unconditionally:
    ```zig
      try put(alloc, w, "  getAbilities(id: string, opts?: { signal?: AbortSignal; requestKey?: string }): Promise<RecordAbilities>;\n");
    ```
- [ ] `emitCreate`: add `const tenant_field = c.options.tenant_field;` and in BOTH field loops (required + optional) add as the second guard line:
  ```zig
          if (tenant_field) |tf| if (std.mem.eql(u8, f.name, tf)) continue;
  ```
  (`emitUpdate` is `Partial<Create>` and inherits the omission.)
- [ ] `emitRecord`: inside the field loop, before the field line:
  ```zig
      if (c.options.tenant_field) |tf| if (std.mem.eql(u8, f.name, tf))
          try putf(alloc, w, "  /** Tenant-owned: `{s}` is server-stamped from the active account. */\n", .{tf});
  ```
- [ ] `emitMeta`: split the final `putf` — replace
  `try putf(alloc, w, "],\n  isAuth: {s},\n}};\n", .{...});` with:
  ```zig
      try putf(alloc, w, "],\n  isAuth: {s},\n", .{if (c.type == .auth) "true" else "false"});
      if (isSearchableCollection(c)) {
          try put(alloc, w, "  searchable: [");
          first = true;
          for (c.fields) |f| {
              if (f.hidden or !f.searchable) continue;
              if (!first) try put(alloc, w, ", ");
              first = false;
              try putf(alloc, w, "\"{s}\"", .{f.name});
          }
          try put(alloc, w, "],\n");
      }
      if (c.options.tenant_field) |tf| {
          try putf(alloc, w, "  tenant: \"{s}\",\n", .{tf});
      }
      try put(alloc, w, "};\n");
  ```
- [ ] `emitImports`: in BOTH branches add `, type RecordAbilities` to the first import line (after `type Client`), add `  type SortExpr,\n` to the typed import block (after `type CollectionMeta,`), and append the compat guard after the imports (spec §3; `export type` so a consumer's `noUnusedLocals` never flags it):
  - in-repo branch appends:
    ```
    \\
    \\// requires @zigbase/client >= 0.3.0
    \\export type _RequiresCore = import("../../../src/typed/index.js").CoreSupports_0_3;
    \\
    ```
  - package branch appends:
    ```
    \\
    \\// requires @zigbase/client >= 0.3.0
    \\export type _RequiresCore = import("@zigbase/client/typed").CoreSupports_0_3;
    \\
    ```
- [ ] `src/codegen/gen_client.zig`:
  - `schemaHash`: after `if (f.isMultiValue()) h.update("*");` add `if (f.searchable) h.update("?");`; after the per-collection fields loop add:
    ```zig
        if (c.options.tenant_field) |tf| {
            h.update("\x01tenant:");
            h.update(tf);
        }
    ```
  - `generate()`: in the "Fluent accessor types" section change the loop to:
    ```zig
        for (cols) |c| {
            try emit.emitFields(alloc, &w, c);
            try emit.emitSortUnion(alloc, &w, c);
        }
    ```
- [ ] Regenerate goldens: `mise exec zig@0.16.0 -- zig build gen-dating-client gen-dating-runtime-client`. Verify with `git diff --stat clients/typescript/test/codegen/dating/` (both files changed; schema-hash lines differ).
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect PASS (incl. the byte-exact golden test).
- [ ] Run `cd clients/typescript && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm test` — expect PASS (regenerated goldens compile against Tasks 3–6 exports; the committed `.test-d.ts` files still typecheck because `sort: "-created"` etc. fit the narrowed types).
- [ ] `git add -A && git commit -m "feat(codegen): searchable/tenant metadata, sort unions, search/vector opts, getAbilities, tenant-omitting Create, _RequiresCore guard"`

---

### Task 10: Zig emitter — generated client factory: `accounts`/`analytics`/`senders`/`withAccount`

**Files:**
- Modify: `src/codegen/gen_client.zig` (`emitClientFactory` + tests)
- Regenerate: `clients/typescript/test/codegen/dating/zbase.gen.ts`, `zbase.runtime.gen.ts`

**Interfaces:**
- Consumes: `Client.accounts/analytics/senders/withAccount` (Tasks 5, 7).
- Produces: generated `ZbClient` interface members `accounts: Client["accounts"]; analytics: Client["analytics"]; senders: Client["senders"]; withAccount(accountId: string): ZbClient;` and a `makeClient(base)` factory so `withAccount` rebuilds the typed facade. Consumed by Tasks 12–14.

- [ ] Read `src/codegen/gen_client.zig` `emitClientFactory` (lines ~148–347) as left by Task 9.
- [ ] TDD — add to gen_client.zig tests:
  ```zig
  test "generated client wires accounts/analytics/senders/withAccount" {
      var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
      defer arena.deinit();
      const a = arena.allocator();
      const cols = try miniBlog(a);
      const out = try generate(a, cols, &.{}, &.{}, &.{}, &.{}, true, "users", "BlogClient", "/api");
      inline for (.{
          // interface members (indexed-access types keep the import surface small)
          "  accounts: Client[\"accounts\"];",
          "  analytics: Client[\"analytics\"];",
          "  senders: Client[\"senders\"];",
          "  withAccount(accountId: string): BlogClient;",
          // factory: createClient delegates to a rebuildable makeClient
          "return makeClient(base);",
          "function makeClient(base: RealtimeEnabledClient): BlogClient {",
          "    accounts: base.accounts,",
          "    analytics: base.analytics,",
          "    senders: base.senders,",
          "    withAccount: (accountId: string): BlogClient => makeClient(withRealtime(base.withAccount(accountId))),",
      }) |needle| try std.testing.expect(std.mem.indexOf(u8, out, needle) != null);
  }
  ```
  Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect FAIL.
- [ ] Implement in `emitClientFactory`:
  1. **Interface tail** — both the `routes_len > 0` and the else branch currently end with a static block containing `files: FilesService; authStore/send/fetch`. Replace those static tails with formatted ones that insert the four new members right before `authStore:` (keeping `files:`/`rpc:` where they are). For the no-routes branch:
     ```zig
         try w.appendSlice(alloc, try std.fmt.allocPrint(alloc,
             \\  files: FilesService;
             \\  accounts: Client["accounts"];
             \\  analytics: Client["analytics"];
             \\  senders: Client["senders"];
             \\  withAccount(accountId: string): {0s};
             \\  authStore: Client["authStore"];
             \\  send: Client["send"];
             \\  fetch: Client["fetch"];
             \\}}
             \\
         , .{client_name}));
     ```
     and analogously for the routes branch (insert the same four lines between the `};` that closes `rpc:` and `authStore:`).
  2. **createClient split** — replace the current `export function createClient…return { db: {` emission with:
     ```zig
         try w.appendSlice(alloc, try std.fmt.allocPrint(alloc,
             \\export function createClient(url: string, opts: {0s}Options = {{}}): {0s} {{
             \\  const base: RealtimeEnabledClient = withRealtime(
             \\    baseCreateClient(url, {{
             \\      fetch: opts.fetch,
             \\      WebSocket: opts.WebSocket,
             \\      authCollection: opts.authCollection ?? "{1s}",
             \\    }}),
             \\  );
             \\  return makeClient(base);
             \\}}
             \\
             \\/** Build the typed facade over a realtime-enabled base client. All facades are
             \\ *  stateless wrappers, so `withAccount` can rebuild them cheaply per scope. */
             \\function makeClient(base: RealtimeEnabledClient): {0s} {{
             \\  return {{
             \\    db: {{
             \\
         , .{ client_name, auth_collection }));
     ```
     (Move this emission ABOVE the options-interface emission or keep order as-is — the options interface must still be emitted before `createClient`; keep the existing order: options interface first, then this block.)
  3. **Factory tail** — replace the final static `authStore/send/fetch` tail with:
     ```zig
         try w.appendSlice(alloc, try std.fmt.allocPrint(alloc,
             \\    accounts: base.accounts,
             \\    analytics: base.analytics,
             \\    senders: base.senders,
             \\    withAccount: (accountId: string): {0s} => makeClient(withRealtime(base.withAccount(accountId))),
             \\    authStore: base.authStore,
             \\    send: base.send.bind(base),
             \\    fetch: base.fetch.bind(base),
             \\  }};
             \\}}
             \\
         , .{client_name}));
     ```
- [ ] Regenerate goldens: `mise exec zig@0.16.0 -- zig build gen-dating-client gen-dating-runtime-client`.
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect PASS. Run `cd clients/typescript && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm test` — expect PASS (the regenerated goldens now reference `base.accounts` etc., which exist since Tasks 5/7).
- [ ] `git add -A && git commit -m "feat(codegen): generated client exposes accounts/analytics/senders + withAccount facade rebuild"`

---

### Task 11: Dating fixture — searchable, tenancy, `notes`, abilities, rollup, publish/track routes + equivalence test

**Files:**
- Modify: `fixtures/dating/schema.zig`, `src/codegen/typegen_cli.zig` (equivalence test)
- Regenerate: `clients/typescript/test/codegen/dating/zbase.gen.ts`, `zbase.runtime.gen.ts`

**Interfaces:**
- Produces: dating server with FTS on `profiles.bio` + `messages.body`; tenancy enabled (`auth_collection = "profiles"`); tenant-owned `notes` collection (`tenant_field = "account"`, `account` is a relation to the live `_accounts` system collection — required because abilities `.via` must name a RELATION field; provisioning allows pre-existing live targets); abilities on `notes` (update ≥ editor, delete ≥ admin); one rollup `notes_daily`; two public routes `POST /api/testing/publish` (fires `ctx.realtime().signal` + `.broadcast`) and `POST /api/testing/track` (fires `ctx.track`). Consumed by Tasks 12–14.

- [ ] Read `fixtures/dating/schema.zig` fully.
- [ ] Field flags: change the two field lines —
  `.{ .name = "bio", .type = .editor, .searchable = true },` (profiles) and
  `.{ .name = "body", .type = .text, .required = true, .searchable = true },` (messages).
- [ ] Add the route types + handlers next to the existing pure handlers:
  ```zig
  // Realtime custom-topic publish (gap-closure integration coverage): fires BOTH verbs so a
  // client sees a `signal` and a `message` frame on `topic`.
  const PublishIn = struct { topic: []const u8, note: []const u8 };
  fn testingPublish(req: *zigbase.Req(PublishIn)) zigbase.RouteError!SendWinkOut {
      req.ctx.realtime().signal(req.input.topic);
      req.ctx.realtime().broadcast(req.input.topic, .{ .note = req.input.note }) catch
          return req.fail(500, "broadcast failed");
      return .{ .ok = true, .note = req.input.note };
  }
  // Analytics capture (gap-closure integration coverage): appends one `_events` row attributed
  // to the caller + active account.
  const TrackIn = struct { name: []const u8 };
  fn testingTrack(req: *zigbase.Req(TrackIn)) zigbase.RouteError!SendWinkOut {
      req.ctx.track(req.input.name, .{ .via = "route" }) catch return req.fail(500, "track failed");
      return .{ .ok = true, .note = req.input.name };
  }
  ```
  and register them in `.routes`:
  ```zig
      .{ .method = .POST, .path = "/api/testing/publish", .handler = testingPublish, .auth = .public },
      .{ .method = .POST, .path = "/api/testing/track", .handler = testingTrack, .auth = .public },
  ```
- [ ] Add the top-level config keys to `zigbase.App(.{ … })` (siblings of `.flags`/`.routes`):
  ```zig
      .tenancy = .{ .enabled = true, .auth_collection = "profiles" },
      .abilities = .{
          .notes = .{
              .update = .{ .relationship = .{ .via = "account", .min_role = .editor } },
              .delete = .{ .relationship = .{ .via = "account", .min_role = .admin } },
          },
      },
      .analytics = .{
          .rollups = .{
              .notes_daily = .{
                  .event = "note.created",
                  .every = .{ .interval = .hourly },
                  .group_by = .{ .account = true, .time_bucket = .day },
                  .metric = .count,
              },
          },
      },
  ```
  (Exact key shapes per `docs/framework.md` §Multi-tenancy/§Abilities/§Product analytics; if `.every`'s Schedule literal differs, grep `docs/framework.md`/`src/framework.zig` for the accepted form and adjust — a compile error here is loud by design.)
- [ ] Add the `notes` collection to `.collections` (after `subscriptions`):
  ```zig
      // Tenant-owned (gap-closure coverage): `account` is a RELATION (abilities .via requires
      // one) to the live `_accounts` system collection; the server stamps it on create.
      .notes = .{
          .fields = .{
              .{ .name = "account", .type = .relation, .target = "_accounts" },
              .{ .name = "title", .type = .text, .required = true },
              .{ .name = "body", .type = .text },
          },
          .tenant_field = "account",
          .rules = .{ .list = "@request.auth.id != \"\"", .view = "@request.auth.id != \"\"", .create = "@request.auth.id != \"\"", .update = "@request.auth.id != \"\"", .delete = "@request.auth.id != \"\"" },
      },
  ```
- [ ] Extend the equivalence test in `src/codegen/typegen_cli.zig` (`"equivalence: data-dir runtime path reproduces the comptime collection surface"`): add a searchable field to `posts` and one tenant-owned collection to `specs`:
  ```zig
          // inside the posts fields slice, append:
          .{ .id = "", .name = "summary", .options = .{ .text = .{} }, .searchable = true },
  ```
  ```zig
          // as a third collection in specs:
          .{ .id = "", .name = "projects", .options = .{ .tenant_field = "account" }, .fields = &.{
              .{ .id = "", .name = "title", .options = .{ .text = .{} } },
              .{ .id = "", .name = "account", .options = .{ .text = .{} } },
          } },
  ```
  (No other change — the test already asserts `expectEqualStrings(ct, rt)`, which now covers `searchable`/`tenant` round-tripping through provision → read-back.)
- [ ] Build the fixture as a server to catch comptime errors early: `mise exec zig@0.16.0 -- zig build dating-server` — expect success.
- [ ] Regenerate goldens: `mise exec zig@0.16.0 -- zig build gen-dating-client gen-dating-runtime-client`. Inspect `git diff clients/typescript/test/codegen/dating/zbase.gen.ts` — expect: `Note`/`NoteCreate`/`NotesService` types (Create WITHOUT `account`), `searchable: ["bio"]` in `profilesMeta`, `searchable: ["body"]` in `messagesMeta`, `tenant: "account"` in `notesMeta`, the abilities doc comment on `NotesService`, and `testingPublish`/`testingTrack` rpc members.
- [ ] Run `mise exec zig@0.16.0 -- zig build test --summary all` — expect PASS (incl. extended equivalence + golden tests).
- [ ] Run `cd clients/typescript && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm test` — expect PASS. Then run the EXISTING integration suite to prove the fixture change doesn't regress it (spec §12: tenancy only affects tenant-owned collections): `mise exec node@24 -- npm run test:integration` — expect PASS.
- [ ] `git add -A && git commit -m "feat(fixtures): dating gains searchable fields, tenancy + notes, abilities, rollup, publish/track routes"`

---

### Task 12: Generated-tier type-level tests (`.test-d.ts`)

**Files:**
- Modify: `clients/typescript/test/codegen/dating/zbase.gen.test-d.ts`

**Interfaces:**
- Consumes: the Task 11 goldens (`Note`, `NoteCreate`, `NotesService`, sort unions, search/vector gating, `withAccount`).

- [ ] Read the current `zbase.gen.test-d.ts` (imports + function-per-area style, `// @ts-expect-error` markers, checked by `npm run typecheck`).
- [ ] Append (extending the existing import list with `Note, NoteCreate, ProfileSort`):
  ```ts
  // --- search & vector gating (0.3.0) ------------------------------------------
  async function searchAndVector() {
    await zb.db.messages.getList({ search: "hello world" }); // messages.body is searchable
    await zb.db.profiles.getPage({ search: "bio words" });   // search works in cursor mode
    // @ts-expect-error tags has no searchable fields -> no `search` key
    await zb.db.tags.getList({ search: "x" });
    await zb.db.subscriptions.getList({ vector: { field: "metadata", metric: "cosine", values: [0.1] } });
    // @ts-expect-error vector.field is narrowed to the collection's json fields
    await zb.db.subscriptions.getList({ vector: { field: "plan", values: [0.1] } });
    // @ts-expect-error messages has no json fields -> no `vector` key
    await zb.db.messages.getList({ vector: { field: "body", values: [1] } });
    // @ts-expect-error vector is offset-only -> absent from getPage
    await zb.db.subscriptions.getPage({ vector: { field: "metadata", values: [1] } });
  }

  // --- typed sort (0.3.0) -------------------------------------------------------
  async function typedSort() {
    await zb.db.profiles.getList({ sort: "-age" });
    await zb.db.profiles.getList({ sort: ["-age", "created"] });
    expectTypeOf<ProfileSort>().toMatchTypeOf<string>();
    // @ts-expect-error "nope" is not a sortable field
    await zb.db.profiles.getList({ sort: "nope" });
    // @ts-expect-error json fields are not sortable
    await zb.db.subscriptions.getList({ sort: "metadata" });
  }

  // --- tenancy (0.3.0) ----------------------------------------------------------
  function tenancyTypes() {
    // The tenant field is readable on the record...
    expectTypeOf<Note["account"]>().toEqualTypeOf<string>();
    // ...but absent from the create payload (server-stamped).
    // @ts-expect-error `account` is server-stamped; NoteCreate omits it entirely
    const bad: NoteCreate = { title: "t", account: "a1" };
    void bad;
    // withAccount returns the SAME typed client shape.
    const scoped = zb.withAccount("acct1");
    expectTypeOf(scoped).toEqualTypeOf<typeof zb>();
    void scoped.db.notes;
  }

  // --- abilities (0.3.0): present on EVERY generated service --------------------
  async function abilities() {
    const ab = await zb.db.notes.getAbilities("n1");
    expectTypeOf(ab).toEqualTypeOf<{ view: boolean; update: boolean; delete: boolean }>();
    await zb.db.tags.getAbilities("t1", { requestKey: "ab" });
  }

  // --- pass-through services (0.3.0) --------------------------------------------
  async function passthroughs() {
    await zb.accounts.activate("acct1");
    await zb.analytics.events({ name: "note.created", since: new Date() });
    await zb.senders.list();
  }
  ```
  NOTE: `expectTypeOf(ab).toEqualTypeOf<{...}>()` must match `RecordAbilities` structurally; if `toEqualTypeOf` balks at the named interface, use `expectTypeOf(ab.update).toEqualTypeOf<boolean>()` per member instead.
- [ ] Run `cd clients/typescript && mise exec node@24 -- npm run typecheck` — expect PASS (every `@ts-expect-error` line suppresses a REAL error; tsc fails if any is unused, which is the negative-case assertion).
- [ ] Run `mise exec node@24 -- npm test` — expect PASS (no runtime change).
- [ ] `git add -A && git commit -m "test(codegen): type-level coverage for search/vector gating, typed sort, tenant omission, abilities, withAccount"`

---

### Task 13: Integration tests A — search/`in`/sort + tenancy + abilities (live dating-server)

**Files:**
- Create: `clients/typescript/test/integration/gap-search.integration.test.ts`, `clients/typescript/test/integration/gap-tenancy.integration.test.ts`

**Interfaces:**
- Consumes: Task 11 fixture (searchable `messages.body`, `notes`, abilities, tenancy), the generated client (`test/codegen/dating/zbase.gen.js`), harness `startAppServer`/`DATING_BIN`/`superuserToken`.

- [ ] Read `clients/typescript/test/integration/dating.integration.test.ts` for the `authedProfile`/`waitFor` conventions and `harness.ts` exports.
- [ ] Create `gap-search.integration.test.ts`:
  ```ts
  import { describe, it, expect, beforeAll, afterAll } from "vitest";
  import { startAppServer, DATING_BIN, type TestServer } from "./harness.js";
  import { createClient } from "../codegen/dating/zbase.gen.js";
  import { createClient as createBaseClient } from "../../src/index.js";
  import { isZigbaseError } from "../../src/errors.js";

  let server: TestServer;
  beforeAll(async () => {
    server = await startAppServer({ bin: DATING_BIN });
  });
  afterAll(() => server?.stop());

  async function authedProfile(email: string) {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
    const profile = await zb.db.profiles.create({
      email,
      password: "member-pass-1",
      passwordConfirm: "member-pass-1",
      name: email.split("@")[0]!,
      age: 30,
    });
    await zb.db.profiles.authWithPassword(email, "member-pass-1");
    return { zb, profile };
  }

  describe("search / native in / typed sort (live)", () => {
    it("FTS hit + miss on messages.body; 400 on an unsearchable collection", async () => {
      const { zb, profile } = await authedProfile("fts@d.app");
      await zb.db.messages.create({ from: profile.id, to: profile.id, body: "zig database rocks" });
      await zb.db.messages.create({ from: profile.id, to: profile.id, body: "unrelated chatter" });

      const hit = await zb.db.messages.getList({ search: "database" });
      expect(hit.items.length).toBe(1);
      expect(hit.items[0]!.body).toContain("database");
      const miss = await zb.db.messages.getList({ search: "nomatchterm" });
      expect(miss.items.length).toBe(0);

      // Unsearchable collection: the typed tier rejects at compile time; the SERVER 400 is
      // proven through the base client.
      const base = createBaseClient(server.url);
      try {
        await base.collection("tags").getList(1, 30, { search: "x" });
        expect.unreachable();
      } catch (e) {
        expect(isZigbaseError(e)).toBe(true);
        expect((e as { status: number }).status).toBe(400);
      }
    });

    it("vector on a default (non -Dvector) build answers a clean 400", async () => {
      const { zb } = await authedProfile("vec@d.app");
      try {
        await zb.db.subscriptions.getList({ vector: { field: "metadata", values: [0.1, 0.2] } });
        expect.unreachable();
      } catch (e) {
        expect(isZigbaseError(e)).toBe(true);
        expect((e as { status: number }).status).toBe(400);
      }
    });

    it("native `in` round-trips against the live grammar (incl. empty list)", async () => {
      const { zb, profile } = await authedProfile("innat@d.app");
      await zb.db.photos.create({ owner: profile.id, caption: "alpha" });
      await zb.db.photos.create({ owner: profile.id, caption: "beta" });
      await zb.db.photos.create({ owner: profile.id, caption: "gamma" });

      const some = await zb.db.photos.getList({
        where: { owner: profile.id, caption: { in: ["alpha", "gamma"] } },
      });
      expect(some.items.map((p) => p.caption).sort()).toEqual(["alpha", "gamma"]);

      const none = await zb.db.photos.getList({
        where: { owner: profile.id, caption: { in: [] } },
      });
      expect(none.items.length).toBe(0);
    });

    it("typed sort accepts single + array forms", async () => {
      const { zb, profile } = await authedProfile("sort@d.app");
      await zb.db.photos.create({ owner: profile.id, caption: "b" });
      await zb.db.photos.create({ owner: profile.id, caption: "a" });
      const list = await zb.db.photos.getList({
        where: { owner: profile.id },
        sort: ["caption", "-created"],
      });
      expect(list.items.map((p) => p.caption)).toEqual(["a", "b"]);
    });
  });
  ```
- [ ] Create `gap-tenancy.integration.test.ts`:
  ```ts
  import { describe, it, expect, beforeAll, afterAll } from "vitest";
  import { startAppServer, superuserToken, DATING_BIN, type TestServer } from "./harness.js";
  import { createClient } from "../codegen/dating/zbase.gen.js";
  import { isZigbaseError } from "../../src/errors.js";

  let server: TestServer;
  let suToken: string;
  beforeAll(async () => {
    server = await startAppServer({ bin: DATING_BIN });
    suToken = await superuserToken(server);
  });
  afterAll(() => server?.stop());

  async function su(path: string, body: Record<string, unknown>): Promise<Record<string, unknown>> {
    const res = await fetch(`${server.url}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", Authorization: `Bearer ${suToken}` },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`${path} failed: ${res.status} ${await res.text()}`);
    return (await res.json()) as Record<string, unknown>;
  }
  const seedAccount = async (slug: string) =>
    (await su("/api/collections/_accounts/records", { name: slug, slug, owner_user: "", status: "active" })).id as string;
  const seedMembership = (account: string, user: string, role: string) =>
    su("/api/collections/_memberships/records", { account, user_collection: "profiles", user, role, status: "active" });

  async function authedProfile(email: string) {
    const zb = createClient(server.url, { WebSocket: globalThis.WebSocket });
    const profile = await zb.db.profiles.create({
      email, password: "member-pass-1", passwordConfirm: "member-pass-1",
      name: email.split("@")[0]!, age: 30,
    });
    await zb.db.profiles.authWithPassword(email, "member-pass-1");
    return { zb, profile };
  }

  describe("tenancy + abilities (live)", () => {
    it("activate -> scope; withAccount scoping; stamped tenant field; cross-account fail closed", async () => {
      const { zb: alice, profile: aliceP } = await authedProfile("alice@t.app");
      const acctA = await seedAccount("acme");
      const acctB = await seedAccount("beta");
      await seedMembership(acctA, aliceP.id, "editor");
      await seedMembership(acctB, aliceP.id, "editor");

      // activate verifies membership and returns the scope
      const scope = await alice.accounts.activate(acctA);
      expect(scope).toEqual({ account: acctA, role: "editor" });

      // withAccount + create: the server STAMPS the tenant field (NoteCreate has no `account`)
      const inA = alice.withAccount(acctA);
      const inB = alice.withAccount(acctB);
      const noteA = await inA.db.notes.create({ title: "a-note" });
      expect(noteA.account).toBe(acctA);
      await inB.db.notes.create({ title: "b-note" });

      // scoped list isolation
      const listA = await inA.db.notes.getList({});
      expect(listA.items.map((n) => n.title)).toEqual(["a-note"]);
      const listB = await inB.db.notes.getList({});
      expect(listB.items.map((n) => n.title)).toEqual(["b-note"]);

      // a non-member scope fails closed on create (no active account context)
      const { zb: mallory } = await authedProfile("mallory@t.app");
      try {
        await mallory.withAccount(acctA).db.notes.create({ title: "steal" });
        expect.unreachable();
      } catch (e) {
        expect(isZigbaseError(e)).toBe(true);
        expect((e as { status: number }).status).toBeGreaterThanOrEqual(400);
      }
      // ...and sees nothing on list
      const stolen = await mallory.withAccount(acctA).db.notes.getList({});
      expect(stolen.items.length).toBe(0);
    });

    it("abilities: role ladder decides update/delete; non-viewable is a 404", async () => {
      const { zb: owner, profile: ownerP } = await authedProfile("owner@t.app");
      const { zb: viewer, profile: viewerP } = await authedProfile("viewer@t.app");
      const { zb: outsider } = await authedProfile("outsider@t.app");
      const acct = await seedAccount("abilities-acct");
      await seedMembership(acct, ownerP.id, "editor");
      await seedMembership(acct, viewerP.id, "viewer");

      const note = await owner.withAccount(acct).db.notes.create({ title: "guarded" });

      // editor: update yes (min_role editor), delete no (min_role admin)
      const abEditor = await owner.withAccount(acct).db.notes.getAbilities(note.id);
      expect(abEditor).toEqual({ view: true, update: true, delete: false });

      // viewer member: sees it, cannot update/delete
      const abViewer = await viewer.withAccount(acct).db.notes.getAbilities(note.id);
      expect(abViewer).toEqual({ view: true, update: false, delete: false });

      // outsider (no membership -> no tenant scope): 404, never reveals existence
      try {
        await outsider.withAccount(acct).db.notes.getAbilities(note.id);
        expect.unreachable();
      } catch (e) {
        expect(isZigbaseError(e)).toBe(true);
        expect((e as { status: number }).status).toBe(404);
      }
    });
  });
  ```
  NOTE for the implementer: if `_accounts` create rejects unknown keys (`owner_user`), read `src/migrations.zig`'s `0014_tenancy` for the exact `_accounts` field set and adjust the seed body; the assertions are the contract.
- [ ] Run `cd clients/typescript && mise exec node@24 -- npm run test:integration` — expect PASS (all files, incl. pre-existing ones). Rerun once on a `ListenError`-only failure (known port-race flake).
- [ ] `git add -A && git commit -m "test(integration): live search/in/sort, tenancy scoping + activate, abilities role ladder"`

---

### Task 14: Integration tests B — analytics, senders, realtime topics + `__features`

**Files:**
- Create: `clients/typescript/test/integration/gap-services.integration.test.ts`, `clients/typescript/test/integration/gap-topics.integration.test.ts`

**Interfaces:**
- Consumes: Tasks 1–2 wire fixes (live), Task 7/8 client surfaces, Task 11 fixture routes (`/api/testing/publish`, `/api/testing/track`, rollup `notes_daily`, dating flags).

- [ ] Create `gap-services.integration.test.ts` (same harness/seed helpers as Task 13 — copy `su`/`seedAccount`/`seedMembership`/`authedProfile` locally; integration files are self-contained by convention):
  ```ts
  // ...imports + beforeAll/afterAll identical to gap-tenancy.integration.test.ts...
  import { createClient as createBaseClient } from "../../src/index.js";

  describe("analytics + senders (live)", () => {
    it("events feed after seeded writes; anon 401; rollup 404-undeclared + declared envelope", async () => {
      const { zb, profile } = await authedProfile("ana@t.app");
      const acct = await seedAccount("analytics-acct");
      await seedMembership(acct, profile.id, "editor");
      const scoped = zb.withAccount(acct);

      // seed one event through the fixture's track route (server resolves actor/account)
      await scoped.rpc.testingTrack({ name: "note.created" });

      const feed = await scoped.analytics.events({ name: "note.created", limit: 10 });
      expect(feed.items.length).toBeGreaterThanOrEqual(1);
      expect(feed.items[0]).toMatchObject({ name: "note.created", account: acct });

      // anonymous -> 401
      await expect(createBaseClient(server.url).analytics.events()).rejects.toMatchObject({ status: 401 });
      // undeclared rollup -> 404
      await expect(scoped.analytics.rollup("nope")).rejects.toMatchObject({ status: 404 });
      // declared rollup -> items envelope (buckets may be empty before the hourly job runs)
      const buckets = await scoped.analytics.rollup("notes_daily");
      expect(Array.isArray(buckets.items)).toBe(true);
    });

    it("senders: create pending -> {items} list -> wrong-token verify 404", async () => {
      const { zb, profile } = await authedProfile("snd@t.app");
      const acct = await seedAccount("senders-acct");
      await seedMembership(acct, profile.id, "editor");
      const scoped = zb.withAccount(acct);

      const created = await scoped.senders.create("noreply@acme.example");
      expect(created.status).toBe("pending");
      expect(created.email).toBe("noreply@acme.example");

      const list = await scoped.senders.list(); // {items} envelope — requires >= 0.10.0
      expect(list.items.map((i) => i.email)).toContain("noreply@acme.example");
      expect(list.items[0]).toHaveProperty("verified_at");

      // wrong token collapses to 404 (non-oracle); happy-path verify is skipped —
      // the token only travels by email.
      await expect(scoped.senders.verify(created.id, "wrong-token")).rejects.toMatchObject({ status: 404 });
    });
  });
  ```
- [ ] Create `gap-topics.integration.test.ts`:
  ```ts
  import { describe, it, expect, beforeAll, afterAll } from "vitest";
  import { startAppServer, superuserToken, DATING_BIN, type TestServer } from "./harness.js";
  import { createClient } from "../../src/index.js";
  import { withRealtime, type TopicMessage } from "../../src/realtime-entry.js";

  let server: TestServer;
  let suToken: string;
  beforeAll(async () => {
    server = await startAppServer({ bin: DATING_BIN });
    suToken = await superuserToken(server);
  });
  afterAll(() => server?.stop());

  function waitFor(cond: () => boolean, timeoutMs = 8000): Promise<void> {
    const deadline = Date.now() + timeoutMs;
    return new Promise((resolve, reject) => {
      const tick = () => {
        if (cond()) return resolve();
        if (Date.now() > deadline) return reject(new Error("timeout waiting for condition"));
        setTimeout(tick, 25);
      };
      tick();
    });
  }

  describe("custom topics + __features (live, server >= 0.10.0 frames)", () => {
    it("receives both kinds from ctx.realtime().signal/.broadcast via the publish route", async () => {
      const zb = withRealtime(createClient(server.url, { WebSocket: globalThis.WebSocket }));
      const got: TopicMessage[] = [];
      const unsub = await zb.realtime.subscribeTopic("orders", (m) => got.push(m));

      await zb.send("POST", "/api/testing/publish", { body: { topic: "orders", note: "hi" } });
      await waitFor(() => got.length >= 2);

      expect(got).toContainEqual({ topic: "orders", kind: "signal" });
      const msg = got.find((m) => m.kind === "message");
      expect(msg?.data).toEqual({ note: "hi" });
      unsub();
    });

    it("a flag-override write emits the standard signal on __features", async () => {
      const zb = withRealtime(createClient(server.url, { WebSocket: globalThis.WebSocket }));
      const got: TopicMessage[] = [];
      await zb.realtime.subscribeTopic("__features", (m) => got.push(m));

      const res = await fetch(`${server.url}/api/settings/flag:device_link_v2`, {
        method: "PUT",
        headers: { "content-type": "application/json", Authorization: `Bearer ${suToken}` },
        body: JSON.stringify({ value: "true" }),
      });
      expect(res.ok).toBe(true);

      await waitFor(() => got.length >= 1);
      expect(got[0]).toEqual({ topic: "__features", kind: "signal" });
    });
  });
  ```
- [ ] Run `cd clients/typescript && mise exec node@24 -- npm run test:integration` — expect PASS (rerun once on a `ListenError`-only flake).
- [ ] `git add -A && git commit -m "test(integration): live analytics/senders envelopes, custom-topic frames, __features signal"`

---

### Task 15: Docs, changelog fragment, version bump, final verification

**Files:**
- Modify: `docs/typescript-sdk.md` + `site/src/content/docs/typescript-sdk.md`, `clients/typescript/README.md`, `clients/typescript/package.json`
- Create: `changelog.d/sdk-090-gap-closure.md`

**Interfaces:** none produced — documentation + version of everything above.

- [ ] Read `docs/typescript-sdk.md` (809 lines; section list: Install / tiers / client / auth / Records / Pagination / Files / Typed client / Runtime introspection / Typed RPC / Typed auth methods / Typed feature state / Realtime + live store / Runtime overrides / Error handling / fields / requestKey / escape hatches / See also).
- [ ] Add the new sections (each with a short runnable example, doc-commented server floors):
  1. **"Search & vector"** (after "Records"): `getList({ search })` on all list reads; the exported `vectorSpec`/`VectorQuery` + `getList({ vector })` (offset-only; server `-Dvector` builds; list the server's 400 messages verbatim per spec §4.1 — the client adds no pre-flight). Typed tier: `search` only on searchable collections, `vector.field` narrowed to json fields.
  2. **"Account scoping (multi-tenancy)"** (after "Auth + stores"): `accountId` option, `withAccount(id)` (shared AuthStore — one principal, many scopes), `accounts.activate(id)` + the `zb_account` cookie caveat (browser same-origin only; API/SSR should prefer `withAccount`; the SDK never reads the cookie). Note the documented limitation: **no realtime tenant scoping** — browser WebSockets cannot carry `X-Account-Id` (spec §2).
  3. **"Abilities"**: `getAbilities(id)` on base + every generated service; 404-non-oracle semantics; `view` always true on 200.
  4. **"Analytics"**: `zb.analytics.events(...)` / `.rollup(name, ...)`; snake_case wire fields kept; `Date` params → ISO.
  5. **"Senders"**: `zb.senders.list/create/verify`; `list` requires server ≥ 0.10.0 (`{items}`); the token is emailed, never returned; 429 throttle mapping.
  6. **"Custom topics"** (inside/after "Realtime + live store"): `subscribeTopic`/`unsubscribeTopic`, `TopicMessage` `kind: "signal" | "message"`, `__features` as `subscribeTopic("__features", cb)` (server ≥ 0.10.0).
  7. **"Typed sort & native `in`"** note in the Typed client section: `sort` narrowed to `{N}Sort | {N}Sort[]` in newly generated files; `in` now compiles to the native operator — **a `{ in: [...] }` where-clause 400s against a pre-0.9.0 server** (spec §3, no gating).
  8. **A "Server compatibility" matrix** — reproduce the spec §3 table (client 0.3.0 features × server <0.9.0 / 0.9.0 / ≥0.10.0), plus the generated-code coupling paragraph (`CoreSupports_0_3` marker: files generated by the 0.10.0 binary need client ≥ 0.3.0; old generated files keep working on the new core).
- [ ] Mirror ALL of the above into `site/src/content/docs/typescript-sdk.md` (adjust internal links to the site's `./framework`-style form as the existing mirror does — diff the two files' headers first).
- [ ] `clients/typescript/README.md`: add a feature-bullets block near the top (search/vector, account scoping, abilities, analytics, senders, custom topics, typed sort + native `in`) with one line: `New in 0.3.0 — requires ZigBase >= 0.9.0 for the new surfaces; senders and the __features signal require >= 0.10.0.`
- [ ] `clients/typescript/package.json`: `"version": "0.3.0"`.
- [ ] Create `changelog.d/sdk-090-gap-closure.md` (sections must be from the recognized set; consumer-facing):
  ```markdown
  ### Breaking

  - `GET /api/senders` now returns `{"items":[…]}` instead of a bare JSON array (unified with the analytics endpoints' envelope).
  - The `__features` realtime channel now emits the standard `{"type":"signal","topic":"__features"}` frame instead of the bespoke `{"type":"features.changed"}` frame.

  ### Features

  - `@zigbase/client` 0.3.0: full-text `search` + structured `vector` queries (`vectorSpec`) on list reads, with per-collection compile-time gating in the generated tiers.
  - `@zigbase/client` 0.3.0: multi-tenant account scoping — `accountId` option, `client.withAccount(id)` scoped views (shared auth store), and `accounts.activate(id)`.
  - `@zigbase/client` 0.3.0: per-record abilities — `getAbilities(id)` on the base and every generated collection service.
  - `@zigbase/client` 0.3.0: analytics read APIs — `client.analytics.events(...)` and `client.analytics.rollup(name, ...)`.
  - `@zigbase/client` 0.3.0: verified sender management — `client.senders.list/create/verify` (list requires ZigBase >= 0.10.0).
  - `@zigbase/client` 0.3.0: realtime custom topics — `subscribeTopic`/`unsubscribeTopic` deliver `signal` and `message` frames (feature-change notifications are `subscribeTopic("__features", cb)`).
  - Generated TS clients surface `searchable`/`tenant` schema metadata: typed `search`/`vector` options, per-collection sort unions (`sort: "-age" | [...]`), tenant fields omitted from `*Create`/`*Update`, and `accounts`/`analytics`/`senders`/`withAccount` on the generated client.

  ### Changed

  - The typed where-DSL `in` operator now compiles to the native `field in (…)` filter operator (requires ZigBase >= 0.9.0; against older servers it is a 400).
  - Clients regenerated by this release require `@zigbase/client` >= 0.3.0 (enforced by a `CoreSupports_0_3` marker type with a self-explaining typecheck error).
  ```
  (The internal `broadcastTopic` refactor gets no fragment line — invisible to consumers, per spec §13.)
- [ ] Build the site: `cd site && npm install && npm run build` — expect success (from repo root: `cd site && mise exec node@24 -- npm run build` if node isn't activated).
- [ ] Final full verification, in order:
  1. `mise exec zig@0.16.0 -- zig build test --summary all` → `Build Summary: … passed`
  2. `mise exec zig@0.16.0 -- zig build gen-dating-client-check gen-dating-runtime-client-check` → clean (goldens not stale)
  3. `cd clients/typescript && mise exec node@24 -- npm run typecheck && mise exec node@24 -- npm test && mise exec node@24 -- npm run test:integration` → all pass
  4. `cd ../.. && mise exec python@3.13 -- python -m pytest tests/admin/test_realtime.py -q` → `2 passed`
- [ ] `git add -A && git commit -m "docs(sdk): 0.3.0 gap-closure docs + changelog fragment; bump @zigbase/client to 0.3.0"`

---

## Self-review: spec coverage map

- §3 versioning: package 0.3.0 + TYPED_CORE_VERSION 0.2.0 (Tasks 4, 15); `CoreSupports_0_3` + `_RequiresCore` guard (Tasks 4, 9); schema-hash folding (Task 9); release coupling documented only (Task 15; `build.zig.zon` untouched per Global Constraints).
- §4 search/vector: base (Task 3), typed gating + emitter (Task 9), tests (Tasks 3, 9, 12, 13).
- §5 native `in` + typed sort: Task 4 (core), Task 9 (emitter unions + narrowing), Tasks 12–13 (type-level + live round-trip).
- §6 tenancy: Task 5 (base), Task 9 (meta/Create omission/record doc comment), Task 10 (generated `withAccount`/`accounts`), Tasks 11–13.
- §7 abilities: Task 6 (base+typed runtime), Task 9 (unconditional emission + doc comment), Tasks 12–13.
- §8 analytics: Task 7; Task 10 pass-through; Task 14 live.
- §9 senders: Task 2 (server wire fix + docs), Task 7 (client), Task 10 (pass-through), Task 14 (live).
- §10 topics: Task 1 (server envelope + `__features` + browser test), Task 8 (client routing/API), Task 11 (publish route), Task 14 (live both kinds + `__features`).
- §11 codegen: Tasks 9–10 (all emitter bullets), Task 11 (equivalence extension).
- §12 testing: every table row is mapped above; goldens regenerated only by the generator (Tasks 9–11); `exports.test.ts`/`typed-exports.test.ts` updated (Tasks 3–7, 4).
- §13 docs/release: Task 15 (docs + mirrors + README + fragment + site build); wire-fix doc updates folded into Tasks 1–2.
