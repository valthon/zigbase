### Internal

- `dumpload.zig`'s collection-creation ordering is now a proper Kahn topological sort (`planCreateOrder`), with unit-tested, deterministic handling of relation cycles (self-relations and mutual/N-node cycles) that surfaces the in-cycle relation fields instead of just falling back to declaration order. Observable dump/load behavior for acyclic schemas (the common case) is unchanged; this lands the pure ordering primitive that Postgres deferred-FK cycle support (a follow-up task) builds on.
