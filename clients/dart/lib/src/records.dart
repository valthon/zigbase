/// Record shape, offset-list envelope, and multipart-encoding helpers.
///
/// The multipart rules are a byte-for-byte port of `toFormData` in
/// `clients/typescript/src/records.ts`: that function iterates array
/// *elements* individually (one form part per element, with per-element
/// type coercion), rather than JSON-encoding a non-file array as a single
/// part. We port that behavior verbatim — including for plain-scalar
/// arrays, which therefore repeat the field key just like file arrays do.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// A single ZigBase record: the raw JSON map plus typed accessors.
///
/// Mirrors the permissive `ZbRecord` shape in `clients/typescript/src/records.ts`
/// (an `id` plus arbitrary fields) that the dynamic base SDK uses.
class ZbRecord {
  final Map<String, dynamic> data;

  ZbRecord(this.data);

  /// The record id, or `''` if absent/not a string.
  String get id {
    final v = data['id'];
    return v is String ? v : '';
  }

  /// Reads a raw field value.
  dynamic operator [](String key) => data[key];

  /// Reads [key] as a [String], or `null` if absent or not a string.
  String? getString(String key) {
    final v = data[key];
    return v is String ? v : null;
  }

  /// Reads [key] as an [int], coercing any [num] (so a JSON `4.0` reads as
  /// `4`). Returns `null` if absent or not numeric.
  int? getInt(String key) {
    final v = data[key];
    return v is num ? v.toInt() : null;
  }

  /// Reads [key] as a [double], coercing any [num]. Returns `null` if absent
  /// or not numeric.
  double? getDouble(String key) {
    final v = data[key];
    return v is num ? v.toDouble() : null;
  }

  /// Reads [key] as a [bool], or `null` if absent or not a bool.
  bool? getBool(String key) {
    final v = data[key];
    return v is bool ? v : null;
  }

  /// Reads [key] as a [List], or `null` if absent or not a list.
  List<dynamic>? getList(String key) {
    final v = data[key];
    return v is List ? v : null;
  }

  /// Returns the underlying [data] map.
  Map<String, dynamic> toJson() => data;
}

/// Result shape of an offset-paginated list (`getList`). Mirrors the wire
/// envelope and `ListResult<T>` in `clients/typescript/src/records.ts`.
class ListResult {
  final int page;
  final int perPage;
  final int totalItems;
  final int totalPages;
  final List<ZbRecord> items;

  ListResult({
    required this.page,
    required this.perPage,
    required this.totalItems,
    required this.totalPages,
    required this.items,
  });

