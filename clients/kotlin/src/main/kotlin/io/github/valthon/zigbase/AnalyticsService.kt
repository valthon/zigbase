package io.github.valthon.zigbase

import io.github.valthon.zigbase.internal.RequestSpec
import io.github.valthon.zigbase.internal.Transport
import io.github.valthon.zigbase.internal.encodePathSegment
import io.github.valthon.zigbase.internal.parseCursorPage
import io.github.valthon.zigbase.internal.unwrapJsonObjectItems
import io.github.valthon.zigbase.query.buildListParams
import io.github.valthon.zigbase.query.formatDate
import io.ktor.http.HttpMethod
import kotlinx.serialization.json.JsonObject
import java.time.Instant

/*
 * Product-analytics read APIs (requires ZigBase >= 0.9.0). Tenant-scoped,
 * fail closed.
 *
 * Port of `AnalyticsService`/`AsyncAnalyticsService` in
 * `clients/python/src/zigbase/analytics.py`, cross-checked against
 * `clients/typescript/src/analytics.ts` (the wire truth for param
 * names/order) and `clients/dart/lib/src/analytics.dart`. Rollup rows are
 * returned as raw [JsonObject]s (their wire field names are the snake_case
 * of src/analytics/api.zig -- `actor_collection`, `occurred_at`,
 * `computed_at`, etc.) rather than a typed class, matching every sibling
 * SDK; event rows go through the same envelope parser as record listing and
 * come back as [ZbRecord].
 *
 * [AnalyticsService.events] reuses
 * [io.github.valthon.zigbase.internal.parseCursorPage] -- the same parser
 * [CollectionService.getPage] uses -- since the `GET /api/analytics/events`
 * envelope (`{items, nextCursor, hasNext}`) is a subset of the records
 * cursor envelope; its `.get()`-style field access degrades correctly
 * (`prevCursor`/`totalItems` fall back to `null`, `hasPrev` to `false`).
 */

/**
 * Product-analytics reads, over a [Transport].
 *
 * Constructed internally -- obtain one from the top-level client rather than
 * calling this constructor directly.
 */
class AnalyticsService internal constructor(
    private val transport: Transport,
) {
    /**
     * `GET /api/analytics/events` -- the tenant-scoped activity feed. 401
     * anonymous; empty `items` with no active account; a superuser sees
     * everything. Paginates with the house cursor: pass the previous
     * page's `nextCursor` back as [cursor] to fetch the next one.
     */
    suspend fun events(
        name: String? = null,
        actor: String? = null,
        since: Instant? = null,
        limit: Int? = null,
        cursor: String? = null,
    ): CursorPage {
        val query = buildListParams(cursor = cursor, limit = limit).toMutableMap()
        name?.let { query["name"] = it }
        actor?.let { query["actor"] = it }
        since?.let { query["since"] = formatDate(it) }
        val body = transport.request(RequestSpec(HttpMethod.Get, "/api/analytics/events", query = query))
        return parseCursorPage(body, "events")
    }

    /**
     * `GET /api/analytics/rollups/:name` -- a declared rollup's summary
     * rows (unwraps `{items}`). 404 for an undeclared name; 403 for a
     * non-account-grouped rollup queried by a non-superuser.
     */
    suspend fun rollup(
        name: String,
        from: Instant? = null,
        to: Instant? = null,
    ): List<JsonObject> {
        val query = LinkedHashMap<String, String>()
        from?.let { query["from"] = formatDate(it) }
        to?.let { query["to"] = formatDate(it) }
        val body =
            transport.request(
                RequestSpec(HttpMethod.Get, "/api/analytics/rollups/${encodePathSegment(name)}", query = query),
            )
        return unwrapJsonObjectItems(body, "rollup")
    }
}
