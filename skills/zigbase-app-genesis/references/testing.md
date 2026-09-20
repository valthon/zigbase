# Testing a ZigBase app

> 📖 This documentation is also published, web-native, at <https://valthon.github.io/zigbase/docs/testing> — the site is the canonical reading experience.

There are two ways to test an app built on ZigBase, and they cover different
things. Pick deliberately.

| Surface | What it exercises | Cost |
| --- | --- | --- |
| **`zigbase.testing`** (in-process, Zig) | The real router, access rules, auth, hooks, custom routes, migrations, provisioning | Milliseconds. No socket, no port, no background threads. |
| **A spawned server** (any language) | Everything above **plus** the HTTP server, TLS/proxying, CORS, WebSocket upgrades, static files, and your client SDK | Seconds. Needs a port and a binary. |

If you are writing a Zig app on ZigBase, `zigbase.testing` is the default and
most of your tests belong there. Reach for a spawned server for the things
in-process testing structurally cannot see.

## Focused repository test execution

The repository also tests the lean SQLite configuration without FTS5:

```sh
mise exec zig@0.16.0 -- zig build install test -Dfts5=false -Dpostgres=false --summary all
```

This builds the stripped binary and runs the full unit suite. SQLite search-only
cases are gated, while disabled-search rejection, ordinary access controls, key
rotation and client generation remain covered. PostgreSQL search is independent
of the SQLite FTS5 flag.

For contributors working inside a **trusted ZigBase checkout**, the standard-library
Python tool `tools/agent_tests.py` provides static JSON test inventory, exact
module/function and TypeScript/Python SDK unit-suite selection, and bounded structured execution reports. It is not
part of an embedded app or the server CLI and adds no deployed resource cost.

```sh
# Toolchain versions are pinned in mise.toml. Install test prerequisites explicitly:
mise exec python@3.13 -- python -m pip install pytest playwright
mise exec python@3.13 -- python -m playwright install chromium
# No tests or conftest are imported by inventory:
mise exec python@3.13 -- python tools/agent_tests.py inventory
# A module ID selects a group; a function ID selects all its parametrizations:
mise exec python@3.13 -- python tools/agent_tests.py run \
  --selector tests/admin/test_capabilities.py --timeout-seconds 180
```

Inventory covers selected agent/route/tuning/schema/files/realtime pytest modules
and the `tests/tools/` performance-contract, replay, executor, selection and
binary-resolver modules, plus `clients/typescript::unit` (pinned Node 24/Vitest,
at most two workers) and `clients/python::unit` (pinned Python 3.13, serial pytest
with explicit pytest-asyncio support). Install TypeScript dependencies with `npm ci`
in `clients/typescript`, and Python dependencies with pinned Python's
`python -m pip install -e 'clients/python[dev,realtime]'` first;
the wrapper does not install anything. SDK integration,
type checking and builds still need separate checks. Item `requirements` conservatively describe module
setup; non-browser selections do not need Chromium. Admin fixtures build the
appropriate binaries when necessary; the advertised prebuilt override is
`ZIGBASE_TEST_BINARY`. Build time counts toward the execution deadline. Prepare binaries
before a short run if needed. A function's ID is not a fully collected pytest
node list: parametrized cases run together, and class methods/dynamic cases are
not individually advertised. Zig unit tests and other SDK suites still use their
existing runners. No changed-file dependency inference or full-suite coverage
claim is made; continue running the complete relevant CI suites before shipping.

The TypeScript CI lane runs its unit suite through the actual bounded wrapper
regression (`mise exec python@3.13 -- python tests/sdk_runner/test_agent_typescript.py`),
reusing the lane's installed npm dependencies. This non-skipping, standard-library
test remains outside `tests/tools`, whose Python-only checks need no Node or SDK
installation.

`clients/python::unit` runs the Python SDK's unit suite serially with explicit
pytest-asyncio loading and integration collection excluded. First install
`clients/python[dev,realtime]` into pinned Python 3.13; the wrapper does not install
dependencies. Python CI replaces its direct unit command with
`mise exec python@3.13 -- python tests/sdk_runner/test_agent_python.py`, a real
non-skipping wrapper regression that reuses those dependencies. Its lint,
typecheck and live integration checks remain separate.
Both CI wrapper regressions request the maximum 1 MiB output budget for failure
diagnostics; interactive runs retain the smaller 64 KiB default. Overflow still
terminates the child and reports `output_limit`, rather than claiming full evidence.

