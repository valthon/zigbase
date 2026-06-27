# Theme A3 — Breaking Ctx-First Handler Reshape Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `*Ctx` the primary object consumers receive — untyped routes become `fn(*Ctx) !Response`, typed routes get `ctx` on `Req`, record hooks become `fn(*Ctx, *RecordEvent) !void`, jobs become `fn(*Ctx, *JobEvent) !void` — and retire the scattered `reader()/writer()/data()` surface, the `caps()` shim, and the public `Data` re-export.

**Architecture:** `Ctx` gains request/user accessors and a thin `issueSession` shim so it can fully serve route handlers. The route-invocation site (`server.zig`), the typed-route thunk (`route_types.zig`), the record-hook dispatcher + emitter (`events.zig`, `api/records.zig`), and the scheduler job call site are each switched to construct and pass a `*Ctx`. Because typed handlers keep the `fn(*Req(In)) !Out` shape (only `Req` gains a `ctx` field), `HandlerInput`/`HandlerOutput` reflection is unchanged and the TS codegen (`gen_client.zig`/`rpc.zig`/`rpc_ts.zig`) needs no changes. All three example apps and the docs/site are migrated; a Breaking changelog fragment is added.

**Tech Stack:** Zig 0.16.0, `std.http`, TS SDK codegen.

## Global Constraints

- Zig 0.16.0 exactly; authoritative signal `Build Summary: N/N tests passed` (`--summary all`).
- **This is a breaking change** (pre-1.0, accepted). Every custom handler/hook/job signature changes; all three examples and docs must compile/pass in the same change set.
- `root.zig` is the unit-test root and public surface.
- Single non-reentrant pool writer — route handlers acquire via `Ctx` (never hold it across `ctx.http`).
- **Depends on Plans A1 and A2**; execute them first.
- The browser/pytest suite catches end-to-end regressions a green `zig build test` hides — run it (memory: run-browser-suite-after-integration).
- Keep docs/site/examples in sync (memory: keep-published-docs-and-examples-in-sync).
- Never edit `CHANGELOG.md`; add a `changelog.d/<slug>.md` fragment.

---

## File Structure

- Modify `src/ctx.zig` — add `request: ?*http.RequestCtx`, `user` accessor, `issueSession` shim.
- Modify `src/server.zig` (~`server.zig:189-194`) — build a `Ctx` and pass it to the untyped handler.
- Modify `src/route_types.zig` — add `ctx: *Ctx` to `Req`; `makeThunk` builds the `Ctx`; route `req.fail`/`param` delegate to it.
- Modify `src/events.zig` — `RouteHandler`/`RecordHandler`/`JobTask`/`LifecycleHandler` type changes; `buildRecordDispatcher` passes `*Ctx`; drop `caps()`, `reader()`, `writer()`, `RouteEvent.issueSession`; keep `RecordEvent`/`JobEvent` as payloads.
- Modify `src/api/records.zig` — `emitRecord` builds a `Ctx` and calls hooks as `(ctx, ev)`.
- Modify the scheduler job call site (where `JobTask` is invoked) — build a `Ctx`, call `(ctx, ev)`.
- Modify `src/root.zig` — remove `pub const Data` re-export; keep `Ctx`.
- Modify `examples/blog`, `examples/golfsim`, `examples/plugins` — every handler/hook/job signature + DB access.
- Modify `docs/framework.md` + `site/src/content/` mirror.
- Create `changelog.d/ctx-first-reshape.md`.

**Interfaces produced:**

```zig
// src/ctx.zig (additions)
request: ?*http.RequestCtx = null,
pub const User = struct { id: []const u8, collection: []const u8, is_superuser: bool };
pub fn user(self: *Ctx) ?User;                  // derived from rctx
pub fn issueSession(self: *Ctx, collection: []const u8, record_id: []const u8) !auth_helpers.Issued;

// src/events.zig (changed handler types)
pub const RouteHandler = *const fn (ctx: *Ctx) anyerror!http.Response;
pub const RecordHandler = *const fn (ctx: *Ctx, ev: *RecordEvent) anyerror!void;
pub const JobTask = *const fn (ctx: *Ctx, ev: *JobEvent) anyerror!void;
pub const LifecycleHandler = *const fn (ctx: *Ctx, ev: *LifecycleEvent) void;

// src/route_types.zig (Req gains)
ctx: *Ctx,   // typed handlers reach capabilities via req.ctx
```

