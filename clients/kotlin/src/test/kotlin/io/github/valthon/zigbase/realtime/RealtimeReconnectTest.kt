package io.github.valthon.zigbase.realtime

/*
 * Tests for [RealtimeService]'s reconnect/backoff/error-handling lifecycle
 * (SP2 Task 4) -- port of the reconnect matrix in
 * `clients/python/tests/test_realtime_reconnect.py`, adapted for real
 * multi-threaded concurrency the same way `RealtimeServiceTest.kt`/
 * `RealtimeAuthTest.kt` are: instead of Python's `_pump()`/`_pump_until()`
 * (a handful of `asyncio.sleep(0)` event-loop turns), tests here poll a
 * real, observable condition ([awaitTrue]) since a concurrently-running
 * coroutine may be running on another real thread. The backoff sleep itself
 * is driven by the injectable `delayFn` constructor param (mirroring the
 * `connector` param), swapped per test for a recording/gating fake instead
 * of Python's monkeypatched `_asleep`.
 *
 * Also covers the two carry-forward closures from the T2/T3 reviews:
 * [RealtimeReconnectAckedResetTest] (a subscription acked against the OLD
 * connection must be reset so it's resent on the new one) and
 * [RealtimeReconnectOrphanAckRegressionTest] (a stale re-auth send with
 * nothing live to join must return promptly rather than hanging on a
 * self-created orphan ack).
 */

import io.github.valthon.zigbase.RealtimeEvent
import io.github.valthon.zigbase.auth.MemoryAuthStore
import io.github.valthon.zigbase.errors.ZigbaseException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

private fun authFrame(token: String): JsonObject =
    buildJsonObject {
        put("action", "auth")
        put("token", token)
    }

private fun authReplyFrame(status: String): JsonObject =
    buildJsonObject {
        put("type", "auth")
        put("status", status)
    }

private fun subscribeFrame(
    topic: String,
    filter: String? = null,
): JsonObject =
    buildJsonObject {
        put("action", "subscribe")
        put("topic", topic)
        if (filter != null) put("filter", filter)
    }

private fun unsubscribeFrame(topic: String): JsonObject =
    buildJsonObject {
        put("action", "unsubscribe")
        put("topic", topic)
    }

private fun ackFrame(topic: String): JsonObject =
    buildJsonObject {
        put("type", "ack")
        put("action", "subscribe")
        put("topic", topic)
    }

private fun eventFrame(
    topic: String,
    action: String,
    recordId: String,
): JsonObject =
    buildJsonObject {
        put("type", "event")
        put("topic", topic)
        put("action", action)
        put("record", buildJsonObject { put("id", recordId) })
    }

private fun errorFrame(message: String): JsonObject =
    buildJsonObject {
        put("type", "error")
        put("message", message)
    }

private fun JsonObject.actionField(): String? = (this["action"] as? JsonPrimitive)?.takeIf { it.isString }?.content

/** Polls [predicate] (a real, wall-clock wait) until it's true or [timeoutMs] elapses. */
private suspend fun awaitTrue(
    timeoutMs: Long = 2_000,
    predicate: () -> Boolean,
) {
    withTimeout(timeoutMs) {
        while (!predicate()) {
            delay(1)
        }
    }
}

/**
 * Extracts the [T] failure from a [Result] (e.g. one produced by
 * `async { runCatching { ... } }`), or fails if it succeeded or failed with
 * a different type. See `RealtimeServiceTest.kt`'s copy for the full
 * rationale (an `async` child's exception otherwise tears down the whole
 * test body as soon as it occurs).
 */
private inline fun <reified T : Throwable> Result<*>.exceptionAs(): T {
    val ex = exceptionOrNull() ?: throw AssertionError("Expected ${T::class.simpleName} to be thrown, but nothing was")
    if (ex !is T) throw ex
    return ex
}

/** A no-op, non-suspending default: most tests don't care about backoff timing at all. */
private val instantDelay: suspend (Long) -> Unit = {}

private fun makeService(
    factory: FakeConnectorFactory = FakeConnectorFactory(),
    authStore: MemoryAuthStore = MemoryAuthStore(),
    onError: (String) -> Unit = {},
    delayFn: suspend (Long) -> Unit = instantDelay,
): Pair<RealtimeService, FakeConnectorFactory> =
    RealtimeService("http://api.test", authStore, factory::connect, onError, delayFn) to factory

