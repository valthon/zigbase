import 'dart:async';

import 'package:test/test.dart';
import 'package:zigbase_client/zigbase_client.dart';

import 'support/fake_socket.dart';

RealtimeService makeService(
  FakeSocketFactory factory, {
  AuthStore? authStore,
  Future<void> Function(Duration)? sleep,
  void Function(Object)? onError,
}) {
  return RealtimeService(
    baseUrl: 'http://api.test',
    authStore: authStore ?? MemoryAuthStore(),
    connector: factory.connect,
    sleep: sleep ?? (Duration d) async {},
    onError: onError,
  );
}

void main() {
  group('RealtimeService.subscribe', () {
    test(
        'opens one WS to /api/realtime, sends subscribe frame, resolves on ack',
        () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final events = <RecordEvent>[];
      final subFut = service.subscribe('posts', events.add);

      await pumpEventQueue();
      expect(factory.lastUri.toString(), 'ws://api.test/api/realtime');
      final ws = factory.last;
      expect(ws.subscribeFrames, [
        {'action': 'subscribe', 'topic': 'posts'}
      ]);

      // Not resolved until the ack arrives.
      var resolved = false;
      unawaited(subFut.then((_) => resolved = true));
      await pumpEventQueue();
      expect(resolved, isFalse);

      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      final unsub = await subFut;
      expect(unsub, isA<ZbUnsubscribe>());
      await service.close();
    });

    test('dispatches event frames to the topic callback only', () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final posts = <RecordEvent>[];
      final other = <RecordEvent>[];
      final subFut = service.subscribe('posts', posts.add);
      await pumpEventQueue();
      final ws = factory.last;
      final otherFut = service.subscribe('comments', other.add);
      await pumpEventQueue();
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'comments'});
      await subFut;
      await otherFut;

      ws.push({
        'type': 'event',
        'topic': 'posts',
        'action': 'create',
        'record': {'id': 'p1', 'title': 'Hi'},
      });
      await pumpEventQueue();
      expect(posts, hasLength(1));
      expect(other, isEmpty);
      expect(posts.first.topic, 'posts');
      expect(posts.first.action, 'create');
      expect(posts.first.record.id, 'p1');
      expect(posts.first.record['title'], 'Hi');
      await service.close();
    });

    test('delete event carries an {id}-only record', () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final got = <RecordEvent>[];
      final subFut = service.subscribe('posts', got.add);
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;

      ws.push({
        'type': 'event',
        'topic': 'posts',
        'action': 'delete',
        'record': {'id': 'p9'},
      });
      await pumpEventQueue();
      expect(got, hasLength(1));
      expect(got.first.action, 'delete');
      expect(got.first.record.id, 'p9');
      expect(got.first.record.data, {'id': 'p9'});
      await service.close();
    });

    test('passes a filter through on the subscribe frame', () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final subFut =
          service.subscribe('posts', (_) {}, filter: "status = 'published'");
      await pumpEventQueue();
      final ws = factory.last;
      expect(ws.subscribeFrames, [
        {
          'action': 'subscribe',
          'topic': 'posts',
          'filter': "status = 'published'"
        }
      ]);
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;
      await service.close();
    });

    test('two callbacks on same (topic, filter) send ONE frame', () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final a = <RecordEvent>[];
      final b = <RecordEvent>[];
      final p1 = service.subscribe('posts', a.add);
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await p1;

      final p2 = service.subscribe('posts', b.add);
      await p2; // already acked -> resolves immediately, no new frame
      expect(ws.subscribeFrames, hasLength(1));

      ws.push({
        'type': 'event',
        'topic': 'posts',
        'action': 'update',
        'record': {'id': 'p1'}
      });
      await pumpEventQueue();
      expect(a, hasLength(1));
      expect(b, hasLength(1));
      await service.close();
    });

    test('concurrent subscribes on an open socket send ONE frame before ack',
        () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final p1 = service.subscribe('posts', (_) {});
      await pumpEventQueue();
      final ws = factory.last;
      // Second subscriber arrives while the first frame awaits its ack.
      final p2 = service.subscribe('posts', (_) {});
      await pumpEventQueue();
      expect(ws.subscribeFrames, hasLength(1));

      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await Future.wait([p1, p2]);
      await service.close();
    });

    test('unsubscribe of one variant keeps sub; both removed sends frame',
        () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final a = <RecordEvent>[];
      final b = <RecordEvent>[];
      final p1 = service.subscribe('posts', a.add);
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await p1;
      await service.subscribe('posts', b.add);

      // Remove one callback; the socket subscription must remain.
      await service.unsubscribe('posts', a.add);
      expect(ws.unsubscribeFrames, isEmpty);
      ws.push({
        'type': 'event',
        'topic': 'posts',
        'action': 'update',
        'record': {'id': 'p1'}
      });
      await pumpEventQueue();
      expect(a, isEmpty);
      expect(b, hasLength(1));

      // Remove the last callback; now an unsubscribe frame is sent.
      await service.unsubscribe('posts', b.add);
      expect(ws.unsubscribeFrames, [
        {'action': 'unsubscribe', 'topic': 'posts'}
      ]);
      await service.close();
    });

    test('unsubscribe(topic, cb) removes a FILTERED subscription', () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final got = <RecordEvent>[];
      final subFut =
          service.subscribe('posts', got.add, filter: "status = 'published'");
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;

      // Public path passes only (topic, cb): must still drop the filtered sub.
      await service.unsubscribe('posts', got.add);
      ws.push({
        'type': 'event',
        'topic': 'posts',
        'action': 'update',
        'record': {'id': 'p1'}
      });
      await pumpEventQueue();
      expect(got, isEmpty);
      expect(ws.unsubscribeFrames, [
        {'action': 'unsubscribe', 'topic': 'posts'}
      ]);
      await service.close();
    });
  });

  group('RealtimeService auth', () {
    test('sends auth first when token present, gates subscribe on auth ok',
        () async {
      final store = MemoryAuthStore()..save('tok-1', {'id': 'u1'});
      final factory = FakeSocketFactory();
      final service = makeService(factory, authStore: store);
      final subFut = service.subscribe('posts', (_) {});
      await pumpEventQueue();
      final ws = factory.last;

      // auth precedes subscribe; subscribe not yet flushed.
      expect(ws.sent, [
        {'action': 'auth', 'token': 'tok-1'}
      ]);

      ws.push({'type': 'auth', 'status': 'ok'});
      await pumpEventQueue();
      expect(ws.subscribeFrames, [
        {'action': 'subscribe', 'topic': 'posts'}
      ]);
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;
      await service.close();
      store.dispose();
    });

    test('anonymous does not send an auth frame', () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final subFut = service.subscribe('public', (_) {});
      await pumpEventQueue();
      final ws = factory.last;
      expect(ws.sent.any((f) => (f as Map)['action'] == 'auth'), isFalse);
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'public'});
      await subFut;
      await service.close();
    });

    test('re-sends auth when the token changes while connected', () async {
      final store = MemoryAuthStore();
      final factory = FakeSocketFactory();
      final service = makeService(factory, authStore: store);
      final subFut = service.subscribe('posts', (_) {});
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;

      store.save('tok-2', {'id': 'u1'});
      await pumpEventQueue();
      expect(ws.sent, contains(equals({'action': 'auth', 'token': 'tok-2'})));
      await service.close();
      store.dispose();
    });

    test('logout while connected sends an empty-token de-auth frame', () async {
      final store = MemoryAuthStore()..save('tok-1', {'id': 'u1'});
      final factory = FakeSocketFactory();
      final service = makeService(factory, authStore: store);
      final events = <RecordEvent>[];
      final subFut = service.subscribe('posts', events.add);
      await pumpEventQueue();
      final ws = factory.last;
      // Authenticate + ack the subscription.
      ws.push({'type': 'auth', 'status': 'ok'});
      await pumpEventQueue();
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;

      // Logout: the connection must be de-authed server-side via an empty
      // token (the server keeps the subscriptions; only identity is cleared).
      store.clear();
      await pumpEventQueue();
      expect(ws.sent, contains(equals({'action': 'auth', 'token': ''})));

      // The server rejects the empty token; the ack path must be benign (no
      // unhandled async error) and existing subscriptions keep delivering.
      ws.push({'type': 'auth', 'status': 'error'});
      await pumpEventQueue();
      ws.push({
        'type': 'event',
        'topic': 'posts',
        'action': 'update',
        'record': {'id': 'p1'}
      });
      await pumpEventQueue();
      expect(events, hasLength(1));
      expect(events.first.record.id, 'p1');
      await service.close();
      store.dispose();
    });

    test('does NOT send an auth frame on an anonymous open', () async {
      // Regression guard for the de-auth fix: the connected-then-logged-out
      // transition sends {token:""}, but a fresh anonymous connect must not.
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final subFut = service.subscribe('public', (_) {});
      await pumpEventQueue();
      final ws = factory.last;
      expect(ws.sent.any((f) => (f as Map)['action'] == 'auth'), isFalse);
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'public'});
      await subFut;
      await service.close();
    });

    test('rapid re-auth before responses does not strand the auth gate',
        () async {
      final store = MemoryAuthStore()..save('tok-1', {'id': 'u1'});
      final factory = FakeSocketFactory();
      final service = makeService(factory, authStore: store);
      final subFut = service.subscribe('posts', (_) {});
      await pumpEventQueue();
      final ws = factory.last;

      // onOpen sent auth tok-1; before its response, the token changes twice.
      store.save('tok-2', {'id': 'u1'});
      store.save('tok-3', {'id': 'u1'});
      await pumpEventQueue();
      final auths =
          ws.sent.where((f) => (f as Map)['action'] == 'auth').toList();
      expect(auths, [
        {'action': 'auth', 'token': 'tok-1'},
        {'action': 'auth', 'token': 'tok-2'},
        {'action': 'auth', 'token': 'tok-3'},
      ]);

      // A single response must open the (reused) auth gate so the subscribe
      // flushes — the superseded completers must not be left hanging.
      ws.push({'type': 'auth', 'status': 'ok'});
      await pumpEventQueue();
      expect(ws.subscribeFrames, [
        {'action': 'subscribe', 'topic': 'posts'}
      ]);

      // Superseded responses arriving late must not raise a double-completion.
      ws.push({'type': 'auth', 'status': 'ok'});
      ws.push({'type': 'auth', 'status': 'error'});
      await pumpEventQueue();

      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut.timeout(const Duration(seconds: 2),
          onTimeout: () => fail('subscribe gate hung on superseded auth'));
      await service.close();
      store.dispose();
    });
  });

  group('RealtimeService errors + reconnect', () {
    test('server error frame rejects pending subscribe and calls onError',
        () async {
      final errors = <Object>[];
      final factory = FakeSocketFactory();
      final service = makeService(factory, onError: errors.add);
      final subFut = service.subscribe('private', (_) {});
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'error', 'message': 'anonymous not allowed'});

      await expectLater(subFut, throwsA(isA<Object>()));
      expect(errors, contains('anonymous not allowed'));
      await service.close();
    });

    test('unexpected close reconnects after 250ms and resubscribes all',
        () async {
      final delays = <Duration>[];
      final factory = FakeSocketFactory();
      final service = makeService(factory, sleep: (d) async => delays.add(d));
      final got = <RecordEvent>[];
      final subFut = service.subscribe('posts', got.add);
      await pumpEventQueue();
      final ws1 = factory.last;
      ws1.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;

      await ws1.serverClose();
      await pumpEventQueue();
      expect(delays, [const Duration(milliseconds: 250)]);
      final ws2 = factory.last;
      expect(identical(ws2, ws1), isFalse);
      expect(ws2.subscribeFrames, [
        {'action': 'subscribe', 'topic': 'posts'}
      ]);

      ws2.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      ws2.push({
        'type': 'event',
        'topic': 'posts',
        'action': 'create',
        'record': {'id': 'p9'}
      });
      await pumpEventQueue();
      expect(got.single.record.id, 'p9');
      await service.close();
    });

    test('backoff doubles across repeated connect failures', () async {
      final delays = <Duration>[];
      final factory = FakeSocketFactory()..pendingFailures = 3;
      final service = makeService(factory, sleep: (d) async => delays.add(d));
      final subFut = service.subscribe('posts', (_) {});
      await pumpEventQueue(times: 40);

      expect(delays, [
        const Duration(milliseconds: 250),
        const Duration(milliseconds: 500),
        const Duration(milliseconds: 1000),
      ]);
      // 4th attempt succeeded; drive it to ack so the pending future resolves.
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;
      await service.close();
    });

    test(
        'a rejected subscribe is dropped so a reconnect never re-subscribes it',
        () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      // A good subscription keeps the socket alive across the reconnect.
      final good = service.subscribe('posts', (_) {});
      await pumpEventQueue();
      final ws1 = factory.last;
      ws1.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await good;

      // A second subscribe the server rejects.
      final bad = service.subscribe('private', (_) {});
      await pumpEventQueue();
      ws1.push({'type': 'error', 'message': 'not allowed'});
      await expectLater(bad, throwsA(isA<Object>()));

      // Transport drop -> reconnect resubscribes only the surviving topics.
      await ws1.serverClose();
      await pumpEventQueue();
      final ws2 = factory.last;
      expect(identical(ws2, ws1), isFalse);
      final topics =
          ws2.subscribeFrames.map((f) => (f as Map)['topic']).toList();
      expect(topics, ['posts']); // NOT 'private'
      await service.close();
    });

    test('a subscribe during the reconnect backoff does not open a 2nd socket',
        () async {
      final sleepGate = Completer<void>();
      final factory = FakeSocketFactory();
      final service = makeService(factory, sleep: (d) => sleepGate.future);
      final p1 = service.subscribe('posts', (_) {});
      await pumpEventQueue();
      final ws1 = factory.last;
      ws1.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await p1;
      expect(factory.connections, hasLength(1));

      // Drop -> schedules a reconnect that is now parked on the gated sleep.
      await ws1.serverClose();
      await pumpEventQueue();
      // A fresh subscribe arrives while the reconnect is still sleeping.
      final p2 = service.subscribe('comments', (_) {});
      await pumpEventQueue();
      expect(factory.connections, hasLength(1)); // no competing socket

      // Release the backoff; the reconnect opens EXACTLY one new socket.
      sleepGate.complete();
      await pumpEventQueue();
      expect(factory.connections, hasLength(2));
      final ws2 = factory.last;
      ws2.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      ws2.push({'type': 'ack', 'action': 'subscribe', 'topic': 'comments'});
      await p2;
      await service.close();
    });

    test('close() stops reconnects and detaches the auth listener', () async {
      final store = MemoryAuthStore();
      final factory = FakeSocketFactory();
      final service = makeService(factory, authStore: store);
      final subFut = service.subscribe('posts', (_) {});
      await pumpEventQueue();
      final ws1 = factory.last;
      ws1.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;

      await service.close();
      // A dropped socket must NOT trigger a reconnect after close().
      await ws1.serverClose();
      await pumpEventQueue();
      expect(factory.connections, hasLength(1));
      // The auth listener is detached: a token change sends nothing.
      store.save('tok-x', {'id': 'u1'});
      await pumpEventQueue();
      expect(ws1.sent.any((f) => (f as Map)['action'] == 'auth'), isFalse);
      store.dispose();
    });
  });

  group('RealtimeService.subscribeTopic', () {
    test('delivers signal and message frames as TopicMessage', () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final got = <TopicMessage>[];
      final subFut = service.subscribeTopic('orders', got.add);
      await pumpEventQueue();
      final ws = factory.last;
      expect(ws.subscribeFrames, [
        {'action': 'subscribe', 'topic': 'orders'}
      ]);
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'orders'});
      await subFut;

      ws.push({'type': 'signal', 'topic': 'orders'});
      ws.push({
        'type': 'message',
        'topic': 'orders',
        'data': {'n': 1}
      });
      ws.push({
        'type': 'message',
        'topic': 'other',
        'data': {'n': 2}
      }); // other topic -> dropped
      ws.push({'type': 'signal'}); // missing topic -> dropped
      await pumpEventQueue();

      expect(got, hasLength(2));
      expect(got[0].kind, 'signal');
      expect(got[0].topic, 'orders');
      expect(got[0].data, isNull);
      expect(got[1].kind, 'message');
      expect(got[1].data, {'n': 1});
      await service.close();
    });

    test('unsubscribeTopic drops delivery and sends one unsubscribe frame',
        () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final got = <TopicMessage>[];
      final subFut = service.subscribeTopic('orders', got.add);
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'orders'});
      await subFut;

      await service.unsubscribeTopic('orders', got.add);
      ws.push({'type': 'signal', 'topic': 'orders'});
      await pumpEventQueue();
      expect(got, isEmpty);
      expect(ws.unsubscribeFrames, [
        {'action': 'unsubscribe', 'topic': 'orders'}
      ]);
      await service.close();
    });
  });

  group('RealtimeService.stream', () {
    test('emits events and unsubscribes on listener cancel', () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final events = <RecordEvent>[];
      final sub = service.stream('posts').listen(events.add);
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await pumpEventQueue();

      ws.push({
        'type': 'event',
        'topic': 'posts',
        'action': 'create',
        'record': {'id': 'p1'}
      });
      await pumpEventQueue();
      expect(events.single.record.id, 'p1');

      await sub.cancel();
      await pumpEventQueue();
      expect(ws.unsubscribeFrames, [
        {'action': 'unsubscribe', 'topic': 'posts'}
      ]);
      await service.close();
    });

    test('cancel before the ack still tears down the subscription', () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final sub = service.stream('posts').listen((_) {});
      await pumpEventQueue();
      final ws = factory.last;
      // No ack yet — cancel while the subscribe round-trip is in flight.
      await sub.cancel();
      await pumpEventQueue();

      // The ack now arrives; the (already-cancelled) stream must immediately
      // unsubscribe rather than leaving the callback + server sub leaked.
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await pumpEventQueue();
      expect(ws.unsubscribeFrames, [
        {'action': 'unsubscribe', 'topic': 'posts'}
      ]);
      await service.close();
    });

    test('cancel before a REJECTED subscribe raises no unhandled error',
        () async {
      final errors = <Object>[];
      final factory = FakeSocketFactory();
      final service = makeService(factory, onError: errors.add);
      final sub = service.stream('private').listen((_) {});
      await pumpEventQueue();
      final ws = factory.last;
      await sub.cancel();
      await pumpEventQueue();

      // The pending subscribe now rejects; the cancelled stream must swallow
      // it (no unhandled async error — the test would fail loudly on one).
      ws.push({'type': 'error', 'message': 'anonymous not allowed'});
      await pumpEventQueue();
      expect(errors, contains('anonymous not allowed'));
      await service.close();
    });
  });

  group('RealtimeService.close', () {
    test('closes an already-acked stream() controller instead of hanging',
        () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      final events = <RecordEvent>[];
      final doneCompleter = Completer<void>();
      final sub = service
          .stream('posts')
          .listen(events.add, onDone: doneCompleter.complete);
      await pumpEventQueue();
      final ws = factory.last;
      ws.push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await pumpEventQueue();
      ws.push({
        'type': 'event',
        'topic': 'posts',
        'action': 'create',
        'record': {'id': 'p1'}
      });
      await pumpEventQueue();
      expect(events, hasLength(1));

      await service.close();
      await doneCompleter.future.timeout(const Duration(seconds: 2),
          onTimeout: () => fail('stream() did not complete after close()'));
      await sub.cancel();
    });

    test('close() completes even when a stream() was never listened to',
        () async {
      final factory = FakeSocketFactory();
      final service = makeService(factory);
      // Mint a stream but never listen: the controller has no listener, so
      // its close() future never completes. close() must not await it.
      service.stream('posts');

      await service.close().timeout(const Duration(seconds: 5),
          onTimeout: () =>
              fail('close() hung on an unlistened stream() controller'));
    });
  });

  group('RealtimeService post-close lifecycle', () {
    test(
      'close() during an in-flight connect: late channel is torn down, '
      'pending subscribe errors, post-close subscribe throws (no wedge)',
      () async {
        final factory = FakeSocketFactory()..gate = Completer<void>();
        final service = makeService(factory);
        final subFut = service.subscribe('posts', (_) {});
        await pumpEventQueue();
        // The connector is parked on the gate; close before it resolves.
        final closeFut = service.close();
        // close() fails the pending subscribe (no hang).
        await expectLater(subFut, throwsStateError);
        await closeFut;

        // The connect now resolves — after close. The service must close the
        // late channel and must NOT be left wedged in a connecting state.
        factory.gate!.complete();
        await pumpEventQueue();
        expect(factory.connections, hasLength(1));
        expect(factory.last.serviceClosed, isTrue);

        // And any later call fails fast instead of hanging.
        expect(() => service.subscribe('posts', (_) {}), throwsStateError);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'subscribe() after close() throws StateError instead of hanging',
      () async {
        final factory = FakeSocketFactory();
        final service = makeService(factory);
        await service.close();
        await expectLater(service.subscribe('posts', (_) {}), throwsStateError);
        // No connection may be opened by the rejected call.
        await pumpEventQueue();
        expect(factory.connections, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'subscribeTopic() after close() throws StateError instead of hanging',
      () async {
        final factory = FakeSocketFactory();
        final service = makeService(factory);
        await service.close();
        await expectLater(
            service.subscribeTopic('orders', (_) {}), throwsStateError);
        await pumpEventQueue();
        expect(factory.connections, isEmpty);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );

    test(
      'stream() after close() throws StateError at mint time',
      () async {
        final factory = FakeSocketFactory();
        final service = makeService(factory);
        await service.close();
        expect(() => service.stream('posts'), throwsStateError);
      },
      timeout: const Timeout(Duration(seconds: 5)),
    );
  });

  group('wsUrl scheme mapping', () {
    test('https base maps to wss and strips trailing slash', () async {
      final factory = FakeSocketFactory();
      final service = RealtimeService(
        baseUrl: 'https://api.test/',
        authStore: MemoryAuthStore(),
        connector: factory.connect,
        sleep: (d) async {},
      );
      final subFut = service.subscribe('posts', (_) {});
      await pumpEventQueue();
      expect(factory.lastUri.toString(), 'wss://api.test/api/realtime');
      factory.last
          .push({'type': 'ack', 'action': 'subscribe', 'topic': 'posts'});
      await subFut;
      await service.close();
    });
  });
}
