import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zigbase_client/src/transport.dart';
import 'package:zigbase_client/zigbase_client.dart';

/// One captured request's salient, real properties (method/path/query/body),
/// asserted against instead of any internal collection.dart bookkeeping.
class _Call {
  final String method;
  final String path;
  final Map<String, String> query;
  final String body;
  final bool hasAuthHeader;

  _Call(this.method, this.path, this.query, this.body, this.hasAuthHeader);
}

/// Builds a [Transport] backed by a scripted queue of [responses]; every
/// request made through it is recorded (in order) into [calls].
Transport _scripted(
  List<http.Response> responses,
  List<_Call> calls, {
  AuthStore? authStore,
}) {
  var i = 0;
  final client = MockClient((req) async {
    calls.add(_Call(
      req.method,
      req.url.path,
      req.url.queryParameters,
      req.body,
      req.headers.containsKey('authorization'),
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

void main() {
  group('authWithPassword', () {
    test('POSTs auth-with-password with skipAuth and saves {token, record}',
        () async {
      final store = MemoryAuthStore()..save('stale-token', {'id': 'old'});
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'token': 'new-token',
              'record': {'id': 'u1', 'email': 'a@b.com'}
            }),
            200),
      ], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      final res = await svc.authWithPassword('a@b.com', 'secret');

      expect(calls, hasLength(1));
      expect(calls[0].method, 'POST');
      expect(calls[0].path, '/api/collections/users/auth-with-password');
      expect(jsonDecode(calls[0].body),
          {'identity': 'a@b.com', 'password': 'secret'});
      // skipAuth: true means the (stale) bearer token must not be sent.
      expect(calls[0].hasAuthHeader, isFalse);

      expect(res.token, 'new-token');
      expect(res.record?.id, 'u1');
      expect(store.token, 'new-token');
      expect(store.record?['id'], 'u1');
    });
  });

  group('authRefresh', () {
    test('POSTs auth-refresh with an empty body and saves the response',
        () async {
      final store = MemoryAuthStore()..save('old-token', {'id': 'u1'});
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'token': 'refreshed',
              'record': {'id': 'u1'}
            }),
            200),
      ], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      final res = await svc.authRefresh();

      expect(calls[0].method, 'POST');
      expect(calls[0].path, '/api/collections/users/auth-refresh');
      expect(jsonDecode(calls[0].body), <String, dynamic>{});
      // Not skipAuth: the existing bearer token IS sent.
      expect(calls[0].hasAuthHeader, isTrue);
      expect(res.token, 'refreshed');
      expect(store.token, 'refreshed');
    });
  });

  group('authWithOAuth2', () {
    test(
        'posts the exact body, skipAuth, saves token with null record, returns token',
        () async {
      final store = MemoryAuthStore();
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode({'token': 'oauth-token'}), 200),
      ], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      final token = await svc.authWithOAuth2(
        provider: 'google',
        code: 'c',
        codeVerifier: 'v',
        redirectUrl: 'https://app/cb',
        state: 's1',
      );

      expect(calls[0].method, 'POST');
      expect(calls[0].path, '/api/collections/users/auth/oauth2/complete');
      expect(jsonDecode(calls[0].body), {
        'provider': 'google',
        'code': 'c',
        'codeVerifier': 'v',
        'redirectUrl': 'https://app/cb',
        'state': 's1',
      });
      expect(calls[0].hasAuthHeader, isFalse);
      expect(token, 'oauth-token');
      expect(store.token, 'oauth-token');
      expect(store.record, isNull);
    });

    test('omits state from the body when not provided', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode({'token': 't'}), 200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'users');

      await svc.authWithOAuth2(
        provider: 'google',
        code: 'c',
        codeVerifier: 'v',
        redirectUrl: 'https://app/cb',
      );

      final decoded = jsonDecode(calls[0].body) as Map<String, dynamic>;
      expect(decoded.containsKey('state'), isFalse);
    });
  });

  group('oauth2Init', () {
    test('POSTs auth/oauth2/initiate with {provider} and parses the response',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'authURL': 'https://p/auth',
              'clientId': 'cid',
              'scopes': ['a', 'b'],
              'state': 'st'
            }),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'users');

      final res = await svc.oauth2Init('google');

      expect(calls[0].method, 'POST');
      expect(calls[0].path, '/api/collections/users/auth/oauth2/initiate');
      expect(jsonDecode(calls[0].body), {'provider': 'google'});
      expect(res.authUrl, 'https://p/auth');
      expect(res.clientId, 'cid');
      expect(res.scopes, ['a', 'b']);
      expect(res.state, 'st');
    });
  });

  group('listAuthProviders', () {
    test('GETs auth/oauth2/providers and unwraps {items}', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'items': [
                {
                  'name': 'google',
                  'authURL': 'https://g/auth',
                  'clientId': 'cid',
                  'scopes': ['openid']
                },
              ]
            }),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'users');

      final providers = await svc.listAuthProviders();

      expect(calls[0].method, 'GET');
      expect(calls[0].path, '/api/collections/users/auth/oauth2/providers');
      expect(providers, hasLength(1));
      expect(providers[0].name, 'google');
      expect(providers[0].authUrl, 'https://g/auth');
      expect(providers[0].clientId, 'cid');
      expect(providers[0].scopes, ['openid']);
    });
  });

  group('logout', () {
    test('POSTs auth-logout and clears the store', () async {
      final store = MemoryAuthStore()..save('t', {'id': 'u1'});
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response('', 204)], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      await svc.logout();

      expect(calls[0].method, 'POST');
      expect(calls[0].path, '/api/collections/users/auth-logout');
      expect(store.token, isNull);
      expect(store.record, isNull);
    });

    test('clears the store even when the server request errors', () async {
      final store = MemoryAuthStore()..save('t', {'id': 'u1'});
      final transport = _scripted(
          [http.Response('{"message":"boom"}', 500)], [],
          authStore: store);
      final svc = CollectionService(transport, store, 'users');

      await expectLater(svc.logout(), throwsA(isA<ZigbaseException>()));
      expect(store.token, isNull);
      expect(store.record, isNull);
    });
  });

  group('verification + password reset', () {
    test('requestVerification POSTs {email}, not skipAuth', () async {
      final store = MemoryAuthStore()..save('t', {'id': 'u1'});
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response('', 204)], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      await svc.requestVerification('a@b.com');

      expect(calls[0].path, '/api/collections/users/request-verification');
      expect(jsonDecode(calls[0].body), {'email': 'a@b.com'});
      expect(calls[0].hasAuthHeader, isTrue);
    });

    test('confirmVerification POSTs {token} with skipAuth', () async {
      final store = MemoryAuthStore()..save('t', {'id': 'u1'});
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response('', 204)], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      await svc.confirmVerification('vtok');

      expect(calls[0].path, '/api/collections/users/confirm-verification');
      expect(jsonDecode(calls[0].body), {'token': 'vtok'});
      expect(calls[0].hasAuthHeader, isFalse);
    });

    test('requestPasswordReset POSTs {email}, not skipAuth', () async {
      final calls = <_Call>[];
      final transport = _scripted([http.Response('', 204)], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'users');

      await svc.requestPasswordReset('a@b.com');

      expect(calls[0].path, '/api/collections/users/request-password-reset');
      expect(jsonDecode(calls[0].body), {'email': 'a@b.com'});
    });

    test('confirmPasswordReset POSTs {token, password} with skipAuth',
        () async {
      final store = MemoryAuthStore()..save('t', {'id': 'u1'});
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response('', 204)], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      await svc.confirmPasswordReset('rtok', 'newpass');

      expect(calls[0].path, '/api/collections/users/confirm-password-reset');
      expect(
          jsonDecode(calls[0].body), {'token': 'rtok', 'password': 'newpass'});
      expect(calls[0].hasAuthHeader, isFalse);
    });
  });

  group('changePassword', () {
    test(
        'PATCHes the record with {password, oldPassword}; no re-auth for a non-principal id',
        () async {
      final store = MemoryAuthStore()
        ..save('t', {'id': 'someone-else', 'email': 'x@y.com'});
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode({'id': 'target', 'email': 'z@z.com'}), 200),
      ], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      final rec = await svc.changePassword('target', 'oldpw', 'newpw');

      expect(calls, hasLength(1)); // no follow-up authWithPassword call
      expect(calls[0].method, 'PATCH');
      expect(calls[0].path, '/api/collections/users/records/target');
      expect(jsonDecode(calls[0].body),
          {'password': 'newpw', 'oldPassword': 'oldpw'});
      expect(rec.id, 'target');
    });

    test(
        're-authenticates using the email identity when the store IS the target principal',
        () async {
      final store = MemoryAuthStore()
        ..save('t', {'id': 'target', 'email': 'z@z.com', 'username': 'zed'});
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({'id': 'target', 'email': 'z@z.com'}), 200), // PATCH
        http.Response(
            jsonEncode({
              'token': 're-token',
              'record': {'id': 'target', 'email': 'z@z.com'}
            }),
            200), // re-auth
      ], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      final rec = await svc.changePassword('target', 'oldpw', 'newpw');

      expect(calls, hasLength(2));
      expect(calls[0].method, 'PATCH');
      expect(calls[1].method, 'POST');
      expect(calls[1].path, '/api/collections/users/auth-with-password');
      expect(jsonDecode(calls[1].body),
          {'identity': 'z@z.com', 'password': 'newpw'});
      expect(rec.id, 'target');
      expect(store.token, 're-token');
    });

    test('falls back to the username identity when email is absent', () async {
      final store = MemoryAuthStore()
        ..save('t', {'id': 'target', 'username': 'zed'});
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({'id': 'target', 'username': 'zed'}), 200), // PATCH
        http.Response(
            jsonEncode({
              'token': 're-token',
              'record': {'id': 'target'}
            }),
            200), // re-auth
      ], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      await svc.changePassword('target', 'oldpw', 'newpw');

      expect(calls, hasLength(2));
      expect(
          jsonDecode(calls[1].body), {'identity': 'zed', 'password': 'newpw'});
    });

    test('does not re-auth when no principal is stored at all', () async {
      final store = MemoryAuthStore();
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode({'id': 'target'}), 200),
      ], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      await svc.changePassword('target', 'oldpw', 'newpw');

      expect(calls, hasLength(1));
    });
  });

  group('sessions', () {
    test(
        'listSessions GETs auth/sessions and unwraps {items} (snake_case wire keys)',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 'sid1',
                  'created': '2026-01-01T00:00:00Z',
                  'last_seen': '2026-01-02T00:00:00Z',
                  'user_agent': 'ua',
                  'ip': '1.2.3.4',
                  'is_current': true,
                },
              ]
            }),
            200),
      ], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'users');

      final sessions = await svc.listSessions();

      expect(calls[0].method, 'GET');
      expect(calls[0].path, '/api/collections/users/auth/sessions');
      expect(sessions, hasLength(1));
      expect(sessions[0].id, 'sid1');
      expect(sessions[0].lastSeen, '2026-01-02T00:00:00Z');
      expect(sessions[0].userAgent, 'ua');
      expect(sessions[0].isCurrent, isTrue);
    });

    test('revokeSession DELETEs auth/sessions/:id (uri-encoded)', () async {
      final calls = <_Call>[];
      final transport = _scripted([http.Response('', 204)], calls);
      final svc = CollectionService(transport, MemoryAuthStore(), 'users');

      await svc.revokeSession('sid with space');

      expect(calls[0].method, 'DELETE');
      expect(calls[0].path,
          '/api/collections/users/auth/sessions/sid%20with%20space');
    });

    test(
        'revokeAllSessions DELETEs auth/sessions and clears the store even on failure',
        () async {
      final store = MemoryAuthStore()..save('t', {'id': 'u1'});
      final transport = _scripted(
          [http.Response('{"message":"boom"}', 500)], [],
          authStore: store);
      final svc = CollectionService(transport, store, 'users');

      await expectLater(
          svc.revokeAllSessions(), throwsA(isA<ZigbaseException>()));
      expect(store.token, isNull);
    });

    test('revokeAllSessions clears the store on success too', () async {
      final store = MemoryAuthStore()..save('t', {'id': 'u1'});
      final calls = <_Call>[];
      final transport =
          _scripted([http.Response('', 204)], calls, authStore: store);
      final svc = CollectionService(transport, store, 'users');

      await svc.revokeAllSessions();

      expect(calls[0].method, 'DELETE');
      expect(calls[0].path, '/api/collections/users/auth/sessions');
      expect(store.token, isNull);
    });
  });

  group('collection name encoding', () {
    test('uri-encodes the collection name in the path', () async {
      final calls = <_Call>[];
      final transport = _scripted([http.Response('', 204)], calls);
      final svc =
          CollectionService(transport, MemoryAuthStore(), 'weird name/x');

      await svc.requestPasswordReset('a@b.com');

      expect(calls[0].path, contains(Uri.encodeComponent('weird name/x')));
    });
  });
}
