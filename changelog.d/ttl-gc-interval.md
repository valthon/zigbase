### Features
- The TTL garbage-collection sweep cadence is now configurable via the comptime `.ttl_gc_interval` App config key (a `schedule.Interval`, default `.{ .minutes = 5 }`); expired rows are still hidden from reads immediately regardless of sweep cadence.
