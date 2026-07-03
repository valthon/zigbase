### Features

- Tunable Cache-Control for static file serving: `App(.{ .static_cache_control = "…" })`
  sets a comptime default, and `--static-cache-control <value>` /
  `ZIGBASE_STATIC_CACHE_CONTROL` override it at runtime (flag wins over env, both win
  over the comptime default). Applies only to static serving (dir/embedded/
  `--serve-static`) — record-file downloads keep their authorization-derived
  Cache-Control unchanged. Unset (the default) is byte-identical to today's stock
  `max-age=3600`. The value must be non-empty, CR/LF-free, and at most 256 bytes;
  an invalid value fails startup with a clear error instead of silently clamping
  or ignoring it.
