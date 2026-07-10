package io.github.valthon.zigbase

import io.github.valthon.zigbase.auth.MemoryAuthStore
import io.github.valthon.zigbase.errors.ZigbaseException
import io.github.valthon.zigbase.internal.Transport
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.http.HttpMethod
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.time.Instant

/**
 * Tests for [FilesService], [AccountsService], [AnalyticsService], and
 * [SendersService] -- a port of `clients/python/tests/test_services.py`.
 */
class ServicesTest {
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

    private fun makeTransport(
        handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData,
    ): Pair<Transport, () -> HttpRequestData?> {
        var seen: HttpRequestData? = null
        val engine =
            MockEngine { request ->
                seen = request
                handler(request)
            }
        val transport = Transport("http://localhost:8090", MemoryAuthStore(), httpClient = HttpClient(engine))
        return transport to { seen }
    }

    // --- FilesService.getUrl / getUrlFor (pure) ------------------------------

    @Test
    fun `getUrlFor encodes each segment and strips trailing slashes`() {
        val (transport, _) = makeTransport { respond("") }
        val svc = FilesService(transport, "http://localhost:8090/")

        val url = svc.getUrlFor("posts", "rec1", "my photo.png")

        assertEquals("http://localhost:8090/api/files/posts/rec1/my%20photo.png", url)
    }

    @Test
    fun `getUrlFor emits download thumb token query in order`() {
        val (transport, _) = makeTransport { respond("") }
        val svc = FilesService(transport, "http://localhost:8090")

        val url = svc.getUrlFor("posts", "rec1", "photo.png", download = true, thumb = "100x100", token = "tok abc")

        assertEquals(
            "http://localhost:8090/api/files/posts/rec1/photo.png?download=1&thumb=100x100&token=tok+abc",
            url,
        )
    }

    @Test
    fun `getUrl derives collection from collectionId`() {
        val (transport, _) = makeTransport { respond("") }
        val svc = FilesService(transport, "http://localhost:8090")
        val record = ZbRecord(recordJson("""{"id":"rec1","collectionId":"col_abc","collectionName":"posts"}"""))

        val url = svc.getUrl(record, "photo.png")

        assertEquals("http://localhost:8090/api/files/col_abc/rec1/photo.png", url)
    }

    @Test
    fun `getUrl falls back to collectionName`() {
        val (transport, _) = makeTransport { respond("") }
        val svc = FilesService(transport, "http://localhost:8090")
        val record = ZbRecord(recordJson("""{"id":"rec1","collectionName":"posts"}"""))

        val url = svc.getUrl(record, "photo.png")

        assertEquals("http://localhost:8090/api/files/posts/rec1/photo.png", url)
    }

    @Test
    fun `getUrl falls back to collectionName when collectionId is empty`() {
        val (transport, _) = makeTransport { respond("") }
        val svc = FilesService(transport, "http://localhost:8090")
        val record = ZbRecord(recordJson("""{"id":"rec1","collectionId":"","collectionName":"posts"}"""))

        val url = svc.getUrl(record, "photo.png")

        assertEquals("http://localhost:8090/api/files/posts/rec1/photo.png", url)
    }

    @Test
    fun `getUrl raises when neither collectionId nor collectionName is present`() {
        val (transport, _) = makeTransport { respond("") }
        val svc = FilesService(transport, "http://localhost:8090")
        val record = ZbRecord(recordJson("""{"id":"rec1"}"""))

        val ex = assertThrows(IllegalArgumentException::class.java) { svc.getUrl(record, "photo.png") }
        assertTrue(ex.message!!.contains("collectionId"))
        assertTrue(ex.message!!.contains("collectionName"))
    }

    // --- FilesService.getToken ------------------------------------------------

    @Test
    fun `getToken posts and unwraps token`() =
        runTest {
            val (transport, seen) = makeTransport { respond("""{"token":"file-tok-1"}""") }
            val svc = FilesService(transport, "http://localhost:8090")

            val tok = svc.getToken()

            assertEquals("file-tok-1", tok)
            assertEquals(HttpMethod.Post, seen()!!.method)
            assertTrue(seen()!!.url.encodedPath.endsWith("/api/files/token"))
        }

    @Test
    fun `getToken raises when token is missing`() =
        runTest {
            val (transport, _) = makeTransport { respond("""{}""") }
            val svc = FilesService(transport, "http://localhost:8090")

            val ex = assertFailsWithSuspend<ZigbaseException> { svc.getToken() }
            assertEquals(0, ex.status)
        }

