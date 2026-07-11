package io.github.valthon.zigbase.typed

import io.github.valthon.zigbase.query.filterValue
import io.github.valthon.zigbase.query.formatDate
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test
import java.time.Instant

/**
 * Tests for the `typed` fluent filter DSL ([Expr]/[FieldExpr] and its
 * per-type subclasses), a port of `clients/python/tests/test_typed_where.py`
 * (itself a port of `clients/dart/lib/typed.dart:202-305` and
 * `clients/dart/test/typed_where_test.dart`) — mirrored byte-for-byte on
 * compiled output. Python's `Expr.__bool__` guard and `__eq__`/`__ne__`
 * dunder-sugar tests have no Kotlin analog: `eq`/`neq`/`gt`/... are plain
 * `infix` methods here (Kotlin cannot overload `==`/`<`/`&&`/`||` to return
 * a non-`Boolean`), so there is no implicit-bool-coercion footgun to guard
 * against.
 */

private enum class Status(
    val w: String,
) {
    DRAFT("draft"),
    PUBLISHED("published"),
}

private fun statusWire(s: Status): String = s.w

/** A minimal generated-style fields builder for a `users` collection, used as the nested-relation target below. */
private class UserFields(
    private val prefix: String = "",
) {
    val name: StringFieldExpr get() = StringFieldExpr("${prefix}name")
    val age: NumberFieldExpr get() = NumberFieldExpr("${prefix}age")
}

/** A minimal generated-style fields builder for a `posts` collection with a nested `author` relation to `users`. */
private class PostFields(
    private val prefix: String = "",
) {
    val title: StringFieldExpr get() = StringFieldExpr("${prefix}title")
    val status: EnumFieldExpr<Status> get() = EnumFieldExpr("${prefix}status", ::statusWire)
    val price: NumberFieldExpr get() = NumberFieldExpr("${prefix}price")
    val active: BoolFieldExpr get() = BoolFieldExpr("${prefix}active")
    val publishedAt: DateFieldExpr get() = DateFieldExpr("${prefix}publishedAt")
    val author: RelFieldExpr<UserFields> get() = RelFieldExpr("${prefix}author") { UserFields(it) }
}

private val f = PostFields()

class ScalarOperatorsTest {
    @Test
    fun `string comparisons and pattern match`() {
        assertEquals("title = 'hi'", (f.title eq "hi").compile())
        assertEquals("title != 'hi'", (f.title neq "hi").compile())
        assertEquals("title ~ 'foo'", (f.title like "foo").compile())
        assertEquals("title !~ 'foo'", (f.title nlike "foo").compile())
    }

    @Test
    fun `string ordering`() {
        assertEquals("title > 'a'", (f.title gt "a").compile())
        assertEquals("title >= 'a'", (f.title gte "a").compile())
        assertEquals("title < 'z'", (f.title lt "z").compile())
        assertEquals("title <= 'z'", (f.title lte "z").compile())
    }

    @Test
    fun `number comparisons`() {
        assertEquals("price >= 10", (f.price gte 10).compile())
        assertEquals("price < 2.5", (f.price lt 2.5).compile())
        assertEquals("price > 1", (f.price gt 1).compile())
        assertEquals("price <= 9", (f.price lte 9).compile())
    }

    @Test
    fun `bool eq`() {
        assertEquals("active = true", (f.active eq true).compile())
        assertEquals("active != false", (f.active neq false).compile())
    }

    @Test
    fun `all eight ops via op map`() {
        assertEquals("price = 1", (f.price eq 1).compile())
        assertEquals("price != 1", (f.price neq 1).compile())
        assertEquals("price > 1", (f.price gt 1).compile())
        assertEquals("price >= 1", (f.price gte 1).compile())
        assertEquals("price < 1", (f.price lt 1).compile())
        assertEquals("price <= 1", (f.price lte 1).compile())
        assertEquals("title ~ 'x'", (f.title like "x").compile())
        assertEquals("title !~ 'x'", (f.title nlike "x").compile())
    }
}

class NumberFieldExprTest {
    @Test
    fun `accepts int long and double operands`() {
        assertEquals("price = 1", (f.price eq 1).compile())
        assertEquals("price = 10", (f.price eq 10L).compile())
        assertEquals("price = 2.5", (f.price eq 2.5).compile())
    }
}

