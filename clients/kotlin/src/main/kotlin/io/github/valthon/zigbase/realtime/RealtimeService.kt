package io.github.valthon.zigbase.realtime

/*
 * The multiplexing core: connect-on-first-subscribe, ack-gated subscribe/
 * unsubscribe, and frame dispatch over one [RealtimeConnection].
 *
 * Port of `RealtimeService` in `clients/python/src/zigbase/realtime.py` --
 * this ports its connect/subscribe/ack/dispatch/close core, the auth
 * lifecycle (`_on_open`'s auth-gated resubscribe, `_send_auth_frame`, the
 * `auth_store.on_change` re-auth listener), AND reconnect with bounded
 * exponential backoff (`_schedule_reconnect`/`_reconnect`), matching every
 * guard recorded in that file's docstrings (each traces back to a review
 * finding). See [scheduleReconnect]/[reconnect] for the backoff shape: an
 * unexpected drop (not a user [close]) or a connector failure re-opens the
 * connection after `min(10_000, 250 shl attempts)` ms (the injectable
 * [delayFn] constructor param, swappable in tests same as [connector]),
 * gated on there being at least one live subscription left to resurrect the
 * socket for, then re-authenticates and [resubscribeAll] resends every
 * surviving subscription's frame -- including one whose ack never arrived
 * before the drop, whose original caller's pending deferred settles on the
 * fresh ack the reconnected socket eventually delivers.
 *
 * Auth lifecycle: on a fresh open, a present [authStore] token is sent
 * FIRST via an `auth` frame, and [resubscribeAll] is gated on that frame's
 * reply SETTLING -- `ok` or `error` alike (a failed auth is surfaced via
 * [onError], never by blocking or failing the resubscribe), so a
 * subscription whose view rule is `@public` still resubscribes even when
 * auth itself fails; an anonymous open resubscribes at once, sending no
 * auth frame. An [authStore] `onChange` listener registered at construction
 * re-sends the event's token (or `""` on logout) verbatim whenever it
 * fires while the socket is open. See [onOpen]/[sendAuthFrame]/
 * [onAuthFrame]/[onAuthStoreChange]/[failAuthGate].
 *
 * Ownership divergence from the Python/TS/Dart ports: this service owns a
 * private [CoroutineScope] (`SupervisorJob` + `Dispatchers.Default`) rather
 * than piggybacking on a caller-supplied scope or an ambient event loop --
 * the persistent receive loop is a child of that scope, and [close] tears
 * the whole scope down. Unlike Python's single-threaded asyncio event loop
 * (where a `subscribe()` call's synchronous prefix can never be interleaved
 * with the receive loop, or another `subscribe()` call, except at an
 * explicit `await`), `Dispatchers.Default` gives real, multi-threaded
 * parallelism -- so, unlike the Python port, every mutation of shared state
 * (the subscription map, connection identity, the connect/connecting/
 * reconnect-pending flags) here goes through [mutex], including
 * check-and-set sequences the Python port gets for free from cooperative
 * scheduling. [sendSubscribeIfNeeded] in particular folds its
 * eligibility-check and its `inflight`-mark into one locked section so two
 * concurrent subscribers to the same key can never both decide to send a
 * frame -- a real race on real threads that Python's design doesn't have to
 * guard against.
 */

import io.github.valthon.zigbase.RealtimeEvent
import io.github.valthon.zigbase.TopicMessage
import io.github.valthon.zigbase.ZbRecord
import io.github.valthon.zigbase.auth.AuthStore
import io.github.valthon.zigbase.errors.ZigbaseException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineName
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ChannelResult
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.buffer
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

private const val CLOSED_MESSAGE = "realtime client closed"

// Reconnect backoff bounds (port of Python's `_RECONNECT_MIN_DELAY`/
// `_RECONNECT_MAX_DELAY`/`_RECONNECT_MAX_SHIFT`): `delay = min(MAX, MIN shl
// attempts.coerceAtMost(MAX_SHIFT))`. The shift is capped well past the point
// the delay already saturates at [RECONNECT_MAX_DELAY_MS] so a long-lived
// connection's ever-growing `attempts` counter can never overflow the shift.
private const val RECONNECT_MIN_DELAY_MS = 250L
private const val RECONNECT_MAX_DELAY_MS = 10_000L
private const val RECONNECT_MAX_SHIFT = 20

private val defaultLogger: System.Logger = System.getLogger("io.github.valthon.zigbase.realtime")

private fun defaultOnError(message: String) {
    defaultLogger.log(System.Logger.Level.WARNING, message)
}

// Record- and topic-subscription keys share one map, so their key spaces
// must be structurally disjoint: the `r:`/`t:` prefixes guarantee no record
// key (however adversarial the topic/filter text) can collide with a topic
// key -- see the `r:`/`t:` collision regression test.
private fun subKey(
    topic: String,
    filter: String?,
): String = if (filter == null) "r:$topic" else "r:$topic $filter"

private fun topicKey(topic: String): String = "t:$topic"

