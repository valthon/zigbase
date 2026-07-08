# Dart SDK live store — design

*Status: implemented. Follow-up stream 3b. Ports the TypeScript live tier
(`clients/typescript/src/live/`) to Dart.*

## Goal

Give the Dart SDK the same high-level "same API, now live" surface the
TypeScript SDK has: `client.realtime.collection(name)` returns live records and
lists that stay in sync from realtime events, backed by one shared per-collection
record cache so the same record id is a single object across every view.

The port is behavioral: membership rules, sort/tiebreaker order, the
precise-vs-refetch tier decision, the single-flight debounced refetch, the
cache ref-counting, and the reserved/polluting-key guards all match the TS
source (`live-collection.ts`, `cache.ts`, `filter-eval.ts`) and their tests
exactly.

## The streams decision (Observable contract)

The TS Observable is `{ subscribe(cb) => unsub; get(); version }` — a listener
registry plus a synchronous snapshot and a monotonic version counter.

**Dart port: pure Dart, NO Flutter dependency.** `LiveRecord` and `LiveList`
expose the identical contract realized idiomatically:

```dart
abstract class Observable<T> {
  T get();                    // synchronous current snapshot
  int get version;            // monotonic change counter (bumped BEFORE notify)
  Stream<void> get changes;   // broadcast; one void event per mutation
}
```

- `get()` and `version` are synchronous accessors, matching TS.
- The TS `subscribe(cb)` listener set becomes a broadcast `Stream<void> changes`.
  `changes.listen(...)` is `subscribe`; cancelling the `StreamSubscription` is
  the returned unsubscribe. This is the framework-agnostic core: a future
  companion package can trivially adapt it to a Flutter `ValueListenable`
  (`version` → `notifyListeners`, `get()` → `value`) without this package
  depending on Flutter.
- `version` is bumped **before** the notification is scheduled, so a listener
  that reads `version`/`get()` always observes post-mutation state. Consumers
  that want a synchronous read after every change key on `version`; the stream
  is the "something changed, re-render" nudge.

Notification is asynchronous (default broadcast controller), the idiomatic Dart
choice; synchronous assertions in tests use `version`/`get()`, and
notification-fired assertions listen on `changes` and pump the event queue.

## Deviations from the TS source (all justified)

1. **No dynamic same-named getters.** TS `LiveRecord` uses `Object.defineProperty`
   so `live.title` reads through to the backing object. Dart cannot define
   arbitrary instance properties at runtime, so the wrapper instead exposes the
   backing record via `get()` (a `ZbRecord`, with its own `[]`/`getString`/…
   accessors) and a convenience `operator [](String key)` that delegates to the
   backing data. `live.get().getString('title')` or `live['title']` replaces
   `live.title`. The reserved/polluting-key patch guards are ported verbatim.
2. **`LiveReader` returns item lists, not envelopes.** The TS reader interface
   returns the full `{ items, page, … }` / `{ items, nextCursor }` envelopes and
   the live store immediately projects `.items`. The Dart `LiveReader` returns
   `List<ZbRecord>` directly (the only thing the live store consumes), which is
   cleaner to implement and to fake in tests. The `CollectionService` adapter
   projects its `ListResult`/`CursorPage` down to `.items`.
3. **Injectable scheduler as a Dart typedef pair.** The TS `schedule`/`clear`
   closures become `ScheduleRefetch`/`ClearRefetch` typedefs; the default uses
   `Timer`. Tests inject a manual scheduler that captures the callback.
4. **Polluting keys (`__proto__`/`constructor`/`prototype`)** carry no
   prototype-pollution risk in Dart, but the guard set is ported for
   cross-SDK parity and defense-in-depth (a hostile server payload naming those
   keys is still dropped from patches).

## Tiered correctness rules (ported verbatim)

A filtered live list decides membership with a two-tier strategy;
`LiveList.mode` reports which tier:

- **`precise`** — the filter references only the record's own scalar fields
  (`locallyEvaluable`: no dotted relation paths, no `@`-macros). Each event is
  evaluated client-side: surgical sorted insert (`lowerBound` binary search),
  in-place patch, re-position when a sort key changes, or remove. Zero extra
  requests.
- **`refetch`** — the filter traverses a relation (`author.name = 'Ada'`) or a
  macro (`@request.auth.id = owner`). The client can't evaluate it locally, so
  the list degrades to a **debounced single-flight re-fetch** (default 200ms).
  At most one fetch is in flight; events arriving during a fetch set a rerun
  flag and re-run once on completion (never overlap). Still live, coalesced to
  one request per burst. A failing refetch keeps the previous items (stale
  until the next event schedules another attempt); it never surfaces as an
  unhandled async error.

The sort always appends an `id`-asc tiebreaker (unless the sort already names
`id`) for a deterministic order — matching TS and the server keyset order.

**Known caveat (both SDKs):** precise mode is exact for the events the
subscription delivers, but the subscription is server-side filtered against a
record's *new* state (`src/realtime/hub.zig` `shouldDeliver`) — an update that
moves a record OUT of the filter emits no event, so the stale row lingers until
the next refetch/reload. Cross-SDK follow-up: subscribe unfiltered in precise
mode and let the client-side evaluator drop non-matching records.

## Architecture

```
clients/dart/lib/src/
  query.dart          # + parseSort / compareBySort / SortTerm (ported from query.ts)
  live/
    filter_eval.dart  # parseFilter / evaluateFilter / analyzeFilter + AST
    cache.dart        # Observable, LiveRecord, RecordCache (ref-counted)
    live_collection.dart
                      # LiveReader, LiveSubscriber, LiveList, LiveCollection,
                      # CloseableLiveRecord, scheduler typedefs
  realtime.dart       # + RealtimeService.collection(name) facade
  client.dart         # wires the reader factory into the realtime getter
```

`RealtimeService` gains a `collection(String name)` method (mirroring TS
`client.realtime.collection(name)`); it needs a `LiveReader` factory, which
`ZigbaseClient` injects when it constructs the service (each reader is a thin
adapter over the collection's `CollectionService`). Constructed standalone
(no factory), `collection()` throws a `StateError` explaining the client-owned
path.

`close()` is mandatory on every live record and list; it is idempotent, and
post-close use throws `StateError` — matching the SDK's existing close
contracts (`ZigbaseClient`, `RealtimeService`).
</content>
