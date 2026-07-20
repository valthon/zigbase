# Allocator Ownership Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the benchmark harness, the compile-enforced `RequestArena` contract, and the CI ratchet, then prove the pattern end-to-end by converting `jwt` to allocator-agnostic contracts.

**Architecture:** Four ownership contracts (self-freeing / owned-result / caller-buffer / arena-scoped) with self-freeing as the default and the arena demoted to a compile-enforced exception. A `zig build bench` harness measures ns/op with an allocation size histogram so conversions are proven to *remove* allocation rather than relocate it. A CI allowlist ratchet stops new leak-masked tests appearing.

**Tech Stack:** Zig 0.16.0 (pinned via mise), bash for CI checks, existing `scripts/check-gating.sh` conventions.

## Global Constraints

- Zig version is **0.16.0 exactly**, invoked as `mise exec zig@0.16.0 -- zig`. Another 0.16.x may not work.
- `zig build test` prints a spurious `failed command: …` line even on success. **The authoritative signal is the `Build Summary: N/N tests passed` line** (use `--summary all`).
- A new `src/*.zig` file's tests do not run until it is added to the `test { _ = @import(...); }` block in `src/root.zig`.
- Never edit `CHANGELOG.md`; add a fragment in `changelog.d/<slug>.md` with `### <Section>` headings.
- Run `mise exec zig@0.16.0 -- zig fmt <files>` before committing Zig changes.
- Design reference: `docs/superpowers/specs/2026-07-19-allocator-ownership-design.md`.

## Scope note (why this plan stops where it does)

The design's central mechanic is that **the compiler generates the migration
worklist**: flipping `ctx.arena` / `ev.arena` / `ctx.allocator` to `RequestArena`
turns every arena-dependent call path into a compile error. Bite-sized tasks
cannot be written for compile errors that do not exist yet.

So this plan delivers the **foundation and the proven exemplar** — harness,
baseline, type, ratchet, rule, and the `jwt` conversion. The field flip and the
triage of its worklist get their own plan, written once the worklist is real.
Each plan produces working, testable software on its own.

## File Structure

| File | Responsibility |
| --- | --- |
| `bench/counting_allocator.zig` (create) | Wrapping allocator: counts allocs, bytes, and a size histogram |
| `bench/harness.zig` (create) | Timing loop (warmup + N iters), stats (median/p95), text + `--json` output |
| `bench/main.zig` (create) | Registers and runs the seed benchmarks |
| `build.zig` (modify) | Add the `bench` step |
| `scripts/bench-compare.sh` (create) | Build+run two revisions, print deltas |
| `src/request_arena.zig` (create) | The `RequestArena` type |
| `scripts/check-allocator-contracts.sh` (create) | Allowlist ratchet |
| `scripts/allocator-allowlist.txt` (create) | `path<TAB>count<TAB>justification` |
| `NO_SLOP.md` (modify) | §2.1 extension: the four contracts + reviewer check |
| `src/jwt.zig` (modify) | Exemplar conversion to contracts 1 and 3 |
| `src/root.zig` (modify) | Register `request_arena.zig` for test discovery |

---

### Task 1: Counting allocator with size histogram

**Files:**
- Create: `bench/counting_allocator.zig`

**Interfaces:**
- Consumes: nothing.
- Produces: `CountingAllocator.init(child: std.mem.Allocator) CountingAllocator`, `.allocator() std.mem.Allocator`, `.stats() Stats`, and `Stats { allocs: u64, bytes: u64, buckets: [5]u64, peak_live: u64 }` with buckets ordered `[<=64, <=512, <=4K, <=64K, >64K]`.

- [ ] **Step 1: Write the failing test**

Create `bench/counting_allocator.zig` containing only the test:

```zig
const std = @import("std");

test "counts allocations into size buckets and tracks peak live bytes" {
    var c = CountingAllocator.init(std.testing.allocator);
    const a = c.allocator();

    const small = try a.alloc(u8, 8); // bucket 0
    const big = try a.alloc(u8, 100_000); // bucket 4
    a.free(small);
    a.free(big);

    const s = c.stats();
    try std.testing.expectEqual(@as(u64, 2), s.allocs);
    try std.testing.expectEqual(@as(u64, 100_008), s.bytes);
    try std.testing.expectEqual(@as(u64, 1), s.buckets[0]);
    try std.testing.expectEqual(@as(u64, 1), s.buckets[4]);
    try std.testing.expectEqual(@as(u64, 100_008), s.peak_live);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig test bench/counting_allocator.zig`
Expected: FAIL — `use of undeclared identifier 'CountingAllocator'`.

- [ ] **Step 3: Write the implementation**

Insert above the test in `bench/counting_allocator.zig`:

