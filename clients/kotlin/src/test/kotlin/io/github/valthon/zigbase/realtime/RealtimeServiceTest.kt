package io.github.valthon.zigbase.realtime

/*
 * Tests for [RealtimeService]'s connect/subscribe/ack core -- port of the
 * ack-gating and topic-isolation coverage in
 * `clients/python/tests/test_realtime_subscribe.py`, adapted for real
 * multi-threaded concurrency (`Dispatchers.Default`, see `RealtimeService.kt`'s
 * header) rather than asyncio's single-threaded event loop: instead of
 * Python's `_pump()` helper (a handful of `asyncio.sleep(0)` yields, since
 * everything but the receive loop runs inline inside the triggering
 * `subscribe`/`subscribeTopic` call there), tests here poll a real,
 * observable condition ([awaitTrue]) -- the only reliable way to know a
 * concurrently-running coroutine has reached a given point when it may be
 * running on another real thread. Every test body runs under
 * `withContext(Dispatchers.Default)` so [awaitTrue]'s internal `delay()` is
 * a genuine wall-clock wait rather than `runTest`'s virtual time (which
 * nothing here needs, since this task never calls `delay()` itself).
 *
 * Auth-gated resubscribe (Task 3) and reconnect backoff (Task 4) are covered
 * by `RealtimeAuthTest.kt` and `RealtimeReconnectTest.kt` respectively, not
 * here.
 */

import io.github.valthon.zigbase.RealtimeEvent
import io.github.valthon.zigbase.TopicMessage
import io.github.valthon.zigbase.auth.MemoryAuthStore
import io.github.valthon.zigbase.errors.ZigbaseException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

private fun makeService(
    factory: FakeConnectorFactory = FakeConnectorFactory(),
    onError: (String) -> Unit = {},
): Pair<RealtimeService, FakeConnectorFactory> = RealtimeService("http://api.test", MemoryAuthStore(), factory::connect, onError) to factory

/** Suspend-friendly assertion: runs [block] and returns the thrown [T], or fails if nothing was thrown. */
private suspend inline fun <reified T : Throwable> assertFailsWithSuspend(noinline block: suspend () -> Unit): T {
    try {
        block()
    } catch (e: Throwable) {
        if (e is T) return e
        throw e
    }
    throw AssertionError("Expected ${T::class.simpleName} to be thrown, but nothing was")
}

/**
 * Extracts the [T] failure from a [Result] (e.g. one produced by
 * `async { runCatching { ... } }`), or fails if it succeeded or failed with
 * a different type.
 *
 * `async { service.subscribe(...) }` alone is unsafe whenever the
 * subscribe is expected to eventually fail: an `async` child's exception
 * propagates to cancel its parent scope as soon as it occurs -- not only
 * once something calls `.await()` on it -- which would tear down the whole
 * test body. Wrapping the body in `runCatching` keeps the underlying
 * coroutine itself completing normally (as a successful `Result`), so
 * the failure is only ever observed by explicitly unwrapping it here.
 */
private inline fun <reified T : Throwable> Result<*>.exceptionAs(): T {
    val ex = exceptionOrNull() ?: throw AssertionError("Expected ${T::class.simpleName} to be thrown, but nothing was")
    if (ex !is T) throw ex
    return ex
}

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

private fun connectFrame(clientId: String): JsonObject =
    buildJsonObject {
        put("type", "connect")
        put("clientId", clientId)
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

private fun signalFrame(topic: String): JsonObject =
    buildJsonObject {
        put("type", "signal")
        put("topic", topic)
    }

private fun messageFrame(
    topic: String,
    n: Int,
): JsonObject =
    buildJsonObject {
        put("type", "message")
        put("topic", topic)
        put("data", buildJsonObject { put("n", n) })
    }

private fun errorFrame(message: String): JsonObject =
    buildJsonObject {
        put("type", "error")
        put("message", message)
    }

class RealtimeServiceLazyConnectTest {
    @Test
    fun `connects only on first subscribe`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                assertTrue(factory.connections.isEmpty())

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), factory.last.subscribeFrames)

                factory.last.push(ackFrame("posts"))
                job.await()
                service.close()
            }
        }
}

class RealtimeServiceAckGatingTest {
    @Test
    fun `subscribe does not resolve before ack`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                assertFalse(job.isCompleted)

