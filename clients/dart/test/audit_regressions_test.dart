import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';
import 'package:zigbase_client/src/transport.dart';

import 'live/fakes.dart';

void main() {
  test('old-token 401 joins a pending newer refresh before retrying', () async {
    final auth = MemoryAuthStore()..save('T0', null);
    final delayedStarted = Completer<void>();
    final releaseDelayed = Completer<void>();
    final secondRefreshStarted = Completer<void>();
    final releaseSecondRefresh = Completer<void>();
    final delayedTokens = <String?>[];
    var refreshes = 0;
    final transport = Transport(
      baseUrl: 'http://test',
      authStore: auth,
      autoRefresh: true,
      maxRetries: 0,
      httpClient: MockClient((req) async {
        final token = req.headers['Authorization'];
        if (req.url.path == '/delayed') {
          delayedTokens.add(token);
          if (token == 'Bearer T0') {
            delayedStarted.complete();
            await releaseDelayed.future;
          }
        }
        return token == 'Bearer T2' ||
                (token == 'Bearer T1' && req.url.path == '/first')
            ? http.Response('{"ok":true}', 200)
            : http.Response('{}', 401);
      }),
      refresh: () async {
        refreshes += 1;
        if (refreshes == 2) {
          secondRefreshStarted.complete();
          await releaseSecondRefresh.future;
        }
        auth.save('T$refreshes', null);
      },
    );
    final delayed = transport.send('/delayed');
    await delayedStarted.future;
    await transport.send('/first');
    final newer = transport.send('/newer');
    await secondRefreshStarted.future;
    releaseDelayed.complete();
    await pumpEventQueue();
    expect(delayedTokens, ['Bearer T0']);
    releaseSecondRefresh.complete();
    expect(await newer, {'ok': true});
    expect(await delayed, {'ok': true});
    expect(delayedTokens, ['Bearer T0', 'Bearer T2']);
    expect(refreshes, 2);
    transport.close();
  });
  for (final title in ['a\nb', 'a\tb', 'a\rb', r'a\b', "a'b", 'a"b']) {
    test('filter serializer and evaluator roundtrip ${filterValue(title)}', () {
      expect(
          evaluateFilter(
              {'title': title}, parseFilter('title = ${filterValue(title)}')),
          isTrue);
    });
  }
  for (final input in [
    r"title = 'bad\q'",
    "title = 'unfinished",
    "title = 'trailing\\"
  ]) {
    test('rejects malformed literal $input', () {
      expect(() => parseFilter(input), throwsFormatException);
    });
  }
  for (final op in ['=', '!=']) {
    test('field RHS $op triggers refetch after an event', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'a', 'left': 3, 'right': 3})
            ];
      void Function()? scheduled;
      final list = await LiveCollection('posts', reader, rt).getList(
        filter: 'left $op right',
        schedule: (run, delay) {
          scheduled = run;
          return Object();
        },
      );
      expect(list.mode, LiveListMode.refetch);
      rt.emit(
          'posts',
          RecordEvent(
              'posts', 'update', rec({'id': 'a', 'left': 3, 'right': 3})));
      expect(scheduled, isNotNull);
      scheduled!();
      await pumpEventQueue();
      expect(reader.listCalls, 2);
    });
  }
  test('control escapes preserve live membership on update', () async {
    final rt = FakeLiveSubscriber();
    final reader = FakeReader()
      ..onGetListItems = () async => [
            rec({'id': 'a', 'title': 'a\nb'})
          ];
    final list = await LiveCollection('posts', reader, rt)
        .getList(filter: 'title = ${filterValue('a\nb')}');
    rt.emit('posts',
        RecordEvent('posts', 'update', rec({'id': 'a', 'title': 'a\nb'})));
    expect(list.items.map((r) => r.id), ['a']);
  });
  test(
      'delayed stale 401 reuses completed refresh; later expiry refreshes again',
      () async {
    final auth = MemoryAuthStore()..save('old', null);
    final started = Completer<void>();
    final release = Completer<void>();
    var refreshes = 0;
    var expireNext = false;
    final client = MockClient((req) async {
      if (req.headers['Authorization'] == 'Bearer old') {
        if (req.url.path == '/delayed') {
          started.complete();
          await release.future;
        }
        return http.Response('{}', 401);
      }
      if (expireNext) {
        expireNext = false;
        return http.Response('{}', 401);
      }
      return http.Response('{"ok":true}', 200);
    });
    final transport = Transport(
      baseUrl: 'http://test',
      authStore: auth,
      httpClient: client,
      autoRefresh: true,
      maxRetries: 0,
      refresh: () async {
        auth.save('fresh-${++refreshes}', null);
      },
    );
    final second = transport.send('/delayed');
    await started.future;
    expect(await transport.send('/first'), {'ok': true});
    release.complete();
    expect(await second, {'ok': true});
    expect(refreshes, 1);
    expireNext = true;
    expect(await transport.send('/later'), {'ok': true});
    expect(refreshes, 2);
    transport.close();
  });
}
