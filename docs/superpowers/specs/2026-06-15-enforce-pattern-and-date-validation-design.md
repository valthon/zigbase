# Enforce `text.pattern` and `date` `min`/`max` — Design

**Date:** 2026-06-15
**Status:** Approved (design); pending spec review → implementation plan

## Problem

Two field options are accepted by the schema API but **silently not enforced** — a footgun
where an author sets a constraint and records violating it are stored anyway:

- **`text.pattern`** (regex) — stored and round-tripped, but record validation never applies
  it. Blocked historically on Zig's std having no regex engine ("we won't hand-roll one").
- **`date.min` / `date.max`** — stored and round-tripped, but never enforced. Blocked on the
  lack of date normalization: a raw lexical compare false-rejects mixed formats
  (`2026-06-10 08:00:00` vs `2026-06-10T08:00:00Z`) and false-accepts garbage like
  `25:99:99`.

Both are documented in `KNOWN_LIMITATIONS.md:13-14` and referenced in `docs/security-audit.md`.
This design enforces both, with first-class compile-time validation where the values are
comptime-known (the project's stated "`@compileError`, never a runtime failure" doctrine).

## Decisions (locked during brainstorming)

1. **Enforce both** (not remove / not reject-loudly).
2. **Regex engine: a custom pure-Zig Thompson NFA**, written in-repo — chosen over vendoring
   SQLite's `regexp.c` (C can't run at Zig `comptime`) and over the Zig libraries surveyed:
   - `ctregex.zig` — disqualified: no license + comptime-**only** (can't compile runtime
     patterns) + abandoned (pre-0.16).
   - `mvzr` — mature/MIT/both phases, but **backtracks** (author warns against semi-trusted
     patterns) → not DoS-safe.
   - `pzre` — MIT/NFA/DoS-safe/both phases, but **no UTF-8 yet**, young (~10★, single
     maintainer), transitive `lens` dep.
   A custom Thompson NFA is the only option satisfying **all** hard constraints at once:
   one engine for comptime **and** runtime, linear-time/DoS-safe by construction, owned +
   MIT, exact Zig 0.16, full control of UTF-8 and the syntax subset.
3. **Date normalizer: pure Zig**, `comptime`-callable, single implementation used at both
   comptime (bound validation) and runtime (record-value validation).

## Why DoS-safety matters even for superuser-set patterns

Field patterns are set by superusers (admin schema editor) or app authors (comptime schema),
not arbitrary end users. But a *careless* admin writing a legitimate-looking pathological
regex (`(a+)+$`) would hang **every record write** touching that field — accidental
production DoS, not just a malicious-admin threat. A linear-time NFA removes the failure mode
entirely. Catastrophic backtracking is impossible by construction.

---

## Component 1 — Regex engine (`src/regex.zig`, new)

A small Thompson-NFA matcher. Parse → compile to an instruction program (Thompson
construction with ε-transitions) → simulate with the Pike/Thompson multi-state simulation
(advance a *set* of active states per input codepoint). Runtime is O(haystack × program),
no backtracking, ever.

### Public API

```zig
pub const Program = struct { /* compiled instructions + metadata */ };
pub const CompileError = error{ InvalidPattern, PatternTooComplex, OutOfMemory };

/// Runtime compile (admin-UI / DB patterns). Allocates the program into `alloc`.
pub fn compile(alloc: std.mem.Allocator, pattern: []const u8) CompileError!Program;

/// Comptime compile (schema literals). Triggers @compileError on a bad pattern.
pub fn compileComptime(comptime pattern: []const u8) Program;

/// Boolean match. Unanchored (substring) semantics. Allocation-free.
pub fn matches(program: Program, haystack: []const u8) bool;
```

`matches` is boolean only (validation needs match / no-match, never captures). The match is
allocation-free: the simulation uses two state-set bitsets sized to the program length
(stack buffer for small programs; bounded by the `PatternTooComplex` cap below).

### Supported syntax (RE2 / PocketBase-flavored subset)

