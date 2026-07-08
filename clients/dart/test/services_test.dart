import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zigbase_client/src/transport.dart';
import 'package:zigbase_client/zigbase_client.dart';

class _Call {
  final String method;
  final Uri url;
  final String body;

  _Call(this.method, this.url, this.body);
}

Transport _scripted(List<http.Response> responses, List<_Call> calls) {
  var i = 0;
  final client = MockClient((req) async {
    calls.add(_Call(req.method, req.url, req.body));
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

void main() {
  group('AccountsService.activate', () {
    test(
        'POSTs /api/accounts/:id/activate (id URL-encoded) and parses the scope',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode({'account': 'a/1', 'role': 'editor'}), 200),
      ], calls);
      final accounts = AccountsService(transport);

      final scope = await accounts.activate('a/1');

      expect(calls, hasLength(1));
      expect(calls[0].method, 'POST');
      expect(calls[0].url.toString(),
          'http://api.test/api/accounts/a%2F1/activate');
      expect(scope.account, 'a/1');
      expect(scope.role, 'editor');
    });
  });

  group('AnalyticsService.events', () {
    test('maps name/actor/since/limit/cursor to query params', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode({'items': <Map<String, dynamic>>[]}), 200),
      ], calls);
      final analytics = AnalyticsService(transport);

      await analytics.events(
        name: 'user.signup',
        actor: 'u1',
        since: '2026-01-02T03:04:05.000Z',
        limit: 10,
        cursor: '2026-01-01T00:00:02Z|e2',
      );

      final q = calls[0].url.queryParameters;
      expect(calls[0].url.path, '/api/analytics/events');
      expect(q['name'], 'user.signup');
      expect(q['actor'], 'u1');
      expect(q['since'], '2026-01-02T03:04:05.000Z');
      expect(q['limit'], '10');
      expect(q['cursor'], '2026-01-01T00:00:02Z|e2');
    });

    test('parses the {items, nextCursor, hasNext} cursor envelope', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'items': [
                {'id': 'e1'}
              ],
              'nextCursor': null,
              'hasNext': false,
            }),
            200),
      ], calls);
      final analytics = AnalyticsService(transport);

      final page = await analytics.events();

      expect(page.items, hasLength(1));
      expect(page.items[0]['id'], 'e1');
      expect(page.nextCursor, isNull);
      expect(page.hasNext, isFalse);
    });

    test('no options sends no query params', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode({'items': <Map<String, dynamic>>[]}), 200),
      ], calls);
      final analytics = AnalyticsService(transport);

      await analytics.events();

      expect(calls[0].url.queryParameters, isEmpty);
    });
  });

  group('AnalyticsService.rollup', () {
    test('hits /api/analytics/rollups/:name (name URL-encoded) with from/to',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'items': [
                {
                  'bucket': '2026-01-01',
                  'account': 'a',
                  'actor': '',
                  'value': 3,
                  'computed_at': 'x',
                }
              ]
            }),
            200),
      ], calls);
      final analytics = AnalyticsService(transport);

      final items = await analytics.rollup('signups daily',
          from: '2026-01-01', to: '2026-02-01');

      expect(calls[0].url.path, '/api/analytics/rollups/signups%20daily');
      expect(calls[0].url.queryParameters['from'], '2026-01-01');
      expect(calls[0].url.queryParameters['to'], '2026-02-01');
      expect(items, hasLength(1));
      expect(items[0]['value'], 3);
    });
  });

  group('SendersService.list', () {
    test('GETs /api/senders and parses the {items} envelope', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 's1',
                  'email': 'a@x.io',
                  'status': 'verified',
                  'verified_at': '2026-01-01 00:00:00',
                }
              ]
            }),
            200),
      ], calls);
      final senders = SendersService(transport);

      final out = await senders.list();

      expect(calls[0].method, 'GET');
      expect(calls[0].url.toString(), 'http://api.test/api/senders');
      expect(out, hasLength(1));
      expect(out[0].id, 's1');
      expect(out[0].email, 'a@x.io');
      expect(out[0].status, 'verified');
      expect(out[0].verifiedAt, '2026-01-01 00:00:00');
    });

    test('maps an empty verified_at to null', () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode({
              'items': [
                {
                  'id': 's2',
                  'email': 'b@x.io',
                  'status': 'pending',
                  'verified_at': '',
                }
              ]
            }),
            200),
      ], calls);
      final senders = SendersService(transport);

      final out = await senders.list();

      expect(out[0].verifiedAt, isNull);
    });
  });

  group('SendersService.create', () {
    test('POSTs the email and parses the create response (no verified_at)',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(
            jsonEncode(
                {'id': 's2', 'email': 'from@acct.io', 'status': 'pending'}),
            201),
      ], calls);
      final senders = SendersService(transport);

      final out = await senders.create('from@acct.io');

      expect(calls[0].method, 'POST');
      expect(calls[0].url.toString(), 'http://api.test/api/senders');
      expect(jsonDecode(calls[0].body), {'email': 'from@acct.io'});
      expect(out.email, 'from@acct.io');
      expect(out.status, 'pending');
      expect(out.verifiedAt, isNull);
    });
  });

  group('SendersService.verify', () {
    test('POSTs the token to /api/senders/:id/verify (id URL-encoded)',
        () async {
      final calls = <_Call>[];
      final transport = _scripted([
        http.Response(jsonEncode({'verified': true}), 200),
      ], calls);
      final senders = SendersService(transport);

      final ok = await senders.verify('s2', 'tok');

      expect(calls[0].method, 'POST');
      expect(calls[0].url.toString(), 'http://api.test/api/senders/s2/verify');
      expect(jsonDecode(calls[0].body), {'token': 'tok'});
      expect(ok, isTrue);
    });
  });
}