                factory.last.push(ackFrame("posts"))
                job.await()
                assertTrue(job.isCompleted)
                service.close()
            }
        }
}

class RealtimeServiceConcurrentSubscribeTest {
    @Test
    fun `same topic and filter sends one frame both callbacks fire`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val events1 = mutableListOf<RealtimeEvent>()
                val events2 = mutableListOf<RealtimeEvent>()
                val job1 = async { service.subscribe("posts") { events1 += it } }
                val job2 = async { service.subscribe("posts") { events2 += it } }

                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), factory.last.subscribeFrames)

                factory.last.push(ackFrame("posts"))
                job1.await()
                job2.await()

                factory.last.push(eventFrame("posts", "update", "p1"))
                awaitTrue { events1.size == 1 && events2.size == 1 }
                service.close()
            }
        }
}

class RealtimeServiceFilterVariantsTest {
    @Test
    fun `distinct filters are distinct variants`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val job1 = async { service.subscribe("posts", filter = "status='live'") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                val job2 = async { service.subscribe("posts", filter = "status='draft'") { } }
                awaitTrue { factory.last.subscribeFrames.size == 2 }

                assertEquals(
                    listOf(subscribeFrame("posts", "status='live'"), subscribeFrame("posts", "status='draft'")),
                    factory.last.subscribeFrames,
                )
                // A single ack is keyed by topic only, so it settles both variants --
                // a pre-existing wire limitation inherited from the TS/Dart/Python SDKs.
                factory.last.push(ackFrame("posts"))
                job1.await()
                job2.await()
                service.close()
            }
        }
}

class RealtimeServiceEventDispatchTest {
    @Test
    fun `dispatches only to exact topic`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val posts = mutableListOf<RealtimeEvent>()
                val comments = mutableListOf<RealtimeEvent>()
                val t1 = async { service.subscribe("posts") { posts += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                val t2 = async { service.subscribe("comments") { comments += it } }
                awaitTrue { factory.last.subscribeFrames.size == 2 }

                factory.last.push(ackFrame("posts"))
                factory.last.push(ackFrame("comments"))
                t1.await()
                t2.await()

                factory.last.push(eventFrame("posts", "create", "p1"))
                awaitTrue { posts.size == 1 }
                assertEquals("posts", posts[0].topic)
                assertEquals("create", posts[0].action)
                assertEquals("p1", posts[0].record.id)
                assertTrue(comments.isEmpty())
                service.close()
            }
        }

    @Test
    fun `delete event carries id-only record`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val got = mutableListOf<RealtimeEvent>()
                val job = async { service.subscribe("posts") { got += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                factory.last.push(eventFrame("posts", "delete", "p9"))
                awaitTrue { got.size == 1 }
                assertEquals("delete", got[0].action)
                assertEquals("p9", got[0].record.id)
                service.close()
            }
        }
}

class RealtimeServiceUnsubscribeTest {
    @Test
    fun `one variant removed keeps the other no frame sent`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val a = mutableListOf<RealtimeEvent>()
                val b = mutableListOf<RealtimeEvent>()
                val cbA: suspend (RealtimeEvent) -> Unit = { a += it }
                val cbB: suspend (RealtimeEvent) -> Unit = { b += it }
                val jobA = async { service.subscribe("posts", callback = cbA) }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                jobA.await()

                service.subscribe("posts", callback = cbB) // already acked -> resolves immediately

                service.unsubscribe("posts", cbA)
                assertTrue(factory.last.unsubscribeFrames.isEmpty())

                factory.last.push(eventFrame("posts", "update", "p1"))
                awaitTrue { b.size == 1 }
                assertTrue(a.isEmpty())

