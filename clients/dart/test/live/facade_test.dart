import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

import '../support/fake_socket.dart';
import 'fakes.dart';

void main() {
  group('realtime.collection facade', () {
    test('standalone RealtimeService without a reader factory throws', () {
      final factory = FakeSocketFactory();
      final service = RealtimeService(
        baseUrl: 'http://api.test',
        authStore: MemoryAuthStore(),
        connector: factory.connect,
      );
      expect(() => service.collection('posts'), throwsStateError);
    });

    test('RealtimeService.collection builds a LiveCollection via the factory',
        () {
      final factory = FakeSocketFactory();
      final reader = FakeReader();
      final service = RealtimeService(
        baseUrl: 'http://api.test',
        authStore: MemoryAuthStore(),
        connector: factory.connect,
        liveReaderFactory: (name) => reader,
      );
      final lc = service.collection('posts');
      expect(lc, isA<LiveCollection>());
      expect(lc.name, 'posts');
    });

    test('two collection() views of one name share the record cache', () {
      final factory = FakeSocketFactory();
      final service = RealtimeService(
        baseUrl: 'http://api.test',
        authStore: MemoryAuthStore(),
        connector: factory.connect,
        liveReaderFactory: (name) => FakeReader(),
      );
      final view1 = service.collection('posts');
      final view2 = service.collection('posts');
      final other = service.collection('comments');

      // Fresh LiveCollection objects, ONE cache per collection name.
      expect(view1, isNot(same(view2)));
      expect(view1.cache, same(view2.cache));
      expect(other.cache, isNot(same(view1.cache)));

      // The same id resolves to the same LiveRecord across both views.
      final live = view1.cache.retain(rec({'id': 'p1', 'title': 'One'}));
      expect(view2.cache.get('p1'), same(live));
    });

    test('the same id is one LiveRecord across two live views (end-to-end)',
        () async {
      // Two LiveCollections sharing one cache (as the facade wires them):
      // an event applied through one view's subscription patches the record
      // the other view's list holds, because it IS the same object.
      final rt = FakeLiveSubscriber();
      final cache = RecordCache();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'a', 'rank': 1})
            ];
      final viewA = LiveCollection('posts', reader, rt, cache: cache);
      final viewB = LiveCollection('posts', reader, rt, cache: cache);

      final listA = await viewA.getList(sort: 'rank');
      final listB = await viewB.getList(sort: 'rank');
      expect(listA.getById('a'), same(listB.getById('a')));

      rt.emit(
          'posts', RecordEvent('posts', 'update', rec({'id': 'a', 'rank': 7})));
      expect(listA.getById('a')!['rank'], 7);
      expect(listB.getById('a')!['rank'], 7);
      listA.close();
      listB.close();
    });

    test('collection() throws once the service is closed', () async {
      final factory = FakeSocketFactory();
      final service = RealtimeService(
        baseUrl: 'http://api.test',
        authStore: MemoryAuthStore(),
        connector: factory.connect,
        liveReaderFactory: (name) => FakeReader(),
      );
      await service.close();
      expect(() => service.collection('posts'), throwsStateError);
    });

    test('ZigbaseClient.realtime.collection is wired to a reader', () async {
      final factory = FakeSocketFactory();
      final client =
          ZigbaseClient('http://api.test', webSocketConnector: factory.connect);
      final lc = client.realtime.collection('posts');
      expect(lc, isA<LiveCollection>());
      expect(lc.name, 'posts');
      await client.close();
      // A closed client denies further realtime access.
      expect(() => client.realtime, throwsStateError);
    });
  });

  group('LiveCollection.getPage', () {
    test('seeds a cursor-paginated live list and reacts to events', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetPageItems = () async => [
              rec({'id': 'a', 'rank': 1}),
              rec({'id': 'b', 'rank': 2}),
            ];
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getPage(limit: 30, sort: 'rank');
      expect(list.items.map((r) => r.id).toList(), ['a', 'b']);
      expect(rt.subscriberCount('posts'), 1);

      rt.emit(
          'posts', RecordEvent('posts', 'create', rec({'id': 'c', 'rank': 0})));
      expect(list.items.map((r) => r.id).toList(), ['c', 'a', 'b']);
      list.close();
    });
  });
}