```zig
const Alignment = std.mem.Alignment;

pub const Stats = struct {
    allocs: u64 = 0,
    bytes: u64 = 0,
    /// [<=64B, <=512B, <=4K, <=64K, >64K] — distinguishes one large allocation
    /// from thousands of small ones, which byte totals hide.
    buckets: [5]u64 = .{0} ** 5,
    peak_live: u64 = 0,
};

pub const CountingAllocator = struct {
    child: std.mem.Allocator,
    st: Stats = .{},
    live: u64 = 0,

    pub fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    pub fn stats(self: *const CountingAllocator) Stats {
        return self.st;
    }

    pub fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = vAlloc,
        .resize = vResize,
        .remap = vRemap,
        .free = vFree,
    };

    fn bucketOf(len: usize) usize {
        if (len <= 64) return 0;
        if (len <= 512) return 1;
        if (len <= 4096) return 2;
        if (len <= 65536) return 3;
        return 4;
    }

    fn vAlloc(ctx: *anyopaque, len: usize, alignment: Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawAlloc(len, alignment, ra) orelse return null;
        self.st.allocs += 1;
        self.st.bytes += len;
        self.st.buckets[bucketOf(len)] += 1;
        self.live += len;
        if (self.live > self.st.peak_live) self.st.peak_live = self.live;
        return p;
    }

    fn vResize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ra)) return false;
        self.live = self.live + new_len - memory.len;
        if (self.live > self.st.peak_live) self.st.peak_live = self.live;
        return true;
    }

    fn vRemap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const p = self.child.rawRemap(memory, alignment, new_len, ra) orelse return null;
        self.live = self.live + new_len - memory.len;
        if (self.live > self.st.peak_live) self.st.peak_live = self.live;
        return p;
    }

    fn vFree(ctx: *anyopaque, memory: []u8, alignment: Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ra);
        self.live -= memory.len;
    }
};
```

- [ ] **Step 4: Run it to verify it passes**

Run: `mise exec zig@0.16.0 -- zig test bench/counting_allocator.zig`
Expected: PASS — `1 passed`.

- [ ] **Step 5: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt bench/counting_allocator.zig
git add bench/counting_allocator.zig
git commit -m "bench: counting allocator with size histogram"
```

---

### Task 2: Timing harness and `zig build bench` step

**Files:**
- Create: `bench/harness.zig`
- Create: `bench/main.zig`
- Modify: `build.zig` (after the `audit` step block near line 170)

**Interfaces:**
- Consumes: `CountingAllocator` from Task 1.
- Produces: `harness.run(name: []const u8, warmup: usize, iters: usize, ctx: anytype, comptime f: fn (@TypeOf(ctx), std.mem.Allocator) anyerror!void) !Result` and `harness.report(results: []const Result, json: bool, w: anytype) !void`; `Result { name, ns_median, ns_p95, allocs, bytes, buckets, peak_live }`.

- [ ] **Step 1: Write the failing test**

Create `bench/harness.zig` with only:

```zig
const std = @import("std");

test "run reports a median, a p95, and the allocation profile" {
    const Ctx = struct { n: usize };
    const F = struct {
        fn body(c: Ctx, a: std.mem.Allocator) anyerror!void {
            const buf = try a.alloc(u8, c.n);
            defer a.free(buf);
        }
    };
    const r = try run("alloc-8", 2, 10, Ctx{ .n = 8 }, F.body);
    try std.testing.expectEqualStrings("alloc-8", r.name);
    try std.testing.expect(r.ns_median > 0);
    try std.testing.expect(r.ns_p95 >= r.ns_median);
    try std.testing.expectEqual(@as(u64, 10), r.allocs); // measured iters only, warmup excluded
    try std.testing.expectEqual(@as(u64, 10), r.buckets[0]);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig test bench/harness.zig`
Expected: FAIL — `use of undeclared identifier 'run'`.

- [ ] **Step 3: Write the implementation**

Insert above the test in `bench/harness.zig`:

```zig
const ca = @import("counting_allocator.zig");

pub const Result = struct {
    name: []const u8,
    ns_median: u64,
    ns_p95: u64,
    allocs: u64,
    bytes: u64,
    buckets: [5]u64,
    peak_live: u64,
};

/// Warm up `warmup` times (JIT-free, but page/cache warm), then measure `iters`
/// timed runs. Allocation stats cover the MEASURED runs only.
pub fn run(
    name: []const u8,
    warmup: usize,
    iters: usize,
    ctx: anytype,
    comptime f: fn (@TypeOf(ctx), std.mem.Allocator) anyerror!void,
) !Result {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var w: usize = 0;
    while (w < warmup) : (w += 1) try f(ctx, gpa.allocator());

    var counting = ca.CountingAllocator.init(gpa.allocator());
    const a = counting.allocator();

    const samples = try gpa.allocator().alloc(u64, iters);
    defer gpa.allocator().free(samples);

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iters) : (i += 1) {
        timer.reset();
        try f(ctx, a);
        samples[i] = timer.read();
    }

    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const st = counting.stats();
    return .{
        .name = name,
        .ns_median = samples[iters / 2],
        .ns_p95 = samples[(iters * 95) / 100],
        .allocs = st.allocs,
        .bytes = st.bytes,
        .buckets = st.buckets,
        .peak_live = st.peak_live,
    };
}

