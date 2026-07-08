/// Test doubles for the live-store unit tests: an in-memory [LiveSubscriber]
/// the test drives with [FakeLiveSubscriber.emit], and a scriptable
/// [LiveReader]. Mirrors the `fakeRealtime()` / reader stubs in the TS live
/// tests (`clients/typescript/test/live-*.test.ts`).
library;

import 'dart:async';

import 'package:zigbase_client/zigbase_client.dart';

/// Builds a [ZbRecord] from a literal map.
ZbRecord rec(Map<String, dynamic> data) => ZbRecord(data);

/// An in-memory realtime stub. The test pushes events to a topic's callbacks
/// with [emit] and inspects [subscriberCount] / [unsubFnCalls].
class FakeLiveSubscriber implements LiveSubscriber {
  final Map<String, Set<void Function(RecordEvent)>> _subs = {};

  /// How many times a returned unsubscribe closure was invoked.
  int unsubFnCalls = 0;

  @override
  Future<ZbUnsubscribe> subscribe(
    String topic,
    void Function(RecordEvent) callback, {
    String? filter,
  }) async {
    _subs.putIfAbsent(topic, () => {}).add(callback);
    return () async {
      unsubFnCalls += 1;
      _subs[topic]?.remove(callback);
    };
  }

  /// Deliver [event] to every callback subscribed to [topic].
  void emit(String topic, RecordEvent event) {
    for (final cb in (_subs[topic] ?? const {}).toList()) {
      cb(event);
    }
  }

  /// Live callback count for [topic].
  int subscriberCount(String topic) => _subs[topic]?.length ?? 0;
}

/// A scriptable [LiveReader]. Assign the `onGet*` closures the test needs.
class FakeReader implements LiveReader {
  Future<ZbRecord> Function(String id)? onGetOne;
  Future<List<ZbRecord>> Function()? onGetListItems;
  Future<List<ZbRecord>> Function()? onGetPageItems;

  /// Total getListItems calls (seed + refetches).
  int listCalls = 0;

  @override
  Future<ZbRecord> getOne(String id, {String? expand, String? fields}) =>
      onGetOne!(id);

  @override
  Future<List<ZbRecord>> getListItems(
    int page,
    int perPage, {
    String? filter,
    String? sort,
    String? expand,
    String? fields,
  }) {
    listCalls += 1;
    return onGetListItems!();
  }

  @override
  Future<List<ZbRecord>> getPageItems({
    String? cursor,
    int? limit,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
  }) =>
      onGetPageItems!();
}