`run` only accepts inventory IDs and fixed runner argv, not arbitrary executables,
options, paths or shell strings. Repository pytest modules run from the checkout
root; SDK suites run from their package directories. The Python SDK prepends its
checkout source to child `PYTHONPATH` and pytest's module path. The wrapper removes `NODE_OPTIONS`,
`PYTEST_ADDOPTS` and `PYTEST_PLUGINS`, disables plugin autoload, and forces foreground
server mode. Child processes receive `MISE_AUTO_INSTALL=false`; install toolchains
explicitly before running. Existing repository Playwright fixtures work without an external
pytest plugin. Other environment settings remain inherited, and the repository
and toolchain remain trusted executable code: **this is not a sandbox**. Tests can
write, build, open sockets and access the network with the caller's authority.

Defaults are 120 seconds and 64 KiB **combined child stdout/stderr**, configurable
within 1–900 seconds and 1 byte–1 MiB. Excess output or time kills the process
group; ordinary group descendants are also cleaned up on completion. Reaping
adds at most two seconds; group-escaping children and process RSS/disk/network
usage are not contained. Output is UTF-8 with replacement for invalid bytes;
JSON escaping may expand beyond the raw-byte cap. Do not merge unrelated stderr
into the JSON stdout stream, and treat captured output as untrusted information.

