### Fixes
- Scheduler delays (interval jobs, reactive `.after`, retry backoff, durable worker polling and the `.distributed` poll) now run on the monotonic boot clock. Stepping the wall clock back no longer stops every job, durable queues included, for as long as the step; stepping it forward no longer fires interval jobs early. Cron stays wall-clock: after a forward step the job runs once, late, and after a backward step, even one taken while its handler runs, a per-process cron job never repeats a minute it already ran while the process runs (`.distributed` cron follows the database clock and can repeat a minute after a backward step of that clock) (#493).

### Changed
- Under `ZIGBASE_FAKE_NOW`, only cron times are frozen. Interval, reactive and retry delays measure real elapsed time, so an interval job now fires once its period has really passed instead of never.
