### Internal

- `records.decodeCursor` now frees the decoded cursor's parse arena on its two binding-rejection
  paths (`error.CursorSort` / `error.CursorFilter`). The decode allocates a contract-2 `Cursor`
  that owns a `std.json` parse arena, but the sort/filter binding checks ran *after* that
  allocation and returned without deiniting it — correct only because the sole production caller
  passes a request scratch arena, and a genuine leak under any other allocator. Added a regression
  test that exercises both reject paths on raw `std.testing.allocator` (leak detection on).
