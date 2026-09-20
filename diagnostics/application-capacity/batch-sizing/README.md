# Durable batch sizing in a mixed application

These raw reports record a local Debug experiment with Zig 0.16.0 on 2026-09-19.
They were built during implementation on base `59ac830b`, with the mixed-workload
changes in this PR. They are not clean-release or dedicated-machine capacity
measurements. Each report records the binary digest, embedded version, fixture
and runner digests, machine details, resources, dataset, and observations.

The task update transaction enqueues a digest job. The initial fixture used
`.workers.capacity.concurrency = 2`. Despite its name, this durable setting is the
maximum serial claim batch per approximately 500 ms worker tick, not two parallel
handler threads. Forty jobs accumulated faster than that batch could drain.

| Phase | Batch 2 drain (seconds) | Batch 128 drain (seconds) |
| --- | ---: | ---: |
| Warmup | 9.426 | 0.416 |
| Measurement | 9.866 | 0.351 |
| Stress | 9.912 | 0.363 |
| Recovery | 9.858 | 0.393 |

Both runs verified 120 requests, 40 tenant-scoped SSE events, and 40 completed
job revisions per phase. All semantic checks passed. The changed batching
configuration explains the polling delay; this is not a claim that larger batches
universally improve throughput. Larger serial batches retain more claimed payloads
and can delay other work. Use the resource report and representative job costs
when choosing a batch.

## Reproduce

Use the checked-in fixture with batch 128. For the comparison, change only its
`.workers.capacity.concurrency` to 2 and rebuild. Keep each binary and report under
a different filename. Use the same pinned compiler, build mode, and command:

```sh
mise exec zig@0.16.0 -- zig build application-capacity --summary all
python3 tools/application_capacity.py --binary zig-out/bin/application-capacity \
  --tenants 2 --tasks 8 --concurrency 2 --stress-concurrency 4 \
  --seconds 2 --warmup 1 --recovery-seconds 2 --max-requests 120 > report.json
```

Inspect `drain.jobs`, `drain.realtime`, `drain.elapsed_seconds`, and `drain.server`
in every phase. A job count alone is insufficient: the runner also matches each
account/revision payload, checks missing or duplicate deliveries, and verifies
rejected writes leave no queued job. `resources` records configuration; it does
not account for all process RSS. The richer report is not the `tune` input schema.

The test host was shared with other builds. Compare the mechanism and correctness,
not the request rates. Repeat on your own controlled target hardware before setting
latency budgets or claiming capacity. Neither run observed HTTP overload refusal;
higher offered concurrency alone is not proof of server saturation.
