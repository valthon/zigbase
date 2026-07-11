package io.github.valthon.zigbase.typed

import io.github.valthon.zigbase.query.filterValue

// Fluent injection-safe filter builder -- mirrors clients/dart/lib/typed.dart:202-305
// and clients/python/src/zigbase/typed.py:281-492.
//
// Every operand this DSL interpolates flows through the base SDK's
// `io.github.valthon.zigbase.query.filterValue` -- this file never formats
// an operand itself. Unlike the Python/Dart ports, Kotlin cannot overload
// `==`/`<`/`&`/`|` to return a non-`Boolean` `Expr`, so operators are plain
// `infix` methods (`f.age gt 18`) and combinators are `infix fun and`/`or`
// (`(f.a eq 1) and (f.b eq 2)`). That also means there is no `__bool__`-style
// implicit-boolean-coercion footgun to guard against here: Kotlin's `&&`/
// `||`/`and`/`or` keywords require a real `Boolean` operand, so an `Expr`
// can never be silently discarded the way Python's `and`/`or`/chained
// comparisons can.

private val OP_MAP: Map<String, String> =
    mapOf(
        "eq" to "=",
        "neq" to "!=",
        "gt" to ">",
        "gte" to ">=",
        "lt" to "<",
        "lte" to "<=",
        "like" to "~",
        "nlike" to "!~",
    )

/**
 * A compiled boolean filter expression.
 *
 * Combine with the [and]/[or] infix combinators (each parenthesizes the
 * result to make precedence explicit) and read the wire string via
 * [compile].
 *
 * Port of `Expr` in `clients/python/src/zigbase/typed.py`.
 */
class Expr internal constructor(
    private val src: String,
) {
    /** The ZigBase filter string this expression compiles to. */
    fun compile(): String = src

    override fun toString(): String = src
}

/** `(a && b)`. Port of `Expr.and_`/`Expr.__and__` in `clients/python/src/zigbase/typed.py`. */
infix fun Expr.and(other: Expr): Expr = Expr("(${this.compile()} && ${other.compile()})")

/** `(a || b)`. Port of `Expr.or_`/`Expr.__or__` in `clients/python/src/zigbase/typed.py`. */
infix fun Expr.or(other: Expr): Expr = Expr("(${this.compile()} || ${other.compile()})")

/**
 * Base per-field accessor: equality + membership.
 *
 * Every operand is serialized through [filterValue] -- this class and its
 * subclasses never format an operand themselves.
 *
 * Port of `FieldExpr` in `clients/python/src/zigbase/typed.py`.
 */
open class FieldExpr(
    protected val path: String,
) {
    protected fun op(
        key: String,
        value: Any?,
    ): Expr = Expr("$path ${OP_MAP.getValue(key)} ${filterValue(value)}")

    infix fun eq(value: Any?): Expr = op("eq", value)

    infix fun neq(value: Any?): Expr = op("neq", value)

    /**
     * `path in (v1, v2)`. An empty list emits `path in ()`, which the
     * server compiles to constant-false.
     */
    fun inList(values: List<Any?>): Expr {
        val rendered = values.joinToString(", ") { filterValue(it) }
        return Expr("$path in ($rendered)")
    }
}

/**
 * A field that supports ordered comparisons (numbers, dates, strings).
 *
 * Port of `ComparableFieldExpr` in `clients/python/src/zigbase/typed.py`.
 */
open class ComparableFieldExpr(
    path: String,
) : FieldExpr(path) {
    infix fun gt(value: Any?): Expr = op("gt", value)

    infix fun gte(value: Any?): Expr = op("gte", value)

    infix fun lt(value: Any?): Expr = op("lt", value)

    infix fun lte(value: Any?): Expr = op("lte", value)
}

/**
 * A `text`/`email`/`url`/`editor` field: comparisons + `~`/`!~` pattern match.
 *
 * Port of `StringFieldExpr` in `clients/python/src/zigbase/typed.py`.
 */
class StringFieldExpr(
    path: String,
) : ComparableFieldExpr(path) {
    infix fun like(value: String): Expr = op("like", value)

    infix fun nlike(value: String): Expr = op("nlike", value)
}

/**
 * A `number` field. Operands are any [Number] (`Int`/`Long`/`Double`);
 * [filterValue] renders each correctly.
 *
 * Port of `NumFieldExpr` in `clients/python/src/zigbase/typed.py`.
 */
class NumberFieldExpr(
    path: String,
) : ComparableFieldExpr(path)

/**
 * A `date`/`autodate` field -- comparisons accept an `Instant`/
 * `OffsetDateTime` or an ISO string; [filterValue] renders either correctly.
 *
 * Port of `DateFieldExpr` in `clients/python/src/zigbase/typed.py`.
 */
class DateFieldExpr(
    path: String,
) : ComparableFieldExpr(path)

/**
 * A `boolean` field.
 *
 * Port of `BoolFieldExpr` in `clients/python/src/zigbase/typed.py`.
 */
class BoolFieldExpr(
    path: String,
) : FieldExpr(path)

/**
 * A `select` field typed to its generated enum [E]. Serializes the enum to
 * its wire string via [wireOf] before handing it to [filterValue].
 *
 * Deliberately does NOT extend [FieldExpr]: a subclass member with the same
 * name (`eq`/`neq`/`inList`) but a generic `E?` parameter erases to the same
 * JVM signature as the inherited `Any?` overload (a "platform declaration
 * clash"), since `E` is unbounded. Standing alone avoids that clash while
 * still exposing the identical `path`-based DSL surface.
 *
 * Port of `EnumFieldExpr` in `clients/python/src/zigbase/typed.py`.
 */
class EnumFieldExpr<E>(
    private val path: String,
    private val wireOf: (E) -> String,
) {
    infix fun eq(value: E?): Expr = Expr("$path = ${filterWire(value)}")

    infix fun neq(value: E?): Expr = Expr("$path != ${filterWire(value)}")

    /** `path in (v1, v2)`, each element serialized via [wireOf] first. */
    fun inList(values: List<E?>): Expr {
        val rendered = values.joinToString(", ") { filterWire(it) }
        return Expr("$path in ($rendered)")
    }

    // `null` must reach `filterValue` un-wired -- `wireOf` (e.g. `Status::wire`)
    // has no defined behavior for `null`, and every other FieldExpr already
    // renders `null` -> `null` via `filterValue` alone.
    private fun filterWire(value: E?): String = filterValue(if (value == null) null else wireOf(value))
}

/**
 * A `relation` field: id-level ops (inherited from [FieldExpr]) plus one
 * level of nested-relation filtering via [rel], e.g.
 * `author.rel { it.name like "A" }` -> `author.name ~ 'A'`. [F] is the
 * target collection's generated fields builder.
 *
 * Port of `RelFieldExpr` in `clients/python/src/zigbase/typed.py`.
 */
class RelFieldExpr<F>(
    path: String,
    private val makeFields: (String) -> F,
) : FieldExpr(path) {
    /**
     * Builds a filter over the related record's fields by prefixing the
     * target fields builder with `"$path."` (one nesting level, matching
     * the Python/Dart ports).
     */
    fun <R> rel(build: (F) -> R): R = build(makeFields("$path."))
}
