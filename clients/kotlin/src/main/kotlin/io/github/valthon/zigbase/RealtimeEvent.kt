package io.github.valthon.zigbase

/**
 * A record mutation delivered on a collection topic.
 *
 * Port of `RealtimeEvent` in `clients/python/src/zigbase/realtime.py`.
 * Unlike the Python/TypeScript/Dart SDKs (whose `record` is a raw
 * dict/object), [record] is a [ZbRecord] here for consistency with the rest
 * of this SDK's public surface; a `delete` action's record wraps an
 * `{"id": ...}`-only object, which [ZbRecord]'s best-effort, null-tolerant
 * accessors handle fine (every field besides `id` simply reads `null`).
 *
 * [action] is one of `create`, `update`, `delete`.
 */
data class RealtimeEvent(
    val topic: String,
    val action: String,
    val record: ZbRecord,
)
