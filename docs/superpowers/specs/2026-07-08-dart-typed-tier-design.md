# Dart typed / codegen tier — design spec

*Stream 3a — make ZigBase's client generator emit Dart alongside TypeScript.*
Date: 2026-07-08. Status: design (spec-first, then implement to a coherent milestone).

## 1. Goal & shape

ZigBase already ships:

- a **TypeScript typed tier**: a hand-written generic core (`clients/typescript/src/typed/`)
  that a generated `zbase.gen.ts` instantiates, produced by a pure-Zig generator
  (`src/codegen/*` → `gen_client.generate`, exposed as `zig build gen-client` and the
  `typegen` subcommand);
- a **Dart base SDK** (`clients/dart/lib/`): dynamic `ZbRecord` + `CollectionService`
  (CRUD, cursor + offset pagination, auth), `RealtimeService`, `FilesService`,
  `ZigbaseClient` — the runtime a typed tier wraps. No generator emits typed Dart.

This stream closes that gap: the generator gains a **Dart output language**, emitting a
`zbase.gen.dart` that instantiates a new **Dart typed runtime** (`clients/dart/lib/typed.dart`)
into concrete, schema-aware record classes and a typed service per collection.

### Why not a straight TS port

Dart lacks the three TS features the typed core leans on:

1. **Structural typing + `as unknown as`** — the TS generator emits loose runtime factories
   (`makeRecordService`) and casts them to narrow per-collection interfaces. Dart has nominal
   typing; there is no cast from a loose object to a concrete interface. → **Generate concrete
   classes** that *compose* the runtime generic (`TypedCollection<T>`), not cast it.
2. **`Proxy`** (the fluent `filter(f => f.title.eq(...))` builder). → **Generate a concrete
   `XFields` class** with one typed getter per field.
3. **Mapped/conditional types** (`WithExpand<Rec, Rel, K>` narrows the return by the expand keys
   passed at the call site). → **Bake expand onto the record**: every generated record carries a
   typed, nullable `expand` accessor. Expansion is populated when requested and `null`/empty
   otherwise; Dart cannot express "this call requested `author`, so `.expand.author` is non-null",
   and pretending it can is worse than an honest nullable.

The design principle mirrors TS: **the runtime holds the machinery; the generated file is thin
and declarative.**

## 2. Generator architecture (Zig side)

The acquisition layer (`acquire*.zig`) already converges every schema source (comptime literal,
data-dir/Postgres, HTTP) onto `[]const schema.Collection`. It is language-neutral and reused
as-is. Guards, `identifiers.pascal`/`recordName`, and `schemaHash` are reused. Only the **emit
layer** branches by language.

New files (all under `src/codegen/`, all pure `[]schema.Collection` → string-buffer, no libc):

| File | Parallels | Emits |
| --- | --- | --- |
| `dart_type.zig` | `ts_type.zig` | `DartKind`, `dartBaseTypeOf`, `dartTypeOf`, `selectEnumName`. Field → Dart type. |
| `emit_dart.zig` | `emit.zig` | Per-collection Dart fragments: enums, record class, `Create`/`Update`, `Fields` builder, `Meta` const, service class, client factory, realtime alias, files. |
| `gen_dart.zig` | `gen_client.zig`'s `generate` | `pub fn generate(...)` — same signature as `gen_client.generate`; orchestrates the whole `.dart` file. |

**Language dimension threaded through the existing plumbing** (a `Lang = enum { ts, dart }`,
default `ts`, in `src/codegen`):

- `cli.zig` `TypegenArgs` gains `lang: []const u8 = "ts"`, parsed from `--lang ts|dart`.
- `typegen_cli.Options` gains `lang: Lang`; `run()` dispatches to `gen_client.generate` (ts)
  or `gen_dart.generate` (dart). `checkOrWrite` is language-neutral (byte compare) — reused.
- `gen_client.parseArgsSlice` / `mainWithCollections` (the `zig build gen-client` exe path)
  gain `--lang`; branch to `gen_dart.generate`.
- `build.zig` `GenOpts` gains `lang: []const u8 = "ts"`; `genClientStep` forwards `--lang`.
- `framework.zig` typegen dispatch passes `ta.lang` through.

