package io.github.valthon.zigbase.integration

import io.github.valthon.zigbase.FileArg
import io.github.valthon.zigbase.codegen.dating.Photo
import io.github.valthon.zigbase.codegen.dating.PhotoCreate
import io.github.valthon.zigbase.codegen.dating.PhotoFields
import io.github.valthon.zigbase.codegen.dating.PhotoUpdate
import io.github.valthon.zigbase.codegen.dating.PrivatePhotoCreate
import io.github.valthon.zigbase.codegen.dating.PrivatePhotoFileField
import io.github.valthon.zigbase.codegen.dating.Profile
import io.github.valthon.zigbase.codegen.dating.ProfileCreate
import io.github.valthon.zigbase.codegen.dating.ProfileFileField
import io.github.valthon.zigbase.codegen.dating.ProfileUpdate
import io.github.valthon.zigbase.codegen.dating.SubscriptionCreate
import io.github.valthon.zigbase.codegen.dating.SubscriptionPlan
import io.github.valthon.zigbase.codegen.dating.TagCreate
import io.github.valthon.zigbase.codegen.dating.ZbClient
import io.github.valthon.zigbase.codegen.dating.createClient
import io.github.valthon.zigbase.errors.ZigbaseException
import io.github.valthon.zigbase.typed.TypedRealtimeEvent
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.request.get
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpStatusCode
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.junit.jupiter.api.AfterAll
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNotEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.BeforeAll
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Timeout
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Typed-tier e2e: drives the GENERATED dating client
 * (`src/test/kotlin/io/github/valthon/zigbase/codegen/dating/ZbaseGen.kt`) --
 * `ZbClient`/`ProfilesService`/`PhotosService`/etc. -- against a real
 * `dating-server` process (the dating fixture, schema comptime-baked in).
 * Mirrors `clients/python/tests/integration/test_typed_dating_live.py` and
 * `clients/dart/test/integration/typed_dating_test.dart`.
 *
 * Skipped as a whole (JUnit5 "aborted", not "failed") when
 * `ZIGBASE_TEST_DATING_BINARY` is unset -- see [requireDatingBinaryOrSkip].
 * The dating fixture's schema is comptime (baked into the binary), so unlike
 * [LiveIntegrationTest] this class seeds no collections of its own -- the
 * server is ready to use as soon as it is healthy.
 *
 * Every test follows the full-shape-plus-negative-control discipline the
 * other live suites in this module established: an assertion that could pass
 * by accident (a filter matched, an event arrived, a file was gated) is
 * paired with a negative control that would fail if the assertion were
 * vacuous (a second, non-matching owner/caption/token that must NOT show up
 * in the result).
 */
@Timeout(value = 60, unit = TimeUnit.SECONDS)
class TypedDatingLiveTest {
    companion object {
        private lateinit var server: LaunchedServer
        private val seq = AtomicInteger(0)

        @JvmStatic
        @BeforeAll
        fun setUpAll() {
            val binary = requireDatingBinaryOrSkip()
            server = startServer(binary)
        }

        @JvmStatic
        @AfterAll
        fun tearDownAll() {
            if (::server.isInitialized) server.stop()
        }

        /** A globally-unique suffix for this class's whole run -- guards every
         * name/email/caption built below against cross-test substring collisions
         * (e.g. a `like` filter on one profile's name accidentally matching
         * another test's fixture data). */
        private fun uniqueId(): Int = seq.getAndIncrement()

        private fun uniqueEmail(tag: String): String = "$tag${uniqueId()}@d.app"

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

        /** Public signup (`profiles.createRule = "@public"`) then password auth. */
        private suspend fun registerAndAuth(
            zb: ZbClient,
            tag: String,
            age: Long = 25,
        ): Profile {
            val email = uniqueEmail(tag)
            val password = "member-pass-1"
            val profile =
                zb.profiles.create(
                    ProfileCreate(
                        email = email,
                        password = password,
                        passwordConfirm = password,
                        name = email.substringBefore("@"),
                        age = age,
                    ),
                )
            zb.profiles.authWithPassword(email, password)
            return profile
        }
    }

    @Test
    fun testTypedGetListSmoke() =
        runBlocking {
            // Harness-first smoke test: a typed getList against the live server,
            // unauthenticated, on a @public-listed collection.
            createClient(server.baseUrl).use { zb ->
                val page = zb.tags.getList()
                assertEquals(1, page.page)
            }
        }

