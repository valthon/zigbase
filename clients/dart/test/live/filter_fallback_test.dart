import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

import 'fakes.dart';

void main() {
  for (final cursor in [false, true]) {
    for (final filter in [
      "'x' = a",
      "a in ('x', 'y')",
      'id in @request.auth.roles'
    ]) {
      test('server grammar uses refetch (cursor=$cursor): $filter', () async {
        final rt = FakeLiveSubscriber();
        var calls = 0;
        Future<List<ZbRecord>> read() async => [
              rec({'id': ++calls == 1 ? 'seed' : 'fresh', 'a': 'x'})
            ];
        final reader = FakeReader()
          ..onGetListItems = read
          ..onGetPageItems = read;
        final collection = LiveCollection('posts', reader, rt);
        void Function()? scheduled;
        Object schedule(void Function() run, Duration _) {
          scheduled = run;
          return Object();
        }

        final list = cursor
            ? await collection.getPage(filter: filter, schedule: schedule)
            : await collection.getList(filter: filter, schedule: schedule);
        expect(list.mode, LiveListMode.refetch);
        expect(list.items.map((r) => r.id), ['seed']);
        rt.emit(
            'posts',
            RecordEvent(
                'posts', 'update', rec({'id': 'seed', 'a': 'changed'})));
        expect(list.items.map((r) => r.id), ['seed']);
        expect(scheduled, isNotNull);
        scheduled!();
        await pumpEventQueue();
        expect(calls, 2);
        expect(list.items.map((r) => r.id), ['fresh']);
        list.close();
      });
    }
    test('initial HTTP error propagates (cursor=$cursor)', () async {
      final error = ZigbaseException(
          status: 400, message: 'invalid filter', url: '/records');
      Future<List<ZbRecord>> fail() async => throw error;
      final reader = FakeReader()
        ..onGetListItems = fail
        ..onGetPageItems = fail;
      final rt = FakeLiveSubscriber();
      final collection = LiveCollection('posts', reader, rt);
      final request = cursor
          ? collection.getPage(filter: 'a = -b')
          : collection.getList(filter: 'a = -b');
      await expectLater(request, throwsA(same(error)));
      expect(rt.subscriberCount('posts'), 0);
    });
  }
  for (final filter in ['a = 1.2.3', 'a = -b', '-b = 1', 'a = in', 'a & b']) {
    test('invalid local bareword is rejected: $filter', () {
      expect(() => parseFilter(filter), throwsFormatException);
    });
  }
  test('CR terminates tokens and supported filters remain precise', () async {
    const filter = "a\r=\r'x'\r&&\rn >= -2";
    expect(evaluateFilter({'a': 'x', 'n': 1}, parseFilter(filter)), isTrue);
    final reader = FakeReader()
      ..onGetListItems = () async => [
            rec({'id': 'a', 'a': 'x', 'n': 1})
          ];
    final rt = FakeLiveSubscriber();
    final list =
        await LiveCollection('posts', reader, rt).getList(filter: filter);
    expect(list.mode, LiveListMode.precise);
    rt.emit('posts',
        RecordEvent('posts', 'update', rec({'id': 'a', 'a': 'other', 'n': 1})));
    expect(list.items, isEmpty);
    list.close();
  });
}
