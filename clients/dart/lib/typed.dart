/// The generic **typed tier** runtime for the ZigBase Dart client.
///
/// A generated `zbase.gen.dart` (produced by `zigbase typegen --lang dart` or
/// `zig build gen-client` with a Dart output) instantiates the building blocks
/// in this library into concrete, schema-aware record classes and one typed
/// service per collection. Everything schema-independent lives here so the
/// generated file stays thin and declarative — the same split the TypeScript
/// tier uses between `@zigbase/client/typed` and a generated `zbase.gen.ts`.
///
/// This library is a second public entrypoint alongside the base barrel
/// `package:zigbase_client/zigbase_client.dart`; import both from generated
/// code. It re-uses the base SDK's injection-safe [filterValue] for operand
/// serialization, so typed filters produce the exact wire bytes the server's
/// filter lexer expects.
library;

import 'zigbase_client.dart';

// ---------------------------------------------------------------------------
// Metadata — mirrors clients/typescript/src/typed/meta.ts
// ---------------------------------------------------------------------------

/// The ZigBase field-type universe (mirrors the server's field table).
enum FieldType {
  text,
  editor,
  email,
  url,
  number,
  boolean,
  date,
  autodate,
  select,
  relation,
  file,
  json,
}

/// Numeric storage mode. `float` fields are plain doubles on the wire; `int`
/// and `fixed` fields are transmitted as **decimal strings** (the server scales
/// them to integers for full i64 precision) and are coerced both directions by
/// generated (de)serialization.
enum NumberMode { float, integer, fixed }

/// Per-field runtime descriptor. `mode`/`scale` carry the int-vs-fixed numeric
/// distinction that drives decimal-string coercion (float fields use
/// [NumberMode.float] and are never coerced).
class FieldMeta {
  final FieldType type;
  final bool multi;
  final NumberMode mode;
  final int? scale;

  const FieldMeta({
    required this.type,
    this.multi = false,
    this.mode = NumberMode.float,
    this.scale,
  });
}

/// Per-collection runtime descriptor consumed by [TypedCollection] and
/// [TypedRealtime]. `name` doubles as the realtime topic and the
/// `client.collection(name)` key.
class CollectionMeta {
  final String name;
  final Map<String, FieldMeta> fields;
  final List<String> fileFields;
  final List<String> expandable;
  final bool isAuth;

  /// Field names with full-text search enabled (server >= 0.9.0); null = none.
  final List<String>? searchable;

  /// Tenant-owning field name; the server stamps it on create. null = not
  /// tenant-owned.
  final String? tenant;

  const CollectionMeta({
    required this.name,
    required this.fields,
    this.fileFields = const [],
    this.expandable = const [],
    this.isAuth = false,
    this.searchable,
    this.tenant,
  });

  /// Safe field lookup by name.
  FieldMeta? field(String name) => fields[name];
}

// ---------------------------------------------------------------------------
// int/fixed coercion helpers — used by generated `fromRecord` constructors
// ---------------------------------------------------------------------------

/// Coerce a wire value (a JSON number, or the decimal-string form used for
/// int/fixed fields) to an [int]. Returns `fallback` for null/empty/unparseable.
int coerceInt(Object? v, [int fallback = 0]) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) {
    if (v.isEmpty) return fallback;
    final n = num.tryParse(v);
    if (n != null) return n.toInt();
  }
  return fallback;
}

/// Coerce a wire value to a [double] (int/fixed fields arrive as decimal
/// strings). Returns `fallback` for null/empty/unparseable.
double coerceDouble(Object? v, [double fallback = 0]) {
  if (v is num) return v.toDouble();
  if (v is String) {
    if (v.isEmpty) return fallback;
    final n = double.tryParse(v);
    if (n != null) return n;
  }
  return fallback;
}

/// Coerce a wire value to a non-null [String] (falls back to '').
String coerceString(Object? v, [String fallback = '']) =>
    v is String ? v : fallback;

/// Coerce a wire value to a [bool] (falls back to false).
bool coerceBool(Object? v, [bool fallback = false]) => v is bool ? v : fallback;

/// Coerce a wire array to `List<String>` (relation-id / file-name multi fields).
List<String> coerceStringList(Object? v) {
  if (v is List) return v.map((e) => e is String ? e : '$e').toList();
  if (v is String && v.isNotEmpty) return [v];
  return const [];
}

