package io.github.valthon.zigbase.internal

import io.github.valthon.zigbase.FileArg
import io.github.valthon.zigbase.query.formatDate
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.time.Instant
import java.time.OffsetDateTime

/*
 * Body encoding: JSON passthrough, or multipart auto-detection.
 *
 * Port of `hasBlob`/`toFormData` in `clients/typescript/src/records.ts`,
 * `has_file`/`encode_body` in `clients/python/src/zigbase/_multipart.py`,
 * and `hasFilePayload`/`encodeMultipart` in `clients/dart/lib/src/records.dart`.
 *
 * Kotlin has no `undefined`, so -- as in the Python port -- the TS
 * "`undefined` is skipped, `null` becomes an empty-string field" rule
 * collapses to one case: a key absent from the body map is simply never
 * iterated (the equivalent of "skipped"), and an explicit `null` value
 * becomes `""`. Every Kotlin `null` a caller can produce therefore maps to
 * what TS calls `null`, never to what TS calls `undefined`.
 */

/**
 * True when [body] contains a [FileArg] (or a `List` containing one) at the
 * top level, meaning the request must be sent as `multipart/form-data`
 * instead of JSON.
 *
 * Mirrors `hasBlob`/`has_file`: only top-level values and top-level list
 * elements are scanned -- a [FileArg] nested inside a `Map` value is not
 * detected here (it is instead rejected loudly by [encodeBody], since a
 * file cannot become a form part from inside a JSON-encoded field).
 */
internal fun hasFile(body: Map<String, Any?>): Boolean {
    for (value in body.values) {
        if (value is FileArg) return true
        if (value is List<*> && value.any { it is FileArg }) return true
    }
    return false
}

/** A single multipart file part, ready to hand to ktor's `MultiPartFormDataContent`. */
internal class FilePart(
    val key: String,
    val filename: String,
    val content: ByteArray,
    val contentType: String?,
)

/**
 * The result of [encodeBody]: either a JSON object, or multipart fields +
 * files. Port of `EncodedBody` in `clients/python/src/zigbase/_multipart.py`.
 */
internal sealed class EncodedBody {
    class Json(
        val element: JsonObject,
    ) : EncodedBody()

    class Multipart(
        val fields: List<Pair<String, String>>,
        val files: List<FilePart>,
    ) : EncodedBody()
}

/**
 * Reads a [FileArg] into its wire triple. For [FileArg.FromFile], the
 * bytes are read from disk here -- exactly once per [encodeBody] call --
 * so the resulting [FilePart] can be reused by a retrying transport
 * without touching the filesystem again.
 */
private fun readFileArg(value: FileArg): Triple<String, ByteArray, String?> =
    when (value) {
        is FileArg.Bytes -> Triple(value.filename, value.content, value.contentType)
        is FileArg.FromFile -> Triple(value.file.name, value.file.readBytes(), value.contentType)
    }

/**
 * Converts [value] to a [JsonElement] for the JSON body path, recursing
 * into nested `Map`/`List`. Throws [IllegalArgumentException] naming [key]
 * -- always the top-level body key, even when the offending value is
 * nested several levels deep, matching the Python port's `json.dumps`-based
 * error naming -- for any value that isn't one of the encodable types
 * below, including a nested [FileArg] (a file cannot appear inside a JSON
 * body) and a non-finite `Double`/`Float` (RFC 8259 forbids `NaN`/
 * `Infinity` in JSON; this is the `allow_nan=False` hardening from the
 * Python port, which the raw `kotlinx.serialization` `JsonPrimitive(Double)`
 * constructor does not itself enforce).
 *
 * Numeric fidelity note: a `Double`/`Float` renders via
 * `JsonPrimitive(Double).toString()`, which uses `Double.toString()` --
 * this may differ byte-for-byte from [io.github.valthon.zigbase.query.formatJsNumber]'s
 * JS-`Number`-matching output. That distinction matters for `filter`
 * strings (byte-parity with the server's lexer is contractual there); it
 * does not matter here, since the server parses the JSON body value rather
 * than lexing it as a filter operand.
 */
