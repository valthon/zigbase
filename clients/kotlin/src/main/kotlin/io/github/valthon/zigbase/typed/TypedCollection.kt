package io.github.valthon.zigbase.typed

import io.github.valthon.zigbase.CollectionService
import io.github.valthon.zigbase.FilesService
import io.github.valthon.zigbase.ZbRecord
import io.github.valthon.zigbase.ZigbaseClient
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.toList
import kotlinx.serialization.json.JsonObject

/*
 * The generic typed CRUD service a generated per-collection service composes
 * over. Port of `TypedList`/`TypedCursorPage`/`join_csv`/`normalize_sort`/
 * `TypedCollection` in `clients/python/src/zigbase/typed.py:500-757`,
 * cross-checked against `clients/dart/lib/typed.dart:307-522`.
 *
 * Coroutine-first, no sync/async fork: unlike typed.py's `TypedCollection`/
 * `AsyncTypedCollection` split, Kotlin ships ONE class with `suspend` CRUD
 * methods and a `Flow` `iterate`/`getFullList`, mirroring the base
 * `CollectionService`'s own single coroutine-first surface.
 */

/**
 * Offset-pagination page of typed records.
 *
 * Port of `TypedList` in `clients/python/src/zigbase/typed.py`.
 */
data class TypedList<T>(
    val items: List<T>,
    val page: Int,
    val perPage: Int,
    val totalItems: Int,
    val totalPages: Int,
)

/**
 * Keyset (cursor) page of typed records.
 *
 * Port of `TypedCursorPage` in `clients/python/src/zigbase/typed.py`.
 */
data class TypedCursorPage<T>(
    val items: List<T>,
    val nextCursor: String?,
    val prevCursor: String?,
    val hasNext: Boolean,
    val hasPrev: Boolean,
    val totalItems: Int?,
)

/**
 * Joins a list of strings to a comma string. `null`/empty -> `null`, so the
 * query param is omitted rather than sent empty.
 *
 * Port of `join_csv` in `clients/python/src/zigbase/typed.py`.
 */
internal fun joinCsv(values: List<String>?): String? {
    if (values.isNullOrEmpty()) return null
    return values.joinToString(",")
}

/**
 * Normalizes a sort argument to the base SDK's comma-joined string form. A
 * list that is empty, or whose entries are all empty, normalizes to `null`
 * (param omitted).
 *
 * Port of `normalize_sort` in `clients/python/src/zigbase/typed.py`.
 */
internal fun normalizeSort(sort: List<String>?): String? {
    if (sort == null) return null
    val parts = sort.filter { it.isNotEmpty() }
    return if (parts.isEmpty()) null else parts.joinToString(",")
}

/**
 * The generic typed CRUD service that a generated per-collection service
 * composes. Wraps the base [CollectionService] for [meta]'s name and maps
 * every returned record through [fromRecord].
 *
 * Kept thin, matching `typed.py`'s `TypedCollection`: `filter` is an
 * already-compiled string (where-compilation happens in generated services,
 * per Task 6), and `sort`/`expand` are normalized here via [normalizeSort]/
 * [joinCsv] before being handed to the base SDK. Writes take the raw
 * `Map<String, Any?>` a generated `toMap()` produced, passed through
 * untouched.
 *
 * Port of `TypedCollection`/`AsyncTypedCollection` in
 * `clients/python/src/zigbase/typed.py`.
 */