---

## Task 1: `Ctx` request/user/issueSession (additive prep)

**Files:**
- Modify: `src/ctx.zig`, `src/root.zig`

**Interfaces:**
- Consumes: `http.RequestCtx`, `request.RequestContext`, `auth_helpers.issueSession` (`src/auth_helpers.zig`).
- Produces: `Ctx.request` field, `Ctx.user()`, `Ctx.issueSession()`.

- [ ] **Step 1: Write the failing test**

```zig
test "ctx.user() reflects the resolved auth identity; anonymous is null" {
    const env = try CtxTestEnv.init();
    defer env.deinit();
    var anon = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{} };
    defer anon.deinit();
    try std.testing.expect(anon.user() == null);
    // A superuser rctx yields a User with is_superuser=true.
    var su = Ctx{ .app = &env.app, .arena = env.arena.allocator(), .rctx = .{ .is_superuser = true } };
    defer su.deinit();
    try std.testing.expect(su.user().?.is_superuser);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `user`/`request` undefined.

- [ ] **Step 3: Write minimal implementation**

Add `request: ?*http.RequestCtx = null` to `Ctx`. Derive `User` from `rctx` (inspect `request.RequestContext` for the auth record + `is_superuser`; map its identity id/collection). Add the `issueSession` shim delegating to `auth_helpers.issueSession` using `self.request.?` and an acquired writer (mirror the old `RouteEvent.issueSession` at `events.zig:155-159`, but sourced from `Ctx`). Document that full session verbs (`clearSession`, refresh/revoke) arrive with Theme D.

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/ctx.zig src/root.zig
git commit -m "feat(ctx): request/user accessors + issueSession shim"
```

---

## Task 2: Untyped route handlers become `fn(*Ctx) !Response`

**Files:**
- Modify: `src/events.zig` (`RouteHandler`, `isUntypedHandler`, `buildRoutes`, `RouteEvent` usage), `src/server.zig` (`server.zig:189-194`)

**Interfaces:**
- Consumes: `Ctx` (Task 1).
- Produces: `RouteHandler = *const fn(ctx: *Ctx) anyerror!http.Response`; `isUntypedHandler` detects `fn(*Ctx) !Response`; `server.zig` builds a `Ctx` (with `.request`, `.rctx`) and calls the handler.

- [ ] **Step 1: Update the events.zig unit tests first (they encode the old shape)**

Change the untyped-handler test bodies (`events.zig:687-723`, `events.zig:790+`) to the new `fn(*Ctx) !http.Response` shape. These edits make the suite assert the new contract.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — type mismatch (`RouteHandler` still expects `*RouteEvent`).

- [ ] **Step 3: Implement**

- In `src/events.zig`: change `RouteHandler` to `*const fn (ctx: *Ctx) anyerror!http.Response`; update `isUntypedHandler` to detect a single `*Ctx` param; `buildRoutes`/`routeMeta` `untyped` detection follows. Keep `RouteEvent` struct only if still needed internally; otherwise remove it and its `reader/writer/issueSession` methods (those capabilities now live on `Ctx`).
- In `src/server.zig:189-194`: build the `Ctx`:
  ```zig
  var rctx = request.RequestContext{ .auth = ..., .is_superuser = ..., .method = @tagName(ctx.method) };
  var cx = Ctx{ .app = app, .arena = ctx.allocator, .rctx = rctx, .request = ctx, .bound_conn = null };
  defer cx.deinit();
  return rt.handler(&cx) catch |e| cx.errorResponse(e); // uses A1 error mapping
  ```
  (Replace the old `RouteEvent` construction; route the caught error through `Ctx.errorResponse` from A1 instead of the ad-hoc mapping.)

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (examples not yet migrated — defer their build to Task 7; if `zig build` compiles examples, migrate the single untyped golfsim handler `calendarFeed` now to keep the tree green).