**Type mapping** (`dart_type.zig`, mirroring `ts_type.zig`'s `kindOf`):

| Field | Dart record type | Notes |
| --- | --- | --- |
| text/email/url/editor | `String` | |
| date/autodate | `String` | ISO-8601 string (matches TS; no `DateTime` parse to stay wire-faithful) |
| bool | `bool` | |
| number `float` | `double` | |
| number `int` | `int` | wire = decimal string; parsed by `fromRecord` |
| number `fixed` scale N | `double` | wire = decimal string; `toStringAsFixed(N)` on write, `double.parse` on read. `double` == TS `number` precision, so no new dep and identical behavior. |
| json | `dynamic` | (`Object?`) |
| select maxSelect 1 | generated `enum` | e.g. `PostStatus { draft, published }` + wire mapping |
| select maxSelect >1 | `List<PostStatus>` | |
| relation maxSelect 1 | `String` | related id |
| relation maxSelect >1 | `List<String>` | related ids |
| file maxSelect 1 | `String` | filename |
| file maxSelect >1 | `List<String>` | filenames |

Multi-value ⇒ `List<Base>`. Non-nullable in the record for required scalars; select/relation
single fields that can be empty are typed nullable where the wire may omit them — to match TS
(which types everything present), the record types scalars as non-null with sensible empty
defaults in `fromRecord` (`''`, `0`, `false`, `[]`) and single-select as **nullable** enum
(an unset select has no valid variant).

## 3. The generated `.dart` file (golden layout)

For the blog schema (`users` auth, `posts`, `tags`), in emission order:

```dart
// GENERATED by zigbase — do not edit. schema-hash: <hex>
// ignore_for_file: non_constant_identifier_names, constant_identifier_names, unused_element, unused_import
import 'package:zigbase_client/zigbase_client.dart';
import 'package:zigbase_client/typed.dart';

// (a) select enums, with wire<->enum mapping
enum PostStatus {
  draft('draft'), published('published');
  const PostStatus(this.wire);
  final String wire;
  static PostStatus? fromWire(Object? v) => ...;
}

// (b) record classes — plain data + typed expand accessor
class User {
  final String id, email; final bool verified; final String name, created, updated;
  User.fromRecord(ZbRecord r) : ...;
  factory User.fromJson(Map<String, dynamic> j) => User.fromRecord(ZbRecord(j));
}
class Post {
  final String id, title;
  final PostStatus? status;
  final double price;          // fixed(2): parsed from decimal string
  final String author;         // relation id
  final List<String> tags;     // relation ids
  final String cover;          // filename
  final String created, updated;
  final PostExpand expand;     // typed, nullable members
  Post.fromRecord(ZbRecord r) : ...;
}
class PostExpand {              // one per collection-with-relations
  final User? author;
  final List<Tag> tags;
  const PostExpand({this.author, this.tags = const []});
  factory PostExpand.fromRecord(ZbRecord r) => ...; // reads r['expand']
}

// (c) create / update payloads
class PostCreate {
  final String title;                    // required
  final PostStatus? status; final double? price; final String? author;
  final List<String>? tags; final MultipartFile? cover;   // file → MultipartFile
  const PostCreate({required this.title, this.status, ...});
  Map<String, dynamic> toMap() => { 'title': title, if (price != null) 'price': price!.toStringAsFixed(2), ... };
}
class PostUpdate { /* all-nullable; same toMap() with presence guards */ }

// (d) fluent fields builder — concrete, no Proxy
class PostFields {
  PostFields([this._p = '']); final String _p;
  StringFieldExpr get title => StringFieldExpr('${_p}title');
  EnumFieldExpr<PostStatus> get status => EnumFieldExpr('${_p}status', (e) => e.wire);
  NumFieldExpr get price => NumFieldExpr('${_p}price');
  RelFieldExpr<UserFields> get author => RelFieldExpr('${_p}author', (p) => UserFields(p));
  StringFieldExpr get id => ...; created; updated;
}

// (e) per-collection metadata (drives the runtime service)
const CollectionMeta postsMeta = CollectionMeta(
  name: 'posts',
  fields: { 'title': FieldMeta(type: FieldType.text), 'price': FieldMeta(type: FieldType.number, mode: NumberMode.fixed, scale: 2), ... },
  fileFields: ['cover'], expandable: ['author', 'tags'], isAuth: false,
);

// (f) typed service — composes TypedCollection<Post>
class PostsService {
  PostsService(ZigbaseClient c) : _c = TypedCollection<Post>(c, postsMeta, Post.fromRecord);
  final TypedCollection<Post> _c;
  Future<TypedList<Post>> getList({Expr Function(PostFields)? where, Object? sort, List<String>? expand, int page = 1, int perPage = 30, ...}) =>
      _c.getList(filter: where == null ? null : where(PostFields()).compile(), sort: _sort(sort), expand: expand, page: page, perPage: perPage);
  Future<Post> getOne(String id, {List<String>? expand, ...});
  Future<TypedCursorPage<Post>> getPage({...});
  Stream<Post> iterate({...});  Future<List<Post>> getFullList({...});
  Future<Post> create(PostCreate data, {List<String>? expand});
  Future<Post> update(String id, PostUpdate data, {List<String>? expand});
  Future<void> delete(String id);
  Future<TypedList<Post>> getFirstListItem? ... ;
  String filter(Expr Function(PostFields) fn) => fn(PostFields()).compile();
  String fileUrl(Post r, {required String field, ...});   // single-file collections only
}
class UsersService {                 // auth collection → extra auth method
  ... Future<AuthResponse> authWithPassword(String identity, String password);
}

// (g) realtime alias
class PostsRealtime extends TypedRealtime<Post> {
  PostsRealtime(ZigbaseClient c) : super(c, postsMeta, Post.fromRecord);
}

// (h) client factory
class BlogClient {
  BlogClient(this.raw, {this.owned = false});
  final ZigbaseClient raw; final bool owned;
  late final PostsService posts = PostsService(raw);
  late final UsersService users = UsersService(raw);
  late final TagsService tags = TagsService(raw);
  late final PostsRealtime postsRealtime = PostsRealtime(raw);
  Future<void> close() => owned ? raw.close() : Future.value();
}
BlogClient createClient(String url, { AuthStore? authStore, String authCollection = 'users', ... }) =>
    BlogClient(ZigbaseClient(url, authStore: authStore, authCollection: authCollection, ...), owned: true);
```

Nested `db.` grouping (TS `zb.db.posts`) is flattened to `client.posts` in Dart — Dart has no
free anonymous-object grouping and top-level accessors are more idiomatic. Realtime is
`client.postsRealtime` (only for collections with a `viewRule`-eligible surface, i.e. all).

## 4. The Dart typed runtime — `clients/dart/lib/typed.dart`

A new public library (exported as `package:zigbase_client/typed.dart`, a second entrypoint
alongside the barrel `zigbase_client.dart`). It contains everything schema-independent so the
generated file stays thin. Sections mirror the TS `typed/` modules:

### 4.1 Metadata (`meta` — mirrors `meta.ts`)

```dart
enum FieldType { text, editor, email, url, number, boolean, date, autodate, select, relation, file, json }
enum NumberMode { float, intMode, fixed }
class FieldMeta { final FieldType type; final bool multi; final NumberMode mode; final int? scale; const FieldMeta({...}); }
class CollectionMeta {
  final String name; final Map<String, FieldMeta> fields;
  final List<String> fileFields, expandable; final bool isAuth;
  final List<String>? searchable; final String? tenant;
  const CollectionMeta({...});
}
```

### 4.2 Filter compiler (`where`/`fluent` — mirrors `where.ts`, `fluent.ts`, `operators.ts`)

Reuse the **existing** `filterValue` in `clients/dart/lib/src/query.dart` for injection-safe
operand serialization (it already matches the server lexer's escape set). Add the fluent
expression tree:

```dart
class Expr {
  const Expr(this._src); final String _src;
  Expr and(Expr o) => Expr('(${_src} && ${o._src})');
  Expr or(Expr o)  => Expr('(${_src} || ${o._src})');
  String compile() => _src;
}
const _opMap = { 'eq': '=', 'neq': '!=', 'gt': '>', 'gte': '>=', 'lt': '<', 'lte': '<=', 'like': '~', 'nlike': '!~' };

class FieldExpr<T> {
  FieldExpr(this.path); final String path;
  Expr eq(T v)  => Expr('$path = ${filterValue(v)}');
  Expr neq(T v) => Expr('$path != ${filterValue(v)}');
  Expr inList(List<T> vs) => Expr('$path in (${vs.map(filterValue).join(', ')})');  // native `in ()`, ZigBase >= 0.9.0
}
class ComparableFieldExpr<T> extends FieldExpr<T> { gt/gte/lt/lte ... }
class StringFieldExpr extends ComparableFieldExpr<String> { like/nlike ... }
class NumFieldExpr extends ComparableFieldExpr<num> {}
class BoolFieldExpr extends FieldExpr<bool> {}
class EnumFieldExpr<E> extends FieldExpr<E> {   // serializes enum → wire string
  EnumFieldExpr(String path, this._wire) : super(path); final String Function(E) _wire;
  @override Expr eq(E v) => Expr('$path = ${filterValue(_wire(v))}'); // + neq/inList
}
class RelFieldExpr<F> extends FieldExpr<String> {   // relation id ops + nested where
  RelFieldExpr(String path, this._mk) : super(path); final F Function(String prefix) _mk;
  Expr rel(Expr Function(F) fn) => fn(_mk('$path.'));   // author.name ~ '...' (depth via nesting)
}
```

`inList` on empty list emits `field in ()` (server = constant-false), matching TS `compileIn`.
`filterValue` throws on non-finite / unsupported operands (already implemented) — injection-safe.

### 4.3 Typed collection service factory (`service` — mirrors `service.ts`)

```dart
class TypedList<T> { final List<T> items; final int page, perPage, totalItems, totalPages; }
class TypedCursorPage<T> { final List<T> items; final String? nextCursor, prevCursor; final bool hasNext, hasPrev; final int? totalItems; }

class TypedCollection<T> {
  TypedCollection(ZigbaseClient client, this.meta, this._fromRecord) : _svc = client.collection(meta.name);
  final CollectionService _svc; final CollectionMeta meta; final T Function(ZbRecord) _fromRecord;

  Future<TypedList<T>> getList({String? filter, String? sort, List<String>? expand, int page, int perPage, String? search, ...})
     => _svc.getList(...).then((r) => TypedList(items: r.items.map(_fromRecord).toList(), ...));
  Future<T> getOne(String id, {...}) => _svc.getOne(...).then(_fromRecord);
  Future<TypedCursorPage<T>> getPage({...});
  Stream<T> iterate({...}) => _svc.iterate(...).map(_fromRecord);
  Future<List<T>> getFullList({...});
  Future<T> create(Map<String, dynamic> body, {...}) => _svc.create(body, ...).then(_fromRecord);
  Future<T> update(String id, Map<String, dynamic> body, {...}) => _svc.update(...).then(_fromRecord);
  Future<void> delete(String id) => _svc.delete(id);
  String fileUrl(ZbRecord r, String filename, {...}) => ...; // via client.files.getUrl
}
```

**Int/fixed coercion lives in the generated (de)serialization**, not in a runtime walk:
- **read**: `Post.fromRecord` parses int fields via a runtime helper `coerceInt(r['age'])`
  (handles both `num` from JSON and the decimal-`String` wire form) and fixed via
  `coerceDouble(r['price'])`. `typed.dart` exports `coerceInt`/`coerceDouble`/`coerceString`
  and list variants used by generated `fromRecord`.
- **write**: `PostCreate.toMap()` emits `int.toString()` for int and `value.toStringAsFixed(scale)`
  for fixed — the decimal-string wire form the server requires. Type-directed, so no runtime
  `typeof` branching (the TS approach), which is more idiomatic and precision-safe in Dart.

This matches the TS end-to-end contract exactly (§8 of the TS map): server stores int/fixed as
decimal strings for full i64 precision; the typed layer coerces both directions; top-level fields
only (expanded relation records belong to other metas).

### 4.4 Typed realtime (`realtime.ts`)

```dart
class TypedRealtimeEvent<T> { final String topic, action; final T record; }
class TypedRealtime<T> {
  TypedRealtime(ZigbaseClient c, this.meta, this._fromRecord) : _rt = c.realtime;
  Future<ZbUnsubscribe> subscribe(void Function(TypedRealtimeEvent<T>) cb, {String? filter, Expr? whereExpr}) =>
    _rt.subscribe(meta.name, (e) => cb(TypedRealtimeEvent(topic: e.topic, action: e.action, record: _fromRecord(e.record))), filter: whereExpr?.compile() ?? filter);
  Stream<TypedRealtimeEvent<T>> stream({String? filter});
}
```

### 4.5 Typed files (`files.ts`)

Generated per-collection `fileUrl(record, {required field, download, thumb, token})` reads
`record.<field>` (the stored filename) and delegates to base `FilesService.getUrl`. Single-value
file fields only, matching TS.

## 5. RPC, auth methods, feature flags (comptime-only surfaces)

These come only from the **comptime** generator path (`zig build gen-client`), which sees
`App.routes`, `App.custom_auth`, `App.flags`. Design:

- **RPC** (`rpc.zig` parallel): emit an `XRpc`-style method set or a `rpc` accessor on the client:
  `Future<HealthOut> golfsimHealth()`, `Future<Object?> bookingsConfirm({required String id})`.
  Path params → named args; GET/DELETE non-param fields → query; POST/PUT/PATCH → body. Output
  Zig structs → generated Dart DTO classes (`dart_type` mirrors `rpc_ts.zig`'s comptime
  Zig-type→string). `std.json.Value` → `Object?`. Untyped/`void` handled as TS.
- **Auth methods** (`emitAuthMethod*` parallel): `client.<coll>Auth.<method>.initiate/complete`
  with typed I/O for built-ins + declared customs.
- **Feature flags**: `client.flags.resolveAll(subject)` → typed `FeatureState`.

**Scope call (honest):** the **core collection/record/where/expand/realtime/files typed tier +
int-fixed coercion** is the milestone this stream commits to landing green (runtime + generator +
golden test + live e2e + CI). RPC is implemented next if the core lands with budget; auth-method
and flags typed surfaces are designed here and deferred to a follow-up. The runtime-introspection
(`typegen --data-dir/--url`) Dart path reuses the same `gen_dart.generate` and so gets the core
tier for free (no routes/flags at runtime, exactly like TS).

## 6. Testing & CI

- **Zig unit tests**: `dart_type.zig` and `emit_dart.zig` carry `test {}` blocks (added to
  `root.zig`'s import block so they run). A **golden byte-exact test** (`gen-dart-test`, wired
  into `test_step` like `gen-test`) regenerates the dating Dart client and diffs it against the
  committed snapshot `clients/dart/test/codegen/dating/zbase.gen.dart`.
- **Dart unit tests** (`clients/dart/test/typed_*.dart`, `package:test`, MockClient pattern):
  the where/fluent compiler (operators, nesting, `in`, escaping), int/fixed coercion round-trip,
  `TypedCollection` list/get/create mapping, enum wire mapping.
- **Dart e2e** (`clients/dart/test/integration/typed_dating_test.dart`, tagged `integration`):
  mirrors `clients/typescript/test/integration/dating.integration.test.ts` — spawn the
  `dating-server` binary (env `ZIGBASE_TEST_DATING_BINARY`, else build), CRUD + nested-relation
  filter + expand single/multi + native cursor + realtime + files(public + private token). A
  no-op skip when the binary env is unset (keeps plain `dart test` green), matching the existing
  Dart integration harness.
- **CI**: the `dart-sdk` job gains (a) a `ZIGBASE_TEST_DATING_BINARY` export (download the
  prebuilt `dating-server` like the `ts-sdk` job) and (b) the typed integration run. The `build`
  job gains a `zig build gen-dating-dart-client-check` staleness gate beside the TS ones.

## 7. Conventions

- House API: list endpoints already return `{items}` via the base SDK; typed wrappers expose
  `items`. Cursor vocabulary (`cursor`/`limit`, `nextCursor`/`hasNext`) preserved. Side-effect
  success `204` handled by base `delete`. Config planes untouched (generator is build-time).
- Consumer-visible generator change → repo-root `changelog.d/<slug>.md` `### Features`.
- Dart runtime additions → `clients/dart/CHANGELOG.md` 0.1.0 `### Added`.
- Docs: new "Typed tier" section in `docs/dart-sdk.md` + `site/` mirror, mirroring the TS doc's
  `## Typed client` structure. `docs/typescript-sdk.md` touched only if shared generator behavior
  (the `--lang` flag) is documented there.