/// Human table by default; `--json` emits one object per line for diffing.
pub fn report(results: []const Result, json: bool, w: anytype) !void {
    if (json) {
        for (results) |r| {
            try w.print(
                "{{\"name\":\"{s}\",\"ns_median\":{d},\"ns_p95\":{d},\"allocs\":{d},\"bytes\":{d},\"peak_live\":{d},\"buckets\":[{d},{d},{d},{d},{d}]}}\n",
                .{ r.name, r.ns_median, r.ns_p95, r.allocs, r.bytes, r.peak_live, r.buckets[0], r.buckets[1], r.buckets[2], r.buckets[3], r.buckets[4] },
            );
        }
        return;
    }
    try w.print("{s:<34} {s:>10} {s:>10} {s:>8} {s:>10}  {s}\n", .{ "benchmark", "ns/op", "p95", "allocs", "bytes", "size buckets (<=64,512,4K,64K,>64K)" });
    for (results) |r| {
        try w.print("{s:<34} {d:>10} {d:>10} {d:>8} {d:>10}  {d},{d},{d},{d},{d}\n", .{
            r.name, r.ns_median, r.ns_p95, r.allocs, r.bytes,
            r.buckets[0], r.buckets[1], r.buckets[2], r.buckets[3], r.buckets[4],
        });
    }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `mise exec zig@0.16.0 -- zig test bench/harness.zig`
Expected: PASS — `1 passed`.

- [ ] **Step 5: Add the runner with one smoke benchmark**

Create `bench/main.zig`:

```zig
const std = @import("std");
const harness = @import("harness.zig");

fn benchNoop(_: void, a: std.mem.Allocator) anyerror!void {
    const b = try a.alloc(u8, 16);
    defer a.free(b);
}

/// Zig 0.16 entry point: argv comes from `init.minimal.args` (NOT `std.process.argsAlloc`,
/// which this Zig does not provide), and stdout is `std.Io.File.stdout()` written through
/// an `Io` writer — the same shape `src/framework.zig:1838` and its `emit` helper use.
pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const arena = init.arena.allocator();

    const argv = try init.minimal.args.toSlice(arena);
    var json = false;
    for (argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--json")) json = true;
    }

    var results: std.ArrayList(harness.Result) = .empty;
    defer results.deinit(alloc);
    try results.append(alloc, try harness.run("smoke/alloc-16", 100, 1000, {}, benchNoop));

    var buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(init.io, &buf);
    try harness.report(results.items, json, &w.interface);
    try w.interface.flush();
}
```

- [ ] **Step 6: Wire the build step**

In `build.zig`, immediately after the `audit_step` block (near line 170), insert:

```zig
    // --- bench: allocation + timing harness (report-only; see the allocator-ownership spec)
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("zigbase", zigbase_mod);
    const bench_exe = b.addExecutable(.{ .name = "zigbase-bench", .root_module = bench_mod });
    const bench_run = b.addRunArtifact(bench_exe);
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run the benchmark harness (ns/op + allocation profile)");
    bench_step.dependOn(&bench_run.step);
```

- [ ] **Step 7: Run it to verify the step works**

Run: `mise exec zig@0.16.0 -- zig build bench`
Expected: a table with a `smoke/alloc-16` row, `allocs` = 1000, buckets `1000,0,0,0,0`.

Run: `mise exec zig@0.16.0 -- zig build bench -- --json`
Expected: one JSON object line containing `"name":"smoke/alloc-16"`.

- [ ] **Step 8: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt bench/harness.zig bench/main.zig build.zig
git add bench/harness.zig bench/main.zig build.zig
git commit -m "bench: timing harness and zig build bench step"
```

---

### Task 3: Seed benchmarks for the paths this migration touches

**Files:**
- Modify: `bench/main.zig`

**Interfaces:**
- Consumes: `harness.run`, the `zigbase` module.
- Produces: benchmark names `jwt/sign`, `jwt/verify`, `query/filter-compile` used by `scripts/bench-compare.sh` and the definition of done.

- [ ] **Step 1: Add the jwt benchmarks**

In `bench/main.zig`, add after the imports:

```zig
const zigbase = @import("zigbase");
const jwt = zigbase.jwt;
const crypto = zigbase.crypto;

const JwtCtx = struct { key: [32]u8, token: []const u8 };

fn benchJwtSign(c: JwtCtx, a: std.mem.Allocator) anyerror!void {
    const claims = jwt.Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 9999999999 };
    const t = try jwt.sign(a, claims, &c.key);
    defer a.free(t);
}

