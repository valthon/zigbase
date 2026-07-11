package io.github.valthon.zigbase.typed

import io.github.valthon.zigbase.ZbRecord
import io.github.valthon.zigbase.ZigbaseClient
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
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Tests for [TypedCollection]/[TypedList]/[TypedCursorPage]/[joinCsv]/
 * [normalizeSort], a port of `clients/python/tests/test_typed_service.py`
 * (cross-checked against `clients/dart/lib/typed.dart:307-522`). Drives a real
 * [ZigbaseClient] (over ktor's [MockEngine], the pattern
 * `CollectionServiceTest` uses) so [TypedCollection] is exercised through the
 * actual `client.collection(name)`/`client.files` wiring rather than a fake.
 */
class TypedCollectionTest {
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

    private fun makeTyped(
        name: String = "posts",
        handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData,
    ): TypedCollection<Post> {
        val engine = MockEngine(handler)
        val client = ZigbaseClient("http://api.test", httpClient = HttpClient(engine))
        return TypedCollection(client, postsMeta.copy(name = name), ::postFromRecord)
    }

    // --- joinCsv / normalizeSort --------------------------------------------

    @Test
    fun `joinCsv omits null`() {
        assertNull(joinCsv(null))
    }

    @Test
    fun `joinCsv omits empty`() {
        assertNull(joinCsv(emptyList()))
    }

    @Test
    fun `joinCsv joins with comma`() {
        assertEquals("author,comments", joinCsv(listOf("author", "comments")))
    }

    @Test
    fun `normalizeSort omits null`() {
        assertNull(normalizeSort(null))
    }

    @Test
    fun `normalizeSort joins a list`() {
        assertEquals("-created,title", normalizeSort(listOf("-created", "title")))
    }

    @Test
    fun `normalizeSort omits an empty list`() {
        assertNull(normalizeSort(emptyList()))
    }

    @Test
    fun `normalizeSort drops empty entries`() {
        assertEquals("-created,title", normalizeSort(listOf("-created", "", "title")))
    }

    // --- collection escape hatch --------------------------------------------

    @Test
    fun `collection escape hatch returns the underlying CollectionService`() {
        val typed = makeTyped { respond("{}") }
        assertEquals("posts", typed.collection.name)
    }

    // --- getList -------------------------------------------------------------

    @Test
    fun `getList maps items through fromRecord and sends the query`() =
        runTest {
            var seen: HttpRequestData? = null
            val typed =
                makeTyped { request ->
                    seen = request
                    respond(
                        """{"page":1,"perPage":30,"totalItems":2,"totalPages":1,
                            |"items":[{"id":"p1","title":"hi"},{"id":"p2","title":"bye"}]}
                        """.trimMargin(),
                    )
                }

            val result =
                typed.getList(
                    filter = "title != ''",
                    sort = listOf("-created", "title"),
                    expand = listOf("author", "comments"),
                )

            assertEquals(listOf(Post("p1", "hi"), Post("p2", "bye")), result.items)
            assertEquals(1, result.page)
            assertEquals(30, result.perPage)
            assertEquals(2, result.totalItems)
            assertEquals(1, result.totalPages)

            assertEquals("title != ''", seen!!.url.parameters["filter"])
            assertEquals("-created,title", seen!!.url.parameters["sort"])
            assertEquals("author,comments", seen!!.url.parameters["expand"])
        }

    @Test
    fun `getList omits expand sort filter when null`() =
        runTest {
            var seen: HttpRequestData? = null
            val typed =
                makeTyped { request ->
                    seen = request
                    respond("""{"items":[]}""")
                }

            typed.getList()

            assertNull(seen!!.url.parameters["expand"])
            assertNull(seen!!.url.parameters["sort"])
            assertNull(seen!!.url.parameters["filter"])
        }

    // --- getOne / getFirstListItem -------------------------------------------

    @Test
    fun `getOne maps through fromRecord`() =
        runTest {
            val typed = makeTyped { respond("""{"id":"p1","title":"hi"}""") }
            assertEquals(Post("p1", "hi"), typed.getOne("p1"))
        }

    @Test
    fun `getFirstListItem maps through fromRecord`() =
        runTest {
            val typed =
                makeTyped {
                    respond(
                        """{"page":1,"perPage":1,"totalItems":1,"totalPages":1,"items":[{"id":"p1","title":"hi"}]}""",
                    )
                }
            assertEquals(Post("p1", "hi"), typed.getFirstListItem("title = 'hi'"))
        }

