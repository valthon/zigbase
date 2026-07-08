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
  final String body;
  final String contentType;

  _Call(this.method, this.path, this.query, this.body, this.contentType);
}

Transport _scripted(List<http.Response> responses, List<_Call> calls,
    {AuthStore? authStore}) {
  var i = 0;
  final client = MockClient((req) async {
    calls.add(_Call(
      req.method,
      req.url.path,
      req.url.queryParameters,
      req.body,
      req.headers['content-type'] ?? '',
    ));
    final res = responses[i];
    i++;
    return res;
  });
  return Transport(
    baseUrl: 'http://api.test',
    authStore: authStore ?? MemoryAuthStore(),
    httpClient: client,
  );
}

Map<String, dynamic> _record(String id) => {'id': id};

void main() {
  group('getList', () {
    test(
        'assembles filter/sort/expand/fields/skipTotal/search/vector query params',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'page': 1,
              'perPage': 30,
              'totalItems': 0,
              'totalPages': 0,
              'items': <Map<String, dynamic>>[],
            }),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getList(
        page: 2,
        perPage: 20,
        filter: "status = 'live'",
        sort: '-created',
        expand: 'author',
        fields: 'id,title',
        skipTotal: true,
        search: 'hello',
        vector: const VectorQuery(field: 'embedding', values: [1.0, 2.5]),
      );

      expect(calls[0].method, 'GET');
      expect(calls[0].path, '/api/collections/posts/records');
      final q = calls[0].query;
      expect(q['page'], '2');
      expect(q['perPage'], '20');
      expect(q['filter'], "status = 'live'");
      expect(q['sort'], '-created');
      expect(q['expand'], 'author');
      expect(q['fields'], 'id,title');
      expect(q['skipTotal'], '1');
      expect(q['search'], 'hello');
      expect(q['vector'], 'embedding:[1,2.5]');
    });

    test('omits optional params entirely when not provided (no skipTotal key)',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'page': 1,
              'perPage': 30,
              'totalItems': 0,
              'totalPages': 0,
              'items': <Map<String, dynamic>>[]
            }),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getList();

      final q = calls[0].query;
      expect(q.containsKey('skipTotal'), isFalse);
      expect(q.containsKey('filter'), isFalse);
      expect(q.containsKey('vector'), isFalse);
      expect(q['page'], '1');
      expect(q['perPage'], '30');
    });

    test('clamps perPage below 1 up to 1', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'page': 1,
              'perPage': 1,
              'totalItems': 0,
              'totalPages': 0,
              'items': <Map<String, dynamic>>[]
            }),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getList(perPage: 0);

      expect(calls[0].query['perPage'], '1');
    });

    test('clamps perPage above 500 down to 500', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'page': 1,
              'perPage': 500,
              'totalItems': 0,
              'totalPages': 0,
              'items': <Map<String, dynamic>>[]
            }),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getList(perPage: 10000);

      expect(calls[0].query['perPage'], '500');
    });

    test('parses the ListResult envelope', () async {
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'page': 1,
              'perPage': 30,
              'totalItems': 2,
              'totalPages': 1,
              'items': [_record('r1'), _record('r2')],
            }),
            200),
      ], []);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final result = await svc.getList();

      expect(result.totalItems, 2);
      expect(result.items.map((r) => r.id), ['r1', 'r2']);
    });
  });

  group('getOne', () {
    test('GETs /records/:id with expand/fields', () async {
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response(jsonEncode(_record('r1')), 200)], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final rec = await svc.getOne('r1', expand: 'author', fields: 'id');

      expect(calls[0].method, 'GET');
      expect(calls[0].path, '/api/collections/posts/records/r1');
      expect(calls[0].query, {'expand': 'author', 'fields': 'id'});
      expect(rec.id, 'r1');
    });

    test('uri-encodes the record id', () async {
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response(jsonEncode(_record('a/b')), 200)], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.getOne('a/b');

      expect(calls[0].path, '/api/collections/posts/records/a%2Fb');
    });
  });

  group('getFirstListItem', () {
    test('requests perPage=1, skipTotal=1 and returns the first item',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'page': 1,
              'perPage': 1,
              'totalItems': 0,
              'totalPages': 0,
              'items': [_record('only')],
            }),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final rec = await svc.getFirstListItem("status = 'live'");

      expect(calls[0].query['perPage'], '1');
      expect(calls[0].query['skipTotal'], '1');
      expect(calls[0].query['filter'], "status = 'live'");
      expect(rec.id, 'only');
    });

    test('throws a synthesized 404 ZigbaseException when nothing matches',
        () async {
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'page': 1,
              'perPage': 1,
              'totalItems': 0,
              'totalPages': 0,
              'items': <Map<String, dynamic>>[]
            }),
            200),
      ], []);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await expectLater(
        svc.getFirstListItem("status = 'nope'"),
        throwsA(isA<ZigbaseException>()
            .having((e) => e.status, 'status', 404)
            .having((e) => e.message, 'message',
                'No record found matching the filter.')),
      );
    });
  });

  group('create', () {
    test('POSTs /records with the body and expand/fields query', () async {
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response(jsonEncode(_record('new1')), 200)], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final rec = await svc.create({'title': 'hi'}, expand: 'author');

      expect(calls[0].method, 'POST');
      expect(calls[0].path, '/api/collections/posts/records');
      expect(calls[0].query, {'expand': 'author'});
      expect(jsonDecode(calls[0].body), {'title': 'hi'});
      expect(rec.id, 'new1');
    });

    test(
        'a body containing a MultipartFile reaches the transport unchanged (multipart request)',
        () async {
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response(jsonEncode(_record('new1')), 200)], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final file = http.MultipartFile.fromString('avatar', 'IMGBYTES',
          filename: 'a.png');
      await svc.create({'title': 'hi', 'avatar': file});

      expect(calls[0].contentType, contains('multipart/form-data'));
      expect(calls[0].body, contains('name="title"'));
      expect(calls[0].body, contains('name="avatar"; filename="a.png"'));
      expect(calls[0].body, contains('IMGBYTES'));
    });
  });

  group('update', () {
    test('PATCHes /records/:id with the body and expand/fields query',
        () async {
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response(jsonEncode(_record('r1')), 200)], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final rec =
          await svc.update('r1', {'title': 'updated'}, fields: 'id,title');

      expect(calls[0].method, 'PATCH');
      expect(calls[0].path, '/api/collections/posts/records/r1');
      expect(calls[0].query, {'fields': 'id,title'});
      expect(jsonDecode(calls[0].body), {'title': 'updated'});
      expect(rec.id, 'r1');
    });

    test(
        'a body containing a MultipartFile reaches the transport unchanged (multipart request)',
        () async {
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response(jsonEncode(_record('r1')), 200)], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final file = http.MultipartFile.fromString('avatar', 'IMGBYTES2',
          filename: 'b.png');
      await svc.update('r1', {'avatar': file});

      expect(calls[0].contentType, contains('multipart/form-data'));
      expect(calls[0].body, contains('name="avatar"; filename="b.png"'));
      expect(calls[0].body, contains('IMGBYTES2'));
    });
  });

  group('delete', () {
    test('DELETEs /records/:id', () async {
      final calls = <_Call>[];
      final transport = _scripted([http.Response('', 204)], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      await svc.delete('r1');

      expect(calls[0].method, 'DELETE');
      expect(calls[0].path, '/api/collections/posts/records/r1');
    });
  });

  group('getAbilities', () {
    test('GETs /records/:id/abilities and parses view/update/delete', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({'view': true, 'update': false, 'delete': false}), 200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'posts');

      final abilities = await svc.getAbilities('r1');

      expect(calls[0].method, 'GET');
      expect(calls[0].path, '/api/collections/posts/records/r1/abilities');
      expect(abilities.view, isTrue);
      expect(abilities.update, isFalse);
      expect(abilities.delete, isFalse);
    });
  });
}
