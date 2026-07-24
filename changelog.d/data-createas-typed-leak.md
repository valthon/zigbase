### Fixes
- Fixed a memory leak in the `Data` facade's typed record I/O: `createAs`/`getAs`/`updateAs` parsed the intermediate `std.json.Value` record returned by `create`/`findById`/`update` into `T` but never freed that intermediate, leaking every owned string in the discarded record (~46 allocations per call) on non-arena allocators. The intermediate is now freed after the parse deep-copies into `T`.

### Changed
- `Data.createAs`/`getAs`/`updateAs` now reject a `T` that (recursively) contains a raw-JSON field (`std.json.Value`/`ObjectMap`/`Array`) at **compile time** with an actionable message. `parseFromValueLeaky` (used by these methods) returns such a field as an alias into the intermediate record they now free — which would dangle a string field (use-after-free) — so typed I/O is restricted to concrete field types; use the untyped `create`/`findById`/`update` for raw JSON.
