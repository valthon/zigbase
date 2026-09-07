### Features
- Opt-in `-Drealtime-backfill=true` adds bounded, single-process SQLite record invalidation backfill with current authorization, id-only results, paginated checkpoints and explicit reset-required gaps. Disabled builds omit the store and endpoint; this is not durable or historical-payload replay.
