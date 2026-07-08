/// Injection-safe helpers for building ZigBase filter expressions and
/// vector-search specs.
///
/// This is a byte-for-byte port of `clients/typescript/src/query.ts`
/// (`quoteString` / `filterValue` / `vectorSpec`): the wire format these
/// functions produce is dictated by the server's filter lexer
/// (`src/query/lexer.zig`), not by either client, so both SDKs must agree
/// exactly with each other and with the server.
library;

/// Quotes a Dart string as a ZigBase filter literal.
///
/// The server lexer unescapes backslash sequences inside a quoted string:
/// `\\`->`\`, `\'`->`'`, `\n`->newline, `\t`->tab, `\r`->CR. We therefore
/// ALWAYS single-quote and escape the bytes that would otherwise terminate or
/// corrupt the literal: backslash, single quote, and the three control
/// chars. Every other byte (including a double quote) is left literal.
/// Because the closing single quote can only appear escaped, the literal can
/// never be broken out of.
String _quoteString(String s) {
  final buf = StringBuffer("'");
  for (final rune in s.runes) {
    if (rune == 0x5C) {
      buf.write(r'\\'); // \
    } else if (rune == 0x27) {
      buf.write(r"\'"); // '
    } else if (rune == 0x0A) {
      buf.write(r'\n'); // newline
    } else if (rune == 0x09) {
      buf.write(r'\t'); // tab
    } else if (rune == 0x0D) {
      buf.write(r'\r'); // CR
    } else {
      buf.writeCharCode(rune);
    }
  }
  buf.write("'");
  return buf.toString();
}

/// Formats a finite [double] to match JS `Number.prototype.toString()` /
/// `JSON.stringify` output exactly.
///
/// Dart's `double.toString()` already uses the same shortest-round-trip
/// algorithm and the same decimal/exponential thresholds and formatting as
/// JS (verified empirically across representative values, including the
/// 1e-6/1e21 notation-switch boundaries and the `e+`/`e-` exponent style);
/// the one difference is that Dart always keeps a `.0` for integral values
/// (`1.0`, `-0.0`) where JS renders a bare integer (`1`, `0`). This strips
/// that suffix so the two runtimes emit identical bytes.
String _formatDouble(double v) {
  if (v == 0) return '0'; // collapses -0.0 -> "0", matching JS String(-0).
  final s = v.toString();
  if (!s.contains('e') && s.endsWith('.0')) {
    return s.substring(0, s.length - 2);
  }
  return s;
}

/// Formats a [DateTime] as a UTC ISO-8601 literal clamped to millisecond
/// precision, matching JS `Date.prototype.toISOString()` byte-for-byte.
///
/// JS `Date` is inherently millisecond-resolution, so the TS SDK always
/// emits exactly a 3-digit fraction (`.678Z`); Dart's `DateTime` has
/// microsecond resolution and `toIso8601String()` would emit a 6-digit
/// fraction (`.678901Z`) whenever `microsecond != 0` (e.g. from
/// `DateTime.now()` on the VM). Beyond breaking byte-parity, that is a
/// server-side correctness hazard: date fields compare lexicographically as
/// TEXT, and `"...05.678Z" > "...05.678901Z"` in a string compare (`Z` sorts
/// above digits), so a microsecond-precision boundary literal would
/// mis-order against stored millisecond-precision values. The sub-millisecond
/// part is dropped by subtraction rather than an epoch-integer round-trip:
/// Dart's `millisecondsSinceEpoch` getter already floors, so this is not
/// needed to protect it — the hazard would only bite a hand-rolled
/// `microsecondsSinceEpoch ~/ 1000`, whose `~/` truncates toward zero and
/// thus rounds the wrong way for pre-1970 (negative-epoch) instants.
String _formatDateTime(DateTime value) {
  final utc = value.toUtc();
  final clamped = utc.microsecond == 0
      ? utc
      : utc.subtract(Duration(microseconds: utc.microsecond));
  return clamped.toIso8601String();
}

/// Serializes a single interpolated value into a safe ZigBase filter
/// operand.
///
/// `null` -> `null`; finite `num` -> bare (`5`, `2.5`); `bool` -> `true`/
/// `false`; `DateTime` -> single-quoted UTC ISO-8601, clamped to millisecond
/// precision (see [_formatDateTime]);
/// `String` -> single-quoted and escaped per [_quoteString]. Any other type
/// — including `List`/`Map` (array/object operands are ambiguous — expand
/// them yourself, e.g. into an `||` chain or a native `in (...)` clause) —
/// throws an [ArgumentError] rather than silently coercing.
String filterValue(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return value ? 'true' : 'false';
  if (value is int) return value.toString();
  if (value is double) {
    if (value.isNaN || value.isInfinite) {
      throw ArgumentError.value(
          value, 'value', 'filter: non-finite number operand');
    }
    return _formatDouble(value);
  }
  if (value is DateTime) return _quoteString(_formatDateTime(value));
  if (value is String) return _quoteString(value);
  if (value is List) {
    throw ArgumentError.value(value, 'value',
        'filter: array operands are ambiguous; expand them yourself (e.g. build an `||` chain)');
  }
  throw ArgumentError.value(
      value, 'value', 'filter: unsupported operand type: ${value.runtimeType}');
}

final RegExp _placeholderPattern = RegExp(r'\{:([A-Za-z_][A-Za-z0-9_]*)\}');

