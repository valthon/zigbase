import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

import 'fakes.dart';

void main() {
  group('LiveList.close teardown', () {
    test('unsubscribes from realtime and releases every retained cache ref',
        () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'a', 'rank': 1}),
              rec({'id': 'b', 'rank': 2}),
            ];
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getList(sort: 'rank');
      expect(rt.subscriberCount('posts'), 1);

      list.close();

      // Realtime unsubscribe was invoked and the topic callback removed.
      expect(rt.unsubFnCalls, greaterThanOrEqualTo(1));
      expect(rt.subscriberCount('posts'), 0);

      // The underlying cache entries were released (refcount -> 0, evicted).
      expect(lc.cache.has('a'), isFalse);
      expect(lc.cache.has('b'), isFalse);

      // After teardown the list is terminal: reads throw, events are ignored.
      expect(() => list.items, throwsStateError);
      rt.emit(
          'posts', RecordEvent('posts', 'create', rec({'id': 'c', 'rank': 0})));
      expect(lc.cache.has('c'), isFalse);
    });

    test('is idempotent: a second close() does not double-free', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'a', 'rank': 1})
            ];
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getList(sort: 'rank');

      list.close();
      final before = rt.unsubFnCalls;
      list.close(); // no-op
      expect(rt.unsubFnCalls, before);
      expect(lc.cache.has('a'), isFalse);
    });

    test('stops a pending refetch timer on close', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'a', 'rank': 1})
            ];
      final lc = LiveCollection('posts', reader, rt);
      void Function()? scheduled;
      var cleared = 0;
      final list = await lc.getList(
        filter: "author.name = 'Ada'", // relation -> refetch tier
        sort: 'rank',
        schedule: (run, delay) {
          scheduled = run;
          return Object();
        },
        clearSchedule: (handle) => cleared += 1,
      );
      rt.emit(
          'posts', RecordEvent('posts', 'create', rec({'id': 'b', 'rank': 2})));
      expect(scheduled, isNotNull);

      final calls = reader.listCalls;
      list.close();
      await pumpEventQueue();
      // The pending timer was cleared and no refetch fired.
      expect(cleared, 1);
      expect(reader.listCalls, calls);
    });
  });

  group('LiveList.mode DX surface', () {
    test('reports precise for an own-field filter and refetch for a relation',
        () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()..onGetListItems = () async => [];
      final lc = LiveCollection('posts', reader, rt);

      final precise =
          await lc.getList(filter: "status = 'published'", sort: 'rank');
      expect(precise.mode, LiveListMode.precise);

      final refetch =
          await lc.getList(filter: "author.name = 'Ada'", sort: 'rank');
      expect(refetch.mode, LiveListMode.refetch);

      final noFilter = await lc.getList(sort: 'rank');
      expect(noFilter.mode, LiveListMode.precise);
    });
  });
}