fn benchJwtVerify(c: JwtCtx, a: std.mem.Allocator) anyerror!void {
    _ = try jwt.verify(a, c.token, &c.key, 2000);
}
```

- [ ] **Step 2: Register them in main**

In `bench/main.zig`'s `main`, before the `report` call:

```zig
    const key = crypto.deriveKey("bench-secret", "tk1");
    const jwt_claims = jwt.Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 9999999999 };
    const jwt_token = try jwt.sign(alloc, jwt_claims, &key);
    defer alloc.free(jwt_token);
    const jctx = JwtCtx{ .key = key, .token = jwt_token };

    try results.append(alloc, try harness.run("jwt/sign", 100, 2000, jctx, benchJwtSign));
    try results.append(alloc, try harness.run("jwt/verify", 100, 2000, jctx, benchJwtVerify));
```

- [ ] **Step 3: Verify jwt symbols are exported**

Run: `grep -nE 'pub const (jwt|crypto)' src/root.zig`
Expected: both are re-exported. If either is missing, add `pub const jwt = @import("jwt.zig");` / `pub const crypto = @import("crypto.zig");` to `src/root.zig` before continuing.

- [ ] **Step 4: Run it**

Run: `mise exec zig@0.16.0 -- zig build bench`
Expected: rows for `jwt/sign` and `jwt/verify` with non-zero `allocs`. **Record this output — it is the pre-conversion baseline for Task 8.**

- [ ] **Step 5: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt bench/main.zig
git add bench/main.zig
git commit -m "bench: seed jwt sign/verify benchmarks"
```

---

### Task 4: `bench-compare.sh` and the recorded baseline

**Files:**
- Create: `scripts/bench-compare.sh`
- Create: `docs/superpowers/plans/baselines/2026-07-19-bench-main.json`

**Interfaces:**
- Consumes: `zig build bench -- --json`.
- Produces: `scripts/bench-compare.sh <rev-a> <rev-b>` printing a delta table.

- [ ] **Step 1: Write the script**

Create `scripts/bench-compare.sh`:

```bash
#!/usr/bin/env bash
# Build and run the bench harness at two revisions and print ns/op + alloc deltas.
# Report-only: this never fails on a regression (see the allocator-ownership spec —
# shared runners are too noisy for a threshold gate).
set -euo pipefail
cd "$(dirname "$0")/.."

A="${1:?usage: bench-compare.sh <rev-a> <rev-b>}"
B="${2:?usage: bench-compare.sh <rev-a> <rev-b>}"
ZIG=(mise exec zig@0.16.0 -- zig)
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

for rev in "$A" "$B"; do
  wt="$tmp/$(echo "$rev" | tr '/' '_')"
  git worktree add --detach "$wt" "$rev" >/dev/null 2>&1
  ( cd "$wt" && "${ZIG[@]}" build bench -- --json ) > "$tmp/$(basename "$wt").json"
  git worktree remove --force "$wt" >/dev/null 2>&1
done

python3 - "$tmp/$(basename "$A" | tr '/' '_').json" "$tmp/$(basename "$B" | tr '/' '_').json" <<'PY'
import json, sys
def load(p):
    out = {}
    for line in open(p):
        line = line.strip()
        if line:
            r = json.loads(line)
            out[r["name"]] = r
    return out
a, b = load(sys.argv[1]), load(sys.argv[2])
print(f"{'benchmark':<34}{'ns/op A':>10}{'ns/op B':>10}{'delta':>9}{'allocs A':>10}{'allocs B':>10}")
for name in sorted(set(a) | set(b)):
    ra, rb = a.get(name), b.get(name)
    if not ra or not rb:
        print(f"{name:<34}{'(only in one revision)':>49}")
        continue
    d = (rb["ns_median"] - ra["ns_median"]) / ra["ns_median"] * 100 if ra["ns_median"] else 0.0
    print(f"{name:<34}{ra['ns_median']:>10}{rb['ns_median']:>10}{d:>8.1f}%{ra['allocs']:>10}{rb['allocs']:>10}")
PY
```

- [ ] **Step 2: Make it executable and smoke-test it**

```bash
chmod +x scripts/bench-compare.sh
./scripts/bench-compare.sh HEAD HEAD
```
Expected: a table where every delta is `0.0%` (same revision twice).

- [ ] **Step 3: Record the baseline**

```bash
mkdir -p docs/superpowers/plans/baselines
mise exec zig@0.16.0 -- zig build bench -- --json > docs/superpowers/plans/baselines/2026-07-19-bench-main.json
cat docs/superpowers/plans/baselines/2026-07-19-bench-main.json
```
Expected: one JSON line per benchmark. This is the reference every later conversion is judged against.

- [ ] **Step 4: Commit**

```bash
git add scripts/bench-compare.sh docs/superpowers/plans/baselines/2026-07-19-bench-main.json
git commit -m "bench: comparison script and recorded baseline"
```

---

### Task 5: The `RequestArena` type

**Files:**
- Create: `src/request_arena.zig`
- Modify: `src/root.zig` (test block + export)

**Interfaces:**
- Consumes: nothing.
- Produces: `RequestArena` with field `a: std.mem.Allocator` and `RequestArena.from(*std.heap.ArenaAllocator) RequestArena`.

- [ ] **Step 1: Write the failing test**

Create `src/request_arena.zig`:

