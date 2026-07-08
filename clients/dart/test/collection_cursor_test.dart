import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zigbase_client/src/transport.dart';
import 'package:zigbase_client/zigbase_client.dart';

class _Call {
  final String method;
  final String path;
  final Map<String, String> query;

  _Call(this.method, this.path, this.query);
}

Transport _scripted(List<http.Response> responses, List<_Call> calls) {
  var i = 0;
  final client = MockClient((req) async {
    calls.add(_Call(req.method, req.url.path, req.url.queryParameters));
    final res = responses[i];
    i++;
    return res;
  });
  return Transport(
      baseUrl: 'http://api.test',
      authStore: MemoryAuthStore(),
      httpClient: client);
}

Map<String, dynamic> _record(String id) => {'id': id};

Map<String, dynamic> _page({
  required List<Map<String, dynamic>> items,
  String? nextCursor,
  String? prevCursor,
  required bool hasNext,
  bool hasPrev = false,
  int? totalItems,
}) {
  return {
    'items': items,
    'nextCursor': nextCursor,
    'prevCursor': prevCursor,
    'hasNext': hasNext,
    'hasPrev': hasPrev,
    if (totalItems != null) 'totalItems': totalItems,
  };
}

void main() {
  group('getPage', () {
    test('maps the full envelope', () async {
      final transport = _scripted([
        http.Response(
            jsonEncode(_page(
              items: [_record('r1'), _record('r2')],
              nextCursor: 'c2',
              prevCursor: null,
              hasNext: true,
              totalItems: 42,
            )),
            200),
      ], []);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final page = await svc.getPage(withTotal: true);

      expect(page.items.map((r) => r.id), ['r1', 'r2']);
      expect(page.nextCursor, 'c2');
      expect(page.prevCursor, isNull);
      expect(page.hasNext, isTrue);
      expect(page.hasPrev, isFalse);
      expect(page.totalItems, 42);
    });

    test('sends limit and, by default, no cursor/skipTotal params', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode(_page(items: [], hasNext: false)), 200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getPage(limit: 50);

      expect(calls[0].method, 'GET');
      expect(calls[0].path, '/api/collections/posts/records');
      expect(calls[0].query['limit'], '50');
      expect(calls[0].query.containsKey('cursor'), isFalse);
      expect(calls[0].query.containsKey('skipTotal'), isFalse);
    });

    test('forwards a non-empty cursor verbatim', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode(_page(items: [], hasNext: false)), 200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getPage(cursor: 'opaque-token-xyz');

      expect(calls[0].query['cursor'], 'opaque-token-xyz');
    });

    test('an empty-string cursor is treated as absent (first page)', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode(_page(items: [], hasNext: false)), 200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getPage(cursor: '');

      expect(calls[0].query.containsKey('cursor'), isFalse);
    });

    test('withTotal sends skipTotal=false', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode(_page(items: [], hasNext: false)), 200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getPage(withTotal: true);

      expect(calls[0].query['skipTotal'], 'false');
    });

    test('passes through filter/sort/expand/fields/search', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode(_page(items: [], hasNext: false)), 200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getPage(
        filter: "status = 'live'",
        sort: '-created',
        expand: 'author',
        fields: 'id',
        search: 'hi',
      );

      final q = calls[0].query;
      expect(q['filter'], "status = 'live'");
      expect(q['sort'], '-created');
      expect(q['expand'], 'author');
      expect(q['fields'], 'id');
      expect(q['search'], 'hi');
    });
  });

  group('iterate', () {
    test('follows nextCursor across 3 pages and stops on hasNext:false',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode(_page(
                items: [_record('a'), _record('b')],
                nextCursor: 'cur2',
                hasNext: true)),
            200),
        http.Response(
            jsonEncode(_page(
                items: [_record('c')], nextCursor: 'cur3', hasNext: true)),
            200),
        http.Response(
            jsonEncode(
                _page(items: [_record('d')], nextCursor: null, hasNext: false)),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final ids = await svc.iterate(batch: 2).map((r) => r.id).toList();

      expect(ids, ['a', 'b', 'c', 'd']);
      expect(calls, hasLength(3));
      expect(calls[0].query['limit'], '2');
      expect(calls[0].query.containsKey('cursor'), isFalse);
      expect(calls[1].query['cursor'], 'cur2');
      expect(calls[2].query['cursor'], 'cur3');
    });

    test(
        'stops when hasNext is false even if nextCursor is non-null (hasNext governs, not nextCursor)',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode(_page(
                items: [_record('only')],
                nextCursor: 'looks-valid-but-ignored',
                hasNext: false)),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final ids = await svc.iterate().map((r) => r.id).toList();

      expect(ids, ['only']);
      expect(calls,
          hasLength(1)); // no second request despite a non-null nextCursor
    });

    test(
        'stops when nextCursor is null even though hasNext could theoretically be true',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode(
                _page(items: [_record('x')], nextCursor: null, hasNext: true)),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final ids = await svc.iterate().map((r) => r.id).toList();

      expect(ids, ['x']);
      expect(calls, hasLength(1));
    });

    test('throws instead of looping when a page is empty but claims hasNext',
        () async {
      // A misbehaving server: first page has items + hasNext, the next page is
      // empty but still claims hasNext. Without a guard this spins forever.
      final transport = _scripted([
        http.Response(
            jsonEncode(_page(
                items: [_record('r1')], nextCursor: 'TOK1', hasNext: true)),
            200),
        http.Response(
            jsonEncode(_page(items: [], nextCursor: 'TOK2', hasNext: true)),
            200),
      ], []);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final seen = <String>[];
      await expectLater(
        () async {
          await for (final r in svc.iterate(batch: 2)) {
            seen.add(r.id);
          }
        }(),
        throwsA(isA<ZigbaseException>()),
      );
      expect(seen, ['r1']); // the first page's items were still yielded
    });

    test('throws instead of looping when the server repeats the same cursor',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode(_page(
                items: [_record('r1')], nextCursor: 'STUCK', hasNext: true)),
            200),
        http.Response(
            jsonEncode(_page(
                items: [_record('r2')], nextCursor: 'STUCK', hasNext: true)),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await expectLater(
        svc.iterate(batch: 2).toList(),
        throwsA(isA<ZigbaseException>()),
      );
      // First page used no cursor, second forwarded "STUCK", the third would
      // repeat "STUCK" -> caught. Exactly two requests are made.
      expect(calls, hasLength(2));
    });

    test(
        'passes filter/sort/expand/fields/search through to every page request',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode(
                _page(items: [_record('a')], nextCursor: 'c2', hasNext: true)),
            200),
        http.Response(
            jsonEncode(
                _page(items: [_record('b')], nextCursor: null, hasNext: false)),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc
          .iterate(
              filter: "x = 'y'",
              sort: '-created',
              expand: 'author',
              fields: 'id',
              search: 'q')
          .toList();

      for (final call in calls) {
        expect(call.query['filter'], "x = 'y'");
        expect(call.query['sort'], '-created');
        expect(call.query['expand'], 'author');
        expect(call.query['fields'], 'id');
        expect(call.query['search'], 'q');
      }
    });
  });

  group('getFullList', () {
    test('accumulates every page into one list', () async {
      final transport = _scripted([
        http.Response(
            jsonEncode(_page(
                items: [_record('a'), _record('b')],
                nextCursor: 'c2',
                hasNext: true)),
            200),
        http.Response(
            jsonEncode(
                _page(items: [_record('c')], nextCursor: null, hasNext: false)),
            200),
      ], []);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final all = await svc.getFullList(batch: 2);

      expect(all.map((r) => r.id), ['a', 'b', 'c']);
    });

    test('returns an empty list when the first page is empty', () async {
      final transport = _scripted([
        http.Response(
            jsonEncode(_page(items: [], nextCursor: null, hasNext: false)),
            200),
      ], []);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final all = await svc.getFullList();

      expect(all, isEmpty);
    });
  });
}
