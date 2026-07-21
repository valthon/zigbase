### Internal

- Point the benchmark harness (`zig build bench`) at the real record read paths for the first
  time (it had only measured the jwt exemplar), and measure allocation cost the way this
  codebase actually pays it:
  - `data/queryAs-50rows` — the typed row-decode path (`data.queryAs`), ~3 small allocations
    per row.
  - `records/findById-json` and `records/list-json-30` — the JSON record path (`records.get`/
    `records.list` -> `std.json.Value`), the shape every REST read returns. The JSON path
    allocates ~3x more allocations and ~6x more bytes per record than the typed path (the
    `ObjectMap` buckets + per-field values, visible in the size histogram), and a batched
    `list` is ~8.7 allocs/record vs ~13 for individual `findById` (the per-record prepare/SQL
    that N+1 gets each pay).
- Add `harness.runArena`: measures an op under a request-style arena reset between iterations —
  the per-request model this codebase uses. Pairing it with the raw-malloc `run` shows the
  point directly: identical allocation count, but ~15x faster under the arena (many small
  dupes are cheap bumps), so the allocation count/size distribution is the real
  backing-independent signal while the raw-malloc ns is overhead the arena erases. The JSON
  record results are arena-lifetime graphs, so they are measured under `runArena` only.
- Expose the record read path to the (Debug) bench via a `dev_mode`-gated `internal` seam in
  `root.zig` — the same never-in-release gate as the dev-only clock/entropy seams, folding to
  `struct {}` in any release build, so it adds nothing to the shipped public surface.
