/// The high-level live store: [LiveCollection] hands out [LiveList]s and
/// [CloseableLiveRecord]s that stay in sync from realtime events.
///
/// A behavioral port of `clients/typescript/src/live/live-collection.ts`,
/// adapted to Dart streams (see
/// `docs/superpowers/specs/2026-07-08-dart-live-store-design.md`). Membership
/// rules, sort/tiebreaker order, the precise-vs-refetch tier decision, and the
/// single-flight debounced refetch all match the TS source.
library;

import 'dart:async';
import 'dart:convert';

import '../collection.dart';
import '../paths.dart';
import '../query.dart';
import '../realtime.dart';
import '../records.dart';
import 'cache.dart';
import 'filter_eval.dart';

/// The subset of a collection's read API the live store seeds through. The
/// [CollectionService] adapter projects its `ListResult`/`CursorPage`
/// envelopes down to the `items` lists this needs.
abstract class LiveReader {
  Future<ZbRecord> getOne(String id, {String? expand, String? fields});

  Future<List<ZbRecord>> getListItems(
    int page,
    int perPage, {
    String? filter,
    String? sort,
    String? expand,
    String? fields,
  });

  Future<List<ZbRecord>> getPageItems({
    String? cursor,
    int? limit,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
  });
}

/// The subset of [RealtimeService] the live store subscribes through.
abstract class LiveSubscriber {
  Future<ZbUnsubscribe> subscribe(
    String topic,
    void Function(RecordEvent) callback, {
    String? filter,
  });
}

/// Adapts a [CollectionService] to the [LiveReader] the live store consumes,
/// projecting its `ListResult`/`CursorPage` envelopes down to `items` lists.
/// This is the reader `ZigbaseClient` injects into the realtime facade.
class CollectionLiveReader implements LiveReader {
  final CollectionService _collection;

  CollectionLiveReader(this._collection);

  @override
  Future<ZbRecord> getOne(String id, {String? expand, String? fields}) =>
      _collection.getOne(id, expand: expand, fields: fields);

  @override
  Future<List<ZbRecord>> getListItems(
    int page,
    int perPage, {
    String? filter,
    String? sort,
    String? expand,
    String? fields,
  }) async {
    final r = await _collection.getList(
        page: page,
        perPage: perPage,
        filter: filter,
        sort: sort,
        expand: expand,
        fields: fields);
    return r.items;
  }

  @override
  Future<List<ZbRecord>> getPageItems({
    String? cursor,
    int? limit,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
  }) async {
    final r = await _collection.getPage(
        cursor: cursor,
        limit: limit ?? 30,
        filter: filter,
        sort: sort,
        expand: expand,
        fields: fields);
    return r.items;
  }
}

/// Schedules a debounced refetch [run] after [delay]; returns an opaque handle
/// the store passes back to [ClearRefetch]. The default uses a [Timer]; tests
/// inject a manual scheduler that captures [run].
typedef ScheduleRefetch = Object Function(void Function() run, Duration delay);

/// Cancels a pending refetch previously scheduled by a [ScheduleRefetch].
typedef ClearRefetch = void Function(Object handle);

Object _defaultSchedule(void Function() run, Duration delay) =>
    Timer(delay, run);

void _defaultClear(Object handle) {
  if (handle is Timer) handle.cancel();
}

/// Correctness tier of a live list: precise local membership vs. server
/// refetch. Read via [LiveList.mode].
enum LiveListMode { precise, refetch }

/// A wrapped record from [LiveCollection.getOne], with an explicit teardown.
///
/// Delegates the [Observable] surface to the shared cached [LiveRecord] (so it
/// participates in cache identity), and adds [close]: unsubscribe the
/// `name/id` topic and release this handle's cache ref. [close] is idempotent;
/// post-close use throws [StateError].
class CloseableLiveRecord implements Observable<ZbRecord> {
  final LiveRecord _inner;
  final void Function() _onClose;
  bool _closed = false;

  CloseableLiveRecord._(this._inner, this._onClose);

  void _check() {
    if (_closed) throw StateError('live record has been closed');
  }

  /// Whether [close] has run.
  bool get isClosed => _closed;

  @override
  ZbRecord get() {
    _check();
    return _inner.get();
  }

  /// The current data; alias of [get].
  ZbRecord get data {
    _check();
    return _inner.data;
  }

  @override
  int get version {
    _check();
    return _inner.version;
  }

  @override
  Stream<void> get changes {
    _check();
    return _inner.changes;
  }

  /// The record id.
  String get id {
    _check();
    return _inner.id;
  }

  /// `true` once a delete event has been applied to the underlying record.
  bool get deleted {
    _check();
    return _inner.deleted;
  }

  /// Reads a raw backing field.
  dynamic operator [](String key) {
    _check();
    return _inner[key];
  }

