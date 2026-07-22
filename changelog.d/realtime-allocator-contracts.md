### Fixes

- Fix memory leaks throughout the realtime subsystem, latent behind the per-connection/per-request
  arena but real under any non-arena allocator:
  - `realtime/connection.removeSub` used `HashMap.remove`, silently dropping the entry without
    freeing the duped subscription key/filter — a connection that subscribed/unsubscribed
    repeatedly accumulated leaked topics until disconnect. Now `fetchRemove` + explicit frees, with
    a new `Conn.deinit` freeing all remaining subscriptions.
  - Realtime frame building (`protocol.zig`, `ws.zig`, `pg_bridge.zig`, `hub.zig`) leaked scratch
    `ObjectMap`s and JSON stringify/parse buffers on nearly every emitted event/signal/ack frame.
  - `realtime/pg_bridge.decode`/`decodeAny` (the Postgres realtime bridge) parsed with a leaky
    parser and returned struct fields aliased into the never-freed tree; now dupes each field fresh
    with `Event`/`Signal`/`MessageRef`/`Payload` `deinit` methods. Also fixes an unfreed
    delete-snapshot JSON buffer in `storeDeleteSnapshotInner`.

### Internal

- Restore leak detection for the `realtime/` subsystem: convert the arena-masked tests in
  `connection`/`protocol`/`ws`/`sse`/`pg_bridge` (all removed from the allowlist) and 6 of 22 in
  `hub`. The remaining 16 `hub` tests are blocked one layer down — 15 leak scratch SQL from
  `collections.create`/`records.create` (a core DB-layer leak, its own batch), and 1 legitimately
  holds a concrete per-connection identity `*ArenaAllocator` (contract-4) — each documented inline.
