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
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Tests for [CollectionService]'s record CRUD + pagination surface, mirroring
 * `clients/python/tests/test_collection.py`'s CRUD/pagination matrix.
 */
class CollectionServiceTest {
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

    private fun makeService(
        name: String = "posts",
        handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData,
    ): CollectionService {
        val engine = MockEngine(handler)
        val transport = Transport("http://api.test", MemoryAuthStore(), httpClient = HttpClient(engine))
        return CollectionService(transport, name)
    }

    // --- getList ------------------------------------------------------------

    @Test
    fun `getList parses the offset envelope`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond(
                        """{"page":2,"perPage":10,"totalItems":42,"totalPages":5,"items":[{"id":"r1"},{"id":"r2"}]}""",
                    )
                }
            val result = service.getList(page = 2, perPage = 10)

            assertEquals(HttpMethod.Get, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/posts/records"))
            assertEquals("2", seen!!.url.parameters["page"])
            assertEquals("10", seen!!.url.parameters["perPage"])
            assertEquals(2, result.page)
            assertEquals(10, result.perPage)
            assertEquals(42, result.totalItems)
            assertEquals(5, result.totalPages)
            assertEquals(listOf("r1", "r2"), result.items.map { it.id })
        }

    @Test
    fun `getList defaults missing totals to 0`() =
        runTest {
            val service = makeService { respond("""{"items":[]}""") }
            val result = service.getList()

            assertEquals(0, result.page)
            assertEquals(0, result.perPage)
            assertEquals(0, result.totalItems)
            assertEquals(0, result.totalPages)
            assertTrue(result.items.isEmpty())
        }

    @Test
    fun `getList clamps perPage to the server max`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"items":[]}""")
                }
            service.getList(perPage = 5000)
            assertEquals("500", seen!!.url.parameters["perPage"])
        }

    @Test
    fun `getList sends skipTotal only when true`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"items":[]}""")
                }
            service.getList(skipTotal = true)
            assertEquals("true", seen!!.url.parameters["skipTotal"])

            var seenDefault: HttpRequestData? = null
            val serviceDefault =
                makeService { request ->
                    seenDefault = request
                    respond("""{"items":[]}""")
                }
            serviceDefault.getList()
            assertNull(seenDefault!!.url.parameters["skipTotal"])
        }

    @Test
    fun `getList passes vector through to the wire`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"items":[]}""")
                }
            service.getList(vector = "[0.1,0.2,0.3]")
            assertEquals("[0.1,0.2,0.3]", seen!!.url.parameters["vector"])
        }

    // --- getOne ---------------------------------------------------------------

    @Test
    fun `getOne fetches a record by id`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"id":"r1","title":"hi"}""")
                }
            val record = service.getOne("r1")

            assertEquals(HttpMethod.Get, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/posts/records/r1"))
            assertEquals("r1", record.id)
            assertEquals("hi", record.getString("title"))
        }

    // --- getFirstListItem -------------------------------------------------------

    @Test
    fun `getFirstListItem returns the first match`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"r1"}]}""")
                }
            val record = service.getFirstListItem("title = 'hi'")

            assertEquals("r1", record.id)
            assertEquals("title = 'hi'", seen!!.url.parameters["filter"])
            assertEquals("1", seen!!.url.parameters["page"])
            assertEquals("1", seen!!.url.parameters["perPage"])
            assertEquals("true", seen!!.url.parameters["skipTotal"])
        }

    @Test
    fun `getFirstListItem raises a synthesized 404 when nothing matches`() =
        runTest {
            val service = makeService { respond("""{"page":1,"perPage":1,"totalItems":0,"totalPages":0,"items":[]}""") }
            val ex = assertFailsWithSuspend<ZigbaseException> { service.getFirstListItem("title = 'missing'") }

            assertEquals(404, ex.status)
            assertEquals("No record found matching the filter.", ex.message)
            assertTrue(ex.url.endsWith("/api/collections/posts/records"))
        }

    // --- create / update / delete -----------------------------------------------

    @Test
    fun `create posts the body and parses the record`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"id":"r1","title":"hi"}""", HttpStatusCode.Created)
                }
            val record = service.create(mapOf("title" to "hi"))

            assertEquals(HttpMethod.Post, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/posts/records"))
            assertEquals("""{"title":"hi"}""", seen!!.body.toByteArray().decodeToString())
            assertEquals("r1", record.id)
        }

    @Test
    fun `update patches the body and parses the record`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"id":"r1","title":"bye"}""")
                }
            val record = service.update("r1", mapOf("title" to "bye"))

            assertEquals(HttpMethod.Patch, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/posts/records/r1"))
            assertEquals("bye", record.getString("title"))
        }

    @Test
    fun `delete issues DELETE and returns Unit`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }
            service.delete("r1")

            assertEquals(HttpMethod.Delete, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/posts/records/r1"))
        }

    // --- getAbilities ---------------------------------------------------------

    @Test
    fun `getAbilities parses the view update delete flags`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"view":true,"update":false,"delete":true}""")
                }
            val abilities = service.getAbilities("r1")

            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/posts/records/r1/abilities"))
            assertTrue(abilities.view)
            assertFalse(abilities.update)
            assertTrue(abilities.delete)
        }

    // --- getPage ----------------------------------------------------------------

    @Test
    fun `getPage round-trips the opaque cursor envelope`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond(
                        """{"items":[{"id":"r1"}],"nextCursor":"TOK1","prevCursor":null,"hasNext":true,"hasPrev":false,"totalItems":7}""",
                    )
                }
            val page = service.getPage(limit = 5, withTotal = true)

            assertEquals("5", seen!!.url.parameters["limit"])
            assertEquals("false", seen!!.url.parameters["skipTotal"])
            assertNull(seen!!.url.parameters["cursor"])
            assertEquals(listOf("r1"), page.items.map { it.id })
            assertEquals("TOK1", page.nextCursor)
            assertNull(page.prevCursor)
            assertTrue(page.hasNext)
            assertFalse(page.hasPrev)
            assertEquals(7, page.totalItems)
        }

    @Test
    fun `getPage normalizes an explicit empty cursor to omitted, matching every sibling SDK`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"items":[],"hasNext":false,"hasPrev":false}""")
                }
            service.getPage(cursor = "")

            assertNull(seen!!.url.parameters["cursor"])
        }

    @Test
    fun `getPage omits cursor for the default first page`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"items":[],"hasNext":false,"hasPrev":false}""")
                }
            service.getPage()

            assertNull(seen!!.url.parameters["cursor"])
        }

    @Test
    fun `getPage defaults totalItems to null without withTotal`() =
        runTest {
            val service = makeService { respond("""{"items":[],"hasNext":false,"hasPrev":false}""") }
            val page = service.getPage()
            assertNull(page.totalItems)
        }

    // --- iterate / getFullList ---------------------------------------------------

    @Test
    fun `iterate crosses pages following nextCursor`() =
        runTest {
            val seenCursors = mutableListOf<String?>()
            val service =
                makeService { request ->
                    val cursor = request.url.parameters["cursor"]
                    seenCursors.add(cursor)
                    when (cursor) {
                        null -> {
                            respond("""{"items":[{"id":"r1"}],"nextCursor":"TOK1","hasNext":true,"hasPrev":false}""")
                        }

                        "TOK1" -> {
                            respond("""{"items":[{"id":"r2"}],"nextCursor":"TOK2","hasNext":true,"hasPrev":true}""")
                        }

                        "TOK2" -> {
                            respond("""{"items":[{"id":"r3"}],"nextCursor":null,"hasNext":false,"hasPrev":true}""")
                        }

                        else -> {
                            throw AssertionError("unexpected cursor $cursor")
                        }
                    }
                }
            val items = service.iterate(batch = 1).toList()

            assertEquals(listOf("r1", "r2", "r3"), items.map { it.id })
            assertEquals(listOf(null, "TOK1", "TOK2"), seenCursors)
        }

    @Test
    fun `getFullList accumulates every page`() =
        runTest {
            var calls = 0
            val service =
                makeService {
                    calls += 1
                    if (calls == 1) {
                        respond("""{"items":[{"id":"r1"}],"nextCursor":"TOK1","hasNext":true,"hasPrev":false}""")
                    } else {
                        respond("""{"items":[{"id":"r2"}],"nextCursor":null,"hasNext":false,"hasPrev":true}""")
                    }
                }
            val items = service.getFullList(batch = 1)
            assertEquals(listOf("r1", "r2"), items.map { it.id })
        }

    @Test
    fun `iterate raises on an empty page that still claims hasNext`() =
        runTest {
            val service =
                makeService {
                    respond("""{"items":[],"nextCursor":"TOK1","hasNext":true,"hasPrev":false}""")
                }
            val ex = assertFailsWithSuspend<ZigbaseException> { service.iterate().toList() }
            assertEquals(0, ex.status)
            assertTrue(ex.message.contains("non-advancing"))
        }

    @Test
    fun `iterate raises on a repeated cursor token`() =
        runTest {
            var calls = 0
            val service =
                makeService {
                    calls += 1
                    if (calls == 1) {
                        respond("""{"items":[{"id":"r1"}],"nextCursor":"TOK1","hasNext":true,"hasPrev":false}""")
                    } else {
                        respond("""{"items":[{"id":"r2"}],"nextCursor":"TOK1","hasNext":true,"hasPrev":true}""")
                    }
                }
            val ex = assertFailsWithSuspend<ZigbaseException> { service.iterate().toList() }
            assertEquals(0, ex.status)
            assertTrue(ex.message.contains("non-advancing"))
        }

    // --- percent-encoding -----------------------------------------------------

    @Test
    fun `collection name is percent-encoded in the path`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService(name = "a/b c") { request ->
                    seen = request
                    respond("""{"items":[]}""")
                }
            service.getList()
            assertTrue(seen!!.url.encodedPath.contains("a%2Fb%20c"))
        }

    @Test
    fun `record id is percent-encoded in the path`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"id":"a/b"}""")
                }
            service.getOne("a/b c")
            assertTrue(seen!!.url.encodedPath.contains("a%2Fb%20c"))
        }

    // --- multipart create -----------------------------------------------------------

    @Test
    fun `create switches to multipart when the body contains a file`() =
        runTest {
            var seenContentType: String? = null
            var seenBody: ByteArray? = null
            val service =
                makeService { request ->
                    seenContentType = request.body.contentType?.toString()
                    seenBody = request.body.toByteArray()
                    respond("""{"id":"r1"}""", HttpStatusCode.Created)
                }
            service.create(mapOf("title" to "hi", "file" to FileArg.Bytes("a.txt", "hello".toByteArray(), "text/plain")))

            assertTrue(seenContentType!!.startsWith("multipart/form-data"))
            val bodyText = String(seenBody!!)
            assertTrue(bodyText.contains("name=\"title\""))
            assertTrue(bodyText.contains("filename=\"a.txt\""))
        }
}
