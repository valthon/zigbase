package io.github.valthon.zigbase

import kotlinx.serialization.json.JsonElement

/**
 * A frame delivered on a custom (non-collection) topic.
 *
 * Port of `TopicMessage` in `clients/python/src/zigbase/realtime.py`.
 * [kind] is `signal` (a re-fetch hint, [data] is `null`) or `message` (a
 * payload-carrying broadcast via `ctx.realtime().broadcast`).
 */
data class TopicMessage(
    val topic: String,
    val kind: String,
    val data: JsonElement? = null,
)