                service.unsubscribe("posts", cbB)
                assertEquals(listOf(unsubscribeFrame("posts")), factory.last.unsubscribeFrames)
                service.close()
            }
        }

    @Test
    fun `unsubscribe removes a filtered variant without a filter arg`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val got = mutableListOf<RealtimeEvent>()
                val cb: suspend (RealtimeEvent) -> Unit = { got += it }
                val job = async { service.subscribe("posts", filter = "status='published'", callback = cb) }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                service.unsubscribe("posts", cb)
                factory.last.push(eventFrame("posts", "update", "p1"))
                delay(20)
                assertTrue(got.isEmpty())
                assertEquals(listOf(unsubscribeFrame("posts")), factory.last.unsubscribeFrames)
                service.close()
            }
        }

    @Test
    fun `callback null and filter null clears every variant`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val got = mutableListOf<RealtimeEvent>()
                val cb: suspend (RealtimeEvent) -> Unit = { got += it }
                val t1 = async { service.subscribe("posts", callback = cb) }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                t1.await()

                val t2 = async { service.subscribe("posts", filter = "status='live'", callback = cb) }
                awaitTrue { factory.last.subscribeFrames.size == 2 }
                factory.last.push(ackFrame("posts"))
                t2.await()

                service.unsubscribe("posts") // callback=null, filter=null -> clears both variants
                assertEquals(listOf(unsubscribeFrame("posts")), factory.last.unsubscribeFrames)

                factory.last.push(eventFrame("posts", "update", "p1"))
                delay(20)
                assertTrue(got.isEmpty())
                service.close()
            }
        }

    @Test
    fun `unsubscribe is idempotent for an unknown topic or callback`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, _) = makeService()
                service.unsubscribe("nope")
                service.unsubscribe("nope", callback = { })
                service.close()
            }
        }
}

class RealtimeServiceSubscribeTopicTest {
    @Test
    fun `delivers signal and message frames by topic`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val got = mutableListOf<TopicMessage>()
                val job = async { service.subscribeTopic("orders") { got += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("orders")), factory.last.subscribeFrames)
                factory.last.push(ackFrame("orders"))
                job.await()

                factory.last.push(signalFrame("orders"))
                factory.last.push(messageFrame("orders", 1))
                factory.last.push(messageFrame("other", 2))
                awaitTrue { got.size == 2 }

                assertEquals("orders", got[0].topic)
                assertEquals("signal", got[0].kind)
                assertNull(got[0].data)
                assertEquals("orders", got[1].topic)
                assertEquals("message", got[1].kind)
                service.close()
            }
        }

    @Test
    fun `unsubscribe topic sends one frame when topic empties`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val got = mutableListOf<TopicMessage>()
                val cb: suspend (TopicMessage) -> Unit = { got += it }
                val job = async { service.subscribeTopic("orders", cb) }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("orders"))
                job.await()

                service.unsubscribeTopic("orders", cb)
                factory.last.push(signalFrame("orders"))
                delay(20)
                assertTrue(got.isEmpty())
                assertEquals(listOf(unsubscribeFrame("orders")), factory.last.unsubscribeFrames)
                service.close()
            }
        }
}

class RealtimeServiceTopicKeyIsolationTest {
    @Test
    fun `record sub key never collides with topic sub key`() =
        runTest {
            withContext(Dispatchers.Default) {
                // Regression guard (ported from realtime-subscribe.test.ts):
                // subscribe("", filter="topic:x") must not collide with
                // subscribeTopic("x") under a naive `" topic:x"`-style key
                // scheme -- the `r:`/`t:` prefixes must keep them
                // structurally disjoint.
                val (service, factory) = makeService()
                val recordEvents = mutableListOf<RealtimeEvent>()
                val topicMsgs = mutableListOf<TopicMessage>()

                val t1 = async { service.subscribe("", filter = "topic:x") { recordEvents += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame(""))
                t1.await()

                val t2 = async { service.subscribeTopic("x") { topicMsgs += it } }
                awaitTrue { factory.last.subscribeFrames.size == 2 }
                factory.last.push(ackFrame("x"))
                t2.await()

                assertTrue(subscribeFrame("", "topic:x") in factory.last.subscribeFrames)
                assertTrue(subscribeFrame("x") in factory.last.subscribeFrames)

                factory.last.push(eventFrame("", "create", "r1"))
                factory.last.push(signalFrame("x"))
                awaitTrue { recordEvents.size == 1 && topicMsgs.size == 1 }

                // Unsubscribing the topic sub must not disturb the independent record sub.
                service.unsubscribeTopic("x")
                factory.last.push(eventFrame("", "update", "r1"))
                awaitTrue { recordEvents.size == 2 }
                service.close()
            }
        }
}

class RealtimeServiceRaisingCallbackTest {
    @Test
    fun `raising callback is caught and surfaced via onError`() =
        runTest {
            withContext(Dispatchers.Default) {
                val errors = mutableListOf<String>()
                val (service, factory) = makeService(onError = { errors += it })
                val badCb: suspend (RealtimeEvent) -> Unit = { throw IllegalStateException("boom") }
                val got = mutableListOf<RealtimeEvent>()

                val job = async { service.subscribe("posts", callback = badCb) }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()
                service.subscribe("posts") { got += it } // already acked -> joins immediately

                factory.last.push(eventFrame("posts", "update", "p1"))
                awaitTrue { got.size == 1 }
                // The loop survived the raising callback -- the well-behaved sibling still fired.
                assertTrue(errors.any { "boom" in it })
                service.close()
            }
        }
}

class RealtimeServiceMalformedFramesTest {
    @Test
    fun `unknown frame type is dropped without crashing the loop`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }

