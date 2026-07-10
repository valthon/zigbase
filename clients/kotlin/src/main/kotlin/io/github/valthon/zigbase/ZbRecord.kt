package io.github.valthon.zigbase

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull

/**
 * A single ZigBase record: the raw JSON object plus typed, null-safe
 * accessors.
 *
 * Port of the permissive `ZbRecord` shape in `clients/typescript/src/records.ts`
 * and `clients/dart/lib/src/records.dart`'s `ZbRecord` (an `id` plus
 * arbitrary fields) -- a thin, immutable wrapper the dynamic base SDK uses.
 * Nothing here validates a record's shape against its collection's schema;
 * every accessor is best-effort and returns `null` rather than throwing on a
 * missing or mistyped field.
 */
data class ZbRecord(
    val raw: JsonObject,
) {
    /** The record id, or `""` if absent or not a string. */
    val id: String get() = getString("id") ?: ""

    /** The record's creation timestamp, or `null` if absent or not a string. */
    val created: String? get() = getString("created")

    /** The record's last-update timestamp, or `null` if absent or not a string. */
    val updated: String? get() = getString("updated")

    /** The server's `expand` map for this record, or `null` if absent or not an object. */
    val expand: JsonObject? get() = raw["expand"] as? JsonObject

    /** Reads a raw field value, or `null` if [key] is absent. */
    operator fun get(key: String): JsonElement? = raw[key]

    /** Reads [key] as a [String], or `null` if absent or not a string. */
    fun getString(key: String): String? {
        val value = raw[key] as? JsonPrimitive ?: return null
        return if (value.isString) value.content else null
    }

    /**
     * Reads [key] as an [Int], coercing any JSON number (so a wire `4.9`
     * reads as `4`, truncated toward zero -- matching `clients/dart`'s `v is
     * num ? v.toInt()`). Returns `null` if absent or not numeric.
     */
    fun getInt(key: String): Int? = numericContent(key)?.toInt()

    /** Reads [key] as a [Double], coercing any JSON number. Returns `null` if absent or not numeric. */
    fun getDouble(key: String): Double? = numericContent(key)

    /** Reads [key] as a [Boolean], or `null` if absent or not a boolean. */
    fun getBoolean(key: String): Boolean? {
        val value = raw[key] as? JsonPrimitive ?: return null
        return value.booleanOrNull
    }

    /**
     * Reads [key] as a `List<String>`, or `null` if absent or not an array.
     * A non-string element is dropped rather than raising -- this is a
     * best-effort convenience accessor, not a schema validator.
     */
    fun getStringList(key: String): List<String>? {
        val array = raw[key] as? JsonArray ?: return null
        return array.mapNotNull { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
    }

    private fun numericContent(key: String): Double? {
        val value = raw[key] as? JsonPrimitive ?: return null
        if (value.isString) return null
        return value.content.toDoubleOrNull()
    }
}
