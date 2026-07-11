package io.github.valthon.zigbase.realtime

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.yield
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.util.concurrent.CopyOnWriteArrayList

/*
 * Test doubles for a [RealtimeConnection] connector.
 *
 * Port of `clients/python/tests/support/fake_connector.py`
 * (`FakeConnection`/`FakeConnectorFactory`), adapted to Kotlin coroutine
 * channels: the Python version queues inbound (server->client) frames in an
 * `asyncio.Queue` and ends iteration on a `None` sentinel; here an unbounded
 * [Channel] plays the same role, CLOSED (rather than sentinel-fed) to end
 * `incoming`'s iteration -- matching [RealtimeConnection.incoming]'s
 * documented close-on-death contract.
 */

/**
 * A single fake connection.
 *
 * - Frames the service under test sends via [send] are JSON-decoded into
 *   [sent] (and split into [subscribeFrames]/[unsubscribeFrames]).
 * - The test delivers a server frame with [push].
 * - The test simulates an unexpected transport drop with [serverClose].
 */
internal class FakeConnection : RealtimeConnection {
    // `CopyOnWriteArrayList`, not a plain `mutableListOf`: `send()` can be
    // called from more than one concurrently-running coroutine on real
    // `Dispatchers.Default` threads (e.g. two racing auth sends, or an auth
    // send racing a subscribe send), while a test's polling assertion
    // (`awaitTrue { factory.last.sent... }`) reads this same list from yet
    // another thread -- a plain `ArrayList` throws
    // `ConcurrentModificationException` under that access pattern; a
    // snapshot-iterator collection does not.
    val sent = CopyOnWriteArrayList<JsonObject>()

    /**
     * When set, the NEXT [send] throws this instead of recording the frame,
     * then clears itself back to `null` (one-shot) so a test can fail
     * exactly one send -- e.g. the auth frame -- without derailing every
     * send that follows on the same connection.
     */
    var sendException: Exception? = null

    /**
     * When set, the NEXT [send] parks on this (after signalling
     * [sendEntered]) before recording the frame, letting a test observe a
     * send in flight and cancel the sending coroutine while it's parked.
     * One-shot: captured and cleared back to `null` on the first [send] that
     * observes it (so a later send on the same connection is not gated). The
     * gate is never required to complete -- cancelling the parked coroutine
     * frees it (the `await` is cancellable).
     */
    var sendGate: CompletableDeferred<Unit>? = null

    /**
     * Completed by [send] the instant it parks on [sendGate], so a test can
     * deterministically wait for the send to be in flight before cancelling
     * the sending coroutine (rather than racing a wall-clock sleep).
     */
    var sendEntered: CompletableDeferred<Unit>? = null

    /** Incremented on every [close] call, so a test can assert exactly-once transport teardown. */
    var closeCount: Int = 0
        private set

    private val channel = Channel<String>(Channel.UNLIMITED)

    override suspend fun send(text: String) {
        val gate = sendGate
        if (gate != null) {
            sendGate = null
            sendEntered?.complete(Unit)
            gate.await()
        }
        val exception = sendException
        if (exception != null) {
            sendException = null
            throw exception
        }
        sent.add(Json.parseToJsonElement(text) as JsonObject)
    }

    override val incoming: ReceiveChannel<String> get() = channel

    override suspend fun close() {
        // A real (ktor) close() suspends, so model a suspension point here.
        // This makes a close() mistakenly invoked in an already-cancelled
        // coroutine (i.e. outside `withContext(NonCancellable)`) observably
        // throw rather than silently completing -- which is what lets
        // RealtimeServiceConnectCancelledAfterCommitTest actually catch a
        // leaked socket on connectOnce's cancellation path. A synchronous
        // fake close would run to completion even under cancellation and hide
        // the leak.
        yield()
        closeCount += 1
        channel.close()
    }

    /** Delivers a server->client frame. */
    suspend fun push(frame: JsonObject) {
        channel.send(frame.toString())
    }

    /** Simulates an unexpected transport drop (peer closed the socket). */
    fun serverClose() {
        channel.close()
    }

    val subscribeFrames: List<JsonObject> get() = sent.filter { actionOf(it) == "subscribe" }

    val unsubscribeFrames: List<JsonObject> get() = sent.filter { actionOf(it) == "unsubscribe" }

    private fun actionOf(frame: JsonObject): String? = (frame["action"] as? JsonPrimitive)?.takeIf { it.isString }?.content
}

/**
 * A connector (`suspend (String) -> RealtimeConnection`) that records every
 * connection it builds.
 */
internal class FakeConnectorFactory {
    val connections = mutableListOf<FakeConnection>()

    /** Connect attempts that throw before succeeding, for backoff tests. */
    var pendingFailures: Int = 0

    /**
     * When set, [connect] parks on this [CompletableDeferred] before
     * resolving, letting a test interleave work (e.g. `close()`) while the
     * connect is in flight.
     */
    var gate: CompletableDeferred<Unit>? = null

    /**
     * Primes the NEXT connection built with a one-shot
     * [FakeConnection.sendException], for tests that need the very first
     * send on a freshly-opened connection -- e.g. the on-open auth frame --
     * to fail. Consumed (reset to `null`) as soon as it's applied.
     */
    var nextSendException: Exception? = null

    /**
     * Primes the NEXT connection built with a one-shot [FakeConnection
     * .sendGate] (and its paired [FakeConnection.sendEntered] signal), for
     * tests that need the first send on a freshly-opened connection -- e.g.
     * the on-open subscribe frame fired from `resubscribeAll` -- to park
     * mid-flight so the sending coroutine can be cancelled while it's in
     * send. Both are consumed (reset to `null`) as soon as they're applied.
     */
    var nextSendGate: CompletableDeferred<Unit>? = null
    var nextSendEntered: CompletableDeferred<Unit>? = null

    suspend fun connect(url: String): RealtimeConnection {
        gate?.await()
        if (pendingFailures > 0) {
            pendingFailures -= 1
            throw RuntimeException("connect failed")
        }
        val connection = FakeConnection()
        nextSendException?.let {
            connection.sendException = it
            nextSendException = null
        }
        nextSendGate?.let {
            connection.sendGate = it
            connection.sendEntered = nextSendEntered
            nextSendGate = null
            nextSendEntered = null
        }
        connections.add(connection)
        return connection
    }

    val last: FakeConnection
        get() = connections.lastOrNull() ?: error("no FakeConnection constructed yet")
}