```zig
const std = @import("std");

test "RequestArena is constructible only from a real arena and exposes .a" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const ra = RequestArena.from(&arena);
    const buf = try ra.a.alloc(u8, 8);
    try std.testing.expectEqual(@as(usize, 8), buf.len);

    // Contract-1 helpers take a plain Allocator; `.a` is the deliberate bridge.
    try std.testing.expect(@TypeOf(ra.a) == std.mem.Allocator);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `mise exec zig@0.16.0 -- zig test src/request_arena.zig`
Expected: FAIL — `use of undeclared identifier 'RequestArena'`.

- [ ] **Step 3: Write the implementation**

Insert above the test:

```zig
/// A request-scoped arena. Deliberately NOT `std.mem.Allocator`: an arena-scoped API
/// cannot be handed a GPA by accident, the dependency is visible in every signature,
/// and the compiler checks it.
///
/// Taking a function `RequestArena` is contract 4 in the allocator-ownership design
/// (docs/superpowers/specs/2026-07-19-allocator-ownership-design.md) and REQUIRES a
/// written justification meeting all three of:
///   1. the result is a graph of interlinked allocations, not a single buffer; and
///   2. freeing them individually would be pointer-chasing for no benefit; and
///   3. the lifetime is genuinely request-scoped — it dies at a known boundary.
/// "It is currently written that way" is not a justification.
pub const RequestArena = struct {
    /// The deliberate escape hatch: contract-1 helpers take a plain `Allocator`, and
    /// they are correct under any allocator including this arena. Greppable on purpose —
    /// stashing `.a` beyond the request lifetime is the one misuse the type cannot stop.
    a: std.mem.Allocator,

    /// Constructible ONLY from a real arena, at the boundary that owns and deinits it.
    /// Taking the concrete `*ArenaAllocator` (not an `Allocator`) makes it structurally
    /// impossible to wrap a GPA just to silence the compiler.
    pub fn from(arena: *std.heap.ArenaAllocator) RequestArena {
        return .{ .a = arena.allocator() };
    }
};
```

- [ ] **Step 4: Run it to verify it passes**

Run: `mise exec zig@0.16.0 -- zig test src/request_arena.zig`
Expected: PASS — `1 passed`.

- [ ] **Step 5: Register for test discovery and export**

In `src/root.zig`, add to the `test { ... }` block alongside the other imports:

```zig
    _ = @import("request_arena.zig");
```

and with the other public re-exports:

```zig
pub const RequestArena = @import("request_arena.zig").RequestArena;
```

- [ ] **Step 6: Verify the suite still passes**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep "Build Summary"`
Expected: `Build Summary: 8/8 steps succeeded; N/N tests passed` with 0 failures.

- [ ] **Step 7: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/request_arena.zig src/root.zig
git add src/request_arena.zig src/root.zig
git commit -m "feat: add compile-enforced RequestArena contract type"
```

---

### Task 6: CI allowlist ratchet

**Files:**
- Create: `scripts/check-allocator-contracts.sh`
- Create: `scripts/allocator-allowlist.txt`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: `scripts/check-allocator-contracts.sh` exiting non-zero when a file's masked-test count exceeds its allowlist entry.

- [ ] **Step 1: Generate the initial allowlist**

```bash
{
  echo "# path<TAB>count<TAB>justification"
  echo "# A test may wrap testing.allocator in an arena ONLY if the code under test takes"
  echo "# RequestArena (contract 4). Every line here is a promise to remove it or justify it."
  grep -rc 'ArenaAllocator.init(std.testing.allocator)' src/ \
    | grep -v ':0$' \
    | awk -F: '{printf "%s\t%s\tPRE-EXISTING: not yet migrated to the ownership contracts\n", $1, $2}' \
    | sort
} > scripts/allocator-allowlist.txt
wc -l scripts/allocator-allowlist.txt
```
Expected: ~104 lines (3 header + ~101 files).

- [ ] **Step 2: Write the checker**

Create `scripts/check-allocator-contracts.sh`:

```bash
#!/usr/bin/env bash
# Allocator-ownership ratchet (see docs/superpowers/specs/2026-07-19-allocator-ownership-design.md).
#
# Wrapping `std.testing.allocator` in an arena DISABLES Zig's leak detector for that
# test. That is legitimate only when the code under test takes `RequestArena`
# (contract 4). This check does not try to prove that statically — it ratchets: every
# masked test is listed with a justification, and a NEW one fails the build until it is
# either removed or argued for in the allowlist.
set -euo pipefail
cd "$(dirname "$0")/.."

ALLOW=scripts/allocator-allowlist.txt
fail=0

while IFS= read -r line; do
  file="${line%%:*}"
  count="${line##*:}"
  allowed="$(awk -F'\t' -v f="$file" '$1 == f { print $2 }' "$ALLOW" | head -1)"
  if [ -z "$allowed" ]; then
    echo "ERROR: $file has $count arena-masked test(s) but no allowlist entry."
    echo "       Convert them to raw std.testing.allocator, or add a justified entry to $ALLOW."
    fail=1
  elif [ "$count" -gt "$allowed" ]; then
    echo "ERROR: $file has $count arena-masked test(s), allowlist permits $allowed."
    echo "       A new masked test disables leak detection — convert it or raise the entry with a reason."
    fail=1
  fi
