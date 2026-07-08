import 'dart:convert';

import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

String _makeJwt(Map<String, dynamic> payload) {
  final header =
      base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
  final body = base64Url.encode(utf8.encode(jsonEncode(payload)));
  return '$header.$body.sig';
}

void main() {
  group('decodeJwtPayload', () {
    test('decodes the payload segment of a hand-built token', () {
      final segment =
          base64Url.encode(utf8.encode('{"id":"u1","exp":9999999999}'));
      final token = 'header.$segment.sig';
      final p = decodeJwtPayload(token);
      expect(p, isNotNull);
      expect(p?['id'], 'u1');
      expect(p?['exp'], 9999999999);
    });

    test('decodes the payload segment', () {
      final token =
          _makeJwt({'id': 'u1', 'collection': 'users', 'exp': 9999999999});
      final p = decodeJwtPayload(token);
      expect(p?['id'], 'u1');
      expect(p?['collection'], 'users');
    });

    test('returns null for malformed tokens', () {
      expect(decodeJwtPayload('not-a-jwt'), isNull);
      expect(decodeJwtPayload(''), isNull);
      expect(decodeJwtPayload('a.b'), isNull);
      expect(decodeJwtPayload('a..c'), isNull);
      expect(decodeJwtPayload('a.!!!notbase64.c'), isNull);
    });
  });

  group('isTokenExpired', () {
    test('false for far-future exp', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(isTokenExpired(_makeJwt({'exp': now + 3600})), isFalse);
    });

    test('true for past exp', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(isTokenExpired(_makeJwt({'exp': now - 10})), isTrue);
    });

    test('true for missing exp', () {
      expect(isTokenExpired(_makeJwt({'id': 'u1'})), isTrue);
    });

    test('true for malformed token', () {
      expect(isTokenExpired('garbage'), isTrue);
    });

    test('leeway pushes a near-future exp into expired', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(isTokenExpired(_makeJwt({'exp': now + 5}), leewaySeconds: 30),
          isTrue);
      expect(isTokenExpired(_makeJwt({'exp': now + 5})), isFalse);
    });
  });
}
