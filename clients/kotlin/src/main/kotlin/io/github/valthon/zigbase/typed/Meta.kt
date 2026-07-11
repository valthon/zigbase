package io.github.valthon.zigbase.typed

/**
 * The typed-tier runtime's semver, mirrored in a generated client's header
 * comment (kept in sync by hand, like `gen_python.zig`'s
 * `TYPED_CORE_VERSION`).
 */
const val TYPED_CORE_VERSION = "0.1.0"

/**
 * The ZigBase field-type universe (mirrors the server's field table).
 *
 * Port of `FieldType` in `clients/python/src/zigbase/typed.py`.
 */
enum class FieldType(
    val wire: String,
) {
    TEXT("text"),
    EDITOR("editor"),
    EMAIL("email"),
    URL("url"),
    NUMBER("number"),
    BOOLEAN("boolean"),
    DATE("date"),
    AUTODATE("autodate"),
    SELECT("select"),
    RELATION("relation"),
    FILE("file"),
    JSON("json"),
}

/**
 * Numeric storage mode.
 *
 * `FLOAT` fields are plain doubles on the wire; `INTEGER` and `FIXED` fields
 * are transmitted as **decimal strings** (the server scales them to
 * integers for full precision) and are coerced both directions by generated
 * (de)serialization.
 *
 * Port of `NumberMode` in `clients/python/src/zigbase/typed.py`.
 */
enum class NumberMode { FLOAT, INTEGER, FIXED }

/**
 * Per-field runtime descriptor.
 *
 * `mode`/`scale` carry the int-vs-fixed numeric distinction that drives
 * decimal-string coercion (float fields use [NumberMode.FLOAT] and are never
 * coerced).
 *
 * Port of `FieldMeta` in `clients/python/src/zigbase/typed.py`.
 */
data class FieldMeta(
    val type: FieldType,
    val multi: Boolean = false,
    val mode: NumberMode = NumberMode.FLOAT,
    val scale: Int? = null,
)

/**
 * Per-collection runtime descriptor.
 *
 * `name` doubles as the realtime topic and the `client.collection(name)`
 * key.
 *
 * Port of `CollectionMeta` in `clients/python/src/zigbase/typed.py`.
 */
data class CollectionMeta(
    val name: String,
    val fields: Map<String, FieldMeta>,
    val fileFields: List<String> = emptyList(),
    val expandable: List<String> = emptyList(),
    val isAuth: Boolean = false,
    // Field names with full-text search enabled (server >= 0.9.0); null = none.
    val searchable: List<String>? = null,
    // Tenant-owning field name; the server stamps it on create. null = not tenant-owned.
    val tenant: String? = null,
) {
    /** Safe field lookup by name. */
    fun field(name: String): FieldMeta? = fields[name]
}