/// Coerce a wire array to `List<int>` (multi-value int fields; decimal strings).
List<int> coerceIntList(Object? v) {
  if (v is List) return v.map((e) => coerceInt(e)).toList();
  return const [];
}

/// Coerce a wire array to `List<double>` (multi-value fixed/float fields).
List<double> coerceDoubleList(Object? v) {
  if (v is List) return v.map((e) => coerceDouble(e)).toList();
  return const [];
}

/// Serialize an [int] field to its decimal-string wire form.
String? encodeInt(int? v) => v?.toString();

/// Serialize a fixed-point field to its scaled decimal-string wire form.
String? encodeFixed(double? v, int scale) => v?.toStringAsFixed(scale);

/// Read a single expanded relation from `record.expand[key]` and map it through
/// the target collection's `fromRecord`. Returns null when the relation was not
/// expanded. Used by generated `<Rec>Expand` classes.
T? expandOne<T>(ZbRecord r, String key, T Function(ZbRecord) fromRecord) {
  final ex = r['expand'];
  if (ex is Map<dynamic, dynamic>) {
    final v = ex[key];
    if (v is Map<dynamic, dynamic>) {
      return fromRecord(ZbRecord(v.cast<String, dynamic>()));
    }
  }
  return null;
}

/// Read a multi-value expanded relation from `record.expand[key]`. Returns an
/// empty list when the relation was not expanded.
List<T> expandMany<T>(ZbRecord r, String key, T Function(ZbRecord) fromRecord) {
  final ex = r['expand'];
  if (ex is Map<dynamic, dynamic>) {
    final v = ex[key];
    if (v is List) {
      return v
          .whereType<Map<dynamic, dynamic>>()
          .map((m) => fromRecord(ZbRecord(m.cast<String, dynamic>())))
          .toList();
    }
  }
  return const [];
}

// ---------------------------------------------------------------------------
// Fluent filter builder — mirrors typed/where.ts + typed/fluent.ts
// ---------------------------------------------------------------------------

/// A compiled boolean filter expression. Combine with [and]/[or] (each
/// parenthesizes) and read the wire string via [compile].
class Expr {
  const Expr(this._src);
  final String _src;

  Expr and(Expr other) => Expr('($_src && ${other._src})');
  Expr or(Expr other) => Expr('($_src || ${other._src})');

  /// The ZigBase filter string this expression compiles to.
  String compile() => _src;

  @override
  String toString() => _src;
}

const Map<String, String> _opMap = {
  'eq': '=',
  'neq': '!=',
  'gt': '>',
  'gte': '>=',
  'lt': '<',
  'lte': '<=',
  'like': '~',
  'nlike': '!~',
};

/// Base per-field accessor: equality + membership. Operands are serialized with
/// the base SDK's injection-safe [filterValue].
class FieldExpr<T> {
  FieldExpr(this.path);

  /// The (possibly dotted, for nested relations) field path.
  final String path;

  Expr _op(String key, Object? value) =>
      Expr('$path ${_opMap[key]} ${filterValue(value)}');

  Expr eq(T value) => _op('eq', value);
  Expr neq(T value) => _op('neq', value);

  /// Native `field in (...)` (ZigBase >= 0.9.0). An empty list emits
  /// `field in ()`, which the server compiles to constant-false.
  Expr inList(List<T> values) =>
      Expr('$path in (${values.map((v) => filterValue(v)).join(', ')})');
}

/// A field that supports ordered comparisons (numbers, dates, strings).
class ComparableFieldExpr<T> extends FieldExpr<T> {
  ComparableFieldExpr(super.path);

  Expr gt(T value) => _op('gt', value);
  Expr gte(T value) => _op('gte', value);
  Expr lt(T value) => _op('lt', value);
  Expr lte(T value) => _op('lte', value);
}

/// A `text`/`email`/`url`/`editor` field: comparisons + `~`/`!~` pattern match.
class StringFieldExpr extends ComparableFieldExpr<String> {
  StringFieldExpr(super.path);

  Expr like(String value) => _op('like', value);
  Expr nlike(String value) => _op('nlike', value);
}

/// A `number` field.
class NumFieldExpr extends ComparableFieldExpr<num> {
  NumFieldExpr(super.path);
}

/// A `date`/`autodate` field — comparisons accept a [DateTime] or an ISO string.
class DateFieldExpr extends ComparableFieldExpr<Object> {
  DateFieldExpr(super.path);
}

