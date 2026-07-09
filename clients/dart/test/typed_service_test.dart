import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zigbase_client/typed.dart';
import 'package:zigbase_client/zigbase_client.dart';

// A minimal generated-style typed record: `age` is an int-mode field (decimal
// string on the wire), `price` a fixed(2) field.
class Post {
  final String id;
  final String title;
  final int age;
  final double price;

  Post.fromRecord(ZbRecord r)
      : id = coerceString(r['id']),
        title = coerceString(r['title']),
        age = coerceInt(r['age']),
        price = coerceDouble(r['price']);
}

const postsMeta = CollectionMeta(
  name: 'posts',
  fields: {
    'title': FieldMeta(type: FieldType.text),
    'age': FieldMeta(type: FieldType.number, mode: NumberMode.integer),
    'price':
        FieldMeta(type: FieldType.number, mode: NumberMode.fixed, scale: 2),
  },
);

class _Call {
  final String method;
  final String path;
  final Map<String, String> query;
  final String body;
  _Call(this.method, this.path, this.query, this.body);
}

ZigbaseClient _client(List<http.Response> responses, List<_Call> calls) {
  var i = 0;
  final mock = MockClient((req) async {
    calls.add(
        _Call(req.method, req.url.path, req.url.queryParameters, req.body));
    return responses[i++];
  });
  return ZigbaseClient('http://api.test', httpClient: mock);
}

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

void main() {
  test('getList maps ZbRecords to typed T and coerces int/fixed', () async {
    final calls = <_Call>[];
    final client = _client([
      _json({
        'page': 1,
        'perPage': 30,
        'totalItems': 1,
        'totalPages': 1,
        'items': [
          {'id': 'a', 'title': 'hi', 'age': '30', 'price': '19.99'}
        ],
      }),
    ], calls);
    final tc = TypedCollection<Post>(client, postsMeta, Post.fromRecord);

    final page = await tc.getList(filter: "title = 'hi'", sort: '-created');
    expect(page.items.single.age, 30);
    expect(page.items.single.price, 19.99);
    expect(page.totalItems, 1);
    expect(calls[0].query['filter'], "title = 'hi'");
    expect(calls[0].query['sort'], '-created');
  });

  test('getOne joins expand list and maps result', () async {
    final calls = <_Call>[];
    final client = _client([
      _json({'id': 'a', 'title': 'x', 'age': '7', 'price': '0.00'}),
    ], calls);
    final tc = TypedCollection<Post>(client, postsMeta, Post.fromRecord);

    final post = await tc.getOne('a', expand: ['author', 'tags']);
    expect(post.age, 7);
    expect(calls[0].query['expand'], 'author,tags');
  });

  test('create sends body and maps typed result', () async {
    final calls = <_Call>[];
    final client = _client([
      _json({'id': 'new', 'title': 'made', 'age': '5', 'price': '3.50'}),
    ], calls);
    final tc = TypedCollection<Post>(client, postsMeta, Post.fromRecord);

    final post = await tc.create({
      'title': 'made',
      'age': encodeInt(5),
      'price': encodeFixed(3.5, 2),
    });
    expect(post.id, 'new');
    expect(post.price, 3.5);
    final sent = jsonDecode(calls[0].body) as Map<String, dynamic>;
    expect(sent['age'], '5'); // decimal-string wire form
    expect(sent['price'], '3.50');
  });

  test('getPage surfaces cursor fields', () async {
    final calls = <_Call>[];
    final client = _client([
      _json({
        'items': [
          {'id': 'a', 'title': 't', 'age': '1', 'price': '0'}
        ],
        'nextCursor': 'CUR',
        'hasNext': true,
        'hasPrev': false,
      }),
    ], calls);
    final tc = TypedCollection<Post>(client, postsMeta, Post.fromRecord);

    final p = await tc.getPage(limit: 1, sort: '-created');
    expect(p.items.single.id, 'a');
    expect(p.nextCursor, 'CUR');
    expect(p.hasNext, true);
    expect(calls[0].query['limit'], '1');
  });
}