                factory.last.push(
                    buildJsonObject {
                        put("type", "bogus")
                        put("topic", "posts")
                    },
                )
                delay(20)
                assertFalse(job.isCompleted)

                factory.last.push(ackFrame("posts"))
                job.await()
                service.close()
            }
        }
}

class RealtimeServiceConnectFrameTest {
    @Test
    fun `connect frame stores client id`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                assertNull(service.clientId)
                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() }
                factory.last.push(connectFrame("c1"))
                awaitTrue { service.clientId == "c1" }

                factory.last.push(ackFrame("posts"))
                job.await()
                service.close()
            }
        }
}

class RealtimeServiceServerErrorFrameTest {
    @Test
    fun `server error rejects pending subscribe and calls onError`() =
        runTest {
            withContext(Dispatchers.Default) {
                val errors = mutableListOf<String>()
                val (service, factory) = makeService(onError = { errors += it })
                val job = async { runCatching { service.subscribe("private") { } } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }

                factory.last.push(errorFrame("anonymous not allowed"))
                val ex = withTimeout(1_000) { job.await() }.exceptionAs<ZigbaseException>()
                assertEquals("anonymous not allowed", ex.message)
                assertTrue(errors.contains("anonymous not allowed"))
                service.close()
            }
        }

    @Test
    fun `a rejected subscribe can be retried with a fresh frame`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val job = async { runCatching { service.subscribe("private") { } } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(errorFrame("nope"))
                withTimeout(1_000) { job.await() }.exceptionAs<ZigbaseException>()

                val retry = async { service.subscribe("private") { } }
                awaitTrue { factory.last.subscribeFrames.size == 2 }
                factory.last.push(ackFrame("private"))
                retry.await()
                service.close()
            }
        }
}

class RealtimeServicePostCloseTest {
    @Test
    fun `subscribe after close raises without hanging`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                service.close()

                val ex =
                    assertFailsWithSuspend<ZigbaseException> {
                        withTimeout(1_000) { service.subscribe("posts") { } }
                    }
                assertEquals(0, ex.status)
                assertTrue(factory.connections.isEmpty())
            }
        }

    @Test
    fun `subscribeTopic after close raises without hanging`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                service.close()

                assertFailsWithSuspend<ZigbaseException> {
                    withTimeout(1_000) { service.subscribeTopic("orders") { } }
                }
                assertTrue(factory.connections.isEmpty())
            }
        }
}

class RealtimeServiceCloseTest {
    @Test
    fun `close cancels the receive loop cleanly without clearing the last-known client id`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() }
                factory.last.push(connectFrame("c1"))
                awaitTrue { service.clientId == "c1" }
                factory.last.push(ackFrame("posts"))
                job.await()

                withTimeout(1_000) { service.close() }
                // Matches the Python port: `clientId` is informational
                // last-known-connection state, not reset by close().
                assertEquals("c1", service.clientId)
            }
        }

    @Test
    fun `close explicitly closes the transport not just the receive loop`() =
        runTest {
            withContext(Dispatchers.Default) {
                // Regression guard: the receive loop's own `finally` clause
                // nulls the active connection as part of unwinding, so
                // `close()` must capture the connection reference BEFORE
                // cancelling that job -- reading it afterward would find it
                // already `null` and silently skip calling `connection.close()`.
                val (service, factory) = makeService()
                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                val conn = factory.last
                withTimeout(1_000) { service.close() }
                assertEquals(1, conn.closeCount)
            }
        }

    @Test
    fun `close during an in-flight connect tears down the late connection`() =
        runTest {
            withContext(Dispatchers.Default) {
                val factory = FakeConnectorFactory()
                factory.gate = CompletableDeferred()
                val (service, _) = makeService(factory)

                val job = async { runCatching { service.subscribe("posts") { } } }
                delay(50) // let the connect attempt reach (and park on) the gate
                assertTrue(factory.connections.isEmpty())

                withTimeout(1_000) { service.close() }
                factory.gate?.complete(Unit)

                withTimeout(1_000) { job.await() }.exceptionAs<ZigbaseException>()
                awaitTrue { factory.connections.size == 1 }
            }
        }
}

