import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

String _makeJwt(Map<String, dynamic> payload) {
  final header =
      base64Url.encode(utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})));
  final body = base64Url.encode(utf8.encode(jsonEncode(payload)));
  return '$header.$body.sig';
}

void main() {
  final farFutureExp = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
  final validToken = _makeJwt({'id': 'u1', 'exp': farFutureExp});

  group('MemoryAuthStore', () {
    test('starts empty and invalid', () {
      final store = MemoryAuthStore();
      expect(store.token, isNull);
      expect(store.record, isNull);
      expect(store.isValid, isFalse);
      store.dispose();
    });

    test('save sets token/record and isValid becomes true', () {
      final store = MemoryAuthStore();
      store.save(validToken, {'id': 'u1'});
      expect(store.token, validToken);
      expect(store.record, {'id': 'u1'});
      expect(store.isValid, isTrue);
      store.dispose();
    });

    test('clear resets token/record and isValid', () {
      final store = MemoryAuthStore();
      store.save(validToken, {'id': 'u1'});
      store.clear();
      expect(store.token, isNull);
      expect(store.record, isNull);
      expect(store.isValid, isFalse);
      store.dispose();
    });

    test('isValid is false for an expired token', () {
      final store = MemoryAuthStore();
      final expired = _makeJwt({'exp': 1});
      store.save(expired, null);
      expect(store.isValid, isFalse);
      store.dispose();
    });

    test('save/clear after dispose update state without throwing', () {
      final store = MemoryAuthStore();
      store.dispose();
      expect(() => store.save(validToken, {'id': 'u1'}), returnsNormally);
      expect(store.token, validToken);
      expect(store.record, {'id': 'u1'});
      expect(store.clear, returnsNormally);
      expect(store.token, isNull);
      expect(store.record, isNull);
    });

    test('onChange emits an AuthEvent on save then on clear', () async {
      final store = MemoryAuthStore();

      final expectation = expectLater(
        store.onChange,
        emitsInOrder([
          isA<AuthEvent>()
              .having((e) => e.token, 'token', validToken)
              .having((e) => e.record, 'record', {'id': 'u1'}),
          isA<AuthEvent>()
              .having((e) => e.token, 'token', isNull)
              .having((e) => e.record, 'record', isNull),
        ]),
      );

      store.save(validToken, {'id': 'u1'});
      store.clear();

      await expectation;
      store.dispose();
    });
  });

  group('AsyncAuthStore', () {
    test('rehydrates token/record from initial JSON', () {
      final initial = jsonEncode({
        'token': validToken,
        'record': {'id': 'u1'}
      });
      final store = AsyncAuthStore(
        save: (_) async {},
        initial: initial,
      );
      expect(store.token, validToken);
      expect(store.record, {'id': 'u1'});
      expect(store.isValid, isTrue);
      store.dispose();
    });

    test('invalid (non-JSON) initial is ignored', () {
      final store = AsyncAuthStore(save: (_) async {}, initial: 'not-json');
      expect(store.token, isNull);
      expect(store.record, isNull);
      expect(store.isValid, isFalse);
      store.dispose();
    });

    test('initial JSON missing a token is ignored', () {
      final store = AsyncAuthStore(
        save: (_) async {},
        initial: jsonEncode({
          'record': {'id': 'u1'}
        }),
      );
      expect(store.token, isNull);
      store.dispose();
    });

    test('no initial provided leaves the store empty', () {
      final store = AsyncAuthStore(save: (_) async {});
      expect(store.token, isNull);
      expect(store.record, isNull);
      store.dispose();
    });

    test('save calls the save callback with serialized JSON', () async {
      final calls = <String>[];
      final store = AsyncAuthStore(save: (data) async {
        calls.add(data);
      });

      store.save(validToken, {'id': 'u1'});
      await Future<void>.delayed(Duration.zero);

      expect(calls, [
        jsonEncode({
          'token': validToken,
          'record': {'id': 'u1'}
        })
      ]);
      store.dispose();
    });

    test('clear calls the clear callback', () async {
      final saveCalls = <String>[];
      final clearCalls = <int>[];
      final store = AsyncAuthStore(
        save: (data) async {
          saveCalls.add(data);
        },
        clear: () async {
          clearCalls.add(1);
        },
      );

      store.save(validToken, {'id': 'u1'});
      store.clear();
      await Future<void>.delayed(Duration.zero);

      expect(saveCalls.length, 1);
      expect(clearCalls, [1]);
      store.dispose();
    });

    test('clear falls back to save("") when no clear callback given', () async {
      final calls = <String>[];
      final store = AsyncAuthStore(save: (data) async {
        calls.add(data);
      });

      store.clear();
      await Future<void>.delayed(Duration.zero);

      expect(calls, ['']);
      store.dispose();
    });

    test('a failed persistence write does not poison the chain', () async {
      final calls = <String>[];
      final zoneErrors = <Object>[];
      final goodWritten = Completer<void>();

      await runZonedGuarded(() async {
        final store = AsyncAuthStore(save: (data) async {
          if (data.contains('"bad"')) throw StateError('disk full');
          calls.add(data);
          goodWritten.complete();
        });

        store.save('bad', null);
        store.save('good', {'id': 'u1'});
        // Deterministic handshake: wait for the "good" write to actually run
        // (rather than a fixed sleep) — it can only happen after the
        // "bad" write's chained future has settled (thrown + been caught).
        await goodWritten.future;
        store.dispose();
      }, (error, stack) {
        zoneErrors.add(error);
      });

      // The failing write is skipped, later writes still persist, and the
      // failure never surfaces as an unhandled async error.
      expect(calls, [
        jsonEncode({
          'token': 'good',
          'record': {'id': 'u1'}
        })
      ]);
      expect(zoneErrors, isEmpty);
    });

    test('writes are chained in order and do not interleave', () async {
      final order = <String>[];
      final firstGate = Completer<void>();
      final secondWritten = Completer<void>();
      final store = AsyncAuthStore(save: (data) async {
        if (data.contains('"first"')) {
          // Held open until the test releases it below, so the "second"
          // write cannot even start (per AsyncAuthStore's chaining
          // contract) until this completes.
          await firstGate.future;
          order.add('first-done');
        } else {
          // If writes were not chained, this callback could run before
          // the still-pending "first" write completes.
          expect(order, contains('first-done'));
          order.add('second-done');
          secondWritten.complete();
        }
      });

      store.save('first', null);
      store.save('second', null);
      firstGate.complete();

      await secondWritten.future;
      expect(order, ['first-done', 'second-done']);
      store.dispose();
    });
  });
}