private fun toJsonElement(
    value: Any?,
    key: String,
): JsonElement =
    when (value) {
        null -> {
            JsonNull
        }

        is JsonElement -> {
            value
        }

        is String -> {
            JsonPrimitive(value)
        }

        is Boolean -> {
            JsonPrimitive(value)
        }

        is Int -> {
            JsonPrimitive(value)
        }

        is Long -> {
            JsonPrimitive(value)
        }

        is Double -> {
            requireFinite(value, key)
            JsonPrimitive(value)
        }

        is Float -> {
            requireFinite(value.toDouble(), key)
            JsonPrimitive(value.toDouble())
        }

        is Instant -> {
            JsonPrimitive(formatDate(value))
        }

        is OffsetDateTime -> {
            JsonPrimitive(formatDate(value.toInstant()))
        }

        is Map<*, *> -> {
            buildJsonObject {
                for ((k, v) in value) put(k.toString(), toJsonElement(v, key))
            }
        }

        is List<*> -> {
            buildJsonArray {
                for (item in value) add(toJsonElement(item, key))
            }
        }

        else -> {
            throw IllegalArgumentException(
                "encodeBody: value for key '$key' is not JSON-encodable (${value::class.simpleName})",
            )
        }
    }

private fun requireFinite(
    value: Double,
    key: String,
) {
    if (!value.isFinite()) {
        throw IllegalArgumentException("encodeBody: value for key '$key' is not JSON-encodable (non-finite number: $value)")
    }
}

/**
 * Encodes a single multipart text-field value (never a [FileArg] or `null`
 * -- callers handle those separately). `Instant`/`OffsetDateTime` ->
 * [formatDate]; `Boolean` -> lowercase `true`/`false`; nested `Map`/`List`
 * -> a JSON string via the same strict [toJsonElement] converter used for
 * the JSON body path, so a nested non-encodable value (including a nested
 * [FileArg]) or non-finite number is rejected here too, naming [key];
 * `Double`/`Float` render via [toJsonElement] as well, for the same
 * finite-number rejection and rendering consistency; every other scalar ->
 * `toString()`.
 */
private fun encodeScalarField(
    key: String,
    value: Any,
): String =
    when (value) {
        is Instant -> formatDate(value)
        is OffsetDateTime -> formatDate(value.toInstant())
        is Boolean -> if (value) "true" else "false"
        is Map<*, *> -> toJsonElement(value, key).toString()
        is List<*> -> toJsonElement(value, key).toString()
        is Double -> toJsonElement(value, key).toString()
        is Float -> toJsonElement(value, key).toString()
        else -> value.toString()
    }

/**
 * Encodes [body] as JSON, or as multipart fields + files if it contains a
 * [FileArg] ([hasFile]).
 *
 * JSON path: every value is passed through [toJsonElement] (which also
 * formats nested `Instant`/`OffsetDateTime`), so the result is guaranteed
 * JSON-safe; a non-encodable value raises [IllegalArgumentException] naming
 * its top-level key rather than being silently dropped or mis-rendered.
 *
 * Multipart path (matches TS `toFormData` / Python `encode_body`): a key
 * absent from [body] is skipped; `null` -> `""`; a [FileArg] -> a
 * [FilePart] (files as files); a top-level `List` is iterated
 * element-wise, one form field or file part per element with the key
 * repeated (a `null` element is dropped; a [FileArg] element becomes a
 * file; every other element is encoded via [encodeScalarField]); other
 * scalars -> [encodeScalarField].
 */
internal fun encodeBody(body: Map<String, Any?>): EncodedBody {
    if (!hasFile(body)) {
        val json =
            buildJsonObject {
                for ((key, value) in body) put(key, toJsonElement(value, key))
            }
        return EncodedBody.Json(json)
    }

    val fields = mutableListOf<Pair<String, String>>()
    val files = mutableListOf<FilePart>()

    for ((key, value) in body) {
        when {
            value is FileArg -> {
                val (filename, content, contentType) = readFileArg(value)
                files.add(FilePart(key, filename, content, contentType))
            }

            value == null -> {
                fields.add(key to "")
            }

            value is List<*> -> {
                for (item in value) {
                    when {
                        item is FileArg -> {
                            val (filename, content, contentType) = readFileArg(item)
                            files.add(FilePart(key, filename, content, contentType))
                        }

                        item == null -> {
                            continue
                        }

                        else -> {
                            fields.add(key to encodeScalarField(key, item))
                        }
                    }
                }
            }

            else -> {
                fields.add(key to encodeScalarField(key, value))
            }
        }
    }

    return EncodedBody.Multipart(fields, files)
}