class RealtimeServiceShutdownAckHangTest {
    /**
     * Regression guard for the T6-review liveness defect: [RealtimeService
     * .shutdown]'s pending-ack failure is only a best-effort `tryLock` (see
     * that method's doc) -- on the (normally rare, race-dependent) tryLock
     * loss, nothing else ever settles a [subscribe] call's pending ack
     * deferred (`receiveLoop`'s own `finally` doesn't touch `sub.pending`,
     * and cancelling `scope` has no effect on the CALLER's own coroutine
     * running `subscribe`), so it would hang forever. [testHookForceShutdownSkipAckFail]
     * deterministically forces that lost-tryLock outcome (rather than
     * relying on winning a real race) so this test is reliably RED against
     * the pre-fix `deferred.await()` and reliably GREEN once `subscribe`/
     * `subscribeTopic` race their ack against [RealtimeService.close]'s
     * (package-private) `closeSignal` too.
     */
    @Test
    fun `shutdown unblocks a subscribe awaiting its ack even when the best-effort ack-fail is skipped`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                // `runCatching` inside the child, not a bare `service.subscribe(...)`:
                // an `async` child's exception otherwise propagates to cancel this
                // whole test body as soon as it occurs, not only once `job.await()`
                // is called -- see `exceptionAs`'s doc above for the same caveat.
                val job = async { runCatching { service.subscribe("posts") { } } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                // never ack the frame -- simulates shutdown()'s tryLock losing.
                service.testHookForceShutdownSkipAckFail = true

                service.shutdown()

                val ex = withTimeout(1_000) { job.await() }.exceptionAs<ZigbaseException>()
                assertEquals(0, ex.status)
            }
        }
}

class RealtimeServiceConnectCancelTest {
    @Test
    fun `cancelling a connect mid-flight resets the connecting flag`() =
        runTest {
            withContext(Dispatchers.Default) {
                val factory = FakeConnectorFactory()
                factory.gate = CompletableDeferred()
                val (service, _) = makeService(factory)

                val job = async { service.subscribe("posts") { } }
                delay(50) // let the connect attempt reach (and park on) the gate
                assertTrue(factory.connections.isEmpty())
                job.cancel()
                job.join()

                // Release the gate so a fresh connect below doesn't hang on it too.
                factory.gate?.complete(Unit)
                factory.gate = null

                // A later subscribe must connect fresh rather than finding
                // `connecting` stuck `true` forever -- the SP2 regression.
                val retry = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                retry.await()
                service.close()
            }
        }
}

class RealtimeServiceConnectFailureTest {
    @Test
    fun `connect failure does not propagate to the subscribe caller`() =
        runTest {
            withContext(Dispatchers.Default) {
                val errors = mutableListOf<String>()
                val factory = FakeConnectorFactory()
                factory.pendingFailures = 1
                val (service, _) = makeService(factory, onError = { errors += it })

                val job = async { runCatching { service.subscribe("posts") { } } }
                awaitTrue { errors.isNotEmpty() }
                assertFalse(job.isCompleted)

                service.close()
                withTimeout(1_000) { job.await() }.exceptionAs<ZigbaseException>()
            }
        }
}

/**
 * Regressions for two TOCTOU windows found in review: a `subscribe`/
 * `subscribeTopic` (or a `connectOnce`) that reads `closedByUser` off-lock,
 * then commits state in a LATER, separate locked section, can have `close()`
 * run to completion in between -- observing the pre-close state and then
 * committing post-close anyway. Both use the internal test-only suspension
 * hooks ([RealtimeService.testHookBeforePendingRegistration]/
 * [RealtimeService.testHookAfterConnect]) to force the race deterministically
 * rather than relying on scheduler luck.
 */