/// A `bool` field.
class BoolFieldExpr extends FieldExpr<bool> {
  BoolFieldExpr(super.path);
}

/// A `select` field typed to its generated enum [E]. Serializes the enum to its
/// wire string via the generated [wireOf].
class EnumFieldExpr<E> extends FieldExpr<E> {
  EnumFieldExpr(super.path, this.wireOf);
  final String Function(E) wireOf;

  @override
  Expr eq(E value) => Expr('$path = ${filterValue(wireOf(value))}');
  @override
  Expr neq(E value) => Expr('$path != ${filterValue(wireOf(value))}');
  @override
  Expr inList(List<E> values) => Expr(
      '$path in (${values.map((v) => filterValue(wireOf(v))).join(', ')})');
}

/// A `relation` field: id-level ops plus one level of nested-relation filtering
/// via [rel] (e.g. `author.name ~ 'A'`). [F] is the target collection's fields
/// builder.
class RelFieldExpr<F> extends FieldExpr<String> {
  RelFieldExpr(super.path, this._makeTargetFields);
  final F Function(String prefix) _makeTargetFields;

  /// Build a filter over the related record's fields, e.g.
  /// `author.rel((u) => u.name.like('A'))` → `author.name ~ 'A'`.
  Expr rel(Expr Function(F fields) build) => build(_makeTargetFields('$path.'));
}

// ---------------------------------------------------------------------------
// Typed pagination envelopes
// ---------------------------------------------------------------------------

/// Offset-pagination page of typed records.
class TypedList<T> {
  final List<T> items;
  final int page;
  final int perPage;
  final int totalItems;
  final int totalPages;

  const TypedList({
    required this.items,
    required this.page,
    required this.perPage,
    required this.totalItems,
    required this.totalPages,
  });
}

/// Keyset (cursor) page of typed records.
class TypedCursorPage<T> {
  final List<T> items;
  final String? nextCursor;
  final String? prevCursor;
  final bool hasNext;
  final bool hasPrev;
  final int? totalItems;

  const TypedCursorPage({
    required this.items,
    required this.nextCursor,
    required this.prevCursor,
    required this.hasNext,
    required this.hasPrev,
    this.totalItems,
  });
}

// ---------------------------------------------------------------------------
// Typed collection service — mirrors typed/service.ts
// ---------------------------------------------------------------------------

/// Join a `List<String>` to a comma string (null/empty → null so the query
/// param is omitted rather than sent empty).
String? joinCsv(List<String>? parts) =>
    (parts == null || parts.isEmpty) ? null : parts.join(',');

/// Normalize a sort argument (a `String` or `List<String>`) to the base SDK's
/// comma-joined string form.
String? normalizeSort(Object? sort) {
  if (sort == null) return null;
  if (sort is String) return sort;
  if (sort is List) {
    final parts = sort.map((e) => '$e').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? null : parts.join(',');
  }
  return '$sort';
}

/// The generic typed CRUD service that a generated per-collection service
/// composes. Wraps the base [CollectionService] for `meta.name` and maps every
/// returned [ZbRecord] through the generated `fromRecord` constructor.
class TypedCollection<T> {
  TypedCollection(ZigbaseClient client, this.meta, this.fromRecord)
      : _svc = client.collection(meta.name),
        _files = client.files;

  final CollectionService _svc;
  final FilesService _files;
  final CollectionMeta meta;
  final T Function(ZbRecord) fromRecord;

  /// The underlying base [CollectionService] — escape hatch for collection
  /// methods the typed surface does not wrap (e.g. auth, abilities).
  CollectionService get collection => _svc;

  Future<TypedList<T>> getList({
    int page = 1,
    int perPage = 30,
    String? filter,
    String? sort,
    List<String>? expand,
    String? fields,
    bool skipTotal = false,
    String? search,
    String? requestKey,
  }) async {
    final r = await _svc.getList(
      page: page,
      perPage: perPage,
      filter: filter,
      sort: sort,
      expand: joinCsv(expand),
      fields: fields,
      skipTotal: skipTotal,
      search: search,
      requestKey: requestKey,
    );
    return TypedList<T>(
      items: r.items.map(fromRecord).toList(),
      page: r.page,
      perPage: r.perPage,
      totalItems: r.totalItems,
      totalPages: r.totalPages,
    );
  }

