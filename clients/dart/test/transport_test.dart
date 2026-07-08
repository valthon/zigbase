import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zigbase_client/src/auth_store.dart';
import 'package:zigbase_client/src/errors.dart';
import 'package:zigbase_client/src/transport.dart';

/// Pump the microtask/event queue until [cond] is true (or a bounded number of
/// turns elapse), so tests can wait for an in-flight request to reach the
/// [MockClient] handler without real delays.
Future<void> _pumpUntil(bool Function() cond, {int max = 2000}) async {
  var n = 0;
  while (!cond() && n < max) {
    await Future<void>.delayed(Duration.zero);
    n++;
  }
}

Transport _transport(
  http.Client client, {
  String baseUrl = 'http://api.test',
  AuthStore? authStore,
  bool autoRefresh = false,
  int maxRetries = 3,
  String? lang,
  String? accountId,
  Future<void> Function()? refresh,
  Future<void> Function(Duration)? sleep,
}) {
  return Transport(
    baseUrl: baseUrl,
    authStore: authStore ?? MemoryAuthStore(),
    httpClient: client,
    autoRefresh: autoRefresh,
    maxRetries: maxRetries,
    lang: lang,
    accountId: accountId,
    refresh: refresh,
    sleep: sleep,
  );
}

void main() {
  group('buildUrl', () {
    test('joins base + path, skips null query values, url-encodes', () {
      final t = _transport(MockClient((_) async => http.Response('', 204)),
          baseUrl: 'http://api.test/');
      final u = t.buildUrl('/api/x', {'a': 1, 'b': null, 'c': 'hello world'});
      expect(u.host, 'api.test');
      expect(u.path, '/api/x');
      expect(u.queryParameters, {'a': '1', 'c': 'hello world'});
    });

    test('passes an absolute http(s) path through unchanged', () {
      final t = _transport(MockClient((_) async => http.Response('', 204)));
      final u = t.buildUrl('https://other.test/thing', {'q': '1'});
      expect(u.host, 'other.test');
      expect(u.path, '/thing');
      expect(u.queryParameters, {'q': '1'});
    });

    test('no query yields a clean url', () {
      final t = _transport(MockClient((_) async => http.Response('', 204)));
      expect(t.buildUrl('/api/x').toString(), 'http://api.test/api/x');
    });

    test('inserts a separator for a relative path without a leading slash', () {
      final t = _transport(MockClient((_) async => http.Response('', 204)));
      expect(t.buildUrl('api/x').toString(), t.buildUrl('/api/x').toString());
      expect(t.buildUrl('api/x').toString(), 'http://api.test/api/x');
    });

    test(
        'a query key duplicating one already in the path is appended, not '
        'overwritten (both values survive)', () {
      final t = _transport(MockClient((_) async => http.Response('', 204)));
      final u = t.buildUrl('/api/x?a=1', {'a': 2, 'b': 'new'});
      expect(u.queryParametersAll['a'], ['1', '2']);
      expect(u.queryParametersAll['b'], ['new']);
    });
  });

  group('headers', () {
    test('sends bearer + accept-language + account header', () async {
      final store = MemoryAuthStore()..save('the.jwt.token', {'id': 'u1'});
      late http.Request seen;
      final t = _transport(
        MockClient((req) async {
          seen = req;
          return http.Response('{"ok":true}', 200);
        }),
        authStore: store,
        lang: 'fr-CA',
        accountId: 'acct-9',
      );
      await t.send('/api/x');
      expect(seen.headers['authorization'], 'Bearer the.jwt.token');
      expect(seen.headers['accept-language'], 'fr-CA');
      expect(seen.headers['x-account-id'], 'acct-9');
    });

    test('skipAuth omits the bearer header', () async {
      final store = MemoryAuthStore()..save('the.jwt.token', {'id': 'u1'});
      late http.Request seen;
      final t = _transport(MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      }), authStore: store);
      await t.send('/api/x', skipAuth: true);
      expect(seen.headers.containsKey('authorization'), isFalse);
    });

    test('per-request X-Account-Id wins over the configured accountId',
        () async {
      late http.Request seen;
      final t = _transport(
        MockClient((req) async {
          seen = req;
          return http.Response('{}', 200);
        }),
        accountId: 'default-acct',
      );
      await t.send('/api/x', headers: {'X-Account-Id': 'override'});
      expect(seen.headers['x-account-id'], 'override');
    });
  });

  group('body', () {
    test('json body sets content-type and encodes', () async {
      late http.Request seen;
      final t = _transport(MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      }));
      await t.send('/api/x', method: 'POST', body: {'title': 'hi', 'n': 3});
      expect(seen.headers['content-type'], contains('application/json'));
      expect(seen.body, '{"title":"hi","n":3}');
      expect(seen.method, 'POST');
    });

    test('list body encodes as json', () async {
      late http.Request seen;
      final t = _transport(MockClient((req) async {
        seen = req;
        return http.Response('[]', 200);
      }));
      await t.send('/api/x', method: 'POST', body: [1, 2, 3]);
      expect(seen.headers['content-type'], contains('application/json'));
      expect(seen.body, '[1,2,3]');
    });

    test('String body is JSON-encoded (a quoted string literal), not sent raw',
        () async {
      late http.Request seen;
      final t = _transport(MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      }));
      await t.send('/api/x', method: 'POST', body: 'hi');
      expect(seen.headers['content-type'], contains('application/json'));
      expect(seen.body, '"hi"');
    });

    test('num body is JSON-encoded bare', () async {
      late http.Request seen;
      final t = _transport(MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      }));
      await t.send('/api/x', method: 'POST', body: 5);
      expect(seen.headers['content-type'], contains('application/json'));
      expect(seen.body, '5');
    });

    test(
        'a DateTime nested in a JSON body encodes as a ms-clamped UTC '
        'ISO-8601 string (no JsonUnsupportedObjectError)', () async {
      late http.Request seen;
      final t = _transport(MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      }));
      final when = DateTime.utc(2026, 7, 8, 12, 34, 56, 789, 654);
      await t.send('/api/x', method: 'POST', body: {
        'title': 'hi',
        'publishedAt': when,
        'nested': {
          'times': [when],
        },
      });
      expect(seen.headers['content-type'], contains('application/json'));
      expect(
          seen.body,
          '{"title":"hi","publishedAt":"2026-07-08T12:34:56.789Z",'
          '"nested":{"times":["2026-07-08T12:34:56.789Z"]}}');
    });

    test(
        'a non-encodable object in a JSON body throws ArgumentError, not '
        'JsonUnsupportedObjectError', () async {
      final t = _transport(MockClient((_) async => http.Response('{}', 200)));
      await expectLater(
        t.send('/api/x', method: 'POST', body: {'bad': Object()}),
        throwsA(isA<ArgumentError>()
            .having((e) => e.message, 'message', contains('Object'))),
      );
    });

    test('GET does not send a body even if one is provided', () async {
      late http.Request seen;
      final t = _transport(MockClient((req) async {
        seen = req;
        return http.Response('{}', 200);
      }));
      await t.send('/api/x', body: {'ignored': true});
      expect(seen.body, isEmpty);
    });

    test('multipart when body has a MultipartFile (fields + repeated + file)',
        () async {
      late http.Request seen;
      final t = _transport(MockClient((req) async {
        seen = req;
        return http.Response('{"ok":true}', 200);
      }));
      final file = http.MultipartFile.fromString('avatar', 'IMGBYTES',
          filename: 'a.png');
      await t.send('/api/x', method: 'POST', body: {
        'name': 'bob',
        'tags': ['x', 'y'],
        'avatar': file,
      });
      expect(seen.headers['content-type'], contains('multipart/form-data'));
      final b = seen.body;
      // single-value scalar -> a form field
      expect(b, contains('name="name"'));
      expect(b, contains('bob'));
      // repeated scalar -> two filename-less parts under the same key
      expect(b, contains('IMGBYTES'));
      expect('name="avatar"; filename="a.png"'.allMatches(b).length, 1);
      final tagParts = 'name="tags"'.allMatches(b).length;
      expect(tagParts, 2,
          reason: 'repeated scalar key must emit one part per value');
      // the repeated tag parts must NOT carry a filename (else the server treats
      // them as file uploads instead of form fields)
      expect(b, isNot(contains('name="tags"; filename')));
    });
  });

  group('multipart across retries', () {
    test('401 refresh retry re-sends the file part intact', () async {
      final bodies = <String>[];
      var calls = 0;
      var refreshed = 0;
      final t = _transport(
        MockClient((req) async {
          calls++;
          bodies.add(req.body);
          return calls == 1
              ? http.Response('{"message":"unauthorized"}', 401)
              : http.Response('{"ok":true}', 200);
        }),
        autoRefresh: true,
      )..refresh = () async {
          refreshed++;
        };
      final out = await t.send('/api/x', method: 'POST', body: {
        'title': 'x',
        'avatar': http.MultipartFile.fromString('avatar', 'IMGBYTES',
            filename: 'a.png'),
      });
      expect(out, {'ok': true});
      expect(refreshed, 1);
      expect(calls, 2);
      // The SECOND request must still carry both the field and the file part.
      final second = bodies[1];
      expect(second, contains('name="title"'));
      expect(second, contains('x'));
      expect(second, contains('name="avatar"; filename="a.png"'));
      expect(second, contains('IMGBYTES'));
    });

    test('429 backoff retry re-sends the file part intact', () async {
      final bodies = <String>[];
      var calls = 0;
      final t = _transport(
        MockClient((req) async {
          calls++;
          bodies.add(req.body);
          return calls == 1
              ? http.Response('{"message":"slow"}', 429)
              : http.Response('{"ok":true}', 200);
        }),
        sleep: (_) async {},
      );
      final out = await t.send('/api/x', method: 'POST', body: {
        'title': 'x',
        'avatar': http.MultipartFile.fromString('avatar', 'IMGBYTES',
            filename: 'a.png'),
      });
      expect(out, {'ok': true});
      expect(calls, 2);
      final second = bodies[1];
      expect(second, contains('name="title"'));
      expect(second, contains('name="avatar"; filename="a.png"'));
      expect(second, contains('IMGBYTES'));
    });

    test(
        'a null-filename MultipartFile survives a 429 retry as a field part, '
        'not a file part', () async {
      final bodies = <String>[];
      var calls = 0;
      final t = _transport(
        MockClient((req) async {
          calls++;
          bodies.add(req.body);
          return calls == 1
              ? http.Response('{"message":"slow"}', 429)
              : http.Response('{"ok":true}', 200);
        }),
        sleep: (_) async {},
      );
      final out = await t.send('/api/x', method: 'POST', body: {
        // No `filename:` — the server treats a filename-less part as a plain
        // form field, even though package:http still models it as a
        // MultipartFile.
        'tag': http.MultipartFile.fromString('tag', 'value'),
      });
      expect(out, {'ok': true});
      expect(calls, 2);
      final second = bodies[1];
      expect(second, contains('name="tag"'));
      expect(second, contains('value'));
      expect(second, isNot(contains('name="tag"; filename')));
    });
  });

  group('2xx parsing', () {
    test('204 returns null', () async {
      final t = _transport(MockClient((_) async => http.Response('', 204)));
      expect(await t.send('/api/x'), isNull);
    });

    test('empty 200 body returns null', () async {
      final t = _transport(MockClient((_) async => http.Response('', 200)));
      expect(await t.send('/api/x'), isNull);
    });

    test('json 200 body decodes', () async {
      final t =
          _transport(MockClient((_) async => http.Response('{"a":1}', 200)));
      expect(await t.send('/api/x'), {'a': 1});
    });
  });

  group('errors', () {
    test('non-2xx throws ZigbaseException with parsed field data', () async {
      final t = _transport(MockClient((_) async => http.Response(
          '{"message":"bad","data":{"title":{"code":"required","message":"is required"}}}',
          400)));
      await expectLater(
        t.send('/api/x'),
        throwsA(isA<ZigbaseException>()
            .having((e) => e.status, 'status', 400)
            .having((e) => e.message, 'message', 'bad')
            .having((e) => e.data['title']?.code, 'field code', 'required')),
      );
    });
  });

  group('401 refresh', () {
    test('401 triggers one-shot refresh then retry', () async {
      var calls = 0;
      var refreshed = 0;
      final t = _transport(
        MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response('{"message":"unauthorized"}', 401)
              : http.Response('{"ok":true}', 200);
        }),
        autoRefresh: true,
      )..refresh = () async {
          refreshed++;
        };
      expect(await t.send('/api/x'), {'ok': true});
      expect(refreshed, 1);
      expect(calls, 2);
    });

    test('401 refresh is one-shot: a second 401 throws (no infinite loop)',
        () async {
      var calls = 0;
      var refreshed = 0;
      final t = _transport(
        MockClient((_) async {
          calls++;
          return http.Response('{"message":"nope"}', 401);
        }),
        autoRefresh: true,
      )..refresh = () async {
          refreshed++;
        };
      await expectLater(t.send('/api/x'), throwsA(isA<ZigbaseException>()));
      expect(refreshed, 1);
      expect(calls, 2);
    });

    test(
        'single-flight: a parallel 401 burst performs ONE refresh and all requests succeed',
        () async {
      // Token expires; the app fires 3 parallel requests. All three 401. The
      // first starts the refresh; the other two must AWAIT that same refresh
      // (not skip it and fail, not start redundant ones) and then retry.
      var refreshed = false;
      var refreshCalls = 0;
      var fetches = 0;
      final gate = Completer<void>();
      final t = _transport(
        MockClient((_) async {
          fetches++;
          return refreshed
              ? http.Response('{"ok":true}', 200)
              : http.Response('{"message":"expired"}', 401);
        }),
        authStore: MemoryAuthStore()..save('stale-tok', {'id': 'u1'}),
        autoRefresh: true,
      )..refresh = () async {
          refreshCalls++;
          await gate
              .future; // hold the refresh open so every 401 lands during it
          refreshed = true;
        };

      final burst = [t.send('/api/a'), t.send('/api/b'), t.send('/api/c')];
      // Let all three 401s land and register on the shared in-flight refresh.
      await _pumpUntil(() => fetches == 3);
      expect(refreshCalls, 1); // not three redundant refreshes

      gate.complete();
      final out = await Future.wait(burst); // NO spurious failures
      expect(out, [
        {'ok': true},
        {'ok': true},
        {'ok': true}
      ]);
      expect(refreshCalls, 1);
      expect(fetches, 6); // 3 x 401 + 3 retried 200s
    });

    test(
        'a persistently-401ing refresh endpoint stays bounded: waiters reject, no recursion, no deadlock',
        () async {
      // The refresh callback issues its OWN (isRefreshCall-marked) request
      // through the transport, exactly like collection.authRefresh() does. When
      // that request also 401s, it must propagate — not await its own refresh
      // (deadlock) and not start another (unbounded recursion).
      var fetches = 0;
      var refreshCalls = 0;
      final refreshGate = Completer<void>();
      late Transport t;
      t = _transport(
        MockClient((req) async {
          fetches++;
          // Hold the auth-refresh response open until both waiters have joined.
          if (req.url.path.contains('auth-refresh')) await refreshGate.future;
          return http.Response('{"message":"expired"}', 401);
        }),
        authStore: MemoryAuthStore()..save('tok', {'id': 'u1'}),
        autoRefresh: true,
        refresh: () async {
          refreshCalls++;
          await t.send('/api/collections/users/auth-refresh',
              method: 'POST', isRefreshCall: true);
        },
      );

      final a = t.send('/api/a');
      final b = t.send('/api/b');
      // Attach expectations before releasing so neither rejection is ever
      // unhandled.
      final expectA = expectLater(a, throwsA(isA<ZigbaseException>()));
      final expectB = expectLater(b, throwsA(isA<ZigbaseException>()));
      await _pumpUntil(() => fetches == 3); // a + b + the one auth-refresh
      refreshGate.complete();

      await Future.wait([expectA, expectB]);
      // Bounded: one refresh; its own 401 propagated. No retries, no nested
      // refreshes.
      expect(refreshCalls, 1);
      expect(fetches, 3);
    });

    test('a failed refresh rejects every waiter with its ORIGINAL 401 error',
        () async {
      var fetches = 0;
      var refreshCalls = 0;
      final gate = Completer<void>();
      final t = _transport(
        MockClient((_) async {
          fetches++;
          return http.Response('{"message":"expired"}', 401);
        }),
        authStore: MemoryAuthStore()..save('tok', {'id': 'u1'}),
        autoRefresh: true,
      )..refresh = () async {
          refreshCalls++;
          await gate.future;
          throw StateError('refresh broke');
        };

      final a = t.send('/api/a');
      final b = t.send('/api/b');
      // The waiter's own 401 (a ZigbaseException, status 401) — NOT the
      // refresh's StateError.
      final is401 = isA<ZigbaseException>()
          .having((e) => e.status, 'status', 401)
          .having((e) => e.message, 'message', 'expired');
      final expectA = expectLater(a, throwsA(is401));
      final expectB = expectLater(b, throwsA(is401));
      await _pumpUntil(() => fetches == 2 && refreshCalls == 1);
      gate.complete();

      await Future.wait([expectA, expectB]);
      expect(refreshCalls, 1);
      expect(fetches, 2); // no retries after the failure
    });

    test('skipAuth does not refresh on 401', () async {
      var refreshed = 0;
      final t = _transport(
        MockClient((_) async => http.Response('{}', 401)),
        autoRefresh: true,
      )..refresh = () async {
          refreshed++;
        };
      await expectLater(
          t.send('/api/x', skipAuth: true), throwsA(isA<ZigbaseException>()));
      expect(refreshed, 0);
    });
  });

  group('429 backoff', () {
    test('honors a numeric Retry-After header verbatim then succeeds',
        () async {
      final delays = <Duration>[];
      var calls = 0;
      final t = _transport(
        MockClient((_) async {
          calls++;
          return calls == 1
              ? http.Response('{"message":"slow"}', 429,
                  headers: {'retry-after': '7'})
              : http.Response('{"ok":true}', 200);
        }),
        sleep: (d) async => delays.add(d),
      );
      expect(await t.send('/api/x'), {'ok': true});
      expect(delays, [const Duration(seconds: 7)]);
      expect(calls, 2);
    });

    test('exponential default backoff then gives up after maxRetries',
        () async {
      final delays = <Duration>[];
      var calls = 0;
      final t = _transport(
        MockClient((_) async {
          calls++;
          return http.Response('{"message":"slow"}', 429);
        }),
        maxRetries: 3,
        sleep: (d) async => delays.add(d),
      );
      await expectLater(
        t.send('/api/x'),
        throwsA(isA<ZigbaseException>().having((e) => e.status, 'status', 429)),
      );
      expect(delays, [
        const Duration(milliseconds: 200),
        const Duration(milliseconds: 400),
        const Duration(milliseconds: 800),
      ]);
      expect(calls, 4);
    });

    test('caps the exponential backoff at 30s', () async {
      final delays = <Duration>[];
      var calls = 0;
      final t = _transport(
        MockClient((_) async {
          calls++;
          return calls <= 20
              ? http.Response('{"message":"slow"}', 429)
              : http.Response('{"ok":true}', 200);
        }),
        maxRetries: 20,
        sleep: (d) async => delays.add(d),
      );
      await t.send('/api/x');
      expect(delays.every((d) => d <= const Duration(seconds: 30)), isTrue);
      expect(delays.contains(const Duration(seconds: 30)), isTrue);
    });
  });

  group('requestKey cancellation', () {
    test('a new request with the same key cancels the prior in-flight one',
        () async {
      final gates = <Completer<http.Response>>[];
      final t = _transport(MockClient((_) {
        final c = Completer<http.Response>();
        gates.add(c);
        return c.future;
      }));

      final first = t.send('/api/x', requestKey: 'k');
      // A real caller awaits promptly; attach the expectation before pumping so
      // the cancellation error is never momentarily unhandled.
      final firstDone =
          expectLater(first, throwsA(isA<ZigbaseCancelledException>()));
      await _pumpUntil(() => gates.length == 1);
      final second = t.send('/api/x', requestKey: 'k');
      await _pumpUntil(() => gates.length == 2);

      gates[1].complete(http.Response('{"ok":true}', 200));

      expect(await second, {'ok': true});
      await firstDone;

      // The stale first response arriving later must not surface as an
      // unhandled async error.
      gates[0].complete(http.Response('{"stale":true}', 200));
      await _pumpUntil(() => false, max: 10);
    });

    test('three rapid same-key requests: only the last survives', () async {
      final gates = <Completer<http.Response>>[];
      final t = _transport(MockClient((_) {
        final c = Completer<http.Response>();
        gates.add(c);
        return c.future;
      }));

      final r1 = t.send('/api/x', requestKey: 'k');
      final r1Done = expectLater(r1, throwsA(isA<ZigbaseCancelledException>()));
      await _pumpUntil(() => gates.length == 1);
      final r2 = t.send('/api/x', requestKey: 'k');
      final r2Done = expectLater(r2, throwsA(isA<ZigbaseCancelledException>()));
      await _pumpUntil(() => gates.length == 2);
      final r3 = t.send('/api/x', requestKey: 'k');
      await _pumpUntil(() => gates.length == 3);

      gates[2].complete(http.Response('{"v":3}', 200));

      expect(await r3, {'v': 3});
      await r1Done;
      await r2Done;

      // Late stale responses to the abandoned requests must be swallowed.
      gates[0].complete(http.Response('{"v":1}', 200));
      gates[1].complete(http.Response('{"v":2}', 200));
      await _pumpUntil(() => false, max: 10);
    });

    test('different keys do not cancel each other', () async {
      final t = _transport(
          MockClient((_) async => http.Response('{"ok":true}', 200)));
      final a = t.send('/api/x', requestKey: 'a');
      final b = t.send('/api/y', requestKey: 'b');
      expect(await a, {'ok': true});
      expect(await b, {'ok': true});
    });
  });

  group('raw', () {
    test('returns a non-2xx response without throwing', () async {
      final t = _transport(
          MockClient((_) async => http.Response('{"message":"boom"}', 500)));
      final res = await t.raw('/api/x');
      expect(res.statusCode, 500);
      expect(res.body, '{"message":"boom"}');
    });

    test('does not auto-refresh or retry', () async {
      var refreshed = 0;
      var calls = 0;
      final t = _transport(
        MockClient((_) async {
          calls++;
          return http.Response('{}', 401);
        }),
        autoRefresh: true,
      )..refresh = () async {
          refreshed++;
        };
      final res = await t.raw('/api/x');
      expect(res.statusCode, 401);
      expect(refreshed, 0);
      expect(calls, 1);
    });

    test('still applies the bearer header', () async {
      final store = MemoryAuthStore()..save('tok', {'id': 'u1'});
      late http.Request seen;
      final t = _transport(MockClient((req) async {
        seen = req;
        return http.Response('ok', 200);
      }), authStore: store);
      await t.raw('/api/x');
      expect(seen.headers['authorization'], 'Bearer tok');
    });
  });
}