class RealtimeReconnectUnexpectedCloseTest {
    @Test
    fun `unexpected close reconnects and resends auth then subscribe on the new connection`() =
        runTest {
            withContext(Dispatchers.Default) {
                val delays = mutableListOf<Long>()
                val store = MemoryAuthStore()
                store.save("tok-1", null)
                val (service, factory) = makeService(authStore = store, delayFn = { ms -> delays.add(ms) })

                val events = mutableListOf<RealtimeEvent>()
                val job = async { service.subscribe("posts") { events += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }
                assertEquals(listOf(authFrame("tok-1")), factory.last.sent)
                factory.last.push(authReplyFrame("ok"))
                awaitTrue { factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                val first = factory.last
                first.serverClose()
                awaitTrue { factory.connections.size == 2 }
                assertEquals(listOf(250L), delays)

                val second = factory.last
                assertTrue(second !== first)
                awaitTrue { second.sent.isNotEmpty() }
                assertEquals(listOf(authFrame("tok-1")), second.sent)
                second.push(authReplyFrame("ok"))
                awaitTrue { second.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), second.subscribeFrames)
                second.push(ackFrame("posts"))

                second.push(eventFrame("posts", "create", "p9"))
                awaitTrue { events.size == 1 }
                assertEquals("p9", events[0].record.id)
                service.close()
            }
        }
}

class RealtimeReconnectBackoffTest {
    @Test
    fun `backoff doubles across consecutive connect failures`() =
        runTest {
            withContext(Dispatchers.Default) {
                val delays = mutableListOf<Long>()
                val factory = FakeConnectorFactory()
                factory.pendingFailures = 3
                val (service, _) = makeService(factory, delayFn = { ms -> delays.add(ms) })

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.size == 1 }
                assertEquals(listOf(250L, 500L, 1000L), delays)
                factory.last.push(ackFrame("posts"))
                job.await()
                service.close()
            }
        }

    @Test
    fun `backoff caps at ten seconds`() =
        runTest {
            withContext(Dispatchers.Default) {
                val delays = mutableListOf<Long>()
                val factory = FakeConnectorFactory()
                factory.pendingFailures = 7
                val (service, _) = makeService(factory, delayFn = { ms -> delays.add(ms) })

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.size == 1 }
                assertEquals(listOf(250L, 500L, 1000L, 2000L, 4000L, 8000L, 10000L), delays)
                factory.last.push(ackFrame("posts"))
                job.await()
                service.close()
            }
        }

    @Test
    fun `attempts reset after a successful open`() =
        runTest {
            withContext(Dispatchers.Default) {
                val delays = mutableListOf<Long>()
                val factory = FakeConnectorFactory()
                factory.pendingFailures = 1
                val (service, _) = makeService(factory, delayFn = { ms -> delays.add(ms) })

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.size == 1 }
                assertEquals(listOf(250L), delays)
                factory.last.push(ackFrame("posts"))
                job.await()

                // Drop the now-healthy connection -- if attempts hadn't reset
                // on the earlier successful open, this backoff would continue
                // doubling (500) instead of restarting at the base delay.
                factory.last.serverClose()
                awaitTrue { factory.connections.size == 2 }
                assertEquals(listOf(250L, 250L), delays)
                factory.last.push(ackFrame("posts"))
                service.close()
            }
        }
}

class RealtimeReconnectSubscribeDuringBackoffTest {
    @Test
    fun `subscribe during backoff creates no second connection until backoff elapses`() =
        runTest {
            withContext(Dispatchers.Default) {
                val gate = CompletableDeferred<Unit>()
                val (service, factory) = makeService(delayFn = { gate.await() })

                val job1 = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job1.await()
                assertEquals(1, factory.connections.size)

                factory.last.serverClose()
                delay(20) // reconnect scheduled, now parked on the gated delay
                assertEquals(1, factory.connections.size)

                val job2 = async { service.subscribe("comments") { } }
                delay(20)
                assertEquals(1, factory.connections.size) // still no competing socket

                gate.complete(Unit)
                awaitTrue { factory.connections.size == 2 }
                factory.last.push(ackFrame("posts"))
                factory.last.push(ackFrame("comments"))
                job2.await()
                service.close()
            }
        }
}