    @Test
    fun testAuthWithPasswordStoresRealTokenProvenByAuthGatedWrite() =
        runBlocking {
            createClient(server.baseUrl).use { zb ->
                val email = uniqueEmail("auth")
                val password = "member-pass-1"
                val profile =
                    zb.profiles.create(
                        ProfileCreate(
                            email = email,
                            password = password,
                            passwordConfirm = password,
                            name = email.substringBefore("@"),
                            age = 30,
                        ),
                    )

                // Negative control FIRST: privatePhotos.create requires auth
                // (`@request.auth.id != ""`) -- before authenticating, the same
                // call this test proves succeeds below must be rejected.
                val denied =
                    assertThrowsSuspend<ZigbaseException> {
                        zb.privatePhotos.create(PrivatePhotoCreate(owner = profile.id, caption = "nope"))
                    }
                assertEquals(403, denied.status)

                val auth = zb.profiles.authWithPassword(email, password)
                assertTrue(auth.token.isNotEmpty())
                assertEquals(
                    auth.token,
                    zb.authStore.token,
                    "authWithPassword must store the returned token in the client's authStore",
                )

                // The stored token genuinely authenticates -- the SAME call denied
                // above now succeeds, proving this isn't just "some string got set".
                val created = zb.privatePhotos.create(PrivatePhotoCreate(owner = profile.id, caption = "now-allowed"))
                assertTrue(created.id.isNotEmpty())
            }
        }

    @Test
    fun testCrudNestedRelationFilterExpandAndCursorPaging() =
        runBlocking {
            createClient(server.baseUrl).use { zb ->
                val profile = registerAndAuth(zb, "ann", age = 25)

                // Int coercion: age is an int-mode number field. `Profile.age`'s
                // static type is already `Long` (Kotlin, unlike Python/Dart, proves
                // this at compile time), so the live-value check below is what
                // actually exercises the wire-to-Long coercion path.
                assertEquals(25L, profile.age)

                val hiking = zb.tags.create(TagCreate(label = "hiking"))
                val coffee = zb.tags.create(TagCreate(label = "coffee"))

                val p1 = zb.photos.create(PhotoCreate(owner = profile.id, caption = "trail", tags = listOf(hiking.id, coffee.id)))
                val p2 = zb.photos.create(PhotoCreate(owner = profile.id, caption = "espresso", tags = listOf(coffee.id)))
                assertTrue(p1.id.isNotEmpty())

                // Negative control: a second profile with its own photo. Without
                // a second owner in play, a broken or silently-ignored filter
                // (e.g. one that compiles to a vacuous `1=1`) would pass every
                // assertion below just as well as a correct one.
                val other = registerAndAuth(zb, "bob", age = 30)
                val otherPhoto = zb.photos.create(PhotoCreate(owner = other.id, caption = "not-mine"))
                val knownPhotoIds = setOf(p1.id, p2.id, otherPhoto.id)

                // Nested-relation filter via the typed fluent builder: owner.name ~ '...'.
                val byOwner = zb.photos.getList(where = { it.owner.rel { o -> o.name like profile.name } })
                val byOwnerIds = byOwner.items.map { it.id }.toSet()
                assertTrue(byOwnerIds.size < knownPhotoIds.size, "expected the filter to exclude otherPhoto")
                assertEquals(setOf(p1.id, p2.id), byOwnerIds)

                // Expand single (owner -> Profile) and multi (tags -> Tag[]).
                val withOwner = zb.photos.getOne(p1.id, expand = listOf("owner"))
                assertEquals(profile.id, withOwner.expand.owner?.id)

                val withTags = zb.photos.getOne(p1.id, expand = listOf("tags"))
                assertEquals(
                    listOf("coffee", "hiking"),
                    withTags.expand.tags
                        .map { it.label }
                        .sorted(),
                )

                // Update + delete.
                val updated = zb.photos.update(p1.id, PhotoUpdate(caption = "summit"))
                assertEquals("summit", updated.caption)
                zb.photos.delete(p1.id)
                // otherPhoto (still live, owned by `other`) is the negative control here
                // too: a broken/ignored filter would return it alongside p2.
                val remaining = zb.photos.getList(where = { it.owner eq profile.id })
                assertEquals(1, remaining.items.size)
                assertEquals(p2.id, remaining.items[0].id)

                // Native cursor: walk two freshly-created tags one per page. Two
                // records created back-to-back can land on the same `created`
                // timestamp (autodate resolution), so which of the two sorts
                // first is not asserted -- only that a `nextCursor` genuinely
                // advances to a DIFFERENT record, round-tripping the cursor
                // itself (matching the Python/Dart ports' same restraint here).
                val t3 = zb.tags.create(TagCreate(label = "t3-${uniqueId()}"))
                val t4 = zb.tags.create(TagCreate(label = "t4-${uniqueId()}"))
                val page1 = zb.tags.getPage(sort = listOf("-created"), limit = 1)
                assertEquals(1, page1.items.size)
                assertTrue(page1.hasNext)
                val page2 = zb.tags.getPage(sort = listOf("-created"), limit = 1, cursor = page1.nextCursor)
                assertEquals(1, page2.items.size)
                // The cursor genuinely advanced to a DIFFERENT record. Which id
                // lands on which page is deliberately NOT asserted: all the tags
                // in this collection can share a `created` tick (autodate
                // resolution) when the test runs sub-second, and `-created` then
                // tie-breaks by id, so no page's `items[0]` is guaranteed to be
                // t3/t4 -- matching the Python/Dart ports' same restraint.
                assertNotEquals(page1.items[0].id, page2.items[0].id)
            }
        }

