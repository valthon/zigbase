package io.github.valthon.zigbase.typed

import io.github.valthon.zigbase.ZigbaseClient
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.serialization.json.JsonObject

/*
 * Typed realtime -- a thin `Flow`/callback wrapper over KSP2's
 * `RealtimeService.subscribe`/`stream`. Port of `TypedRealtime`/
 * `TypedRealtimeEvent` in `clients/python/src/zigbase/typed.py:962-1048`,
 * cross-checked against `clients/dart/lib/typed.dart:522-569`.
 *
 * This does not reimplement the wire protocol: every subscribe/ack/dispatch/
 * reconnect concern lives in `RealtimeService` already (see that file for
 * the full contract); [TypedRealtime] only maps each raw [RealtimeEvent]'s
 * record through [fromRecord].
 *
 * No per-collection `close()` -- deliberately, matching the Python/Dart
 * ports: this wraps the client's single, shared, multiplexed
 * `RealtimeService` (`ZigbaseClient.realtime`); closing it here would kill
 * every OTHER collection's subscriptions too and permanently disable
 * reconnect. Tear down one subscription with the `Unsubscribe` [subscribe]
 * returns (or by ending collection of a [stream]); tear down the connection
 * itself with `ZigbaseClient.close()`.
 */

/**
 * A record-mutation event with [record] mapped through `fromRecord`.
 *
 * [action] is `create`/`update`/`delete`. On `delete`, [record] was
 * converted from an id-only mapping (`{"id": ...}`) -- see
 * [TypedRealtime.subscribe].
 *
 * Port of `TypedRealtimeEvent` in `clients/python/src/zigbase/typed.py`.
 */
data class TypedRealtimeEvent<T>(
    val topic: String,
    val action: String,
    val record: T,
)

/**
 * Typed realtime surface for one collection. A generated subclass fixes `T`
 * and `fromRecord`.
 *
 * Port of `TypedRealtime` in `clients/python/src/zigbase/typed.py`.
 */
open class TypedRealtime<T>(
    client: ZigbaseClient,
    val meta: CollectionMeta,
    private val fromRecord: (JsonObject) -> T,
) {
    private val rt = client.realtime

    /**
     * Subscribes to [meta]'s topic; [callback] receives each event with
     * `record` mapped through `fromRecord` -- including a `delete` event,
     * whose id-only `record` still runs through `fromRecord` (its coercer
     * fallbacks tolerate the missing fields), matching `typed.py`/
     * `typed.dart` (no delete special case).
     *
     * [where] takes precedence over [filter] when both are given
     * (`where?.compile() ?: filter`). See [io.github.valthon.zigbase.realtime
     * .RealtimeService.subscribe] for the full ack-gated subscribe/
     * reconnect/callback-isolation contract this inherits unchanged.
     */
    suspend fun subscribe(
        where: Expr? = null,
        filter: String? = null,
        callback: suspend (TypedRealtimeEvent<T>) -> Unit,
    ): suspend () -> Unit =
        rt.subscribe(meta.name, effectiveFilter(where, filter)) { event ->
            callback(TypedRealtimeEvent(event.topic, event.action, fromRecord(event.record.raw)))
        }

    /**
     * A cold [Flow] of [TypedRealtimeEvent]s for [meta]'s topic, layered
     * over [io.github.valthon.zigbase.realtime.RealtimeService.stream]:
     * inherits that function's subscribe-on-first-collect, teardown-on-
     * completion/cancellation/rejection, and unbounded-buffering contract
     * unchanged -- this only maps each delivered [io.github.valthon.zigbase
     * .RealtimeEvent] through `fromRecord`. [where]/[filter] behave as in
     * [subscribe].
     */
    fun stream(
        where: Expr? = null,
        filter: String? = null,
    ): Flow<TypedRealtimeEvent<T>> =
        rt.stream(meta.name, effectiveFilter(where, filter)).map { event ->
            TypedRealtimeEvent(event.topic, event.action, fromRecord(event.record.raw))
        }

    private fun effectiveFilter(
        where: Expr?,
        filter: String?,
    ): String? = where?.compile() ?: filter
}
