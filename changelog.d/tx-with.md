### Features
- `ctx.txWith(T, payload, fn)` (#237) — a `ctx.tx` companion that threads a caller-supplied payload directly into the transaction callback, so a route/hook/job that needs request data inside a transaction no longer has to smuggle it through a `threadlocal` global.
