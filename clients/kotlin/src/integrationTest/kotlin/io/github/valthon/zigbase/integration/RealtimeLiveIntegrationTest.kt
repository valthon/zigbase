package io.github.valthon.zigbase.integration

import io.github.valthon.zigbase.RealtimeEvent
import io.github.valthon.zigbase.ZigbaseClient
import io.github.valthon.zigbase.errors.ZigbaseException
import io.github.valthon.zigbase.query.zbFilter
import kotlinx.coroutines.async
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Timeout
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Live-server realtime suite: drives the PUBLIC [ZigbaseClient.realtime] facade -- and, through
 * it, the real production [io.github.valthon.zigbase.realtime.KtorWebSocketConnector] (ktor-CIO
 * WebSocket) -- against a real `zigbase serve` process. This is the first end-to-end exercise of
 * that connector; every other realtime test in this module fakes the transport.
 *
 * A dedicated sibling class (its own server, separate from [LiveIntegrationTest]'s CRUD/auth/file
 * coverage) rather than extra `@Test`s there: a realtime test that leaves a socket open, or a
 * server-side subscription lingering past a test method, must never perturb unrelated CRUD
 * assertions sharing the same server.
 *
 * Every test follows the same full-shape-plus-negative-control discipline as
 * `LiveIntegrationTest`: an assertion that could pass by accident (an event arrived, a subscribe
 * was rejected) is paired with a negative control that would fail if the assertion were vacuous
 * (a different record's update never reaching a record-scoped subscription, a non-matching create
 * never reaching a filtered one, an anonymous socket's rejection carrying the server's actual
 * auth-required text rather than any old exception).
 */
@Timeout(value = 60, unit = TimeUnit.SECONDS)
class RealtimeLiveIntegrationTest {
    companion object {
        private lateinit var server: LaunchedServer
        private val postSeq = AtomicInteger(0)
        private val memberSeq = AtomicInteger(0)

        @JvmStatic
        @BeforeAll
        fun setUpAll() {
            val binary = requireBinaryOrSkip()
            server = startServer(binary)
            createCollection(server.baseUrl, server.superuserToken, postsDefinition("posts"))
            createCollection(server.baseUrl, server.superuserToken, membersDefinition("members"))
        }

        @JvmStatic
        @AfterAll
        fun tearDownAll() {
            if (::server.isInitialized) server.stop()
        }

        private fun adminClient(): ZigbaseClient {
            val client = ZigbaseClient(server.baseUrl)
            client.authStore.save(server.superuserToken, null)
            return client
        }

        private fun nextTitle(): String = "rt-${postSeq.getAndIncrement()}"

        private data class MemberFixture(
            val email: String,
            val password: String,
            val id: String,
        )

        /** Creates a `members` record via the superuser client. Returns its email/password/id. */
        private suspend fun seedMember(password: String): MemberFixture {
            val email = "rtmember${memberSeq.getAndIncrement()}@test.local"
            val id =
                adminClient().use { admin ->
                    admin
                        .collection("members")
                        .create(
                            mapOf(
                                "email" to email,
                                "password" to password,
                                "passwordConfirm" to password,
                                "name" to "RT Member",
                                "emailVisibility" to true,
                            ),
                        ).id
                }
            return MemberFixture(email, password, id)
        }

        /** Suspend-friendly `assertThrows`: runs [block] and returns the thrown [T], or fails if nothing was thrown. */
        private suspend inline fun <reified T : Throwable> assertThrowsSuspend(noinline block: suspend () -> Unit): T {
            try {
                block()
            } catch (e: Throwable) {
                if (e is T) return e
                throw e
            }
            throw AssertionError("Expected ${T::class.simpleName} to be thrown, but nothing was")
        }
    }

    @Test
    fun testSubscribeAckSmoke() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                withTimeout(10_000) { client.realtime.subscribe("posts") { } }
                assertNotNull(client.realtime.clientId, "the server's connect frame should have assigned a clientId")

                // A second subscribe to the SAME (unfiltered) topic is already acked -- it must
                // return promptly, and its callback must be genuinely registered rather than
                // silently dropped: proven below by actually receiving an event through it.
                val events = Channel<RealtimeEvent>(Channel.UNLIMITED)
                withTimeout(10_000) { client.realtime.subscribe("posts") { ev -> events.trySend(ev) } }

