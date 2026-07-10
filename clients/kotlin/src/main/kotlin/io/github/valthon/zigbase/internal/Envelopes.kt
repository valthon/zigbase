package io.github.valthon.zigbase.internal

import io.github.valthon.zigbase.CursorPage
import io.github.valthon.zigbase.ZbRecord
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.intOrNull

/*
 * Shared JSON-envelope parsing helpers, used by [io.github.valthon.zigbase.CollectionService]
 * and [io.github.valthon.zigbase.AnalyticsService]/[io.github.valthon.zigbase.SendersService] --
 * factored out here rather than duplicated per service.
 */

/** Reads [key] as a [Boolean], or `false` if absent/not a boolean. */
internal fun booleanField(
    obj: JsonObject,
    key: String,
): Boolean = (obj[key] as? JsonPrimitive)?.booleanOrNull ?: false

/** Reads [key] as a [String], or `null` if absent/not a string. */
internal fun stringOrNullField(
    obj: JsonObject,
    key: String,
): String? = (obj[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

/** Reads `items` as a `List<ZbRecord>`, dropping non-object elements; `emptyList()` if `items` is absent/not an array. */
internal fun recordItemsField(obj: JsonObject): List<ZbRecord> =
    (obj["items"] as? JsonArray)?.mapNotNull { (it as? JsonObject)?.let(::ZbRecord) } ?: emptyList()

/**
 * Parses a `{items, nextCursor, prevCursor, hasNext, hasPrev, totalItems}`
 * cursor envelope into a [CursorPage].
 *
 * Shared by [io.github.valthon.zigbase.CollectionService.getPage] (the full
 * shape) and [io.github.valthon.zigbase.AnalyticsService.events] (whose
 * `GET /api/analytics/events` envelope is a subset -- `prevCursor`/
 * `totalItems` fall back to `null`, `hasPrev` to `false`, matching every
 * sibling SDK's shared-parser reuse of the records cursor page shape).
 */
internal fun parseCursorPage(
    body: JsonElement?,
    context: String,
): CursorPage {
    val envelope = ensureObjectBody(body, context)
    return CursorPage(
        items = recordItemsField(envelope),
        nextCursor = stringOrNullField(envelope, "nextCursor"),
        prevCursor = stringOrNullField(envelope, "prevCursor"),
        hasNext = booleanField(envelope, "hasNext"),
        hasPrev = booleanField(envelope, "hasPrev"),
        totalItems = (envelope["totalItems"] as? JsonPrimitive)?.intOrNull,
    )
}

/**
 * Unwraps the house `{items}` list envelope as raw [JsonObject] rows (not
 * [ZbRecord]) -- used by endpoints whose rows aren't record-shaped
 * (analytics events/rollups, senders).
 */
internal fun unwrapJsonObjectItems(
    body: JsonElement?,
    context: String,
): List<JsonObject> {
    val envelope = ensureObjectBody(body, context)
    return (envelope["items"] as? JsonArray)?.mapNotNull { it as? JsonObject } ?: emptyList()
}
