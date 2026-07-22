### Performance

- Pre-size the record-read hot path's growing collections so their backing is allocated once
  instead of reallocating as they fill. `records.rowToObject` (and its at-rest sibling)
  pre-sizes the per-record `std.json.ObjectMap` to id/created/updated + the collection's
  fields; `records.list` pre-sizes its result-item list to the page limit. Measured with
  `zig build bench`, a 30-record list read dropped from ~260 to ~226 allocations per page
  (~13%) — the 512-byte size bucket fell from 38 to 6 — and a single-record read drops an
  allocation. Output is byte-identical (insertion/append order is unchanged), verified by the
  record + cursor-pagination browser tests.
