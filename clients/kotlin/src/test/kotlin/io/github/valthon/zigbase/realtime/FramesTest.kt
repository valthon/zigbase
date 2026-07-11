package io.github.valthon.zigbase.realtime

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.ClosedReceiveChannelException
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Tests for the realtime frame codec ([encodeAuth]/[encodeSubscribe]/
 * [encodeUnsubscribe]/[decodeFrame]/[realtimeUrl]) and the [FakeConnection]/
 * [FakeConnectorFactory] test doubles, mirroring
 * `clients/python/tests/test_realtime_frames.py` (codec fixtures) and
 * `clients/python/tests/support/fake_connector.py` (fake round-trip).
 */
private fun parse(text: String): JsonObject = Json.parseToJsonElement(text) as JsonObject

private fun stringField(
    obj: JsonObject,
    key: String,
): String? = (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

class EncodeAuthTest {
    @Test
    fun `encodes action and token`() {
        val frame = parse(encodeAuth("tok123"))
        assertEquals(
            buildJsonObject {
                put("action", "auth")
                put("token", "tok123")
            },
            frame,
        )
    }

    @Test
    fun `empty token de-auths`() {
        val frame = parse(encodeAuth(""))
        assertEquals("", stringField(frame, "token"))
    }
}

class EncodeSubscribeTest {
    @Test
    fun `omits filter key entirely when null`() {
        val frame = parse(encodeSubscribe("posts", null))
        assertEquals(
            buildJsonObject {
                put("action", "subscribe")
                put("topic", "posts")
            },
            frame,
        )
        assertFalse("filter" in frame)
    }

    @Test
    fun `includes filter key when present`() {
        val frame = parse(encodeSubscribe("posts", "status='live'"))
        assertEquals(
            buildJsonObject {
                put("action", "subscribe")
                put("topic", "posts")
                put("filter", "status='live'")
            },
            frame,
        )
    }
}

class EncodeUnsubscribeTest {
    @Test
    fun `encodes action and topic`() {
        val frame = parse(encodeUnsubscribe("posts"))
        assertEquals(
            buildJsonObject {
                put("action", "unsubscribe")
                put("topic", "posts")
            },
            frame,
        )
    }
}

class DecodeFrameTest {
    @Test
    fun `parses a JSON object`() {
        val frame = decodeFrame("""{"type":"connect","clientId":"c1"}""")
        assertEquals("connect", frame?.let { stringField(it, "type") })
        assertEquals("c1", frame?.let { stringField(it, "clientId") })
    }

    @Test
    fun `drops malformed json`() {
        assertNull(decodeFrame("not json"))
    }

    @Test
    fun `drops a JSON array`() {
        assertNull(decodeFrame("[1, 2, 3]"))
    }

    @Test
    fun `drops a bare number`() {
        assertNull(decodeFrame("42"))
    }

    @Test
    fun `drops a bare string`() {
        assertNull(decodeFrame(""""hello""""))
    }

    @Test
    fun `drops a bare boolean`() {
        assertNull(decodeFrame("true"))
    }

    @Test
    fun `drops json null`() {
        assertNull(decodeFrame("null"))
    }
}

class RealtimeUrlTest {
    @Test
    fun `maps http to ws`() {
        assertEquals("ws://localhost:8090/api/realtime", realtimeUrl("http://localhost:8090"))
    }

    @Test
    fun `maps https to wss`() {
        assertEquals("wss://example.com/api/realtime", realtimeUrl("https://example.com"))
    }

    @Test
    fun `strips a single trailing slash`() {
        assertEquals("ws://localhost:8090/api/realtime", realtimeUrl("http://localhost:8090/"))
    }

    @Test
    fun `strips multiple trailing slashes`() {
        assertEquals("ws://localhost:8090/api/realtime", realtimeUrl("http://localhost:8090///"))
    }
}

@OptIn(ExperimentalCoroutinesApi::class)
class FakeConnectionTest {
    @Test
    fun `push delivers a frame on incoming`() =
        runTest {
            val connection = FakeConnection()
            val frame =
                buildJsonObject {
                    put("type", "connect")
                    put("clientId", "c1")
                }

            connection.push(frame)
            val received = connection.incoming.receive()

            assertEquals(frame, parse(received))
        }

    @Test
    fun `send captures a decoded frame in sent`() =
        runTest {
            val connection = FakeConnection()

            connection.send(encodeAuth("tok"))

            assertEquals(1, connection.sent.size)
            assertEquals("auth", stringField(connection.sent[0], "action"))
        }

    @Test
    fun `subscribeFrames and unsubscribeFrames filter by action`() =
        runTest {
            val connection = FakeConnection()

            connection.send(encodeSubscribe("posts", null))
            connection.send(encodeAuth("tok"))
            connection.send(encodeUnsubscribe("posts"))

            assertEquals(1, connection.subscribeFrames.size)
            assertEquals(1, connection.unsubscribeFrames.size)
            assertEquals("posts", stringField(connection.subscribeFrames[0], "topic"))
            assertEquals("posts", stringField(connection.unsubscribeFrames[0], "topic"))
        }

    @Test
    fun `sendException fails exactly the next send, then clears`() =
        runTest {
            val connection = FakeConnection()
            connection.sendException = RuntimeException("boom")

            val ex =
                try {
                    connection.send(encodeAuth("tok"))
                    null
                } catch (e: RuntimeException) {
                    e
                }
            assertEquals("boom", ex?.message)
            assertTrue(connection.sent.isEmpty())

            // One-shot: the next send succeeds and is recorded normally.
            connection.send(encodeAuth("tok2"))
            assertEquals(1, connection.sent.size)
        }

    @Test
    fun `serverClose ends incoming`() =
        runTest {
            val connection = FakeConnection()

            connection.serverClose()

            val ex =
                try {
                    connection.incoming.receive()
                    null
                } catch (e: ClosedReceiveChannelException) {
                    e
                }
            assertTrue(ex is ClosedReceiveChannelException)
        }

    @Test
    fun `close ends incoming`() =
        runTest {
            val connection = FakeConnection()

            connection.close()

            val ex =
                try {
                    connection.incoming.receive()
                    null
                } catch (e: ClosedReceiveChannelException) {
                    e
                }
            assertTrue(ex is ClosedReceiveChannelException)
        }
}

@OptIn(ExperimentalCoroutinesApi::class)
class FakeConnectorFactoryTest {
    @Test
    fun `connect hands out a fresh connection tracked in connections and last`() =
        runTest {
            val factory = FakeConnectorFactory()

            val first = factory.connect("ws://x/api/realtime")
            val second = factory.connect("ws://x/api/realtime")

            assertEquals(listOf(first, second), factory.connections)
            assertEquals(second, factory.last)
        }

    @Test
    fun `pendingFailures throws for that many attempts, then succeeds`() =
        runTest {
            val factory = FakeConnectorFactory()
            factory.pendingFailures = 2

            var failures = 0
            repeat(2) {
                try {
                    factory.connect("ws://x/api/realtime")
                } catch (e: Exception) {
                    failures += 1
                }
            }
            assertEquals(2, failures)
            assertEquals(0, factory.pendingFailures)
            assertTrue(factory.connections.isEmpty())

            val connection = factory.connect("ws://x/api/realtime")
            assertEquals(listOf(connection), factory.connections)
        }

    @Test
    fun `gate parks connect until completed`() =
        runTest(StandardTestDispatcher()) {
            val factory = FakeConnectorFactory()
            val gate = CompletableDeferred<Unit>()
            factory.gate = gate

            val job = async { factory.connect("ws://x/api/realtime") }
            advanceUntilIdle()
            assertTrue(factory.connections.isEmpty())

            gate.complete(Unit)
            advanceUntilIdle()

            assertEquals(1, factory.connections.size)
            assertEquals(factory.connections[0], job.await())
        }

    @Test
    fun `nextSendException primes the next built connection once`() =
        runTest {
            val factory = FakeConnectorFactory()
            factory.nextSendException = RuntimeException("auth send failed")

            val connection = factory.connect("ws://x/api/realtime") as FakeConnection
            assertNull(factory.nextSendException)

            val ex =
                try {
                    connection.send(encodeAuth("tok"))
                    null
                } catch (e: RuntimeException) {
                    e
                }
            assertEquals("auth send failed", ex?.message)

            val second = factory.connect("ws://x/api/realtime") as FakeConnection
            second.send(encodeAuth("tok"))
            assertEquals(1, second.sent.size)
        }
}
