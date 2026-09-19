### Features

- Bound retained durable queue rows and UTF-8 payload bytes with optional per-queue capacity, atomic SQLite/PostgreSQL admission, and bounded `ctx.queueCapacity` snapshots. Retry and terminal history retain capacity until deletion or GC.
- Include serial durable poll batches in opt-in coordinated execution admission; saturated workers leave jobs pending without spending attempts or rate tokens.
