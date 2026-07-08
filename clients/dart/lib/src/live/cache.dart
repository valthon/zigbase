/// The observable contract, the live-record wrapper, and the ref-counted
/// per-collection record cache.
///
/// A behavioral port of `clients/typescript/src/live/cache.ts`, adapted to a
/// pure-Dart, framework-agnostic streams model (see
/// `docs/superpowers/specs/2026-07-08-dart-live-store-design.md`).
library;

import 'dart:async';

import '../records.dart';

/// Reserved fields owned by the wrapper; never patched from a server payload.
const _reservedKeys = {'id', 'version', 'deleted'};

/// Keys that could reassign a prototype / mutate intrinsics in JS. Harmless in
/// Dart, but dropped from patches for cross-SDK parity and defense-in-depth.
const _pollutingKeys = {'__proto__', 'constructor', 'prototype'};

bool _isReservedKey(String key) => _reservedKeys.contains(key);

bool _isSafePatchKey(String key) =>
    !_reservedKeys.contains(key) && !_pollutingKeys.contains(key);

/// Framework-agnostic observable contract (matches the spec).
///
/// [get] is the synchronous current snapshot; [version] a monotonic counter
/// bumped BEFORE each change notification; [changes] a broadcast stream that
/// emits one void event per mutation. `changes.listen(...)` is the TS
/// `subscribe(cb)`; cancelling the subscription is the returned unsubscribe.
abstract class Observable<T> {
  /// The current backing value.
  T get();

  /// A monotonic counter incremented on every mutation, before [changes] fires.
  int get version;

  /// A broadcast stream nudged once per mutation.
  Stream<void> get changes;
}

/// A wrapped record with a stable identity. Updates patch the backing record
/// IN PLACE and bump [version]; deletes set [deleted]. Bind via the
/// [Observable] contract; read fields through [get] (a [ZbRecord]) or the
/// convenience [operator []].
class LiveRecord implements Observable<ZbRecord> {
  bool _deleted = false;
  int _version = 0;
  final ZbRecord _backing;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  LiveRecord(ZbRecord initial) : _backing = initial;

  /// The record id.
  String get id => _backing.id;

  /// `true` once a delete event has been applied.
  bool get deleted => _deleted;

  @override
  int get version => _version;

  @override
  ZbRecord get() => _backing;

  /// The current data; alias of [get] kept for ergonomics.
  ZbRecord get data => _backing;

  @override
  Stream<void> get changes => _changes.stream;

  /// Reads a raw backing field. Replaces TS's dynamic `live.title` getter,
  /// which Dart cannot synthesize at runtime.
  dynamic operator [](String key) => _backing.data[key];

  /// Patch backing fields in place (used by the cache on update events).
  ///
  /// Mutates the SAME backing map so external [get] references stay live. Only
  /// safe own keys are copied; reserved fields (`id`/`version`/`deleted`) are
  /// owned by the wrapper and left untouched, and `__proto__`/`constructor`/
  /// `prototype` are dropped.
  void patch(ZbRecord next) {
    final target = _backing.data;
    final safeKeys = next.data.keys.where(_isSafePatchKey).toList();
    final safeSet = safeKeys.toSet();
    // Drop keys that disappeared from the payload (but keep reserved fields).
    for (final k in target.keys.toList()) {
      if (!safeSet.contains(k) && !_isReservedKey(k)) {
        target.remove(k);
      }
    }
    for (final k in safeKeys) {
      target[k] = next.data[k];
    }
    _bump();
  }

  /// Flag this record deleted and notify.
  void markDeleted() {
    _deleted = true;
    _bump();
  }

  void _bump() {
    _version += 1;
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Close the change stream. Called by [RecordCache] on eviction; not part of
  /// the public API.
  void dispose() {
    if (!_changes.isClosed) unawaited(_changes.close());
  }
}

class _Entry {
  final LiveRecord record;
  int refs;
  _Entry(this.record, this.refs);
}

/// Per-collection record cache keyed by record id. Hands out the SAME
/// [LiveRecord] for a given id so one event updates every view. Ref-counted:
/// retained while >= 1 live view/observer references it; evicted at zero.
class RecordCache {
  final Map<String, _Entry> _entries = {};

  /// Retain (and create-or-merge) the record for `data.id`; +1 refcount.
  LiveRecord retain(ZbRecord data) {
    final existing = _entries[data.id];
    if (existing != null) {
      existing.refs += 1;
      // Merge fresher data without losing identity.
      existing.record.patch(data);
      return existing.record;
    }
    final record = LiveRecord(data);
    _entries[data.id] = _Entry(record, 1);
    return record;
  }

  /// The cached record for [id], or null.
  LiveRecord? get(String id) => _entries[id]?.record;

  /// Whether [id] is currently retained.
  bool has(String id) => _entries.containsKey(id);

  /// Release one ref for [id]; evict and dispose the record at zero.
  void release(String id) {
    final entry = _entries[id];
    if (entry == null) return;
    entry.refs -= 1;
    if (entry.refs <= 0) {
      _entries.remove(id);
      entry.record.dispose();
    }
  }

  /// Apply an update event to the cached record for `data.id`, if present.
  void applyUpdate(ZbRecord data) => _entries[data.id]?.record.patch(data);

  /// Apply a delete event to the cached record for [id], if present.
  void applyDelete(String id) => _entries[id]?.record.markDeleted();
}
