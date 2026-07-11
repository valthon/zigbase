package io.github.valthon.zigbase.typed

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.longOrNull
import java.math.BigDecimal
import java.math.RoundingMode
import kotlin.math.floor

// Wire coercers, encoders, and expand helpers used by generated `fromRecord`
// constructors and `toMap` payload builders.
//
// Port of the coercion + expand sections of
// `clients/python/src/zigbase/typed.py` (`coerce_int`/`coerce_float`/etc.,
// `encode_int`/`encode_fixed`, `expand_one`/`expand_many`), itself a port of
// `clients/dart/lib/typed.dart`. These read `kotlinx.serialization.json`
// values directly (records arrive as a `JsonObject`), reusing the accessor
// patterns from `io.github.valthon.zigbase.ZbRecord`.

/** Treats both an absent key (Kotlin `null`) and an explicit JSON `null` as "missing". */
private fun JsonElement?.orMissing(): JsonElement? = if (this == null || this is JsonNull) null else this

/**
 * Coerce a wire value (a JSON number, or the decimal-string form used for
 * int-mode fields) to a [Long]. Returns [fallback] for missing/empty/
 * unparseable values, but **raises [IllegalArgumentException] on a numeric
 * value with a fractional part** (`"9.99"`, `9.99`): the server always
 * sends integers for int-mode fields, so a non-integer number means the
 * field is not actually int-mode -- silent truncation would hide the
 * schema drift.
 *
 * A JSON `true`/`false` is deliberately *not* treated as a valid integer
 * here, even though [JsonPrimitive.booleanOrNull] and [JsonPrimitive.longOrNull]
 * both key off the same untyped `content` string: Dart's `v is int` check
 * (the type this ports) excludes `bool` at the type-system level, so a
 * boolean wire value falls through to [fallback] like any other
 * unrecognized type, for parity.
 *
 * Port of `coerce_int` in `clients/python/src/zigbase/typed.py`.
 */
fun coerceLong(
    v: JsonElement?,
    fallback: Long = 0L,
): Long {
    val e = v.orMissing() as? JsonPrimitive ?: return fallback
    if (e.isString) {
        val s = e.content
        if (s.isEmpty()) return fallback
        s.toLongOrNull()?.let { return it }
        val d = s.toDoubleOrNull() ?: return fallback
        if (d != floor(d) || !d.isFinite()) {
            throw IllegalArgumentException("int-mode field received a non-integer value: \"$s\"")
        }
        // A whole double outside Long's range would silently clamp to
        // Long.MIN/MAX under toLong() -- the same silent corruption the
        // fractional check above rejects. Upper bound is `<` because
        // Long.MAX_VALUE.toDouble() rounds UP to 2^63 (out of range).
        if (d < Long.MIN_VALUE.toDouble() || d >= Long.MAX_VALUE.toDouble()) {
            throw IllegalArgumentException("int-mode field value out of Long range: \"$s\"")
        }
        return d.toLong()
    }
    if (e.booleanOrNull != null) return fallback
    e.longOrNull?.let { return it }
    val d = e.doubleOrNull ?: return fallback
    if (d != floor(d) || !d.isFinite()) {
        throw IllegalArgumentException("int-mode field received a non-integer value: $d")
    }
    if (d < Long.MIN_VALUE.toDouble() || d >= Long.MAX_VALUE.toDouble()) {
        throw IllegalArgumentException("int-mode field value out of Long range: $d")
    }
    return d.toLong()
}

/**
 * Coerce a wire value to a [Double] (int/fixed fields arrive as decimal
 * strings). Returns [fallback] for missing/empty/unparseable values.
 *
 * Same Dart-parity rationale as [coerceLong]: a JSON boolean is excluded,
 * so it falls through to [fallback].
 *
 * Port of `coerce_float` in `clients/python/src/zigbase/typed.py`.
 */
fun coerceDouble(
    v: JsonElement?,
    fallback: Double = 0.0,
): Double {
    val e = v.orMissing() as? JsonPrimitive ?: return fallback
    if (e.isString) {
        val s = e.content
        if (s.isEmpty()) return fallback
        return s.toDoubleOrNull() ?: fallback
    }
    if (e.booleanOrNull != null) return fallback
    return e.doubleOrNull ?: fallback
}

/**
 * Coerce a wire value to a non-null [String] (falls back to [fallback]).
 *
 * Port of `coerce_str` in `clients/python/src/zigbase/typed.py`.
 */