class RealtimeReconnectRejectedTopicTest {
    @Test
    fun `a topic rejected by an error frame is not resurrected by reconnect`() =
        runTest {
            withContext(Dispatchers.Default) {
                val errors = mutableListOf<String>()
                val (service, factory) = makeService(onError = { errors += it })

                val goodJob = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                goodJob.await()

                val badJob = async { runCatching { service.subscribe("private") { } } }
                awaitTrue { factory.last.subscribeFrames.size == 2 }
                factory.last.push(errorFrame("not allowed"))
                withTimeout(1_000) { badJob.await() }.exceptionAs<ZigbaseException>()
                assertTrue(errors.contains("not allowed"))

                val first = factory.last
                first.serverClose()
                awaitTrue { factory.connections.size == 2 }
                val second = factory.last
                awaitTrue { second.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), second.subscribeFrames) // NOT "private"
                second.push(ackFrame("posts"))
                service.close()
            }
        }
}

class RealtimeReconnectThrowingDelayTest {
    @Test
    fun `a throwing delayFn reports onError and does not wedge future reconnects`() =
        runTest {
            withContext(Dispatchers.Default) {
                var calls = 0
                val errors = mutableListOf<String>()
                val delayFn: suspend (Long) -> Unit = {
                    calls += 1
                    if (calls == 1) throw RuntimeException("delay broke")
                }
                val (service, factory) = makeService(onError = { errors += it }, delayFn = delayFn)

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                val first = factory.last
                first.serverClose()
                awaitTrue { factory.connections.size == 2 }
                assertTrue(errors.any { "delay broke" in it })

                // Not wedged: a second drop still triggers a reconnect.
                val second = factory.last
                second.push(ackFrame("posts"))
                second.serverClose()
                awaitTrue { factory.connections.size == 3 }
                factory.last.push(ackFrame("posts"))
                service.close()
            }
        }
}

class RealtimeReconnectCloseDuringBackoffTest {
    @Test
    fun `close during backoff cancels the pending reconnect`() =
        runTest {
            withContext(Dispatchers.Default) {
                val gate = CompletableDeferred<Unit>()
                val (service, factory) = makeService(delayFn = { gate.await() })

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                factory.last.serverClose()
                delay(20) // reconnect scheduled, parked on the gate
                assertEquals(1, factory.connections.size)

                withTimeout(1_000) { service.close() }
                gate.complete(Unit) // released even so -- no reconnect must follow
                delay(100)
                assertEquals(1, factory.connections.size)
            }
        }
}

class RealtimeReconnectGatedOnLiveSubscriptionsTest {
    @Test
    fun `drop with no live subscriptions does not reconnect`() =
        runTest {
            withContext(Dispatchers.Default) {
                val delays = mutableListOf<Long>()
                val (service, factory) = makeService(delayFn = { ms -> delays.add(ms) })
                val cb: suspend (RealtimeEvent) -> Unit = { }
                val job = async { service.subscribe("posts", callback = cb) }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                service.unsubscribe("posts", cb)
                assertEquals(listOf(unsubscribeFrame("posts")), factory.last.unsubscribeFrames)

                factory.last.serverClose()
                delay(100)

                assertEquals(1, factory.connections.size) // no reconnect attempted
                assertTrue(delays.isEmpty())
                service.close()
            }
        }

    @Test
    fun `drop with live subscriptions still reconnects`() =
        runTest {
            withContext(Dispatchers.Default) {
                // Existing-behavior guard alongside the gate above: a live
                // subscription must still trigger a reconnect on an
                // unexpected drop.
                val (service, factory) = makeService()
                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                factory.last.serverClose()
                awaitTrue { factory.connections.size == 2 }
                factory.last.push(ackFrame("posts"))
                service.close()
            }
        }

    @Test
    fun `connect failure with no live subscriptions during backoff does not reschedule`() =
        runTest {
            withContext(Dispatchers.Default) {
                // Targets the OTHER schedule site: `attemptConnect`'s
                // connector-failure branch, reached from inside `reconnect`
                // after the backoff delay. Subscriptions drain to zero WHILE
                // that delay is parked, so the connect attempt that follows
                // -- which itself fails -- must not schedule a further retry.
                val gate = CompletableDeferred<Unit>()
                val delayCalls = mutableListOf<Long>()
                val delayFn: suspend (Long) -> Unit = { ms ->
                    delayCalls.add(ms)
                    gate.await()
                }
                val factory = FakeConnectorFactory()
                val (service, _) = makeService(factory, delayFn = delayFn)
                val cb: suspend (RealtimeEvent) -> Unit = { }
                val job = async { service.subscribe("posts", callback = cb) }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                factory.last.serverClose()
                awaitTrue { delayCalls.size == 1 } // reconnect scheduled (subs still live), parked on the gate
                assertEquals(1, factory.connections.size)

                service.unsubscribe("posts", cb) // drains subscriptions to zero mid-backoff
                factory.pendingFailures = 1 // the upcoming connect attempt fails once

                gate.complete(Unit)
                delay(100)

                assertEquals(1, factory.connections.size) // the failed attempt built no connection
                assertEquals(1, delayCalls.size) // no further reconnect was scheduled
                service.close()
            }
        }
}

