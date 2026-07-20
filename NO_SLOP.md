# NO_SLOP.md — Zig code-review standard for AI reviewers

> **What this is:** the quality bar every change to this Zig codebase is reviewed against, distilled from Andrew Kelley's own writing, the official Zig docs and `zig zen`, and the Zig project's stated positions. When an AI agent reviews or writes Zig here, *this* is the rubric.
>
> Every claim below traces to a cited primary or corroborated source (see "Sources"). Findings were adversarially verified; two tempting-but-unsupported claims were dropped and are flagged in "What the evidence does NOT support."

---

## 0. How to read this guide (scope & honesty first)

There are **two very different things** people mean by "Kelley's view on AI code," and a reviewer that conflates them will be wrong:

1. **The idiomatic-Zig bar** (§2–§5) — a *stable, long-standing* set of design tenets from Kelley's own writing and the official docs. This is what "good Zig" means. It is what you actually enforce when reviewing Zig code, *regardless of who or what wrote it*.

2. **The "AI slop" stance** (§6) — Kelley's *policy and rhetoric* about AI-generated **contributions to the Zig project**. This is motivated by **reviewer-time economics and mentorship**, and by a **process** claim ("unreviewed code shipped on the strength of a test suite is not good enough"). It is **not** a universal law that "AI cannot produce correct code," and you should not use it as one.

> **Load-bearing nuance:** Kelley's "invariably garbage / negative value" remarks are about *submissions to Zig's PR queue* competing for a tiny core team's attention — not a claim that any AI-touched line is defective. When you act as an *AI reviewer enforcing his idiomatic bar*, you are doing exactly the human-grade review he says the process needs. Frame findings around **code properties**, not authorship.

**The one-sentence bar** (his own words): *"The bar that I want to hold software to is uncompromising perfection"* — explicitly rejecting *"works surprisingly well"* and *"the test suite catches everything"* as sufficient. Review to that standard.

---

## 1. The Zen of Zig — the values every rule descends from

The official `zig zen` (authored under Kelley) is the root of the rubric. The lines that most directly drive code review:

- **Communicate intent precisely.**
- **Favor reading code over writing code.**
- **Only one obvious way to do things.**
- **Runtime crashes are better than bugs.** / **Compile errors are better than runtime crashes.**
- **Edge cases matter.**
- **Reduce the amount one must remember.**
- **Resource allocation may fail; resource deallocation must succeed.**
- **Memory is a resource.**

And Kelley's four ranked language priorities (from *Introduction to the Zig Programming Language*): **Pragmatism → Optimal (perf ≥ C) → Safety → Readability** — with the crucial framing that *"the most natural way to write a program should result in top-of-the-line runtime performance."* **Idiomatic and fast should coincide.** If code is fast but ugly, or clean but needlessly slow, that tension is itself a review signal.

---

## 2. Reviewer rubric — the hard rules (flag every violation)

These are the checks that reflect Zig's actual design guarantees. A violation is almost always a real defect, not a style nit.

### 2.1 Explicit allocators — no hidden allocation
- **Rule:** *Any function that allocates memory takes an `Allocator` parameter.* There are **no hidden allocations** in idiomatic Zig.
- **Flag:** a function that allocates internally by reaching for a global allocator (`std.heap.page_allocator`, a file-scope `GeneralPurposeAllocator`, a hidden singleton) instead of accepting `allocator: std.mem.Allocator`.
- **Flag:** library/API code that hard-codes an allocator, denying the caller control over allocation strategy (arena vs. GPA vs. fixed-buffer).
- **Why:** allocation policy belongs to the caller; hiding it breaks composability, testability (`std.testing.allocator` leak detection), and arena-based lifetime management.

### 2.2 Every allocation has a matching, guaranteed deallocation
- **Rule:** *Resource allocation may fail; resource deallocation must succeed.* Pair every `alloc`/`create`/acquire with `defer`/`errdefer` **immediately after** the acquisition.
- **Flag:** an `alloc` with no `defer free` / `errdefer free` on the paths that can leak; a `defer` placed far from its acquisition; deallocation guarded by a condition that can be skipped.
- **Flag:** `errdefer` missing on the *error* path when an allocation must be rolled back but kept on success (a classic partial-construction leak).
- **Idiom:** deallocation code directly follows allocation code (`defer`), so both are visible together. Reviewers should be able to see the free next to the alloc.

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
| 4 | **Arena-scoped** | `fn f(arena: RequestArena, …) !T` | Interlinked graph reclaimed by arena drop. The signature can't accept a GPA by accident — `RequestArena` isn't `Allocator` — but a deliberate `.{ .a = gpa }` struct literal still compiles (Zig has no private fields); the guarantee is against accidental misuse, and any bypass is greppable. Needs a written justification, not just the type. |

