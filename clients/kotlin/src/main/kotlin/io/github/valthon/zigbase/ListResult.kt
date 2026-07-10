package io.github.valthon.zigbase

/**
 * Result of an offset-paginated [CollectionService.getList] call. Mirrors the
 * wire envelope; a missing total field defaults to `0` (parity with
 * `clients/dart/lib/src/records.dart`'s `ListResult.fromJson`).
 */
data class ListResult(
    val page: Int,
    val perPage: Int,
    val totalItems: Int,
    val totalPages: Int,
    val items: List<ZbRecord>,
)