- Literals — UTF-8 codepoints.
- `.` — any codepoint **except** `\n` (RE2 default).
- Anchors — `^` (string start), `$` (string end). Single-line only (no multiline mode).
- Character classes — `[...]`, negated `[^...]`, ranges `[a-z]`, escapes inside.
- Predefined classes — `\d \D \w \W \s \S` (**ASCII** semantics — documented).
- Escapes — `\t \n \r \f \v`, escaped metacharacters `\. \* \+ \? \( \) \[ \] \{ \} \| \^ \$ \\`.
- Alternation — `X|Y`.
- Grouping — `(...)` non-capturing (`(?:...)` accepted as an explicit alias).
- Quantifiers — `* + ?` and bounded `{m}` `{m,}` `{m,n}` (greedy; greediness is irrelevant
  to a boolean match).

### Semantics & safety

- **Unanchored substring match** by default (matches anywhere unless `^…$`-anchored) —
  consistent with both SQLite's `regexp()` and PocketBase's Go `MatchString`. Authors anchor
  with `^…$` for a full-string match. Documented.
- **`{m,n}` expansion cap.** Bounded quantifiers expand the program; a `PatternTooComplex`
  error is returned (runtime) / `@compileError` raised (comptime) when the compiled program
  exceeds a fixed instruction ceiling. Prevents memory blowup from `a{0,1000000}`.
- **UTF-8.** Pattern and haystack are treated as UTF-8; `.`, literals, and ranges operate on
  codepoints. Predefined classes (`\d\w\s`) are ASCII — documented limitation.

### Out of scope (deferred, documented)

Capture extraction, backreferences, lazy/possessive quantifiers, `\b` word boundaries,
`\p{}` Unicode classes, case-insensitive flag. None are needed for boolean field validation;
add later if a real need appears.

---

## Component 2 — Date normalizer (`src/datetime.zig`, new)

```zig
pub const ParseError = error{ InvalidFormat, OutOfRange };

/// Parse an accepted date/datetime string to UTC seconds since the Unix epoch.
/// Pure Zig — callable at comptime and runtime. Strict component validation.
pub fn parse(s: []const u8) ParseError!i64;
```

### Accepted grammar

- `YYYY-MM-DD` (date part required).
- Optional time part, separated by `T` or a space: `HH:MM`, `HH:MM:SS`, optional fractional
  `.fff…` (parsed, truncated to whole seconds for comparison).
- Optional zone: trailing `Z` (UTC) or `±HH:MM` offset (folded to UTC). A missing zone is
  treated as UTC (naive).
- Trailing garbage is rejected.

### Validation

- Strict component ranges: month 1–12, day valid for the month **with leap-year rule**,
  hour 0–23, minute 0–59, second 0–59. `25:99:99`, month 13, day 32, Feb 29 in a non-leap
  year all → `OutOfRange`. Malformed shapes → `InvalidFormat`.
- Civil-date → epoch via `days_from_civil` (Howard Hinnant algorithm), pure Zig, no libc.

The canonical stored form `YYYY-MM-DDTHH:MM:SSZ` (produced by `strftime` for
autodate/created/updated) parses cleanly.

---

## Component 3 — Integration

### Record validation (`src/records.zig`, `validateFieldValue`)

- **`.text` arm:** when `o.pattern != null` and the value is a non-empty string,
  `regex.compile(arena, pattern)` then `matches`; append `validation_pattern` on no-match.
  A pattern that fails to compile at this point **fails closed** (validation error + log) —
  though schema validation (below) should prevent bad patterns from ever being stored.
  Null / empty values skip the check (a field must stay clearable).
- **`.date` arm** (currently a silent no-op): a non-empty date value must `parse`
  (garbage → `validation_date`); when `min`/`max` are set, compare normalized seconds
  (`validation_min` / `validation_max`). Bounds parsed through the same `parse`; an
  unparseable bound fails closed. Null / empty skip.

Per-write compile of the pattern is acceptable (patterns are small). A compiled-program cache
is a deferred optimization (noted, not built).

### Schema validation (`src/schema.zig`, `validate`)

So a bad constraint is caught at definition time (admin-UI schema save → clear field error),
not as a 500 at the first record write:

- Text field with `pattern`: attempt `regex.compile`; on error append a `ValidationError`.
- Date field with `min`/`max`: attempt `datetime.parse` on each bound; on error append a
  `ValidationError`.

