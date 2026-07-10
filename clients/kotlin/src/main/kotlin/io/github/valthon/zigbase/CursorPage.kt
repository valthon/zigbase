package io.github.valthon.zigbase

/**
 * One page of native server-side cursor (keyset) pagination
 * ([CollectionService.getPage]).
 *
 * The server (`src/api/records.zig` + `src/query/keyset.zig`) mints the
 * opaque `nextCursor`/`prevCursor` tokens; this client forwards whatever it
 * received verbatim and never decodes, validates, or synthesizes one.
 * [totalItems] is `null` unless the page was fetched with `withTotal = true`.
 */
data class CursorPage(
    val items: List<ZbRecord>,
    val nextCursor: String?,
    val prevCursor: String?,
    val hasNext: Boolean,
    val hasPrev: Boolean,
    val totalItems: Int?,
)