class RealtimeServiceCloseRaceTest {
    @Test
    fun `a subscribe parked before pending registration does not hang forever when close races it`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val hookEntered = CompletableDeferred<Unit>()
                val releaseHook = CompletableDeferred<Unit>()
                service.testHookBeforePendingRegistration = {
                    hookEntered.complete(Unit)
                    releaseHook.await()
                }

                // Registers the callback and connects, then parks exactly
                // between the closed-check and the pending-deferred
                // registration -- the historical gap.
                val job = async { runCatching { service.subscribe("posts") { } } }
                withTimeout(1_000) { hookEntered.await() }

                // close() runs to completion while the subscribe is parked:
                // it fails whatever is in `sub.pending` right now (nothing --
                // the parked call hasn't registered its deferred yet) and
                // clears the subscription map.
                withTimeout(1_000) { service.close() }

                // Release the parked subscribe: it must observe the
                // already-closed flag INSIDE the same lock as registering its
                // deferred, rather than registering one nothing will ever
                // settle.
                releaseHook.complete(Unit)
                withTimeout(1_000) { job.await() }.exceptionAs<ZigbaseException>()
            }
        }

    @Test
    fun `a connect resolving after close reads the flag does not leak the connection`() =
        runTest {
            withContext(Dispatchers.Default) {
                val factory = FakeConnectorFactory()
                val (service, _) = makeService(factory)
                val hookEntered = CompletableDeferred<Unit>()
                val releaseHook = CompletableDeferred<Unit>()
                service.testHookAfterConnect = {
                    hookEntered.complete(Unit)
                    releaseHook.await()
                }

                // The connector resolves and the off-lock closed-check reads
                // `false`, then parks right before the connection would be
                // committed -- the historical gap.
                val job = async { runCatching { service.subscribe("posts") { } } }
                withTimeout(1_000) { hookEntered.await() }
                assertTrue(factory.connections.isNotEmpty())

                // close() runs to completion while the connect is parked: at
                // this point `activeConnection` is still `null`, so a naive
                // close() has nothing of this connection to tear down.
                withTimeout(1_000) { service.close() }

                // Release the parked connect: its connection must still get
                // torn down -- not silently adopted after the scope it would
                // run on has already been cancelled, which would leak the
                // socket forever.
                releaseHook.complete(Unit)
                withTimeout(1_000) { job.await() }.exceptionAs<ZigbaseException>()
                awaitTrue { factory.last.closeCount == 1 }
            }
        }
}

/**
 * Regression for the pre-existing `connectOnce()` TOCTOU: a demonstrated
 * ~1/60 flake in `RealtimeServiceConcurrentSubscribeTest` under real
 * `Dispatchers.Default` parallelism. `attemptConnect()` used to clear
 * `connecting` in its own `finally` on EVERY exit, including success --
 * before `connectOnce()`'s later, separate locked section ever commits
 * `activeConnection`. In that gap, a concurrent `subscribe()` observed
 * `connecting == false && activeConnection == null && reconnectPending ==
 * false` (all false) and opened a second, competing socket -- a silent leak
 * plus a duplicate subscribe frame. [RealtimeService.testHookAfterConnect]
 * pins the race deterministically at exactly that gap.
 */
class RealtimeServiceConnectToctouRaceTest {
    @Test
    fun `a subscribe racing a parked connect never opens a second connection`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val hookEntered = CompletableDeferred<Unit>()
                val releaseHook = CompletableDeferred<Unit>()
                service.testHookAfterConnect = {
                    hookEntered.complete(Unit)
                    releaseHook.await()
                }

                // job1's connect is parked right after `attemptConnect()`
                // returns -- BEFORE `activeConnection` is committed. This is
                // exactly the historical TOCTOU window.
                val job1 = async { service.subscribe("posts") { } }
                withTimeout(1_000) { hookEntered.await() }

