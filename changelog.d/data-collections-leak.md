### Fixes

- The standalone `WriterData`/`ReaderData` DB-access handles (`ev.writer()`/`ev.reader()`) no longer leak on the process allocator: their `data()` accessor now allocates on an arena OWNED BY THE HANDLE, so a record op's collection metadata, SQL scratch, and returned records are all freed together when the handle's `deinit()` runs. Results are valid until `deinit()`. (`ctx.records()` was never affected — it already uses the per-request arena.)