fun coerceString(
    v: JsonElement?,
    fallback: String = "",
): String {
    val e = v.orMissing() as? JsonPrimitive ?: return fallback
    return if (e.isString) e.content else fallback
}

/**
 * Coerce a wire value to a [Boolean] (falls back to [fallback]).
 *
 * Port of `coerce_bool` in `clients/python/src/zigbase/typed.py`.
 */
fun coerceBoolean(
    v: JsonElement?,
    fallback: Boolean = false,
): Boolean {
    val e = v.orMissing() as? JsonPrimitive ?: return fallback
    if (e.isString) return fallback
    return e.booleanOrNull ?: fallback
}

/**
 * Coerce a wire array to `List<String>` (relation-id / file-name multi
 * fields). A single non-empty string is wrapped; any other scalar returns
 * an empty list.
 *
 * Port of `coerce_str_list` in `clients/python/src/zigbase/typed.py`.
 */
fun coerceStringList(v: JsonElement?): List<String> {
    when (val e = v.orMissing() ?: return emptyList()) {
        is JsonArray -> return e.map { el -> (el as? JsonPrimitive)?.content ?: el.toString() }
        is JsonPrimitive -> return if (e.isString && e.content.isNotEmpty()) listOf(e.content) else emptyList()
        else -> return emptyList()
    }
}

/**
 * Coerce a wire array to `List<Long>` (multi-value int fields; decimal
 * strings), via [coerceLong] per element -- so a fractional element still
 * raises [IllegalArgumentException].
 *
 * Port of `coerce_int_list` in `clients/python/src/zigbase/typed.py`.
 */
fun coerceLongList(v: JsonElement?): List<Long> {
    val arr = v.orMissing() as? JsonArray ?: return emptyList()
    return arr.map { coerceLong(it) }
}

/**
 * Coerce a wire array to `List<Double>` (multi-value fixed/float fields),
 * via [coerceDouble] per element.
 *
 * Port of `coerce_float_list` in `clients/python/src/zigbase/typed.py`.
 */
fun coerceDoubleList(v: JsonElement?): List<Double> {
    val arr = v.orMissing() as? JsonArray ?: return emptyList()
    return arr.map { coerceDouble(it) }
}

/**
 * Serialize a [Long] field to its decimal-string wire form.
 *
 * Port of `encode_int` in `clients/python/src/zigbase/typed.py`.
 */
fun encodeInt(v: Long?): String? = v?.toString()

/**
 * Serialize a fixed-point field to its scaled decimal-string wire form,
 * matching Dart's `toStringAsFixed(scale)`.
 *
 * Rounds the double's exact binary value (via `BigDecimal(v)`, *not*
 * `BigDecimal(v.toString())`) half-up to [scale] places. A plain
 * `String.format("%.${scale}f", v)` uses round-half-to-even and would
 * render an exact tie like `0.125` at scale 2 as `"0.12"` instead of the
 * `"0.13"` Dart produces.
 *
 * Port of `encode_fixed` in `clients/python/src/zigbase/typed.py`.
 */
fun encodeFixed(
    v: Double?,
    scale: Int,
): String? {
    if (v == null) return null
    return BigDecimal(v).setScale(scale, RoundingMode.HALF_UP).toPlainString()
}

/**
 * Read a single expanded relation from `record["expand"][key]` and map it
 * through the target collection's [fromRecord]. Returns `null` when the
 * relation was not expanded. Used by generated `<Rec>Expand` classes.
 *
 * Port of `expand_one` in `clients/python/src/zigbase/typed.py`.
 */
fun <T> expandOne(
    record: JsonObject,
    key: String,
    fromRecord: (JsonObject) -> T,
): T? {
    val ex = record["expand"] as? JsonObject ?: return null
    val v = ex[key] as? JsonObject ?: return null
    return fromRecord(v)
}

/**
 * Read a multi-value expanded relation from `record["expand"][key]`.
 * Returns an empty list when the relation was not expanded; a non-object
 * element in the array is skipped rather than raising.
 *
 * Port of `expand_many` in `clients/python/src/zigbase/typed.py`.
 */
fun <T> expandMany(
    record: JsonObject,
    key: String,
    fromRecord: (JsonObject) -> T,
): List<T> {
    val ex = record["expand"] as? JsonObject ?: return emptyList()
    val arr = ex[key] as? JsonArray ?: return emptyList()
    return arr.mapNotNull { (it as? JsonObject)?.let(fromRecord) }
}