private fun stringField(
    obj: JsonObject,
    key: String,
): String? = (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

private enum class SubKind { RECORDS, TOPIC }

/**
 * Outcome of [RealtimeService.sendAuthFrame]'s atomic staleness-check-and-send
 * section (held under `authSendMutex`): [Stale] means a newer send already
 * won the ordering race and this frame was never written to the wire; [Sent]
 * carries the ack to await (freshly created or reused, always created BEFORE
 * `authSendMutex` is released -- see that method's doc for why this ordering
 * closes the orphan-ack gap); [SendFailed] means the frame was attempted but
 * the transport write itself threw.
 */
private sealed class AuthSendOutcome {
    object Stale : AuthSendOutcome()

    data class Sent(
        val ack: CompletableDeferred<Unit>,
    ) : AuthSendOutcome()

    data class SendFailed(
        val message: String,
    ) : AuthSendOutcome()
}

/** All fields are guarded by [RealtimeService.mutex]; never mutate directly. */
private class Subscription(
    val topic: String,
    val kind: SubKind,
    val filter: String? = null,
) {
    val callbacks: MutableSet<suspend (RealtimeEvent) -> Unit> = linkedSetOf()
    val topicCallbacks: MutableSet<suspend (TopicMessage) -> Unit> = linkedSetOf()

    // Futures waiting on the `ack` of the in-flight subscribe frame.
    val pending: MutableList<CompletableDeferred<Unit>> = mutableListOf()
    var acked: Boolean = false

    // A subscribe frame is on the wire awaiting its ack -- concurrent
    // subscribers must join `pending` without sending a duplicate frame.
    var inflight: Boolean = false
}

/**
 * Multiplexes realtime subscriptions over a single [RealtimeConnection].
 *
 * Port of `RealtimeService` in `clients/python/src/zigbase/realtime.py` (see
 * this file's header comment for the exact scope of this port). Connects
 * lazily on the first [subscribe]/[subscribeTopic] call; every subscribe is
 * gated on the server's `ack` frame for its topic, and concurrent
 * subscribers to the same topic/filter share one wire frame. Not
 * constructible directly -- obtain one from the top-level client once it
 * wires this in.
 */
class RealtimeService internal constructor(
    private val baseUrl: String,
    // A present token is sent on open (gating resubscribe on the reply
    // settling) and re-sent on every token change while connected; see the
    // class doc's "Auth lifecycle" paragraph.
    private val authStore: AuthStore,
    private val connector: suspend (String) -> RealtimeConnection,
    onError: ((String) -> Unit)? = null,
    // Reconnect backoff sleep, indirected through an injectable param --
    // mirroring [connector] -- so tests can collapse (or observe/gate) the
    // delay instead of waiting on the wall clock. Defaults to a real
    // `kotlinx.coroutines.delay`.
    private val delayFn: suspend (Long) -> Unit = { ms -> delay(ms) },
) {
    private val onError: (String) -> Unit = onError ?: ::defaultOnError

    private val supervisorJob = SupervisorJob()
    private val scope: CoroutineScope =
        CoroutineScope(supervisorJob + Dispatchers.Default + CoroutineName("zigbase-realtime"))

    private val mutex = Mutex()
    private val subscriptions = mutableMapOf<String, Subscription>()

    private var activeConnection: RealtimeConnection? = null
    private var opened = false
    private var connecting = false
    private var reconnectPending = false

    // Consecutive-failure counter driving the backoff shift in [reconnect];
    // reset to 0 on every successful open (see [connectOnce]) same as
    // Python's `_reconnect_attempts`.
    private var reconnectAttempts = 0
    private var receiveJob: Job? = null

    // Auth lifecycle. `authAck` is the in-flight auth-reply deferred, REUSED
    // across back-to-back sends (see `sendAuthFrame`) so rapid token churn
    // before any reply arrives shares one waiter that settles together on
    // the first response. A `CompletableDeferred<Unit>` (not `<Boolean>`)
    // was chosen to mirror the Python port's `asyncio.Future[None]` exactly:
    // it completes normally on an `ok` reply and exceptionally on anything
    // else, so `sendAuthFrame`'s `ack.await()` can reuse the same
    // catch-and-report-via-onError shape as every other guarded send in
    // this file, rather than branching on a `Boolean` result. Every access
    // goes through `mutex`, same as every other field above.
    private var authAck: CompletableDeferred<Unit>? = null

    // Ordering guard for the ACTUAL on-wire auth send, deliberately kept
    // separate from `mutex`: unlike Python's single-threaded event loop,
    // `Dispatchers.Default` gives no ordering guarantee across two
    // independently `scope.launch`ed re-auth coroutines (see
    // `onAuthStoreChange`) -- a login immediately followed by a logout
    // could otherwise reach the wire in EITHER order, leaving the server
    // authenticated on a stale token even though the client already
    // considers itself logged out. `authSeqCounter` is incremented
    // SYNCHRONOUSLY inside `onAuthStoreChange` (the one place with a true
    // ordering signal: `AuthStore.save()`/`clear()` call listeners in strict
    // call order on the calling thread) and threaded through to
    // `sendAuthFrame`, which drops any send whose sequence number is older
    // than the newest one already accepted -- so the wire always converges
    // on the LATEST intended token regardless of how the launches get
    // scheduled. `authSendMutex` -- not `mutex` -- guards the check+write so
    // this can hold across the actual (usually brief) `conn.send()` call
    // without contending with unrelated subscribe/unsubscribe/dispatch work
    // on the shared `mutex`.
    private val authSeqCounter = AtomicLong(0)
    private val authSendMutex = Mutex()
    private var latestAuthSendSeq = 0L

    // Registered at construction (this service owns a live `scope` from the
    // start, unlike the Python port which must lazily capture the running
    // loop) so `authStore.save()`/`clear()` -- which may call listeners
    // synchronously from ANY thread -- always has somewhere safe to hand
    // off to. `close()` calls this to detach the listener so a save/clear
    // after close sends nothing.
    private val authUnsubscribe: () -> Unit = authStore.onChange(::onAuthStoreChange)

    // Read on the `raiseIfClosed()` fast path without the mutex, so this
    // must stay volatile for cross-thread visibility; every write to it
    // happens inside `mutex.withLock` (in `close()`) regardless.
    @Volatile
    private var closedByUser = false

    // Guards [shutdown]'s idempotency (its own entry gate, distinct from the
    // mutex-guarded `closedByUser` check [close] uses -- [shutdown] must
    // never suspend to take `mutex` for that check).
    private val shutdownStarted = AtomicBoolean(false)

    /**
     * Test-only. When `true`, [shutdown] skips its best-effort
     * `mutex.tryLock()` pending-ack-failure step entirely -- deterministically
     * simulating the (normally rare, race-dependent) outcome where that
     * `tryLock` loses. A test uses this to prove [subscribe]/[subscribeTopic]
     * still unblock via [closeSignal] even when nothing explicitly fails
     * their pending ack. `false` (the default) is a no-op.
     */
    @Volatile
    internal var testHookForceShutdownSkipAckFail = false

    // Completed exactly once, in `close()`, right after the `closedByUser`
    // transition -- lets [stream]/[streamTopic] end their flow with a clean
    // channel close (no cause) instead of throwing, distinguishing a
    // service-initiated close from a REJECTED subscribe (which throws the
    // server's error into the collector, same as [subscribe] itself).
    private val closeSignal = CompletableDeferred<Unit>()

    @Volatile
    private var clientIdState: String? = null

    /**
     * The server-assigned connection id from the last `connect` frame, or
     * `null` before the socket has connected.
     */
    val clientId: String? get() = clientIdState

    /**
     * Test-only suspension point, invoked (with no lock held) in
     * [subscribe]/[subscribeTopic] immediately before the locked section
     * that registers the pending ack-[CompletableDeferred]. `null` (the
     * default) is a no-op. Lets a test force a deterministic interleaving
     * with a concurrent [close] -- the TOCTOU regression this guards
     * against: a `subscribe` parked here while `close()` runs to completion
     * must observe the closed flag inside that same lock rather than
     * registering a deferred nothing will ever settle.
     */
    internal var testHookBeforePendingRegistration: (suspend () -> Unit)? = null

    /**
     * Test-only suspension point, invoked in [connectOnce] immediately
     * after a successful [attemptConnect], before the locked
     * closed-check-and-commit section. `null` (the default) is a no-op.
     * Lets a test force a deterministic interleaving with a concurrent
     * [close] -- the TOCTOU regression this guards against: a connect
     * resolving here while `close()` runs to completion must have its
     * connection torn down rather than silently adopted after the scope it
     * would run on has already been cancelled.
     */
    internal var testHookAfterConnect: (suspend () -> Unit)? = null

    /**
     * Test-only suspension point, invoked in [connectOnce] immediately after
     * the closed-check-and-commit section succeeds (connection adopted,
     * `opened`/`activeConnection` committed), before [onOpen]/
     * [resubscribeAll] ever runs. `null` (the default) is a no-op. Lets a
     * test force a deterministic interleaving with a concurrent `subscribe`
     * that was deferring in [ensureConnected] (because it observed
     * `connecting` or `activeConnection` before this commit) and, once it
     * observes the just-committed `opened`/`activeConnection`, sends its own
     * subscribe frame BEFORE [resubscribeAll] gets a chance to run --
     * regression-tested by `RealtimeServiceResubscribeStompTest`, where
     * [resubscribeAll]'s reset used to be a separate, later locked step and
     * could stomp that already-sent frame's `inflight` mark and resend a
     * duplicate.
     */
    internal var testHookAfterCommit: (suspend () -> Unit)? = null

    /**
     * Test-only suspension point, invoked in [onAuthStoreChange]'s launched
     * coroutine, before the `opened`/`closedByUser` check, with the frame's
     * token. `null` (the default) is a no-op. Lets a test force a
     * deterministic reordering of two racing re-auth sends -- parking the
     * older (lower-sequence) one here while a newer one runs to completion
     * -- to verify [sendAuthFrame]'s sequence-based staleness check actually
     * drops the stale frame rather than letting it land on the wire after
     * the newer one.
     */
    internal var testHookBeforeAuthSend: (suspend (String) -> Unit)? = null

    /**
     * Test-only completion signal, invoked in [onAuthStoreChange]'s launched
     * coroutine right after its (possibly skipped) [sendAuthFrame] call
     * returns, with the frame's token. `null` (the default) is a no-op. Lets
     * a test observe that a fire-and-forget re-auth send actually finished
     * rather than hanging -- the regression this guards against is the
     * orphan-ack gap in [sendAuthFrame]: a send that loses the ordering race
     * used to unconditionally create a fresh ack before checking staleness,
     * so a call that turned out stale AND had nothing live to join could
     * await a deferred nothing would ever complete.
     */
    internal var testHookAfterAuthSend: (suspend (String) -> Unit)? = null

    // ---- public API ---------------------------------------------------------

    suspend fun subscribe(
        topic: String,
        filter: String? = null,
        callback: suspend (RealtimeEvent) -> Unit,
    ): suspend () -> Unit {
        raiseIfClosed()
        val key = subKey(topic, filter)
        val sub =
            mutex.withLock {
                raiseIfClosed()
                subscriptions
                    .getOrPut(key) { Subscription(topic, SubKind.RECORDS, filter) }
                    .also { it.callbacks.add(callback) }
            }
        val unsubscribeFn: suspend () -> Unit = { unsubscribe(topic, callback, filter = filter) }

        ensureConnected()
        raiseIfClosed()

        testHookBeforePendingRegistration?.invoke()

        val deferred =
            mutex.withLock {
                raiseIfClosed()
                if (sub.acked) null else CompletableDeferred<Unit>().also { sub.pending.add(it) }
            } ?: return unsubscribeFn

        sendSubscribeIfNeeded(sub)
        // Races the pending ack against `closeSignal` (completed
        // unconditionally by BOTH `close()` and `shutdown()`, before either
        // does any other teardown work) rather than a bare `deferred.await()`:
        // `shutdown()`'s own pending-ack failure is only a best-effort
        // `tryLock` (see its doc), so this is the actual liveness guarantee
        // that a caller parked here never hangs past the service closing --
        // see `RealtimeServiceShutdownAckHangTest`.
        select<Unit> {
            deferred.onAwait {}
            closeSignal.onAwait { throw ZigbaseException(status = 0, message = CLOSED_MESSAGE, url = "") }
        }
        return unsubscribeFn
    }

    /**
     * Subscribes to a custom (non-collection) topic: `signal`/`message`
     * frames are delivered as [TopicMessage]s. Same ack/dedup machinery as
     * [subscribe].
     */
    suspend fun subscribeTopic(
        topic: String,
        callback: suspend (TopicMessage) -> Unit,
    ): suspend () -> Unit {
        raiseIfClosed()
        val key = topicKey(topic)
        val sub =
            mutex.withLock {
                raiseIfClosed()
                subscriptions
                    .getOrPut(key) { Subscription(topic, SubKind.TOPIC) }
                    .also { it.topicCallbacks.add(callback) }
            }
        val unsubscribeFn: suspend () -> Unit = { unsubscribeTopic(topic, callback) }

        ensureConnected()
        raiseIfClosed()

        testHookBeforePendingRegistration?.invoke()

        val deferred =
            mutex.withLock {
                raiseIfClosed()
                if (sub.acked) null else CompletableDeferred<Unit>().also { sub.pending.add(it) }
            } ?: return unsubscribeFn

        sendSubscribeIfNeeded(sub)
        // Races the pending ack against `closeSignal` (completed
        // unconditionally by BOTH `close()` and `shutdown()`, before either
        // does any other teardown work) rather than a bare `deferred.await()`:
        // `shutdown()`'s own pending-ack failure is only a best-effort
        // `tryLock` (see its doc), so this is the actual liveness guarantee
        // that a caller parked here never hangs past the service closing --
        // see `RealtimeServiceShutdownAckHangTest`.
        select<Unit> {
            deferred.onAwait {}
            closeSignal.onAwait { throw ZigbaseException(status = 0, message = CLOSED_MESSAGE, url = "") }
        }
        return unsubscribeFn
    }

    /**
     * A cold [Flow] of [RealtimeEvent]s for [topic], layered over [subscribe]:
     * each collection subscribes FRESH on its first `collect` (this function
     * itself does no I/O -- it only builds the [Flow]), delivers every event
     * dispatched to [topic] while being collected, and unsubscribes when
     * collection ends for ANY reason: normal completion (`take(n)`/`break`),
     * the collecting coroutine being cancelled, or [close] tearing down the
     * whole service.
     *
     * A subscribe rejected by the server (an `error` frame) throws the
     * [ZigbaseException] out of `collect { }` -- matching [subscribe]'s own
     * contract. By contrast, [close] ends the flow CLEANLY (the channel is
     * closed with no cause, so `collect { }` returns normally) rather than
     * throwing: a service-initiated shutdown is not a per-stream failure --
     * see [closeSignal]. Cancelling the collecting coroutine mid-ack (before
     * the initial subscribe's ack has even arrived) is leak-free: cleanup
     * always calls [unsubscribe] directly with the callback this flow
     * registered, regardless of how far [subscribe] got, rather than relying
     * on [subscribe]'s returned unsubscribe closure (which a cancelled/
     * rejected call never returns) -- matching [subscribe]'s own
     * cancellation caveat (a callback registered before the ack is awaited
     * stays registered if the awaiting coroutine is cancelled; this cleanup
     * strips it) -- and idempotent either way.
     *
     * Teardown is fire-and-forget, launched on this service's own [scope]:
     * `awaitClose`'s block runs outside any suspend context, so the (suspend)
     * [unsubscribe] call can't run inline there. It is always safe to run
     * even after [close]: [unsubscribe] is a no-op once the subscription map
     * has already been cleared.
     *
     * Delivery is UNBOUNDED (`buffer(Channel.UNLIMITED)`), matching the
     * accepted-not-an-oversight tradeoff in the Python/TS/Dart ports: a
     * consumer that falls behind the server just grows memory rather than
     * dropping events or applying backpressure to sibling subscribers
     * sharing this service's single receive loop. A [ChannelResult] failure
     * from `trySend` for any reason OTHER than the channel already being
     * closed (teardown in progress -- expected, not an error) is reported via
     * the service's `onError` rather than silently dropped.
     */
    fun stream(
        topic: String,
        filter: String? = null,
    ): Flow<RealtimeEvent> =
        callbackFlow {
            val producer = this
            val callback: suspend (RealtimeEvent) -> Unit = { ev -> reportDroppedSend(producer.trySend(ev)) }
            val closeWatcher =
                launch {
                    closeSignal.await()
                    producer.close()
                }
            try {
                subscribe(topic, filter, callback)
            } catch (e: Throwable) {
                if (e !is CancellationException && closedByUser) {
                    // `close()` raced the still-pending subscribe ack (the
                    // acked window is already clean via `closeSignal`/
                    // `closeWatcher` -- see their docs): this is a
                    // service-initiated shutdown, not a per-stream failure,
                    // so end the flow the same clean way, rather than
                    // propagating `close()`'s synthetic "closed" exception
                    // into the collector. `closeSignal` is already completed
                    // by the time `close()` can have failed this subscribe's
                    // ack, so `closeWatcher` is guaranteed to close the
                    // channel -- just wait for it. No unsubscribe is owed:
                    // `close()` already cleared the subscription map.
                    //
                    // By design, this can't tell a close()-induced failure
                    // apart from a genuine server rejection that happens to
                    // land in this exact instant `closedByUser` flips true --
                    // both throw here, and both take this branch. That's
                    // intentional, not a bug: the service is closing either
                    // way, so surfacing the rejection instead would gain
                    // nothing and risks this path hanging on a connection
                    // that will never reply again.
                    closeWatcher.join()
                    return@callbackFlow
                }
                closeWatcher.cancel()
                scope.launch { runCatching { unsubscribe(topic, callback, filter = filter) } }
                throw e
            }
            awaitClose {
                closeWatcher.cancel()
                scope.launch { runCatching { unsubscribe(topic, callback, filter = filter) } }
            }
        }.buffer(Channel.UNLIMITED)

    /**
     * Same as [stream], but for a custom (non-collection) topic -- layered
     * over [subscribeTopic]/[unsubscribeTopic] the same way [stream] is
     * layered over [subscribe]/[unsubscribe]. See [stream]'s doc for the
     * full rejected/close/cancellation/backpressure contract, which applies
     * identically here.
     */
    fun streamTopic(topic: String): Flow<TopicMessage> =
        callbackFlow {
            val producer = this
            val callback: suspend (TopicMessage) -> Unit = { msg -> reportDroppedSend(producer.trySend(msg)) }
            val closeWatcher =
                launch {
                    closeSignal.await()
                    producer.close()
                }
            try {
                subscribeTopic(topic, callback)
            } catch (e: Throwable) {
                if (e !is CancellationException && closedByUser) {
                    // Same service-close-vs-genuine-rejection distinction as
                    // `stream()`'s catch block above -- see there for the
                    // full rationale, including why a genuine rejection
                    // landing in this exact instant is by-design swallowed
                    // as a clean close rather than surfaced.
                    closeWatcher.join()
                    return@callbackFlow
                }
                closeWatcher.cancel()
                scope.launch { runCatching { unsubscribeTopic(topic, callback) } }
                throw e
            }
            awaitClose {
                closeWatcher.cancel()
                scope.launch { runCatching { unsubscribeTopic(topic, callback) } }
            }
        }.buffer(Channel.UNLIMITED)

    /**
     * Reports a `trySend` failure that isn't the channel already being
     * closed (an expected outcome mid-teardown, not a dropped event) via
     * `onError` -- shared by [stream]/[streamTopic] so neither silently
     * drops an event without saying so.
     */
    private fun <T> reportDroppedSend(result: ChannelResult<T>) {
        if (result.isFailure && !result.isClosed) {
            onError("realtime stream: dropped an event, channel send failed")
        }
    }

    /**
     * Removes a record callback.
     *
     * When [filter] is omitted, [callback] is removed from EVERY variant of
     * [topic] regardless of filter (a filtered subscription's key would
     * never match the unfiltered key, so keying alone would silently leak
     * it). When [filter] is given, only that exact `(topic, filter)`
     * variant is targeted. A single `unsubscribe` frame is sent once
     * [topic] has no live variant (record or topic) left. Idempotent for an
     * unknown topic/callback.
     */
    suspend fun unsubscribe(
        topic: String,
        callback: (suspend (RealtimeEvent) -> Unit)? = null,
        filter: String? = null,
    ) {
        val (shouldSend, conn) =
            mutex.withLock {
                val targets =
                    if (filter != null) {
                        listOfNotNull(subscriptions[subKey(topic, filter)])
                    } else {
                        subscriptions.values.filter { it.kind == SubKind.RECORDS && it.topic == topic }
                    }
                var removed = false
                for (target in targets) {
                    if (callback != null) target.callbacks.remove(callback) else target.callbacks.clear()
                    if (target.callbacks.isEmpty()) {
                        subscriptions.remove(subKey(target.topic, target.filter))
                        removed = true
                    }
                }
                if (removed && opened && !hasTopic(topic)) true to activeConnection else false to null
            }
        if (shouldSend && conn != null) sendUnsubscribeFrame(conn, topic)
    }

    /**
     * Removes a topic callback (all of them when [callback] is omitted);
     * sends one `unsubscribe` frame once the topic has no live variant
     * (record or topic) left. Idempotent for an unknown topic/callback.
     */
    suspend fun unsubscribeTopic(
        topic: String,
        callback: (suspend (TopicMessage) -> Unit)? = null,
    ) {
        val key = topicKey(topic)
        val (shouldSend, conn) =
            mutex.withLock {
                val sub = subscriptions[key]
                if (sub == null) {
                    false to null
                } else {
                    if (callback != null) sub.topicCallbacks.remove(callback) else sub.topicCallbacks.clear()
                    if (sub.topicCallbacks.isEmpty()) {
                        subscriptions.remove(key)
                        if (opened && !hasTopic(topic)) true to activeConnection else false to null
                    } else {
                        false to null
                    }
                }
            }
        if (shouldSend && conn != null) sendUnsubscribeFrame(conn, topic)
    }

    /**
     * Tears down the socket, stops the receive loop, and fails any
     * subscribe still awaiting its ack (with a [ZigbaseException], status
     * `0`) so no caller is left hanging. Idempotent; a subscribe/
     * subscribeTopic call after this always throws immediately rather than
     * hanging.
     */
    suspend fun close() {
        val alreadyClosed =
            mutex.withLock {
                if (closedByUser) {
                    true
                } else {
                    closedByUser = true
                    false
                }
            }
        if (alreadyClosed) return

        // Wakes every live `stream()`/`streamTopic()` watcher so its flow ends
        // with a clean channel close (no cause) rather than hanging or
        // throwing -- see `closeSignal`'s field doc.
        closeSignal.complete(Unit)

        // Unregisters the auth listener BEFORE tearing anything else down,
        // matching the Python port's `close()` ordering -- a `save()`/
        // `clear()` racing this call must never observe a live listener
        // past this point.
        authUnsubscribe()

        val (conn, toFail, authAckToFail) =
            mutex.withLock {
                val pending = subscriptions.values.flatMap { it.pending }
                subscriptions.clear()
                val ack = authAck
                authAck = null
                Triple(activeConnection, pending, ack)
            }

        val exception = ZigbaseException(status = 0, message = CLOSED_MESSAGE, url = "")
        for (deferred in toFail) {
            if (!deferred.isCompleted) deferred.completeExceptionally(exception)
        }
        // Unblocks an inline `ack.await()` still in flight inside the
        // on-open auth send (not scheduled via `scope.launch`, unlike the
        // fire-and-forget re-auth sends off `onAuthStoreChange`) so that
        // caller's `subscribe()` doesn't hang on a connection that will
        // never respond again.
        if (authAckToFail != null && !authAckToFail.isCompleted) {
            authAckToFail.completeExceptionally(exception)
        }

        // Cancels the receive loop (a child of `scope`) and waits for its
        // `finally` (see `receiveLoop`) to finish unwinding before this
        // returns.
        supervisorJob.cancelAndJoin()

        if (conn != null) {
            runCatching { conn.close() }
        }
    }

    /**
     * Non-suspend counterpart to [close], for a caller that cannot suspend --
     * [io.github.valthon.zigbase.ZigbaseClient.close] is `AutoCloseable`
     * (non-suspend) even though this service's own [close] is `suspend`.
     * Idempotently marks the service closed and cancels [scope]/
     * [supervisorJob]: the receive loop (a child of [scope]) is torn down by
     * that cancellation, and its production connection is actually severed
     * one step later, when the caller closes the `HttpClient` backing the
     * default ktor connector (see [io.github.valthon.zigbase.realtime
     * .KtorWebSocketConnector]) -- unlike [close], this never awaits
     * [supervisorJob], so it does not itself call `conn.close()` (a suspend
     * function) and never risks a double-free of the connection.
     *
     * Best-effort: also fails any subscribe/auth ack still pending, exactly
     * like [close], but via [Mutex.tryLock] (non-suspend) rather than
     * [Mutex.withLock] -- on the rare contended case this step is simply
     * skipped. This is a pure optimization (a faster, more specific
     * exception), NOT the liveness guarantee: [subscribe]/[subscribeTopic]
     * race their pending ack against [closeSignal] (completed above,
     * unconditionally, before this best-effort step even runs), so a caller
     * awaiting its ack unblocks the instant the service closes regardless of
     * whether this `tryLock` wins.
     */
    internal fun shutdown() {
        if (!shutdownStarted.compareAndSet(false, true)) return
        closedByUser = true
        closeSignal.complete(Unit)
        authUnsubscribe()

        if (!testHookForceShutdownSkipAckFail && mutex.tryLock()) {
            try {
                val exception = ZigbaseException(status = 0, message = CLOSED_MESSAGE, url = "")
                for (sub in subscriptions.values) {
                    for (deferred in sub.pending) if (!deferred.isCompleted) deferred.completeExceptionally(exception)
                    sub.pending.clear()
                }
                subscriptions.clear()
                authAck?.let { if (!it.isCompleted) it.completeExceptionally(exception) }
                authAck = null
            } finally {
                mutex.unlock()
            }
        }

        supervisorJob.cancel()
    }

    // ---- connection lifecycle ------------------------------------------------

    private fun hasTopic(topic: String): Boolean = subscriptions.values.any { it.topic == topic }

    private fun raiseIfClosed() {
        if (closedByUser) throw ZigbaseException(status = 0, message = CLOSED_MESSAGE, url = "")
    }

    private suspend fun ensureConnected() {
        // Defer to an in-flight connect OR a scheduled reconnect -- during
        // that window a fresh subscribe here must not open a second,
        // competing socket. Check-and-set happens atomically under `mutex`
        // since, unlike Python's single-threaded event loop, a second
        // subscriber can genuinely run this concurrently on another thread.
        val shouldConnect =
            mutex.withLock {
                if (activeConnection != null || connecting || reconnectPending) {
                    false
                } else {
                    connecting = true
                    true
                }
            }
        if (shouldConnect) connectOnce()
    }

    /**
     * Attempts exactly one connect via [attemptConnect], then -- on
     * success -- establishes the connection, starts the receive loop, and
     * resends every subscription still owed a frame.
     *
     * Mirrors the Python port's `_connect_once`'s fire-and-forget contract:
     * a connector failure is never raised to a [subscribe]/[subscribeTopic]
     * caller racing this attempt (see [ensureConnected]) -- it's surfaced
     * via [onError] instead (see [attemptConnect]), so the caller's pending
     * future simply stays pending until a later attempt succeeds and
     * resends its frame.
     */
    private suspend fun connectOnce() {
        // Failure/cancellation: `attemptConnect()` already cleared
        // `connecting` itself (see its doc) -- nothing else to undo here.
        val conn = attemptConnect() ?: return

        // Success hands ownership of `connecting` to THIS function: it stays
        // `true` (never observed all-false alongside a null
        // `activeConnection`) from here until the `finally` below, closing
        // the TOCTOU window a concurrent `ensureConnected()` used to slip
        // through -- see `RealtimeServiceConnectToctouRaceTest`.
        var adopted = false
        // Flips to `true` only once [onOpen] has fully returned -- i.e. the
        // connection is not merely committed but wired up (auth sent+settled,
        // every surviving subscription resubscribed). A cancellation or throw
        // anywhere after the commit but before this point leaves a
        // half-initialized connection: `activeConnection`/`opened` are set,
        // but [resubscribeAll]/auth never finished, so the socket would block
        // every future reconnect ([ensureConnected] sees a non-null
        // `activeConnection`) while delivering nothing -- worst of all when
        // cancelled in the narrow gap AFTER commit but BEFORE the receive loop
        // is even launched, a genuinely dead half-open socket nothing would
        // ever close. The `finally` uses this to transactionally roll the
        // commit back. See `RealtimeServiceConnectCancelledAfterCommitTest`.
        var success = false
        try {
            testHookAfterConnect?.invoke()

            // The closed-check and the connection commit MUST be one atomic
            // section: checking `closedByUser` and storing `activeConnection`
            // as two separate locked steps leaves a window where `close()` can
            // run to completion in between, observing no connection to tear
            // down -- and this connect then adopts `conn` anyway, onto a scope
            // `close()` already cancelled, leaking the socket forever (nothing
            // left will ever call `.close()` on it).
            //
            // The acked/inflight reset for every CURRENT subscription is
            // folded into this SAME locked section (not a separate, later
            // step in `resubscribeAll` -- see that function's doc for the
            // regression this closes): the moment any other coroutine can
            // observe `opened == true` (the gate `sendSubscribeIfNeeded`
            // checks), every subscription's flags must already reflect the
            // new connection generation, or a concurrent `subscribe()` that
            // was deferring in `ensureConnected` on the OLD `connecting`/
            // `activeConnection` state could send its own frame in the gap,
            // only for `resubscribeAll`'s reset to stomp that fresh
            // `inflight` mark and resend a duplicate.
            val abandoned =
                mutex.withLock {
                    if (closedByUser) {
                        true
                    } else {
                        activeConnection = conn
                        opened = true
                        reconnectAttempts = 0
                        adopted = true
                        for (sub in subscriptions.values) {
                            sub.acked = false
                            sub.inflight = false
                        }
                        false
                    }
                }
            if (abandoned) {
                // close() ran while the connect was in flight (or in this
                // exact window): the `finally` below closes `conn` since
                // `adopted` stays `false` -- this service never put it in
                // `activeConnection`, so nothing else will ever close it.
                return
            }

            testHookAfterCommit?.invoke()

            val job = scope.launch { receiveLoop(conn) }
            mutex.withLock { receiveJob = job }

            onOpen()
            success = true
        } finally {
            withContext(NonCancellable) {
                mutex.withLock {
                    connecting = false
                    // Transactional rollback of a commit that never finished
                    // wiring up (see `success`'s doc): undo the
                    // `activeConnection`/`opened` publish so a later
                    // `subscribe()` opens a fresh socket rather than adopting
                    // this dead half-open one. Guarded by `activeConnection
                    // === conn` so it can only ever null OUT this connect's own
                    // connection, never a newer one -- though none can exist
                    // yet, since `connecting` stays `true` until this very
                    // section. `connecting = false` and the null-out happen in
                    // ONE locked section, so no concurrent `ensureConnected`
                    // ever sees an intermediate state. Serialized with
                    // `close()`'s own `activeConnection` read/clear by this
                    // same `mutex`.
                    if (!success && adopted && activeConnection === conn) {
                        activeConnection = null
                        opened = false
                        // Roll back the receive-loop handle too, so an
                        // unsuccessful connect leaves no dangling `receiveJob`
                        // beside a null `activeConnection`: receiveLoop's own
                        // finally will NOT clear it (it gates on
                        // `activeConnection === conn`, already false after the
                        // null-out just above). The launched loop still
                        // terminates on its own once `conn.close()` (below) ends
                        // `conn.incoming`; this only keeps the tracked handle
                        // consistent with the rolled-back connection state.
                        receiveJob = null
                    }
                }
                // Close the socket on ANY unsuccessful exit -- not just the
                // never-adopted case. A commit that failed to finish wiring up
                // (rolled back just above) owns closing its own connection too:
                // otherwise an adopted-but-unwired socket leaks (nothing else
                // holds a reference to `.close()` it). Idempotent + `runCatching`,
                // so a double close racing `close()`'s own teardown is harmless.
                //
                // MUST run INSIDE `withContext(NonCancellable)` (but outside the
                // `mutex.withLock`, to avoid holding the lock across I/O):
                // `conn.close()` is a suspend fn, and this finally's whole reason
                // to exist is the cancellation path. Left outside NonCancellable,
                // `close()` would throw `CancellationException` at its first
                // suspension point in the already-cancelled coroutine and
                // `runCatching` would swallow it -- so the socket would never
                // actually close, leaking exactly the connection we are here to
                // reclaim.
                if (!success) runCatching { conn.close() }
            }
        }
    }

    /**
     * Runs once per fresh open: a present [authStore] token is sent and
     * awaited BEFORE resubscribing, so the server has applied the identity
     * before evaluating subscription rules; an anonymous open skips
     * straight to resubscribing -- an empty/absent token here means there
     * is nothing to de-auth yet (no connection has ever been authenticated),
     * unlike a logout that arrives WHILE already connected (see
     * [onAuthStoreChange]), which must still send `auth("")` to tell the
     * server to drop an identity it already applied. An auth failure never
     * blocks this -- [sendAuthFrame] swallows it into [onError] and returns
     * normally either way.
     */
    private suspend fun onOpen() {
        val token = authStore.token
        if (!token.isNullOrEmpty()) {
            sendAuthFrame(token, authSeqCounter.incrementAndGet())
        }
        resubscribeAll()
    }

    /**
     * Runs the connector, returning the new connection or `null` on
     * failure (after reporting via [onError] and calling
     * [scheduleReconnect]).
     *
     * [connecting] is cleared here ONLY on the failure/cancellation path --
     * on [CancellationException] (the original fix for the regression where
     * a cancelled connect attempt left [connecting] stuck `true` forever,
     * wedging every later subscribe) and on a connector exception (where
     * [scheduleReconnect] has, by this point, already set
     * [reconnectPending] if eligible -- so clearing [connecting] leaves no
     * all-false window). On SUCCESS, ownership of [connecting] passes to
     * [connectOnce], which does not clear it until the connection is
     * committed (or definitively abandoned) -- clearing it here too, right
     * after this returns, is the pre-existing TOCTOU this file's header and
     * `RealtimeServiceConnectToctouRaceTest` describe: a concurrent
     * `ensureConnected()` could observe `connecting == false &&
     * activeConnection == null` in the gap and open a second, competing
     * socket. Either way this returns, the clear (when it happens) runs
     * wrapped in `withContext(NonCancellable)` since a `finally` running
     * during cancellation would otherwise have its own suspending calls
     * rejected immediately.
     */
    private suspend fun attemptConnect(): RealtimeConnection? {
        val url = realtimeUrl(baseUrl)
        var conn: RealtimeConnection? = null
        try {
            conn =
                try {
                    connector(url)
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    onError(e.message ?: e.toString())
                    scheduleReconnect()
                    null
                }
            return conn
        } finally {
            if (conn == null) {
                withContext(NonCancellable) {
                    mutex.withLock { connecting = false }
                }
            }
        }
    }

    /**
     * Resends every surviving subscription's frame on a fresh open --
     * including a RECONNECT, not just the very first connect.
     *
     * The `acked`/`inflight` reset every subscription needs BEFORE any frame
     * goes out (without it, a subscription acked against the OLD, now-dead
     * connection would still read `acked == true` here, and
     * [sendSubscribeIfNeeded] would silently skip resending it forever -- the
     * caller would still believe it's live on a connection that no longer
     * exists) happens in [connectOnce]'s own commit section, NOT here: a
     * separate, later reset step here used to leave a window between the
     * commit (after which `opened`/`activeConnection` are visible, so
     * `sendSubscribeIfNeeded`'s `!opened` gate no longer blocks anyone) and
     * this function actually running, in which a concurrent `subscribe()`
     * already deferring in `ensureConnected()` could send its own frame --
     * only for this function's reset to stomp that fresh `inflight` mark and
     * resend a duplicate (see `RealtimeServiceResubscribeStompTest`). This
     * merely reads the current subscriptions and lets
     * [sendSubscribeIfNeeded]'s own atomic check-and-mark decide, per
     * subscription, whether a frame is still owed.
     */
    private suspend fun resubscribeAll() {
        val subs = mutex.withLock { subscriptions.values.toList() }
        for (sub in subs) {
            sendSubscribeIfNeeded(sub)
        }
    }

    /**
     * Schedules the next reconnect attempt with bounded exponential backoff
     * (see [reconnect]), called from [receiveLoop]'s `finally` (an
     * unexpected drop) and [attemptConnect]'s connector-failure branch (a
     * connect that never even opened).
     *
     * The eligibility check-and-set is ONE atomic section under [mutex] --
     * a no-op when a reconnect is already pending (both call sites can want
     * one), the service has been closed, or there are no live subscriptions
     * left to resurrect the socket for (an idle connection that every caller
     * has already unsubscribed from must not be reopened, matching the
     * TS/Dart/Python ports) -- so concurrent callers from either site (or a
     * racing [subscribe]/[unsubscribe]) can never spawn two competing
     * reconnect [Job]s.
     */
    private suspend fun scheduleReconnect() {
        val shouldSchedule =
            mutex.withLock {
                if (reconnectPending || closedByUser || subscriptions.isEmpty()) {
                    false
                } else {
                    reconnectPending = true
                    true
                }
            }
        if (shouldSchedule) {
            scope.launch { reconnect() }
        }
    }

    /**
     * Runs one backoff-then-connect cycle: sleeps `min(10_000, 250 shl
     * attempts.coerceAtMost(20))` ms via [delayFn] (attempts incremented
     * per call, reset to `0` on the next successful open -- see
     * [connectOnce]), then runs [connectOnce] again (auth-first, then
     * [resubscribeAll] with its acked/inflight reset -- unacked pending
     * subscribes' original deferreds settle on the fresh acks the
     * reconnected socket eventually delivers).
     *
     * [reconnectPending] is cleared, and [connecting] is set, in ONE locked
     * step in the `finally` below -- NOT two separate steps -- so no other
     * task can ever observe a window where NEITHER flag guards
     * [ensureConnected]. Python's single-threaded event loop gets this for
     * free (`_connect_once`'s very first, non-suspending statement sets
     * `_connecting = True` immediately after `_reconnect` clears
     * `_reconnect_pending`, with no other task able to run in between); a
     * real concurrent [subscribe] on `Dispatchers.Default` could otherwise
     * slip through that gap and open a second, competing socket. [connecting]
     * is reset back to `false` by [attemptConnect]'s own `finally` once the
     * actual connect attempt (inside [connectOnce], called below) completes
     * -- or, if [closedByUser] became `true` while this was sleeping and
     * [connectOnce] is never called at all, reset right here instead so it
     * never wedges `true` forever.
     *
     * The `finally` always clears [reconnectPending] -- even when [delayFn]
     * itself throws (reported via [onError], the backoff simply treated as
     * elapsed rather than retried) -- so a misbehaving injected delay can
     * never wedge every future reconnect attempt; and even when this whole
     * function is cancelled outright (`close()`'s scope cancellation during
     * the backoff sleep), via `withContext(NonCancellable)`, matching every
     * other cleanup-under-cancellation `finally` in this file.
     */
    private suspend fun reconnect() {
        val delayMs =
            mutex.withLock {
                val shift = reconnectAttempts.coerceAtMost(RECONNECT_MAX_SHIFT)
                val computed = (RECONNECT_MIN_DELAY_MS shl shift).coerceAtMost(RECONNECT_MAX_DELAY_MS)
                reconnectAttempts += 1
                computed
            }
        var delayElapsed = false
        try {
            try {
                delayFn(delayMs)
                delayElapsed = true
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A misbehaving injected delay is treated as elapsed (reported
                // via onError, the backoff simply counted as done) rather than
                // wedging every future reconnect attempt.
                onError(e.message ?: e.toString())
                delayElapsed = true
            }
        } finally {
            withContext(NonCancellable) {
                mutex.withLock {
                    reconnectPending = false
                    // Only hand `connecting` on to the [connectOnce] call below
                    // when the backoff actually elapsed. If this coroutine was
                    // cancelled DURING `delayFn` (close() cancelling the scope
                    // mid-backoff -- the common cancellation point), the
                    // CancellationException propagates past the `if (closedByUser)`
                    // block below, so `connectOnce` never runs; leaving
                    // `connecting = true` here would then wedge it `true` forever.
                    connecting = delayElapsed
                }
            }
        }
        if (closedByUser) {
            // Wrapped in `NonCancellable`, matching every other
            // cleanup-under-cancellation `finally` in this file: a
            // cancellation landing exactly here (between the `closedByUser`
            // read and the `connecting = false` write) must not leave
            // `connecting` stuck `true` -- inert post-close in practice
            // (`raiseIfClosed` already gates every reader), but this closes
            // the cancellation window rather than leaving it open by
            // omission.
            withContext(NonCancellable) { mutex.withLock { connecting = false } }
            return
        }
        connectOnce()
    }

    /**
     * `authStore`'s change listener, registered at construction.
     *
     * `save()`/`clear()` call listeners synchronously and from arbitrary
     * code -- possibly not a coroutine at all -- so this stays a plain,
     * non-suspending function and hands off to [scope], which this service
     * owns for its whole lifetime (unlike the Python port, which must
     * lazily capture the running loop on first connect). [record] is
     * unused: only the token drives re-auth. The event's [token] is used
     * VERBATIM (never re-read from `authStore.token`), since by the time
     * this runs a rapid second `save()`/`clear()` may already have moved
     * the store past the value this particular event announced.
     *
     * The sequence number is captured HERE, synchronously, on the calling
     * thread -- `AuthStore` calls its listeners in `save()`/`clear()` call
     * order, so this is the one place with a true ordering signal. It is
     * threaded through to [sendAuthFrame], which uses it to discard a
     * stale send raced by a newer one; see [authSeqCounter]'s field doc for
     * why this exists at all (there is no such race in the Python/TS/Dart
     * ports, which run single-threaded).
     *
     * The eligibility check (connected, not user-closed) happens INSIDE
     * the launched coroutine, under [mutex] -- not before [scope.launch] --
     * so a `close()` landing between this call firing and that coroutine
     * actually running is never missed: either the scope is already
     * cancelled by then (the launch itself never runs its body), or the
     * locked check observes the just-set closed flag and skips the send.
     */
    private fun onAuthStoreChange(
        token: String?,
        record: JsonObject?,
    ) {
        val seq = authSeqCounter.incrementAndGet()
        scope.launch {
            testHookBeforeAuthSend?.invoke(token ?: "")
            val shouldSend = mutex.withLock { opened && !closedByUser }
            if (shouldSend) sendAuthFrame(token ?: "", seq)
            testHookAfterAuthSend?.invoke(token ?: "")
        }
    }

    /**
     * Sends an `auth` frame and awaits its reply.
     *
     * The ack deferred is REUSED across back-to-back sends (rapid token
     * churn before any reply arrives): every waiter shares one deferred and
     * settles together on the FIRST reply -- including a call whose OWN
     * frame gets dropped as stale below, since some other, newer call now
     * owns settling that shared ack and this caller must still wait for it
     * (a caller shortcutting past that wait just because its particular
     * send lost the ordering race would wrongly un-gate [onOpen]'s
     * resubscribe before the identity that actually reached the server has
     * been confirmed).
     *
     * [seq] gates the actual on-wire write against [authSendMutex]/
     * [latestAuthSendSeq] (see that field's doc for the race this exists to
     * close): a send whose [seq] is older than the newest one already
     * accepted is silently discarded -- never written to the wire -- since
     * an even newer auth intent has already superseded it.
     *
     * Orphan-ack fix (T4 review carry-forward from T3): the ack is now
     * created/reused ONLY inside the winning (non-stale) branch, atomically
     * with the [latestAuthSendSeq] bump and the wire write, all under
     * [authSendMutex] -- never eagerly in a separate step before the
     * staleness check, as the pre-fix version did. That eager creation was
     * the bug: a call that turned out stale, arriving after the winning
     * send's reply had ALREADY settled and detached [authAck] back to
     * `null`, would install a brand-new [authAck] nobody would ever
     * complete (nothing sent for it, and the one reply that mattered had
     * already come and gone) -- then hang forever awaiting its own orphan.
     * `authSendMutex` fully serializes every call (regardless of [seq]) in
     * lock-acquisition order, so by the time ANY call evaluates its own
     * staleness, every earlier winner's ack has already been created (or
     * already settled+detached) -- there is no window left in which a
     * losing call could observe a not-yet-created ack that will still
     * arrive later. So: if this call is stale AND [authAck] is `null`, the
     * newest send's reply has unambiguously already settled -- return
     * WITHOUT awaiting anything, rather than creating (and hanging on) a
     * fresh orphan.
     *
     * Never throws (other than [CancellationException]) -- a failure,
     * whether the send itself or a rejected `status`, is reported via
     * [onError] only, so it can never block [onOpen]'s resubscribe gate or
     * leave a fire-and-forget re-auth coroutine (from [onAuthStoreChange])
     * with an unhandled exception.
     */
    private suspend fun sendAuthFrame(
        token: String,
        seq: Long,
    ) {
        val conn = mutex.withLock { activeConnection } ?: return

        val outcome: AuthSendOutcome =
            authSendMutex.withLock {
                if (seq < latestAuthSendSeq) {
                    AuthSendOutcome.Stale
                } else {
                    latestAuthSendSeq = seq
                    val ack = mutex.withLock { authAck ?: CompletableDeferred<Unit>().also { authAck = it } }
                    try {
                        conn.send(encodeAuth(token))
                        AuthSendOutcome.Sent(ack)
                    } catch (e: CancellationException) {
                        throw e
                    } catch (e: Exception) {
                        AuthSendOutcome.SendFailed(e.message ?: e.toString())
                    }
                }
            }

        when (outcome) {
            is AuthSendOutcome.Sent -> {
                awaitAuthAck(outcome.ack)
            }

            is AuthSendOutcome.SendFailed -> {
                // No reply will ever arrive for a frame that never went out
                // -- fail the (possibly shared/reused) ack so nothing
                // strands, then report; nothing left to await.
                onError(outcome.message)
                failAuthAck(outcome.message)
            }

            AuthSendOutcome.Stale -> {
                // Some other, newer send now owns settling the shared ack --
                // join it, UNLESS nothing is live to join (see this method's
                // doc for why that means the newest reply already settled).
                val ack = mutex.withLock { authAck } ?: return
                awaitAuthAck(ack)
            }
        }
    }

    private suspend fun awaitAuthAck(ack: CompletableDeferred<Unit>) {
        try {
            ack.await()
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            onError(e.message ?: e.toString())
        }
    }

    /**
     * Settles the live `auth` reply deferred from a server `auth` frame's
     * `status`.
     *
     * Detaches (`authAck = null`) BEFORE settling so a superseded frame's
     * later reply (the deferred is reused across back-to-back sends, see
     * [sendAuthFrame]) finds [authAck] already `null` and is a no-op rather
     * than double-settling a deferred a fresh send has since replaced.
     */
    private suspend fun onAuthFrame(status: String?) {
        val ack =
            mutex.withLock {
                val current = authAck
                authAck = null
                current
            } ?: return
        if (ack.isCompleted) return
        if (status == "ok") {
            ack.complete(Unit)
        } else {
            ack.completeExceptionally(ZigbaseException(status = 0, message = "auth failed", url = ""))
        }
    }

    /**
     * Detaches and fails a live auth-ack deferred with [message].
     *
     * Shared by [close] and [failAuthGate]: both are places where the
     * connection is going away and no `auth` reply will ever arrive, so
     * whoever is awaiting the (possibly shared/reused) ack inside
     * [sendAuthFrame] must be unblocked rather than left hanging. A no-op
     * when there's nothing pending.
     */
    private suspend fun failAuthAck(message: String) {
        val ack =
            mutex.withLock {
                val current = authAck
                authAck = null
                current
            }
        if (ack != null && !ack.isCompleted) {
            ack.completeExceptionally(ZigbaseException(status = 0, message = message, url = ""))
        }
    }

    /**
     * Called from [receiveLoop]'s `finally` on every connection loss --
     * mirroring the Python port's `_fail_auth_ack` call there. An
     * unexpected drop can land while [onOpen] is still awaiting the auth
     * ack (a genuine suspension point, unlike the largely synchronous
     * resubscribe sends): without this, nothing but a user [close] would
     * ever settle that ack, and [onOpen] -- and the [subscribe] call that
     * triggered it -- would hang forever. [sendAuthFrame] routes this
     * through [onError] and returns normally either way, so [onOpen] still
     * reaches [resubscribeAll].
     */
    private suspend fun failAuthGate() {
        failAuthAck("realtime connection lost")
    }

    /**
     * Sends [sub]'s subscribe frame if it's eligible: connected, not
     * already on the wire, and not already acked. The eligibility check and
     * the `inflight` mark happen in one locked section so two concurrent
     * callers for the same [Subscription] can never both decide to send --
     * only one send is ever in flight per subscription at a time.
     */
    private suspend fun sendSubscribeIfNeeded(sub: Subscription) {
        val conn =
            mutex.withLock {
                if (!opened || sub.inflight || sub.acked) return@withLock null
                val current = activeConnection ?: return@withLock null
                sub.inflight = true
                current
            } ?: return
        try {
            conn.send(encodeSubscribe(sub.topic, sub.filter))
        } catch (e: CancellationException) {
            // The sending coroutine was cancelled mid-send (e.g. a caller
            // cancelled its own `subscribe()` while parked here). The frame
            // may not have gone out, so undo the inflight mark BEFORE
            // rethrowing -- same rationale as the `Exception` branch below --
            // or `inflight` stays stuck `true` forever on this subscription
            // and a later subscribe to the same topic/filter (which shares
            // this `Subscription`) hits `sendSubscribeIfNeeded`'s `inflight`
            // gate, never sends its own frame, and hangs (bounded only by
            // `close()`). The reset MUST run under `NonCancellable`: a bare
            // `mutex.withLock` (a suspend call) inside an already-cancelled
            // coroutine would itself throw `CancellationException` before the
            // reset ran. `sub.pending`'s futures are left untouched, exactly
            // as in the `Exception` branch.
            withContext(NonCancellable) { mutex.withLock { sub.inflight = false } }
            throw e
        } catch (e: Exception) {
            // The frame never went out -- undo the inflight mark so the
            // next open (this connection's own resubscribe, or a later
            // reconnect) re-sends it instead of treating it as already on
            // the wire. `sub.pending`'s futures are left untouched: they
            // stay pending until a fresh ack eventually arrives.
            mutex.withLock { sub.inflight = false }
            onError(e.message ?: e.toString())
        }
    }

    private suspend fun sendUnsubscribeFrame(
        conn: RealtimeConnection,
        topic: String,
    ) {
        try {
            conn.send(encodeUnsubscribe(topic))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            onError(e.message ?: e.toString())
        }
    }

    // ---- receive loop / dispatch ----------------------------------------------

    private suspend fun receiveLoop(conn: RealtimeConnection) {
        try {
            for (raw in conn.incoming) {
                val frame = decodeFrame(raw) ?: continue
                dispatch(frame)
            }
        } finally {
            // Wrapped in `NonCancellable`: this runs as part of unwinding a
            // cancelled job (e.g. `close()`'s `supervisorJob.cancelAndJoin()`),
            // where an unprotected suspending call would be rejected
            // immediately instead of actually running.
            withContext(NonCancellable) {
                mutex.withLock {
                    if (activeConnection === conn) {
                        opened = false
                        activeConnection = null
                        receiveJob = null
                    }
                }
                failAuthGate()
                if (!closedByUser) scheduleReconnect()
            }
        }
    }

    private suspend fun dispatch(frame: JsonObject) {
        when (stringField(frame, "type")) {
            "connect" -> clientIdState = stringField(frame, "clientId")

            "auth" -> onAuthFrame(stringField(frame, "status"))

            "ack" -> stringField(frame, "topic")?.let { onAck(it) }

            "event" -> onEvent(frame)

            "signal", "message" -> onTopicFrame(frame)

            "error" -> onErrorFrame(stringField(frame, "message") ?: "realtime error")

            // any other/missing type -> unknown, dropped silently
            else -> Unit
        }
    }

    private suspend fun onAck(topic: String) {
        // Ack frames carry only a topic string, so this settles EVERY
        // subscription sharing that topic -- record and topic subs alike,
        // and every filter variant of a record sub.
        val toComplete =
            mutex.withLock {
                val settled = mutableListOf<CompletableDeferred<Unit>>()
                for (sub in subscriptions.values) {
                    if (sub.topic != topic) continue
                    sub.acked = true
                    sub.inflight = false
                    settled += sub.pending
                    sub.pending.clear()
                }
                settled
            }
        for (deferred in toComplete) if (!deferred.isCompleted) deferred.complete(Unit)
    }

    private suspend fun onEvent(frame: JsonObject) {
        val topic = stringField(frame, "topic") ?: return
        val record = frame["record"] as? JsonObject ?: JsonObject(emptyMap())
        val action = stringField(frame, "action") ?: ""
        val event = RealtimeEvent(topic, action, ZbRecord(record))
        val callbacks =
            mutex.withLock {
                subscriptions.values
                    .filter { it.kind == SubKind.RECORDS && it.topic == topic }
                    .flatMap { it.callbacks.toList() }
            }
        for (cb in callbacks) {
            try {
                cb(event)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A raising callback must not kill the loop.
                onError(e.message ?: e.toString())
            }
        }
    }

    private suspend fun onTopicFrame(frame: JsonObject) {
        val topic = stringField(frame, "topic") ?: return // malformed (missing topic) -> dropped
        val kind = stringField(frame, "type") ?: ""
        val data = if (kind == "message") frame["data"] else null
        val message = TopicMessage(topic, kind, data)
        val callbacks =
            mutex.withLock {
                subscriptions.values
                    .filter { it.kind == SubKind.TOPIC && it.topic == topic }
                    .flatMap { it.topicCallbacks.toList() }
            }
        for (cb in callbacks) {
            try {
                cb(message)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A raising callback must not kill the loop.
                onError(e.message ?: e.toString())
            }
        }
    }

    private suspend fun onErrorFrame(message: String) {
        // The server's error frame carries NO topic, so this rejects EVERY
        // unacked pending subscribe (a pre-existing wire-protocol
        // limitation inherited from the TS/Dart/Python SDKs). Each
        // rejected subscription never acked, so no unsubscribe frame is
        // owed; it's dropped from the map entirely so a later reconnect
        // won't silently resubscribe a topic the caller was already told
        // had failed -- a later subscribe() re-creates it fresh.
        val toFail =
            mutex.withLock {
                val failed = mutableListOf<CompletableDeferred<Unit>>()
                val iterator = subscriptions.entries.iterator()
                while (iterator.hasNext()) {
                    val sub = iterator.next().value
                    if (sub.acked || sub.pending.isEmpty()) continue
                    iterator.remove()
                    failed += sub.pending
                    sub.pending.clear()
                }
                failed
            }
        val exception = ZigbaseException(status = 0, message = message, url = "")
        for (deferred in toFail) if (!deferred.isCompleted) deferred.completeExceptionally(exception)
        onError(message)
    }
}
