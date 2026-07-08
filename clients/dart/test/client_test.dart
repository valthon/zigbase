import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

import 'support/fake_socket.dart';

class _Call {
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String body;

  _Call(this.method, this.url, this.headers, this.body);
}

/// Scripts a sequence of canned [responses] behind a [MockClient], recording
/// every request into [calls].
http.Client _mock(List<http.Response> responses, List<_Call> calls) {
  var i = 0;
  return MockClient((req) async {
    calls.add(_Call(req.method, req.url, req.headers, req.body));
    final res = responses[i];
    i++;
    return res;
  });
}

/// Wraps an [http.Client] and counts [close] calls, so tests can verify
/// *whether* a given [ZigbaseClient.close] propagated to the shared client —
/// `MockClient.close()` is a no-op inherited from `BaseClient` and cannot
/// itself distinguish "closed" from "not closed".
class _TrackingClient extends http.BaseClient {
  final http.Client _inner;
  int closeCalls = 0;

  _TrackingClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closeCalls++;
    _inner.close();
  }
}

void main() {
  group('ZigbaseClient construction', () {
    test('defaults to a MemoryAuthStore', () {
      final client = ZigbaseClient('http://api.test');
      expect(client.authStore, isA<MemoryAuthStore>());
    });

    test('uses a caller-supplied AuthStore instead of the default', () {
      final store = MemoryAuthStore();
      final client = ZigbaseClient('http://api.test', authStore: store);
      expect(client.authStore, same(store));
    });

    test('strips trailing slashes from baseUrl', () {
      final client = ZigbaseClient('http://api.test///');
      expect(client.baseUrl, 'http://api.test');
    });
  });

  group('ZigbaseClient.collection', () {
    test('caches by name: repeated calls return the identical instance', () {
      final client = ZigbaseClient('http://api.test');
      final a1 = client.collection('posts');
      final a2 = client.collection('posts');
      final b = client.collection('comments');
      expect(identical(a1, a2), isTrue);
      expect(identical(a1, b), isFalse);
      expect(a1.name, 'posts');
      expect(b.name, 'comments');
    });
  });

  group('ZigbaseClient service getters', () {
    test('files/accounts/analytics/senders are lazy and cached', () {
      final client = ZigbaseClient('http://api.test');
      expect(identical(client.files, client.files), isTrue);
      expect(identical(client.accounts, client.accounts), isTrue);
      expect(identical(client.analytics, client.analytics), isTrue);
      expect(identical(client.senders, client.senders), isTrue);
    });

    test('realtime is lazy and cached (single instance)', () {
      final factory = FakeSocketFactory();
      final client =
          ZigbaseClient('http://api.test', webSocketConnector: factory.connect);
      final r1 = client.realtime;
      final r2 = client.realtime;
      expect(identical(r1, r2), isTrue);
      // Accessing the getter alone must not open a socket.
      expect(factory.connections, isEmpty);
    });
  });

  group('ZigbaseClient onRealtimeError', () {
    test(
        'an unconsumed realtime error frame reaches the constructor-supplied '
        'onRealtimeError (not silently dropped)', () async {
      final factory = FakeSocketFactory();
      final errors = <Object>[];
      final client = ZigbaseClient(
        'http://api.test',
        webSocketConnector: factory.connect,
        onRealtimeError: errors.add,
      );
      addTearDown(client.close);

      final subFut = client.realtime.subscribe('posts', (_) {});
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;

      // No pending subscribe is left to reject this error frame — without
      // the facade wiring onRealtimeError through, it would be dropped.
      ws.push({'type': 'error', 'message': 'boom'});
      await pumpEventQueue();

      expect(errors, contains('boom'));
    });

    test('defaultRealtimeErrorLog does not throw (the facade default)', () {
      expect(
          () => defaultRealtimeErrorLog(StateError('boom')), returnsNormally);
    });

    test('withAccount siblings inherit the parent\'s onRealtimeError',
        () async {
      final factory = FakeSocketFactory();
      final errors = <Object>[];
      final client = ZigbaseClient(
        'http://api.test',
        webSocketConnector: factory.connect,
        onRealtimeError: errors.add,
      );
      addTearDown(client.close);
      final sibling = client.withAccount('acct-1');

      final subFut = sibling.realtime.subscribe('posts', (_) {});
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;

      ws.push({'type': 'error', 'message': 'sibling-boom'});
      await pumpEventQueue();

      expect(errors, contains('sibling-boom'));
    });
  });

  group('ZigbaseClient.send', () {
    test('delegates to the transport, attaching the bearer token', () async {
      final calls = <_Call>[];
      final client = ZigbaseClient(
        'http://api.test',
        httpClient: _mock(
          [
            http.Response(jsonEncode({'ok': true}), 200)
          ],
          calls,
        ),
      );
      client.authStore.save('tok123', null);

      final result = await client.send('GET', '/api/health');

      expect(calls, hasLength(1));
      expect(calls[0].method, 'GET');
      expect(calls[0].url.toString(), 'http://api.test/api/health');
      expect(calls[0].headers['authorization'], 'Bearer tok123');
      expect(result, {'ok': true});
    });

    test('forwards query/body/headers/requestKey to the transport', () async {
      final calls = <_Call>[];
      final client = ZigbaseClient(
        'http://api.test',
        httpClient: _mock(
          [
            http.Response(jsonEncode({'created': true}), 201)
          ],
          calls,
        ),
      );

      final result = await client.send(
        'POST',
        '/api/collections/posts/records',
        query: {'expand': 'author'},
        body: {'title': 'hi'},
        headers: {'X-Test': '1'},
      );

      expect(calls[0].method, 'POST');
      expect(calls[0].url.path, '/api/collections/posts/records');
      expect(calls[0].url.queryParameters['expand'], 'author');
      expect(jsonDecode(calls[0].body), {'title': 'hi'});
      expect(calls[0].headers['x-test'], '1');
      expect(result, {'created': true});
    });
  });

  group('ZigbaseClient.rawRequest', () {
    test('returns the http.Response as-is, without throwing, on non-2xx',
        () async {
      final calls = <_Call>[];
      final client = ZigbaseClient(
        'http://api.test',
        httpClient: _mock(
          [http.Response('{"message":"nope"}', 404)],
          calls,
        ),
      );

      final res = await client.rawRequest('GET', '/api/missing');

      expect(res.statusCode, 404);
      expect(res.body, '{"message":"nope"}');
    });
  });

  group('ZigbaseClient.withAccount', () {
    test('shares the authStore but scopes requests with a new X-Account-Id',
        () async {
      final calls = <_Call>[];
      final client = ZigbaseClient(
        'http://api.test',
        httpClient: _mock(
          [
            http.Response(jsonEncode({'n': 1}), 200),
            http.Response(jsonEncode({'n': 2}), 200),
          ],
          calls,
        ),
        accountId: 'parent-acct',
      );
      client.authStore.save('shared-tok', {'id': 'u1'});

      final sibling = client.withAccount('acct-42');

      expect(identical(sibling.authStore, client.authStore), isTrue);
      expect(sibling.baseUrl, client.baseUrl);

      await client.send('GET', '/api/health');
      await sibling.send('GET', '/api/health');

      expect(calls, hasLength(2));
      expect(calls[0].headers['x-account-id'], 'parent-acct');
      expect(calls[1].headers['x-account-id'], 'acct-42');
      // The sibling still carries the shared bearer token.
      expect(calls[1].headers['authorization'], 'Bearer shared-tok');
    });

    test('collection() on a sibling is independent of the parent\'s cache', () {
      final client = ZigbaseClient('http://api.test');
      final sibling = client.withAccount('acct-1');
      expect(identical(client.collection('posts'), sibling.collection('posts')),
          isFalse);
    });
  });

  group('ZigbaseClient autoRefresh + authCollection', () {
    test('401 triggers POST auth-refresh then retries the original request',
        () async {
      final calls = <_Call>[];
      var i = 0;
      final httpClient = MockClient((req) async {
        calls.add(_Call(req.method, req.url, req.headers, req.body));
        final res = switch (i) {
          0 => http.Response('{"message":"unauthorized"}', 401),
          1 => http.Response(
              jsonEncode({
                'token': 'new-tok',
                'record': {'id': 'u1', 'collectionName': 'users'},
              }),
              200),
          _ => http.Response(jsonEncode({'id': 'p1'}), 200),
        };
        i++;
        return res;
      });

      final client = ZigbaseClient(
        'http://api.test',
        httpClient: httpClient,
        autoRefresh: true,
        authCollection: 'users',
      );
      client.authStore.save('stale-tok', null);

      final result = await client.collection('posts').getOne('p1');

      expect(calls, hasLength(3));
      expect(calls[0].url.path, '/api/collections/posts/records/p1');
      expect(calls[0].headers['authorization'], 'Bearer stale-tok');
      expect(calls[1].url.path, '/api/collections/users/auth-refresh');
      expect(calls[1].headers['authorization'], 'Bearer stale-tok');
      expect(calls[2].url.path, '/api/collections/posts/records/p1');
      expect(calls[2].headers['authorization'], 'Bearer new-tok');
      expect(result.id, 'p1');
      expect(client.authStore.token, 'new-tok');
    });
  });

  group('ZigbaseClient.close', () {
    test('is idempotent and safe to call twice', () async {
      final client = ZigbaseClient('http://api.test');
      await client.close();
      await client.close();
    });

    test('closes the underlying http client', () async {
      final tracker =
          _TrackingClient(MockClient((req) async => http.Response('{}', 200)));
      final client = ZigbaseClient('http://api.test', httpClient: tracker);
      await client.close();
      expect(tracker.closeCalls, 1);
    });

    test('disposes an owned (default) AuthStore', () async {
      final client = ZigbaseClient('http://api.test');
      final events = <AuthEvent>[];
      client.authStore.onChange.listen(events.add);
      await client.close();
      // The controller is closed; further save()s no longer emit.
      client.authStore.save('tok', null);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
    });

    test('does NOT dispose a caller-supplied AuthStore', () async {
      final store = MemoryAuthStore();
      final client = ZigbaseClient('http://api.test', authStore: store);
      final events = <AuthEvent>[];
      store.onChange.listen(events.add);
      await client.close();
      store.save('tok', null);
      await Future<void>.delayed(Duration.zero);
      expect(events, hasLength(1));
    });

    test(
        'closing a sibling does not close the shared http client; closing '
        'the parent does', () async {
      final tracker =
          _TrackingClient(MockClient((req) async => http.Response('{}', 200)));
      final client = ZigbaseClient('http://api.test', httpClient: tracker);
      final sibling = client.withAccount('acct-1');

      await sibling.close();
      expect(tracker.closeCalls, 0);

      await client.close();
      expect(tracker.closeCalls, 1);
    });

    test('closes realtime only if it was created', () async {
      final factory = FakeSocketFactory();
      final client =
          ZigbaseClient('http://api.test', webSocketConnector: factory.connect);
      // Never touched client.realtime -> nothing to close, no throw.
      await client.close();
    });
  });

  group('ZigbaseClient after close()', () {
    test('realtime throws StateError (no service can leak past teardown)',
        () async {
      final factory = FakeSocketFactory();
      final client =
          ZigbaseClient('http://api.test', webSocketConnector: factory.connect);
      await client.close();
      expect(() => client.realtime, throwsStateError);
      // Idempotent second close is still fine, and nothing was ever minted.
      await client.close();
      expect(factory.connections, isEmpty);
    });

    test('send and rawRequest throw StateError', () async {
      final client = ZigbaseClient(
        'http://api.test',
        httpClient: MockClient((req) async => http.Response('{}', 200)),
      );
      await client.close();
      expect(() => client.send('GET', '/x'), throwsStateError);
      expect(() => client.rawRequest('GET', '/x'), throwsStateError);
    });

    test('collection, service getters, and withAccount throw StateError',
        () async {
      final client = ZigbaseClient('http://api.test');
      await client.close();
      expect(() => client.collection('posts'), throwsStateError);
      expect(() => client.files, throwsStateError);
      expect(() => client.accounts, throwsStateError);
      expect(() => client.analytics, throwsStateError);
      expect(() => client.senders, throwsStateError);
      expect(() => client.withAccount('acct-1'), throwsStateError);
    });

    test('a closed sibling throws while the parent keeps working', () async {
      final calls = <_Call>[];
      final client = ZigbaseClient(
        'http://api.test',
        httpClient: _mock([http.Response('{}', 200)], calls),
      );
      final sibling = client.withAccount('acct-1');
      await sibling.close();
      expect(() => sibling.send('GET', '/x'), throwsStateError);
      await client.send('GET', '/x'); // the parent is unaffected
      expect(calls, hasLength(1));
    });
  });
}