done < <(grep -rc 'ArenaAllocator.init(std.testing.allocator)' src/ | grep -v ':0$')

# Stale entries: a file that no longer has masked tests should drop off the list.
while IFS=$'\t' read -r file count _rest; do
  case "$file" in \#*|"") continue ;; esac
  actual="$(grep -c 'ArenaAllocator.init(std.testing.allocator)' "$file" 2>/dev/null || echo 0)"
  if [ "$actual" -lt "$count" ]; then
    echo "STALE: $file now has $actual masked test(s), allowlist still claims $count — lower it."
    fail=1
  fi
done < "$ALLOW"

if [ "$fail" -eq 0 ]; then echo "allocator contracts: OK"; fi
exit "$fail"
```

- [ ] **Step 3: Verify it passes on the current tree**

```bash
chmod +x scripts/check-allocator-contracts.sh
./scripts/check-allocator-contracts.sh
```
Expected: `allocator contracts: OK`.

- [ ] **Step 4: Verify it actually catches a new masked test**

```bash
printf '\ntest "temp ratchet probe" {\n    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);\n    defer arena.deinit();\n    _ = arena.allocator();\n}\n' >> src/jwt.zig
./scripts/check-allocator-contracts.sh || echo "EXPECTED FAILURE ABOVE"
```
Expected: an `ERROR: src/jwt.zig has N ... allowlist permits N-1` line, then `EXPECTED FAILURE ABOVE`.

Now revert the probe **with Edit, not `git checkout`** (the file has uncommitted work in later tasks): delete exactly the 5 appended lines from the end of `src/jwt.zig`, then re-run:

```bash
./scripts/check-allocator-contracts.sh
```
Expected: `allocator contracts: OK`.

- [ ] **Step 5: Wire it into CI**

In `.github/workflows/ci.yml`, in the same job that runs `scripts/check-gating.sh`, add a step immediately after it:

```yaml
      - name: Allocator ownership contracts (ratchet)
        run: ./scripts/check-allocator-contracts.sh
```

- [ ] **Step 6: Commit**

```bash
git add scripts/check-allocator-contracts.sh scripts/allocator-allowlist.txt .github/workflows/ci.yml
git commit -m "ci: ratchet against new leak-masked tests"
```

---

### Task 7: Document the contracts in NO_SLOP.md

**Files:**
- Modify: `NO_SLOP.md` (insert after the §2.2 block, before `### 2.3`)

**Interfaces:**
- Consumes: nothing.
- Produces: the reviewer-facing rule referenced by every later conversion.

- [ ] **Step 1: Insert the new section**

In `NO_SLOP.md`, immediately before the line `### 2.3 Errors are values — none may be silently ignored`, insert:

```markdown
### 2.2a Ownership contracts — what a function returns and who frees it

§2.1 covers *taking* an allocator and §2.2 covers pairing alloc/free, but the bug
that survives both is a function that allocates scratch and never frees it —
correct under a caller's arena, a leak under any other allocator. Every
allocator-taking function must be exactly one of these, and say which:

| # | Contract | Shape | Promise |
| - | -------- | ----- | ------- |
| 1 | **Self-freeing** (default) | `fn f(alloc, …) ![]u8` | Frees all scratch; exactly one allocation escapes — the return. Correct under ANY allocator. |
| 2 | **Owned-result** | `fn f(alloc, …) !Result` + `Result.deinit(alloc)` | Result owns an internal graph; caller deinits. |
| 3 | **Caller-buffer** | `fn f(buf: []u8, …) …` | Allocates nothing. Preferred when output is bounded by its input. |
| 4 | **Arena-scoped** | `fn f(arena: RequestArena, …) !T` | Interlinked graph reclaimed by arena drop. Compile-enforced; needs justification. |

- **Flag:** a function that allocates scratch and returns without freeing it, relying on the caller having passed an arena. That is contract 4 without the type — the defect this section exists to stop.
- **Contract 4 must be earned.** All three must hold: (1) the result is a graph of interlinked allocations, not a single buffer; (2) freeing them individually would be pointer-chasing for no benefit; (3) the lifetime is genuinely request-scoped. "It is currently written that way" and "adding `defer`s is tedious" are NOT justifications.
- **Reviewer check (mechanical):** *Which contract is this function? Does its test use raw `std.testing.allocator` (leak detection ON)? If it takes `RequestArena`, where is the written justification?*
- **Wrapping `std.testing.allocator` in an arena disables Zig's leak detector** for that test. Legitimate only for contract 4, and every instance is listed in `scripts/allocator-allowlist.txt`; `scripts/check-allocator-contracts.sh` fails the build on a new one.
```

