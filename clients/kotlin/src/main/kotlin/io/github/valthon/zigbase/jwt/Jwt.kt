package io.github.valthon.zigbase.jwt

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.Base64

/**
 * Decodes the payload segment of a JWT, without verifying its signature.
 *
 * Port of `decodeJwtPayload` in `clients/typescript/src/jwt.ts`. The client
 * never verifies a token's signature (only the server can, holding the
 * secret); this only reads claims to drive client-side behavior like
 * pre-emptive refresh.
 *
 * Returns `null` for any malformed input: a token that doesn't have exactly
 * three dot-separated segments, an empty payload segment, invalid
 * base64url, a payload segment that isn't valid UTF-8, or a payload that
 * doesn't decode to a JSON object.
 */
fun decodeJwtPayload(token: String): JsonObject? {
    val parts = token.split(".")
    if (parts.size != 3 || parts[1].isEmpty()) return null

    return try {
        val segment = parts[1]
        val padded = segment + "=".repeat((4 - segment.length % 4) % 4)
        val bytes = Base64.getUrlDecoder().decode(padded)

        val decoder =
            StandardCharsets.UTF_8
                .newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
        val text = decoder.decode(ByteBuffer.wrap(bytes)).toString()

        val element = Json.parseToJsonElement(text)
        element as? JsonObject
    } catch (e: Exception) {
        null
    }
}

/**
 * Returns `true` when [token] is expired (or has no readable numeric `exp`
 * claim).
 *
 * Port of `isTokenExpired` in `clients/typescript/src/jwt.ts`. [leewaySeconds]
 * is subtracted from `exp` before comparing to the current time, so a token
 * can be treated as expired slightly before its real expiry (e.g. to
 * account for clock skew or in-flight request latency). [nowEpochSeconds]
 * is injectable so callers (notably tests) can pin "now" instead of racing
 * the system clock; it defaults to the wall clock.
 */
fun isTokenExpired(
    token: String,
    leewaySeconds: Long = 0,
    nowEpochSeconds: () -> Long = { System.currentTimeMillis() / 1000 },
): Boolean {
    val payload = decodeJwtPayload(token) ?: return true
    val exp = payload["exp"] as? JsonPrimitive ?: return true
    // A JSON boolean is a JsonPrimitive too; content.toDoubleOrNull() rejects
    // "true"/"false" as a non-numeric claim, so booleans fall through here.
    if (exp.isString) return true
    val expSeconds = exp.content.toDoubleOrNull() ?: return true

    return expSeconds - leewaySeconds <= nowEpochSeconds()
}
