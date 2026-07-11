package io.github.valthon.zigbase.typed

/*
 * Tests for [TypedRealtime]/[TypedRealtimeEvent], a port of
 * `clients/dart/lib/typed.dart:522-569` (`TypedRealtime<T>`), cross-checked
 * against `clients/python/tests/test_typed_realtime.py`.
 *
 * Drives a real [ZigbaseClient] wired to a [FakeConnectorFactory] (same
 * doubles `ZigbaseClientRealtimeTest`/`RealtimeStreamTest` use) so the
 * wrapper is exercised through the actual `client.realtime` property rather
 * than a hand-rolled fake `RealtimeService`. Everything runs inside
 * `withContext(Dispatchers.Default)`: the underlying `RealtimeService` uses
 * real threads, not `runTest`'s virtual time, so a bare `runTest` body would
 * deadlock on `awaitTrue`'s real-`delay` poll.
 */

import io.github.valthon.zigbase.ZigbaseClient
import io.github.valthon.zigbase.realtime.FakeConnectorFactory
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.respond
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.util.concurrent.CopyOnWriteArrayList

private data class Post(
    val id: String,
    val title: String,
)

private fun postFromRecord(json: JsonObject): Post =
    Post(
        id = json["id"]?.jsonPrimitive?.content ?: "",
        title = json["title"]?.jsonPrimitive?.content ?: "",
    )

private val postsMeta =
    CollectionMeta(
        name = "posts",
        fields = mapOf("title" to FieldMeta(type = FieldType.TEXT)),
    )

private fun mockHttpClient(): HttpClient = HttpClient(MockEngine { respond("{}") })

/** A [TypedRealtime] wired to a fresh [FakeConnectorFactory], plus the [ZigbaseClient] it wraps. */
private fun makeTypedRealtime(
    factory: FakeConnectorFactory = FakeConnectorFactory(),
): Triple<TypedRealtime<Post>, ZigbaseClient, FakeConnectorFactory> {
    val client = ZigbaseClient("http://api.test", httpClient = mockHttpClient())
    client.realtimeConnectorForTesting = factory::connect
    return Triple(TypedRealtime(client, postsMeta, ::postFromRecord), client, factory)
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
    record: JsonObject,
): JsonObject =
    buildJsonObject {
        put("type", "event")
        put("topic", topic)
        put("action", action)
        put("record", record)
    }

/** Polls (real wall-clock wait) until [predicate] is true or [timeoutMs] elapses. */
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

class TypedRealtimeSubscribeTest {
    @Test
    fun `subscribe delivers a typed event with the converted record`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (rt, client, factory) = makeTypedRealtime()
                val events = CopyOnWriteArrayList<TypedRealtimeEvent<Post>>()

                val job = async { rt.subscribe { events += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                val unsubscribe = job.await()

                factory.last.push(
                    eventFrame(
                        "posts",
                        "create",
                        buildJsonObject {
                            put("id", "1")
                            put("title", "Hi")
                        },
                    ),
                )
                awaitTrue { events.isNotEmpty() }

                assertEquals(1, events.size)
                val event = events[0]
                assertEquals("posts", event.topic)
                assertEquals("create", event.action)
                assertEquals(Post(id = "1", title = "Hi"), event.record)

                unsubscribe()
                client.close()
            }
        }

    @Test
    fun `a where Expr compiles into the subscribe frame's filter`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (rt, client, factory) = makeTypedRealtime()
                val where = StringFieldExpr("title").eq("Hi")

                val job = async { rt.subscribe(where = where) { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(
                    listOf(
                        buildJsonObject {
                            put("action", "subscribe")
                            put("topic", "posts")
                            put("filter", where.compile())
                        },
                    ),
                    factory.last.subscribeFrames,
                )
                factory.last.push(ackFrame("posts"))
                job.await()
                client.close()
            }
        }

    @Test
    fun `a plain filter string passes through when no where is given`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (rt, client, factory) = makeTypedRealtime()