                // A concurrent subscribe to a DIFFERENT topic races that
                // window. `testHookBeforePendingRegistration` fires right
                // after `ensureConnected()` returns inside `subscribe()` --
                // reachable quickly ONLY if job2 did NOT itself get stuck
                // re-entering the (shared) `testHookAfterConnect` park, i.e.
                // only if it correctly deferred to job1's in-flight connect
                // instead of opening a second one. Pre-fix, job2 opens its
                // own connection and gets stuck in that same park too, so
                // this never fires before the bounded wait below elapses.
                val job2ReachedPending = CompletableDeferred<Unit>()
                service.testHookBeforePendingRegistration = { job2ReachedPending.complete(Unit) }
                val job2 = async { service.subscribe("comments") { } }
                withTimeoutOrNull(500) { job2ReachedPending.await() }

                // The fix: exactly one connection, never two.
                assertEquals(1, factory.connections.size)

                releaseHook.complete(Unit)

                awaitTrue { factory.last.subscribeFrames.size >= 2 }
                factory.last.push(ackFrame("posts"))
                factory.last.push(ackFrame("comments"))
                job1.await()
                job2.await()
                assertEquals(1, factory.connections.size)
                service.close()
            }
        }
}

/**
 * A SEPARATE regression from [RealtimeServiceConnectToctouRaceTest]'s, found
 * while heavy-flake-looping this file's fix for that one: `resubscribeAll`'s
 * reset of every subscription's `acked`/`inflight` flags used to be a
 * separate, LATER locked step than [RealtimeService.connectOnce]'s
 * `activeConnection`/`opened` commit -- so a concurrent `subscribe()` to the
 * SAME topic, already deferring in `ensureConnected()` (because it observed
 * `connecting` or `activeConnection` before the commit), could observe the
 * just-committed `opened`/`activeConnection`, send its own subscribe frame,
 * and mark `inflight = true` -- all BEFORE `resubscribeAll` got a chance to
 * run. `resubscribeAll`'s reset then stomped that fresh `inflight` mark back
 * to `false` and resent, producing a duplicate frame on the SAME connection
 * (never a second connection, unlike the TOCTOU above -- this is why it
 * wasn't caught by that test's `factory.connections.size` assertion, only by
 * a much heavier stress loop). [RealtimeService.testHookAfterCommit] pins
 * this race deterministically at exactly that gap.
 */
class RealtimeServiceResubscribeStompTest {
    @Test
    fun `resubscribeAll does not stomp and resend a frame a racing subscribe already sent`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val hookEntered = CompletableDeferred<Unit>()
                val releaseHook = CompletableDeferred<Unit>()
                service.testHookAfterCommit = {
                    hookEntered.complete(Unit)
                    releaseHook.await()
                }

                val job1 = async { service.subscribe("posts") { } }
                withTimeout(1_000) { hookEntered.await() }

                // `opened`/`activeConnection` are committed but `onOpen()`/
                // `resubscribeAll()` hasn't run yet. A concurrent subscribe
                // to the SAME topic -- already deferred inside
                // `ensureConnected()`, since `connecting` was true when it
                // checked -- can now race in and send its own frame on the
                // freshly-committed connection before `resubscribeAll` ever
                // runs.
                val job2 = async { service.subscribe("posts") { } }
                withTimeout(1_000) { awaitTrue { factory.last.subscribeFrames.isNotEmpty() } }

                releaseHook.complete(Unit)

                // Both jobs only complete once acked -- by the time they do,
                // `resubscribeAll` (which runs synchronously inside job1's
                // own `subscribe()` call, before it can even register its own
                // pending deferred) has definitely already finished, so this
                // is a deterministic post-condition, not a race window.
                factory.last.push(ackFrame("posts"))
                withTimeout(1_000) { job1.await() }
                withTimeout(1_000) { job2.await() }
                assertEquals(1, factory.last.subscribeFrames.size)
                service.close()
            }
        }
}

/**
 * Regression for the gemini KSP2 finding on [RealtimeService]'s
 * `sendSubscribeIfNeeded`: its `CancellationException` catch used to rethrow
 * WITHOUT resetting `sub.inflight`, while the sibling `Exception` catch does.
 * So a `subscribe()` cancelled while parked in `conn.send` left the shared
 * [Subscription] stuck `inflight = true` forever; a later subscribe to the
 * same topic/filter (which shares that `Subscription`) then hit the
 * `inflight` gate, never sent its own frame, and hung (bounded only by
 * `close()`). The fix resets `inflight` under `NonCancellable` before
 * rethrowing.
 *
 * The gated send here is the one fired DIRECTLY from `subscribe()` on an
 * ALREADY-open connection -- deliberately not the `resubscribeAll` send
 * inside `connectOnce`, whose own (Finding 2) teardown would tear the socket
 * down and mask this by resetting `inflight` at the next commit.
 */
