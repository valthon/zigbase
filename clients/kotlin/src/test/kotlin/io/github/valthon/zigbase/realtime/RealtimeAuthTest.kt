package io.github.valthon.zigbase.realtime

/*
 * Tests for [RealtimeService]'s auth lifecycle -- port of the auth-gated
 * on-open resubscribe and re-auth-on-token-change coverage in
 * `clients/python/tests/test_realtime_auth.py`, adapted for real
 * multi-threaded concurrency the same way `RealtimeServiceTest.kt` is (see
 * that file's header comment for the `awaitTrue` rationale in place of
 * Python's `_pump()`).
 *
 * One deliberate deviation from the TS/Dart ports, matching the Python port:
 * an auth failure is always surfaced via `onError` here (never silently
 * swallowed).
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

private fun JsonObject.stringOrNull(key: String): String? = (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

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

private fun makeService(
    factory: FakeConnectorFactory = FakeConnectorFactory(),
    authStore: MemoryAuthStore = MemoryAuthStore(),
    onError: (String) -> Unit = {},
): Triple<RealtimeService, FakeConnectorFactory, MemoryAuthStore> =
    Triple(RealtimeService("http://api.test", authStore, factory::connect, onError), factory, authStore)

class RealtimeAuthOnOpenTest {
    @Test
    fun `auth frame precedes subscribe and gates it on ok`() =
        runTest {
            withContext(Dispatchers.Default) {
                val store = MemoryAuthStore()
                store.save("tok-1", null)
                val (service, factory, _) = makeService(authStore = store)

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }

                assertEquals(listOf(authFrame("tok-1")), factory.last.sent)
                assertTrue(factory.last.subscribeFrames.isEmpty())

                factory.last.push(authReplyFrame("ok"))
                awaitTrue { factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), factory.last.subscribeFrames)

                factory.last.push(ackFrame("posts"))
                job.await()
                service.close()
            }
        }

    @Test
    fun `anonymous open sends no auth frame`() =
        runTest {
            withContext(Dispatchers.Default) {
                val (service, factory, _) = makeService()

                val job = async { service.subscribe("public") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }

                assertEquals(listOf(subscribeFrame("public")), factory.last.sent)

                factory.last.push(ackFrame("public"))
                job.await()
                service.close()
            }
        }
}

class RealtimeAuthErrorOnOpenTest {
    @Test
    fun `auth error on open calls onError and still resubscribes`() =
        runTest {
            withContext(Dispatchers.Default) {
                val errors = mutableListOf<String>()
                val store = MemoryAuthStore()
                store.save("tok-1", null)
                val (service, factory, _) = makeService(authStore = store, onError = { errors += it })

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }
                assertEquals(listOf(authFrame("tok-1")), factory.last.sent)

                factory.last.push(authReplyFrame("error"))
                awaitTrue { factory.last.subscribeFrames.isNotEmpty() }

                assertEquals(1, errors.size)
                // Public subs must still work even when auth fails.
                assertEquals(listOf(subscribeFrame("posts")), factory.last.subscribeFrames)

                factory.last.push(ackFrame("posts"))
                withTimeout(1_000) { job.await() }
                service.close()
            }
        }
}

class RealtimeReauthOnTokenChangeTest {
    @Test
    fun `token change while open sends new auth frame with event token verbatim`() =
        runTest {
            withContext(Dispatchers.Default) {
                val store = MemoryAuthStore()
                val (service, factory, _) = makeService(authStore = store)

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), factory.last.sent)
                factory.last.push(ackFrame("posts"))
                job.await()

                store.save("tok-1", null)
                awaitTrue { factory.last.sent.last() == authFrame("tok-1") }
                service.close()
            }
        }

    @Test
    fun `logout sends empty token frame and existing subs keep delivering`() =
        runTest {
            withContext(Dispatchers.Default) {
                val store = MemoryAuthStore()
                store.save("tok-1", null)
                val events = mutableListOf<RealtimeEvent>()
                val (service, factory, _) = makeService(authStore = store)

                val job = async { service.subscribe("posts") { events += it } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }
                factory.last.push(authReplyFrame("ok"))
                awaitTrue { factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                store.clear()
                awaitTrue { factory.last.sent.last() == authFrame("") }

                // The server rejects the empty token; existing subscriptions
                // must keep delivering regardless.
                factory.last.push(authReplyFrame("error"))
                factory.last.push(eventFrame("posts", "update", "p1"))
                awaitTrue { events.size == 1 }
                assertEquals("p1", events[0].record.id)
                service.close()
            }
        }

    @Test
    fun `rapid reauth before any response settles cleanly and strands no waiter`() =
        runTest {
            withContext(Dispatchers.Default) {
                val store = MemoryAuthStore()
                store.save("tok-1", null)
                val (service, factory, _) = makeService(authStore = store)

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }
                assertEquals(listOf(authFrame("tok-1")), factory.last.sent)

                // onOpen sent auth tok-1; before its response, the token
                // changes twice. Each re-auth is scheduled on a separate
                // `scope.launch`ed coroutine (real `Dispatchers.Default`
                // concurrency, no cross-launch ordering guarantee) -- so
                // whether tok-1's and/or tok-2's frames actually reach the
                // wire before tok-3's is scheduling-dependent (the
                // sequence-based staleness check in `sendAuthFrame` may
                // drop either or both of them if tok-3's send wins the race
                // to the lock first). What's NOT scheduling-dependent: since
                // tok-3 carries the highest sequence number of the three,
                // its send is never itself dropped, and nothing sent after
                // it can have a higher sequence number -- so it is always
                // both actually sent AND the LAST auth frame to reach the
                // wire, regardless of how the three launches interleave.
                store.save("tok-2", null)
                store.save("tok-3", null)
                awaitTrue {
                    factory.last.sent.lastOrNull { it.stringOrNull("action") == "auth" } == authFrame("tok-3")
                }

                // A single response settles the shared, reused deferred so
                // the gated subscribe flushes -- superseded waiters must not
                // hang.
                factory.last.push(authReplyFrame("ok"))
                awaitTrue { factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), factory.last.subscribeFrames)

                // Late, superseded responses arriving after the deferred was
                // already detached and settled must not raise or
                // double-settle anything.
                factory.last.push(authReplyFrame("ok"))
                factory.last.push(authReplyFrame("error"))

                factory.last.push(ackFrame("posts"))
                // Fails (times out) if the subscribe gate hung on a
                // superseded auth.
                withTimeout(1_000) { job.await() }
                service.close()
            }
        }
}

class RealtimeAuthSendOrderingTest {
    @Test
    fun `a stale reauth send never reaches the wire after a newer one already has`() =
        runTest {
            withContext(Dispatchers.Default) {
                // Regression guard: two re-auth sends (login then logout, in
                // that order) are each scheduled on their own
                // `scope.launch`ed coroutine -- real `Dispatchers.Default`
                // concurrency, with NO guarantee the older one's frame
                // reaches the wire before the newer one's. Forces the
                // reorder deterministically (a real scheduler might not
                // reproduce it every run): parks the OLDER (login) send at
                // `testHookBeforeAuthSend` while the NEWER (logout) send
                // runs to completion first, then releases the parked one and
                // asserts its now-stale frame never reaches the wire -- the
                // wire must end on (and only ever show) the newer, empty-
                // token logout, never a stale re-appearance of the old
                // token after it.
                val store = MemoryAuthStore()
                val (service, factory, _) = makeService(authStore = store)

                // Connect anonymously first, so the race below is purely
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

                store.save("tok-1", null) // login: parks at the hook
                withTimeout(1_000) { loginEntered.await() }

                store.clear() // logout: not gated -- runs to completion first
                awaitTrue { factory.last.sent.any { it == authFrame("") } }

                // Release the parked (now-stale) login send.
                releaseLogin.complete(Unit)
                delay(50) // let it run to completion (dropped as stale)

                val authFrames = factory.last.sent.filter { it.stringOrNull("action") == "auth" }
                assertEquals(listOf(authFrame("")), authFrames)
                service.close()
            }
        }
}

class RealtimeSendAuthFrameSendFailureTest {
    @Test
    fun `auth send failure fails the gate and calls onError but resubscribe still happens`() =
        runTest {
            withContext(Dispatchers.Default) {
                val errors = mutableListOf<String>()
                val store = MemoryAuthStore()
                store.save("tok-1", null)
                val factory = FakeConnectorFactory()
                factory.nextSendException = RuntimeException("send boom")
                val (service, _, _) = makeService(factory, authStore = store, onError = { errors += it })

                val job = async { service.subscribe("posts") { } }
                awaitTrue { errors.isNotEmpty() }

                assertTrue(errors.any { "send boom" in it })
                // The one-shot send failure only hit the auth frame -- the
                // resubscribe that follows in onOpen still goes out normally.
                awaitTrue { factory.last.subscribeFrames.isNotEmpty() }
                assertEquals(listOf(subscribeFrame("posts")), factory.last.subscribeFrames)

                factory.last.push(ackFrame("posts"))
                withTimeout(1_000) { job.await() }
                service.close()
            }
        }
}

class RealtimeAuthCloseDetachesListenerTest {
    @Test
    fun `auth store save after close sends nothing`() =
        runTest {
            withContext(Dispatchers.Default) {
                val store = MemoryAuthStore()
                store.save("tok-1", null)
                val (service, factory, _) = makeService(authStore = store)

                val job = async { service.subscribe("posts") { } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }
                factory.last.push(authReplyFrame("ok"))
                awaitTrue { factory.last.subscribeFrames.isNotEmpty() }
                factory.last.push(ackFrame("posts"))
                job.await()

                withTimeout(1_000) { service.close() }
                val sentBefore = factory.last.sent.size

                store.save("tok-2", null)
                delay(50)
                assertEquals(sentBefore, factory.last.sent.size)
            }
        }
}

class RealtimeConnectionDropDuringAuthGateTest {
    @Test
    fun `drop before auth reply unblocks the gate without close`() =
        runTest {
            withContext(Dispatchers.Default) {
                // Regression guard (the SP2 Critical, ported as prevention):
                // an unexpected connection drop (not a user close()) while
                // the on-open auth gate is still awaiting its reply must
                // settle the gate itself -- the receive loop's `finally`
                // must fail the auth deferred alongside its existing state
                // reset. Before the fix, nothing but close() ever settled
                // it, so this would hang forever with no external close()
                // call.
                val errors = mutableListOf<String>()
                val store = MemoryAuthStore()
                store.save("tok-1", null)
                val (service, factory, _) = makeService(authStore = store, onError = { errors += it })

                val job = async { runCatching { service.subscribe("posts") { } } }
                awaitTrue { factory.connections.isNotEmpty() && factory.last.sent.isNotEmpty() }
                assertEquals(listOf(authFrame("tok-1")), factory.last.sent)

                factory.last.serverClose()
                // No close() call here -- only the drop itself must unblock
                // the gate.
                awaitTrue { errors.isNotEmpty() }

                assertEquals(1, errors.size)
                // The subscribe's OWN pending future stays unresolved here:
                // Task 4's reconnect IS scheduled (the drop leaves a live
                // subscription behind), but its default real-clock backoff
                // (250ms, no delayFn override in this file) hasn't elapsed
                // within this short wait -- so from this test's point of
                // view nothing has resent the frame yet. close() below
                // settles it regardless, whether the reconnect already
                // landed or is still asleep in its backoff.
                delay(20)
                assertFalse(job.isCompleted)

                withTimeout(1_000) { service.close() }
                withTimeout(1_000) { job.await() }.exceptionAs<ZigbaseException>()
            }
        }
}