class EnumFieldTest {
    @Test
    fun `eq neq and inList serialize via wireOf`() {
        assertEquals("status = 'published'", (f.status eq Status.PUBLISHED).compile())
        assertEquals("status != 'draft'", (f.status neq Status.DRAFT).compile())
        assertEquals(
            "status in ('draft', 'published')",
            f.status.inList(listOf(Status.DRAFT, Status.PUBLISHED)).compile(),
        )
    }

    @Test
    fun `eq and neq pass null through to null without calling wireOf`() {
        assertEquals("status = null", (f.status eq null).compile())
        assertEquals("status != null", (f.status neq null).compile())
    }

    @Test
    fun `inList null element passes through to null`() {
        assertEquals("status in ('draft', null)", f.status.inList(listOf(Status.DRAFT, null)).compile())
    }

    @Test
    fun `null handling matches a plain FieldExpr`() {
        assertEquals(
            (f.title eq null).compile().replace("title", "status"),
            (f.status eq null).compile(),
        )
        assertEquals(
            (f.title neq null).compile().replace("title", "status"),
            (f.status neq null).compile(),
        )
    }

    @Test
    fun `a raw enum reaching filterValue directly throws`() {
        // Regression guard: EnumFieldExpr.eq/neq/inList must serialize via
        // wireOf before calling filterValue -- filterValue itself has no
        // enum branch and must reject a raw enum member.
        assertThrows(IllegalArgumentException::class.java) { filterValue(Status.PUBLISHED) }
    }
}

class InListTest {
    @Test
    fun `non-empty values render comma-separated`() {
        assertEquals("title in ('a', 'b')", f.title.inList(listOf("a", "b")).compile())
    }

    @Test
    fun `empty list emits constant-false form`() {
        assertEquals("title in ()", f.title.inList(emptyList()).compile())
    }
}

class AndOrParenthesizeTest {
    @Test
    fun `and combines and parenthesizes`() {
        val e = (f.price gte 10) and (f.status eq Status.PUBLISHED)
        assertEquals("(price >= 10 && status = 'published')", e.compile())
    }

    @Test
    fun `or combines and parenthesizes`() {
        val e = (f.title eq "a") or (f.title eq "b")
        assertEquals("(title = 'a' || title = 'b')", e.compile())
    }

    @Test
    fun `nesting and-or preserves precedence via parens`() {
        val a = f.price gte 10
        val b = f.status eq Status.PUBLISHED
        val c = f.active eq true
        val e = (a and b) or c
        assertEquals("((price >= 10 && status = 'published') || active = true)", e.compile())
    }
}

class RelationFieldsTest {
    @Test
    fun `id-level eq`() {
        assertEquals("author = 'u1'", (f.author eq "u1").compile())
    }

    @Test
    fun `nested relation where builds a dotted path`() {
        assertEquals("author.name ~ 'Ann'", f.author.rel { it.name like "Ann" }.compile())
        assertEquals("author.age > 21", f.author.rel { it.age gt 21 }.compile())
    }
}

class InjectionSafetyTest {
    @Test
    fun `escapes single quotes`() {
        assertEquals("title = 'O\\'Brien'", (f.title eq "O'Brien").compile())
    }

    @Test
    fun `escapes single quotes in inList`() {
        assertEquals("title in ('O\\'Brien')", f.title.inList(listOf("O'Brien")).compile())
    }
}

class DateFieldTest {
    @Test
    fun `Instant operand renders via formatDate`() {
        val instant = Instant.parse("2024-01-02T03:04:05.678Z")
        val expected = "publishedAt >= '${formatDate(instant)}'"
        assertEquals(expected, (f.publishedAt gte instant).compile())
    }

    @Test
    fun `ISO string operand is quoted as-is`() {
        assertEquals(
            "publishedAt = '2024-01-02T03:04:05.678Z'",
            (f.publishedAt eq "2024-01-02T03:04:05.678Z").compile(),
        )
    }
}

class UnsupportedOperandsTest {
    @Test
    fun `a List operand throws IllegalArgumentException`() {
        assertThrows(IllegalArgumentException::class.java) { f.title.eq(listOf("a", "b")) }
    }
}