    @Test
    fun testIntAndFixedCoercionRoundTrip() =
        runBlocking {
            createClient(server.baseUrl).use { zb ->
                val profile = registerAndAuth(zb, "fixed")

                val sub =
                    zb.subscriptions.create(
                        SubscriptionCreate(
                            profile = profile.id,
                            plan = SubscriptionPlan.PREMIUM,
                            // fixed(2): encoded as "9.99" on write, parsed back to a Double.
                            price = 9.99,
                            renewsAt = "2026-01-01 00:00:00.000Z",
                            active = true,
                        ),
                    )
                assertEquals(9.99, sub.price)
                assertEquals(SubscriptionPlan.PREMIUM, sub.plan)
                assertTrue(sub.active)

                val read = zb.subscriptions.getOne(sub.id)
                assertEquals(9.99, read.price)
            }
        }

    @Test
    fun testTypedRealtimeCreateEventWithFilteredNegativeControl() =
        runBlocking {
            createClient(server.baseUrl).use { zb ->
                val profile = registerAndAuth(zb, "rt")
                val matchCaption = "rt-match-${uniqueId()}"
                val noMatchCaption = "rt-nomatch-${uniqueId()}"

                val events = Channel<TypedRealtimeEvent<Photo>>(Channel.UNLIMITED)
                // Typed filter delivery: subscribe with a `where` Expr that only
                // matches `matchCaption`, not just the bare collection topic.
                val filterExpr = PhotoFields().caption eq matchCaption
                val unsub = zb.photosRealtime.subscribe(where = filterExpr) { ev -> events.trySend(ev) }
                try {
                    // Negative control FIRST: a non-matching caption must not be
                    // delivered to this filtered subscription.
                    zb.photos.create(PhotoCreate(owner = profile.id, caption = noMatchCaption))
                    assertNull(
                        withTimeoutOrNull(1_500) { events.receive() },
                        "a non-matching create must not be delivered to a filtered typed subscription",
                    )

                    val made = zb.photos.create(PhotoCreate(owner = profile.id, caption = matchCaption))
                    val event = withTimeout(10_000) { events.receive() }
                    assertEquals("create", event.action)
                    assertEquals(made.id, event.record.id)
                    // The event's record went through the same fromRecord coercion as a
                    // regular REST response -- check a plain field survives it too, not
                    // just the id.
                    assertEquals(matchCaption, event.record.caption)
                } finally {
                    unsub()
                }
            }
        }

    @Test
    fun testFilesPublicAvatarAndGatedPrivatePhoto() =
        runBlocking {
            createClient(server.baseUrl).use { zb ->
                val profile = registerAndAuth(zb, "files")

                // Public avatar on the (public) profile -- fileUrl is fetchable anonymously.
                val withAvatar =
                    zb.profiles.update(
                        profile.id,
                        ProfileUpdate(avatar = FileArg.Bytes("a.png", byteArrayOf(1, 2, 3, 4))),
                    )
                val avatarUrl = zb.profiles.fileUrl(withAvatar, field = ProfileFileField.AVATAR)
                val plainHttp = HttpClient(CIO)
                try {
                    val pub: HttpResponse = plainHttp.get(avatarUrl)
                    assertEquals(HttpStatusCode.OK, pub.status)

                    // Private photo: owner-only view -- the image file is gated by the viewRule.
                    val priv =
                        zb.privatePhotos.create(
                            PrivatePhotoCreate(
                                owner = profile.id,
                                image = FileArg.Bytes("secret.png", byteArrayOf(5, 6, 7, 8)),
                                caption = "hidden",
                            ),
                        )
                    val privUrlNoTok = zb.privatePhotos.fileUrl(priv, field = PrivatePhotoFileField.IMAGE)
                    val anon: HttpResponse = plainHttp.get(privUrlNoTok)
                    assertNotEquals(HttpStatusCode.OK, anon.status)

                    // With a fresh file-access token (owner is authed), the file is fetchable.
                    val token = zb.raw.files.getToken()
                    val privUrlTok = zb.privatePhotos.fileUrl(priv, field = PrivatePhotoFileField.IMAGE, token = token)
                    val ok: HttpResponse = plainHttp.get(privUrlTok)
                    assertEquals(HttpStatusCode.OK, ok.status)
                } finally {
                    plainHttp.close()
                }
            }
        }
}
