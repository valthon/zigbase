package io.github.valthon.zigbase.codegen.dating

import io.github.valthon.zigbase.ZigbaseClient
import io.github.valthon.zigbase.auth.MemoryAuthStore
import io.ktor.client.HttpClient
import io.ktor.client.engine.mock.MockEngine
import io.ktor.client.engine.mock.MockRequestHandleScope
import io.ktor.client.engine.mock.respond
import io.ktor.client.engine.mock.toByteArray
import io.ktor.client.request.HttpRequestData
import io.ktor.client.request.HttpResponseData
import kotlinx.coroutines.test.runTest
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Behavior coverage for the generated BEHAVIOR half (Task 6: `<Rec>Fields`
 * builders, `CollectionMeta`, typed services, `ZbClient`) — exercises the
 * actual wire path via a ktor `MockEngine`, unlike [GoldenDataTest]'s pure
 * `fromRecord`/`toMap` unit checks. `gradle build` already COMPILES the
 * golden; this proves the generated services correctly drive `TypedCollection`/
 * `ZigbaseClient` end to end: a `where` lambda compiles into the request's
 * `filter` query param, `create` sends `toMap()`'s output as the body, a
 * nested relation filter compiles a dotted path, and the auth graft hits the
 * real auth endpoint.
 */
class GoldenBehaviorTest {
    private fun makeClient(handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData): ZbClient {
        val engine = MockEngine(handler)
        val raw = ZigbaseClient("http://api.test", authStore = MemoryAuthStore(), httpClient = HttpClient(engine))
        return ZbClient(raw, owned = true)
    }

    private fun profileJson(id: String = "prof1"): String =
        """{"id":"$id","email":"a@example.com","username":"annie","verified":true,"name":"Annie",""" +
            """"bio":"hi","website":"https://example.com","age":27,"gender":"female","avatar":"a.png",""" +
            """"created":"2024-01-01 00:00:00.000Z","updated":"2024-01-01 00:00:00.000Z"}"""

    @Test
    fun `getList maps items through fromRecord into typed Profile instances`() =
        runTest {
            val client =
                makeClient {
                    respond("""{"page":1,"perPage":30,"totalItems":1,"totalPages":1,"items":[${profileJson()}]}""")
                }

            val result = client.profiles.getList()

            assertEquals(1, result.items.size)
            val profile = result.items[0]
            assertEquals("prof1", profile.id)
            assertEquals(27L, profile.age)
            assertEquals(ProfileGender.FEMALE, profile.gender)
        }

    @Test
    fun `a where lambda compiles into the sent filter query param`() =
        runTest {
            var seen: HttpRequestData? = null
            val client =
                makeClient { request ->
                    seen = request
                    respond("""{"items":[]}""")
                }

            client.profiles.getList(where = { it.age gt 18 })

            assertEquals("age > 18", seen!!.url.parameters["filter"])
        }

    @Test
    fun `create sends the toMap output as the request body`() =
        runTest {
            var seenBody: String? = null
            val client =
                makeClient { request ->
                    seenBody = request.body.toByteArray().decodeToString()
                    respond(profileJson())
                }

            client.profiles.create(
                ProfileCreate(
                    email = "b@example.com",
                    password = "secret123",
                    passwordConfirm = "secret123",
                    name = "Bea",
                ),
            )

            assertTrue(seenBody!!.contains(""""email":"b@example.com""""))
            assertTrue(seenBody.contains(""""name":"Bea""""))
            // Unset optional fields are omitted entirely, not sent as explicit nulls.
            assertTrue(!seenBody.contains("bio"))
        }

    @Test
    fun `a nested rel filter compiles a dotted path`() =
        runTest {
            var seen: HttpRequestData? = null
            val client =
                makeClient { request ->
                    seen = request
                    respond("""{"items":[]}""")
                }

            client.photos.getList(where = { it.owner.rel { p -> p.name eq "Annie" } })

            assertEquals("owner.name = 'Annie'", seen!!.url.parameters["filter"])
        }

    @Test
    fun `authWithPassword hits the auth-with-password endpoint`() =
        runTest {
            var seenPath: String? = null
            val client =
                makeClient { request ->
                    seenPath = request.url.encodedPath
                    respond("""{"token":"tok","record":${profileJson()}}""")
                }

            val auth = client.profiles.authWithPassword("a@example.com", "secret123")

            assertEquals("/api/collections/profiles/auth-with-password", seenPath)
            assertEquals("tok", auth.token)
        }
}
