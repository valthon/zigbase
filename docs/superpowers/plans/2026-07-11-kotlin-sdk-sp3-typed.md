# Kotlin Client SDK KSP3 (Typed Tier) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the typed tier of the Kotlin SDK — the third and final Kotlin milestone: a hand-written `io.github.valthon.zigbase.typed` runtime plus a new `--lang kotlin` emitter in the server's typegen pipeline generating `@Serializable` record data classes with `fromRecord` coercion, Create/Update payload models with `toMap` wire encoding, fluent injection-safe filter builders, one typed collection service per collection, and Flow-based typed realtime — golden-gated in CI and proven e2e against the dating fixture. **RPC / typed custom-auth emission is out of scope** (TS-only across all SDKs).

**Architecture:** Two halves.
1. **A hand-written typed runtime** in the base module (`clients/kotlin/src/main/kotlin/io/github/valthon/zigbase/typed/*.kt`, package `io.github.valthon.zigbase.typed`), ported from Python's `zigbase/typed.py` / Dart's `typed.dart`: meta types, wire coercers (int-raises-on-fractional, `ROUND_HALF_UP` fixed rendering, byte-parity number/date via the base SDK's existing `query.filterValue`/`formatDate`), an `Expr`/`FieldExpr` filter DSL that routes every operand through the existing `io.github.valthon.zigbase.query.filterValue` chokepoint, `TypedList`/`TypedCursorPage`, one generic **suspend-based** `TypedCollection` (no sync/async fork — Kotlin is coroutine-first, matching Dart's single async surface), and a Flow-based `TypedRealtime`.
2. **A Zig emitter trio** (`kotlin_type.zig`, `emit_kotlin.zig`, `gen_kotlin.zig`) mirroring the Python/Dart emitters, wired into `--lang kotlin`, producing a committed golden `clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/codegen/dating/ZbaseGen.kt` whose formatting is delegated to **Spotless/ktlint** (`spotlessApply`, the `dart format` / `ruff format` pattern). Because the golden lives in the **test source set**, `gradle build` compiles it and `spotlessCheck` lints it — a stronger validity guarantee than Python's import-only golden test.

