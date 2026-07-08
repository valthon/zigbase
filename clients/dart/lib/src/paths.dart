/// Internal dotted-path readers shared by the sort comparator
/// (`query.dart`), the filter evaluator (`live/filter_eval.dart`), and the
/// live list's sort-key signature (`live/live_collection.dart`).
///
/// NOT exported from `zigbase_client.dart` — implementation detail only.
library;

/// Walks pre-split [path] segments into [record]. Any non-map intermediate
/// (null, scalar, missing) resolves the whole path to null.
Object? readPathSegments(Map<String, dynamic> record, List<String> path) {
  Object? cur = record;
  for (final key in path) {
    if (cur is! Map) return null;
    cur = cur[key];
  }
  return cur;
}

/// Reads a possibly-dotted field path (`"author.name"`) out of [obj].
Object? readDottedPath(Map<String, dynamic> obj, String path) {
  if (!path.contains('.')) return obj[path];
  return readPathSegments(obj, path.split('.'));
}
