package io.github.valthon.zigbase.internal

import io.github.valthon.zigbase.FileArg
import io.github.valthon.zigbase.auth.MemoryAuthStore
import io.github.valthon.zigbase.errors.ZigbaseException
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockEngineConfig
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.OutgoingContent
import io.ktor.http.headersOf
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.io.IOException

/**
 * Tests for [RequestSpec]/[Transport] -- one test per numbered rule in the
 * task-6 brief's behavior contract, mirroring
 * `clients/python/tests/test_transport.py`.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class TransportTest {
    /** Runs [block] and returns the thrown [T], or fails if nothing was thrown. Suspend-friendly [assertThrows]. */
    private suspend inline fun <reified T : Throwable> assertFailsWithSuspend(noinline block: suspend () -> Unit): T {
        try {
            block()
        } catch (e: Throwable) {
            if (e is T) return e
            throw e
        }
        throw AssertionError("Expected ${T::class.simpleName} to be thrown, but nothing was")
    }

    private fun makeTransport(
        authStore: MemoryAuthStore = MemoryAuthStore(),
        authCollection: String? = null,
        autoRefresh: Boolean = false,
        accountId: String? = null,
        lang: String? = null,
        maxRetries: Int = 3,
        delayFn: suspend (Long) -> Unit = { },
        handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData,
    ): Transport {
        val engine = MockEngine(handler)
        return Transport(
            "http://api.test",
            authStore,
            authCollection = authCollection,
            autoRefresh = autoRefresh,
            accountId = accountId,
            lang = lang,
            maxRetries = maxRetries,
            httpClient = HttpClient(engine),
            delayFn = delayFn,
        )
    }

    // --- RequestSpec / encodePathSegment ------------------------------------

    @Test
    fun `encodePathSegment escapes slash and space`() {
        assertEquals("a%2Fb%20c", encodePathSegment("a/b c"))
    }

    @Test
    fun `encodePathSegment leaves plain text alone`() {
        assertEquals("plain", encodePathSegment("plain"))
    }

    @Test
    fun `encodePathSegment escapes unicode as utf-8 byte sequences`() {
        assertEquals("caf%C3%A9", encodePathSegment("café"))
    }

    // --- ensureObjectBody / requireStringField -------------------------------

    @Test
    fun `ensureObjectBody passes through a JsonObject`() {
        val body = buildJsonObject { put("a", 1) }
        assertEquals(body, ensureObjectBody(body, "x"))
    }

    @Test
    fun `ensureObjectBody raises status 0 on a non-object element`() {
        val ex = assertThrows(ZigbaseException::class.java) { ensureObjectBody(JsonPrimitive("str"), "get_one") }
        assertEquals(0, ex.status)
        assertTrue(ex.message.contains("get_one"))
    }

    @Test
    fun `ensureObjectBody raises status 0 on a null element`() {
        val ex = assertThrows(ZigbaseException::class.java) { ensureObjectBody(null, "get_one") }
        assertEquals(0, ex.status)
    }

    @Test
    fun `requireStringField returns the string`() {
        assertEquals("tok1", requireStringField(buildJsonObject { put("token", "tok1") }, "token", "x"))
    }

    @Test
    fun `requireStringField accepts an empty string`() {
        assertEquals("", requireStringField(buildJsonObject { put("token", "") }, "token", "x"))
    }

    @Test
    fun `requireStringField raises status 0 when the key is missing`() {
        val ex = assertThrows(ZigbaseException::class.java) { requireStringField(buildJsonObject { }, "token", "get_one") }
        assertEquals(0, ex.status)
        assertTrue(ex.message.contains("token"))
    }

    @Test
    fun `requireStringField raises status 0 when the value is not a string`() {
        val ex =
            assertThrows(ZigbaseException::class.java) {
                requireStringField(buildJsonObject { put("token", 1) }, "token", "get_one")
            }
        assertEquals(0, ex.status)
    }

    // --- Rule 1: header assembly ---------------------------------------------

    @Test
    fun `header assembly sets authorization lang and account id`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("tok.tok.tok", null)
            var seen: HttpRequestData? = null
            val transport =
                makeTransport(authStore = store, accountId = "acct-1", lang = "fr") { request ->
                    seen = request
                    respond("""{"ok":true}""", HttpStatusCode.OK, headersOf(HttpHeaders.ContentType, listOf("application/json")))
                }
            transport.request(RequestSpec(HttpMethod.Get, "/api/x"))
            val req = seen!!

            assertEquals("Bearer tok.tok.tok", req.headers[HttpHeaders.Authorization])
            assertEquals("fr", req.headers[HttpHeaders.AcceptLanguage])
            assertEquals("acct-1", req.headers["X-Account-Id"])
        }

    @Test
    fun `header assembly skipAuth omits authorization`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("tok.tok.tok", null)
            var seen: HttpRequestData? = null
            val transport =
                makeTransport(authStore = store) { request ->
                    seen = request
                    respond("""{"ok":true}""")
                }
            transport.request(RequestSpec(HttpMethod.Get, "/api/x", skipAuth = true))

            assertNull(seen!!.headers[HttpHeaders.Authorization])
        }

    @Test
    fun `header assembly no token omits authorization`() =
        runTest {
            var seen: HttpRequestData? = null
            val transport =
                makeTransport { request ->
                    seen = request
                    respond("""{"ok":true}""")
                }
            transport.request(RequestSpec(HttpMethod.Get, "/api/x"))

            assertNull(seen!!.headers[HttpHeaders.Authorization])
        }

    @Test
    fun `header assembly spec X-Account-Id wins over configured account id`() =
        runTest {
            var seen: HttpRequestData? = null
            val transport =
                makeTransport(accountId = "configured-acct") { request ->
                    seen = request
                    respond("""{"ok":true}""")
                }
            transport.request(RequestSpec(HttpMethod.Get, "/api/x", headers = mapOf("X-Account-Id" to "explicit-acct")))

            assertEquals("explicit-acct", seen!!.headers["X-Account-Id"])
        }

    @Test
    fun `header assembly custom headers pass through`() =
        runTest {
            var seen: HttpRequestData? = null
            val transport =
                makeTransport { request ->
                    seen = request
                    respond("""{"ok":true}""")
                }
            transport.request(RequestSpec(HttpMethod.Get, "/api/x", headers = mapOf("X-Custom" to "value")))

            assertEquals("value", seen!!.headers["X-Custom"])
        }

    @Test
    fun `header assembly authorization and lang overwrite spec headers`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("tok.tok.tok", null)
            var seen: HttpRequestData? = null
            val transport =
                makeTransport(authStore = store, lang = "fr") { request ->
                    seen = request
                    respond("""{"ok":true}""")
                }
            transport.request(
                RequestSpec(
                    HttpMethod.Get,
                    "/api/x",
                    headers = mapOf("Authorization" to "Bearer stale-caller-supplied", "Accept-Language" to "de"),
                ),
            )
            val req = seen!!

            assertEquals("Bearer tok.tok.tok", req.headers[HttpHeaders.Authorization])
            assertEquals("fr", req.headers[HttpHeaders.AcceptLanguage])
        }

    // --- Rule 2: 2xx decoding --------------------------------------------------

    @Test
    fun `204 returns null`() =
        runTest {
            val transport = makeTransport { respond("", HttpStatusCode.NoContent) }
            assertNull(transport.request(RequestSpec(HttpMethod.Delete, "/api/x")))
        }

    @Test
    fun `200 empty body returns null`() =
        runTest {
            val transport = makeTransport { respond("", HttpStatusCode.OK) }
            assertNull(transport.request(RequestSpec(HttpMethod.Get, "/api/x")))
        }

    @Test
    fun `200 json body parses`() =
        runTest {
            val transport = makeTransport { respond("""{"page":2,"items":[]}""", HttpStatusCode.OK) }
            val out = transport.request(RequestSpec(HttpMethod.Get, "/api/x"))
            assertEquals(2L, out!!.jsonObject["page"]!!.jsonPrimitive.long)
        }

    // --- Rule 3: non-2xx raises --------------------------------------------------

    @Test
    fun `non-2xx raises ZigbaseException`() =
        runTest {
            val transport = makeTransport { respond("""{"message":"Nope.","data":{}}""", HttpStatusCode.Forbidden) }
            val ex = assertFailsWithSuspend<ZigbaseException> { transport.request(RequestSpec(HttpMethod.Get, "/api/x")) }
            assertEquals(403, ex.status)
            assertEquals("Nope.", ex.message)
            assertTrue(ex.url.endsWith("/api/x"))
        }

    // --- Rule 4: 429 backoff -------------------------------------------------------

    @Test
    fun `429 retry-after header honored verbatim`() =
        runTest {
            val delays = mutableListOf<Long>()
            var calls = 0
            val transport =
                makeTransport(delayFn = { delays.add(it) }) {
                    calls += 1
                    if (calls == 1) {
                        respond("""{"message":"slow"}""", HttpStatusCode.TooManyRequests, headersOf(HttpHeaders.RetryAfter, "5"))
                    } else {
                        respond("""{"ok":true}""")
                    }
                }
            transport.request(RequestSpec(HttpMethod.Get, "/api/x"))
            assertEquals(listOf(5000L), delays)
        }

    @Test
    fun `429 exponential backoff when no retry-after`() =
        runTest {
            val delays = mutableListOf<Long>()
            var calls = 0
            val transport =
                makeTransport(maxRetries = 5, delayFn = { delays.add(it) }) {
                    calls += 1
                    if (calls <= 3) {
                        respond("""{"message":"slow"}""", HttpStatusCode.TooManyRequests)
                    } else {
                        respond("""{"ok":true}""")
                    }
                }
            transport.request(RequestSpec(HttpMethod.Get, "/api/x"))
            assertEquals(listOf(200L, 400L, 800L), delays)
        }

    @Test
    fun `429 backoff capped at 30 seconds`() =
        runTest {
            val delays = mutableListOf<Long>()
            var calls = 0
            val transport =
                makeTransport(maxRetries = 20, delayFn = { delays.add(it) }) {
                    calls += 1
                    if (calls <= 20) {
                        respond("""{"message":"slow"}""", HttpStatusCode.TooManyRequests)
                    } else {
                        respond("""{"ok":true}""")
                    }
                }
            transport.request(RequestSpec(HttpMethod.Get, "/api/x"))
            assertTrue(delays.max() <= 30_000L)
            assertTrue(delays.contains(30_000L))
        }

    @Test
    fun `429 retried up to maxRetries then raises`() =
        runTest {
            val delays = mutableListOf<Long>()
            var calls = 0
            val transport =
                makeTransport(maxRetries = 3, delayFn = { delays.add(it) }) {
                    calls += 1
                    respond("""{"message":"slow"}""", HttpStatusCode.TooManyRequests, headersOf(HttpHeaders.RetryAfter, "0"))
                }
            val ex = assertFailsWithSuspend<ZigbaseException> { transport.request(RequestSpec(HttpMethod.Get, "/api/x")) }
            assertEquals(429, ex.status)
            assertEquals(4, calls)
            assertEquals(3, delays.size)
        }

    @Test
    fun `429 retried for PATCH`() =
        runTest {
            val delays = mutableListOf<Long>()
            var calls = 0
            val transport =
                makeTransport(maxRetries = 3, delayFn = { delays.add(it) }) {
                    calls += 1
                    if (calls == 1) {
                        respond("""{"message":"slow"}""", HttpStatusCode.TooManyRequests, headersOf(HttpHeaders.RetryAfter, "0"))
                    } else {
                        respond("""{"ok":true}""")
                    }
                }
            val out = transport.request(RequestSpec(HttpMethod.Patch, "/api/x", body = mapOf("a" to 1)))
            assertTrue(out!!.jsonObject["ok"]!!.jsonPrimitive.boolean)
            assertEquals(2, calls)
            assertEquals(listOf(200L), delays)
        }

    @Test
    fun `429 retried for every method`() =
        runTest {
            val methods = listOf(HttpMethod.Get, HttpMethod.Head, HttpMethod.Delete, HttpMethod.Patch, HttpMethod.Post, HttpMethod.Put)
            for (method in methods) {
                var calls = 0
                val transport =
                    makeTransport(maxRetries = 1, delayFn = { }) {
                        calls += 1
                        if (calls == 1) {
                            respond("""{"message":"slow"}""", HttpStatusCode.TooManyRequests, headersOf(HttpHeaders.RetryAfter, "0"))
                        } else if (method == HttpMethod.Get) {
                            respond("""{"ok":true}""")
                        } else {
                            respond("", HttpStatusCode.NoContent)
                        }
                    }
                transport.request(RequestSpec(method, "/api/x"))
                assertEquals(2, calls, "method $method should retry once")
            }
        }

    // --- Rule 5: single-flight 401 refresh -----------------------------------------

    @Test
    fun `401 without autoRefresh propagates`() =
        runTest {
            var calls = 0
            val store = MemoryAuthStore()
            store.save("tok", null)
            val transport =
                makeTransport(authStore = store, autoRefresh = false, authCollection = "users") {
                    calls += 1
                    respond("""{"message":"expired"}""", HttpStatusCode.Unauthorized)
                }
            val ex = assertFailsWithSuspend<ZigbaseException> { transport.request(RequestSpec(HttpMethod.Get, "/api/x")) }
            assertEquals(401, ex.status)
            assertEquals(1, calls)
        }

    @Test
    fun `401 without authCollection propagates`() =
        runTest {
            var calls = 0
            val store = MemoryAuthStore()
            store.save("tok", null)
            val transport =
                makeTransport(authStore = store, autoRefresh = true, authCollection = null) {
                    calls += 1
                    respond("""{"message":"expired"}""", HttpStatusCode.Unauthorized)
                }
            assertFailsWithSuspend<ZigbaseException> { transport.request(RequestSpec(HttpMethod.Get, "/api/x")) }
            assertEquals(1, calls)
        }

    @Test
    fun `401 without token propagates`() =
        runTest {
            var calls = 0
            val transport =
                makeTransport(autoRefresh = true, authCollection = "users") {
                    calls += 1
                    respond("""{"message":"expired"}""", HttpStatusCode.Unauthorized)
                }
            assertFailsWithSuspend<ZigbaseException> { transport.request(RequestSpec(HttpMethod.Get, "/api/x")) }
            assertEquals(1, calls)
        }

    @Test
    fun `401 marked isRefresh propagates without recursion`() =
        runTest {
            var calls = 0
            val store = MemoryAuthStore()
            store.save("tok", null)
            val transport =
                makeTransport(authStore = store, autoRefresh = true, authCollection = "users") {
                    calls += 1
                    respond("""{"message":"expired"}""", HttpStatusCode.Unauthorized)
                }
            assertFailsWithSuspend<ZigbaseException> {
                transport.request(RequestSpec(HttpMethod.Post, "/api/collections/users/auth-refresh", isRefresh = true))
            }
            assertEquals(1, calls)
        }

    @Test
    fun `401 one-shot refresh then retries`() =
        runTest {
            val calls = mutableListOf<String>()
            val store = MemoryAuthStore()
            store.save("old.tok", null)
            val transport =
                makeTransport(authStore = store, autoRefresh = true, authCollection = "users") { request ->
                    if (request.url.encodedPath.endsWith("auth-refresh")) {
                        calls.add("refresh")
                        respond("""{"token":"new.tok","record":{"id":"u1"}}""")
                    } else {
                        calls.add("x")
                        if (calls.count { it == "x" } == 1) {
                            respond("""{"message":"expired"}""", HttpStatusCode.Unauthorized)
                        } else {
                            respond("""{"ok":true}""")
                        }
                    }
                }
            val out = transport.request(RequestSpec(HttpMethod.Get, "/api/x"))
            assertTrue(out!!.jsonObject["ok"]!!.jsonPrimitive.boolean)
            assertEquals(listOf("x", "refresh", "x"), calls)
            assertEquals("new.tok", store.token)
        }

    @Test
    fun `401 refresh endpoint itself 401s propagates the original`() =
        runTest {
            var xCalls = 0
            var refreshCalls = 0
            val store = MemoryAuthStore()
            store.save("tok", null)
            val transport =
                makeTransport(authStore = store, autoRefresh = true, authCollection = "users") { request ->
                    if (request.url.encodedPath.endsWith("auth-refresh")) {
                        refreshCalls += 1
                        respond("""{"message":"refresh expired"}""", HttpStatusCode.Unauthorized)
                    } else {
                        xCalls += 1
                        respond("""{"message":"original expired"}""", HttpStatusCode.Unauthorized)
                    }
                }
            val ex = assertFailsWithSuspend<ZigbaseException> { transport.request(RequestSpec(HttpMethod.Get, "/api/x")) }
            assertEquals(401, ex.status)
            assertEquals("original expired", ex.message)
            assertEquals(1, refreshCalls)
            assertEquals(1, xCalls)
        }

    @Test
    fun `401 refresh failure propagates the original 401`() =
        runTest {
            var xCalls = 0
            val store = MemoryAuthStore()
            store.save("tok", null)
            val transport =
                makeTransport(authStore = store, autoRefresh = true, authCollection = "users") { request ->
                    if (request.url.encodedPath.endsWith("auth-refresh")) {
                        respond("""{"message":"bad refresh request"}""", HttpStatusCode.BadRequest)
                    } else {
                        xCalls += 1
                        respond("""{"message":"original expired"}""", HttpStatusCode.Unauthorized)
                    }
                }
            val ex = assertFailsWithSuspend<ZigbaseException> { transport.request(RequestSpec(HttpMethod.Get, "/api/x")) }
            assertEquals(401, ex.status)
            assertEquals("original expired", ex.message)
            assertEquals(1, xCalls)
        }

    @Test
    fun `401 refresh empty body propagates original 401 and preserves the store`() =
        runTest {
            var xCalls = 0
            var refreshCalls = 0
            val store = MemoryAuthStore()
            val record = buildJsonObject { put("id", "u1") }
            store.save("tok", record)
            val transport =
                makeTransport(authStore = store, autoRefresh = true, authCollection = "users") { request ->
                    if (request.url.encodedPath.endsWith("auth-refresh")) {
                        refreshCalls += 1
                        respond("", HttpStatusCode.NoContent)
                    } else {
                        xCalls += 1
                        respond("""{"message":"original expired"}""", HttpStatusCode.Unauthorized)
                    }
                }
            val ex = assertFailsWithSuspend<ZigbaseException> { transport.request(RequestSpec(HttpMethod.Get, "/api/x")) }
            assertEquals(401, ex.status)
            assertEquals("original expired", ex.message)
            assertEquals(1, refreshCalls)
            assertEquals(1, xCalls)
            assertEquals("tok", store.token)
            assertEquals(record, store.record)
        }

    @Test
    fun `401 refresh body missing token clears the store`() =
        runTest {
            val calls = mutableListOf<String>()
            val store = MemoryAuthStore()
            store.save("old.tok", buildJsonObject { put("id", "u1") })
            val transport =
                makeTransport(authStore = store, autoRefresh = true, authCollection = "users") { request ->
                    if (request.url.encodedPath.endsWith("auth-refresh")) {
                        calls.add("refresh")
                        respond("""{"unexpected":"shape"}""")
                    } else {
                        calls.add("x")
                        if (calls.count { it == "x" } == 1) {
                            respond("""{"message":"expired"}""", HttpStatusCode.Unauthorized)
                        } else {
                            respond("""{"ok":true}""")
                        }
                    }
                }
            val out = transport.request(RequestSpec(HttpMethod.Get, "/api/x"))
            assertTrue(out!!.jsonObject["ok"]!!.jsonPrimitive.boolean)
            assertEquals(listOf("x", "refresh", "x"), calls)
            assertNull(store.token)
            assertNull(store.record)
        }

    @Test
    fun `two concurrent 401s trigger exactly one refresh`() {
        // MockEngine (like every ktor engine) dispatches request execution on
        // its own `dispatcher` -- Dispatchers.IO by default, a REAL thread
        // pool decoupled from `runTest`'s virtual TestCoroutineScheduler.
        // `advanceUntilIdle()` only drains that virtual scheduler's queue, so
        // without pinning the engine's dispatcher to the SAME scheduler used
        // by `runTest` below, it would return immediately without the mock
        // handler having run at all (observed as `refreshCalls == 0`) --
        // there'd be nothing left to make this deterministic. Pinning both to
        // one `StandardTestDispatcher` makes `advanceUntilIdle()` a
        // structural guarantee: it runs every coroutine to its next real
        // suspension point (here, `gate.await()` for the refresh owner and
        // `flight.await()` for the waiter) with no timing heuristics.
        val testDispatcher = StandardTestDispatcher()

        val gate = CompletableDeferred<Unit>()
        var refreshCalls = 0
        var refreshed = false
        val calls = mutableMapOf("a" to 0, "b" to 0)

        val store = MemoryAuthStore()
        store.save("stale.tok", null)

        val engineConfig =
            MockEngineConfig().apply {
                dispatcher = testDispatcher
                addHandler { request ->
                    val path = request.url.encodedPath
                    when {
                        path.endsWith("auth-refresh") -> {
                            refreshCalls += 1
                            gate.await()
                            refreshed = true
                            respond("""{"token":"fresh.tok","record":{"id":"u1"}}""")
                        }

                        path.endsWith("/a") -> {
                            calls["a"] = calls.getValue("a") + 1
                            if (refreshed) respond("""{"ok":true}""") else respond("""{"message":"expired"}""", HttpStatusCode.Unauthorized)
                        }

                        else -> {
                            calls["b"] = calls.getValue("b") + 1
                            if (refreshed) respond("""{"ok":true}""") else respond("""{"message":"expired"}""", HttpStatusCode.Unauthorized)
                        }
                    }
                }
            }
        val transport =
            Transport(
                "http://api.test",
                store,
                authCollection = "users",
                autoRefresh = true,
                httpClient = HttpClient(MockEngine(engineConfig)),
            )

        runTest(testDispatcher) {
            val job1 = async { transport.request(RequestSpec(HttpMethod.Get, "/api/a")) }
            val job2 = async { transport.request(RequestSpec(HttpMethod.Get, "/api/b")) }

            // Drive both coroutines to their blocked state (one inside the
            // refresh network call, awaiting `gate`; the other joined as a
            // waiter on the shared flight) before releasing the refresh.
            advanceUntilIdle()
            assertEquals(1, refreshCalls, "refresh should have started exactly once before being released")

            gate.complete(Unit)
            advanceUntilIdle()

            val r1 = job1.await()
            val r2 = job2.await()
            assertTrue(r1!!.jsonObject["ok"]!!.jsonPrimitive.boolean)
            assertTrue(r2!!.jsonObject["ok"]!!.jsonPrimitive.boolean)
            assertEquals(1, refreshCalls)
            assertEquals("fresh.tok", store.token)
        }
    }

    // --- Rule 6: multipart / GET-drops-body -----------------------------------------

    @Test
    fun `multipart request uses multipart content-type with a boundary and never hand-sets it`() =
        runTest {
            var seenContentType: String? = null
            var seenBody: ByteArray? = null
            val transport =
                makeTransport { request ->
                    seenContentType = request.body.contentType?.toString()
                    seenBody = request.body.toByteArray()
                    respond("""{"id":"1"}""", HttpStatusCode.Created)
                }
            transport.request(
                RequestSpec(
                    HttpMethod.Post,
                    "/api/collections/posts/records",
                    body = mapOf("title" to "hi", "file" to FileArg.Bytes("a.txt", "hello".toByteArray(), "text/plain")),
                ),
            )
            assertTrue(seenContentType!!.startsWith("multipart/form-data"))
            assertTrue(seenContentType!!.contains("boundary="))
            val bodyText = String(seenBody!!)
            assertTrue(bodyText.contains("name=\"title\""))
            assertTrue(bodyText.contains("filename=\"a.txt\""))
            assertTrue(bodyText.contains("hello"))
        }

    @Test
    fun `multipart filename containing a quote is escaped in the part header`() =
        runTest {
            var seenBody: ByteArray? = null
            val transport =
                makeTransport { request ->
                    seenBody = request.body.toByteArray()
                    respond("""{"id":"1"}""", HttpStatusCode.Created)
                }
            transport.request(
                RequestSpec(
                    HttpMethod.Post,
                    "/api/collections/posts/records",
                    body =
                        mapOf(
                            "file" to
                                FileArg.Bytes(
                                    "he said \"hi\".txt",
                                    "hello".toByteArray(),
                                    "text/plain",
                                ),
                        ),
                ),
            )
            val bodyText = String(seenBody!!)
            // A well-formed quoted-string part header escapes every embedded
            // `"` as `\"` -- an unescaped one would prematurely terminate the
            // `filename="..."` parameter, corrupting the part header.
            assertTrue(bodyText.contains("filename=\"he said \\\"hi\\\".txt\""))
        }

    @Test
    fun `json body sets content-type application json`() =
        runTest {
            var seenContentType: String? = null
            var seenBody: String? = null
            val transport =
                makeTransport { request ->
                    seenContentType = request.body.contentType?.toString()
                    seenBody = request.body.toByteArray().decodeToString()
                    respond("""{"id":"1"}""", HttpStatusCode.Created)
                }
            transport.request(RequestSpec(HttpMethod.Post, "/api/x", body = mapOf("title" to "hi")))
            assertEquals("application/json", seenContentType)
            assertEquals("""{"title":"hi"}""", seenBody)
        }

    @Test
    fun `GET drops the body`() =
        runTest {
            var seenContentLength: Long? = null
            var seenIsNoContent = false
            val transport =
                makeTransport { request ->
                    seenContentLength = request.body.contentLength
                    seenIsNoContent = request.body is OutgoingContent.NoContent
                    respond("""{"ok":true}""")
                }
            val out = transport.request(RequestSpec(HttpMethod.Get, "/api/x", body = mapOf("ignored" to "value")))
            assertTrue(out!!.jsonObject["ok"]!!.jsonPrimitive.boolean)
            assertTrue(seenIsNoContent || seenContentLength == null || seenContentLength == 0L)
        }

    // --- Rule 7: network errors propagate unwrapped -----------------------------------

    @Test
    fun `network errors propagate unwrapped`() =
        runTest {
            val transport = makeTransport { throw IOException("boom") }
            assertFailsWithSuspend<IOException> { transport.request(RequestSpec(HttpMethod.Get, "/api/x")) }
        }

    // --- rawRequest: no error mapping, no retry -------------------------------------

    @Test
    fun `rawRequest returns the response without raising or retrying`() =
        runTest {
            var calls = 0
            val transport =
                makeTransport {
                    calls += 1
                    respond("""{"message":"slow"}""", HttpStatusCode.TooManyRequests, headersOf(HttpHeaders.RetryAfter, "0"))
                }
            val response = transport.rawRequest(RequestSpec(HttpMethod.Get, "/api/x"))
            assertEquals(HttpStatusCode.TooManyRequests, response.status)
            assertEquals(1, calls)
        }

    // --- close() -----------------------------------------------------------------------

    @Test
    fun `close closes a self-created client`() {
        val store = MemoryAuthStore()
        val transport = Transport("http://api.test", store)
        transport.close()
        // No exception -- the underlying CIO client shuts down cleanly.
        assertTrue(true)
    }

    @Test
    fun `close does not close a caller-provided client`() =
        runTest {
            val engine = MockEngine { respond("""{"ok":true}""") }
            val client = HttpClient(engine)
            val store = MemoryAuthStore()
            val transport = Transport("http://api.test", store, httpClient = client)
            transport.close()
            // The caller-supplied client must still work after Transport.close().
            val ok = transport.request(RequestSpec(HttpMethod.Get, "/api/x"))
            assertTrue(ok!!.jsonObject["ok"]!!.jsonPrimitive.boolean)
            client.close()
        }
}
