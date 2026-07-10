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
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Tests for [CollectionService]'s auth surface, mirroring
 * `clients/python/tests/test_collection_auth.py`.
 */
class CollectionServiceAuthTest {
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
        name: String = "users",
        authStore: MemoryAuthStore = MemoryAuthStore(),
        handler: suspend MockRequestHandleScope.(HttpRequestData) -> HttpResponseData,
    ): CollectionService {
        val engine = MockEngine(handler)
        val transport = Transport("http://api.test", authStore, httpClient = HttpClient(engine))
        return CollectionService(transport, name)
    }

    // --- authWithPassword -------------------------------------------------------

    @Test
    fun `authWithPassword posts skipAuth, sends no bearer, and saves token and record`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("stale-token", buildJsonObject { put("id", "old") })
            var seen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    seen = request
                    respond("""{"token":"new-token","record":{"id":"u1","email":"a@b.com"}}""")
                }

            val res = service.authWithPassword("a@b.com", "secret")

            assertEquals(HttpMethod.Post, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/auth-with-password"))
            assertEquals("""{"identity":"a@b.com","password":"secret"}""", seen!!.body.toByteArray().decodeToString())
            assertNull(seen!!.headers["Authorization"])
            assertEquals("new-token", res.token)
            assertEquals("u1", res.record?.id)
            assertEquals("new-token", store.token)
            assertEquals("u1", store.record?.get("id")?.let { (it as JsonPrimitive).content })
        }

    @Test
    fun `authWithPassword raises when token is missing`() =
        runTest {
            val service = makeService { respond("""{"record":{"id":"u1"}}""") }
            val ex = assertFailsWithSuspend<ZigbaseException> { service.authWithPassword("a@b.com", "secret") }
            assertEquals(0, ex.status)
            assertTrue(ex.message.contains("token"))
        }

    @Test
    fun `authWithPassword raises when token is not a string`() =
        runTest {
            val service = makeService { respond("""{"token":12345,"record":{"id":"u1"}}""") }
            val ex = assertFailsWithSuspend<ZigbaseException> { service.authWithPassword("a@b.com", "secret") }
            assertEquals(0, ex.status)
            assertTrue(ex.message.contains("token"))
        }

    @Test
    fun `authWithPassword raises a clear error on a non-object body`() =
        runTest {
            val service = makeService { respond("", HttpStatusCode.NoContent) }
            val ex = assertFailsWithSuspend<ZigbaseException> { service.authWithPassword("a@b.com", "secret") }
            assertEquals(0, ex.status)
            assertTrue(ex.message.contains("JSON object"))
        }

    // --- authRefresh --------------------------------------------------------------

    @Test
    fun `authRefresh carries bearer and is exempt from the single-flight refresh loop`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("old-token", null)
            var calls = 0
            var seen: HttpRequestData? = null
            val engine =
                MockEngine { request ->
                    calls += 1
                    seen = request
                    respond("", HttpStatusCode.Unauthorized)
                }
            val transport =
                Transport(
                    "http://api.test",
                    store,
                    authCollection = "users",
                    autoRefresh = true,
                    httpClient = HttpClient(engine),
                )
            val service = CollectionService(transport, "users")

            val ex = assertFailsWithSuspend<ZigbaseException> { service.authRefresh() }

            assertEquals(401, ex.status)
            assertEquals(1, calls)
            assertEquals("Bearer old-token", seen!!.headers["Authorization"])
        }

    @Test
    fun `authRefresh posts empty body and saves the response`() =
        runTest {
            val store = MemoryAuthStore()
            var seen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    seen = request
                    respond("""{"token":"refreshed","record":{"id":"u1"}}""")
                }

            val res = service.authRefresh()

            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/auth-refresh"))
            assertEquals("{}", seen!!.body.toByteArray().decodeToString())
            assertEquals("refreshed", res.token)
            assertEquals("refreshed", store.token)
        }

    @Test
    fun `authRefresh raises when token is missing`() =
        runTest {
            val service = makeService { respond("""{"record":{"id":"u1"}}""") }
            val ex = assertFailsWithSuspend<ZigbaseException> { service.authRefresh() }
            assertEquals(0, ex.status)
            assertTrue(ex.message.contains("token"))
        }

    // --- listAuthProviders / oauth2Init ------------------------------------------

    @Test
    fun `listAuthProviders unwraps items`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"items":[{"name":"google","authURL":"https://g/auth","clientId":"cid"}]}""")
                }

            val providers = service.listAuthProviders()

            assertEquals(HttpMethod.Get, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/auth/oauth2/providers"))
            assertEquals(1, providers.size)
            assertEquals("google", (providers[0]["name"] as JsonPrimitive).content)
        }

    @Test
    fun `listAuthProviders raises a clear error on a non-object body`() =
        runTest {
            val service = makeService { respond("", HttpStatusCode.NoContent) }
            val ex = assertFailsWithSuspend<ZigbaseException> { service.listAuthProviders() }
            assertEquals(0, ex.status)
            assertTrue(ex.message.contains("JSON object"))
        }

    @Test
    fun `oauth2Init posts provider and returns the raw object`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"authURL":"https://p/auth","clientId":"cid","scopes":["a","b"],"state":"st"}""")
                }

            val res = service.oauth2Init("google")

            assertEquals(HttpMethod.Post, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/auth/oauth2/initiate"))
            assertEquals("""{"provider":"google"}""", seen!!.body.toByteArray().decodeToString())
            assertEquals("cid", (res["clientId"] as JsonPrimitive).content)
        }

    // --- authWithOAuth2 ------------------------------------------------------------

    @Test
    fun `authWithOAuth2 posts exact body, skipAuth, and saves token only`() =
        runTest {
            val store = MemoryAuthStore()
            var seen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    seen = request
                    respond("""{"token":"oauth-token"}""")
                }

            val res =
                service.authWithOAuth2(
                    provider = "google",
                    code = "c",
                    codeVerifier = "v",
                    redirectUrl = "https://app/cb",
                    state = "s1",
                )

            assertEquals(HttpMethod.Post, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/auth/oauth2/complete"))
            assertEquals(
                """{"provider":"google","code":"c","codeVerifier":"v","redirectUrl":"https://app/cb","state":"s1"}""",
                seen!!.body.toByteArray().decodeToString(),
            )
            assertNull(seen!!.headers["Authorization"])
            assertEquals("oauth-token", res.token)
            assertNull(res.record)
            assertNull(res.meta)
            assertEquals("oauth-token", store.token)
            assertNull(store.record)
        }

    @Test
    fun `authWithOAuth2 omits state when not provided`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("""{"token":"t"}""")
                }

            service.authWithOAuth2(provider = "google", code = "c", codeVerifier = "v", redirectUrl = "https://app/cb")

            assertFalse(
                seen!!
                    .body
                    .toByteArray()
                    .decodeToString()
                    .contains("state"),
            )
        }

    @Test
    fun `authWithOAuth2 raises when token is missing`() =
        runTest {
            val service = makeService { respond("{}") }
            val ex =
                assertFailsWithSuspend<ZigbaseException> {
                    service.authWithOAuth2(provider = "google", code = "c", codeVerifier = "v", redirectUrl = "https://app/cb")
                }
            assertEquals(0, ex.status)
            assertTrue(ex.message.contains("token"))
        }

    @Test
    fun `authWithOAuth2 raises when token is not a string`() =
        runTest {
            val service = makeService { respond("""{"token":12345}""") }
            val ex =
                assertFailsWithSuspend<ZigbaseException> {
                    service.authWithOAuth2(provider = "google", code = "c", codeVerifier = "v", redirectUrl = "https://app/cb")
                }
            assertEquals(0, ex.status)
            assertTrue(ex.message.contains("token"))
        }

    // --- logout ----------------------------------------------------------------------

    @Test
    fun `logout posts and clears the store`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("t", buildJsonObject { put("id", "u1") })
            var seen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }

            service.logout()

            assertEquals(HttpMethod.Post, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/auth-logout"))
            assertNull(store.token)
            assertNull(store.record)
        }

    @Test
    fun `logout clears the store even when the request fails with 500`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("t", buildJsonObject { put("id", "u1") })
            val service =
                makeService(authStore = store) { respond("""{"message":"boom"}""", HttpStatusCode.InternalServerError) }

            assertFailsWithSuspend<ZigbaseException> { service.logout() }

            assertNull(store.token)
            assertNull(store.record)
        }

    // --- verification / password reset ------------------------------------------------

    @Test
    fun `requestVerification posts email and is not skipAuth`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("t", null)
            var seen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }

            service.requestVerification("a@b.com")

            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/request-verification"))
            assertEquals("""{"email":"a@b.com"}""", seen!!.body.toByteArray().decodeToString())
            assertEquals("Bearer t", seen!!.headers["Authorization"])
        }

    @Test
    fun `confirmVerification posts token and is skipAuth`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("t", null)
            var seen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }

            service.confirmVerification("vtok")

            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/confirm-verification"))
            assertEquals("""{"token":"vtok"}""", seen!!.body.toByteArray().decodeToString())
            assertNull(seen!!.headers["Authorization"])
        }

    @Test
    fun `requestPasswordReset posts email and is not skipAuth`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("t", null)
            var seen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }

            service.requestPasswordReset("a@b.com")

            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/request-password-reset"))
            assertEquals("Bearer t", seen!!.headers["Authorization"])
        }

    @Test
    fun `confirmPasswordReset posts token and password and is skipAuth`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("t", null)
            var seen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }

            service.confirmPasswordReset("rtok", "newpass")

            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/confirm-password-reset"))
            assertEquals("""{"token":"rtok","password":"newpass"}""", seen!!.body.toByteArray().decodeToString())
            assertNull(seen!!.headers["Authorization"])
        }

    // --- changePassword ----------------------------------------------------------------

    @Test
    fun `changePassword patches the record with no re-auth for a non-principal target`() =
        runTest {
            val store = MemoryAuthStore()
            store.save(
                "t",
                buildJsonObject {
                    put("id", "someone-else")
                    put("email", "x@y.com")
                },
            )
            var calls = 0
            val service =
                makeService(authStore = store) {
                    calls += 1
                    respond("""{"id":"target","email":"z@z.com"}""")
                }

            val rec = service.changePassword("target", "oldpw", "newpw")

            assertEquals(1, calls)
            assertEquals("target", rec.id)
        }

    @Test
    fun `changePassword re-authenticates with the email identity when self`() =
        runTest {
            val store = MemoryAuthStore()
            store.save(
                "t",
                buildJsonObject {
                    put("id", "target")
                    put("email", "z@z.com")
                    put("username", "zed")
                },
            )
            var calls = 0
            var reauthSeen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    calls += 1
                    if (calls == 1) {
                        respond("""{"id":"target","email":"z@z.com"}""")
                    } else {
                        reauthSeen = request
                        respond("""{"token":"re-token","record":{"id":"target","email":"z@z.com"}}""")
                    }
                }

            val rec = service.changePassword("target", "oldpw", "newpw")

            assertEquals(2, calls)
            assertTrue(reauthSeen!!.url.encodedPath.endsWith("/api/collections/users/auth-with-password"))
            assertEquals(
                """{"identity":"z@z.com","password":"newpw"}""",
                reauthSeen!!.body.toByteArray().decodeToString(),
            )
            assertEquals("target", rec.id)
            assertEquals("re-token", store.token)
        }

    @Test
    fun `changePassword falls back to the username identity when email is absent`() =
        runTest {
            val store = MemoryAuthStore()
            store.save(
                "t",
                buildJsonObject {
                    put("id", "target")
                    put("username", "zed")
                },
            )
            var calls = 0
            var reauthSeen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    calls += 1
                    if (calls == 1) {
                        respond("""{"id":"target","username":"zed"}""")
                    } else {
                        reauthSeen = request
                        respond("""{"token":"re-token","record":{"id":"target"}}""")
                    }
                }

            service.changePassword("target", "oldpw", "newpw")

            assertEquals(
                """{"identity":"zed","password":"newpw"}""",
                reauthSeen!!.body.toByteArray().decodeToString(),
            )
        }

    @Test
    fun `changePassword does not re-auth when no principal is stored`() =
        runTest {
            var calls = 0
            val service =
                makeService {
                    calls += 1
                    respond("""{"id":"target"}""")
                }

            service.changePassword("target", "oldpw", "newpw")

            assertEquals(1, calls)
        }

    @Test
    fun `changePassword reads the auth store after update completes, not before`() =
        runTest {
            val store = MemoryAuthStore()
            // The store initially holds a DIFFERENT principal -- if
            // changePassword captured the principal before calling
            // update(), it would wrongly skip re-auth.
            store.save("t", buildJsonObject { put("id", "someone-else") })
            var calls = 0
            val service =
                makeService(authStore = store) {
                    calls += 1
                    if (calls == 1) {
                        // Simulate the store changing to the target
                        // principal as a side effect landing during the
                        // PATCH call; changePassword must observe THIS
                        // state, not the one captured before update() ran.
                        store.save(
                            "t",
                            buildJsonObject {
                                put("id", "target")
                                put("email", "z@z.com")
                            },
                        )
                        respond("""{"id":"target","email":"z@z.com"}""")
                    } else {
                        respond("""{"token":"re-token","record":{"id":"target","email":"z@z.com"}}""")
                    }
                }

            service.changePassword("target", "oldpw", "newpw")

            assertEquals(2, calls)
        }

    // --- sessions -------------------------------------------------------------------------

    @Test
    fun `listSessions unwraps items with snake_case keys passed through`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond(
                        "{\"items\":[{\"id\":\"sid1\",\"created\":\"2026-01-01T00:00:00Z\"," +
                            "\"last_seen\":\"2026-01-02T00:00:00Z\",\"user_agent\":\"ua\"," +
                            "\"ip\":\"1.2.3.4\",\"is_current\":true}]}",
                    )
                }

            val sessions = service.listSessions()

            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/auth/sessions"))
            assertEquals(1, sessions.size)
            assertEquals("sid1", (sessions[0]["id"] as JsonPrimitive).content)
            assertEquals("ua", (sessions[0]["user_agent"] as JsonPrimitive).content)
            assertEquals(true, (sessions[0]["is_current"] as JsonPrimitive).booleanOrNull)
        }

    @Test
    fun `revokeSession deletes the encoded session path`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }

            service.revokeSession("sid with space")

            assertEquals(HttpMethod.Delete, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/auth/sessions/sid%20with%20space"))
        }

    @Test
    fun `revokeAllSessions deletes and clears the store on success`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("t", buildJsonObject { put("id", "u1") })
            var seen: HttpRequestData? = null
            val service =
                makeService(authStore = store) { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }

            service.revokeAllSessions()

            assertEquals(HttpMethod.Delete, seen!!.method)
            assertTrue(seen!!.url.encodedPath.endsWith("/api/collections/users/auth/sessions"))
            assertNull(store.token)
        }

    @Test
    fun `revokeAllSessions clears the store even on failure`() =
        runTest {
            val store = MemoryAuthStore()
            store.save("t", buildJsonObject { put("id", "u1") })
            val service =
                makeService(authStore = store) { respond("""{"message":"boom"}""", HttpStatusCode.InternalServerError) }

            assertFailsWithSuspend<ZigbaseException> { service.revokeAllSessions() }

            assertNull(store.token)
        }

    // --- collection name encoding ------------------------------------------------------

    @Test
    fun `auth endpoints percent-encode the collection name`() =
        runTest {
            var seen: HttpRequestData? = null
            val service =
                makeService(name = "weird name/x") { request ->
                    seen = request
                    respond("", HttpStatusCode.NoContent)
                }

            service.requestPasswordReset("a@b.com")

            assertTrue(seen!!.url.encodedPath.contains("weird%20name%2Fx"))
        }
}