/// Interpolates named `{:name}` placeholders in [expr] with
/// `filterValue(params[name])`.
///
/// Static text outside placeholders is passed through verbatim. Throws an
/// [ArgumentError] if [expr] references a name absent from [params].
///
///   zbFilter('status = {:s} && n > {:n}', {'s': 'published', 'n': 5})
///   // => "status = 'published' && n > 5"
String zbFilter(String expr, [Map<String, Object?> params = const {}]) {
  return expr.replaceAllMapped(_placeholderPattern, (match) {
    final name = match.group(1)!;
    if (!params.containsKey(name)) {
      throw ArgumentError.value(
          name, 'name', 'zbFilter: unknown placeholder {:$name}');
    }
    return filterValue(params[name]);
  });
}

/// One term of a parsed sort spec: a (possibly dotted) field path and a
/// direction. Ported from `SortTerm` in `clients/typescript/src/query.ts`.
class SortTerm {
  final String field;

  /// `'asc'` or `'desc'`.
  final String dir;

  const SortTerm(this.field, this.dir);

  @override
  bool operator ==(Object other) =>
      other is SortTerm && other.field == field && other.dir == dir;

  @override
  int get hashCode => Object.hash(field, dir);

  @override
  String toString() => 'SortTerm($field, $dir)';
}

/// Parses a sort string (`"-created,title"`) into ordered [SortTerm]s.
///
/// A leading `-` means descending; a leading `+` or no prefix means ascending;
/// blank terms are dropped. Byte-for-byte port of `parseSort` in
/// `clients/typescript/src/query.ts`.
List<SortTerm> parseSort(String sort) {
  final terms = <SortTerm>[];
  for (final raw in sort.split(',')) {
    final t = raw.trim();
    if (t.isEmpty) continue;
    if (t.startsWith('-')) {
      terms.add(SortTerm(t.substring(1).trim(), 'desc'));
    } else if (t.startsWith('+')) {
      terms.add(SortTerm(t.substring(1).trim(), 'asc'));
    } else {
      terms.add(SortTerm(t, 'asc'));
    }
  }
  return terms.where((t) => t.field.isNotEmpty).toList();
}

/// Reads a possibly-dotted field path (`"author.name"`) out of a record map.
Object? _readSortPath(Map<String, dynamic> obj, String path) {
  if (!path.contains('.')) return obj[path];
  Object? cur = obj;
  for (final seg in path.split('.')) {
    if (cur is! Map) return null;
    cur = cur[seg];
  }
  return cur;
}

/// Compares two scalar values. Null/absent values sort BEFORE everything (the
/// ascending baseline; the caller flips the sign for descending). Numbers
/// compare numerically, booleans false-before-true, everything else by string.
/// Port of `compareScalar` in `clients/typescript/src/query.ts` (returns a
/// sign, which is all the multi-key comparator uses).
int _compareScalar(Object? a, Object? b) {
  final an = a == null;
  final bn = b == null;
  if (an && bn) return 0;
  if (an) return -1;
  if (bn) return 1;
  if (a is num && b is num) return a.compareTo(b);
  if (a is bool && b is bool) return (a ? 1 : 0) - (b ? 1 : 0);
  return a.toString().compareTo(b.toString());
}

/// Multi-key comparator over [terms]. Null/absent values sort first under
/// ascending and last under descending. Reused by the live-store list to keep
/// items ordered. Port of `compareBySort` in `clients/typescript/src/query.ts`.
int compareBySort(
  Map<String, dynamic> a,
  Map<String, dynamic> b,
  List<SortTerm> terms,
) {
  for (final term in terms) {
    final cmp = _compareScalar(
        _readSortPath(a, term.field), _readSortPath(b, term.field));
    if (cmp != 0) return term.dir == 'desc' ? -cmp : cmp;
  }
  return 0;
}

/// A structured nearest-neighbor query for `getList` (server `-Dvector`
/// builds only).
class VectorQuery {
  /// The json field holding the stored embeddings. Passed through verbatim
  /// (the server gates identifiers).
  final String field;

  /// Distance metric (`'cosine'` or `'l2'`); the server defaults to cosine
  /// when omitted.
  final String? metric;

  /// The query embedding. Every element must be a finite number.
  final List<double> values;

  const VectorQuery({required this.field, this.metric, required this.values});

  /// Serializes this query to the `<field>[:metric]:<json-array>` wire spec
  /// of `GET /api/collections/:col/records?vector=…`.
  ///
  /// Requires ZigBase >= 0.9.0 built with `-Dvector=true` (a default build
  /// answers 400 "Vector search is not enabled in this build."). Vector
  /// search is offset-only — the server rejects it in cursor mode. Throws an
  /// [ArgumentError] on a non-finite value (same posture as [filterValue]).
  ///
  /// The array is rendered with the same byte format as JS
  /// `JSON.stringify(values)` — comma-separated, no whitespace, integral
  /// doubles bare (`1`, not `1.0`) — since the TS SDK builds this spec via
  /// `JSON.stringify` and both clients must produce identical wire bytes.
  String spec() {
    final buf = StringBuffer('[');
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      if (v.isNaN || v.isInfinite) {
        throw ArgumentError.value(
            v, 'values', 'vectorSpec: non-finite embedding value');
      }
      if (i > 0) buf.write(',');
      buf.write(_formatDouble(v));
    }
    buf.write(']');
    final metricPart = metric != null ? ':$metric' : '';
    return '$field$metricPart:$buf';
  }
}
