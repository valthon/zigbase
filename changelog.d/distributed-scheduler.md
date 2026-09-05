### Features

- Opt-in comptime `.distributed` cron/interval jobs share persisted schedules across database instances, recover expired leases, and fence stale dispatcher completions. `JobEvent.scheduled_at` supplies stable occurrence identity across retries/recovery, while `generation` identifies each claim attempt.

### Changed

- Distributed schedules poll through readers every 15 seconds when idle and retire stopped jobs locally. Current owners may complete after lease expiry if no newer claim exists; lease duration can be tuned without changing schedule identity.
- Zero-minute declared intervals are rejected at compile time for all scheduled jobs; reactive handlers may still explicitly request an immediate next tick.
