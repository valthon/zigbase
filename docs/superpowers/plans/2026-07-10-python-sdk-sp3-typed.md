# Python Client SDK SP3 (Typed Tier) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the typed tier of the Python SDK: a pydantic-free `zigbase/typed.py` runtime plus a new `--lang python` emitter in the server's typegen pipeline generating Pydantic-v2 record models, fluent injection-safe filter builders, and typed sync/async collection services — golden-gated in CI and proven e2e against the dating fixture.

**Architecture:** Two halves. (1) A hand-written typed runtime in the base wheel (`zigbase/typed.py`) ported from Dart's `typed.dart`: meta types, wire coercers, an `Expr`/`FieldExpr` filter DSL that routes every operand through the existing `zigbase.query.filter_value`, `TypedList`/`TypedCursorPage`, a generic `TypedCollection` forked sync/async, and async-only `TypedRealtime`. (2) A Zig emitter trio (`python_type.zig`, `emit_python.zig`, `gen_python.zig`) mirroring the Dart emitters, wired into `--lang python`, producing a committed golden `clients/python/tests/codegen/dating/zbase_gen.py` whose formatting is delegated to `ruff format` (the `dart format` pattern).

**Tech Stack:** Python ≥3.10 (pydantic>=2 ONLY via the new `[typed]` extra, used by generated code alone); Zig 0.16 for the emitter; dating fixture (`fixtures/dating/schema.zig`) as generator input and e2e server.

**Normative references:** Dart is the template everywhere: `clients/dart/lib/typed.dart` (runtime), `clients/dart/test/codegen/dating/zbase.gen.dart` (generated shape), `src/codegen/{gen_dart,emit_dart,dart_type}.zig` (emitter), `clients/dart/test/typed_where_test.dart` + `test/integration/typed_dating_test.dart` (tests), `docs/dart-sdk.md` §typed-tier (docs). TS's `clients/typescript/src/typed/` is secondary (port `where/service/realtime` RUNTIME behavior only; `expand.ts`/`operators.ts` are type-level-only — do NOT port). The design spec is `docs/superpowers/specs/2026-07-09-python-sdk-design.md` (SP3 section).

## Global Constraints

