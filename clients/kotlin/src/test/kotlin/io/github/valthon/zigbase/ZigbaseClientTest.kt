package io.github.valthon.zigbase

import io.github.valthon.zigbase.auth.MemoryAuthStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import io.ktor.client.request.request
import io.ktor.client.request.url
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertSame
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Tests for [ZigbaseClient] -- a port of `clients/python/tests/test_client.py`'s
 * `ZigBase` matrix (construction, `collection()`, lazily-cached services,
 * `send`/`rawRequest`/`health`, `withAccount` ownership sharing, `close`
 * idempotency), cross-checked against `clients/dart/lib/src/client.dart`'s
 * ownership contract.
 */
class ZigbaseClientTest {
    private fun recorder(
        handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData,
    ): Pair<HttpClient, () -> List<HttpRequestData>> {
        val seen = mutableListOf<HttpRequestData>()
        val engine =
            MockEngine { request ->
                seen.add(request)
                handler(request)
            }
        return HttpClient(engine) to { seen.toList() }
    }

    // --- construction --------------------------------------------------------

    @Test
    fun `base url is normalized`() {
        val (client, _) = recorder { respond("{}") }
        val zb = ZigbaseClient("http://localhost:8090///", httpClient = client)
        assertEquals("http://localhost:8090", zb.baseUrl)
        zb.close()
    }

    @Test
    fun `default auth store is a memory auth store`() {
        val (client, _) = recorder { respond("{}") }
        val zb = ZigbaseClient("http://localhost:8090", httpClient = client)
        assertTrue(zb.authStore is MemoryAuthStore)
        zb.close()
    }

    @Test
    fun `explicit auth store is used verbatim`() {
        val store = MemoryAuthStore()
        val (client, _) = recorder { respond("{}") }
        val zb = ZigbaseClient("http://localhost:8090", authStore = store, httpClient = client)
        assertSame(store, zb.authStore)
        zb.close()
    }

    // --- collection() ----------------------------------------------------------

    @Test
    fun `collection binds name to the wire path`() =
        runTest {
            val (client, requests) = recorder { respond("""{"id":"rec1","collectionName":"posts"}""") }
            val zb = ZigbaseClient("http://localhost:8090", httpClient = client)
            val svc = zb.collection("posts")

            assertEquals("posts", svc.name)
            svc.getOne("rec1")

            assertEquals("/api/collections/posts/records/rec1", requests().first().url.encodedPath)
            zb.close()
        }

    // --- lazily-cached services --------------------------------------------------

    @Test
    fun `service getters are cached identical instances`() {
        val (client, _) = recorder { respond("{}") }
        val zb = ZigbaseClient("http://localhost:8090", httpClient = client)

        assertSame(zb.files, zb.files)
        assertSame(zb.accounts, zb.accounts)
        assertSame(zb.analytics, zb.analytics)
        assertSame(zb.senders, zb.senders)
        zb.close()
    }

    // --- health() ----------------------------------------------------------

    @Test
    fun `health gets api health`() =
        runTest {
            val (client, requests) = recorder { respond("""{"status":"ok"}""") }
            val zb = ZigbaseClient("http://localhost:8090", httpClient = client)

            val result = zb.health()

            assertEquals("ok", result["status"]!!.jsonPrimitive.content)
            assertEquals(HttpMethod.Get, requests().first().method)
            assertEquals("/api/health", requests().first().url.encodedPath)
            zb.close()
        }

    @Test
    fun `health raises a clear error on 204`() =
        runTest {
            val (client, _) = recorder { respond("", HttpStatusCode.NoContent) }
            val zb = ZigbaseClient("http://localhost:8090", httpClient = client)

            assertFailsWithSuspend<Throwable> { zb.health() }
            zb.close()
        }

    // --- send() / rawRequest() --------------------------------------------------

