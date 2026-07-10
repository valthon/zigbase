package io.github.valthon.zigbase.integration

import io.github.valthon.zigbase.Abilities
import io.github.valthon.zigbase.FileArg
import io.github.valthon.zigbase.ZigbaseClient
import io.github.valthon.zigbase.errors.ZigbaseException
import io.github.valthon.zigbase.query.zbFilter
import io.ktor.client.HttpClient
import io.ktor.client.call.body
import io.ktor.client.engine.cio.CIO
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
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
 * Live-server integration suite: drives the public [ZigbaseClient] facade
 * against a real `zigbase serve` process (see [Harness]). Skipped as a whole
 * (JUnit5 "aborted", not "failed") when `ZIGBASE_TEST_BINARY` is unset --
 * see [requireBinaryOrSkip].
 *
 * Coverage mirrors `clients/python/tests/integration/test_crud_live.py` /
 * `test_auth_live.py` / `test_files_live.py` (the SP1 Task 12 reference
 * list), cross-checked against `clients/dart/test/integration
 * /integration_test.dart`. Two prior sibling SDKs (Dart, Python) picked up
 * review findings for assertions that would pass even if the feature under
 * test were broken -- every test here follows the same discipline those
 * reviews established: assert the FULL shape of a response (not just "it
 * didn't throw"), and where a positive assertion could pass by accident (an
 * auth-refresh proving a token still works, a rule denying access), pair it
 * with a negative control that would fail if the assertion were vacuous
 * (see [testAuthRefreshRotatesTokenWithGenuineAuthGate]'s anonymous 404).
 *
 * `runBlocking` (not `runTest`) wraps every test body: these calls hit a
 * real server over real sockets, so there is no virtual clock to control and
 * no reason to take on `runTest`'s default wall-clock timeout budget.
 */
@Timeout(value = 60, unit = TimeUnit.SECONDS)
class LiveIntegrationTest {
    companion object {
        private lateinit var server: LaunchedServer
        private val memberSeq = AtomicInteger(0)

        @JvmStatic
        @BeforeAll
        fun setUpAll() {
            val binary = requireBinaryOrSkip()
            server = startServer(binary)
            createCollection(server.baseUrl, server.superuserToken, postsDefinition("posts"))
            createCollection(server.baseUrl, server.superuserToken, postsDefinition("cursorposts"))
            createCollection(server.baseUrl, server.superuserToken, lockedDefinition("locked"))
            createCollection(server.baseUrl, server.superuserToken, membersDefinition("members"))
            createCollection(server.baseUrl, server.superuserToken, postsDefinition("feed"))
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

        /** Creates a `members` record via the superuser client. Returns `email to password`. */
        private suspend fun seedMember(password: String): Pair<String, String> {
            val email = "member${memberSeq.getAndIncrement()}@test.local"
            adminClient().use { admin ->
                admin.collection("members").create(
                    mapOf(
                        "email" to email,
                        "password" to password,
                        "passwordConfirm" to password,
                        "name" to "Mem",
                        "emailVisibility" to true,
                    ),
                )
            }
            return email to password
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
    fun testHealthCheck() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                val health = client.health()
                assertEquals("ok", health["status"]?.jsonPrimitive?.content)
            }
        }

    @Test
    fun testCrudRoundtripWithZbFilterAndApostrophe() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                val posts = client.collection("posts")

                val target = posts.create(mapOf("title" to "O'Brien", "views" to 100))
                posts.create(mapOf("title" to "Smith", "views" to 101))
                assertTrue(target.id.isNotEmpty())
                assertEquals("O'Brien", target.getString("title"))
                assertEquals(100, target.getInt("views"))

                val fetched = posts.getOne(target.id)
                assertEquals("O'Brien", fetched.getString("title"))

                // The apostrophe must survive the lexer round-trip: a query that
                // matched everything (or nothing) here would silently hide a
                // filter-escaping regression.
                val result = posts.getList(filter = zbFilter("title = {:t}", mapOf("t" to "O'Brien")))
                assertEquals(listOf(target.id), result.items.map { it.id })
                assertEquals("O'Brien", result.items[0].getString("title"))
            }
        }

    @Test
    fun testPatchPartialUpdateLeavesOtherFieldsUntouched() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                val posts = client.collection("posts")
                val created = posts.create(mapOf("title" to "Original", "views" to 7))

                val updated = posts.update(created.id, mapOf("title" to "Renamed"))
                assertEquals("Renamed", updated.getString("title"))
                assertEquals(7, updated.getInt("views")) // untouched by the partial PATCH
            }
        }

    @Test
    fun testDeleteThenGetOneRaises404() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                val posts = client.collection("posts")
                val created = posts.create(mapOf("title" to "Ephemeral", "views" to 1))

                posts.delete(created.id)

                val ex = assertThrowsSuspend<ZigbaseException> { posts.getOne(created.id) }
                assertEquals(404, ex.status)
            }
        }

    @Test
    fun testGetAbilitiesOnPublicCollection() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                val posts = client.collection("posts")
                val created = posts.create(mapOf("title" to "Abilities", "views" to 1))

                val abilities = posts.getAbilities(created.id)
                // posts has @public view/update/delete rules -- even an anonymous
                // caller can do all three.
                assertEquals(Abilities(view = true, update = true, delete = true), abilities)
            }
        }

    @Test
    fun testLockedCollectionCreateAsAnonRaises403() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                val ex =
                    assertThrowsSuspend<ZigbaseException> {
                        client.collection("locked").create(mapOf("title" to "nope"))
                    }
                assertEquals(403, ex.status)
            }
        }

    @Test
    @Timeout(value = 60, unit = TimeUnit.SECONDS)
    fun testCursorIterateOverMultiplePages() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                val posts = client.collection("cursorposts")
                val seedCount = 70
                for (i in 0 until seedCount) {
                    posts.create(mapOf("title" to "C$i", "views" to i))
                }

                // Manually drive getPage to confirm the run actually spans > 2
                // pages, and that the server-side sort order (views ascending)
                // is honored continuously across the cursor boundary, not just
                // within one page.
                val seenIds = mutableListOf<String>()
                val seenViews = mutableListOf<Int>()
                var pages = 0
                var page = posts.getPage(limit = 30, sort = "views", withTotal = true)
                assertEquals(seedCount, page.totalItems)
                while (true) {
                    pages += 1
                    seenIds.addAll(page.items.map { it.id })
                    seenViews.addAll(page.items.map { it.getInt("views") ?: -1 })
                    if (!page.hasNext || page.nextCursor.isNullOrEmpty()) break
                    page = posts.getPage(cursor = page.nextCursor, limit = 30, sort = "views")
                }
                assertTrue(pages > 2, "expected > 2 pages, got $pages")
                assertEquals(seedCount, seenIds.size)
                assertEquals(seedCount, seenIds.toSet().size, "no duplicate ids across pages")
                assertEquals(seenViews.sorted(), seenViews, "sort order must hold across the cursor boundary")
                assertEquals((0 until seedCount).toList(), seenViews)

                // iterate() yields every record exactly once, following the
                // cursor itself (a different code path from the manual getPage
                // loop above).
                val iterated = posts.iterate(batch = 30, sort = "views").toList()
                assertEquals(seedCount, iterated.size)
                assertEquals(seedCount, iterated.map { it.id }.toSet().size)
            }
        }

    @Test
    fun testPasswordAuth() =
        runBlocking {
            val (email, password) = seedMember("member-pass-1")

            ZigbaseClient(server.baseUrl).use { client ->
                val auth = client.collection("members").authWithPassword(email, password)
                assertTrue(auth.token.isNotEmpty())
                assertEquals(auth.token, client.authStore.token)
                assertNotNull(auth.record)
                assertEquals(email, auth.record!!.getString("email"))
            }
        }

    @Test
    fun testAuthRefreshRotatesTokenWithGenuineAuthGate() =
        runBlocking {
            val (email, password) = seedMember("member-pass-2")

            ZigbaseClient(server.baseUrl).use { client ->
                val members = client.collection("members")
                val auth = members.authWithPassword(email, password)
                val memberId = auth.record!!.id

                val refreshed = members.authRefresh()
                assertTrue(refreshed.token.isNotEmpty())
                assertNotEquals(auth.token, refreshed.token, "authRefresh should mint a fresh token, not echo the old one")
                assertEquals(refreshed.token, client.authStore.token)

                // The refreshed token genuinely authenticates: `members`'
                // viewRule is `@request.auth.id = id`, so only the record's own
                // owner can view it. /api/health would be a hollow proof here --
                // it has no auth check at all, so it would pass with any (or no)
                // token.
                val ownRecord = members.getOne(memberId)
                assertEquals(memberId, ownRecord.id)

                // ... and the same rule denies the SAME record to an anonymous
                // caller, so the assertion above has teeth (it isn't just "any
                // token works"). View denial never reveals existence -> 404, not 403.
                ZigbaseClient(server.baseUrl).use { anon ->
                    val ex = assertThrowsSuspend<ZigbaseException> { anon.collection("members").getOne(memberId) }
                    assertEquals(404, ex.status)
                }
            }
        }

    @Test
    fun testLogoutClearsStore() =
        runBlocking {
            val (email, password) = seedMember("member-pass-3")

            ZigbaseClient(server.baseUrl).use { client ->
                val members = client.collection("members")
                members.authWithPassword(email, password)
                assertNotNull(client.authStore.token)

                members.logout()
                assertNull(client.authStore.token)
                assertNull(client.authStore.record)
            }
        }

    @Test
    fun testMultipartFileUploadAndFetchBytes() =
        runBlocking {
            ZigbaseClient(server.baseUrl).use { client ->
                val posts = client.collection("posts")
                val content = "hello-file".toByteArray()
                val created =
                    posts.create(
                        mapOf(
                            "title" to "With cover",
                            "cover" to FileArg.Bytes("cover.txt", content),
                        ),
                    )
                val coverName = created.getString("cover")
                assertNotNull(coverName)
                assertTrue(coverName!!.isNotEmpty())

                // The create response doesn't echo collectionId/collectionName
                // (only client-SDK codegen adds those; the plain HTTP API never
                // does), so `files.getUrl(record, ...)` would throw here --
                // build the URL from the explicit (collection, recordId,
                // filename) triple instead, matching the Python/Dart ports'
                // same workaround.
                val url = client.files.getUrlFor("posts", created.id, coverName)

                // Plain ktor GET, deliberately bypassing the SDK's own Transport
                // -- proves the URL is independently fetchable (no auth needed
                // for a @public collection's file), and that the server stored
                // the exact bytes uploaded.
                val plainHttp = HttpClient(CIO)
                try {
                    val response: HttpResponse = plainHttp.get(url)
                    assertEquals(HttpStatusCode.OK, response.status)
                    assertArrayEquals(content, response.body<ByteArray>())
                } finally {
                    plainHttp.close()
                }
            }
        }
}