class RealtimeServiceSubscribeSendCancelledTest {
    @Test
    fun `a subscribe cancelled mid-send resets inflight so a later subscribe to the same topic still sends`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()

                // Establish a healthy, fully-open connection first, so the
                // send cancelled below is `subscribe()`'s own direct
                // `sendSubscribeIfNeeded` call -- connectOnce has already
                // returned by this point.
                val seed = async { service.subscribe("seed") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("seed"))
                seed.await()

                // Park the NEXT send on this live connection -- it will be the
                // "posts" subscribe frame.
                val sendEntered = CompletableDeferred<Unit>()
                factory.last.sendEntered = sendEntered
                factory.last.sendGate = CompletableDeferred()

                val jobA = async { service.subscribe("posts") { } }
                withTimeout(1_000) { sendEntered.await() }

                // Cancel jobA while it is parked in `conn.send` with
                // `sub.inflight` already marked `true`.
                jobA.cancel()
                jobA.join()

                // A second subscribe to the SAME topic shares that
                // Subscription. Pre-fix it hits the stuck `inflight` gate,
                // never sends a frame, and hangs on an ack that never comes;
                // post-fix the reset lets its frame go out and the ack settle
                // it.
                val jobB = async { service.subscribe("posts") { } }
                awaitTrue { factory.last.subscribeFrames.any { it == subscribeFrame("posts") } }
                factory.last.push(ackFrame("posts"))
                withTimeout(1_000) { jobB.await() }
                service.close()
            }
        }
}

/**
 * Regression for the gemini KSP2 finding on [RealtimeService.connectOnce]: a
 * connect cancelled (or throwing) AFTER the `activeConnection`/`opened`
 * commit but BEFORE [RealtimeService] finished wiring the connection up left
 * a half-initialized socket -- `activeConnection` non-null and `opened` true,
 * yet auth/resubscribe never ran. Worst case (pinned here via
 * [RealtimeService.testHookAfterCommit]), the cancellation lands in the gap
 * AFTER commit but BEFORE the receive loop is even launched: a genuinely dead
 * half-open socket with no receive loop, which the old `finally` neither
 * closed (`adopted` was `true`) nor rolled back -- so `ensureConnected` saw a
 * non-null `activeConnection`, never reconnected, and every later subscribe
 * hung. The fix tracks a `success` flag and transactionally undoes the commit
 * (null `activeConnection`, clear `opened`, close the socket) on any
 * unsuccessful exit.
 */
class RealtimeServiceConnectCancelledAfterCommitTest {
    @Test
    fun `a connect cancelled after commit is rolled back so a later subscribe reconnects`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val hookEntered = CompletableDeferred<Unit>()
                val releaseHook = CompletableDeferred<Unit>()
                service.testHookAfterCommit = {
                    hookEntered.complete(Unit)
                    releaseHook.await()
                }

                // job1 parks right after connectOnce commits
                // `activeConnection`/`opened` but BEFORE the receive loop is
                // launched -- the dead-half-open window.
                val job1 = async { service.subscribe("posts") { } }
                withTimeout(1_000) { hookEntered.await() }
                assertEquals(1, factory.connections.size)

                // Cancel job1 while parked: connectOnce unwinds through its
                // `finally`. Pre-fix, `adopted == true` keeps
                // `activeConnection`/`opened` set and never closes the socket,
                // wedging the service on a receive-loop-less connection.
                job1.cancel()
                job1.join()

                // Clear the hook so the fresh connect below is not parked too.
                service.testHookAfterCommit = null

                // Post-fix, the commit was rolled back, so this subscribe
                // opens a brand-new connection. Pre-fix, `ensureConnected`
                // sees the stale non-null `activeConnection`, never connects,
                // and this hangs on an ack nothing will deliver.
                val job2 = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.size == 2 }
                factory.last.push(ackFrame("posts"))
                withTimeout(1_000) { job2.await() }

                // The rolled-back socket was torn down, not leaked.
                assertEquals(1, factory.connections[0].closeCount)
                service.close()
            }
        }
}
