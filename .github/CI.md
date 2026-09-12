# CI latency and coverage

The goal is under ten minutes from workflow creation to completion, ideally
five, without weakening ZigBase's lean or feature-enabled configurations.
Measure the whole workflow, including scheduling, artifacts and post-job cache
work; do not report only the fastest job or exclude slow required checks.

## Job boundaries

| Lane | Coverage / responsibility |
| --- | --- |
| `build` matrix | Independent core/example bundles containing portable same-run binaries and example frontends |
| `browser-tests` | Default admin/browser suite and Blog Zigapagos flow |
| `cli-tests` | Lifecycle/doctor, tooling (including performance-parser tests), SMTP TLS |
| `feature-tests` matrix | Workbench; ImageMagick/Golfsim; RAM uploads; durable uploads; realtime backfill/migration coordination/idempotency/memory jobs |
| `contracts` | Compile-fail contracts, symbol gating, example in-process tests, allocator/ledger/changelog checks |
| `performance` | Realtime ReleaseSafe correctness plus ReleaseSmall size and allocation contracts |
| `codegen` | All checked-in client snapshots, including language-specific formatting |
| Existing standalone lanes | Default/prod/dev-tools-off units and fuzz compilation, PostgreSQL, PostgreSQL TLS, S3, public site |
| Existing downstream lanes | TypeScript, Dart, Python, Kotlin SDKs and migration-agent evaluations |

The required `browser` check is an `always()` aggregate. Every split lane must
report `success`; failure, cancellation or skipping fails the aggregate. The
existing `unit` and `ts-sdk` check names also remain intact. Keep new feature
lanes in that dependency closure rather than making their failures advisory.

Feature lanes retain their configuration-specific full unit suites, positive
and negative symbol controls, compile-fail contracts and HTTP tests. Most opt-in
HTTP tests skip in the default browser invocation: that invocation is not a
replacement for their dedicated lanes. The only removed test command was the
extra `unittest` invocation of `test_performance_contracts.py`, which remains
collected by `pytest tests/tools`.

Upload suites use two xdist workers with per-test data directories and free
ports. Keep the existing serial policy for lifecycle's process/timing-sensitive
checks and the live SMTP/TLS integration test (which uses ephemeral ports).
Do not reduce production
password hashing costs to accelerate test setup.

## Build/cache policy

- Transferred binaries are built with `-Dcpu=baseline` from the current run;
  never substitute a cached older executable for a build step.
- In `ci.yml`, cache the shared Zig toolchain/dependency directory, not the continually
  growing `.zig-local` object history. Jobs still reuse local objects within
  one runner. This trades some recompilation for bounded transfer overhead;
  measure cold runs as well as warm ones before expanding caching again.
  Other workflows such as scheduled fuzzing retain their own cache policies.
- Build the portable root fixtures in one graph with two compiler workers
  (`-j2`), sharing prerequisites without unbounded concurrent compilation.
- Core and example artifacts are produced concurrently. Tar archives preserve
  repository-relative paths and executable bits across the two bundles; every
  downstream consumer explicitly unpacks its required bundles before use. The
  CLI suite, non-TypeScript SDKs and agent evaluations download only core binaries. Low ZIP
  compression (level one) balances producer CPU with transfer size. Missing
  bundles fail unpacking rather than silently using a locally rebuilt binary.
- Install only the tools a lane uses. Only browser lanes install Chromium.
- Cancel superseded runs for the same PR. Main and manual runs use distinct
  concurrency groups and are not cancelled by newer revisions.

## Baseline and validation

Five completed runs sampled on 2026-09-12 took 27:06–33:25 (median 30:53),
with roughly 48–56 runner-minutes. Every critical path was `build → browser`.
For example, [run 34705767340](https://github.com/valthon/zigbase/actions/runs/34705767340)
took 31:59: build 7:14, browser 24:41. The actual general headless suite was
only 3:37; serial feature compilation and HTTP tests dominated the rest.

The first split-lane run, [34720257868](https://github.com/valthon/zigbase/actions/runs/34720257868)
at `938c5a08`, passed in **10:04**, using **67.45 runner-minutes**. Its critical
path remained build (4:51) then browser (4:59), with scheduling and the aggregate
accounting for the balance. This is about 67% faster than the sampled median,
but still misses ten minutes and increases runner cost. That revision used
serial portable-fixture builds; bounded two-worker compilation and dependency
cleanup are the next measured changes, not an assumed further speedup.

The subsequent [run 34720819956](https://github.com/valthon/zigbase/actions/runs/34720819956)
at `1b448c9a` passed in **9:34**, using **62.13 runner-minutes**. Build fell to
3:58; browser took 5:22. This meets ten minutes for that run, not a five-minute
or cold-run guarantee. Follow-up cleanup wires the prebuilt dating binary into
both browser consumers and reserves full Git history for ledger checks.

Run [34722825811](https://github.com/valthon/zigbase/actions/runs/34722825811)
at `7949d95f` passed in **10:19** / **64.95 runner-minutes**: build stayed near
four minutes, but browser execution and artifact transfers took longer. The
under-ten target is not consistently met yet. Splitting core/example artifact
production and compressing transfers lightly is intended to add headroom;
measure it rather than assuming the fastest prior result will repeat.

For subsequent measurements, record exact head/run, end-to-end time, critical path, runner
minutes and cache state after hosted CI completes. More concurrent cold builds
can increase runner minutes even while reducing feedback latency. If build
remains the bottleneck, split artifact production by the consumers that need
each bundle; if uploads dominate, profile reusable setup rather than deleting
crash-recovery coverage.

Validate workflow syntax and shell expressions with `actionlint`, compare
retained test commands against the base revision, and run both upload suites
with the new worker count. Also verify the aggregate rejects failed, skipped
and cancelled dependencies before relying on its green status.
