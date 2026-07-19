### Fixes

- Comptime `.migrations` bare-tuple entries now reject an unknown key (a typo'd `.transational`/`.donw` was silently dropped) with a loud `@compileError`, matching every other list-shaped config key.
- Webhook deliveries: at startup, warn about any declared queue whose `visibility_timeout_s` is too small to safely host a webhook delivery's in-handler retry backoff, which could otherwise let the queue re-dispatch an in-flight delivery as a concurrent duplicate.
- The "per-route rate limit cannot identify the client" startup warning now fires once per distinct route pattern instead of once per process, so a second unprotected route is no longer silently skipped from the log.
- Postgres placeholder renumbering no longer panics on a pathological statement with an extreme number of anonymous `?` placeholders (the anonymous running counter is now bounded by the same param cap as a numbered `?N`, returning a prepare error instead of overflowing the placeholder buffer).