    @Test
    fun `send hits an arbitrary path with the bearer header`() =
        runTest {
            val (client, requests) = recorder { respond("""{"ok":true}""") }
            val store = MemoryAuthStore()
            store.save("tok.tok.tok", null)
            val zb = ZigbaseClient("http://localhost:8090", authStore = store, httpClient = client)

            val result = zb.send(HttpMethod.Post, "/api/custom", body = mapOf("a" to 1))

            assertNotNull(result)
            val req = requests().first()
            assertEquals("Bearer tok.tok.tok", req.headers["Authorization"])
            assertEquals(HttpMethod.Post, req.method)
            assertEquals("/api/custom", req.url.encodedPath)
            zb.close()
        }

    @Test
    fun `rawRequest returns the response without decoding`() =
        runTest {
            val (client, _) = recorder { respond("""{"status":"ok"}""") }
            val zb = ZigbaseClient("http://localhost:8090", httpClient = client)

            val response: HttpResponse = zb.rawRequest(HttpMethod.Get, "/api/health")

            assertEquals(HttpStatusCode.OK, response.status)
            zb.close()
        }

    // --- withAccount() ----------------------------------------------------------

    @Test
    fun `withAccount sends the header only on the sibling`() =
        runTest {
            val (client, requests) = recorder { respond("{}") }
            val zb = ZigbaseClient("http://localhost:8090", httpClient = client)
            val sibling = zb.withAccount("acct-1")

            zb.send(HttpMethod.Get, "/api/x")
            sibling.send(HttpMethod.Get, "/api/y")

            assertTrue(requests()[0].headers["X-Account-Id"] == null)
            assertEquals("acct-1", requests()[1].headers["X-Account-Id"])
            zb.close()
        }

    @Test
    fun `withAccount shares the auth store and underlying http client`() {
        val (client, _) = recorder { respond("{}") }
        val zb = ZigbaseClient("http://localhost:8090", httpClient = client)

        val sibling = zb.withAccount("acct-1")

        assertSame(zb.authStore, sibling.authStore)
        assertSame(zb.httpClientForTesting, sibling.httpClientForTesting)

        // login propagates: saving on either store is visible to the other.
        zb.authStore.save("tok", null)
        assertEquals("tok", sibling.authStore.token)
        zb.close()
    }

    @Test
    fun `withAccount sibling close never closes the shared client`() =
        runTest {
            val (client, _) = recorder { respond("""{"ok":true}""") }
            val zb = ZigbaseClient("http://localhost:8090", httpClient = client)
            val sibling = zb.withAccount("acct-1")

            sibling.close()

            // parent still works after the sibling closed.
            val result = zb.send(HttpMethod.Get, "/api/x")
            assertNotNull(result)
            zb.close()
        }

    @Test
    fun `chained withAccount stays sane`() =
        runTest {
            val (client, requests) = recorder { respond("{}") }
            val zb = ZigbaseClient("http://localhost:8090", httpClient = client)
            val a = zb.withAccount("acct-a")
            val b = a.withAccount("acct-b")

            b.send(HttpMethod.Get, "/api/z")

            assertEquals("acct-b", requests().first().headers["X-Account-Id"])
            assertSame(zb.authStore, b.authStore)
            zb.close()
        }

    // --- close() -----------------------------------------------------------------

    @Test
    fun `close closes a self-created client`() =
        runTest {
            val zb = ZigbaseClient("http://127.0.0.1:65535")

            zb.close()

            assertFailsWithSuspend<Throwable> { zb.rawRequest(HttpMethod.Get, "/api/health") }
        }

    @Test
    fun `close leaves an injected client open`() =
        runTest {
            val (client, _) = recorder { respond("""{"status":"ok"}""") }
            val zb = ZigbaseClient("http://localhost:8090", httpClient = client)

            zb.close()

            // the injected client itself is still usable directly.
            val response = client.request { url("http://localhost:8090/api/health") }
            assertEquals(HttpStatusCode.OK, response.status)
        }

    @Test
    fun `close is idempotent`() {
        val zb = ZigbaseClient("http://127.0.0.1:65535")
        zb.close()
        zb.close()
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