**Tech Stack:** Kotlin 2.4 / Kotlin/JVM, JDK 17 floor (`clients/kotlin/build.gradle.kts`); kotlinx.serialization for the generated `@Serializable` models; coroutines (`suspend` + `Flow`) throughout; ktor `MockEngine` for unit tests; Zig 0.16 for the emitter; the dating fixture (`fixtures/dating/schema.zig`) as generator input and e2e server. No new runtime dependency is added (kotlinx.serialization is already a base dependency — unlike Python's optional Pydantic `[typed]` extra, the Kotlin typed tier ships entirely in the one artifact).

**Normative references:**
- **Emitter template:** the Python trio `src/codegen/{gen_python,emit_python,python_type}.zig` (primary), cross-checked against the Dart trio `src/codegen/{gen_dart,emit_dart,dart_type}.zig`. Wiring: `src/codegen/typegen_cli.zig` (`Lang` enum + `parseLang` + the `switch (opts.lang)` dispatch), `src/codegen/gen_client.zig` (the `--lang` argv branch ~L838/L892 + `mainWithCollections`), `src/codegen/gen_main.zig`, `build.zig` (the `gen-dating-python-client` step at :288-298), `src/root.zig` (the `codegen` struct + test block at :249-253 / :402-404).
- **Runtime template:** `clients/python/src/zigbase/typed.py` (primary — meta/coercers/Expr-DSL/TypedCollection/TypedRealtime) and its tests (`clients/python/tests/test_typed_coerce.py`, `test_typed_where.py`, `test_typed_service.py`, `test_typed_realtime.py`, `integration/test_typed_dating_live.py`); `clients/dart/lib/typed.dart` (the single-async shape Kotlin follows, since Kotlin has no sync fork).
- **Existing Kotlin SDK (REUSE, do not reimplement):** KSP1 base — `query/Query.kt` (`filterValue`/`zbFilter`/`formatDate`/`formatJsNumber` — the chokepoint + byte-parity number/date rendering are DONE), `CollectionService.kt` (suspend CRUD + `Flow` `iterate`, `AuthResponse`, `authWithPassword`), `ZbRecord.kt`, `FilesService.kt` (`getUrl`), `FileArg.kt`, `ZigbaseClient.kt` (facade + `realtime`/`collection`/`files`); KSP2 realtime — `realtime/RealtimeService.kt` (`stream(topic, filter): Flow<RealtimeEvent>`, `subscribe`), `RealtimeEvent.kt`. Test infra: `src/test/.../realtime/FakeConnector.kt`, ktor `MockEngine` patterns in `CollectionServiceTest.kt`; `src/integrationTest/.../Harness.kt` (free-port + health-poll).
- **Structural plan template:** `docs/superpowers/plans/2026-07-10-python-sdk-sp3-typed.md`. Global-Constraints template: `docs/superpowers/plans/2026-07-10-kotlin-sdk-sp1-base-client.md` and `...-sp2-realtime.md`.
- **Spec:** `docs/superpowers/specs/2026-07-10-kotlin-sdk-design.md` (KSP3 / typed-tier section).

---

## Global Constraints

- **Paths & commands.** Runtime + tests in `clients/kotlin/`; emitter in `src/codegen/` + `build.zig` + `src/root.zig`. Kotlin gates: `mise exec gradle@9.6 -- gradle -p clients/kotlin spotlessCheck build` (unit + format/lint) and `... integrationTest` (live). Zig gates: `mise exec zig@0.16.0 -- zig build test --summary all` (authoritative signal is the `Build Summary: N/N tests passed` line) + the golden step. Never leave the worktree; absolute paths only.
- **All KSP1/KSP2 conventions hold.** TDD (RED before GREEN) on every task; KDoc on public runtime types naming the Python/Dart counterparts; `internal` visibility for internals; Spotless-clean; commit style `feat(kotlin-sdk)` / `feat(typegen)` / `test(kotlin-sdk)` / `docs(kotlin-sdk)` ending with the Claude co-author trailer; do NOT push mid-plan (run tell-a-git-story before any PR). Carry the cross-SDK hardenings: loud rejection of non-encodable/non-finite operands (already in `filterValue`), byte-parity number/date, every filter operand through the ONE `filterValue` chokepoint, discriminating e2e assertions with negative controls.
- **Runtime is hand-written; it ships in the one base artifact.** No optional extra (unlike Python's `[typed]`): kotlinx.serialization is already a base dependency. Package `io.github.valthon.zigbase.typed`. A `TYPED_CORE_VERSION` constant is defined here and mirrored in the emitter's generated header comment (kept in sync by hand, like `gen_python.zig`'s `TYPED_CORE_VERSION`).
- **Injection safety is non-negotiable.** Every operand the filter DSL interpolates flows through `io.github.valthon.zigbase.query.filterValue` — the DSL never formats an operand itself. The O'Brien test (`f.title.eq("O'Brien").compile() == "title = 'O\\'Brien'"`) is mandatory. Enum operands are serialized to their wire string via `wireOf` FIRST, then handed to `filterValue` (a raw enum reaching `filterValue` must throw, matching Python).
- **Wire coercion parity with Dart/Python.** `coerceInt` returns `Long` and **raises `IllegalArgumentException` on a fractional value** (`9.99`, `"9.99"`) — schema drift must not truncate silently; int/fixed cross the wire as **decimal strings** (`encodeInt(v: Long?)` → `v.toString()`; `encodeFixed(v: Double?, scale)` → `BigDecimal(v).setScale(scale, RoundingMode.HALF_UP)` rendered fixed — half-away-from-zero on the exact binary value, NOT `String.format`'s half-to-even); `Double` (float/fixed) is passed to `filterValue`/left as-is on read. `Boolean` is excluded from the numeric coercers (Kotlin `is Long`/`is Double` already exclude `Boolean`, matching Dart's `v is int`).
- **No sync/async fork.** Kotlin is coroutine-first: ONE `TypedCollection` with `suspend` CRUD methods + a `Flow` `iterate`/`getFullList`, mirroring the base `CollectionService`. `TypedRealtime` is Flow-based over the single shared `RealtimeService` (no per-collection `close()` — closing the shared service kills every subscription; the base `ZigbaseClient.close()` owns teardown). This halves the emitter surface vs Python (no `emitAsyncService`/`AsyncZbClient`).
- **Generated shape.** `@Serializable data class <Rec>(...)` + `companion object { fun fromRecord(r: JsonObject): <Rec> }`; select fields → `enum class <Rec><Field>(val wire: String) { ... ; companion object { fun fromWire(v: String?): ...? } }`; `<Rec>Create`/`<Rec>Update` `data class`es with `fun toMap(): Map<String, Any?>`; `class <Rec>Fields(prefix: String = "")`; `val <col>Meta: CollectionMeta`; `class <Rec>sService(client: ZigbaseClient)`; `class <Rec>sRealtime(client: ZigbaseClient)`; a `ZbClient` facade + `fun createClient(url, ...): ZbClient`. Generated members whose sanitized Kotlin name ≠ wire key carry `@SerialName("<wire>")` so kotlinx serialization of the model stays wire-faithful.
- **Kotlin reserved-word sanitization** in the emitter mirrors `emit_python.zig`'s `memberIdent`: hardcode Kotlin's hard keyword list (`as break class continue do else false for fun if in interface is null object package return super this throw true try typealias typeof val var when while`) + a context-reserved set per scope (record: `expand`, `fromRecord`; payload: `toMap`; enum: `wire`, `fromWire`, `entries`, `values`, `valueOf`, `name`, `ordinal`; client: `raw`, `owned`, `close`, `send`, `authStore`, `realtime`). A sanitized member gets a trailing `_`; the wire key is NEVER changed (`fromRecord` reads `r["class"]`, `toMap` writes `m["class"]`, and `@SerialName("class")` is emitted). A generation-time duplicate-identifier check (two schema names collapsing to one Kotlin identifier) errors loudly (`error.KotlinIdentCollision`), mirroring `checkDuplicateIdents`. Rationale for trailing-`_` over Kotlin backtick-escaping (`` `class` ``): cross-SDK consistency with emit_python/emit_dart and cleaner generated source.
- **Emitter signature parity.** `gen_kotlin.generate(...)` mirrors `gen_python.generate`'s exact 11-arg signature (`gen_python.zig:37`); `routes`/`custom_auth`/`flags`/`experiments` are accepted and discarded (`_ = routes;` …). New `src/codegen/*.zig` files MUST be added to `src/root.zig`'s `codegen` struct AND its test block or their tests never run (mirror :249-253 and :402-404).
- **Golden + idempotency.** `clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/codegen/dating/ZbaseGen.kt`, package `io.github.valthon.zigbase.codegen.dating`, committed **Spotless-clean**. `build.zig` step `gen-dating-kotlin-client` (mirroring :288-298) writes it; the freshness gate = regenerate → `spotlessApply` → `git diff --exit-code <golden>` (the Dart/Python format-then-diff pattern). Because Spotless's `target("src/**/*.kt")` already covers the test source set, the committed golden must be ktlint-clean or `spotlessCheck build` fails — so emit **explicit imports** (no wildcard `import ...typed.*`, which trips the non-autofixable `no-wildcard-imports` rule) and let `spotlessApply` normalize everything else. Header carries the `schema-hash` (reuse `gen_client.schemaHash`) + a `typed-core-version` comment.
- **Fixture coverage gap.** The dating fixture has no multi-select or multi-file (non-relation) field, so unit-test `coerceStringList`/`coerceIntList`/`coerceDoubleList` and the multi-select enum coercion directly (T1); do NOT modify the shared fixture.

---

### Task 1: Typed runtime — metadata, coercers, encoders, expand helpers

**Files:**
- Create: `clients/kotlin/src/main/kotlin/io/github/valthon/zigbase/typed/Meta.kt`, `.../typed/Coerce.kt`, `clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/typed/CoerceTest.kt`

**Interfaces (Produces):** (port of `typed.py` metadata + coercion sections)
```kotlin
package io.github.valthon.zigbase.typed

const val TYPED_CORE_VERSION = "0.1.0"

enum class FieldType(val wire: String) { TEXT("text"), EDITOR("editor"), EMAIL("email"), URL("url"),
    NUMBER("number"), BOOLEAN("boolean"), DATE("date"), AUTODATE("autodate"), SELECT("select"),
    RELATION("relation"), FILE("file"), JSON("json") }
enum class NumberMode { FLOAT, INTEGER, FIXED }

data class FieldMeta(val type: FieldType, val multi: Boolean = false,
    val mode: NumberMode = NumberMode.FLOAT, val scale: Int? = null)
data class CollectionMeta(val name: String, val fields: Map<String, FieldMeta>,
    val fileFields: List<String> = emptyList(), val expandable: List<String> = emptyList(),
    val isAuth: Boolean = false, val searchable: List<String>? = null, val tenant: String? = null) {
    fun field(name: String): FieldMeta? = fields[name]
}

// Coerce.kt — reads from kotlinx JsonElement (records arrive as JsonObject)
fun coerceLong(v: JsonElement?, fallback: Long = 0L): Long   // RAISES on fractional (9.99 / "9.99")
fun coerceDouble(v: JsonElement?, fallback: Double = 0.0): Double
fun coerceString(v: JsonElement?, fallback: String = ""): String
fun coerceBoolean(v: JsonElement?, fallback: Boolean = false): Boolean
fun coerceStringList(v: JsonElement?): List<String>
fun coerceLongList(v: JsonElement?): List<Long>
fun coerceDoubleList(v: JsonElement?): List<Double>
fun encodeInt(v: Long?): String?                    // decimal string for wire
fun encodeFixed(v: Double?, scale: Int): String?    // BigDecimal(v).setScale(scale, HALF_UP) rendered fixed
fun <T> expandOne(record: JsonObject, key: String, fromRecord: (JsonObject) -> T): T?
fun <T> expandMany(record: JsonObject, key: String, fromRecord: (JsonObject) -> T): List<T>
```
Behavior parity with `typed.py:121-274` exactly: empty/absent → fallback; `"42.0"`/`42.0` accepted by `coerceLong`, `"42.5"`/`9.99` raise `IllegalArgumentException`; a JSON number with no fractional part is accepted; `Boolean` never satisfies the numeric coercers. `expandOne`/`expandMany` read `record["expand"]?[key]` (a `JsonObject`/`JsonArray`), absent → `null`/`[]`. Coercers read `kotlinx.serialization.json` primitives (`JsonPrimitive.longOrNull`, `.doubleOrNull`, `.isString`/`.content`, `.booleanOrNull`) — reuse the accessor patterns from `ZbRecord.kt`.

- [ ] **Step 1: RED** — write `CoerceTest.kt`: every coercer's accept/reject/fallback matrix (fractional-Long rejection both number and string forms; list coercers on arrays/scalars/absent/mixed; `encodeFixed` scale rendering — `9.99 → "9.99"`, `5.0 @ scale 2 → "5.00"`, the `0.125 @ scale 2 → "0.13"` HALF_UP-vs-HALF_EVEN discriminator from `typed.py`'s docstring; `encodeInt` `5L → "5"`, `null → null`); `expandOne`/`expandMany` with a lambda converter (present single, present list, absent, empty expand block). Assert exact bytes.
- [ ] **Step 2: Run the module's `test` task, verify FAIL.**
- [ ] **Step 3: Implement `Meta.kt` + `Coerce.kt`.**
- [ ] **Step 4: `spotlessCheck build` PASS.**
- [ ] **Step 5: Commit** (`feat(kotlin-sdk): typed runtime metadata and wire coercion`)

---

### Task 2: Typed runtime — Expr / FieldExpr filter DSL over filterValue

**Files:**
- Create: `clients/kotlin/src/main/kotlin/io/github/valthon/zigbase/typed/Filter.kt`, `clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/typed/FilterTest.kt`

**Interfaces (Produces):** (port of `typed.py:281-492`, adapted to Kotlin's operator rules)
```kotlin
class Expr internal constructor(private val src: String) {
    fun compile(): String = src
    override fun toString(): String = src
}
infix fun Expr.and(other: Expr): Expr   // Expr("(${a} && ${b})")
infix fun Expr.or(other: Expr): Expr    // Expr("(${a} || ${b})")

open class FieldExpr(protected val path: String) {              // eq / neq / inList
    infix fun eq(value: Any?): Expr                             // "$path = ${filterValue(value)}"
    infix fun neq(value: Any?): Expr
    fun inList(values: List<Any?>): Expr                        // "$path in (v1, v2)"; empty -> "$path in ()"
}
open class ComparableFieldExpr(path: String) : FieldExpr(path)  // adds gt/gte/lt/lte (infix)
class StringFieldExpr(path: String) : ComparableFieldExpr(path) // adds like/nlike (~ / !~, infix)
class NumberFieldExpr(path: String) : ComparableFieldExpr(path) // operands are `Number` (Int/Long/Double)
class DateFieldExpr(path: String) : ComparableFieldExpr(path)   // operands `Any` (Instant/OffsetDateTime/String)
class BoolFieldExpr(path: String) : FieldExpr(path)
class EnumFieldExpr<E>(path: String, private val wireOf: (E) -> String) : FieldExpr(path) {
    infix fun eq(value: E?): Expr    // filterValue(value?.let(wireOf))  — null stays un-wired
    infix fun neq(value: E?): Expr
    fun inList(values: List<E?>): Expr
}
class RelFieldExpr<F>(path: String, private val makeFields: (String) -> F) : FieldExpr(path) {
    fun <R> rel(build: (F) -> R): R = build(makeFields("$path."))   // one nesting level: author.name ~ 'A'
}
```
Op map (parity with `typed.py`'s `_OP_MAP`): `eq =`, `neq !=`, `gt >`, `gte >=`, `lt <`, `lte <=`, `like ~`, `nlike !~`. Every operand through `io.github.valthon.zigbase.query.filterValue` (import it; a `List`/unsupported operand throws from `filterValue` itself). **Kotlin operator note (decided):** unlike Python, Kotlin cannot overload `==`/`&`/`|` to return a non-`Boolean` — so ops are `infix` methods (`f.age gt 18`) and combinators are `infix fun and`/`or` (`(f.a eq 1) and (f.b eq 2)`). There is therefore NO `__bool__`-style ambiguity footgun to guard against (Kotlin `&&`/`||` require real `Boolean`s), so no `Expr.toBoolean()`-throws hack is needed — simpler than the Python port.

- [ ] **Step 1: RED** — `FilterTest.kt` asserting exact `.compile()` bytes (mirror `test_typed_where.py`): all 8 scalar ops; injection `StringFieldExpr("title") eq "O'Brien"` → `"title = 'O\\'Brien'"`; `inList` values + empty → `"title in ()"`; `and`/`or` parenthesization; `EnumFieldExpr` `wireOf` serialization (and a raw enum reaching `filterValue` throws); relation id-eq; nested `RelFieldExpr("author") { UserFields(it) }.rel { it.name like "Ann" }.compile() == "author.name ~ 'Ann'"` (hand-written minimal `UserFields` in the test); `Instant` operand renders via `formatDate` quoting; `NumberFieldExpr` with `Long`/`Double`/`Int`; a `List` operand throws `IllegalArgumentException`.
- [ ] **Step 2: RED. — Step 3: Implement. — Step 4: Gates PASS. — Step 5: Commit** (`feat(kotlin-sdk): typed filter DSL over filterValue`)

---

### Task 3: Typed runtime — result envelopes + TypedCollection (suspend + Flow)

**Files:**
- Create: `clients/kotlin/src/main/kotlin/io/github/valthon/zigbase/typed/TypedCollection.kt`, `clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/typed/TypedCollectionTest.kt`

**Interfaces (Produces):** (port of `typed.py:500-757`, single-async à la Dart)
```kotlin
data class TypedList<T>(val items: List<T>, val page: Int, val perPage: Int,
    val totalItems: Int, val totalPages: Int)
data class TypedCursorPage<T>(val items: List<T>, val nextCursor: String?, val prevCursor: String?,
    val hasNext: Boolean, val hasPrev: Boolean, val totalItems: Int?)

internal fun joinCsv(values: List<String>?): String?          // null/empty -> null (param omitted)
internal fun normalizeSort(sort: List<String>?): String?      // comma-join; empty -> null

class TypedCollection<T>(client: ZigbaseClient, val meta: CollectionMeta,
    private val fromRecord: (JsonObject) -> T) {
    val collection: CollectionService   // escape hatch (auth/abilities)
    suspend fun getList(page: Int = 1, perPage: Int = 30, filter: String? = null,
        sort: List<String>? = null, expand: List<String>? = null, fields: String? = null,
        skipTotal: Boolean = false, search: String? = null): TypedList<T>
    suspend fun getOne(id: String, expand: List<String>? = null, fields: String? = null): T
    suspend fun getFirstListItem(filter: String, ...): T
    suspend fun getPage(cursor: String? = null, limit: Int = 30, filter: String? = null, ...): TypedCursorPage<T>
    fun iterate(batch: Int = 100, filter: String? = null, ...): Flow<T>       // maps each ZbRecord.raw through fromRecord
    suspend fun getFullList(batch: Int = 100, ...): List<T>
    suspend fun create(body: Map<String, Any?>, expand: List<String>? = null, fields: String? = null): T
    suspend fun update(id: String, body: Map<String, Any?>, ...): T
    suspend fun delete(id: String)
    fun fileUrl(record: ZbRecord, filename: String, download: Boolean = false,
        thumb: String? = null, token: String? = null): String
}
```
Keep it thin like `TypedCollection` in `typed.py`: `filter` is an already-compiled string (where-compilation happens in the generated service, T6); `sort`/`expand` go through `normalizeSort`/`joinCsv`; every read maps `ZbRecord.raw` (a `JsonObject`) through `fromRecord`; writes take the RAW `Map` a generated `toMap()` produced, untouched. Wraps the base `client.collection(meta.name)` and `client.files`. `iterate` maps the base `CollectionService.iterate` `Flow<ZbRecord>` via `.map { fromRecord(it.raw) }`.

- [ ] **Step 1: RED** — `TypedCollectionTest.kt` with ktor `MockEngine` (pattern from `CollectionServiceTest.kt`): reads map through `fromRecord` (assert element types); `getPage` cursor round-trip; `iterate` maps every item; `create`/`update` pass the raw `Map` body through untouched (assert the sent JSON body); `fileUrl` delegates to `FilesService.getUrl` semantics (build a `ZbRecord` carrying `collectionName`); `collection` escape hatch returns the underlying `CollectionService`; `getList`/`getPage` map envelope fields (`totalPages`, `nextCursor`, `hasNext`).
- [ ] **Step 2: RED. — Step 3: Implement. — Step 4: Gates PASS. — Step 5: Commit** (`feat(kotlin-sdk): generic typed collection service`)

---

### Task 4: Typed runtime — TypedRealtime (Flow-based)

**Files:**
- Create: `clients/kotlin/src/main/kotlin/io/github/valthon/zigbase/typed/TypedRealtime.kt`, `clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/typed/TypedRealtimeTest.kt`

**Interfaces (Produces):** (port of `typed.py:962-1048`, over KSP2's `RealtimeService`)
```kotlin
data class TypedRealtimeEvent<T>(val topic: String, val action: String, val record: T)

open class TypedRealtime<T>(client: ZigbaseClient, val meta: CollectionMeta,
    private val fromRecord: (JsonObject) -> T) {
    suspend fun subscribe(where: Expr? = null, filter: String? = null,
        callback: suspend (TypedRealtimeEvent<T>) -> Unit): suspend () -> Unit
    fun stream(where: Expr? = null, filter: String? = null): Flow<TypedRealtimeEvent<T>>
    // effectiveFilter = where?.compile() ?: filter; topic = meta.name; NO close() (shared service)
}
```
`stream` is `client.realtime.stream(meta.name, effectiveFilter).map { TypedRealtimeEvent(it.topic, it.action, fromRecord(it.record.raw)) }` — inherits KSP2's cold-Flow subscribe-on-first-collect / clean-cancellation / reject-throws contract unchanged. `subscribe` wraps `RealtimeService.subscribe`, converting each `RealtimeEvent` through `fromRecord`. **Delete events** (`record` wraps `{"id": ...}` only) STILL run through `fromRecord` — its coercer fallbacks tolerate the missing fields — matching `typed.py`/`typed.dart` (no delete special-case; the report notes Dart/Python do the same). No per-collection `close()` (shared multiplexed service; `ZigbaseClient.close()` owns teardown).

- [ ] **Step 1: RED** — `TypedRealtimeTest.kt` using the injected fake connector (`ZigbaseClient.realtimeConnectorForTesting` + `FakeConnector.kt`): `stream` yields typed events with converted records and tears down on cancellation/`take(n)`; a `where: Expr` compiles into the subscribe frame's filter (assert the frame the fake connector received); a `delete` event's id-only record still converts (every non-id field falls back); `subscribe` delivers `TypedRealtimeEvent` and the returned lambda unsubscribes. Assert there is no `close()` on `TypedRealtime` (compile-level contract).
- [ ] **Step 2: RED. — Step 3: Implement. — Step 4: Gates PASS. — Step 5: Commit** (`feat(kotlin-sdk): typed realtime Flow wrapper`)

---

### Task 5: Zig emitter — types, records/enums/payload models, `--lang kotlin` wiring, golden (data half)

**Files:**
- Create: `src/codegen/kotlin_type.zig`, `src/codegen/emit_kotlin.zig`, `src/codegen/gen_kotlin.zig`, `clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/codegen/dating/ZbaseGen.kt` (generated + committed)
- Modify: `src/codegen/typegen_cli.zig` (`Lang` enum `{ ts, dart, python, kotlin }` + `parseLang` + the `run` switch), `src/codegen/gen_client.zig` (the `--lang` argv branch ~L838 + the `mainWithCollections` switch ~L892, extend the error string to list `kotlin`), `build.zig` (step `gen-dating-kotlin-client`, mirroring :288-298; out = the golden path), `src/root.zig` (add `kotlin_type`/`emit_kotlin`/`gen_kotlin` to the `codegen` struct AND the test block)

**Interfaces (Produces):**
- `kotlin_type.zig` (mirror `python_type.zig`): `KtKind` enum + `kindOf`; `selectEnumName` (reuses `identifiers.recordName`+`pascal`); `ktBaseTypeOf`/`ktRecordTypeOf` — text/email/url/editor/date/autodate → `String`; number int → `Long`, float/fixed → `Double`; bool → `Boolean`; json → `JsonElement`; select → the enum class (multi → `List<Enum>`); relation/file → `String`/`List<String>`; nullability: a single `select` → `<Enum>?` (an unset select has no variant), a single relation defaults to `""` on read (non-null `String`), multi → `List<..>` (empty default); `fieldTypeEnum` → the `FieldType.<SCREAMING>` member name.
- `gen_kotlin.generate(alloc, cols, comptime routes, comptime custom_auth, flags, experiments, in_repo, auth_collection, client_name, api_prefix)` — same signature as `gen_python.generate`; discards routes/custom_auth/flags/experiments/in_repo/api_prefix. Emits: file header (`// GENERATED by zigbase — do not edit.` + `// schema-hash: {x:0>16}` + `// typed-core-version: {s}`), `package io.github.valthon.zigbase.codegen.dating`, **explicit** imports (`io.github.valthon.zigbase.ZigbaseClient`, `...CollectionService`, `...ZbRecord`, `...FileArg`, `...AuthResponse` when any auth collection, `io.github.valthon.zigbase.typed.*` members named explicitly OR a curated import list, `kotlinx.serialization.*`, `kotlinx.serialization.json.JsonObject`/`JsonElement`), then per this task's DATA half: per select field an `enum class <Rec><Field>(val wire: String) { DRAFT("draft"), ... ; companion object { fun fromWire(v: String?): <Rec><Field>? = entries.firstOrNull { it.wire == v } } }`; per collection a `@Serializable data class <Rec>(...)` with typed members (`@SerialName("<wire>")` when the sanitized member ≠ wire key) + `companion object { fun fromRecord(r: JsonObject): <Rec> }` using the coercers (int→`coerceLong`, fixed/float→`coerceDouble`, select→`fromWire`, relation/file→`coerceString`/`coerceStringList`, json→`r["x"]`, expand submodel `<Rec>Expand` via `expandOne`/`expandMany`); plus `<Rec>Create`/`<Rec>Update` `data class`es with `fun toMap(): Map<String, Any?>` applying `encodeInt`/`encodeFixed`/enum `.wire`/file passthrough and OMITTING null (unset) fields (auth collections: `Create` adds `email`/`password`/`passwordConfirm`; `Update` omits password). File Create fields → `FileArg?`.
- Kotlin keyword sanitization + duplicate-ident check per Global Constraints.

- [ ] **Step 1: RED** — write `gen_kotlin.zig` skeleton + a Zig snapshot test (mirror `gen_python.zig`'s `test "generate emits a valid-looking … client for a mini blog"`): a byte-exact expected fragment for one small collection's enum + record + create; register the three files in `src/root.zig`. Verify the test FAILS before implementation, then implement `kotlin_type.zig`/`emit_kotlin.zig`/`gen_kotlin.zig` until byte-exact.
- [ ] **Step 2:** Wire `Lang.kotlin` (typegen_cli + gen_client argv/switch + error strings) + the `build.zig` step; `zig build gen-dating-kotlin-client`; `spotlessApply` the golden; commit it. Verify idempotence: regenerate + `spotlessApply` → no diff.
- [ ] **Step 3: Kotlin-side golden compile+sanity test** — the golden lives in `src/test`, so `gradle build` already COMPILES it (validity guarantee). Add `codegen/dating/GoldenDataTest.kt`: construct one record via `Profile.fromRecord(<canned JsonObject>)`, assert member types (`age` is `Long`, `price` is `Double`, `gender` is the enum), `toMap` round-trip for a `Create` with fixed-scale rendering (`SubscriptionCreate(price = 9.99).toMap()["price"] == "9.99"`).
- [ ] **Step 4: All gates + `zig build test --summary all` PASS.**
- [ ] **Step 5: Commit** (`feat(typegen): kotlin emitter — records, enums, payload models`)

---

### Task 6: Zig emitter — fields builders, meta, services, realtime, client factory (behavior half)

**Files:**
- Modify: `src/codegen/emit_kotlin.zig`, `src/codegen/gen_kotlin.zig`, the committed golden (regenerated), `clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/codegen/dating/GoldenBehaviorTest.kt` (new)

Generated additions (mirror `emit_python.zig` T6, minus the async fork):
- `class <Rec>Fields(prefix: String = "")` with per-field `val` properties returning the right FieldExpr subclass at path `"$prefix<name>"`; relations → `RelFieldExpr("<path>") { <Target>Fields(it) }`; selects → `EnumFieldExpr("<path>") { it.wire }`; the fixed `id`/`created`/`updated` trailer; auth collections add `email`/`username`/`verified`. File/json fields have no fluent accessor (skipped), matching `emit_python`'s `fluentExpr` nulls.
- `val <col>Meta = CollectionMeta(name = "...", fields = mapOf(...), fileFields = listOf(...), expandable = listOf(...), isAuth = ..., searchable = ..., tenant = ...)`.
- `class <Rec>sService(client: ZigbaseClient)` wrapping `TypedCollection<<Rec>>`: `suspend` query methods accepting `where: (<Rec>Fields) -> Expr` (compiled via `where(<Rec>Fields()).compile()`); `create(data: <Rec>Create)` → `c.create(data.toMap())`; `update(id, data: <Rec>Update)`; `iterate(...)` returns `Flow<<Rec>>`; a `filter(fn)` helper; auth collections graft `suspend fun authWithPassword(identity, password): AuthResponse` (delegating to `c.collection.authWithPassword`); typed `fileUrl(record, field: <Rec>FileField, ...)` with a per-collection `enum class <Rec>FileField(val wire: String)` for single-value file fields only (mirror `emitFileFieldEnum`/`emitFileUrlMethod`; the `.get`-vs-bracket eager-KeyError concern is Python-specific — Kotlin `JsonObject[key]` returns `null`, so build the filename via `when (field)` over the typed record's members).
- `class <Rec>sRealtime(client: ZigbaseClient) : TypedRealtime<<Rec>>(client, <col>Meta, <Rec>::fromRecord)`.
- Client factory: `class ZbClient(val raw: ZigbaseClient, val owned: Boolean = false) : AutoCloseable` lazily exposing `val <col> = <Rec>sService(raw)` and `val <col>Realtime = <Rec>sRealtime(raw)` per collection, `val authStore`, a `suspend fun send(...)`, `override fun close()` (closes `raw` iff `owned`); `fun createClient(url: String, ...): ZbClient` defaulting `authCollection` to the auth collection's name. ONE facade (no `AsyncZbClient`).

- [ ] **Step 1: RED** — extend the Zig snapshot test with byte-exact fragments for one collection's `Fields` builder (covers every FieldExpr subclass), the `<col>Meta`, the service head (constructor + `getList` with the `where`-lambda-compiles pattern), the realtime subclass, and the `ZbClient`/`createClient` factory. Implement until byte-exact.
- [ ] **Step 2:** Regenerate the golden + `spotlessApply`; verify byte-idempotent.
- [ ] **Step 3: Kotlin golden behavior tests** (`GoldenBehaviorTest.kt`, ktor `MockEngine`): typed `getList` maps to `Profile` instances; a `where` lambda compiles into the sent `filter` query param (assert the request URL); `create` sends `toMap()` output; a nested rel filter compiles a dotted path; the auth graft (`profiles.authWithPassword`) hits the auth endpoint. (The golden already compiles via `gradle build`, so these test runtime behavior, not just importability.)
- [ ] **Step 4: All gates + `zig build test` PASS.**
- [ ] **Step 5: Commit** (`feat(typegen): kotlin emitter — fields, services, client factory`)

---

### Task 7: CI wiring — golden freshness/idempotency gate

**Files:**
- Modify: `.github/workflows/ci.yml` — add a **"Dating Kotlin client snapshot is fresh"** step in the `build` job, after the Python one (:99-104): `mise exec zig@0.16.0 -- zig build gen-dating-kotlin-client` → `mise exec gradle@9.6 -- gradle -p clients/kotlin spotlessApply` → `git diff --exit-code clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/codegen/dating/ZbaseGen.kt`. (The `kotlin-sdk` job already exports `ZIGBASE_TEST_DATING_BINARY` at :540 and runs `spotlessCheck build` + `integrationTest` — no change needed there; the T8 typed e2e rides the existing `integrationTest` step.)

**Decided (gate placement):** host the freshness gate in the **`build` job** alongside the Dart/Python golden gates (consistency; the zig toolchain + generator are already compiled there, and `mise exec gradle` provides Spotless). The one cost is warming a Gradle daemon in a job that otherwise skips it — if `build`-job time becomes a concern, the alternative is to move this single step into the `kotlin-sdk` job (Gradle already warm there) and run `zig build gen-dating-kotlin-client` via its mise-provided zig; note this in the PR so the owner can choose.

- [ ] **Step 1:** Write the workflow change; confirm the gate commands run locally end-to-end (regenerate → `spotlessApply` → clean scoped diff). YAML sanity check.
- [ ] **Step 2:** Gates + unit suite green.
- [ ] **Step 3: Commit** (`ci(kotlin-sdk): golden freshness gate for the typed client`)

---

### Task 8: Typed e2e against dating-server

**Files:**
- Create: `clients/kotlin/src/integrationTest/kotlin/io/github/valthon/zigbase/integration/TypedDatingLiveTest.kt` (reuse `Harness.kt`'s free-port/health-poll; guard with `assumeTrue(System.getenv("ZIGBASE_TEST_DATING_BINARY") != null)` so a plain `integrationTest` run without the binary stays green, mirroring the Dart/Python guards)

Coverage (mirror `clients/dart/test/integration/typed_dating_test.dart` + `test_typed_dating_live.py`), with **discriminating assertions + negative controls** (sabotage each assertion mentally: it must fail if the SDK were wrong):
- Auth: `ZbClient.profiles.authWithPassword(...)` (typed graft) → a real token stored.
- Typed CRUD: create a `Profile`/`Photo`/`Subscription` via the typed `Create` model, read it back as the typed record, `update`, `delete`.
- Nested-relation fluent filter: `photos.getList { it.owner.rel { o -> o.name like "%Ann%" } }` returns only matching photos (negative control: a non-matching name returns none).
- Expand single + multi: `PhotoExpand.owner` (single) and `PhotoExpand.tags` (multi) populated after an `expand`.
- Cursor paging via `getPage` (round-trip a `nextCursor`).
- Int coercion: `profile.age is Long` and equals the created value (negative control: a fractional wire value would raise — covered by unit tests, not exercised here).
- Fixed(2) round-trip: `SubscriptionCreate(price = 9.99)` → wire `"9.99"` → `subscription.price == 9.99`.
- Typed realtime: subscribe via `ProfilesRealtime.stream()`, create a profile, receive a typed `create` event whose `record` is a converted `Profile`.
- File URLs: public `avatar` fetchable bare; a `privatePhotos` image 403 bare / 200 with a files token (`files.getToken()`).

Build the dating-server first: `mise exec zig@0.16.0 -- zig build dating-server`. Run the file twice for flakes; run the whole `integrationTest` suite once (the existing KSP1/KSP2 live tests must stay green). Fix any SDK/emitter bug found with its own commit + a unit/golden regression test.

- [ ] **Step 1:** Harness + smoke (typed `getList` against live).
- [ ] **Step 2:** Coverage tests; run 2×; fix bugs (own commits + regression tests).
- [ ] **Step 3:** Gates + full unit suite.
- [ ] **Step 4: Commit** (`test(kotlin-sdk): typed tier e2e against dating fixture`)

---

### Task 9: Docs + changelog

**Files:**
- Modify:
  - `docs/kotlin-sdk.md` — **flip the intro** (the line at ~L14 currently reads "A generated typed tier is **not** in this release — see that section"): now it IS. Add a **Typed tier** section modeled on `docs/python-sdk.md` / `docs/dart-sdk.md` §typed-tier: generation command (`zigbase typegen --lang kotlin --out …`), the generated surface (`@Serializable` records + `fromRecord`, `Create`/`Update` + `toMap`, `<Rec>Fields` fluent filters + injection safety, `TypedCollection`, `<Rec>sRealtime` Flow, `ZbClient`/`createClient`), coercion semantics (int→`Long` decimal-string, fixed `HALF_UP`), the free kotlinx-serialization angle (the Kotlin analog of Pydantic's JSON-schema selling point), the no-sync-fork / Flow-realtime shape, and the **RPC-not-emitted** note. Grep `docs/framework.md`/`docs/api.md` for `--lang dart|python` lists and add `kotlin` where they enumerate languages.
  - `clients/kotlin/README.md` — a typed quickstart (generate, `createClient`, a `where` lambda sample).
  - `clients/kotlin/CHANGELOG.md` — an `[Unreleased]` typed-tier entry (client-independent versioning convention).
  - **Site mirror:** `site/src/content/docs/kotlin-sdk.md` is GENERATED from `docs/kotlin-sdk.md` by `gen-docs-mirror.mjs` — do NOT hand-edit; build the site (`cd site && npm run build`) to regenerate and confirm the new section renders.
- Create: `changelog.d/kotlin-sdk-typed.md`:
```markdown
### Features

- Kotlin SDK typed tier: `zigbase typegen --lang kotlin` generates `@Serializable` record data classes with `fromRecord` coercion, `Create`/`Update` payloads with `toMap` wire encoding, injection-safe fluent filter builders, and typed collection services (plus Flow-based typed realtime) over the new `io.github.valthon.zigbase.typed` runtime — golden-gated in CI against the dating fixture.
```

- [ ] **Step 1:** Write all docs; snippet-audit every sample against the generated golden + the runtime; `cd site && npm run build` green with the new section.
- [ ] **Step 2:** Grep check for stale `--lang ts|dart|python`-only lists; Kotlin gates + unit suite; `zig build test`.
- [ ] **Step 3: Commit** (`docs(kotlin-sdk): typed tier docs, changelog fragment`)

---

## Decided divergences (recommendations baked in — do not re-open without owner sign-off)

1. **RPC / typed custom-auth emission — OUT OF SCOPE** (TS-only across all SDKs; the dating fixture's `winks`/`messages` routes + `device_link` custom auth are ignored by `gen_kotlin`, exactly as by `gen_dart`/`gen_python`).
2. **No sync/async fork.** Kotlin ships ONE coroutine-first surface (`suspend` + `Flow`), matching the base KSP1/KSP2 SDK and Dart's single-async tier. No `Async*` classes; this halves the emitter's service/client surface vs Python.
3. **Select → `enum class`, not sealed class.** Plain `enum class <Rec><Field>(val wire: String)` + a `fromWire` companion — select values are a closed set; matches Dart/Python; simplest and interops with kotlinx (`@SerialName` not needed on enum *entries* since we serialize via `.wire`, not the entry name).
4. **Filter DSL uses `infix` methods + `infix and`/`or`, not operator overloading.** Kotlin cannot overload `==`/`&`/`|` to return `Expr`, so `f.age gt 18` / `(a) and (b)`. A side benefit: no `__bool__` ambiguity footgun exists in Kotlin, so the Python port's `Expr.__bool__`-raises guard is dropped.
5. **Reserved words → trailing-`_` sanitization + `@SerialName`**, not backtick-escaping — cross-SDK consistency with `emit_python`/`emit_dart` and cleaner source; wire key unchanged; `@SerialName("<wire>")` keeps kotlinx serialization wire-faithful.
6. **int-mode → `Long`** (i64 precision; int/fixed cross as decimal strings), fixed/float → `Double`. `NumberFieldExpr` operands are typed `Number` (not tightly `Long`-vs-`Double`) so `filterValue`'s per-type rendering applies; a minor looseness vs the record field type, flagged but accepted (matches Python's single `NumFieldExpr[float]`).
7. **No `requestKey`/dedup, no SSE** — carries the KSP1/KSP2 documented divergence (lean, consistent with the newest SDKs).
8. **Golden formatter = Spotless/ktlint via `spotlessApply`** (the `dart format`/`ruff format` analog); golden lives in the **test source set** so `gradle build` compiles it and `spotlessCheck` lints it — a stronger guarantee than Python's import-only test. Emit **explicit imports** (no wildcard) to satisfy the non-autofixable `no-wildcard-imports` rule; if any other non-autofixable ktlint rule trips the committed golden, add a targeted `@file:Suppress("ktlint:standard:<rule>")` header rather than hand-formatting (the Kotlin analog of Python's `# ruff: noqa`).

## Golden + idempotency CI mechanics (concrete)

- **Stored:** one committed file `clients/kotlin/src/test/kotlin/io/github/valthon/zigbase/codegen/dating/ZbaseGen.kt`, Spotless-clean, in package `io.github.valthon.zigbase.codegen.dating`.
- **Generated by:** `build.zig` step `gen-dating-kotlin-client` — `b.addRunArtifact(gen_exe)` with `ZBASE_INREPO=1` and args `--out <golden> --api-prefix /api --lang kotlin` (clone of :291-298).
- **Compared/idempotency-gated by:** the `build`-job step `zig build gen-dating-kotlin-client` → `gradle -p clients/kotlin spotlessApply` → `git diff --exit-code <golden>` (format-then-diff, so a pure formatter-style delta can never fail it; the scoped path keeps `spotlessApply`'s whole-tree reformat from affecting the check).
- **Regenerated (dev loop):** `zig build gen-dating-kotlin-client && gradle -p clients/kotlin spotlessApply` then commit.
- **Additionally validated by:** `gradle -p clients/kotlin spotlessCheck build` (the `kotlin-sdk` job) COMPILES the golden as a test source and LINTS it — catching any generated symbol that doesn't resolve or any lint regression, beyond the freshness diff.

## Self-review notes (applied)

- **Spec coverage:** the KSP3 spec section (`docs/superpowers/specs/2026-07-10-kotlin-sdk-design.md` §Program-shape-3) = "fourth emitter trio (mirroring gen_dart/gen_python) generating kotlinx-serializable data classes with fromRecord coercion, Create/Update payloads with toMap, fields builders over a hand-written typed runtime (meta, Dart-parity coercers incl. int-raises-on-fractional and ROUND_HALF_UP, Expr/FieldExpr DSL, TypedCollection, Flow-based typed realtime), golden-gated in CI (formatter-delegated, regeneration-idempotent), dating-fixture e2e; RPC out of scope" → T5-T6 (emitter+golden), T1-T4 (runtime), T3 (TypedCollection), T4 (Flow realtime), T7 (gate), T8 (e2e), T9 (docs). The parity contract's hardenings (one escaping chokepoint, byte-parity number/date, loud rejection, discriminating e2e + negative controls) map to T2's `filterValue` routing, the reused `Query.kt`, T1's coercers, and T8's controls.
- **Type consistency:** `FieldMeta`/`CollectionMeta` (T1) consumed by T3/T4 and emitted `<col>Meta` (T6); `Expr`/`FieldExpr` (T2) consumed by T4 (`where=`) and T6 (generated `<Rec>Fields`); `TypedCollection`/`TypedRealtime` (T3/T4) wrapped by T6 services; `TYPED_CORE_VERSION` defined T1, stamped T5.
- **Deliberate scope-outs recorded:** RPC + typed custom-auth (TS-only), sync fork (Kotlin has none), `requestKey`/SSE (KSP divergence), fixture multi-select/multi-file additions (unit-tested directly instead).
