import 'dart:async';
import 'dart:math';

import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

import 'fakes.dart';

List<String> ids(LiveList list) => list.items.map((r) => r.id).toList();

void main() {
  group('LiveList refetch fallback (relation filter)', () {
    test('debounces and re-fetches the query instead of guessing membership',
        () async {
      final rt = FakeLiveSubscriber();
      final pages = [
        [
          rec({'id': 'a', 'rank': 1})
        ],
        [
          rec({'id': 'a', 'rank': 1}),
          rec({'id': 'b', 'rank': 2}),
        ],
      ];
      final reader = FakeReader();
      reader.onGetListItems = () async {
        final idx = reader.listCalls - 1;
        return pages[idx < pages.length ? idx : pages.length - 1];
      };
      final lc = LiveCollection('posts', reader, rt);

      // Manually-driven scheduler so the test controls debounce flushing.
      void Function()? scheduled;
      final list = await lc.getList(
        // relation traversal -> NOT locally evaluable -> refetch fallback
        filter: "author.name = 'Ada'",
        sort: 'rank',
        refetchDebounce: const Duration(milliseconds: 50),
        schedule: (run, delay) {
          scheduled = run;
          return Object();
        },
      );
      expect(list.mode, LiveListMode.refetch);
      expect(ids(list), ['a']);

      // Two events arrive; only one refetch should be scheduled (debounced).
      rt.emit(
          'posts', RecordEvent('posts', 'create', rec({'id': 'b', 'rank': 2})));
      rt.emit(
          'posts', RecordEvent('posts', 'create', rec({'id': 'x', 'rank': 9})));
      expect(scheduled, isNotNull);

      // Flush the debounce.
      scheduled!();
      await pumpEventQueue();

      expect(reader.listCalls, 2); // initial seed + one refetch
      expect(ids(list), ['a', 'b']);
    });
  });

  group('LiveList refetch concurrency guard', () {
    test('never runs two refetches in parallel; reconciles to the latest data',
        () async {
      final rt = FakeLiveSubscriber();

      var inFlight = 0;
      var maxInFlight = 0;
      final resolvers = <void Function(List<ZbRecord>)>[];
      var call = 0;
      final reader = FakeReader();
      reader.onGetListItems = () {
        call += 1;
        if (call == 1) {
          return Future.value([
            rec({'id': 'a', 'rank': 1})
          ]);
        }
        inFlight += 1;
        maxInFlight = max(maxInFlight, inFlight);
        final c = Completer<List<ZbRecord>>();
        resolvers.add((items) {
          inFlight -= 1;
          c.complete(items);
        });
        return c.future;
      };
      final lc = LiveCollection('posts', reader, rt);

      // Synchronous scheduler: each event flushes a refetch attempt immediately.
      final list = await lc.getList(
        filter: "author.name = 'Ada'", // relation -> refetch tier
        sort: 'rank',
        schedule: (run, delay) {
          run();
          return Object();
        },
      );
      expect(ids(list), ['a']);

      // Burst of events: each triggers scheduleRefetch synchronously.
      for (final id in ['b', 'c', 'd']) {
        rt.emit('posts',
            RecordEvent('posts', 'create', rec({'id': id, 'rank': 2})));
      }

      // Exactly one refetch in flight despite the burst.
      expect(maxInFlight, 1);
      expect(resolvers.length, 1);

      // Complete the first refetch with stale data; a rerun was requested while
      // it ran, so a second refetch must auto-run on completion.
      resolvers.removeAt(0)([
        rec({'id': 'a', 'rank': 1}),
        rec({'id': 'b', 'rank': 2}),
      ]);
      await pumpEventQueue();

      expect(resolvers.length, 1);
      expect(maxInFlight, 1);

      // Final reconcile reflects the latest data.
      resolvers.removeAt(0)([
        rec({'id': 'a', 'rank': 1}),
        rec({'id': 'b', 'rank': 2}),
        rec({'id': 'c', 'rank': 3}),
        rec({'id': 'd', 'rank': 4}),
      ]);
      await pumpEventQueue();
      expect(ids(list), ['a', 'b', 'c', 'd']);
    });
  });

  group('LiveList refetch failure', () {
    test('a failing refetch keeps the previous items and recovers later',
        () async {
      final rt = FakeLiveSubscriber();
      var call = 0;
      final reader = FakeReader();
      reader.onGetListItems = () {
        call += 1;
        switch (call) {
          case 1: // seed
            return Future.value([
              rec({'id': 'a', 'rank': 1})
            ]);
          case 2: // first refetch: fail
            return Future<List<ZbRecord>>.error(StateError('network down'));
          default: // recovery refetch
            return Future.value([
              rec({'id': 'a', 'rank': 1}),
              rec({'id': 'b', 'rank': 2}),
            ]);
        }
      };
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getList(
        filter: "author.name = 'Ada'", // relation -> refetch tier
        sort: 'rank',
        schedule: (run, delay) {
          run();
          return Object();
        },
      );
      expect(ids(list), ['a']);
      final v0 = list.version;

      // Event -> refetch that FAILS: no unhandled async error, list unchanged.
      await runZonedGuarded(() async {
        rt.emit('posts',
            RecordEvent('posts', 'create', rec({'id': 'b', 'rank': 2})));
        await pumpEventQueue();
      }, (e, st) {
        fail('failing refetch surfaced an unhandled async error: $e');
      })!;
      expect(ids(list), ['a']); // previous items kept
      expect(list.version, v0); // no notification for a failed refetch

      // A later event schedules a fresh refetch, which recovers.
      rt.emit(
          'posts', RecordEvent('posts', 'create', rec({'id': 'b', 'rank': 2})));
      await pumpEventQueue();
      expect(ids(list), ['a', 'b']);
      expect(list.version, greaterThan(v0));
    });
  });

  group('LiveList reconcile notifications', () {
    test('one reconcile with removals + inserts fires exactly one bump',
        () async {
      final rt = FakeLiveSubscriber();
      var call = 0;
      final reader = FakeReader();
      reader.onGetListItems = () {
        call += 1;
        if (call == 1) {
          return Future.value([
            rec({'id': 'a', 'rank': 1}),
            rec({'id': 'b', 'rank': 2}),
          ]);
        }
        // Refetch: 'a' and 'b' fall out, 'c' and 'd' come in.
        return Future.value([
          rec({'id': 'c', 'rank': 3}),
          rec({'id': 'd', 'rank': 4}),
        ]);
      };
      final lc = LiveCollection('posts', reader, rt);
      final list = await lc.getList(
        filter: "author.name = 'Ada'",
        sort: 'rank',
        schedule: (run, delay) {
          run();
          return Object();
        },
      );
      final v0 = list.version;

      rt.emit(
          'posts', RecordEvent('posts', 'update', rec({'id': 'x', 'rank': 9})));
      await pumpEventQueue();

      expect(ids(list), ['c', 'd']);
      // Two removals + two inserts reconcile as ONE version bump.
      expect(list.version, v0 + 1);
    });
  });
}