                adminClient().use { admin ->
                    admin.collection("posts").create(mapOf("title" to nextTitle(), "views" to 1))
                }
                val event = withTimeout(10_000) { events.receive() }
                assertEquals("create", event.action)
            }
        }

    @Test
    fun testCreateEventCarriesRecord() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                val events = Channel<RealtimeEvent>(Channel.UNLIMITED)
                val unsub = client.realtime.subscribe("posts") { ev -> events.trySend(ev) }
                try {
                    val created =
                        adminClient().use { admin ->
                            admin.collection("posts").create(mapOf("title" to nextTitle(), "views" to 42))
                        }
                    val event = withTimeout(10_000) { events.receive() }
                    assertEquals("create", event.action)
                    assertEquals(created.id, event.record.id)
                    assertEquals(created.getString("title"), event.record.getString("title"))
                    assertEquals(42, event.record.getInt("views"))
                } finally {
                    unsub()
                }
            }
        }

    @Test
    fun testUpdateAndDeleteEventsOnBothTopicsWithNegativeControl() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                adminClient().use { admin ->
                    val target = admin.collection("posts").create(mapOf("title" to nextTitle(), "views" to 1))
                    val other = admin.collection("posts").create(mapOf("title" to nextTitle(), "views" to 1))

                    val collectionEvents = Channel<RealtimeEvent>(Channel.UNLIMITED)
                    val recordEvents = Channel<RealtimeEvent>(Channel.UNLIMITED)
                    val unsubCollection = client.realtime.subscribe("posts") { ev -> collectionEvents.trySend(ev) }
                    val unsubRecord = client.realtime.subscribe("posts/${target.id}") { ev -> recordEvents.trySend(ev) }
                    try {
                        // Negative control FIRST: an update to a DIFFERENT record must reach the
                        // collection topic but must NOT reach the record-scoped subscription.
                        admin.collection("posts").update(other.id, mapOf("title" to "other-updated"))
                        val collectionOtherEvent = withTimeout(10_000) { collectionEvents.receive() }
                        assertEquals("update", collectionOtherEvent.action)
                        assertEquals(other.id, collectionOtherEvent.record.id)
                        assertNull(
                            withTimeoutOrNull(1_500) { recordEvents.receive() },
                            "record-topic subscription must not receive an update for a different record",
                        )

                        admin.collection("posts").update(target.id, mapOf("title" to "target-updated"))
                        val collectionUpdate = withTimeout(10_000) { collectionEvents.receive() }
                        assertEquals("update", collectionUpdate.action)
                        assertEquals(target.id, collectionUpdate.record.id)
                        assertEquals("target-updated", collectionUpdate.record.getString("title"))
                        val recordUpdate = withTimeout(10_000) { recordEvents.receive() }
                        assertEquals("update", recordUpdate.action)
                        assertEquals(target.id, recordUpdate.record.id)
                        assertEquals("target-updated", recordUpdate.record.getString("title"))

                        admin.collection("posts").delete(target.id)
                        val collectionDelete = withTimeout(10_000) { collectionEvents.receive() }
                        assertEquals("delete", collectionDelete.action)
                        assertEquals(setOf("id"), collectionDelete.record.raw.keys, "delete event must be id-only")
                        assertEquals(target.id, collectionDelete.record.id)
                        val recordDelete = withTimeout(10_000) { recordEvents.receive() }
                        assertEquals("delete", recordDelete.action)
                        assertEquals(setOf("id"), recordDelete.record.raw.keys, "delete event must be id-only")
                        assertEquals(target.id, recordDelete.record.id)
                    } finally {
                        unsubCollection()
                        unsubRecord()
                    }
                }
            }
        }

    @Test
    fun testMembersSubscribeRequiresAuthThenDeliversSelfScopedEvent() =
        runBlocking {
            val target = seedMember("rt-member-pass-1")
            val other = seedMember("rt-member-pass-2")

            // `members`' viewRule (`@request.auth.id = id`) is neither blank nor `@public`, so an
            // anonymous socket is rejected at SUBSCRIBE time, before per-record delivery is even
            // considered -- assert the server's actual rejection text, not just "it threw".
            ZigbaseClient(server.baseUrl).use { anon ->
                val ex = assertThrowsSuspend<ZigbaseException> { anon.realtime.subscribe("members") { } }
                assertTrue(
                    ex.message.contains("authentication required"),
                    "expected an auth-required rejection, got: ${ex.message}",
                )
            }

            adminClient().use { admin ->
                ZigbaseClient(server.baseUrl).use { client ->
                    client.collection("members").authWithPassword(target.email, target.password)

                    val events = Channel<RealtimeEvent>(Channel.UNLIMITED)
                    val unsub = client.realtime.subscribe("members") { ev -> events.trySend(ev) }
                    try {
                        // Negative control: a DIFFERENT member's update must not reach this
                        // self-scoped subscription (viewRule re-applied per record on delivery).
                        admin.collection("members").update(other.id, mapOf("name" to "Other Updated"))
                        assertNull(
                            withTimeoutOrNull(1_500) { events.receive() },
                            "must not receive an event for a different member",
                        )

                        admin.collection("members").update(target.id, mapOf("name" to "Target Updated"))
                        val event = withTimeout(10_000) { events.receive() }
                        assertEquals("update", event.action)
                        assertEquals(target.id, event.record.id)
                        assertEquals("Target Updated", event.record.getString("name"))
                    } finally {
                        unsub()
                    }
                }
            }
        }

    @Test
    fun testZbFilterFilteredDeliveryMatchingFirst() =
        runBlocking {
            val tag = nextTitle()
            val filter = zbFilter("views > {:n}", mapOf("n" to 100))

            ZigbaseClient(server.baseUrl).use { client ->
                adminClient().use { admin ->
                    val events = Channel<RealtimeEvent>(Channel.UNLIMITED)
                    val unsub = client.realtime.subscribe("posts", filter = filter) { ev -> events.trySend(ev) }
                    try {
                        // Non-matching FIRST, confirmed undelivered, THEN matching -- so "the
                        // first event received is the matching one" is a real, ordering-backed
                        // assertion rather than just "some event arrived eventually".
                        val nonMatching = admin.collection("posts").create(mapOf("title" to "$tag-low", "views" to 1))
                        assertNull(
                            withTimeoutOrNull(1_500) { events.receive() },
                            "a non-matching create must not be delivered to a filtered subscription",
                        )

                        val matching = admin.collection("posts").create(mapOf("title" to "$tag-high", "views" to 500))
                        val event = withTimeout(10_000) { events.receive() }
                        assertEquals("create", event.action)
                        assertEquals(matching.id, event.record.id)
                        assertEquals("$tag-high", event.record.getString("title"))
                        assertNotEquals(nonMatching.id, event.record.id)
                    } finally {
                        unsub()
                    }
                }
            }
        }

    @Test
    fun testStreamTakeOneCleanTeardown() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                adminClient().use { admin ->
                    // First, prove `unsubscribe()` -- the exact mechanism `stream()`'s
                    // `awaitClose` invokes on cancellation -- genuinely stops delivery: subscribe
                    // manually, observe one event, unsubscribe, then confirm a later create is
                    // NOT delivered.
                    val manualEvents = Channel<RealtimeEvent>(Channel.UNLIMITED)
                    val unsub = client.realtime.subscribe("posts") { ev -> manualEvents.trySend(ev) }
                    val first = admin.collection("posts").create(mapOf("title" to nextTitle(), "views" to 1))
                    val firstEvent = withTimeout(10_000) { manualEvents.receive() }
                    assertEquals(first.id, firstEvent.record.id)
                    unsub()
                    admin.collection("posts").create(mapOf("title" to nextTitle(), "views" to 1))
                    assertNull(
                        withTimeoutOrNull(1_500) { manualEvents.receive() },
                        "unsubscribe must stop further delivery to the torn-down callback",
                    )

                    // Now the `stream().take(1)` contract itself: exactly one event, then clean
                    // completion -- no hang, no leftover delivery. The connection is already open
                    // (warmed up above), so only a fresh subscribe+ack round trip over the live
                    // socket -- not a new connect -- races the create below; a short delay gives
                    // that round trip room to land first (same pattern as the Python port's
                    // `test_stream_yields_one_event_then_breaks_cleanly`).
                    val collector =
                        async {
                            client.realtime
                                .stream("posts")
                                .take(1)
                                .toList()
                        }
                    delay(300)
                    val created = admin.collection("posts").create(mapOf("title" to nextTitle(), "views" to 1))
                    val collected = withTimeout(10_000) { collector.await() }
                    assertEquals(1, collected.size)
                    assertEquals("create", collected[0].action)
                    assertEquals(created.id, collected[0].record.id)
                }
            }
        }
}
