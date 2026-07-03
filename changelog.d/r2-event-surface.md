### Breaking

- `RecordEvent.ctx` is now `RecordEvent.rctx` (`ctx` always means `*Ctx` in a hook signature). Mechanical migration: `ev.ctx.` → `ev.rctx.`.
- `RecordEvent.app` was removed — it put the UB footgun (`ev.app.allocator` vs `ev.arena`) one dot from every hook. Use the hook's `ctx.app`; allocate record data with `ev.arena`. (`JobEvent.app`/`ErrorEvent.app` are unchanged.)
- `RouteEvent` was deleted. It was never passed to a live route (handlers take `*Ctx`); it existed only in tests. Events carry data; `ctx` carries capabilities.