    // --- AccountsService.activate ----------------------------------------------

    @Test
    fun `activate posts encoded id path and returns scope`() =
        runTest {
            val (transport, seen) = makeTransport { respond("""{"account":"acc_1","role":"owner"}""") }
            val svc = AccountsService(transport)

            val scope = svc.activate("acc/1")

            assertEquals("owner", scope["role"]!!.jsonPrimitive.content)
            assertEquals("acc_1", scope["account"]!!.jsonPrimitive.content)
            assertEquals(HttpMethod.Post, seen()!!.method)
            assertTrue(seen()!!.url.encodedPath.endsWith("/api/accounts/acc%2F1/activate"))
        }

    // --- AnalyticsService.events -------------------------------------------------

    @Test
    fun `events sends query and parses cursor envelope`() =
        runTest {
            val (transport, seen) =
                makeTransport {
                    respond("""{"items":[{"id":"e1","name":"signup"}],"nextCursor":"c2","hasNext":true}""")
                }
            val svc = AnalyticsService(transport)

            val page = svc.events(name = "signup", actor = "u1", limit = 10, cursor = "c1")

            assertEquals(HttpMethod.Get, seen()!!.method)
            assertTrue(seen()!!.url.encodedPath.endsWith("/api/analytics/events"))
            assertEquals("signup", seen()!!.url.parameters["name"])
            assertEquals("u1", seen()!!.url.parameters["actor"])
            assertEquals("10", seen()!!.url.parameters["limit"])
            assertEquals("c1", seen()!!.url.parameters["cursor"])
            assertEquals(listOf("e1"), page.items.map { it.id })
            assertEquals("c2", page.nextCursor)
            assertTrue(page.hasNext)
            assertNull(page.prevCursor)
            assertNull(page.totalItems)
        }

    @Test
    fun `events since formats as iso millis Z`() =
        runTest {
            val (transport, seen) = makeTransport { respond("""{"items":[],"nextCursor":null,"hasNext":false}""") }
            val svc = AnalyticsService(transport)

            svc.events(since = Instant.parse("2024-01-02T03:04:05.678Z"))

            assertEquals("2024-01-02T03:04:05.678Z", seen()!!.url.parameters["since"])
        }

    @Test
    fun `events with no opts sends no name actor since cursor limit params`() =
        runTest {
            val (transport, seen) = makeTransport { respond("""{"items":[{"id":"e1"}],"nextCursor":null,"hasNext":false}""") }
            val svc = AnalyticsService(transport)

            val page = svc.events()

            assertNull(seen()!!.url.parameters["name"])
            assertNull(seen()!!.url.parameters["actor"])
            assertNull(seen()!!.url.parameters["since"])
            assertNull(seen()!!.url.parameters["cursor"])
            assertNull(seen()!!.url.parameters["limit"])
            assertEquals(listOf("e1"), page.items.map { it.id })
            assertFalse(page.hasNext)
        }

    // --- AnalyticsService.rollup ----------------------------------------------------

    @Test
    fun `rollup sends encoded name and from to and unwraps items`() =
        runTest {
            val (transport, seen) = makeTransport { respond("""{"items":[{"bucket":"2024-01-01","value":3}]}""") }
            val svc = AnalyticsService(transport)

            val rows =
                svc.rollup(
                    "daily active/users",
                    from = Instant.parse("2024-01-01T00:00:00.000Z"),
                    to = Instant.parse("2024-01-02T00:00:00.000Z"),
                )

            assertEquals(1, rows.size)
            assertEquals("2024-01-01", rows[0]["bucket"]!!.jsonPrimitive.content)
            assertTrue(seen()!!.url.encodedPath.endsWith("/api/analytics/rollups/daily%20active%2Fusers"))
            assertEquals("2024-01-01T00:00:00.000Z", seen()!!.url.parameters["from"])
            assertEquals("2024-01-02T00:00:00.000Z", seen()!!.url.parameters["to"])
        }

    @Test
    fun `rollup with no opts sends empty query`() =
        runTest {
            val (transport, seen) = makeTransport { respond("""{"items":[]}""") }
            val svc = AnalyticsService(transport)

            val rows = svc.rollup("daily")

            assertTrue(rows.isEmpty())
            assertNull(seen()!!.url.parameters["from"])
            assertNull(seen()!!.url.parameters["to"])
        }

    // --- SendersService -----------------------------------------------------------