- [ ] **Step 5: Commit**

```bash
git add src/events.zig src/server.zig
git commit -m "feat!(routes): untyped route handlers receive *Ctx"
```

---

## Task 3: Typed routes — `Req` gains `ctx`, `makeThunk` builds it

**Files:**
- Modify: `src/route_types.zig` (`Req`, `makeThunk` at `route_types.zig:45-71,167-213`)

**Interfaces:**
- Consumes: `Ctx` (Task 1).
- Produces: `Req(In).ctx: *Ctx`; `req.fail`/`req.param` delegate to `ctx`; `makeThunk` constructs the `Ctx` and the `Req`. `HandlerInput`/`HandlerOutput` unchanged → codegen unchanged.

- [ ] **Step 1: Write/adjust the failing test**

Add a route_types test: a typed handler reads `req.ctx.user()` and `req.ctx.records()`; assert `makeThunk` wires `req.ctx` non-null with the right app/arena.

```zig
test "makeThunk wires req.ctx with app + arena" {
    // Build a minimal RouteEvent-equivalent input path (or a Ctx directly), run the thunk,
    // assert the handler observed req.ctx.app == app and req.ctx.arena == request arena.
}
```

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — `Req.ctx` undefined.

- [ ] **Step 3: Implement**

- Add `ctx: *Ctx` to `Req(InputT)` (`route_types.zig:45-71`); keep `input`/`params`. Remove the now-redundant `app`/`arena` opaque fields, OR keep them as deprecated passthroughs sourced from `ctx` (prefer removal for cleanliness — this is the breaking window). `req.param` reads from `ctx.request.?` params; `req.fail` delegates to `ctx.fail`.
- In `makeThunk` (`route_types.zig:167-213`): the thunk now receives `ctx: *Ctx` (matching the new `RouteHandler`). Build the `Req` from `ctx` (input parsed from `ctx.request.?.query`/`.body` as before; `params` from `ctx.request.?.params`; `auth_id` from `ctx.rctx`), set `req.ctx = ctx`, call the typed handler, serialize `Out` to JSON (unchanged).

- [ ] **Step 4: Run to verify pass + codegen unaffected**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Run the codegen/TS SDK build path (the existing CI step) to confirm RPC output is byte-identical aside from intended changes.
Expected: PASS; codegen drift-guard tests green.

- [ ] **Step 5: Commit**

```bash
git add src/route_types.zig
git commit -m "feat!(routes): typed Req gains ctx; makeThunk builds it (codegen unchanged)"
```

---

## Task 4: Record hooks become `fn(*Ctx, *RecordEvent) !void`

**Files:**
- Modify: `src/events.zig` (`RecordHandler`, `buildRecordDispatcher` at `events.zig:474-503`, the dispatcher tests `events.zig:505-617`), `src/api/records.zig` (`emitRecord` at `api/records.zig:22-57`)

**Interfaces:**
- Consumes: `Ctx`, the A2 in-transaction hook ordering.
- Produces: `RecordHandler = *const fn(ctx: *Ctx, ev: *RecordEvent) anyerror!void`; dispatcher threads `ctx`; `emitRecord` builds a `Ctx` bound to the in-txn conn (`bound_conn = conn`) and passes `(ctx, ev)`. `RecordEvent` keeps `record`/`phase`/`collection`/`arena` but its `data` field is removed (capabilities now via `ctx`).

- [ ] **Step 1: Update dispatcher tests to the new shape**

Rewrite the `events.zig` dispatcher tests (`events.zig:505-617`) so hooks are `fn(ctx: *Ctx, ev: *RecordEvent) !void`, constructing a bound `Ctx` like A1 Task 8. These assert the new contract.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — handler arity mismatch.

- [ ] **Step 3: Implement**

