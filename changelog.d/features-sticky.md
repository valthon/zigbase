### Features

- Sticky experiment assignments (#129): declare an experiment `.sticky = true` to persist a subject's first variant in `_experiment_assignments` so it **survives later weight changes** (new subjects still follow the current weights; empty subjects are never persisted). A framework-internal `_experiment_gc` job — installed only when a `.sticky` experiment is declared — reaps assignments older than the new `.experiment_assignment_ttl` config (in days, default `90`) hourly in bounded batches.
