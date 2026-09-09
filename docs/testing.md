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

For contributors working inside a **trusted ZigBase checkout**, the standard-library
Python tool `tools/agent_tests.py` provides static JSON test inventory, exact
module/function selection, and bounded structured execution reports. It is not
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
and binary-resolver tooling. Item `requirements` conservatively describe module
setup; non-browser selections do not need Chromium. Admin fixtures build the
appropriate binaries when necessary; the advertised prebuilt override is
`ZIGBASE_TEST_BINARY`. Build time counts toward the execution deadline. Prepare binaries
before a short run if needed. A function's ID is not a fully collected pytest
node list: parametrized cases run together, and class methods/dynamic cases are
not individually advertised. Zig unit tests and SDK suites still use their
existing runners. No changed-file dependency inference or full-suite coverage
claim is made; continue running the complete relevant CI suites before shipping.

`run` only accepts inventory IDs and fixed pytest argv, not arbitrary executables,
options, paths or shell strings. It runs from the checkout root, removes
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
[the agent guide](agents.md#focused-repository-tests).

For a conservative first test selection after edits, run
`mise exec python@3.13 -- python tools/agent_tests.py affected --base origin/main`.
This compares the base commit to the working tree plus non-ignored untracked
files, returning module selectors without executing them. Curated dependencies
select related allowlisted modules; unknown paths select the entire allowlist.
The JSON explicitly reports incomplete coverage: this never replaces the full
relevant Zig, browser, SDK, docs or other CI suites. See the agent guide for Git
limits, filename encoding and snapshot limitations.

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
test runner. That runner matters: `zig build test` otherwise runs the test
binary in server mode (`--listen=-`), and an app booted by the harness does
enough work at process exit that Zig 0.16's build runner can mis-read a normal
exit as a crash — printing `failed command: … --listen=-` and intermittently
failing the build. The `.simple` runner rides the exit code instead, and fails
the build on a leaked allocation.

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
[framework.md §15](framework.md#15-testing-your-app-zigbasetesting).

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
([framework.md §14](framework.md#14-test--dev-mode-determinism-seams)). If
you're staring at CLI failures after a flag-varied build, that's not it —
look for staleness instead.

If you're working on ZigBase itself rather than an app built on it, there is
a second, related instance: some of the repo's own browser-suite fixtures are
separate `zig build <name>` steps that a plain `zig build` never produces,
so a fresh checkout's local run reports a batch of setup errors that CI
doesn't. See [CONTRIBUTING.md](../CONTRIBUTING.md) for the exact build steps
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

- [framework.md §15](framework.md#15-testing-your-app-zigbasetesting) — the full `zigbase.testing` API
- [framework.md §14](framework.md#14-test--dev-mode-determinism-seams) — determinism seams for a spawned server (`ZIGBASE_FAKE_NOW`, `ZIGBASE_FAKE_SEED`, `zigbase.testcapture`)
- [recipes.md](recipes.md) — task-oriented recipes, including a deterministic-test recipe
