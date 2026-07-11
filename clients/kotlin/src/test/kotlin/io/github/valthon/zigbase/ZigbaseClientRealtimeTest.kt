package io.github.valthon.zigbase

import io.github.valthon.zigbase.errors.ZigbaseException
import io.github.valthon.zigbase.realtime.FakeConnectorFactory
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import io.ktor.http.HttpMethod
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotSame
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Test

/**
 * Tests for [ZigbaseClient.realtime] -- wiring the realtime tier (Tasks 2-5.5)
 * through the public facade: same-instance caching, the internal
 * [ZigbaseClient.realtimeConnectorForTesting] injection point, `close()`
 * ordering across the suspend/non-suspend boundary, and [ZigbaseClient
 * .withAccount] sibling isolation.
 *
 * Every test that drives a [FakeConnectorFactory] connection runs under
 * `withContext(Dispatchers.Default)` and polls with [awaitTrue] -- same
 * pattern as `realtime/RealtimeServiceTest.kt` -- since [ZigbaseClient
 * .realtime] runs its own connect/subscribe/ack machinery on real
 * `Dispatchers.Default` threads, independent of `runTest`'s virtual time.
 */
class ZigbaseClientRealtimeTest {
    private fun mockClient(): HttpClient = HttpClient(MockEngine { respond("{}") })

    private fun ackFrame(topic: String): JsonObject =
        buildJsonObject {
            put("type", "ack")
            put("action", "subscribe")
            put("topic", topic)
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

    @Test
    fun `realtime is the same instance on every access`() {
        val zb = ZigbaseClient("http://localhost:8090", httpClient = mockClient())
        assertSame(zb.realtime, zb.realtime)
        zb.close()
    }

    @Test
    fun `injected fake connector is driven through the facade`() =
        runTest {
            withContext(Dispatchers.Default) {
                val factory = FakeConnectorFactory()
                val zb = ZigbaseClient("http://localhost:8090", httpClient = mockClient())
                zb.realtimeConnectorForTesting = factory::connect

                val job = async { zb.realtime.subscribe("posts") {} }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                assertEquals(1, factory.last.subscribeFrames.size)
                zb.close()
            }
        }

    @Test
    fun `close tears down realtime before transport`() =
        runTest {
            val zb = ZigbaseClient("http://127.0.0.1:65535")
            zb.realtimeConnectorForTesting = FakeConnectorFactory()::connect
            zb.realtime // materialize before close

            zb.close()

            assertFailsWithSuspend<ZigbaseException> { zb.realtime.subscribe("posts") {} }
            assertFailsWithSuspend<Throwable> { zb.rawRequest(HttpMethod.Get, "/api/health") }
        }

    @Test
    fun `withAccount sibling gets its own independent realtime`() =
        runTest {
            withContext(Dispatchers.Default) {
                val parentFactory = FakeConnectorFactory()
                val zb = ZigbaseClient("http://localhost:8090", httpClient = mockClient())
                zb.realtimeConnectorForTesting = parentFactory::connect
                val sibling = zb.withAccount("acct-1")

                assertNotSame(zb.realtime, sibling.realtime)

                // the injected test connector propagates to the sibling.
                val siblingJob = async { sibling.realtime.subscribe("posts") {} }
                awaitTrue { parentFactory.connections.isNotEmpty() && parentFactory.last.subscribeFrames.isNotEmpty() }
                parentFactory.last.push(ackFrame("posts"))
                siblingJob.await()
                assertEquals(1, parentFactory.connections.size)

                // closing the parent's realtime never disturbs the sibling's
                // still-open connection -- a further sibling subscribe reuses
                // it rather than opening a new one (connections.size stays 1).
                zb.close()
                val secondJob = async { sibling.realtime.subscribe("comments") {} }
                awaitTrue { parentFactory.last.subscribeFrames.size == 2 }
                parentFactory.last.push(ackFrame("comments"))
                secondJob.await()
                assertEquals(1, parentFactory.connections.size)

                sibling.close()
            }
        }

    /** Runs [block] and returns the thrown [T], or fails if nothing was thrown. Suspend-friendly `assertThrows`. */
    private suspend inline fun <reified T : Throwable> assertFailsWithSuspend(noinline block: suspend () -> Unit): T {
        try {
            block()
        } catch (e: Throwable) {
            if (e is T) return e
            throw e
        }
        throw AssertionError("Expected ${T::class.simpleName} to be thrown, but nothing was")
    }
}