  /// Unsubscribe the `name/id` topic and release this record's cache ref.
  /// Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    _onClose();
  }
}

/// An ordered, live list of [LiveRecord]s kept in sync from realtime events.
///
/// Implements the [Observable] contract over `List<LiveRecord>`. On a
/// create/update/delete event a **precise** list surgically inserts (at the
/// sorted position), patches in place, re-positions on a sort-key change, or
/// removes; a **refetch** list (relation/macro filter) debounces a
/// single-flight re-fetch instead. [close] is mandatory and idempotent;
/// post-close use throws [StateError].
class LiveList implements Observable<List<LiveRecord>> {
  final RecordCache _cache;
  final List<LiveRecord> _items = [];

  /// O(1) id -> record index kept in sync with [_items].
  final Map<String, LiveRecord> _index = {};
  final StreamController<void> _changes = StreamController<void>.broadcast();
  int _version = 0;

  final List<SortTerm> _sortTerms;
  final FilterNode? _filterAst;
  final bool _precise;

  final Future<List<ZbRecord>> Function() _onRefetch;
  final Duration _debounce;
  final ScheduleRefetch _schedule;
  final ClearRefetch _clear;
  Object? _refetchTimer;

  // Coalescing guard: true from the moment a debounce is scheduled until its
  // callback fires. Used instead of `_refetchTimer != null` because a
  // synchronous scheduler fires the callback (which nulls `_refetchTimer`)
  // BEFORE `_schedule` returns the handle we then store — so the handle can be
  // stale, but this flag always reflects "a debounce is currently pending".
  bool _refetchPending = false;

  // Refetch concurrency guard.
  bool _refetchInFlight = false;
  bool _rerunRequested = false;

  // Teardown.
  ZbUnsubscribe? _unsub;
  bool _closed = false;

  LiveList._(
    this._cache,
    List<ZbRecord> seed, {
    FilterNode? filterAst,
    String? sort,
    required Future<List<ZbRecord>> Function() onRefetch,
    required Duration debounce,
    required ScheduleRefetch schedule,
    required ClearRefetch clear,
  })  : _sortTerms = _appendIdTiebreaker(parseSort(sort ?? '')),
        _filterAst = filterAst,
        _precise = analyzeFilter(filterAst).locallyEvaluable,
        _onRefetch = onRefetch,
        _debounce = debounce,
        _schedule = schedule,
        _clear = clear {
    for (final rec in seed) {
      final live = _cache.retain(rec);
      _items.add(live);
      _index[live.id] = live;
    }
    _sortItems();
  }

  void _check() {
    if (_closed) throw StateError('LiveList has been closed');
  }

  /// Which correctness tier this list operates in.
  LiveListMode get mode {
    _check();
    return _precise ? LiveListMode.precise : LiveListMode.refetch;
  }

  @override
  int get version {
    _check();
    return _version;
  }

  @override
  List<LiveRecord> get() {
    _check();
    return _items;
  }

  /// The live items, ordered by the query sort. Alias of [get]; a stable,
  /// mutated reference (its identity does not change as items move).
  List<LiveRecord> get items {
    _check();
    return _items;
  }

  @override
  Stream<void> get changes {
    _check();
    return _changes.stream;
  }

  /// O(1) membership lookup by id.
  LiveRecord? getById(String id) {
    _check();
    return _index[id];
  }

  /// Store the realtime unsubscribe so [close] can tear it down.
  void _setUnsub(ZbUnsubscribe unsub) {
    if (_closed) {
      // Closed before the subscribe resolved — tear it down immediately.
      unawaited(unsub());
      return;
    }
    _unsub = unsub;
  }

  /// Tear down the list: drop the realtime subscription, cancel any pending
  /// refetch, release every retained cache ref, and close the change stream.
  /// Idempotent.
  void close() {
    if (_closed) return;
    _closed = true;

    final timer = _refetchTimer;
    if (timer != null && _refetchPending) {
      _clear(timer);
    }
    _refetchTimer = null;
    _refetchPending = false;
    final unsub = _unsub;
    _unsub = null;
    if (unsub != null) unawaited(unsub());

    for (final rec in _items) {
      _cache.release(rec.id);
    }
    _items.clear();
    _index.clear();
    unawaited(_changes.close());
  }

  /// Called by [LiveCollection] for each realtime event on the collection
  /// topic.
  void handleEvent(RecordEvent event) {
    if (_closed) return;
    if (!_precise) {
      _scheduleRefetch();
      return;
    }
    if (event.action == 'delete') {
      _removeById(event.record.id);
      return;
    }
    final matches = _filterAst != null
        ? evaluateFilter(event.record.data, _filterAst)
        : true;
    final existing = _index[event.record.id];
    if (matches) {
      if (existing == null) {
        _insertNew(event.record);
        _bump();
      } else {
        final before = _sortKeyOf(existing);
        _cache.applyUpdate(event.record);
        // Only re-sort if the record's sort keys actually moved.
        if (_sortKeyOf(existing) != before) _reposition(existing);
        _bump();
      }
    } else if (existing != null) {
      _removeById(event.record.id);
    }
  }