Reports distinguish process success/failure, timeout, output-limit, execution and
cleanup errors. They include argv, limits, child exit status, duration and bounded
output. `cleanup_failed` reports cleanup failure separately without replacing a
test-failure, timeout, output-limit or execution-error outcome; `cleanup_error` is used when
cleanup alone fails. `test_counts: null` deliberately avoids inferring counts from human pytest
text. A passed process may have skipped tests. Exit codes are 0 for successful
inventory/passed execution, 1 for an unsuccessful run, and 2 for argument/selector/
inventory failures. The complete machine contract and boundary notes are in
[the agent guide](https://github.com/valthon/zigbase/blob/main/docs/agents.md#focused-repository-tests).

For a conservative first test selection after edits, run
`mise exec python@3.13 -- python tools/agent_tests.py affected --base origin/main`.
This compares the base commit to the working tree plus non-ignored untracked
files, returning module selectors without executing them. Curated dependencies
select related allowlisted modules; unknown paths select the entire allowlist.
The JSON explicitly reports incomplete coverage: this never replaces the full
relevant Zig, browser, SDK, docs or other CI suites. See the agent guide for Git
limits, filename encoding and snapshot limitations.

The focused allowlist also covers local performance-contract, parity-replay and
agent-tool regressions under `tests/tools/`. They use synthetic artifacts and local
fixtures rather than a Zig build or browser. Replay needs loopback socket access,
affected-test fixtures need Git, and executor fixtures need `mise` for one nested
resolver check. Module selectors run unittest classes too; individual class-method
selectors remain outside the inventory. The separate inventory-expansion driver
is intentionally not allowlisted, avoiding recursive wrapper tests.

## Application capacity

The project/task fixture is a first application-workload measurement, beyond isolated
microbenchmarks. It runs the real HTTP records API with authenticated users, native
account tenancy, indexed task lists, relation expansion, and writes. Every update also
enqueues a transactional durable digest job and produces a live tenant-scoped SSE event.
Warmup, normal measurement, higher-load stress, and recovery run against the same server.

From a clean checkout, preserve the revision and build command alongside each report:

```sh
mise exec zig@0.16.0 -- zig build application-capacity -Doptimize=ReleaseFast -Dcpu=baseline
mise exec python@3.13 -- python tools/application_capacity.py \
  --binary zig-out/bin/application-capacity --tenants 2 --tasks 100 \
  --concurrency 4 --stress-concurrency 8 --warmup 2 --seconds 10 \
  --recovery-seconds 5 --drain-seconds 15 > application-capacity.json
# Small live correctness check, also run in CI (no latency thresholds):
ZIGBASE_TEST_CAPACITY_BINARY="$PWD/zig-out/bin/application-capacity" \
  mise exec python@3.13 -- python -m unittest discover \
  -s tests/tools -p test_application_capacity.py
```

The runner owns a temporary directory and loopback server. It never accepts an existing
server URL or database. Inherited `ZIGBASE_*` variables are removed; plain-HTTP cookies,
foreground serving, disabled auth rate limiting, and disabled request logging are set
explicitly. This isolates the fixture from production credentials and settings. The
process is terminated and its data removed on completion or failure.

**Dataset and operation contract.** Each tenant has one member, one project, and the
requested number of tasks. Accounts and memberships are seeded directly in SQLite
outside timing; users, projects, and tasks are provisioned through the HTTP API as a
superuser. Measured requests use member bearer tokens and `X-Account-Id`, never the
superuser. Each worker owns a distinct task and repeatedly:

1. Lists up to 20 tasks, sorted by ID, with `expand=project`.
2. Updates its task title to a unique worker/sequence value.
3. Reads that task with project expansion and verifies the acknowledged title.

Every response is checked for tenant, task, and project identity. Lists must have the
expected length, sorted unique IDs, and correct expanded projects. Pre/post checks reject
foreign task reads/writes, nonmember account selection, and unauthenticated access.
After each phase the last acknowledged title is read again outside timing. Incorrect
HTTP or application results count as errors; setup or final verification failure emits
a failure object and exits nonzero. A fast empty response cannot qualify as useful work.

**Realtime and background work.** One authenticated SSE subscriber per tenant observes
updates to `tasks`. The runner matches each acknowledged task/revision to its event,
rejecting missing, duplicate, unexpected, malformed, or foreign-tenant deliveries.
Delivery latency starts immediately before the update request, so it includes mutation
time and client scheduling as well as delivery; it is not transport-only latency.
The update hook atomically enqueues one durable job containing the resolved account
and unique revision title. The job hashes that payload and performs 64 additional SHA-256 rounds, without external I/O.
After each phase, bounded observation verifies the completed job's payload identity
against every acknowledged update, not merely a matching aggregate count. Rejected
writes must leave both the task and job count unchanged.

Reports use schema version 2 and retain `measurement` alongside `warmup`, `stress`,
and `recovery`. Stress defaults to twice normal concurrency, capped at 64; set
`--stress-concurrency` explicitly for comparisons. Recovery returns to normal
concurrency for `--recovery-seconds` (default 5). Each phase allows up to
`--drain-seconds` (default 15) for events/jobs to complete before the next phase.
Completion requires another 250 ms of SSE observation within that drain deadline;
late duplicates or unexpected frames observed in that window fail the phase. This
is a bounded observation, not a guarantee against arbitrarily delayed delivery.
Durable identities include the registered `digest` kind, tenant, revision, and done status.
The drain has separate timing and resource observations; request throughput excludes
it. Thus recovery measures return to ordinary load **after** backlog drain, not
requests competing with the old backlog. Any phase error or incomplete semantic
check makes `passed` false and the command exit nonzero, with phase evidence retained.

**Bounds and measurement.** Inputs cap tenants at 16, tasks per tenant at 1,000,
normal/stress concurrency at 64, warmup at 30 seconds, measurement/stress/recovery
at 300 seconds each, drain at 60 seconds per phase, and requests at 200,000 per
phase. Warmup has a separate cap of 10,000 requests. Each worker needs a distinct
task, and the request budget must allow a three-operation cycle for every worker. Each worker has one outstanding
request, a five-second socket timeout, and a 2 MiB response cap; it starts no new request
after the phase deadline. In-flight requests drain, so elapsed time can exceed the
requested duration. `limit_reached` indicates that the request cap shortened a phase.
The finite client stores at most one latency per attempted request, one acknowledged
revision per successful update, and at most the phase request budget of events per
subscriber. Completed jobs remain in the temporary database for verification; the
fixture caps retained jobs at 1,000,000 and payload bytes at 256 MiB.

The JSON report includes successful throughput; attempted and successful counts; bounded
error categories; per-operation nearest-rank p50/p95/p99/max client latency including
failed requests; effective compiled `resources`; binary digest, size, version/build/target;
runner and fixture source digests; machine/CPU affinity; dataset/index definitions; and
post-run SQLite/WAL file sizes. Linux additionally reports server-process CPU seconds and
RSS sampled every 50 ms during request phases, plus observations during drain polling. Other platforms emit null CPU/RSS values.

**Correlate with the workbench.** Build the same fixture with
`-Dquery-workbench=true` and add `--workbench` to the runner command. It captures
an initial operator snapshot and each phase's `workbench_after`, outside request
timing. A disabled or older unsupported workbench fails explicitly. Snapshots are
cumulative for the process, including setup and verification traffic; compare
matching keys across snapshots and inspect dropped counters before attributing a
change. A missing key after the table fills is not zero activity. Timing families
are inclusive and cannot be subtracted to infer exclusive CPU time. Instrumentation
has overhead: compare runs with the same build flags, and keep uninstrumented
capacity observations separate. The workbench stores neither SQL parameters nor
job payloads, and the report does not retain the operator token.

**Interpretation.** These are warm-cache, closed-loop observations, including HTTP
connection setup and client-side semantic validation, on shared client/server hardware.
Python or connection churn can be the bottleneck. CPU is process time, not normalized
host utilization; RSS sampling can miss short peaks. File sizes are not disk I/O rates.
The binary's embedded commit and the checkout's source digests are separate provenance:
a dirty build or a binary from elsewhere must not be labeled a clean revision. Preserve
all build flags and the raw report before comparing runs. The runner does not claim a
maximum user count, production SLO, comparative cost advantage, or small-machine baseline.

The [capacity backlog](https://github.com/valthon/zigbase/blob/main/BACKLOG.md) retains uploads, open-loop load, cold-cache
behavior, PostgreSQL, replicas, and a reproducible small-machine report as future work.
Increasing concurrency is a pressure probe; it does not establish that the server
saturated. Preserve error counts and the recovery phase when interpreting a run. Use [performance contracts](#performance-contracts)
for allocation/binary gates and the [tuning advisor](https://github.com/valthon/zigbase/blob/main/docs/framework.md#offline-measurement-advisor-zigbase-tune)
for comparing supported measurement inputs; this richer report is not the advisor's
input schema.

A [worked batch-sizing investigation](https://github.com/valthon/zigbase/blob/main/diagnostics/application-capacity/batch-sizing/README.md)
preserves paired raw reports: the original two-job serial claim batch produced
roughly ten-second drains for 40 jobs; batch 128 drained them in roughly 0.4 seconds
on the same shared Debug test host. The walkthrough explains the polling mechanism,
reproduction commands, and retained-work tradeoff. It is a configuration example,
not a small-machine capacity claim.

## Performance contracts

Performance contracts are offline build/CI tooling, not application runtime
configuration. They enforce caller-owned binary-size and allocation ceilings;
they do not add instrumentation to deployed binaries or gate wall-clock timing.

Run the checked-in Linux x86_64 example with Zig 0.16.0 on PATH:

```sh
bash scripts/check-performance.sh > performance-report.json
# Compare a later run using exactly the same contract/build/workload:
bash scripts/check-performance.sh --baseline performance-report.json > next-report.json
```

The script builds the normal server with `ReleaseSmall`, baseline CPU,
`x86_64-linux-gnu`, and `-Ddev-tools=false`, then runs the benchmark-only harness
in `ReleaseFast` with the same target/CPU. Its temporary binary and JSONL inputs
are removed afterward; the report retains their SHA-256 digests. CI runs this
example and uploads the report. No noisy latency percentage determines success.

For your own app, build its binary and emit JSONL in the `bench/harness.zig`
format, then use the standalone standard-library Python command:

```sh
python3 tools/performance_contracts.py \
  --contract my-contract.json --binary zig-out/bin/myapp \
  --benchmarks my-benchmarks.jsonl > performance-report.json
```

Copy `bench/contracts/release-small-linux.json` as a starting point. Contract
schema version 1 requires `build` labels, `binary_max_bytes`, and a nonempty
`benchmarks` map. Each named benchmark declares its exact measured `iterations`
and a nonempty `max` map selecting allocation metrics. Realtime entries also
declare exact `subscribers` and `payload_bytes`. Unknown keys, missing metrics,
duplicate workload identities/JSON keys, inconsistent buckets, noninteger/negative metrics,
changed workload dimensions, and incompatible baselines fail closed. Extra
uncontracted benchmark rows are validated but do not create implicit budgets.
Realtime identity includes subscriber count and payload size; this first contract
schema selects one such pairing per named realtime scenario.

Exit status is **0** when all budgets pass, **1** for a budget violation (with
the complete JSON report), and **2** for invalid/missing input (stderr diagnostic,
no report). Version 1 reports contain artifact/contract hashes, declared build
labels, each actual/limit/pass result, median timings in nanoseconds, and optional
baseline deltas. Save them as CI artifacts; a zero baseline timing produces a
null percentage, not a fabricated improvement. Baselines must use the identical
contract bytes, including build/workload labels and limits.
Binary inputs are capped at 256 MiB, and contract, benchmark JSONL and baseline
files at 8 MiB each. Size preflight rejects oversized files before reading or
hashing; bounded reads also reject files that grow past the cap during the check.
Exceeding these input caps is invalid input (exit 2), not a budget violation (exit 1).

**Units and limits matter.** Ordinary `allocs` and `bytes` are totals over all
measured iterations, excluding warmup; bytes count successful allocation requests,
not resize/remap growth. `peak_live` is the maximum logical requested live bytes
in one invocation. Arena reset ends those logical lifetimes, even though backing
capacity is retained. These are **not process RSS**, SQLite/libc allocation totals,
or retained arena capacity. Realtime `allocs_per_event`/`bytes_per_event` are
integer-normalized per-event values; `peak_live_bytes` remains an absolute logical
peak. Median timings are advisory only; compare them on a controlled, otherwise
idle host with matching workload, target, toolchain and build modes. The offline
CLI trusts declared build labels: hashes bind files, not their build provenance.
It neither rebuilds the app nor authenticates supplied benchmark observations.

The example's ceilings are deliberate regression headroom, not universal promises.
Initial x86_64 Linux measurements with Zig 0.16.0 were approximately 3.25 MB for
the configured server (4 MB ceiling), 0 allocations for JWT verification,
38,000 allocations / 3,214,000 requested bytes / 1,028 logical peak bytes for
2,000 record reads, and 34,000 / 8,032,000 / 5,198 for 2,000 filter compilations.
Record/filter ceilings allow roughly 5–17% headroom; the smoke fixture has exact
known counts. Review changes to the workload or toolchain before recalibrating
budgets. Different app features and targets need their own measured contract.

## The build wiring (copy this)

`zigbase.addTest` gives you a test artifact wired with ZigBase's `.simple`-mode
runner. It reports through the process exit code and fails on assertions, leaked
allocations, logged errors, and abnormal process exits.

Zig 0.16.0's default server-mode runner (`--listen=-`) can print a misleading
`failed command:` label after successful tests when the child leaves stderr output
at exit. A single newline from facil.io's destructor is sufficient; the reproduced
case exits zero and reports all tests passed. This is a diagnostic bug, not evidence
of an app crash or a runner race. Check **both the command exit status and the final
build summary**. A nonzero exit, signal, failed test, or leak is a real failure and
must be investigated separately.

The supported `addTest` wiring avoids this label on successful runs. Contributors
can reproduce the distinction and verify real failure handling with
`mise exec zig@0.16.0 python@3.13 -- python tests/test_runner/verify.py`. The
[regression fixture](https://github.com/valthon/zigbase/blob/main/tests/test_runner/README.md) checks the installed compiler
and the shipped runner without patching either. Upstream diagnosis remains tracked
in [#261](https://github.com/valthon/zigbase/issues/261). The
[standalone Zig+C reproduction](https://github.com/valthon/zigbase/blob/main/diagnostics/issue-261/README.md) also verifies
a candidate upstream diagnostic patch against a private compiler-library copy;
it does not modify the installed compiler.

```zig
const std = @import("std");
const zigbase = @import("zigbase"); // the dependency's build.zig

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("zigbase", .{ .target = target, .optimize = optimize });

    const app_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigbase.addTo(dep, app_mod); // adds the import AND sets link_libc

    const exe = b.addExecutable(.{ .name = "myapp", .root_module = app_mod });
    b.installArtifact(exe);

    const tests = zigbase.addTest(b, dep, .{ .root_module = app_mod });
    b.step("test", "Run tests").dependOn(&b.addRunArtifact(tests).step);
}
```

Two things people get wrong here:

- **Reuse `app_mod` for the test artifact.** Rooting a second module at
  `src/main.zig` puts one file in two modules, which Zig rejects.
- **Your app must be reachable from a test.** An `App(.{...})` literal inlined
  into `main` is not. Hoist it:

  ```zig
  pub const App = zigbase.App(.{ /* … */ });

  pub fn main(init: std.process.Init) !void {
      return App.runCli(init);
  }
  ```

`zigbase init --framework` scaffolds all of this already.

## A worked test

```zig
test "the list rule hides drafts from the public" {
    var t = try zigbase.testing.start(App, .{}); // migrations run, onBootstrap fires
    defer t.deinit();                            // tears down the app + the tempdir

    _ = try t.createRecord("posts", .{ .title = "Draft", .published = false });
    _ = try t.createRecord("posts", .{ .title = "Live", .published = true });

    const r = try t.request(.GET, "/api/collections/posts/records", .{});
    try std.testing.expectEqual(@as(u16, 200), r.status);

    const page = try r.json(struct { items: []struct { title: []const u8 } });
    try std.testing.expectEqual(@as(usize, 1), page.items.len);
    try std.testing.expectEqualStrings("Live", page.items[0].title);
}
```

Authenticating is two calls, and they are not equivalent:

```zig
// Real endpoint, full fidelity: rate limiter, argon2 verify, verification gate,
// and the beforeAuthSuccess/onAuth hooks all run.
const user = try t.loginPassword("users", "u@example.com", "hunter2xyz");

// Direct JWT mint: deterministic, no HTTP, none of the above runs.
const sess = try t.mintSession("users", user_id);

const r = try t.request(.POST, "/api/collections/users/auth-refresh", .{ .auth = user });
```

Use `loginPassword` when the login path is part of what you are testing, and
`mintSession` when you just need an authenticated caller.

Mail and the clock are seams too:

```zig
var t = try zigbase.testing.start(App, .{ .fake_now_unix = 1_800_000_000 });
defer t.deinit();
const mail = try t.captureMail(); // install BEFORE the request that sends
```

The complete API — every `StartOptions` field, every `request` option, the
`Response` accessors, seeding helpers, and encrypted-field apps — is in
[framework.md §15](https://github.com/valthon/zigbase/blob/main/docs/framework.md#15-testing-your-app-zigbasetesting).

## What in-process tests do NOT cover

A green `zig build test` says nothing about:

- the HTTP server itself, TLS, or a reverse proxy in front of it;
- CORS and browser cookie behavior (including the `Secure` flag — see
  `--insecure-cookies`);
- WebSocket upgrades and realtime delivery over a socket;
- static-file serving and your frontend;
- your client SDK's wire handling.

Cover those with a spawned server. `examples/blog` does both and its README
says which is which.

## Traps: a spawned-server suite tests whatever is on disk

A spawned-server suite (Python, or your own language — see below) shells out
to a binary that has to already exist. Neither the harness nor the failure
message tells you when that binary is **missing** or was built from a
**different version of your tree** than the one you're testing — both surface
as confusing failures that look like product defects.

**Stale artifact — the binary predates your tree.** The binary your suite
drives isn't kept in sync with your source automatically. Any workflow that
changes the tree between builds — a rebase, a stash, a branch switch, an
interactive-rebase stop, a history cleanup pass — can leave a binary missing
code the tests now expect. The tell is the *shape* of the failure: a coherent
subset fails — typically every test tied to one feature — while everything
else passes cleanly. A real product defect rarely takes out exactly one
feature's whole test file and leaves every neighbor green. ZigBase's own CLI
suite has hit this concretely: a run where `test_doctor.py`'s 7 tests failed
and the other 16 CLI tests (`test_serve_lifecycle.py` +
`test_serve_ephemeral.py`) all passed looked alarming, but it meant the binary
predated `doctor` landing in the tree, not that `doctor` was broken. The
danger isn't carelessness — a coherent-sounding cause ("release builds must
break the CLI") arrives early and stops the search, and it explains the
symptom well enough that it never feels like a guess. Reading the actual list
of failing tests, not just a `tail -1` summary line, is what makes the
one-file shape hard to miss. When you see it, ask the binary before you
suspect the code: `zigbase help` (or your app's equivalent) shows a missing
command instantly. Fix: rebuild before you test, every time you've touched
the tree since the last build:

```sh
zig build
```

Positive result worth knowing on its own: a properly built
`zig build -Ddev-mode=false` binary passes ZigBase's own `tests/cli` 23/23 —
a prod-mode build does not break the CLI, not even `--ephemeral`, whose
random-suffix generator is the one CLI feature wired to the dev-mode-gated
fake-entropy seam
([framework.md §14](https://github.com/valthon/zigbase/blob/main/docs/framework.md#14-test--dev-mode-determinism-seams)). If
you're staring at CLI failures after a flag-varied build, that's not it —
look for staleness instead.

If you're working on ZigBase itself rather than an app built on it, there is
a second, related instance: some of the repo's own browser-suite fixtures are
separate `zig build <name>` steps that a plain `zig build` never produces,
so a fresh checkout's local run reports a batch of setup errors that CI
doesn't. See [CONTRIBUTING.md](https://github.com/valthon/zigbase/blob/main/CONTRIBUTING.md) for the exact build steps
that suite needs.

Both instances are the same class: **a spawned-server suite tests whatever
artifacts already exist on disk, and nothing tells you when one is missing or
no longer matches your source.** Before believing such a failure is a product
defect, check which artifacts are on disk and how and when they were built.

## Testing without Zig

If ZigBase is a backend-in-a-box for you — no `build.zig` anywhere — the test
story is a real server and your own language's test runner:

```sh
zigbase serve --data-dir "$(mktemp -d)" --http-port 8099 --insecure-cookies &
# ... wait for GET /api/health, run your suite against http://127.0.0.1:8099 ...
```

Bind an unused port per suite and give each run its own data directory, or two
suites will fight over the database. The example harnesses under
`examples/*/test/harness.ts` are a working reference for the wait-for-health and
free-port dance.

## See also

- [framework.md §15](https://github.com/valthon/zigbase/blob/main/docs/framework.md#15-testing-your-app-zigbasetesting) — the full `zigbase.testing` API
- [framework.md §14](https://github.com/valthon/zigbase/blob/main/docs/framework.md#14-test--dev-mode-determinism-seams) — determinism seams for a spawned server (`ZIGBASE_FAKE_NOW`, `ZIGBASE_FAKE_SEED`, `zigbase.testcapture`)
- [recipes.md](https://github.com/valthon/zigbase/blob/main/docs/recipes.md) — task-oriented recipes, including a deterministic-test recipe

## Durable queue capacity checks

`zig build durable-capacity-fixture check-durable-capacity-contracts` builds a
consumer with operator-only enqueue/inspection routes and rejects invalid budgets.
Run `ZIGBASE_TEST_DURABLE_CAPACITY_BINARY="$PWD/zig-out/bin/durable-capacity-fixture"
python -m pytest tests/admin/test_durable_capacity.py -q` for concurrent HTTP count
and UTF-8 byte limits. Unit tests cover retained retry/dead-letter/canceled rows,
GC recovery, rollback, shrunken legacy queues, independent SQLite producers and
reopen. `zig build test -Dcoordinated-admission=true` also verifies that saturation
prevents durable claims and releases the batch permit after completion.

With `-Dpostgres=true` and a dedicated `ZIGBASE_PG_TEST_URL`, live tests use two
connections to verify transaction-held admission contention, post-commit limits,
rollback recovery, READ COMMITTED enforcement, reclaim and GC. The database role
needs schema creation permission; individual queue tests isolate their own schema.