  factory ListResult.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return ListResult(
      page: json['page'] as int? ?? 0,
      perPage: json['perPage'] as int? ?? 0,
      totalItems: json['totalItems'] as int? ?? 0,
      totalPages: json['totalPages'] as int? ?? 0,
      items: rawItems
          .map((e) => ZbRecord(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}

/// Formats a [DateTime] as a UTC ISO-8601 string clamped to millisecond
/// precision, matching JS `Date.prototype.toISOString()` byte-for-byte (see
/// the equivalent helper in `lib/src/query.dart` for the full rationale).
String _formatDateTime(DateTime value) {
  final utc = value.toUtc();
  final clamped = utc.microsecond == 0
      ? utc
      : utc.subtract(Duration(microseconds: utc.microsecond));
  return clamped.toIso8601String();
}

/// `true` when `body` contains an [http.MultipartFile] (or a [List]
/// containing one) at the top level, meaning the request must be sent as
/// `multipart/form-data` instead of JSON. Mirrors `hasBlob` in
/// `clients/typescript/src/records.ts`.
bool hasFilePayload(Map<String, dynamic> body) {
  for (final value in body.values) {
    if (value is http.MultipartFile) return true;
    if (value is List && value.any((e) => e is http.MultipartFile)) {
      return true;
    }
  }
  return false;
}

/// Rebuilds [file] with its `field` forced to [key], since the outer map key
/// — not whatever the file happened to be constructed with — is the source
/// of truth for the form field name (matching `FormData.append(key, blob)`
/// in the TS `toFormData`, where a `Blob` carries no field name of its own).
http.MultipartFile _withField(http.MultipartFile file, String key) {
  if (file.field == key) return file;
  return http.MultipartFile(key, file.finalize(), file.length,
      filename: file.filename, contentType: file.contentType);
}

/// Splits `body` into multipart fields + files per the TS `toFormData`
/// rules (`clients/typescript/src/records.ts`):
///
/// - `null` -> appended as an empty-string field.
/// - [http.MultipartFile] -> appended as a file (its `field` is forced to
///   the map key).
/// - [DateTime] -> a plain UTC ISO-8601 string field (not JSON-quoted).
/// - nested [Map] (non-file) -> `jsonEncode`-d into a single field. A
///   [DateTime] nested anywhere inside the container serializes as a
///   millisecond-clamped UTC ISO-8601 JSON string, matching what JS
///   `JSON.stringify` emits for a `Date` via `Date.prototype.toJSON`. Any
///   other non-JSON-encodable value nested inside (including a nested
///   [http.MultipartFile], which cannot become a form part from inside a
///   JSON field) throws an [ArgumentError] naming the offending key — a
///   deliberate divergence from TS, where `JSON.stringify` silently emits
///   `{}` garbage for such values.
/// - [List] -> iterated **element-wise**: each element is independently
///   classified and appended under the same key (files as files, `null`
///   elements dropped, [DateTime]/[Map] elements encoded as above, other
///   scalars via `toString()`). This means a non-file array also repeats
///   the key once per element — it is never JSON-encoded as a whole array
///   — exactly mirroring the TS source, which loops `for (const item of
///   value)` regardless of item type. An empty list therefore produces no
///   field part at all.
/// - other scalars -> `toString()`.
({Map<String, List<String>> fields, List<http.MultipartFile> files})
    encodeMultipart(Map<String, dynamic> body) {
  final fields = <String, List<String>>{};
  final files = <http.MultipartFile>[];

  void addField(String key, String value) {
    fields.putIfAbsent(key, () => <String>[]).add(value);
  }

  String encodeScalarLike(String key, dynamic value) {
    if (value is DateTime) return _formatDateTime(value);
    if (value is Map || value is List) {
      // JS `JSON.stringify` serializes nested Dates transparently via
      // `Date.prototype.toJSON`; Dart's `jsonEncode` has no such hook, so
      // supply one. Anything else non-encodable is rejected loudly (TS
      // would silently emit "{}" for it). `jsonEncode` reports the
      // offending object by throwing `JsonUnsupportedObjectError` (it also
      // wraps anything `toEncodable` itself throws in that same error), so
      // catch it here and surface a clear ArgumentError naming the key.
      try {
        return jsonEncode(value,
            toEncodable: (Object? nested) =>
                nested is DateTime ? _formatDateTime(nested) : nested);
      } on JsonUnsupportedObjectError catch (e) {
        throw ArgumentError.value(
            e.unsupportedObject,
            'body',
            'encodeMultipart: value nested under key "$key" is cyclic or '
                'not JSON-encodable (${e.unsupportedObject.runtimeType})');
      }
    }
    return value.toString();
  }

  for (final entry in body.entries) {
    final key = entry.key;
    final value = entry.value;
    if (value == null) {
      addField(key, '');
    } else if (value is http.MultipartFile) {
      files.add(_withField(value, key));
    } else if (value is List) {
      for (final item in value) {
        if (item is http.MultipartFile) {
          files.add(_withField(item, key));
        } else if (item == null) {
          continue;
        } else {
          addField(key, encodeScalarLike(key, item));
        }
      }
    } else {
      addField(key, encodeScalarLike(key, value));
    }
  }

  return (fields: fields, files: files);
}
