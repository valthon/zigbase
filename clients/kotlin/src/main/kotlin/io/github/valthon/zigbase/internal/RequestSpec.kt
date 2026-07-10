package io.github.valthon.zigbase.internal

import io.ktor.http.HttpMethod

/**
 * One logical HTTP request, before header/auth/body assembly.
 *
 * Port of `RequestSpec` in `clients/python/src/zigbase/_request.py` /
 * `RequestOptions` in `clients/typescript/src/transport.ts`. Nothing here
 * performs I/O -- [Transport] is what actually sends a [RequestSpec] over
 * the wire. [path] is the request path (e.g.
 * `/api/collections/posts/records`) with any dynamic segments already
 * percent-encoded via [encodePathSegment] -- the transport concatenates it
 * onto the base URL verbatim. [body], when present, is encoded by
 * `io.github.valthon.zigbase.internal.encodeBody` (JSON, or multipart if it
 * contains a [io.github.valthon.zigbase.FileArg]). [isRefresh] marks the
 * transport's own `auth-refresh` call so a 401 on it propagates instead of
 * recursing into the single-flight refresh path.
 */
internal data class RequestSpec(
    val method: HttpMethod,
    val path: String,
    val query: Map<String, String>? = null,
    val body: Map<String, Any?>? = null,
    val skipAuth: Boolean = false,
    val isRefresh: Boolean = false,
    val headers: Map<String, String>? = null,
)

/** The RFC 3986 unreserved characters -- the exact set `encodeURIComponent` leaves untouched. */
private val UNRESERVED_PATH_CHARS: Set<Char> =
    buildSet {
        addAll('A'..'Z')
        addAll('a'..'z')
        addAll('0'..'9')
        addAll(listOf('-', '_', '.', '!', '~', '*', '\'', '(', ')'))
    }

/**
 * Percent-encodes a single path segment, escaping every byte outside the
 * RFC 3986 unreserved set -- including `/`, since a caller-supplied id/name
 * must never be interpreted as introducing a new path segment.
 *
 * `java.net.URLEncoder` is form (`application/x-www-form-urlencoded`)
 * encoding -- it turns a space into `+`, not `%20` -- so it cannot stand in
 * for JS `encodeURIComponent` / Python `urllib.parse.quote(s, safe="")`.
 * This encodes the UTF-8 bytes of [s] directly instead, matching
 * `encodeURIComponent`'s unreserved set byte-for-byte, including for
 * non-ASCII input (each UTF-8 byte of a multi-byte character is escaped
 * individually).
 */
internal fun encodePathSegment(s: String): String {
    val bytes = s.toByteArray(Charsets.UTF_8)
    val out = StringBuilder(bytes.size)
    for (b in bytes) {
        val unsigned = b.toInt() and 0xFF
        val c = unsigned.toChar()
        if (unsigned < 0x80 && c in UNRESERVED_PATH_CHARS) {
            out.append(c)
        } else {
            out.append('%')
            out.append(HEX_DIGITS[(unsigned shr 4) and 0xF])
            out.append(HEX_DIGITS[unsigned and 0xF])
        }
    }
    return out.toString()
}

private val HEX_DIGITS = "0123456789ABCDEF"