    @Test
    fun `senders list unwraps items`() =
        runTest {
            val (transport, seen) =
                makeTransport { respond("""{"items":[{"id":"s1","email":"a@b.com","status":"verified"}]}""") }
            val svc = SendersService(transport)

            val rows = svc.list()

            assertEquals(1, rows.size)
            assertEquals("s1", rows[0]["id"]!!.jsonPrimitive.content)
            assertEquals(HttpMethod.Get, seen()!!.method)
            assertTrue(seen()!!.url.encodedPath.endsWith("/api/senders"))
        }

    @Test
    fun `senders create posts email and returns body`() =
        runTest {
            val (transport, seen) = makeTransport { respond("""{"id":"s2","email":"c@d.com","status":"pending"}""") }
            val svc = SendersService(transport)

            val row = svc.create("c@d.com")

            assertEquals("c@d.com", row["email"]!!.jsonPrimitive.content)
            assertEquals(HttpMethod.Post, seen()!!.method)
            assertTrue(seen()!!.url.encodedPath.endsWith("/api/senders"))
            assertEquals("""{"email":"c@d.com"}""", seen()!!.body.toByteArray().decodeToString())
        }

    @Test
    fun `senders verify posts token and returns verified flag`() =
        runTest {
            val (transport, seen) = makeTransport { respond("""{"verified":true}""") }
            val svc = SendersService(transport)

            val result = svc.verify("s1", "tok-1")

            assertTrue(result)
            assertEquals(HttpMethod.Post, seen()!!.method)
            assertTrue(seen()!!.url.encodedPath.endsWith("/api/senders/s1/verify"))
            assertEquals("""{"token":"tok-1"}""", seen()!!.body.toByteArray().decodeToString())
        }

    @Test
    fun `senders verify returns false and encodes id segment`() =
        runTest {
            val (transport, seen) = makeTransport { respond("""{"verified":false}""") }
            val svc = SendersService(transport)

            val result = svc.verify("s/1", "tok-1")

            assertFalse(result)
            assertTrue(seen()!!.url.encodedPath.endsWith("/api/senders/s%2F1/verify"))
        }

    // --- non-object 2xx body guard --------------------------------------------------

    @Test
    fun `getToken raises clear error on non-object body`() =
        runTest {
            val (transport, _) = makeTransport { respond("null") }
            val svc = FilesService(transport, "http://localhost:8090")

            val ex = assertFailsWithSuspend<ZigbaseException> { svc.getToken() }
            assertTrue(ex.message.contains("JSON object"))
            assertEquals(0, ex.status)
        }

    @Test
    fun `rollup raises clear error on non-object body`() =
        runTest {
            val (transport, _) = makeTransport { respond("null") }
            val svc = AnalyticsService(transport)

            val ex = assertFailsWithSuspend<ZigbaseException> { svc.rollup("daily") }
            assertTrue(ex.message.contains("JSON object"))
            assertEquals(0, ex.status)
        }

    @Test
    fun `events raises clear error on non-object body`() =
        runTest {
            val (transport, _) = makeTransport { respond("null") }
            val svc = AnalyticsService(transport)

            val ex = assertFailsWithSuspend<ZigbaseException> { svc.events() }
            assertTrue(ex.message.contains("JSON object"))
            assertEquals(0, ex.status)
        }

    @Test
    fun `senders list raises clear error on non-object body`() =
        runTest {
            val (transport, _) = makeTransport { respond("null") }
            val svc = SendersService(transport)

            val ex = assertFailsWithSuspend<ZigbaseException> { svc.list() }
            assertTrue(ex.message.contains("JSON object"))
            assertEquals(0, ex.status)
        }

    @Test
    fun `senders verify raises clear error on non-object body`() =
        runTest {
            val (transport, _) = makeTransport { respond("null") }
            val svc = SendersService(transport)

            val ex = assertFailsWithSuspend<ZigbaseException> { svc.verify("s1", "tok") }
            assertTrue(ex.message.contains("JSON object"))
            assertEquals(0, ex.status)
        }

    @Test
    fun `activate raises clear error on non-object body`() =
        runTest {
            val (transport, _) = makeTransport { respond("null") }
            val svc = AccountsService(transport)

            val ex = assertFailsWithSuspend<ZigbaseException> { svc.activate("acc_1") }
            assertTrue(ex.message.contains("JSON object"))
            assertEquals(0, ex.status)
        }
}

private fun recordJson(text: String): JsonObject = Json.parseToJsonElement(text) as JsonObject
