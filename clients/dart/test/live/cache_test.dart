import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

void main() {
  group('RecordCache + LiveRecord', () {
    test('returns the SAME wrapped object for a given id across lookups', () {
      final cache = RecordCache();
      final a = cache.retain(ZbRecord({'id': 'p1', 'title': 'First'}));
      final b = cache.get('p1');
      expect(b, same(a));
      expect(a.get()['title'], 'First');
      // The wrapper reads through to the backing record.
      expect(a['title'], 'First');
      expect(a.id, 'p1');
    });

    test('patches fields in place, bumps version, and notifies on update',
        () async {
      final cache = RecordCache();
      final live =
          cache.retain(ZbRecord({'id': 'p1', 'title': 'First', 'views': 1}));
      var notifications = 0;
      live.changes.listen((_) => notifications += 1);
      final v0 = live.version;

      cache.applyUpdate(ZbRecord({'id': 'p1', 'title': 'Edited', 'views': 2}));

      expect(live.get()['title'], 'Edited');
      expect(live['views'], 2);
      expect(live.version, v0 + 1);
      // Identity is stable through the patch.
      expect(cache.get('p1'), same(live));

      await pumpEventQueue();
      expect(notifications, 1);
    });

    test('flags a record deleted on a delete event and notifies', () async {
      final cache = RecordCache();
      final live = cache.retain(ZbRecord({'id': 'p1', 'title': 'First'}));
      var notifications = 0;
      live.changes.listen((_) => notifications += 1);
      cache.applyDelete('p1');
      expect(live.deleted, isTrue);
      await pumpEventQueue();
      expect(notifications, 1);
    });

    test('ref-counts: evicted only when the last referer releases it', () {
      final cache = RecordCache();
      final a1 = cache.retain(ZbRecord({'id': 'p1', 'title': 'First'}));
      final a2 = cache.retain(ZbRecord({'id': 'p1', 'title': 'First'}));
      expect(a2, same(a1));

      cache.release('p1'); // -> 1
      expect(cache.has('p1'), isTrue);
      cache.release('p1'); // -> 0, evicted
      expect(cache.has('p1'), isFalse);
    });

    test('patch skips reserved keys and drops polluting keys', () {
      final cache = RecordCache();
      final live =
          cache.retain(ZbRecord({'id': 'p1', 'title': 'First', 'version': 0}));
      final v0 = live.version;

      // A hostile payload trying to clobber reserved fields and pollute.
      cache.applyUpdate(ZbRecord({
        'id': 'p1',
        'version': 999,
        'deleted': true,
        '__proto__': {'polluted': true},
        'title': 'Edited',
      }));

      expect(live.get()['title'], 'Edited');
      // Reserved fields untouched (wrapper owns id/version/deleted).
      expect(live.id, 'p1');
      expect(live.deleted, isFalse);
      expect(
          live.version, v0 + 1); // bumped by the cache, not the payload's 999
      // Polluting key never entered the backing map.
      expect(live.get().data.containsKey('__proto__'), isFalse);
      // A field literally named 'version' stays at its seeded value.
      expect(live.get()['version'], 0);
    });

    test('patch removes keys dropped from the payload, and re-adds later', () {
      final cache = RecordCache();
      final live = cache
          .retain(ZbRecord({'id': 'p1', 'title': 'First', 'subtitle': 'Sub'}));
      expect(live['subtitle'], 'Sub');

      cache.applyUpdate(ZbRecord({'id': 'p1', 'title': 'First'}));
      expect(live.get().data.containsKey('subtitle'), isFalse);
      expect(live['subtitle'], isNull);

      cache.applyUpdate(
          ZbRecord({'id': 'p1', 'title': 'First', 'subtitle': 'Back'}));
      expect(live['subtitle'], 'Back');
    });

    test('cancelling a change subscription stops further notifications',
        () async {
      final cache = RecordCache();
      final live = cache.retain(ZbRecord({'id': 'p1', 'n': 0}));
      var notifications = 0;
      final sub = live.changes.listen((_) => notifications += 1);
      cache.applyUpdate(ZbRecord({'id': 'p1', 'n': 1}));
      await pumpEventQueue();
      await sub.cancel();
      cache.applyUpdate(ZbRecord({'id': 'p1', 'n': 2}));
      await pumpEventQueue();
      expect(notifications, 1);
    });
  });
}
