import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

import 'fakes.dart';

List<String> ids(LiveList list) => list.items.map((r) => r.id).toList();

void main() {
  group('LiveCollection.getList -> LiveList', () {
    test('seeds items ordered by sort and notifies on changes', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'b', 'title': 'B', 'rank': 2}),
              rec({'id': 'a', 'title': 'A', 'rank': 1}),
            ];
      final lc = LiveCollection('posts', reader, rt);

      final list = await lc.getList(sort: 'rank');
      expect(ids(list), ['a', 'b']); // sorted by rank asc
      var notifications = 0;
      list.changes.listen((_) => notifications += 1);

      rt.emit(
        'posts',
        RecordEvent(
            'posts', 'create', rec({'id': 'c', 'title': 'C', 'rank': 0})),
      );
      expect(ids(list), ['c', 'a', 'b']);
      await pumpEventQueue();
      expect(notifications, greaterThanOrEqualTo(1));
    });

    test('removes on delete and re-sorts in place when an update moves a key',
        () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'a', 'rank': 1}),
              rec({'id': 'b', 'rank': 2}),
              rec({'id': 'c', 'rank': 3}),
            ];
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getList(sort: 'rank');

      rt.emit('posts', RecordEvent('posts', 'delete', rec({'id': 'b'})));
      expect(ids(list), ['a', 'c']);

      // update moves "a" to the end and patches it in place
      rt.emit(
          'posts', RecordEvent('posts', 'update', rec({'id': 'a', 'rank': 9})));
      expect(ids(list), ['c', 'a']);
      expect(list.items[1]['rank'], 9);
    });

    test('drops a record on an update that moves it OUT of an own-field filter',
        () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'a', 'status': 'published', 'rank': 1}),
              rec({'id': 'b', 'status': 'published', 'rank': 2}),
            ];
      final lc = LiveCollection('posts', reader, rt);
      final list =
          await lc.getList(filter: "status = 'published'", sort: 'rank');

      rt.emit(
        'posts',
        RecordEvent(
            'posts', 'update', rec({'id': 'a', 'status': 'draft', 'rank': 1})),
      );
      expect(ids(list), ['b']);

      // an update that moves a NEW record INTO the filter inserts it
      rt.emit(
        'posts',
        RecordEvent('posts', 'update',
            rec({'id': 'z', 'status': 'published', 'rank': 0})),
      );
      expect(ids(list), ['z', 'b']);
    });
  });

  group('LiveList sorted insertion', () {
    test('lands a matching create at the correct sorted position', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'a', 'rank': 10}),
              rec({'id': 'c', 'rank': 30}),
              rec({'id': 'e', 'rank': 50}),
            ];
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getList(sort: 'rank');
      expect(ids(list), ['a', 'c', 'e']);

      rt.emit('posts',
          RecordEvent('posts', 'create', rec({'id': 'd', 'rank': 40})));
      expect(ids(list), ['a', 'c', 'd', 'e']); // middle

      rt.emit(
          'posts', RecordEvent('posts', 'create', rec({'id': 'z', 'rank': 5})));
      expect(ids(list), ['z', 'a', 'c', 'd', 'e']); // front

      rt.emit('posts',
          RecordEvent('posts', 'create', rec({'id': 'y', 'rank': 99})));
      expect(ids(list), ['z', 'a', 'c', 'd', 'e', 'y']); // end
    });

    test('O(1) membership: getById returns the live record', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'a', 'rank': 1})
            ];
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getList(sort: 'rank');
      expect(list.getById('a')?.id, 'a');
      expect(list.getById('missing'), isNull);
    });

    test('id-asc tiebreaker orders records with equal sort keys', () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader()
        ..onGetListItems = () async => [
              rec({'id': 'b', 'rank': 1}),
              rec({'id': 'a', 'rank': 1}),
            ];
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getList(sort: 'rank');
      expect(ids(list), ['a', 'b']); // tie broken by id asc

      rt.emit(
          'posts', RecordEvent('posts', 'create', rec({'id': 'c', 'rank': 1})));
      expect(ids(list), ['a', 'b', 'c']);
    });
  });

  group('cache identity across views', () {
    test('the same id is one LiveRecord shared by a list and a getOne',
        () async {
      final rt = FakeLiveSubscriber();
      final reader = FakeReader();
      reader.onGetListItems = () async => [
            rec({'id': 'a', 'rank': 1})
          ];
      reader.onGetOne = (String id) async => rec({'id': id, 'rank': 1});
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getList(sort: 'rank');
      final one = await lc.getOne('a');

      // Same backing record: an event patches both views at once.
      expect(one.get(), same(list.getById('a')!.get()));
      rt.emit(
          'posts', RecordEvent('posts', 'update', rec({'id': 'a', 'rank': 7})));
      expect(one['rank'], 7);
      expect(list.getById('a')!['rank'], 7);
    });
  });
}
