### Breaking

- Custom handler/hook/job signatures now receive a unified per-request `*Ctx`:
  - Untyped routes are `fn(ctx: *zigbase.Ctx) anyerror!zigbase.http.Response` (was `fn(*RouteEvent)`).
  - Record hooks are `fn(ctx: *zigbase.Ctx, ev: *zigbase.RecordEvent) anyerror!void` (was one-arg `fn(*RecordEvent)`).
  - Jobs are `fn(ctx: *zigbase.Ctx, ev: *zigbase.events.JobEvent) anyerror!void` (was one-arg `fn(*JobEvent)`).
  - Lifecycle hooks are `fn(ctx: *zigbase.Ctx, ev: *zigbase.events.LifecycleEvent) void`.
  - Typed routes keep `fn(req: *zigbase.Req(In)) zigbase.RouteError!Out`, but reach capabilities via `req.ctx` (`req.ctx.records()`, `req.ctx.http()`, `req.ctx.arena`, `req.ctx.app`).
- DB access is now uniform through the `Ctx` capability object: `ctx.records()` (list/get/create/update/delete), `ctx.tx()` (atomic writes), and `ctx.http()` (outbound client). In a `before*` hook, `ctx.records()` is bound to the triggering write's in-transaction connection, so a side-write commits/rolls back atomically with it.
- Removed `RecordEvent.data`, `JobEvent.reader()`/`JobEvent.writer()`, `ev.caps()`, and the public `zigbase.Data` re-export. Migrate hook/job DB access to `ctx.records()`; for raw SQL on a migration-owned table use the pooled writer via `ctx.app.pool.acquireWriter()`.