### Comptime validation (`src/framework.zig`, `App()` assembly)

During the existing comptime assembly of `cfg.collections`:

- For each text field with a comptime-known `pattern`: `regex.compileComptime(pattern)` →
  `@compileError` with a clear message on a bad pattern.
- For each date field with a comptime-known `min`/`max`: `comptime datetime.parse(bound)` →
  `@compileError` on a bad bound.

This is validation-only at comptime; the runtime path recompiles. (Embedding the
comptime-compiled `Program` to skip the runtime compile is a possible future optimization but
requires threading the comptime collection through to the validation site — deferred.)

### Test root (`src/root.zig`)

Add `_ = @import("regex.zig");` and `_ = @import("datetime.zig");` to the test block so their
`test {}` blocks are discovered. Re-export `regex` / `datetime` only if we want them in the
public framework surface (default: keep internal).

### Build

No `build.zig` change — pure Zig, no C, no vendored source, no `build.zig.zon` dependency.

---

## Testing

### Zig unit tests
- `src/regex.zig`: literals; `.`; anchors; classes incl. negation/ranges; `\d\w\s` (+ negated);
  escapes; alternation; groups; quantifiers incl. `{m}`/`{m,}`/`{m,n}`; UTF-8 literals/ranges;
  unanchored vs anchored; empty pattern; parse-error cases; `PatternTooComplex` cap; a
  `comptime`-evaluated match; and a **DoS regression**: `(a+)+$` against a long non-matching
  input completes in linear time.
- `src/datetime.zig`: every accepted format; leap-year boundaries; range rejections
  (`25:99:99`, month 13, day 32, Feb 29 non-leap); offset folding; comparison ordering across
  mixed formats; a `comptime`-evaluated parse.
- `src/records.zig`: **rewrite** the two existing "NOT enforced" tests (the `text.pattern`
  one and the date `min`/`max` no-op) into enforcement tests — pattern match passes /
  mismatch → `validation_pattern`; valid date passes / garbage → `validation_date` / out of
  `min`-`max` → `validation_min`/`validation_max`.
- `src/schema.zig`: a collection with a bad `pattern` and a bad date bound each produce a
  `ValidationError`.

### Browser suite (`tests/admin/`) — required per project convention
Extend the schema/validation coverage: create a text field with a `pattern` and confirm a
record create that violates it is rejected in the admin UI; create a date field with
`min`/`max` and confirm an out-of-range create is rejected. (Identify the closest existing
`tests/admin/` test to extend during planning.) Unit-green has repeatedly hidden end-to-end
regressions, so this runs locally before completion.

---

## Documentation sync (all required — the repo mirrors docs to `site/`)

- `KNOWN_LIMITATIONS.md` — remove the two bullets (lines 13-14).
- `site/src/content/docs/known-limitations.md` — same removal.
- `docs/fields.md` (+ its `site/src/content/docs/` mirror) — document enforced `pattern`
  (syntax subset, unanchored substring semantics, ASCII `\d\w\s`, `.` excludes `\n`, `{m,n}`
  cap, anchor for full-match) and enforced date `min`/`max` (accepted formats, comptime
  validation).
- `docs/security-audit.md` (lines ~106, ~424) — update: `pattern` is now enforced via a
  linear-time NFA (note DoS-safety); date bounds enforced with normalization.
- `docs/framework.md` — note comptime validation of patterns + date bounds (the
  `@compileError` surface).
- `CHANGELOG.md` + `site/src/content/docs/changelog.md` — add entries under `[Unreleased]`.
- `src/records.zig:161-163` — update/remove the "deliberately NOT enforced" comment.
- `examples/` — audit `golfsim` / `plugins` for date or pattern field usage; ensure none
  rely on the old non-enforcement (fix if so, keeping the complexity ladder intact).

## Out of scope

Compiled-pattern caching; embedding comptime-compiled programs to skip runtime compile;
captures/backreferences/lazy quantifiers/`\b`/`\p{}`/case-insensitive flag; multiline mode;
timezone-name parsing (only `Z` / numeric offset).
