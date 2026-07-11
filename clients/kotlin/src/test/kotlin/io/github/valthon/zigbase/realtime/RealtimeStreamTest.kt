package io.github.valthon.zigbase.realtime

/*
 * Tests for [RealtimeService.stream]/[RealtimeService.streamTopic] -- cold
 * `Flow`s layered over the callback [RealtimeService.subscribe]/
 * [RealtimeService.subscribeTopic] API. Port of the intended semantics in
 * `clients/python/src/zigbase/realtime.py`'s `stream()` (subscribe on first
 * collection, unsubscribe on completion/cancellation/rejection/close), but
 * `callbackFlow`'s cancellation model -- not Python's generator/`aclose()`
 * shape -- is the source of truth for HOW teardown is wired here.
 *
 * Same helpers/idioms as `RealtimeServiceTest.kt` (private to that file, so
 * duplicated here rather than shared): `makeService`, `awaitTrue` (a real,
 * observable-condition poll -- never a fixed sleep used for POSITIVE
 * synchronization), and the frame builders. Event-collector lists use
 * `CopyOnWriteArrayList`, not a plain `mutableListOf` -- same rationale as
 * `FakeConnection.sent` in `FakeConnector.kt`: the service's dispatch loop
 * appends from a real `Dispatchers.Default` thread while a test's polling
 * `awaitTrue` predicate reads (and here, iterates via `.any { }`) the same
 * list from another; a plain `ArrayList` throws `ConcurrentModificationException`
 * under that access pattern.
 */

import io.github.valthon.zigbase.RealtimeEvent
import io.github.valthon.zigbase.auth.MemoryAuthStore
import io.github.valthon.zigbase.errors.ZigbaseException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.concurrent.CopyOnWriteArrayList

private fun makeService(
    factory: FakeConnectorFactory = FakeConnectorFactory(),
    onError: (String) -> Unit = {},
): Pair<RealtimeService, FakeConnectorFactory> = RealtimeService("http://api.test", MemoryAuthStore(), factory::connect, onError) to factory

