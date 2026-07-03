### Breaking

- Removed the legacy `.jobs = .{ .pool_size = N }` spelling; set `.pools = .{ .jobs = N }`. The old key is now a pointed compile error (N1).

### Features

- `.migrations` accepts a bare tuple (`.migrations = .{ .{ .id = "...", .up = f } }`) like every other list-shaped config key; the typed-slice form still works (E1).