- [ ] **Step 2: Verify the surrounding structure is intact**

Run: `grep -nE '^### 2\.[0-9]' NO_SLOP.md`
Expected: `2.1`, `2.2`, `2.2a`, `2.3`, `2.4`, `2.5`, `2.6` in ascending order.

- [ ] **Step 3: Commit**

```bash
git add NO_SLOP.md
git commit -m "docs: add ownership contracts to the review standard"
```

---

### Task 8: Convert `jwt` to allocator-agnostic contracts (the exemplar)

**Files:**
- Modify: `src/jwt.zig`
- Modify: `bench/main.zig` (verify benchmark switches to the new API)
- Modify: `scripts/allocator-allowlist.txt` (drop `src/jwt.zig`)
- Create: `changelog.d/jwt-ownership-contracts.md`

**Interfaces:**
- Consumes: nothing.
- Produces: `jwt.verifyInto(scratch: []u8, token: []const u8, key: []const u8, now: i64) JwtError!Claims` and `jwt.peekClaimsInto(scratch: []u8, token: []const u8) JwtError!Claims`; `jwt.scratch_size` (a `usize` constant); new error `error.TokenTooLarge`. `jwt.sign` is unchanged (already contract 1).

**Design note for the implementer:** `verify` currently returns `Claims` whose
strings borrow the JSON parse tree it allocated, so it *cannot* free that tree —
contract 4 without the type. Claims are not bounded by a constant (`pl` is
application-supplied opaque state), so a fixed-size struct buffer is wrong.
Contract 3 is achieved by taking a **caller-provided scratch buffer** driven by a
`FixedBufferAllocator`: zero heap allocation, the existing parse logic is reused
unchanged, and an over-large token fails closed with `error.TokenTooLarge`.

- [ ] **Step 1: Write the failing tests**

Add to `src/jwt.zig` (leak detection ON — raw `std.testing.allocator`):

```zig
test "verifyInto round-trips claims with zero heap allocation" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .csrf = "c1", .iat = 1000, .exp = 2000 };

    const token = try sign(a, claims, &key);
    defer a.free(token);

    var scratch: [scratch_size]u8 = undefined;
    const out = try verifyInto(&scratch, token, &key, 1500);
    try std.testing.expectEqualStrings("u1", out.id);
    try std.testing.expectEqualStrings("users", out.collection);
    try std.testing.expectEqual(TokenType.auth, out.type);
    try std.testing.expectEqualStrings("c1", out.csrf);
}

test "verifyInto fails closed when the scratch buffer is too small" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    defer a.free(token);

    var tiny: [8]u8 = undefined;
    try std.testing.expectError(error.TokenTooLarge, verifyInto(&tiny, token, &key, 1500));
}

test "verifyInto still rejects a tampered payload and an expired token" {
    const a = std.testing.allocator;
    const key = crypto.deriveKey("secret", "tk1");
    const claims = Claims{ .id = "u1", .collection = "users", .type = .auth, .iat = 1000, .exp = 2000 };
    const token = try sign(a, claims, &key);
    defer a.free(token);

    var scratch: [scratch_size]u8 = undefined;
    try std.testing.expectError(error.Expired, verifyInto(&scratch, token, &key, 3000));

    const bad = try a.dupe(u8, token);
    defer a.free(bad);
    bad[bad.len - 1] = if (bad[bad.len - 1] == 'A') 'B' else 'A';
    try std.testing.expectError(error.BadSignature, verifyInto(&scratch, bad, &key, 1500));
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep -E "verifyInto|Build Summary"`
Expected: compile failure — `use of undeclared identifier 'verifyInto'`.

- [ ] **Step 3: Implement the contract-3 API**

In `src/jwt.zig`, add `TokenTooLarge` to the `JwtError` set, then add:

```zig
/// Scratch needed to decode + parse the largest token we accept. The decoded payload is
/// smaller than the token itself, so this bounds both; an over-large token fails closed
/// with `error.TokenTooLarge` rather than allocating.
pub const scratch_size: usize = 8192;

/// Contract 3 (caller-buffer): verifies signature + expiry and returns claims that BORROW
/// `scratch`. Allocates nothing on the heap — `scratch` is the only storage, so the claims
/// are valid exactly as long as the caller keeps it alive. Prefer this over `verify`.
pub fn verifyInto(scratch: []u8, token: []const u8, key: []const u8, now: i64) JwtError!Claims {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    return verify(fba.allocator(), token, key, now) catch |e| switch (e) {
        error.OutOfMemory => error.TokenTooLarge,
        else => e,
    };
}

/// Contract 3 counterpart of `peekClaims`: decodes the payload WITHOUT verifying the
/// signature or expiry, borrowing `scratch`. Allocates nothing on the heap.
pub fn peekClaimsInto(scratch: []u8, token: []const u8) JwtError!Claims {
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    return peekClaims(fba.allocator(), token) catch |e| switch (e) {
        error.OutOfMemory => error.TokenTooLarge,
        else => e,
    };
}
```

