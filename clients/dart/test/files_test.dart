import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zigbase_client/src/transport.dart';
import 'package:zigbase_client/zigbase_client.dart';

class _Call {
  final String method;
  final String url;

  _Call(this.method, this.url);
}

Transport _scripted(List<http.Response> responses, List<_Call> calls) {
  var i = 0;
  final client = MockClient((req) async {
    calls.add(_Call(req.method, req.url.toString()));
    final res = responses[i];
    i++;
    return res;
  });
  return Transport(
    baseUrl: 'http://api.test',
    authStore: MemoryAuthStore(),
    httpClient: client,
  );
}

FilesService _files({String baseUrl = 'http://api.test'}) {
  final transport = Transport(
    baseUrl: baseUrl,
    authStore: MemoryAuthStore(),
    httpClient: MockClient((_) async => http.Response('', 204)),
  );
  return FilesService(transport, baseUrl);
}

void main() {
  group('FilesService.getUrl', () {
    test('builds a URL from a record + filename (collectionName)', () {
      final files = _files();
      final url = files.getUrl(
        ZbRecord({'id': 'rec1', 'collectionName': 'posts'}),
        'photo.png',
      );
      expect(url, 'http://api.test/api/files/posts/rec1/photo.png');
    });

    test('prefers collectionId over collectionName', () {
      final files = _files();
      final url = files.getUrl(
        ZbRecord({
          'id': 'rec1',
          'collectionId': 'col_abc',
          'collectionName': 'posts',
        }),
        'p.png',
      );
      expect(url, 'http://api.test/api/files/col_abc/rec1/p.png');
    });

    test(
        'throws ArgumentError when neither collectionId nor collectionName present',
        () {
      final files = _files();
      expect(
        () => files.getUrl(ZbRecord({'id': 'rec1'}), 'p.png'),
        throwsArgumentError,
      );
    });

    test('URL-encodes a filename with a space', () {
      final files = _files();
      final url = files.getUrl(
        ZbRecord({'id': 'r', 'collectionName': 'posts'}),
        'a b.png',
      );
      expect(url, 'http://api.test/api/files/posts/r/a%20b.png');
    });

    test('URL-encodes a filename with a #', () {
      final files = _files();
      final url = files.getUrl(
        ZbRecord({'id': 'r', 'collectionName': 'posts'}),
        'a#b.png',
      );
      expect(url, 'http://api.test/api/files/posts/r/a%23b.png');
    });

    test('URL-encodes hostile collection/record segments too', () {
      final files = _files();
      final url = files.getUrl(
        ZbRecord({'id': 'r/1', 'collectionName': 'a b'}),
        'p.png',
      );
      expect(url, 'http://api.test/api/files/a%20b/r%2F1/p.png');
    });

    test('adds download=1, thumb, and token query params', () {
      final files = _files();
      final url = files.getUrl(
        ZbRecord({'id': 'r', 'collectionName': 'posts'}),
        'p.png',
        download: true,
        thumb: '100x100',
        token: 'tok123',
      );
      final u = Uri.parse(url);
      expect(u.path, '/api/files/posts/r/p.png');
      expect(u.queryParameters['download'], '1');
      expect(u.queryParameters['thumb'], '100x100');
      expect(u.queryParameters['token'], 'tok123');
    });

    test('omits download when false and thumb/token when null', () {
      final files = _files();
      final url = files.getUrl(
        ZbRecord({'id': 'r', 'collectionName': 'posts'}),
        'p.png',
      );
      expect(url, 'http://api.test/api/files/posts/r/p.png');
    });

    test('trims trailing slashes from baseUrl', () {
      final files = _files(baseUrl: 'http://api.test/');
      final url = files.getUrl(
        ZbRecord({'id': 'r', 'collectionName': 'posts'}),
        'p.png',
      );
      expect(url, 'http://api.test/api/files/posts/r/p.png');
    });
  });

  group('FilesService.getUrlFor', () {
    test('accepts explicit collection/record ids', () {
      final files = _files();
      final url = files.getUrlFor('posts', 'rec1', 'p.png');
      expect(url, 'http://api.test/api/files/posts/rec1/p.png');
    });

    test('applies query options same as getUrl', () {
      final files = _files();
      final url = files.getUrlFor('posts', 'rec1', 'p.png',
          download: true, thumb: '50x50', token: 't1');
      final u = Uri.parse(url);
      expect(u.queryParameters,
          {'download': '1', 'thumb': '50x50', 'token': 't1'});
    });
  });

  group('FilesService.getToken', () {
    test('POSTs /api/files/token and returns the token', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode({'token': 'file-tok'}), 200),
      ], calls);
      final files = FilesService(transport, 'http://api.test');

      final token = await files.getToken();

      expect(token, 'file-tok');
      expect(calls, hasLength(1));
      expect(calls[0].method, 'POST');
      expect(calls[0].url, 'http://api.test/api/files/token');
    });
  });
}