- Paths: SDK work in `clients/python/`; emitter work in `src/codegen/` + `build.zig` + `src/root.zig`. Commands: `mise exec python@3.13 -- python -m <cmd>` from `clients/python/`; `mise exec zig@0.16.0 -- zig build <step>` from the worktree root.
- **`zigbase/typed.py` is pydantic-free and ships in the base wheel.** `pydantic>=2` is added ONLY as the optional extra **`zigbase[typed]`**; only generated `zbase_gen.py` imports it. Typed realtime consumers need `zigbase[typed,realtime]`.
- **Injection safety:** every operand interpolated by the filter DSL flows through `zigbase.query.filter_value` — the DSL never formats operands itself. The O'Brien test (`title = 'O\'Brien'`) is mandatory.
- Wire coercion parity with Dart: `coerce_int` RAISES (ValueError) on fractional input (schema drift must not truncate silently); int/fixed cross the wire as decimal strings (`encode_int` → `str(v)`, `encode_fixed(v, scale)` → `f"{v:.{scale}f}"`); float untouched.
- Sync/async fork: `TypedCollection` (over `CollectionService`) AND `AsyncTypedCollection` (over `AsyncCollectionService`); generated services come in both flavors; `TypedRealtime` is ASYNC-ONLY over `AsyncZigBase.realtime` with NO per-collection close (shared multiplexed service).
- Zig emitter: `gen_python.generate(...)` mirrors `gen_dart.generate`'s exact 11-arg signature (`gen_dart.zig:28`); routes/custom_auth/flags/experiments are accepted and discarded (`_ = routes;` …) — **RPC and typed custom-auth emission are OUT OF SCOPE** (Dart parity; TS-only features). New `src/codegen/*.zig` files MUST be referenced in `src/root.zig`'s test block or their tests never run.
- Golden: `clients/python/tests/codegen/dating/zbase_gen.py`, committed `ruff format`-clean (run ruff from `clients/python/` so its pyproject config applies); `build.zig` steps `gen-dating-python-client` + `gen-dating-python-client-check` mirroring `build.zig:279-286`; CI freshness gate in the `build` job = regenerate → `ruff format` → `git diff --exit-code` (the Dart pattern at ci.yml:79-83).
- Generated file header carries the `schema-hash` (reuse `schemaHash()`, `gen_client.zig:20`) and a `TYPED_CORE_VERSION` compat marker (constant defined in `zigbase/typed.py`, mirrored in the generated header comment).
- Python reserved-word sanitization in the emitter mirrors `emit_dart.zig`'s `isDartKeyword`/`memberIdent`: hardcode Python's keyword list (`False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case`) + collision-with-model-namespace check; sanitized member gets trailing `_`, wire key unchanged.
- Gates at every commit from `clients/python/`: `ruff format --check .`, `ruff check .`, `mypy src` (strict), `pytest -m "not integration" -q`. Zig-side commits additionally: `mise exec zig@0.16.0 -- zig build test --summary all` (authoritative signal is the Build Summary line) + the golden `-check` step once it exists. TDD (RED before GREEN) on every Python task; Zig emitter tasks verify via golden snapshots.
- Commits `feat(python-sdk)`/`feat(typegen)`/`test(python-sdk)`/`docs(python-sdk)` style, ending with the Claude co-author trailer. Module docstrings name the Dart/TS counterparts.
- Fixture coverage gap (multi-select/multi-file non-relation absent from dating): unit-test `coerce_str_list`/`coerce_int_list`/`coerce_float_list` directly; do NOT modify the shared fixture.

---

### Task 1: Typed runtime — meta types, coercers, encoders, expand helpers

**Files:**
- Create: `clients/python/src/zigbase/typed.py` (part 1), `clients/python/tests/test_typed_coerce.py`

**Interfaces (Produces):**
```python
# typed.py — port of clients/dart/lib/typed.dart (metadata + coercion sections)
TYPED_CORE_VERSION = "0.1.0"

class FieldType(str, Enum):  # text, editor, email, url, number, boolean, date, autodate, select, relation, file, json
class NumberMode(str, Enum):  # float, integer, fixed

@dataclass(frozen=True)
class FieldMeta:
    type: FieldType
    multi: bool = False
    mode: NumberMode = NumberMode.FLOAT
    scale: int | None = None

@dataclass(frozen=True)
class CollectionMeta:
    name: str                       # realtime topic + client.collection(name) key
    fields: Mapping[str, FieldMeta]
    file_fields: tuple[str, ...] = ()
    expandable: tuple[str, ...] = ()
    is_auth: bool = False
    searchable: tuple[str, ...] | None = None
    tenant: str | None = None
    def field(self, name: str) -> FieldMeta | None: ...

def coerce_int(v: object, fallback: int = 0) -> int: ...      # RAISES ValueError on fractional (9.99 / "9.99")
def coerce_float(v: object, fallback: float = 0.0) -> float: ...
def coerce_str(v: object, fallback: str = "") -> str: ...
def coerce_bool(v: object, fallback: bool = False) -> bool: ...
def coerce_str_list(v: object) -> list[str]: ...
def coerce_int_list(v: object) -> list[int]: ...
def coerce_float_list(v: object) -> list[float]: ...
def encode_int(v: int | None) -> str | None: ...              # decimal string for wire
def encode_fixed(v: float | None, scale: int) -> str | None:  # Decimal(v).quantize(ROUND_HALF_UP) — Dart toStringAsFixed parity (half-away-from-zero on the exact binary value; NOT f-string half-to-even)
def expand_one(record: Mapping[str, Any], key: str, from_record: Callable[[Mapping[str, Any]], T]) -> T | None: ...
def expand_many(record: Mapping[str, Any], key: str, from_record: Callable[[Mapping[str, Any]], T]) -> list[T]: ...
```
Behavior parity with typed.dart:103-164 exactly (empty→fallback; `"42.0"` accepted by coerce_int, `"42.5"` raises; expand helpers read `record["expand"][key]`, absent → None/[]).

- [ ] **Step 1: Write failing tests** — every coercer's accept/reject/fallback matrix (incl. fractional-int rejection both float and string forms, list coercers on scalars/None/mixed), encode_fixed scale rendering (9.99→"9.99", 5→"5.00"), expand_one/expand_many with a lambda converter (present single, present list, absent, empty expand block).
- [ ] **Step 2: Run `pytest tests/test_typed_coerce.py -q`, verify FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: All gates PASS.**
- [ ] **Step 5: Commit** (`feat(python-sdk): typed runtime metadata and wire coercion`)

---

### Task 2: Typed runtime — Expr / FieldExpr filter DSL

**Files:**
- Modify: `clients/python/src/zigbase/typed.py`, Create: `clients/python/tests/test_typed_where.py`

**Interfaces (Produces):**
```python
class Expr:
    def __init__(self, raw: str) -> None: ...
    def and_(self, other: "Expr") -> "Expr": ...   # -> Expr(f"({a} && {b})")
    def or_(self, other: "Expr") -> "Expr": ...    # -> Expr(f"({a} || {b})")
    __and__ = and_; __or__ = or_                   # (f.a.eq(1)) & (f.b.eq(2))
    def compile(self) -> str: ...

class FieldExpr(Generic[T]):
    def __init__(self, path: str) -> None: ...
    def eq(self, v: T) -> Expr: ...                # path = filter_value(v)
    def neq(self, v: T) -> Expr: ...
    def in_list(self, vs: Sequence[T]) -> Expr: ...  # path in (v1, v2); empty -> "path in ()"
    __eq__ = eq  # type: ignore[assignment]  — dunder sugar returns Expr, documented
    __ne__ = neq

class ComparableFieldExpr(FieldExpr[T]):  # adds gt/gte/lt/lte + __gt__/__ge__/__lt__/__le__
class StringFieldExpr(ComparableFieldExpr[str]):  # adds like/nlike (~ / !~)
class NumFieldExpr(ComparableFieldExpr[float]): ...
class DateFieldExpr(ComparableFieldExpr[object]): ...   # datetime or ISO str, via filter_value
class BoolFieldExpr(FieldExpr[bool]): ...
class EnumFieldExpr(FieldExpr[E]):
    def __init__(self, path: str, wire_of: Callable[[E], str]) -> None: ...  # serialize enum first
class RelFieldExpr(FieldExpr[str], Generic[F]):
    def __init__(self, path: str, make_fields: Callable[[str], F]) -> None: ...
    def rel(self, build: Callable[[F], Expr]) -> Expr: ...   # build(make_fields(f"{path}.")) — one nesting level
```
Every operand through `zigbase.query.filter_value` (import from `zigbase.query`; it is intentionally not re-exported at package root). Op map: eq `=`, neq `!=`, gt `>`, gte `>=`, lt `<`, lte `<=`, like `~`, nlike `!~` (typed.dart:202-305 parity). mypy-strict note: overriding `__eq__` with a non-bool return needs a scoped `# type: ignore[override]` with a comment — acceptable, mirror how it's done once and reuse.

- [ ] **Step 1: Write failing tests** (assert exact `.compile()` bytes, mirroring clients/dart/test/typed_where_test.dart): scalar ops all 8; injection `StringFieldExpr("title").eq("O'Brien").compile() == "title = 'O\\'Brien'"`; in_list values + empty → `"title in ()"`; and/or parenthesization incl. dunder forms; enum wire_of; relation id-eq; nested `RelFieldExpr("author", UserFields).rel(lambda u: u.name.like("Ann")).compile() == "author.name ~ 'Ann'"` (hand-written minimal UserFields in the test); datetime operand renders via format_date quoting; list/dict operand raises TypeError (from filter_value).
- [ ] **Step 2: RED.** — **Step 3: Implement.** — **Step 4: Gates PASS.** — **Step 5: Commit** (`feat(python-sdk): typed filter DSL over filter_value`)

---

### Task 3: Typed runtime — result envelopes + TypedCollection (sync & async)

**Files:**
- Modify: `clients/python/src/zigbase/typed.py`, Create: `clients/python/tests/test_typed_service.py`

**Interfaces (Produces):**
```python
@dataclass(frozen=True)
class TypedList(Generic[T]):
    items: list[T]; page: int; per_page: int; total_items: int; total_pages: int
@dataclass(frozen=True)
class TypedCursorPage(Generic[T]):
    items: list[T]; next_cursor: str | None; prev_cursor: str | None
    has_next: bool; has_prev: bool; total_items: int | None

def join_csv(vs: Sequence[str] | None) -> str | None: ...     # None/empty -> None (param omitted)
def normalize_sort(sort: str | Sequence[str] | None) -> str | None: ...

class TypedCollection(Generic[T]):
    def __init__(self, client: ZigBase, meta: CollectionMeta, from_record: Callable[[Mapping[str, Any]], T]) -> None: ...
    # get_list -> TypedList[T]; get_one; get_first_list_item; get_page -> TypedCursorPage[T];
    # iterate -> Iterator[T]; get_full_list -> list[T]; create(body: Mapping)/update(id, body)/delete;
    # file_url(record_dict, filename, *, download=False, thumb=None, token=None) -> str
    # All read paths map through from_record; writes take the RAW dict the generated to_map() produced.
    # where: on every query method accept `where: Callable[[], Expr] | Expr | None = None` — actually match
    #   the generated-service pattern: services compile where themselves; TypedCollection takes filter: str | None.
    @property
    def collection(self) -> CollectionService: ...   # escape hatch (auth/abilities)

class AsyncTypedCollection(Generic[T]):  # same surface over AsyncZigBase/AsyncCollectionService, async methods
```
Keep TypedCollection thin like typed.dart:353-522: it receives already-compiled `filter: str | None`, `sort` via normalize_sort, `expand` via join_csv. The where-compilation happens in generated services (Task 6's emitted code), matching Dart.

- [ ] **Step 1: Write failing tests** (MockTransport like test_collection.py): reads map through from_record (assert instance types); get_page cursor round-trip; iterate maps every item; create/update pass the raw dict body through untouched; file_url delegates to FilesService semantics (string building — construct with a record dict carrying collectionName); escape hatch returns the underlying service; async mirror for get_list/create/iterate.
- [ ] **Step 2: RED.** — **Step 3: Implement.** — **Step 4: Gates PASS.** — **Step 5: Commit** (`feat(python-sdk): generic typed collection services`)

---

### Task 4: Typed runtime — TypedRealtime (async-only)

**Files:**
- Modify: `clients/python/src/zigbase/typed.py`, Create: `clients/python/tests/test_typed_realtime.py`

**Interfaces (Produces):**
```python
@dataclass(frozen=True)
class TypedRealtimeEvent(Generic[T]):
    topic: str; action: str; record: T

class TypedRealtime(Generic[T]):
    def __init__(self, client: AsyncZigBase, meta: CollectionMeta, from_record: Callable[[Mapping[str, Any]], T]) -> None: ...
    async def subscribe(self, callback: Callable[[TypedRealtimeEvent[T]], Any], *,
                        filter: str | None = None, where: Expr | None = None) -> Unsubscribe: ...
    def stream(self, *, filter: str | None = None, where: Expr | None = None) -> AsyncIterator[TypedRealtimeEvent[T]]: ...
    # where.compile() if where else filter; topic = meta.name; NO close() (shared service; typed.dart:529-569)
```
Delete events carry `{"id": ...}` only — from_record must still be applied? NO: mirror Dart — delete events pass through from_record too (the generated from_record tolerates missing fields via coercer fallbacks). Verify against typed.dart's TypedRealtime and match exactly; flag in the report if Dart special-cases deletes.

- [ ] **Step 1: Write failing tests** (fake connector from tests/support): subscribe delivers TypedRealtimeEvent with converted record; where: Expr compiles into the subscribe frame's filter; stream yields typed events and tears down on break; no close() attribute (assert absence to lock the contract).
- [ ] **Step 2: RED.** — **Step 3: Implement.** — **Step 4: Gates PASS.** — **Step 5: Commit** (`feat(python-sdk): typed realtime wrapper`)

---

### Task 5: Zig emitter — types, records/enums/payload models, `--lang python` wiring

**Files:**
- Create: `src/codegen/python_type.zig`, `src/codegen/emit_python.zig`, `src/codegen/gen_python.zig`, `clients/python/tests/codegen/dating/zbase_gen.py` (generated + committed)
- Modify: `src/codegen/gen_client.zig` (~:888 lang branch), `src/codegen/typegen_cli.zig` (~:35 Lang enum + run switch), `build.zig` (steps `gen-dating-python-client`, mirroring :279-286), `src/root.zig` (test block references)

**Interfaces (Produces):**
- `gen_python.generate(alloc, cols, comptime routes, comptime custom_auth, flags, experiments, in_repo, auth_collection, client_name, api_prefix)` — same signature as `gen_dart.generate` (gen_dart.zig:28); discards routes/custom_auth/flags/experiments.
- Generated (this task's scope — the data half): file header (schema-hash + TYPED_CORE_VERSION comment + generated-file warning), imports (`from __future__ import annotations`, pydantic `BaseModel`, zigbase.typed coercers), per select field a `class <Rec><Field>(str, Enum)` with wire values + `@classmethod from_wire`, per collection a `class <Rec>(BaseModel)` with typed fields + `@classmethod from_record(cls, r: Mapping) -> <Rec>` using the coercers (int fields coerce_int, fixed coerce_float-from-decimal-string, select from_wire, relation str/list[str], json Any, expand submodel `class <Rec>Expand(BaseModel)` via expand_one/expand_many), plus `<Rec>Create`/`<Rec>Update` BaseModels with `def to_map(self) -> dict[str, Any]` applying encode_int/encode_fixed/enum `.value`-wire/file passthrough and omitting unset fields (auth collections: Create adds email/password/password_confirm→wire `passwordConfirm`, Update omits password).
- Field-type mapping per the research table: text/email/url/editor/date/autodate→`str`; number int→`int`, float→`float`, fixed→`float` (wire decimal string handled by encode/coerce); bool→`bool`; json→`Any`; select→Enum (multi→`list[Enum]`); relation/file→`str`/`list[str]`; Create file fields→`FileArg` (reuse `zigbase._multipart.FileArg`).
- Python keyword sanitization per Global Constraints.

- [ ] **Step 1: Write the emitter skeleton + a Zig snapshot test** (mirror how gen-test works for TS/Dart — a byte-exact expected fragment for one small collection; register files in src/root.zig).
- [ ] **Step 2: Wire `--lang python` + build step; generate the dating golden; `ruff format` it from clients/python; commit the golden.** Verify: `zig build gen-dating-python-client` is idempotent post-format (regen+format → no diff).
- [ ] **Step 3: Python-side golden sanity test** (`tests/codegen/test_golden_imports.py`, unit-marked): `import` the generated module (pydantic installed via `[typed]` in dev env — ADD `pydantic>=2` to the `typed` extra AND to dev extras in this task), instantiate one record via from_record with a canned dict, assert field types (age int, price float, gender enum), to_map round-trip for Create with fixed-scale rendering.
- [ ] **Step 4: All gates + `zig build test --summary all` PASS.**
- [ ] **Step 5: Commit** (`feat(typegen): python emitter — records, enums, payload models`)

---

### Task 6: Zig emitter — fields builders, meta, services, realtime, client factory

**Files:**
- Modify: `src/codegen/emit_python.zig`, `src/codegen/gen_python.zig`, the committed golden (regenerated), `build.zig` (add `gen-dating-python-client-check`)

Generated additions (the behavior half, mirroring zbase.gen.dart):
- `class <Rec>Fields` with `def __init__(self, prefix: str = "")`; per-field getters returning the right FieldExpr subclass with `f"{prefix}{name}"` paths; relations → `RelFieldExpr("<path>", TargetFields)`; selects → `EnumFieldExpr(..., wire_of=lambda e: e.value)`.
- `<col>_meta: CollectionMeta` consts.
- `class <Rec>sService` (sync, wraps `TypedCollection[<Rec>]`) and `class Async<Rec>sService` (wraps `AsyncTypedCollection`): query methods accept `where: Callable[[<Rec>Fields], Expr] | None` and compile via `where(<Rec>Fields()).compile()`; `create(data: <Rec>Create)` → `._c.create(data.to_map())`; `filter(fn)` helper; auth collections graft `auth_with_password` passthrough; typed `file_url(record, field: <Rec>FileField, ...)` with a per-collection file-field Enum.
- `class <Rec>sRealtime(TypedRealtime[<Rec>])` (async-only).
- Client factories: `class ZbClient` (sync: db services only) and `class AsyncZbClient` (async: services + realtime attrs), each lazy-constructing per-collection services over a passed base client; `def create_client(url, **kw) -> ZbClient` / `create_async_client`.
- [ ] **Step 1: Extend the Zig snapshot test for one service+fields fragment; RED (snapshot mismatch) then implement.**
- [ ] **Step 2: Regenerate golden + ruff format; add `gen-dating-python-client-check` to build.zig; verify check step green and byte-idempotent.**
- [ ] **Step 3: Python golden behavior tests** (extend tests/codegen/, unit-marked, MockTransport): typed get_list maps to Profile instances; where lambda compiles into the sent filter param (assert query string); create sends to_map output; nested rel filter compiles dotted path; sync + async service smoke.
- [ ] **Step 4: All gates + zig build test + check step PASS.**
- [ ] **Step 5: Commit** (`feat(typegen): python emitter — fields, services, client factory`)

---

### Task 7: CI wiring

**Files:**
- Modify: `.github/workflows/ci.yml` — (a) `build` job: python golden freshness gate after the Dart one (regenerate via `zig build gen-dating-python-client`, `ruff format` the golden via mise python from clients/python, `git diff --exit-code`); (b) `python-sdk` job: add dating-server chmod + `ZIGBASE_TEST_DATING_BINARY` export (copy the dart-sdk pattern at ci.yml:445-447); install line gains nothing (pydantic comes via dev extras from Task 5's pyproject change — verify; if not, extend the install to `[dev,realtime,typed]`).

- [ ] **Step 1: Write the workflow changes; YAML sanity check; confirm the build job's gate commands run locally end-to-end (regen → format → clean diff).**
- [ ] **Step 2: Gates + unit suite green.**
- [ ] **Step 3: Commit** (`ci(python-sdk): golden freshness gate and dating binary for typed e2e`)

---

### Task 8: Typed e2e against dating-server

**Files:**
- Create: `clients/python/tests/integration/test_typed_dating_live.py` (own harness fixture launching `ZIGBASE_TEST_DATING_BINARY`; module-level skip when unset — mirror the Dart guard so plain runs stay green; do NOT touch the existing conftest's zigbase-binary fixtures beyond reuse of free-port/health-poll helpers if importable)

Coverage (mirror clients/dart/test/integration/typed_dating_test.dart): auth (profiles authWithPassword via typed service graft) → CRUD with typed models → nested-relation fluent filter (`p.owner.rel(lambda o: o.name.like(...))`) → expand single+multi (PhotoExpand.owner/tags) → cursor paging via get_page → int coercion (`isinstance(profile.age, int)`) → fixed(2) round-trip (9.99 → wire "9.99" → 9.99) → typed realtime create event (AsyncZbClient) → file URLs (public avatar fetchable; private photo 403 bare / 200 with files token). Build dating-server first: `mise exec zig@0.16.0 -- zig build dating-server`. Run the file twice for flakes; whole integration suite once (existing 27 must stay green).

- [ ] **Step 1: Harness + smoke (typed get_list against live).** — **Step 2: Coverage tests; run 2x; fix SDK/emitter bugs found (own commits + unit/golden tests each).** — **Step 3: Gates + full unit suite.** — **Step 4: Commit** (`test(python-sdk): typed tier e2e against dating fixture`)

---

### Task 9: Packaging + docs + changelog

**Files:**
- Modify: `clients/python/pyproject.toml` (confirm `typed = ["pydantic>=2"]` extra from Task 5; dev extras include pydantic), `clients/python/README.md` (typed quickstart: generate via `zigbase typegen --lang python`, create_client usage, where lambda sample), `clients/python/CHANGELOG.md` ([Unreleased] typed entry), `docs/python-sdk.md` + `site/src/content/docs/python-sdk.md` (Typed tier section modeled on docs/dart-sdk.md §typed-tier at ~L673: generation commands, generated surface, fluent filters + injection safety, coercion semantics incl. int/fixed, expand, typed realtime, `[typed]` extra, TYPED_CORE_VERSION compat note, RPC-not-emitted note), `docs/framework.md`/`docs/api.md` typegen references gain `--lang python` where `--lang dart` is listed (grep, update real lists only)
- Create: `changelog.d/python-sdk-typed.md`:
```markdown
### Features

- Python SDK typed tier (`zigbase[typed]`): `zigbase typegen --lang python` generates Pydantic v2 record models, injection-safe fluent filter builders, and typed sync/async collection services (plus async typed realtime) over the new `zigbase.typed` runtime, golden-gated in CI against the dating fixture.
```

- [ ] **Step 1: Write all docs; snippet audit every sample against the generated golden + typed.py; site build green with the new section.**
- [ ] **Step 2: Grep check for stale "--lang ts|dart"-only lists; four gates + unit suite.**
- [ ] **Step 3: Commit** (`docs(python-sdk): typed tier docs, extra, changelog fragment`)

---

## Self-review notes (applied)
- Spec coverage: SP3 spec section = "Python emitter in the existing typegen pipeline; Pydantic v2 models per collection + typed accessors wrapping the base client (both sync and async); validation + serialization; golden-file gating like Dart" — Tasks 5-6 (emitter+golden), 1-4 (runtime), 3 (sync+async accessors), 7 (gates), 8 (e2e), 9 (extra+docs). JSON-Schema-export selling point comes free with pydantic (mention in docs, no work).
- Type consistency: FieldMeta/CollectionMeta (T1) consumed by T3/T4/T6 emitted code; Expr/FieldExpr (T2) consumed by T4 (where=) and T6 (generated builders); TypedCollection/AsyncTypedCollection (T3) wrapped by T6 services; TYPED_CORE_VERSION defined T1, stamped T5.
- Deliberate scope-outs recorded: RPC + typed custom-auth emission (TS-only today — follow the Dart queue), dict-shaped where (TS-only), fixture multi-select/multi-file additions.
