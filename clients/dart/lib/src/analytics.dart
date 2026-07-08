/// Product-analytics read APIs (requires ZigBase >= 0.9.0). Tenant-scoped,
/// fail closed.
///
/// A port of `AnalyticsService` in `clients/typescript/src/analytics.ts`.
/// Event/rollup rows are returned as raw `Map<String, dynamic>` (their wire
/// field names are snake_case — `actor_collection`, `occurred_at`,
/// `computed_at`, etc., confirmed against `src/analytics/api.zig`) rather
/// than a typed class, matching this SDK's Task 9 interface.
library;

import 'transport.dart';

/// One page of the tenant-scoped activity feed (`GET /api/analytics/events`).
/// The cursor keys are always present in the wire envelope, never omitted.
class AnalyticsEventsPage {
  final List<Map<String, dynamic>> items;
  final String? nextCursor;
  final bool hasNext;

  AnalyticsEventsPage({
    required this.items,
    required this.nextCursor,
    required this.hasNext,
  });

  factory AnalyticsEventsPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return AnalyticsEventsPage(
      items: rawItems
          .map((e) => e as Map<String, dynamic>)
          .toList(growable: false),
      nextCursor: json['nextCursor'] as String?,
      hasNext: json['hasNext'] as bool? ?? false,
    );
  }
}

class AnalyticsService {
  final Transport _transport;

  AnalyticsService(this._transport);

  /// `GET /api/analytics/events` — the tenant-scoped activity feed. 401
  /// anonymous; empty `items` with no active account; a superuser sees
  /// everything. Paginates with the house cursor: pass the previous page's
  /// `nextCursor` back as [cursor] to fetch the next one; `hasNext` is false
  /// (and `nextCursor` null) on the last page.
  Future<AnalyticsEventsPage> events({
    String? name,
    String? actor,
    String? since,
    int? limit,
    String? cursor,
  }) async {
    final res = await _transport.send(
      '/api/analytics/events',
      query: {
        'name': name,
        'actor': actor,
        'since': since,
        'limit': limit,
        'cursor': cursor,
      },
    ) as Map<String, dynamic>;
    return AnalyticsEventsPage.fromJson(res);
  }

  /// `GET /api/analytics/rollups/:name` — a declared rollup's summary rows
  /// (unwraps the `{items}` envelope). 404 for an undeclared name; 403 for a
  /// non-account-grouped rollup queried by a non-superuser.
  Future<List<Map<String, dynamic>>> rollup(
    String name, {
    String? from,
    String? to,
  }) async {
    final res = await _transport.send(
      '/api/analytics/rollups/${Uri.encodeComponent(name)}',
      query: {'from': from, 'to': to},
    ) as Map<String, dynamic>;
    final rawItems = res['items'] as List<dynamic>? ?? const [];
    return rawItems
        .map((e) => e as Map<String, dynamic>)
        .toList(growable: false);
  }
}