- **Flag:** a function that allocates scratch and returns without freeing it, relying on the caller having passed an arena. That is contract 4 without the type — the defect this section exists to stop.
- **Contract 4 must be earned.** All three must hold: (1) the result is a graph of interlinked allocations, not a single buffer; (2) freeing them individually would be pointer-chasing for no benefit; (3) the lifetime is genuinely request-scoped. "It is currently written that way" and "adding `defer`s is tedious" are NOT justifications.
- **Reviewer check (mechanical):** *Which contract is this function? Does its test use raw `std.testing.allocator` (leak detection ON)? If it takes `RequestArena`, where is the written justification?*
- **Wrapping the testing allocator — under either the `std.testing.allocator` or aliased `testing.allocator` spelling — in an arena disables Zig's leak detector** for that test (`ArenaAllocator.init(std.testing.allocator)` and `ArenaAllocator.init(testing.allocator)` are both this). Legitimate only for contract 4, and every instance is listed in `scripts/allocator-allowlist.txt`; `scripts/check-allocator-contracts.sh` fails the build on a new one.

### 2.3 Errors are values — none may be silently ignored
- **Rule:** *Errors are values, and may not be ignored.* Every error union is handled with `try`, `catch`, an explicit switch on the error set, or a **deliberate** `unreachable`/`catch unreachable` that is genuinely provable.
- **Flag:** `catch unreachable` / `catch {}` used to *silence* an error that can actually occur (the #1 AI-code and beginner tell).
- **Flag:** `catch |err| {}` that swallows without logging, propagating, or handling.
- **Flag:** over-broad `anyerror` in signatures where an explicit, minimal error set is knowable — it erases intent and defeats exhaustive `switch`.
- **Flag:** discarding a returned error union with `_ =` where the error is meaningful.

### 2.4 No hidden control flow
- **Rule:** *"If Zig code doesn't look like it's jumping away to call a function, then it isn't."* No operator overloading, no exceptions, no hidden destructors, no property getters/setters, no macros/preprocessor.
- **Flag:** attempts to simulate hidden control flow (e.g. smuggling side effects into places a reader wouldn't expect a call), or fighting the language to recreate exceptions/RAII.
- **Caveat (be fair):** `defer`/`errdefer` are a *deliberate, visible* exception — the statement is always written at the site, even though it runs later. Treat "no hidden control flow" as a principle to protect, not a stick to beat `defer` with.

### 2.5 Correctness > passing tests (the "uncompromising perfection" rule)
- **Rule:** A green test suite is **not** proof of correctness. Kelley explicitly rebuts *"the test suite is good enough to catch everything"* as a defense for shipping large unreviewed code.
- **Flag:** logic that "passes the tests" but is unsound on unexercised edge cases — *edge cases matter*.
- **Flag:** assertion abuse — `assert`/`unreachable` used to *paper over* unhandled states rather than to encode a genuinely-proven invariant. (Kelley has specifically criticized "abuse of assertions" and "hacks on top of hacks.")
- **Reviewer behavior:** reason about *what inputs/states break this*, don't stop at "tests are green." Produce concrete failure scenarios.

### 2.6 comptime is a scalpel, not a hammer
- **Rule:** `comptime`/generics are for genuine compile-time needs, not reflexive metaprogramming. Kelley has publicly warned about *"comptime abuse"* and its compile-time cost.
- **Flag:** heavy comptime/`anytype` machinery where a plain runtime function or a small explicit interface would be clearer and cheaper to compile.
- **Flag:** `anytype` parameters that erase intent and could be a concrete type or a small explicit vtable.
- **Trade-off to weigh:** comptime cleverness vs. readability and compile time — Zig prizes fast builds; gratuitous comptime taxes them.

---

## 3. Reviewer rubric — the readability & "one obvious way" rules

These flow from *Favor reading code over writing code*, *Only one obvious way*, and *Reduce the amount one must remember*. Weigh them as strong preferences; a violation is a smell, not always a bug.

- **Prefer the canonical construct.** If there's an obvious idiomatic way (a stdlib type, `std.ArrayList`, a labeled `switch`, `for`/`while` with captures) and the code hand-rolls a cleverer variant, flag the cleverer one. *Clever ≠ better.*
- **Avoid complicated syntax / write for the reader.** Deeply nested ternaries, dense one-liners, and gratuitous abstraction layers that obscure control flow are anti-idiomatic even when correct.
- **Communicate intent precisely.** Names, types, and structure should make intent obvious to a *new* reader. Prefer explicit, narrow types over `anytype`/`anyerror`/`usize`-for-everything when a precise type exists.
- **Reduce what one must remember.** Flag "spooky action" — invariants that must be maintained across distant code with nothing local to signal them.
- **No dead/speculative generality.** Unused parameters, unused variables (a *compile error* in Zig — see §5), premature "flexible" abstractions with one caller.

---

## 4. Performance idioms (data-oriented design)

From Kelley's *Practical Data-Oriented Design* talk. These matter because Zig's promise is *"most natural way = fastest."* Apply them to hot, high-cardinality data — not everywhere.

- **The whole trick:** find the struct you have *the most of in memory* and make it smaller. *Avoid cache misses.*
- **Index instead of pointer.** For big arrays of the same struct, store `u32` indexes rather than 8-byte pointers — halves size and reduces alignment (watch the loss of pointer type-safety).
- **Eliminate padding via Struct-of-Arrays.** Prefer `std.MultiArrayList` over `ArrayList(struct{...})` for large collections — it removes inter-field padding. (In Zig this is roughly a "5-character change," so the bar for doing it on hot data is low.)
- **Store booleans / rare flags out of band.** Don't bloat a hot struct with a `bool` that forces padding; segregate or bit-pack.
- **Store sparse/optional data in a hash map**, not an always-present field most instances don't use.
- **Encodings instead of polymorphism.** Prefer compact, purpose-fit encodings over one-size-fits-all tagged unions when the struct is high-cardinality (Kelley shrank compiler tokens 64B→5B, AST nodes 120B→~15B this way, for double-digit % speedups).
- **Math can beat memory.** Recomputing can be faster than memoizing when the memo costs a cache miss — don't reflexively cache.

**Reviewer stance:** don't demand DoD everywhere (it's a readability trade-off). *Do* flag a struct that (a) is instantiated in large quantities on a hot path and (b) is obviously bloated by padding, embedded rare fields, or pointers where indexes would do. Justify with the size/cache argument, and prefer measurement over assertion (Kelley empirically validated every DoD change).

> **This repo:** `db.zig`'s pool, `query/` compiler nodes, `schema.zig` field descriptors, and realtime subscriber records are the high-cardinality structures where §4 actually bites — apply it there, not to one-shot config structs.

---

## 5. What NOT to flag — style is deliberately un-enforced

This is where over-eager reviewers lose credibility with the Zig community. Kelley (as `andrewrk`) has stated **officially**:

> *"Zig will not enforce identifier naming conventions according to any style. The 'style guide' will always be merely offered as a point of commonality... not any kind of rules or enforcement from the language or tooling."*

And he draws a bright line:

> *"Errors such as unused variables or misleading indentation are about **catching bugs**, not enforcing any particular style."*

Reviewer consequences:

- **Do NOT report naming-convention deviations as errors or must-fix.** The Zig Style Guide (`TitleCase` types, `camelCase` functions, `snake_case` variables/fields, `snake_case.zig` files) is a **convention worth noting for consistency**, phrased as an *optional* suggestion — never as a language rule or a blocking finding.
- **DO treat as real:** unused variables/imports, misleading indentation, shadowing, ignored errors, leaks, unreachable-that-is-reachable — these are the "catching bugs" category and are legitimately enforced (several are hard compile errors in Zig).
- **Formatting:** `zig fmt` is the canonical formatter. Don't hand-litigate whitespace; assume `zig fmt`. Flag only *semantic* formatting issues (e.g. misleading indentation) — those are bug-class, not style.
- **Naming redundancy** *is* worth a gentle note (from the Style Guide): avoid names that repeat their namespace (`std.math.math_sqrt`) or restate what context already makes obvious. This is about **communicating intent**, so it's a legitimate readability comment — phrased as a suggestion.

**Calibration rule:** classify every finding as **bug-class** (enforce) or **style/convention-class** (suggest, never block). Misfiling a style nit as a bug is itself a review defect by Kelley's standard.

---

## 6. The "AI slop" doctrine — what it actually says, and how to apply it as a reviewer

Kelley's most-quoted positions (all traced to a ~May 2026 JetBrains podcast, his July 2026 Bun blog post, and Zig's Code of Conduct):

