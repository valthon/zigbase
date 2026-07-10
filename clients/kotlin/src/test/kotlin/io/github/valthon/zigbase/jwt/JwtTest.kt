package io.github.valthon.zigbase.jwt

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.nio.charset.StandardCharsets
import java.util.Base64

private fun b64url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

private fun b64url(text: String): String = b64url(text.toByteArray(StandardCharsets.UTF_8))

/** Hand-assembles a JWT (unsigned "sig" segment) from a JSON payload body. */
private fun makeJwt(payloadJson: String): String {
    val header = b64url("""{"alg":"HS256","typ":"JWT"}""")
    val body = b64url(payloadJson)
    return "$header.$body.sig"
}

class DecodeJwtPayloadTest {
    @Test
    fun `round-trips a hand-built token`() {
        val token = makeJwt("""{"id":"u1","exp":9999999999}""")
        val payload = decodeJwtPayload(token)
        assertTrue(payload != null)
        assertEquals("u1", payload!!["id"]!!.jsonPrimitive.content)
        assertEquals(9999999999L, payload["exp"]!!.jsonPrimitive.content.toLong())
    }

    @Test
    fun `decodes the payload segment`() {
        val token = makeJwt("""{"id":"u1","collection":"users","exp":9999999999}""")
        val payload = decodeJwtPayload(token)
        assertTrue(payload != null)
        assertEquals("u1", payload!!["id"]!!.jsonPrimitive.content)
        assertEquals("users", payload["collection"]!!.jsonPrimitive.content)
    }

    @Test
    fun `returns null for malformed tokens`() {
        assertNull(decodeJwtPayload("not-a-jwt"))
        assertNull(decodeJwtPayload(""))
        assertNull(decodeJwtPayload("a.b"))
        assertNull(decodeJwtPayload("a..c"))
        assertNull(decodeJwtPayload("a.!!!notbase64.c"))
    }

    @Test
    fun `returns null when the payload is not a JSON object`() {
        val token = makeJwt("[1,2,3]")
        assertNull(decodeJwtPayload(token))
    }

    @Test
    fun `returns null for a payload segment that is not valid UTF-8`() {
        // A lone 0xC3 continuation-starter byte with no follow-up byte is not
        // valid UTF-8 on its own.
        val invalidUtf8 = byteArrayOf(0xC3.toByte())
        val token = "header.${b64url(invalidUtf8)}.sig"
        assertNull(decodeJwtPayload(token))
    }
}

class IsTokenExpiredTest {
    @Test
    fun `false for a far-future exp`() {
        val token = makeJwt("""{"exp":1000}""")
        assertFalse(isTokenExpired(token, nowEpochSeconds = { 500L }))
    }

    @Test
    fun `true for a past exp`() {
        val token = makeJwt("""{"exp":1000}""")
        assertTrue(isTokenExpired(token, nowEpochSeconds = { 2000L }))
    }

    @Test
    fun `true for a missing exp`() {
        val token = makeJwt("""{"id":"u1"}""")
        assertTrue(isTokenExpired(token, nowEpochSeconds = { 500L }))
    }

    @Test
    fun `true for a malformed token`() {
        assertTrue(isTokenExpired("garbage"))
    }

    @Test
    fun `leeway pushes a near-future exp into expired`() {
        val token = makeJwt("""{"exp":1005}""")
        assertTrue(isTokenExpired(token, leewaySeconds = 30, nowEpochSeconds = { 1000L }))
        assertFalse(isTokenExpired(token, nowEpochSeconds = { 1000L }))
    }

    @Test
    fun `true for a boolean exp claim`() {
        val payload: JsonObject = buildJsonObject { put("exp", JsonPrimitive(true)) }
        val token = "header.${b64url(payload.toString())}.sig"
        assertTrue(isTokenExpired(token, nowEpochSeconds = { 500L }))
    }
}