- `src/events.zig`: change `RecordHandler` to two-arg; in `buildRecordDispatcher`, change the generated `dispatch` to `fn(ctx: *Ctx, ev: *RecordEvent)` and call `@field(g, fname)(ctx, ev)`. Remove `RecordEvent.data` (and update `validateHooks`' coerce check).
- `src/api/records.zig`: in `emitRecord`, build the `Ctx` (`bound_conn = conn`, `rctx = rctx`, `arena = arena`) and call `dispatch(&ctx, &ev)`. This composes with A2 (the conn is already the in-transaction writer).

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/events.zig src/api/records.zig
git commit -m "feat!(hooks): record hooks receive (*Ctx, *RecordEvent)"
```

---

## Task 5: Jobs (+ lifecycle) become `fn(*Ctx, *JobEvent) !void`

**Files:**
- Modify: `src/events.zig` (`JobTask`, `LifecycleHandler`, `JobEvent`/`LifecycleEvent` — drop their `reader()/writer()`), the scheduler call site (where `JobTask` is invoked — find via `submit_fn`/worker loop in `src/scheduler.zig`)

**Interfaces:**
- Consumes: `Ctx`.
- Produces: `JobTask = *const fn(ctx: *Ctx, ev: *JobEvent) anyerror!void`; scheduler builds a `Ctx` (anonymous rctx, null request, null bound_conn) and calls `(ctx, ev)`.

- [ ] **Step 1: Update job/lifecycle tests + scheduler call site test**

Adjust any job tests to the two-arg shape.

- [ ] **Step 2: Run to verify failure**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: FAIL — job arity mismatch.

- [ ] **Step 3: Implement**

Change `JobTask`/`LifecycleHandler` types; remove `reader()/writer()` from `JobEvent`/`LifecycleEvent` (capabilities via `ctx`). In the scheduler worker loop (and `App.submit` path), build `var cx = Ctx{ .app = app, .arena = app.allocator, .rctx = .{}, .request = null, .bound_conn = null }; defer cx.deinit(); try task(&cx, &job_ev);`.

- [ ] **Step 4: Run to verify pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/events.zig src/scheduler.zig
git commit -m "feat!(jobs): job/lifecycle handlers receive (*Ctx, *Event)"
```

---

## Task 6: Remove the public `Data` re-export and the `caps()` shim

**Files:**
- Modify: `src/root.zig` (`root.zig:9`), `src/events.zig` (delete `caps()` added in A1 Task 8 — now redundant)

**Interfaces:**
- Produces: `Data` no longer in the public surface; `Ctx` is the only capability entry point.

- [ ] **Step 1: Remove + rebuild**

Delete `pub const Data = @import("data.zig").Data;` from `root.zig` (keep the internal `data.zig` import where used). Delete the `caps()` methods from the event types.

- [ ] **Step 2: Run to verify the in-tree suite still builds**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Expected: PASS (internal users of `Data` unaffected; only the public re-export is gone).

- [ ] **Step 3: Commit**

```bash
git add src/root.zig src/events.zig
git commit -m "feat!(api): remove public Data re-export and caps() shim (use Ctx)"
```

---

## Task 7: Migrate all three examples + docs/site + Breaking changelog

**Files:**
- Modify: `examples/blog/src/main.zig` (7 signatures: `blog:34,68,79,104` record hooks; `114,136` typed routes; `156` job)
- Modify: `examples/golfsim/src/main.zig` (`55` hook w/ `ev.data`, `134,197,237,315` typed routes, `275` job w/ manual Data, `330` untyped route, `354` file hook, `369` hook)
- Modify: `examples/plugins/src/main.zig` (`329` error, `355` auth, `390` hook, `411` job)
- Modify: `docs/framework.md` + `site/src/content/` mirror
- Create: `changelog.d/ctx-first-reshape.md`

**Interfaces:**
- Consumes: every reshaped signature above.

- [ ] **Step 1: Migrate examples**

Convert each signature and DB access:
- Record hook `fn(ev: *RecordEvent) !void` → `fn(ctx: *Ctx, ev: *RecordEvent) !void`; `ev.data.findById(...)` → `ctx.records().get(...)` (or `.list`); mutations still via `ev.record`/`ev.arena`.
- Job `fn(ev: *JobEvent) !void` → `fn(ctx: *Ctx, ev: *JobEvent) !void`; `ev.app.pool.acquireWriter()` + manual `Data` → `ctx.records()` / `ctx.tx(...)`.
- Untyped route `fn(ev: *RouteEvent) !Response` → `fn(ctx: *Ctx) !Response`; build the response from `ctx.request.?`.
- Typed route `fn(req: *Req(In)) !Out` → unchanged signature; replace `req.app`/`req.arena` with `req.ctx.*`; `req.ctx.records()`/`req.ctx.http()` as needed.
- `FileEvent`/`AuthEvent`/`ErrorEvent` handlers: out of this plan's scope unless they used `Data`/`reader`/`writer` — if so, switch to `Ctx`; otherwise leave (their reshape, if any, is a later theme).

`examples/plugins` must `npm run build` its frontend before its Zig build (it embeds `frontend/dist`).

- [ ] **Step 2: Build every example**

Run each example's build per its README (and `npm run build` for plugins' frontend first).
Expected: all three compile and run.

