### Features

- Typed record I/O on the records handle: `ctx.records().createAs(T, col, .{…})`, `getAs(T, col, id)`, and `updateAs(T, col, id, .{…})` reflect a plain Zig struct into a write and parse the resulting record back into `T` — no more hand-assembling `ObjectMap`s or unwrapping union tags. Struct fields map to schema fields by name, optionals map to nullable columns, and every literal field is comptime-verified to exist on `T` (a typo is a build error). The `std.json.Value` API stays for dynamic callers.

### Fixes

- `.int` and `.fixed`-mode `.number` fields now accept a JSON **number** on write, not only a string — symmetric with reads, which return a string. `price_cents = 500` and `price = 5.0` (scaled to a `fixed` field) bind correctly instead of failing validation; a fractional float on an `.int` field is still rejected.
