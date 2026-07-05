### Fixes
- Setting `.auth.session.gc_cron` without `.auth.session.store = .table` is now the compile error it was always meant to be. The guard lived in a lazy comptime value referenced only by the `.table`-mode session-GC job, so in the misuse case (`.epoch` store) it was never analyzed and the misconfiguration silently compiled and did nothing; it now fails loudly at build time.