    // --- getPage ---------------------------------------------------------------

    @Test
    fun `getPage round-trips the cursor and maps envelope fields`() =
        runTest {
            var seen: HttpRequestData? = null
            val typed =
                makeTyped { request ->
                    seen = request
                    respond(
                        """{"items":[{"id":"p1","title":"hi"}],"nextCursor":"cursor-2","prevCursor":null,
                            |"hasNext":true,"hasPrev":false,"totalItems":null}
                        """.trimMargin(),
                    )
                }

            val page = typed.getPage(cursor = "cursor-1", limit = 1)

            assertEquals(listOf(Post("p1", "hi")), page.items)
            assertEquals("cursor-2", page.nextCursor)
            assertNull(page.prevCursor)
            assertTrue(page.hasNext)
            assertFalse(page.hasPrev)
            assertNull(page.totalItems)
            assertEquals("cursor-1", seen!!.url.parameters["cursor"])
        }

    // --- iterate / getFullList ---------------------------------------------

    @Test
    fun `iterate maps every item across pages`() =
        runTest {
            val pages =
                listOf(
                    """{"items":[{"id":"p1","title":"a"},{"id":"p2","title":"b"}],"nextCursor":"c2",
                        |"prevCursor":null,"hasNext":true,"hasPrev":false,"totalItems":null}
                    """.trimMargin(),
                    """{"items":[{"id":"p3","title":"c"}],"nextCursor":null,"prevCursor":"c2",
                        |"hasNext":false,"hasPrev":true,"totalItems":null}
                    """.trimMargin(),
                )
            var call = 0
            val typed =
                makeTyped {
                    respond(pages[call++])
                }

            val items = typed.iterate(batch = 2).toList()

            assertEquals(listOf(Post("p1", "a"), Post("p2", "b"), Post("p3", "c")), items)
        }

    @Test
    fun `getFullList accumulates via iterate`() =
        runTest {
            val typed =
                makeTyped {
                    respond(
                        """{"items":[{"id":"p1","title":"a"}],"nextCursor":null,"prevCursor":null,
                            |"hasNext":false,"hasPrev":false,"totalItems":null}
                        """.trimMargin(),
                    )
                }

            assertEquals(listOf(Post("p1", "a")), typed.getFullList())
        }

    // --- create / update / delete -------------------------------------------

    @Test
    fun `create passes the raw body through untouched and maps the result`() =
        runTest {
            var seen: HttpRequestData? = null
            val typed =
                makeTyped { request ->
                    seen = request
                    respond("""{"id":"new1","title":"hello"}""", HttpStatusCode.Created)
                }

            val result = typed.create(mapOf("title" to "hello", "extra" to 42))

            assertEquals(Post("new1", "hello"), result)
            assertEquals(HttpMethod.Post, seen!!.method)
            assertEquals("""{"title":"hello","extra":42}""", seen!!.body.toByteArray().decodeToString())
        }

    @Test
    fun `update passes the raw body through untouched and maps the result`() =
        runTest {
            var seen: HttpRequestData? = null
            val typed =
                makeTyped { request ->
                    seen = request
                    respond("""{"id":"p1","title":"updated"}""")
                }

            val result = typed.update("p1", mapOf("title" to "updated"))

            assertEquals(Post("p1", "updated"), result)
            assertEquals(HttpMethod.Patch, seen!!.method)
            assertEquals("""{"title":"updated"}""", seen!!.body.toByteArray().decodeToString())
        }

    @Test
    fun `delete issues DELETE`() =
        runTest {
            var seen: HttpRequestData? = null
            val typed =
                makeTyped { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }

            typed.delete("p1")

            assertEquals(HttpMethod.Delete, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/posts/records/p1"))
        }

    // --- fileUrl ---------------------------------------------------------------

    @Test
    fun `fileUrl delegates to FilesService getUrl semantics`() =
        runTest {
            val typed = makeTyped { respond("{}") }
            val record =
                ZbRecord(
                    buildJsonObject {
                        put("id", JsonPrimitive("p1"))
                        put("collectionName", JsonPrimitive("posts"))
                    },
                )

            val url = typed.fileUrl(record, "photo.png", download = true, thumb = "100x100")

            assertEquals("http://api.test/api/files/posts/p1/photo.png?download=1&thumb=100x100", url)
        }
}
