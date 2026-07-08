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