                val job = async { rt.subscribe(filter = "title = 'x'") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(
                    listOf(
                        buildJsonObject {
                            put("action", "subscribe")
                            put("topic", "posts")
                            put("filter", "title = 'x'")
                        },
                    ),
                    factory.last.subscribeFrames,
                )
                factory.last.push(ackFrame("posts"))
                job.await()
                client.close()
            }
        }

    @Test
    fun `a delete event's id-only record still converts via fromRecord fallbacks`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (rt, client, factory) = makeTypedRealtime()
                val events = CopyOnWriteArrayList<TypedRealtimeEvent<Post>>()

                val job = async { rt.subscribe { events += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                factory.last.push(eventFrame("posts", "delete", buildJsonObject { put("id", "1") }))
                awaitTrue { events.isNotEmpty() }

                assertEquals("delete", events[0].action)
                assertEquals(Post(id = "1", title = ""), events[0].record)
                client.close()
            }
        }

    @Test
    fun `the returned unsubscribe lambda sends an unsubscribe frame`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (rt, client, factory) = makeTypedRealtime()

                val job = async { rt.subscribe { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                val unsubscribe = job.await()

                unsubscribe()
                awaitTrue { factory.last.unsubscribeFrames.isNotEmpty() }
                client.close()
            }
        }
}

class TypedRealtimeStreamTest {
    @Test
    fun `stream yields typed events mapped from the base stream`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (rt, client, factory) = makeTypedRealtime()
                val got = CopyOnWriteArrayList<TypedRealtimeEvent<Post>>()

                val collectJob = launch { rt.stream().collect { got += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                factory.last.push(
                    eventFrame(
                        "posts",
                        "update",
                        buildJsonObject {
                            put("id", "2")
                            put("title", "Bye")
                        },
                    ),
                )
                awaitTrue { got.isNotEmpty() }

                assertEquals("update", got[0].action)
                assertEquals(Post(id = "2", title = "Bye"), got[0].record)

                collectJob.cancel()
                collectJob.join()
                client.close()
            }
        }

    @Test
    fun `stream tears down (unsubscribes) on take(1) completion`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (rt, client, factory) = makeTypedRealtime()

                val collectJob =
                    async {
                        rt.stream().take(1).toList()
                    }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                factory.last.push(eventFrame("posts", "create", buildJsonObject { put("id", "3") }))

                val results = withTimeout(2_000) { collectJob.await() }
                assertEquals(1, results.size)

                awaitTrue { factory.last.unsubscribeFrames.isNotEmpty() }
                client.close()
            }
        }

    @Test
    fun `a where Expr compiles into the stream's subscribe frame filter`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (rt, client, factory) = makeTypedRealtime()
                val where = StringFieldExpr("title").eq("Hi")

                val collectJob = launch { rt.stream(where = where).collect { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(
                    listOf(
                        buildJsonObject {
                            put("action", "subscribe")
                            put("topic", "posts")
                            put("filter", where.compile())
                        },
                    ),
                    factory.last.subscribeFrames,
                )

                collectJob.cancel()
                collectJob.join()
                client.close()
            }
        }
}

class TypedRealtimeNoCloseTest {
    @Test
    fun `TypedRealtime exposes no close -- the shared RealtimeService owns teardown`() {
        // Compile-level contract: `TypedRealtime` must not declare a `close`
        // member. Reflection asserts none of its OWN declared methods (not
        // inherited `Object` methods like `Object#wait`/etc.) is named
        // `close`, so the shared, multiplexed `RealtimeService` -- torn down
        // only by `ZigbaseClient.close()` -- remains the sole owner of
        // connection teardown, matching `typed.py`'s `TypedRealtime` (which
        // documents the identical omission).
        val declaredCloseMethods = TypedRealtime::class.java.declaredMethods.filter { it.name == "close" }
        assertTrue(declaredCloseMethods.isEmpty())
        assertFalse(TypedRealtime::class.java.methods.any { it.name == "close" && it.declaringClass == TypedRealtime::class.java })
    }
}
