### Features

- Handler/hook/job capability object: handlers, hooks, and jobs now receive a
  `*Ctx` directly, exposing `ctx.records()` (filtered/sorted/paginated list +
  get/create/update/delete, with `expand`/relations), an outbound `ctx.http()`
  client, and a standard error model (`ctx.fail`/`ctx.invalid`, error→status
  mapping over the existing `{code,message,data}` envelope). Custom handlers no
  longer need to drop to raw SQL or vendor an HTTP stack.