class TypedCollection<T>(
    client: ZigbaseClient,
    val meta: CollectionMeta,
    private val fromRecord: (JsonObject) -> T,
) {
    /**
     * The underlying base [CollectionService] -- escape hatch for methods
     * the typed surface does not wrap (e.g. auth, abilities).
     */
    val collection: CollectionService = client.collection(meta.name)

    private val files: FilesService = client.files

    /** `GET /records` (offset pagination), mapped through [fromRecord]. */
    suspend fun getList(
        page: Int = 1,
        perPage: Int = 30,
        filter: String? = null,
        sort: List<String>? = null,
        expand: List<String>? = null,
        fields: String? = null,
        skipTotal: Boolean = false,
        search: String? = null,
    ): TypedList<T> {
        val result =
            collection.getList(
                page = page,
                perPage = perPage,
                filter = filter,
                sort = normalizeSort(sort),
                expand = joinCsv(expand),
                fields = fields,
                skipTotal = skipTotal,
                search = search,
            )
        return TypedList(
            items = result.items.map { fromRecord(it.raw) },
            page = result.page,
            perPage = result.perPage,
            totalItems = result.totalItems,
            totalPages = result.totalPages,
        )
    }

    /** `GET /records/:id`, mapped through [fromRecord]. */
    suspend fun getOne(
        id: String,
        expand: List<String>? = null,
        fields: String? = null,
    ): T = fromRecord(collection.getOne(id, expand = joinCsv(expand), fields = fields).raw)

    /**
     * `getList(1, 1, skipTotal = true, filter = filter, ...)` sugar, mapped
     * through [fromRecord]. Throws a synthesized 404 exception when nothing
     * matches (see [CollectionService.getFirstListItem]).
     */
    suspend fun getFirstListItem(
        filter: String,
        sort: List<String>? = null,
        expand: List<String>? = null,
        fields: String? = null,
        search: String? = null,
    ): T =
        fromRecord(
            collection
                .getFirstListItem(
                    filter = filter,
                    sort = normalizeSort(sort),
                    expand = joinCsv(expand),
                    fields = fields,
                    search = search,
                ).raw,
        )

    /**
     * Native server-side cursor (keyset) pagination, mapped through
     * [fromRecord]. See [CollectionService.getPage] for the full contract.
     */
    suspend fun getPage(
        cursor: String? = null,
        limit: Int = 30,
        filter: String? = null,
        sort: List<String>? = null,
        expand: List<String>? = null,
        fields: String? = null,
        withTotal: Boolean = false,
        search: String? = null,
    ): TypedCursorPage<T> {
        val page =
            collection.getPage(
                cursor = cursor,
                limit = limit,
                withTotal = withTotal,
                filter = filter,
                sort = normalizeSort(sort),
                expand = joinCsv(expand),
                fields = fields,
                search = search,
            )
        return TypedCursorPage(
            items = page.items.map { fromRecord(it.raw) },
            nextCursor = page.nextCursor,
            prevCursor = page.prevCursor,
            hasNext = page.hasNext,
            hasPrev = page.hasPrev,
            totalItems = page.totalItems,
        )
    }

    /**
     * Iterates every matching record, mapped through [fromRecord]. See
     * [CollectionService.iterate] for the non-advancing-cursor guard.
     */
    fun iterate(
        batch: Int = 100,
        filter: String? = null,
        sort: List<String>? = null,
        expand: List<String>? = null,
        fields: String? = null,
        search: String? = null,
    ): Flow<T> =
        collection
            .iterate(
                batch = batch,
                filter = filter,
                sort = normalizeSort(sort),
                expand = joinCsv(expand),
                fields = fields,
                search = search,
            ).map { fromRecord(it.raw) }

    /** Accumulates every matching record into a list via [iterate]. */
    suspend fun getFullList(
        batch: Int = 100,
        filter: String? = null,
        sort: List<String>? = null,
        expand: List<String>? = null,
        fields: String? = null,
        search: String? = null,
    ): List<T> = iterate(batch, filter, sort, expand, fields, search).toList()

    /**
     * `POST /records`. [body] is the raw map a generated `toMap()` produced
     * -- passed through untouched -- and the response is mapped through
     * [fromRecord].
     */
    suspend fun create(
        body: Map<String, Any?>,
        expand: List<String>? = null,
        fields: String? = null,
    ): T = fromRecord(collection.create(body, expand = joinCsv(expand), fields = fields).raw)

    /**
     * `PATCH /records/:id`. [body] is passed through untouched -- see
     * [create].
     */
    suspend fun update(
        id: String,
        body: Map<String, Any?>,
        expand: List<String>? = null,
        fields: String? = null,
    ): T = fromRecord(collection.update(id, body, expand = joinCsv(expand), fields = fields).raw)

    /** `DELETE /records/:id`. */
    suspend fun delete(id: String) = collection.delete(id)

    /**
     * Builds a file URL for a stored filename on [record] -- generated
     * services expose a typed `fileUrl(T, field = ...)` wrapper on top of
     * this. See [FilesService.getUrl] for the collection-derivation and URL
     * shape.
     */
    fun fileUrl(
        record: ZbRecord,
        filename: String,
        download: Boolean = false,
        thumb: String? = null,
        token: String? = null,
    ): String = files.getUrl(record, filename, download = download, thumb = thumb, token = token)
}
