# Allocator ownership contracts

**Status:** design approved, implementation not started
**Date:** 2026-07-19

## Problem

Two independent code reviews (Gemini, Copilot) on PR #295 each caught the *same*
class of defect: a function that allocates scratch with a caller-supplied
allocator and never frees it. Correct under a request arena, a leak under any
other allocator. Finding these one at a time, by reading code, does not scale
and will not stop.

The root cause is not carelessness. Zig ships a leak detector —
`std.testing.allocator` fails any test that leaks — and the codebase disables it
in most tests by wrapping it in an arena:

| Measure | Count |
| --- | --- |
| Tests wrapping `testing.allocator` in an arena (**detection off**) | 887 |
| Tests using raw `testing.allocator` (**detection on**) | 656 |
| Functions taking a caller allocator | 578 |
| Files containing masked tests | 121 |

`ArenaAllocator.init(std.testing.allocator)` frees everything at `deinit`, so the
detector never fires. About 57% of test allocator usage neutralises the exact
mechanism that would have caught both reviewers' findings automatically. (An
earlier pass of this count, 783 across 101 files, undercounted: it grepped only
the `ArenaAllocator.init(std.testing.allocator)` spelling and missed the
equally common aliased form — `const testing = std.testing;` ... `ArenaAllocator.init(testing.allocator)`.
Broadening the pattern to match both found the true population above.)

Evidence this is real, not theoretical: converting a single `jwt` test off the
arena immediately reported **8 leaked allocations with exact stacks**, in
`sign`/`verify` — a path that runs on every login and token refresh. Fixing
`sign` dropped it to 4.

### The gap in the standard

