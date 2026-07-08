import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

import 'fakes.dart';

void main() {
  group('LiveCollection.getOne', () {
    test('seeds via REST getOne and returns a wrapped live record', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetOne = (id) async => rec({'id': id, 'title': 'Seed'});
      final lc = LiveCollection('posts', reader, rt);

      final live = await lc.getOne('p1');
      expect(live.get()['title'], 'Seed');
      expect(live['title'], 'Seed');
      expect(live.id, 'p1');
      expect(rt.subscriberCount('posts/p1'), 1);
    });

    test('patches the live record in place on an update event', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetOne = (id) async => rec({'id': id, 'title': 'Seed', 'views': 1});
      final lc = LiveCollection('posts', reader, rt);
      final live = await lc.getOne('p1');
      var notifications = 0;
      live.changes.listen((_) => notifications += 1);

      rt.emit(
        'posts/p1',
        RecordEvent('posts/p1', 'update',
            rec({'id': 'p1', 'title': 'Edited', 'views': 9})),
      );
      expect(live.get()['title'], 'Edited');
      expect(live['views'], 9);
      await pumpEventQueue();
      expect(notifications, 1);
    });

    test('flags the record deleted on a delete event', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetOne = (id) async => rec({'id': id, 'title': 'Seed'});
      final lc = LiveCollection('posts', reader, rt);
      final live = await lc.getOne('p1');
      rt.emit('posts/p1', RecordEvent('posts/p1', 'delete', rec({'id': 'p1'})));
      expect(live.deleted, isTrue);
    });

    test('close() unsubscribes, releases the cache ref, and is idempotent',
        () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetOne = (id) async => rec({'id': id, 'title': 'Seed'});
      final lc = LiveCollection('posts', reader, rt);
      final live = await lc.getOne('p1');
      expect(rt.subscriberCount('posts/p1'), 1);

      live.close();
      expect(rt.unsubFnCalls, greaterThanOrEqualTo(1));
      expect(rt.subscriberCount('posts/p1'), 0);
      expect(lc.cache.has('p1'), isFalse);

      // Idempotent.
      final before = rt.unsubFnCalls;
      live.close();
      expect(rt.unsubFnCalls, before);
    });

    test('post-close use throws StateError', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetOne = (id) async => rec({'id': id, 'title': 'Seed'});
      final lc = LiveCollection('posts', reader, rt);
      final live = await lc.getOne('p1');
      live.close();
      expect(() => live.get(), throwsStateError);
      expect(() => live.id, throwsStateError);
      expect(() => live.version, throwsStateError);
      expect(() => live['title'], throwsStateError);
    });
  });
}
