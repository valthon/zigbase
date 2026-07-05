### Performance

- Steady-state feature-flag and experiment resolution now costs **zero `_kv` reads**: an in-process cache serves the current `flag:*` / `exp:*:weights` override set to both `ctx.flags().resolveAll` and the per-flag/`App.flag`/`App.experiment` lookups. A same-instance override write (`App.setFlag`, the admin settings verbs) invalidates it instantly, so a kill-switch flip still takes effect on the next request; on Postgres, another instance's write self-heals within a 5 s staleness bound (so it runs on both backends, unlike the SQLite-only collection cache).
