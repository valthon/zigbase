package io.github.valthon.zigbase.errors

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject

/**
 * A single field-level validation error, as returned in the `data` map of a
 * ZigBase API error response.
 *
 * Port of `FieldError` in `clients/typescript/src/errors.ts`.
 */
data class FieldError(
    val code: String,
    val message: String,
)

/**
 * Thrown when the ZigBase API responds with a non-2xx status.
 *
 * Port of `ZigbaseError` in `clients/typescript/src/errors.ts`. [status] is
 * the HTTP status; `0` is reserved as a client-side sentinel denoting a
 * protocol violation detected locally (e.g. a non-advancing realtime or
 * pagination cursor) rather than an actual server response.
 */
class ZigbaseException(
    val status: Int,
    override val message: String,
    val data: Map<String, FieldError> = emptyMap(),
    val url: String,
) : Exception(message) {
    override fun toString(): String = "ZigbaseException($status): $message ($url)"
}

/**
 * Builds a [ZigbaseException] from a response body, which may not be JSON.
 *
 * Port of `parseErrorResponse` in `clients/typescript/src/errors.ts`, with
 * the malformed-field-error hardening from `clients/python/src/zigbase/errors.py`
 * / `clients/dart/lib/src/errors.dart`: a `data` entry that isn't a
 * `{code, message}` object of strings is skipped rather than defaulted, so
 * callers can't mistake "absent/malformed" for a real (if unusually empty)
 * field error.
 *
 * Parses a `{message?, data?}` shaped JSON body, where `data` maps field
 * names to `{code, message}` objects. When the body is not valid JSON (or
 * not a JSON object), falls back to [reasonPhrase] (a blank string counts
 * as absent), then to a generic `"Request failed with status $status"`
 * message.
 */
fun parseErrorResponse(
    status: Int,
    bodyText: String,
    url: String,
    reasonPhrase: String? = null,
): ZigbaseException {
    var message = if (!reasonPhrase.isNullOrBlank()) reasonPhrase else "Request failed with status $status"
    var data: Map<String, FieldError> = emptyMap()

    try {
        val root = Json.parseToJsonElement(bodyText).jsonObject

        val rawMessage = root["message"]
        if (rawMessage is JsonPrimitive && rawMessage.isString) {
            message = rawMessage.content
        }

        val rawData = root["data"]
        if (rawData is JsonObject) {
            val entries = mutableMapOf<String, FieldError>()
            for ((key, value) in rawData) {
                if (value !is JsonObject) continue
                val code = value["code"]
                val fieldMessage = value["message"]
                if (code !is JsonPrimitive || !code.isString) continue
                if (fieldMessage !is JsonPrimitive || !fieldMessage.isString) continue
                entries[key] = FieldError(code.content, fieldMessage.content)
            }
            data = entries
        }
    } catch (e: Exception) {
        // Non-JSON (or non-object) body; keep the fallback message.
    }

    return ZigbaseException(status = status, message = message, data = data, url = url)
}