  Future<T> getOne(String id,
          {List<String>? expand, String? fields, String? requestKey}) =>
      _svc
          .getOne(id,
              expand: joinCsv(expand), fields: fields, requestKey: requestKey)
          .then(fromRecord);

  Future<T> getFirstListItem(String filter,
          {List<String>? expand, String? fields, String? requestKey}) =>
      _svc
          .getFirstListItem(filter,
              expand: joinCsv(expand), fields: fields, requestKey: requestKey)
          .then(fromRecord);

  Future<TypedCursorPage<T>> getPage({
    String? cursor,
    int limit = 30,
    String? filter,
    String? sort,
    List<String>? expand,
    String? fields,
    bool withTotal = false,
    String? search,
    String? requestKey,
  }) async {
    final p = await _svc.getPage(
      cursor: cursor,
      limit: limit,
      filter: filter,
      sort: sort,
      expand: joinCsv(expand),
      fields: fields,
      withTotal: withTotal,
      search: search,
      requestKey: requestKey,
    );
    return TypedCursorPage<T>(
      items: p.items.map(fromRecord).toList(),
      nextCursor: p.nextCursor,
      prevCursor: p.prevCursor,
      hasNext: p.hasNext,
      hasPrev: p.hasPrev,
      totalItems: p.totalItems,
    );
  }

  Stream<T> iterate({
    int batch = 100,
    String? filter,
    String? sort,
    List<String>? expand,
    String? fields,
    String? search,
  }) =>
      _svc
          .iterate(
            batch: batch,
            filter: filter,
            sort: sort,
            expand: joinCsv(expand),
            fields: fields,
            search: search,
          )
          .map(fromRecord);

  Future<List<T>> getFullList({
    int batch = 100,
    String? filter,
    String? sort,
    List<String>? expand,
    String? fields,
    String? search,
  }) async {
    final rows = await _svc.getFullList(
      batch: batch,
      filter: filter,
      sort: sort,
      expand: joinCsv(expand),
      fields: fields,
      search: search,
    );
    return rows.map(fromRecord).toList();
  }

  Future<T> create(Map<String, dynamic> body,
          {List<String>? expand, String? fields, String? requestKey}) =>
      _svc
          .create(body,
              expand: joinCsv(expand), fields: fields, requestKey: requestKey)
          .then(fromRecord);

  Future<T> update(String id, Map<String, dynamic> body,
          {List<String>? expand, String? fields, String? requestKey}) =>
      _svc
          .update(id, body,
              expand: joinCsv(expand), fields: fields, requestKey: requestKey)
          .then(fromRecord);

  Future<void> delete(String id) => _svc.delete(id);

  /// Build a file URL for a stored filename on `record`. `record` is the raw
  /// [ZbRecord] (generated services expose a typed `fileUrl(T, field:)` wrapper).
  String fileUrl(ZbRecord record, String filename,
          {bool download = false, String? thumb, String? token}) =>
      _files.getUrl(record, filename,
          download: download, thumb: thumb, token: token);
}

// ---------------------------------------------------------------------------
// Typed realtime — mirrors typed/realtime.ts
// ---------------------------------------------------------------------------

/// A typed record-mutation event.
class TypedRealtimeEvent<T> {
  final String topic;
  final String action; // create | update | delete
  final T record;

  const TypedRealtimeEvent(this.topic, this.action, this.record);
}

/// Typed realtime surface for one collection. A generated subclass fixes [T]
/// and the `fromRecord` mapper.
class TypedRealtime<T> {
  TypedRealtime(ZigbaseClient client, this.meta, this.fromRecord)
      : _rt = client.realtime;

  final RealtimeService _rt;
  final CollectionMeta meta;
  final T Function(ZbRecord) fromRecord;

  Future<ZbUnsubscribe> subscribe(
    void Function(TypedRealtimeEvent<T>) callback, {
    String? filter,
    Expr? where,
  }) =>
      _rt.subscribe(
        meta.name,
        (e) => callback(
            TypedRealtimeEvent<T>(e.topic, e.action, fromRecord(e.record))),
        filter: where?.compile() ?? filter,
      );

  Stream<TypedRealtimeEvent<T>> stream({String? filter, Expr? where}) =>
      _rt.stream(meta.name, filter: where?.compile() ?? filter).map((e) =>
          TypedRealtimeEvent<T>(e.topic, e.action, fromRecord(e.record)));

  Future<void> close() => _rt.close();
}
