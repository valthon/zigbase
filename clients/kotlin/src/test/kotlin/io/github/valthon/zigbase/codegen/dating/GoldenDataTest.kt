package io.github.valthon.zigbase.codegen.dating

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Test

/**
 * Sanity coverage for the generated DATA half (`ZbaseGen.kt`, produced by
 * `zig build gen-dating-kotlin-client` from `fixtures/dating/schema.zig`).
 * `gradle build` already COMPILES the golden (it lives in `src/test`) — the
 * stronger validity guarantee Python's import-only golden test lacks. This
 * test additionally exercises `fromRecord`/`toMap` behavior: member TYPES
 * (`Long`/`Double`/enum), and `toMap`'s fixed-scale rendering.
 */
class GoldenDataTest {
    private fun profileJson(
        age: Long = 27,
        gender: String? = "female",
    ): JsonObject =
        buildJsonObject {
            put("id", "prof1")
            put("email", "a@example.com")
            put("username", "annie")
            put("verified", true)
            put("name", "Annie")
            put("bio", "hello")
            put("website", "https://example.com")
            put("age", age)
            if (gender != null) put("gender", gender)
            put("avatar", "avatar.png")
            put("created", "2024-01-01 00:00:00.000Z")
            put("updated", "2024-01-01 00:00:00.000Z")
        }

    @Test
    fun `fromRecord coerces int-mode and select fields to the right Kotlin types`() {
        val profile = Profile.fromRecord(profileJson())

        // `age` (number, mode=int) must coerce to a Kotlin Long, not Double/String.
        val age: Long = profile.age
        assertEquals(27L, age)

        // `gender` (select) must coerce to the generated enum, not a raw String.
        val gender: ProfileGender? = profile.gender
        assertEquals(ProfileGender.FEMALE, gender)
        assertEquals("female", gender?.wire)
    }

    @Test
    fun `fromRecord maps an unset select to null (no matching enum variant)`() {
        val profile = Profile.fromRecord(profileJson(gender = null))
        assertNull(profile.gender)
    }

    @Test
    fun `SubscriptionCreate toMap renders a fixed-scale price as a half-up decimal string`() {
        // `price` (number, mode=fixed, scale=2) must render as a decimal STRING on
        // the wire (not a raw Double), matching the server's fixed-point transport.
        val payload = SubscriptionCreate(price = 9.99)
        val map = payload.toMap()

        assertEquals("9.99", map["price"])
        // Fields left unset are OMITTED entirely, not sent as explicit nulls.
        assertEquals(false, map.containsKey("profile"))
        assertEquals(false, map.containsKey("plan"))
    }

    @Test
    fun `SubscriptionCreate toMap serializes the select enum via its wire value`() {
        val payload = SubscriptionCreate(plan = SubscriptionPlan.PREMIUM)
        assertEquals("premium", payload.toMap()["plan"])
    }
}
