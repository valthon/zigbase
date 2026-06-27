### Features

- Handler/hook/job capability object: `ev.caps()` returns a `Ctx` exposing
  `records()` (filtered/sorted/paginated list + get/create/update/delete, with
  `expand`/relations), an outbound `http()` client, and a standard error model
  (`ctx.fail`/`ctx.invalid`, error→status mapping over the existing `{code,message,data}`
  envelope). Custom handlers no longer need to drop to raw SQL or vendor an HTTP stack.
