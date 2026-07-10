package io.github.valthon.zigbase

import io.github.valthon.zigbase.internal.RequestSpec
import io.github.valthon.zigbase.internal.Transport
import io.github.valthon.zigbase.internal.encodePathSegment
import io.github.valthon.zigbase.internal.ensureObjectBody
import io.github.valthon.zigbase.internal.requireStringField
import io.ktor.http.HttpMethod
import java.net.URLEncoder
import java.nio.charset.StandardCharsets

/*
 * File URL construction + the file-access token endpoint.
 *
 * Port of `FilesService`/`AsyncFilesService` in
 * `clients/python/src/zigbase/files.py` (the hardened normative reference --
 * `requireStringField` on `token`), cross-checked against
 * `clients/typescript/src/files.ts` (the wire truth for param names/order)
 * and `clients/dart/lib/src/files.dart`.
 *
 * `getUrl`/`getUrlFor` are PURE string builders -- no request -- so
 * [FilesService] takes [baseUrl] as an explicit constructor argument
 * (mirroring `FilesService(transport, baseUrl)` in every reference SDK)
 * rather than reading it off [Transport], which has no public `baseUrl`.
 */

/**
 * File URL construction + `POST /api/files/token`, over a [Transport].
 *
 * Constructed internally -- obtain one from the top-level client rather than
 * calling this constructor directly.
 */
class FilesService internal constructor(
    private val transport: Transport,
    private val baseUrl: String,
) {
    /**
     * Builds a file URL for [record] + [filename]. The collection is
     * derived from [record]'s `collectionId`, falling back to
     * `collectionName` (matching `FileRecordRef.collectionId ??
     * collectionName` in files.ts / `record.get("collectionId") or
     * record.get("collectionName")` in files.py) -- an empty-string
     * `collectionId` falls through to `collectionName` too (Python's
     * truthy `or`, kept here deliberately for cross-SDK parity). Throws
     * [IllegalArgumentException] naming the problem when [record] has
     * neither.
     */
    fun getUrl(
        record: ZbRecord,
        filename: String,
        download: Boolean = false,
        thumb: String? = null,
        token: String? = null,
    ): String = getUrlFor(fileCollection(record), record.id, filename, download, thumb, token)

    /** Builds a file URL from an explicit `(collection, recordId, filename)`. */
    fun getUrlFor(
        collection: String,
        recordId: String,
        filename: String,
        download: Boolean = false,
        thumb: String? = null,
        token: String? = null,
    ): String = buildFileUrl(baseUrl, collection, recordId, filename, download, thumb, token)

    /**
     * `POST /api/files/token` -- mints a short-lived file-access token for
     * embedding protected files (e.g. in an `<img>` tag). Raises when the
     * response is missing `token` or it isn't a string, rather than
     * silently defaulting to `""`.
     */
    suspend fun getToken(): String {
        val body = transport.request(RequestSpec(HttpMethod.Post, "/api/files/token"))
        return requireStringField(ensureObjectBody(body, "getToken"), "token", "getToken")
    }
}

/** [FilesService.getUrl]'s collection derivation -- see that KDoc. */
private fun fileCollection(record: ZbRecord): String {
    val id = record.getString("collectionId")
    val name = record.getString("collectionName")
    val col = if (!id.isNullOrEmpty()) id else name
    if (col.isNullOrEmpty()) {
        throw IllegalArgumentException(
            "record has neither collectionId nor collectionName; cannot build a file URL",
        )
    }
    return col
}

/**
 * `{baseUrl}/api/files/{collection}/{recordId}/{filename}`, each path
 * segment individually [encodePathSegment]-ed, plus an optional
 * `download=1`/`thumb=<spec>`/`token=<t>` query string in that order --
 * byte-for-byte the shape files.ts/files.py/files.dart build. The query
 * values are `application/x-www-form-urlencoded` (space -> `+`), matching
 * JS `URLSearchParams`/Python `urlencode` -- distinct from [encodePathSegment]'s
 * `%20` path encoding.
 */
private fun buildFileUrl(
    baseUrl: String,
    collection: String,
    recordId: String,
    filename: String,
    download: Boolean,
    thumb: String?,
    token: String?,
): String {
    val base = baseUrl.trimEnd('/')
    val path =
        "$base/api/files/${encodePathSegment(collection)}" +
            "/${encodePathSegment(recordId)}/${encodePathSegment(filename)}"

    val params = mutableListOf<Pair<String, String>>()
    if (download) params.add("download" to "1")
    if (!thumb.isNullOrEmpty()) params.add("thumb" to thumb)
    if (!token.isNullOrEmpty()) params.add("token" to token)
    if (params.isEmpty()) return path

    val qs = params.joinToString("&") { (k, v) -> "$k=${encodeFormValue(v)}" }
    return "$path?$qs"
}

private fun encodeFormValue(s: String): String = URLEncoder.encode(s, StandardCharsets.UTF_8)