- [ ] **Step 3: Docs + site + changelog**

Rewrite the `docs/framework.md` handler/hook/job sections to the `Ctx` surface; mirror into `site/src/content/`; `cd site && npm run build`. Add the fragment:

```markdown
### Breaking

- Custom handler/hook/job signatures now receive a unified `*Ctx`:
  untyped routes are `fn(ctx: *Ctx) !Response`, record hooks
  `fn(ctx: *Ctx, ev: *RecordEvent) !void`, jobs `fn(ctx: *Ctx, ev: *JobEvent) !void`;
  typed routes keep `fn(req: *Req(In)) !Out` but reach capabilities via `req.ctx`.
  The `reader()`/`writer()`/`.data()` accessors and the public `Data` re-export are
  removed — use `ctx.records()`, `ctx.tx()`, `ctx.http()`.
```

- [ ] **Step 4: Full verification — unit + browser + examples**

Run: `mise exec zig@0.16.0 -- zig build test --summary all`
Run: `mise exec python@3.13 -- python -m pytest tests/admin -q` (the full admin suite — the reshape touches the request path).
Expected: `Build Summary: N/N tests passed`; browser suite green; all examples build.

- [ ] **Step 5: Commit**

```bash
git add examples docs/framework.md site/src/content changelog.d/ctx-first-reshape.md
git commit -m "feat!(examples,docs): migrate to the ctx-first handler surface"
```

---

## Self-Review

**Spec coverage (Theme A spec §2, §7):**
- Uniform `ctx`-first delivery to route/hook/job → Tasks 2,3,4,5. ✓
- `ctx.request`/`ctx.user` → Task 1. ✓
- Remove public `Data` re-export → Task 6. ✓
- Typed-route codegen parity preserved (Req keeps shape) → Task 3. ✓
- Examples + docs + site + Breaking changelog → Task 7. ✓
- `ctx.auth` session verbs (clearSession etc.) remain deferred to Theme D; only an `issueSession` shim is provided (Task 1) so existing session minting keeps working. ✓

**Placeholder scan:** Each task's reshape is concrete with the exact target sites (file:line) and the before/after signature. No "TBD". Task 3's test is described as constructing a Ctx-driven thunk input; the implementer fills the minimal Req per the surrounding makeThunk code.

**Type consistency:** `RouteHandler`/`RecordHandler`/`JobTask`/`LifecycleHandler` new signatures are declared once (File Structure interfaces) and used identically across Tasks 2–5. `Req.ctx`, `ctx.records()`, `ctx.tx()`, `ctx.http()`, `ctx.user()`, `ctx.errorResponse()` match A1/A2.

**Reconciliation note:** Execute A1 → A2 → A3 in order. Before starting A3, re-read the as-built `src/ctx.zig` and `src/events.zig` from A1/A2 and adjust any names that drifted (e.g. the `records()` method vs field form). The codegen-unchanged claim depends on typed handlers keeping `fn(*Req(In)) !Out`; if A3 execution finds a reason to change that shape, the codegen files in the exploration (`gen_client.zig`, `rpc.zig`, `rpc_ts.zig`) re-enter scope.
```