/**
 * Extracts the [T] failure from a [Result] (e.g. one produced by
 * `async { runCatching { ... } }`), or fails if it succeeded or failed with
 * a different type. Same rationale as `RealtimeServiceTest.kt`'s twin: an
 * `async` child's exception would otherwise tear down the whole test body
 * the instant it occurs, not only once something awaits it.
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

class RealtimeStreamCollectTest {
    @Test
    fun `stream delivers dispatched events in order to a collector`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val got = CopyOnWriteArrayList<RealtimeEvent>()
                val collectJob = launch { service.stream("posts").collect { got += it } }

                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), factory.last.subscribeFrames)
                factory.last.push(ackFrame("posts"))

                factory.last.push(eventFrame("posts", "create", "p1"))
                factory.last.push(eventFrame("posts", "update", "p2"))
                awaitTrue { got.size == 2 }
                assertEquals("p1", got[0].record.id)
                assertEquals("create", got[0].action)
                assertEquals("p2", got[1].record.id)
                assertEquals("update", got[1].action)

                collectJob.cancel()
                collectJob.join()
                service.close()
            }
        }
}

class RealtimeStreamCancelMidAckTest {
    @Test
    fun `cancelling the collector mid-ack tears down leak-free`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val hookEntered = CompletableDeferred<Unit>()
                val releaseHook = CompletableDeferred<Unit>()
                service.testHookBeforePendingRegistration = {
                    hookEntered.complete(Unit)
                    releaseHook.await()
                }

                val got = CopyOnWriteArrayList<RealtimeEvent>()
                val collectJob = launch { service.stream("posts").collect { got += it } }
                withTimeout(1_000) { hookEntered.await() }

                collectJob.cancel()
                releaseHook.complete(Unit)
                withTimeout(1_000) { collectJob.join() }

                // Teardown ran (an unsubscribe frame was sent for the never-acked
                // subscription) -- proof the callback registered before cancellation
                // didn't leak.
                awaitTrue { factory.last.unsubscribeFrames.isNotEmpty() }

                // A dangling/stuck subscription would silently swallow this fresh
                // subscribe's frame (still `inflight`); it must send a NEW one.
                service.testHookBeforePendingRegistration = null
                val framesBefore = factory.last.subscribeFrames.size
                val job2 = async { service.subscribe("posts") { } }
                awaitTrue { factory.last.subscribeFrames.size > framesBefore }
                factory.last.push(ackFrame("posts"))
                job2.await()
                service.close()
            }
        }
}

class RealtimeStreamRejectedTest {
    @Test
    fun `a rejected subscribe throws into the collector`() =
        runTest {
            withContext(Dispatchers.Default) {
                // `CopyOnWriteArrayList`, not a plain `mutableListOf`: `onError`
                // appends from the receive-loop thread while this test's
                // `awaitTrue` polls (and `.contains`s) the same list from
                // another -- same rationale as `FakeConnection.sent`.
                val errors = CopyOnWriteArrayList<String>()
                val (service, factory) = makeService(onError = { errors += it })
                val result = async { runCatching { service.stream("private").collect { } } }

                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(errorFrame("anonymous not allowed"))

                val ex = withTimeout(1_000) { result.await() }.exceptionAs<ZigbaseException>()
                assertEquals("anonymous not allowed", ex.message)
                // `onErrorFrame` completes the rejected subscribe's deferred
                // BEFORE calling `onError` -- so `result.await()` above can
                // resolve before `errors` is populated; poll rather than
                // assert immediately.
                awaitTrue { errors.contains("anonymous not allowed") }
                // The server never acked (and the subscription was dropped by the
                // rejection itself) -- no unsubscribe frame is owed.
                assertTrue(factory.last.unsubscribeFrames.isEmpty())
                service.close()
            }
        }
}

class RealtimeStreamCloseEndsCleanlyTest {
    @Test
    fun `service close ends the flow cleanly without throwing`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val got = CopyOnWriteArrayList<RealtimeEvent>()
                var completedNormally = false
                var thrown: Throwable? = null
                val collectJob =
                    launch {
                        try {
                            service.stream("posts").collect { got += it }
                            completedNormally = true
                        } catch (e: Throwable) {
                            thrown = e
                        }
                    }

                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                // Prove the flow is fully live (subscribed, acked, delivering) before
                // closing -- not merely mid-subscribe.
                factory.last.push(eventFrame("posts", "create", "p1"))
                awaitTrue { got.size == 1 }

                withTimeout(1_000) { service.close() }
                withTimeout(1_000) { collectJob.join() }

                assertTrue(completedNormally)
                assertEquals(null, thrown)
            }
        }
}

class RealtimeStreamCloseWhileUnackedTest {
    @Test
    fun `service close while the subscribe ack is still pending ends the flow cleanly`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                var completedNormally = false
                var thrown: Throwable? = null
                val collectJob =
                    launch {
                        try {
                            service.stream("posts").collect { }
                            completedNormally = true
                        } catch (e: Throwable) {
                            thrown = e
                        }
                    }

                // The subscribe frame is on the wire but deliberately never
                // acked -- close() must race the still-in-flight subscribe()
                // call, not a settled one (that window is already covered by
                // RealtimeStreamCloseEndsCleanlyTest).
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }

                withTimeout(1_000) { service.close() }
                withTimeout(1_000) { collectJob.join() }

                assertTrue(completedNormally)
                assertEquals(null, thrown)
            }
        }
}

class RealtimeStreamTakeOneTest {
    @Test
    fun `take(1) unsubscribes only its own callback then the last variant sends unsubscribe`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory) = makeService()
                val otherEvents = CopyOnWriteArrayList<RealtimeEvent>()
                val otherJob = launch { service.stream("posts").collect { otherEvents += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                factory.last.push(eventFrame("posts", "create", "seed"))
                awaitTrue { otherEvents.size == 1 }

                val firstEvents = CopyOnWriteArrayList<RealtimeEvent>()
                val firstJob = launch { service.stream("posts").take(1).collect { firstEvents += it } }

                // Retry-push a probe event until `first` has definitely registered and
                // captured one -- deterministic convergence (bounded by withTimeout), not
                // a fixed sleep relied on for synchronization; `other` (already live)
                // receives every probe too.
                withTimeout(2_000) {
                    var n = 0
                    while (firstEvents.isEmpty()) {
                        factory.last.push(eventFrame("posts", "update", "probe-${n++}"))
                        delay(1)
                    }
                }
                awaitTrue { firstJob.isCompleted }

                // The shared subscription is still alive for `other` -- tearing down
                // `first` must NOT send an unsubscribe frame yet. The fire-and-forget
                // teardown is asynchronous, so give it a bounded window to (not) run.
                delay(20)
                assertTrue(factory.last.unsubscribeFrames.isEmpty())

                // `other` keeps receiving events after `first`'s teardown -- proof it
                // was never disturbed by it.
                factory.last.push(eventFrame("posts", "update", "after-teardown"))
                awaitTrue { otherEvents.any { it.record.id == "after-teardown" } }

                // Now remove the LAST variant: ending `other` must send the frame.
                otherJob.cancel()
                otherJob.join()
                awaitTrue { factory.last.unsubscribeFrames.isNotEmpty() }
                assertEquals(listOf(unsubscribeFrame("posts")), factory.last.unsubscribeFrames)
                service.close()
            }
        }
}
