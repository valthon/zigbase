### Features
- Configure lazy memory-job and `app.submit` workers with `.pools.memory_jobs` (1–64), independently of scheduler workers. Explicit resource profiles select 1/4/8 workers; omission preserves four. Offline resource reports include the requested worker count, not live counts or memory predictions.
### Fixes
- Honor `.pools.stack_size` for memory-job threads as documented, using the same 1 MiB floor as scheduler threads.
### Changed
- Explicitly larger stack settings now also increase memory-worker stacks. Partial or zero thread startup logs the actual/requested count, and contending workers park during startup instead of spinning.
