/// One page of native server-side cursor (keyset) pagination.
///
/// The server (`src/api/records.zig` + `src/query/keyset.zig`) mints the
/// opaque `nextCursor`/`prevCursor` tokens; the client forwards whatever it
/// received verbatim — it never decodes, validates, or synthesizes a token.
/// `totalItems` is present only when the page was fetched with a total
/// requested (`skipTotal: false`). Mirrors `CursorPage<T>` in
/// `clients/typescript/src/cursor.ts` and the `getPage` envelope mapping in
/// `clients/typescript/src/collection.ts`.
library;

import 'records.dart';

class CursorPage {
  final List<ZbRecord> items;
  final String? nextCursor;
  final String? prevCursor;
  final bool hasNext;
  final bool hasPrev;
  final int? totalItems;

  CursorPage({
    required this.items,
    required this.nextCursor,
    required this.prevCursor,
    required this.hasNext,
    required this.hasPrev,
    this.totalItems,
  });

  factory CursorPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return CursorPage(
      items: rawItems
          .map((e) => ZbRecord(e as Map<String, dynamic>))
          .toList(growable: false),
      nextCursor: json['nextCursor'] as String?,
      prevCursor: json['prevCursor'] as String?,
      hasNext: json['hasNext'] as bool? ?? false,
      hasPrev: json['hasPrev'] as bool? ?? false,
      totalItems: json['totalItems'] as int?,
    );
  }
}