  /// Insert a freshly-retained record at its sorted position (binary search).
  void _insertNew(ZbRecord rec) {
    final live = _cache.retain(rec);
    _index[live.id] = live;
    final at = _lowerBound(live);
    _items.insert(at, live);
  }

  /// Re-place an already-present record after its sort keys changed.
  void _reposition(LiveRecord live) {
    final cur = _items.indexOf(live);
    if (cur != -1) _items.removeAt(cur);
    final at = _lowerBound(live);
    _items.insert(at, live);
  }

  /// First index whose record sorts >= [live] (binary search over the
  /// comparator).
  int _lowerBound(LiveRecord live) {
    var lo = 0;
    var hi = _items.length;
    final key = live.get().data;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (compareBySort(_items[mid].get().data, key, _sortTerms) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Cheap signature of a record's sort keys, to detect whether it moved.
  String _sortKeyOf(LiveRecord live) {
    final data = live.get().data;
    return _sortTerms
        .map((t) => jsonEncode(readDottedPath(data, t.field)))
        .join(' ');
  }

  /// Remove [id] from the list (and release its cache ref). Pass
  /// `notify: false` when the caller batches its own single [_bump] (the
  /// reconcile loop), so observers see one notification per reconcile rather
  /// than one per dropped row.
  void _removeById(String id, {bool notify = true}) {
    final live = _index[id];
    if (live == null) return;
    final idx = _items.indexOf(live);
    if (idx != -1) _items.removeAt(idx);
    _index.remove(id);
    _cache.release(id);
    if (notify) _bump();
  }

  void _sortItems() {
    _items
        .sort((a, b) => compareBySort(a.get().data, b.get().data, _sortTerms));
  }

  void _scheduleRefetch() {
    if (_refetchPending) return;
    _refetchPending = true;
    _refetchTimer = _schedule(() {
      _refetchPending = false;
      _refetchTimer = null;
      unawaited(_doRefetch());
    }, _debounce);
  }

  /// Refetch the query and reconcile. Guarded so at most one fetch is in
  /// flight: a request that arrives while one is running sets [_rerunRequested]
  /// and re-runs once on completion instead of overlapping.
  ///
  /// Failure contract: a failing refetch (network error, auth expiry, …) is
  /// swallowed — the list simply keeps its previous items (stale until the
  /// next event schedules another refetch, which starts from a clean
  /// single-flight state and can recover). It never surfaces as an unhandled
  /// async error.
  Future<void> _doRefetch() async {
    if (_closed) return;
    if (_refetchInFlight) {
      _rerunRequested = true;
      return;
    }
    _refetchInFlight = true;
    try {
      final List<ZbRecord> fresh;
      try {
        fresh = await _onRefetch();
      } catch (_) {
        // Keep the previous items; see the failure contract above. The
        // enclosing finally still clears the single-flight state (and honors a
        // rerun request), so a later refetch is not wedged.
        return;
      }
      if (_closed) return;
      _reconcile(fresh);
    } finally {
      _refetchInFlight = false;
      if (_rerunRequested && !_closed) {
        _rerunRequested = false;
        unawaited(_doRefetch());
      }
    }
  }

  void _reconcile(List<ZbRecord> fresh) {
    final nextIds = fresh.map((r) => r.id).toSet();
    // Release rows that fell out (without a per-row notification; the single
    // _bump below covers the whole reconcile).
    for (final r in _items.toList()) {
      if (!nextIds.contains(r.id)) _removeById(r.id, notify: false);
    }
    // Insert/patch the fresh set.
    for (final rec in fresh) {
      final existing = _index[rec.id];
      if (existing == null) {
        final live = _cache.retain(rec);
        _index[live.id] = live;
        _items.add(live);
      } else {
        _cache.applyUpdate(rec);
      }
    }
    _sortItems();
    _bump();
  }

  void _bump() {
    _version += 1;
    if (!_changes.isClosed) _changes.add(null);
  }
}

List<SortTerm> _appendIdTiebreaker(List<SortTerm> terms) {
  if (terms.any((t) => t.field == 'id')) return terms;
  return [...terms, const SortTerm('id', 'asc')];
}

/// The live-store entry point for one collection. Backed by one shared record
/// cache, so the same record id is a single [LiveRecord] across every view.
///
/// Obtain via `client.realtime.collection(name)`, or construct directly with a
/// [LiveReader] + [LiveSubscriber] (e.g. in tests).
class LiveCollection {
  final String name;
  final LiveReader _reader;
  final LiveSubscriber _subscriber;
  final RecordCache _cache;

  /// [cache] lets an owner (the `client.realtime.collection(name)` facade)
  /// share one [RecordCache] across every [LiveCollection] view of the same
  /// collection, so the same record id is a single [LiveRecord] SDK-wide.
  /// Omitted (tests, standalone use), a private cache is created.
  LiveCollection(this.name, this._reader, this._subscriber,
      {RecordCache? cache})
      : _cache = cache ?? RecordCache();

  /// The shared per-collection cache (exposed for teardown assertions in
  /// tests).
  RecordCache get cache => _cache;

  /// Returns a wrapped live record, seeded via REST and kept live via the
  /// `name/id` topic. Call [CloseableLiveRecord.close] when done.
  Future<CloseableLiveRecord> getOne(
    String id, {
    String? expand,
    String? fields,
  }) async {
    final seed = await _reader.getOne(id, expand: expand, fields: fields);
    final live = _cache.retain(seed);
    var closed = false;
    ZbUnsubscribe? unsub;

    void onClose() {
      if (closed) return;
      closed = true;
      final u = unsub;
      unsub = null;
      if (u != null) unawaited(u());
      _cache.release(id);
    }

    final handle = CloseableLiveRecord._(live, onClose);

    final off = await _subscriber.subscribe('$name/$id', (event) {
      if (event.action == 'delete') {
        _cache.applyDelete(id);
      } else {
        _cache.applyUpdate(event.record);
      }
    });
    if (closed) {
      unawaited(off());
    } else {
      unsub = off;
    }

    return handle;
  }

  /// Offset-seeded live list. `perPage` follows the reader's own clamping.
  Future<LiveList> getList({
    int page = 1,
    int perPage = 30,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
    Duration refetchDebounce = const Duration(milliseconds: 200),
    ScheduleRefetch? schedule,
    ClearRefetch? clearSchedule,
  }) async {
    final seed = await _reader.getListItems(page, perPage,
        filter: filter, sort: sort, expand: expand, fields: fields);
    return _buildList(
      seed,
      filter: filter,
      sort: sort,
      onRefetch: () => _reader.getListItems(page, perPage,
          filter: filter, sort: sort, expand: expand, fields: fields),
      refetchDebounce: refetchDebounce,
      schedule: schedule,
      clearSchedule: clearSchedule,
    );
  }

  /// Cursor-seeded live list.
  Future<LiveList> getPage({
    String? cursor,
    int limit = 30,
    String? filter,
    String? sort,
    String? expand,
    String? fields,
    Duration refetchDebounce = const Duration(milliseconds: 200),
    ScheduleRefetch? schedule,
    ClearRefetch? clearSchedule,
  }) async {
    final seed = await _reader.getPageItems(
        cursor: cursor,
        limit: limit,
        filter: filter,
        sort: sort,
        expand: expand,
        fields: fields);
    return _buildList(
      seed,
      filter: filter,
      sort: sort,
      onRefetch: () => _reader.getPageItems(
          cursor: cursor,
          limit: limit,
          filter: filter,
          sort: sort,
          expand: expand,
          fields: fields),
      refetchDebounce: refetchDebounce,
      schedule: schedule,
      clearSchedule: clearSchedule,
    );
  }

  Future<LiveList> _buildList(
    List<ZbRecord> seed, {
    String? filter,
    String? sort,
    required Future<List<ZbRecord>> Function() onRefetch,
    required Duration refetchDebounce,
    ScheduleRefetch? schedule,
    ClearRefetch? clearSchedule,
  }) async {
    // Parse the filter exactly once; the AST feeds both the membership
    // evaluator and the precise-vs-refetch analysis inside LiveList.
    final filterAst = filter != null ? parseFilter(filter) : null;
    final list = LiveList._(
      _cache,
      seed,
      filterAst: filterAst,
      sort: sort,
      onRefetch: onRefetch,
      debounce: refetchDebounce,
      schedule: schedule ?? _defaultSchedule,
      clear: clearSchedule ?? _defaultClear,
    );
    // Known cross-SDK gap (mirrors the TS live tier): the subscription itself
    // is server-side filtered, and the server evaluates the filter on the
    // record's NEW state (src/realtime/hub.zig shouldDeliver) — so an update
    // that moves a record OUT of the filter emits no event, and a precise list
    // keeps the stale row until the next refetch/reload. Follow-up: subscribe
    // unfiltered in precise mode and let the client-side evaluator drop it.
    final unsub =
        await _subscriber.subscribe(name, list.handleEvent, filter: filter);
    list._setUnsub(unsub);
    return list;
  }
}