`NO_SLOP.md` §2.1 governs *taking* an allocator; §2.2 governs pairing
`alloc`/`free`. Neither says anything about **what a function returns and who
owns it**. That unstated half is where every one of these bugs lives. The
codebase has organically grown four different ownership patterns
(`regex.Program.deinit`, `values.zig`'s prose "requires an arena",
`log.formatLine`'s caller buffer, ordinary self-freeing helpers) chosen ad hoc,
undocumented in the standard, and unenforced.

This design codifies and enforces the taxonomy the codebase already gropes
toward.

## Contract taxonomy

Every function taking an allocator must be exactly one of these, and say which.

| # | Contract | Signature shape | Promise |
| --- | --- | --- | --- |
| 1 | **Self-freeing** (default) | `fn f(alloc: Allocator, …) ![]u8` | Frees all scratch. Exactly one allocation escapes — the return value. Caller frees it. Correct under any allocator. |
| 2 | **Owned-result** | `fn f(alloc: Allocator, …) !Result`, `Result.deinit(alloc)` | The result owns an internal graph; the caller calls `deinit`. Use when the return borrows internals. Precedent: `regex.Program`, `dumpload.Report`, `saslprep.Prepared`. |
| 3 | **Caller-buffer** (zero-alloc) | `fn f(buf: []u8, …) []const u8` | Allocates nothing. Preferred whenever the output is bounded. Precedent: `report/log.formatLine`, `sql/dialect.placeholder`. |
| 4 | **Arena-scoped** (exception) | `fn f(arena: RequestArena, …) !T` | Produces an interlinked graph reclaimed only by arena drop. Signature-enforced — a GPA cannot flow in accidentally; a deliberate struct literal still can, so it is greppable rather than impossible. Requires written justification. |

Contract 1 is the default. Anything that cannot justify contract 4 must become
1, 2, or 3.

### The bar for contract 4

An arena dependency must be *earned*. All three must hold:

1. The result is a **graph of interlinked allocations**, not a single buffer; and
2. freeing them individually would be pointer-chasing for no benefit; and
3. the lifetime is **genuinely request-scoped** — it dies at a known boundary.

Explicitly **not** justifications: "it is currently written that way", "adding
`defer`s is tedious", "the caller happens to pass an arena today".

Worked example: `jwt.verify` fails this bar. JWT claims are small and bounded, so
it becomes contract 3 (fixed-buffer decode, zero allocation) or contract 2 — not
contract 4.

## The `RequestArena` type

```zig
/// A request-scoped arena. Deliberately NOT `std.mem.Allocator`: an arena-scoped
/// API cannot be handed a GPA by accident, the dependency is visible in every
/// signature, and the compiler checks it.
pub const RequestArena = struct {
    a: std.mem.Allocator,

    /// Constructible ONLY from a real arena, at the boundary that owns and
    /// deinits it. Taking the concrete *ArenaAllocator (not an Allocator) means a
    /// GPA can't flow in ACCIDENTALLY through the signature. Zig has no private
    /// fields, so a deliberate `RequestArena{ .a = some_gpa }` struct literal still
    /// compiles — that bypass is not prevented, only made greppable and
    /// high-friction instead of the default path.
    pub fn from(arena: *std.heap.ArenaAllocator) RequestArena {
        return .{ .a = arena.allocator() };
    }
};
```

Three properties carry the design:

1. **No implicit conversion** in either direction. This *is* the enforcement.
2. **Construction takes `*std.heap.ArenaAllocator`**, not an `Allocator`, so a GPA
   cannot flow in *accidentally* through a signature. Zig has no private fields, so
   a deliberate `RequestArena{ .a = some_gpa }` literal still compiles — the bypass
   is made greppable and high-friction, not prevented. The accidental path is what
   this closes, and that is the path the defect class actually travels.
3. **`.a` is the deliberate escape.** An arena-scoped function calls a
   self-freeing function via `arena.a`. That is correct by construction —
   contract 1 functions work under any allocator, including an arena — and it is
   greppable, so stashing `.a` beyond the request is reviewable.

## Compiler-driven migration

The arena boundary already exists as named fields, so the compiler can perform
the audit:

| Field | Location | Change |
| --- | --- | --- |
| `ctx.arena` | `src/ctx.zig:50` | `std.mem.Allocator` → `RequestArena` |
| `ev.arena` | `src/events.zig:118` | `std.mem.Allocator` → `RequestArena` |
| `ctx.allocator` | `src/http.zig:13` | `std.mem.Allocator` → `RequestArena` |

These are fed by the per-request arena created at `src/server.zig:284`.

Changing the field types makes **every error an arena-dependent call path** — an
exact, exhaustive, machine-generated worklist. No manual survey, no missed cases.
For each error there is one decision: convert to contract 1/2/3 (preferred), or
accept a `RequestArena` parameter with a justification meeting the three-part
bar.

The process is **monotonic**: every conversion to contract 1 deletes errors and
shrinks the arena region toward its justified core. The compiler maintains the
worklist and reports when the migration is complete. This is what makes a
single-PR migration tractable.

### Where the boundary lands

The arena region becomes the *request/response construction layer* — an HTTP
handler building a response graph reclaimed when the request completes is a
legitimate contract 4, justified once at the boundary. The payoff is that
everything handlers call into (jwt, url, query, records helpers, codegen) must be
contract 1/2/3, and every one of those tests gets the leak detector switched on.

## Enforcement

Three layers, so the contract cannot decay back into convention.

### Runtime: the leak detector is the default

> A test may wrap `testing.allocator` in an arena **only if** the code under test
> takes `RequestArena`. Everything else uses raw `std.testing.allocator`.

This is mechanically decidable from the signature — not a judgment call. After
migration, arena-wrapped tests are a small known set mirroring the contract-4
surface exactly.

### CI: an allowlist ratchet

Add `scripts/check-allocator-contracts.sh` (precedent: `scripts/check-gating.sh`)
which greps for both the `ArenaAllocator.init(std.testing.allocator)` spelling and
the aliased `ArenaAllocator.init(testing.allocator)` form (regex
`ArenaAllocator\.init\((std\.)?testing\.allocator\)`), compares against a
checked-in allowlist carrying each entry's justification, and **fails on any new
entry**. A precise static "is this function arena-dependent" analysis is
unreliable; an allowlist is blunt but robust, and makes a new masked test a
deliberate, argued act in a diff rather than a silent default.

The allowlist is keyed by **file path plus an occurrence count**, since one file
may hold both contract-4 tests and ordinary ones. Raising a file's count requires
editing the allowlist — so adding a masked test to an already-listed file is
still a visible, reviewable change rather than something that slips in under an
existing entry.

### NO_SLOP: the rule reviewers apply

Extend §2.1/§2.2 with the four contracts, the three-part arena bar, and the
mechanical reviewer check:

> Which contract is this function? Does its test use the leak detector? If it
> takes `RequestArena`, where is the justification?

## Performance: remove allocation, do not relocate it

Converting contract 4 → 1/2 can *add* copies. `jwt.verify` is the case in point:
an owned-result version would dupe claim strings that today borrow the parse
tree — extra allocation on every authenticated request. That trades a leak for a
regression and is not acceptable.

This is why contract 3 exists. JWT claims are small and bounded, so a
fixed-buffer decode allocates nothing — strictly better than both today's
borrow-from-arena and a duping owned-result.

**Requirement:** for every hot-path conversion, choose the contract that
*removes* allocation rather than relocating it, and verify it rather than
assuming.

**How it is verified.** Allocation *count* is not a sufficient proxy: cost is
nonlinear in both count and size. One 64 KB allocation and eight thousand 8-byte
allocations can carry identical byte totals at wildly different cost, and a
count-only check would rank the eight thousand as cheaper. Measuring the property
properly requires timing, so this design builds the benchmark harness the repo
currently lacks.

### Benchmark harness (`zig build bench`)

Timing is the metric; the allocation profile is the diagnosis that explains a
timing move.

| Reported per benchmark | Why |
| --- | --- |
| ns/op — median and p95 over N iterations after warmup | the real cost; p95 exposes variance |
| allocs/op, bytes/op | totals |
| **allocation size histogram** (≤64B, ≤512B, ≤4K, ≤64K, >64K) | distinguishes `1×64K` from `8000×8B`, which totals hide — the signal that catches replacing one arena bump with thousands of small GPA allocations |
| peak live bytes | arena high-water vs incremental churn |

Mechanics: `std.time.Timer` for monotonic nanoseconds; a wrapping allocator that
tallies count, bytes, and the size histogram; `--json` output; and
`scripts/bench-compare.sh <rev-a> <rev-b>` to build, run, and print deltas
between two revisions.

**Seed benchmarks** — micro plus one end-to-end, so a regression can be both
attributed and sanity-checked for real-world impact:

| Benchmark | Kind |
| --- | --- |
| `jwt.sign` | micro |
| `jwt.verify` / `peekClaims` | micro |
| records list + `?expand=` at several page sizes | micro |
| filter/sort compile | micro |
| full request round-trip through the router | end-to-end |

**CI role: report-only.** CI runs the harness and publishes the before/after
table on the PR, but never fails on it. Shared runners are noisy enough that a
threshold gate would produce false failures, and a performance gate people learn
to ignore is worse than no gate. Regressions are caught by a human reading the
delta. Revisit automated gating once the baseline gives us real variance data.

**Sequencing consequence:** the harness and a captured baseline must exist
*before* any conversion lands, or there is nothing to compare against. This makes
the harness step 1 of the migration, not a verification afterthought.

## Migration plan

Executed as one PR, built as ordered commits so each compiles and is green.

1. **Build the harness and capture the baseline.** `zig build bench` with the
   seed benchmarks, `scripts/bench-compare.sh`, and a recorded baseline run on
   `main`. This lands *first* — every later step is judged against these numbers,
   and a baseline captured after conversions have begun is worthless.
2. **Land the type and rule.** `RequestArena` in `src/request_arena.zig`, the
   NO_SLOP §2.1 extension, and `scripts/check-allocator-contracts.sh` with an
   initially permissive allowlist (every currently-masked file). Nothing breaks;
   the ratchet is installed.
3. **Convert leaf libraries.** `jwt`, `url`, `crypto`, `values`, `captcha`,
   `sql/*`, `codegen/*` — no arena justification, pure contract 1/2/3. Each
   conversion flips its tests to raw `testing.allocator` and removes its
   allowlist entry. Highest leak yield, zero ripple.
4. **Flip the field types** (`ctx.arena`, `ev.arena`, `ctx.allocator`). The
   compiler emits the exhaustive worklist; step 3 has already resolved much of
   it.
5. **Triage each error** against the three-part bar: convert (preferred), or
   accept `RequestArena` plus a written justification.
6. **Re-run the harness and diff against the baseline**, reading the size
   histogram alongside ns/op so any timing move is explained rather than merely
   observed.
7. **Close the ratchet.** The allowlist now contains only justified contract-4
   files; CI fails on additions.

Ordering within the PR matters: leaf libraries first means handler-level errors
dissolve as their callees become contract 1.

## Definition of done

All five, verified rather than asserted:

- `zig build test` green with leak detection active on every non-contract-4
  module, **and `zig build test -Dpostgres=true` green** — opt-in targets hide
  breakage (a compile error in the Postgres-only path shipped undetected during
  PR #295 for exactly this reason).
- Every remaining `ArenaAllocator.init(std.testing.allocator)` appears in the
  allowlist with a justification meeting the three-part bar.
- Every `RequestArena` parameter carries a written justification; none reads "it
  was written that way".
- Browser suite (`tests/admin`) and all three examples green — unit-green has
  hidden regressions in this repo before.
- `zig build bench` re-run and diffed against the recorded `main` baseline, with
  the delta table published on the PR. Every ns/op move is *explained* by its
  allocation histogram — not merely observed — and any regression is either
  designed away or accepted with a written rationale.

## Risks

- **Step 4 (flipping the field types) produces a large first-compile error
  count.** Inherent to the single-PR choice; step 3 exists to shrink it
  beforehand by converting leaf libraries first.
- **`.a` is greppable but not compile-proof** against stashing the allocator
  beyond the request lifetime. Mitigated by review and called out in NO_SLOP;
  accepted rather than solved.
- **A conversion may prove impossible without a measured regression.** In that
  case the API stays contract 4 with the measurement itself as its
  justification. That is a legitimate outcome, not a failure of the design.

## Expected findings

Recorded so the design can be checked against reality afterwards: leaf libraries
convert cleanly to contract 1 with real leaks fixed; a genuinely small contract-4
core survives at the request/response construction layer; and a handful of APIs
such as `jwt.verify` turn out to want contract 3, ending up *better* than they
are today rather than a compromise.