class RealtimeReconnectDropBeforeAckTest {
    @Test
    fun `an unacked subscribe settles once the reconnect delivers a fresh ack`() =
        runTest {
            withContext(Dispatchers.Default) {
                // Was a permanent hang before Task 4 (documented as a known
                // limitation); reconnect must now resend the never-acked
                // frame and let its original future settle.
                val (service, factory) = makeService()
                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), factory.last.subscribeFrames)

                factory.last.serverClose()
                awaitTrue { factory.connections.size == 2 }

                assertFalse(job.isCompleted)
                val second = factory.last
                awaitTrue { second.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), second.subscribeFrames)
                second.push(ackFrame("posts"))
                withTimeout(1_000) { job.await() }
                service.close()
            }
        }
}

class RealtimeReconnectAckedResetTest {
    @Test
    fun `reconnect resends every previously-acked subscription's frame`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val job1 = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job1.await()

                val job2 = async { service.subscribe("comments") { } }
                awaitTrue { factory.last.subscribeFrames.size == 2 }
                factory.last.push(ackFrame("comments"))
                job2.await()

                factory.last.serverClose()
                awaitTrue { factory.connections.size == 2 }
                val second = factory.last
                awaitTrue { second.subscribeFrames.size == 2 }
                assertEquals(
                    setOf(subscribeFrame("posts"), subscribeFrame("comments")),
                    second.subscribeFrames.toSet(),
                )
                second.push(ackFrame("posts"))
                second.push(ackFrame("comments"))
                service.close()
            }
        }
}

/**
 * Regression for the T4-review carry-forward orphan-ack gate starvation in
 * `sendAuthFrame`: a re-auth send that loses the ordering race used to
 * unconditionally create a fresh ack before checking staleness, so a call
 * that turned out stale -- arriving after the winning send's reply had
 * ALREADY settled and detached the shared ack -- would install a brand-new
 * ack nobody would ever complete, then hang forever awaiting it. Forces the
 * exact interleaving deterministically via the existing
 * `testHookBeforeAuthSend` hook (same mechanism `RealtimeAuthTest.kt`'s
 * `RealtimeAuthSendOrderingTest` uses), plus the new `testHookAfterAuthSend`
 * completion signal to observe that the stale call actually returns rather
 * than hanging.
 */
class RealtimeReconnectOrphanAckRegressionTest {
    @Test
    fun `a stale reauth with no live ack to join returns without hanging`() =
        runTest {
            withContext(Dispatchers.Default) {
                val store = MemoryAuthStore()
                val (service, factory) = makeService(authStore = store)

                // Connect anonymously first so the race below is purely
                // between the two re-auth sends -- not entangled with
                // onOpen's own initial send.
                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), factory.last.sent)
                factory.last.push(ackFrame("posts"))
                job.await()

                val loginEntered = CompletableDeferred<Unit>()
                val releaseLogin = CompletableDeferred<Unit>()
                service.testHookBeforeAuthSend = { token ->
                    if (token == "tok-1") {
                        loginEntered.complete(Unit)
                        releaseLogin.await()
                    }
                }
                val loginFinished = CompletableDeferred<Unit>()
                service.testHookAfterAuthSend = { token ->
                    if (token == "tok-1") loginFinished.complete(Unit)
                }

                store.save("tok-1", null) // login: parks at the hook before sendAuthFrame ever runs
                withTimeout(1_000) { loginEntered.await() }

                store.clear() // logout: not gated -- runs its full round trip first
                awaitTrue { factory.last.sent.any { it == authFrame("") } }
                factory.last.push(authReplyFrame("ok")) // settles + detaches the shared ack
                awaitTrue { factory.last.sent.count { it.actionField() == "auth" } == 1 }

                // Release the parked (now-stale) login send: its OWN
                // `sendAuthFrame` call must find nothing live to join (the
                // logout's ack already settled+detached) and return
                // promptly, WITHOUT hanging on a self-created orphan ack.
                releaseLogin.complete(Unit)
                withTimeout(1_000) { loginFinished.await() }

                // The stale login frame never reached the wire -- the only
                // auth frame ever sent is the logout's.
                val authFrames = factory.last.sent.filter { it.actionField() == "auth" }
                assertEquals(listOf(authFrame("")), authFrames)
                service.close()
            }
        }
}