- **On value:** *"People are sending us contributions that have no value whatsoever. They have negative value, because they take review time away from the team."* Widely reported as *"invariably garbage."*
- **On the test-suite defense:** *"The argument for shipping all the million lines of unreviewed slop is that the test suite is good enough to catch everything. It's not sufficient to catch bugs in Zig code but it is sufficient to catch bugs in a million lines of unreviewed slop?"* (re: Bun's ~1M-line Claude-driven Rust rewrite.)
- **On the bar:** *"I'm always hearing people say that AI code works surprisingly well. But to me, that is not the bar... The bar that I want to hold software to is uncompromising perfection."*
- **The Zig project's ban** (Code of Conduct, "Strict No LLM / No AI Policy"): *"No LLM-generated content, whether it be code or prose. No paraphrasing LLM-generated content. No LLMs for editing... No LLMs for translation... No LLMs for brainstorming... No LLMs for finding bugs."*
- **Stated motives:** (1) **reviewer-time economics** — a tiny core team, ~200 open PRs; (2) **mentorship** — AI is *"unteachable,"* whereas reviewing a human's PR is an investment in a future contributor ("you bet on the contributor, not the contents of their first PR"); (3) **trust/determinism** — he prefers *deterministic tools he can fully trust*; AI output *"always needs review, even for... refactoring the name of a function."*

### How an AI reviewer should operationalize this (without hypocrisy)

You are an AI, and the point of your review is to *supply* the human-grade scrutiny Kelley says AI submissions lack. So:

1. **Review to "uncompromising perfection," not "tests pass."** Never conclude "looks good, CI is green." Actively hunt edge cases, allocator/lifetime bugs, and swallowed errors. Provide concrete failure scenarios, not vibes.
2. **Detect the "slop" fingerprints** — the concrete defects that unreviewed AI-generated Zig characteristically ships:
   - `catch unreachable` / `catch {}` over fallible calls (§2.3)
   - allocations without matching `defer`/`errdefer`; missing `errdefer` on partial construction (§2.2)
   - functions that allocate via a global allocator instead of a passed one (§2.1)
   - over-broad `anyerror`, gratuitous `anytype`/comptime (§2.3, §2.6)
   - plausible-looking code that passes happy-path tests but breaks on empty/overflow/boundary inputs (§2.5)
   - hand-rolled reimplementations of stdlib functionality (violates "one obvious way")
   - stale/incorrect doc comments that describe intent the code doesn't fulfill
3. **Flag "large unreviewed volume" as its own risk.** A huge diff justified only by "the tests pass" is exactly the pattern Kelley rejects. Recommend decomposition and line-by-line human review; do not bless bulk on test-suite strength alone.
4. **Judge the code, not the author.** Report **properties** ("this leaks on the error path," "this ignores a fallible result"), never "this looks AI-generated." Authorship is the *project's* policy lever; your job is correctness and idiom.
5. **Respect determinism/precision in your own output.** Cite the exact `file:line`, give the minimal correct fix, and don't hedge — imprecise review is the very thing he distrusts.

---

## 7. What the evidence does NOT support (don't overreach)

Adversarial verification **rejected** these framings — do not present them as Kelley's position:

- ✗ *"Non-determinism is Kelley's single core objection to AI."* It's **one of several** (economics, mentorship, trust), not THE core one.
- ✗ *"His core objection is that AI submissions show no understanding of the codebase."* Reported, but not established as his central argument.
- ✗ *"AI can never write correct code" as a universal law.* His remarks target **contributions to the Zig project** and **unreviewed bulk shipping**, not a metaphysical claim about all AI code.
- ✗ Treating naming/formatting conventions as **enforceable rules** — he explicitly disowns that (§5).

Also note the honest source-strength split: §2–§5 rest on **primary** sources (Kelley's blog, ziglang.org, the Zig issue tracker, the Zen) and are stable. §6's punchy quotes lean on **tech-press reporting** of two primary events; the load-bearing quotes ("negative value / takes review time," "uncompromising perfection," "unreviewed slop") are directly attributed and consistent across outlets, while "invariably garbage" is in places a journalistic gloss. The AI material is recent (Apr–Jul 2026) and may evolve.

---

## 8. One-screen reviewer checklist

**Bug-class — enforce (block):**
- [ ] Every allocating fn takes an `Allocator` param; no hidden/global allocation
- [ ] Every `alloc`/resource has a local `defer`/`errdefer`; `errdefer` present on partial-construction paths
- [ ] No ignored/swallowed errors; no `catch unreachable`/`catch {}` over genuinely-fallible calls
- [ ] Error sets are precise (not gratuitous `anyerror`); exhaustive handling where switched
- [ ] No unused variables/imports, no shadowing, no misleading indentation, no reachable `unreachable`
- [ ] Assertions encode proven invariants, not swept-under states
- [ ] Correctness reasoned to edge cases — not "tests pass"; concrete failure scenario for each finding
- [ ] Hot, high-cardinality structs aren't obviously cache-hostile (padding/pointers/rare fields inline)

**Readability/idiom — suggest (don't block):**
- [ ] Canonical construct over clever bespoke one ("one obvious way")
- [ ] Precise names/types; no namespace-redundant names; intent obvious to a new reader
- [ ] comptime/`anytype` justified vs. a simpler runtime/explicit form; build-time cost respected
- [ ] Doc comments accurate and focused on the declared interface

**Do NOT flag:**
- [ ] Naming-convention style as a rule (it's optional commonality)
- [ ] Whitespace/formatting `zig fmt` owns (except *misleading* indentation)
- [ ] "This looks AI-written" — review properties, not authorship

---

## Sources

**Primary (Kelley / official):**
- Andrew Kelley, *Introduction to the Zig Programming Language* — https://andrewkelley.me/post/intro-to-zig.html
- Andrew Kelley, *My Thoughts on the Bun Rust Rewrite* ("unreviewed slop") — https://andrewkelley.me/post/my-thoughts-bun-rust-rewrite.html
- Andrew Kelley, *A Practical Guide to Applying Data-Oriented Design* (talk) — https://www.youtube.com/watch?v=IroPQ150F6c
- Zig — *Overview / Why Zig* (no hidden control flow, allocator param, errors are values) — https://ziglang.org/learn/overview/
- Zig — *Documentation: Style Guide* (naming, redundancy, doc comments) — https://ziglang.org/documentation/master/#Style-Guide
- Zig — *Code of Conduct: Strict No LLM / No AI Policy* — https://ziglang.org/code-of-conduct/
- Kelley (`andrewrk`), *Zig will not enforce naming conventions; errors are about catching bugs* — https://github.com/ziglang/zig/issues/14228
- *The Zen of Zig* (`zig zen`) — published in the Zig compiler/docs

**Corroborating secondary (AI-stance quotes):**
- The Register, *Zig creator seeks 'uncompromising perfection' before blessing 1.0* — https://www.theregister.com/software/2026/05/28/zig-creator-seeks-uncompromising-perfection-before-blessing-10/
- The Register, *Zig creator calls Bun's Claude Rust rewrite 'unreviewed slop'* — https://www.theregister.com/devops/2026/07/14/zig-creator-calls-buns-claude-rust-rewrite-unreviewed_slop/
- TechSpot, *Zig maintainer: AI-generated code 'invariably garbage'* — https://www.techspot.com/news/112596-zig-maintainer-worthless-ai-generated-code-rejected.html
- Simon Willison, *The Zig project's rationale for their anti-AI contribution policy* — https://simonwillison.net/2026/Apr/30/zig-anti-ai/
- JetBrains Blog, *Why Zig Isn't 1.0 (Yet)* — https://blog.jetbrains.com/blog/2026/06/05/why-zig-isn-t-1-0-yet/
- Sourcegraph, *Revisiting the design approach to Zig* — https://sourcegraph.com/blog/zig-programming-language-revisiting-design-approach

*Methodology: 6 search angles → 21 sources → 72 extracted claims → 25 verified by 3-vote adversarial verification (23 confirmed, 2 refuted). Refuted claims are recorded in §7.*