Then update the doc comments on `verify` and `peekClaims` to record what they are:

```zig
/// Contract 4 (arena-scoped) — the returned `Claims` borrow the JSON parse tree allocated
/// from `alloc`, so this function cannot free it. Callers must pass an arena. PREFER
/// `verifyInto`, which is contract 3 and allocates nothing. Retained for callers already
/// holding a request arena; it is scheduled for removal once they migrate.
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `mise exec zig@0.16.0 -- zig build test --summary all 2>&1 | grep "Build Summary"`
Expected: `Build Summary: 8/8 steps succeeded; N/N tests passed`, 0 failures and **0 leaks** — the new tests use raw `std.testing.allocator`.

- [ ] **Step 5: Point the benchmark at the zero-alloc path**

In `bench/main.zig`, replace `benchJwtVerify` with:

```zig
fn benchJwtVerify(c: JwtCtx, _: std.mem.Allocator) anyerror!void {
    var scratch: [jwt.scratch_size]u8 = undefined;
    _ = try jwt.verifyInto(&scratch, c.token, &c.key, 2000);
}
```

- [ ] **Step 6: Prove the conversion removed allocation rather than relocating it**

Run: `mise exec zig@0.16.0 -- zig build bench`
Expected: the `jwt/verify` row now shows **`allocs` = 0** and all-zero buckets, versus the non-zero baseline recorded in Task 3/4. `ns/op` should not increase; if it does, read the histogram before proceeding and record the explanation in the commit message.

- [ ] **Step 7: Drop jwt from the allowlist and confirm the ratchet**

Remove the `src/jwt.zig` line from `scripts/allocator-allowlist.txt`, then:

```bash
./scripts/check-allocator-contracts.sh
```
Expected: `allocator contracts: OK`. (If it reports `STALE`, the file still contains a masked test — convert it before continuing.)

- [ ] **Step 8: Add the changelog fragment**

Create `changelog.d/jwt-ownership-contracts.md`:

```markdown
### Fixes

- JWT signing no longer leaks its intermediate buffers when handed a non-arena allocator: `jwt.sign` now frees the payload JSON, both base64 encodings, and the signing input, leaving only the returned token allocated.

### Features

- Added `jwt.verifyInto` and `jwt.peekClaimsInto`, which decode and verify a token into a caller-provided scratch buffer with **zero heap allocation**. An over-large token fails closed with `error.TokenTooLarge`. The allocator-taking `jwt.verify`/`jwt.peekClaims` remain for callers already holding a request arena.
```

- [ ] **Step 9: Commit**

```bash
mise exec zig@0.16.0 -- zig fmt src/jwt.zig bench/main.zig
git add src/jwt.zig bench/main.zig scripts/allocator-allowlist.txt changelog.d/jwt-ownership-contracts.md
git commit -m "feat: zero-allocation jwt verify via caller scratch buffer"
```

---

## Definition of done for this plan

- [ ] `mise exec zig@0.16.0 -- zig build test --summary all` reports 0 failures and 0 leaks.
- [ ] `mise exec zig@0.16.0 -- zig build test -Dpostgres=true --summary all` reports 0 failures (opt-in targets hide breakage — a Postgres-only compile error shipped undetected during PR #295 for exactly this reason).
- [ ] `mise exec zig@0.16.0 -- zig build bench` runs and prints `jwt/sign`, `jwt/verify`, `smoke/alloc-16`.
- [ ] `jwt/verify` reports `allocs = 0` against a non-zero recorded baseline.
- [ ] `./scripts/check-allocator-contracts.sh` prints `allocator contracts: OK`, and adding a masked test makes it fail.
- [ ] `src/jwt.zig` no longer appears in `scripts/allocator-allowlist.txt`.
- [ ] `NO_SLOP.md` contains §2.2a between §2.2 and §2.3.

## Follow-on plan (not this one)

Once this lands, write `docs/superpowers/plans/<date>-allocator-ownership-migration.md`
covering both remaining pieces of the spec's migration:

1. **The remaining leaf libraries** the spec names in step 3 — `url`, `crypto`,
   `values`, `captcha`, `sql/*`, `codegen/*`. Each is a mechanical repeat of
   Task 8's shape (convert to contract 1/2/3, flip its tests to raw
   `std.testing.allocator`, drop its allowlist entry, check the bench delta), so
   they are batched there rather than duplicated here. They are deliberately NOT
   left implicit: the migration plan must enumerate one task per file, with the
   real code, exactly as Task 8 does.
2. **The field flip and its worklist** — change `ctx.arena` (`src/ctx.zig:50`),
   `ev.arena` (`src/events.zig:118`), and `ctx.allocator` (`src/http.zig:13`) to
   `RequestArena`, then triage each resulting compile error against the
   three-part bar, converting to contracts 1/2/3 where justified and removing
   each converted file from the allowlist.

Piece 2's tasks are enumerable only after the flip produces the error list —
which is why this plan stops here rather than guessing at them.
