package io.github.valthon.zigbase.query

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset

/**
 * Port of `clients/python/tests/test_query.py` (itself a port of
 * `clients/typescript/test/query-filter.test.ts` +
 * `clients/dart/test/query_test.dart`). Every SDK must byte-match the
 * server's filter lexer (`src/query/lexer.zig`), so these fixtures are
 * intentionally duplicated rather than shared.
 */
class FilterValueTest {
    @Test
    fun `passes through null, bool, and finite numbers bare`() {
        assertEquals("null", filterValue(null))
        assertEquals("true", filterValue(true))
        assertEquals("false", filterValue(false))
        assertEquals("5", filterValue(5))
        assertEquals("3.14", filterValue(3.14))
    }

    @Test
    fun `integral float renders bare, not 1point0`() {
        assertEquals("1", filterValue(1.0))
        assertEquals("2.5", filterValue(2.5))
        assertEquals("0", filterValue(-0.0))
    }

    @Test
    fun `long renders bare`() {
        assertEquals("9007199254740993", filterValue(9007199254740993L))
    }

    @Test
    fun `single-quotes a plain string`() {
        assertEquals("'published'", filterValue("published"))
    }

    @Test
    fun `escapes an embedded single quote`() {
        assertEquals("""'O\'Brien'""", filterValue("O'Brien"))
    }

    @Test
    fun `leaves an embedded double quote literal`() {
        assertEquals("""'say "hi"'""", filterValue("say \"hi\""))
    }

    @Test
    fun `represents a value with both single and double quotes`() {
        assertEquals(
            """'he said "hi" to O\'Brien'""",
            filterValue("he said \"hi\" to O'Brien"),
        )
    }

    @Test
    fun `escapes backslashes`() {
        assertEquals("""'a\\b'""", filterValue("""a\b"""))
    }

    @Test
    fun `escapes control characters`() {
        assertEquals("""'a\nb\tc\rd'""", filterValue("a\nb\tc\rd"))
    }

    @Test
    fun `neutralizes an injection attempt`() {
        // The leading single quote is escaped, so the payload can never break
        // out of the single-quoted literal; the closing quote must never
        // appear unescaped anywhere in the output.
        val evil = "' || 1=1 --"
        val result = filterValue(evil)
        assertEquals("""'\' || 1=1 --'""", result)
        assertEquals('\'', result.first())
        assertEquals('\'', result.last())
        val inner = result.substring(1, result.length - 1)
        var i = 0
        while (true) {
            val idx = inner.indexOf('\'', i)
            if (idx == -1) break
            assertEquals('\\', inner[idx - 1], "unescaped quote at $idx in $inner")
            i = idx + 1
        }
    }

    @Test
    fun `serializes an Instant as a single-quoted UTC ISO string`() {
        val instant = Instant.parse("2026-06-16T00:00:00Z")
        assertEquals("'2026-06-16T00:00:00.000Z'", filterValue(instant))
    }

    @Test
    fun `clamps an Instant to millisecond precision (truncating, not rounding)`() {
        val instant = Instant.parse("2026-01-02T03:04:05.678901234Z")
        assertEquals("'2026-01-02T03:04:05.678Z'", filterValue(instant))
    }

    @Test
    fun `serializes an OffsetDateTime by converting to UTC first`() {
        val odt = OffsetDateTime.of(2026, 1, 2, 0, 0, 0, 0, ZoneOffset.ofHours(-5))
        assertEquals("'2026-01-02T05:00:00.000Z'", filterValue(odt))
    }

    @Test
    fun `raises on List operand`() {
        val ex = assertThrows(IllegalArgumentException::class.java) { filterValue(listOf(1, 2)) }
        assertTrue(ex.message!!.contains("array", ignoreCase = true))
    }

    @Test
    fun `raises on Map operand`() {
        val ex = assertThrows(IllegalArgumentException::class.java) { filterValue(mapOf("a" to 1)) }
        assertTrue(ex.message!!.contains("unsupported operand", ignoreCase = true))
    }

    @Test
    fun `raises on non-finite Double`() {
        for (v in listOf(Double.NaN, Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY)) {
            val ex = assertThrows(IllegalArgumentException::class.java) { filterValue(v) }
            assertTrue(ex.message!!.contains("non-finite", ignoreCase = true))
        }
    }

    @Test
    fun `raises on non-finite Float`() {
        val ex = assertThrows(IllegalArgumentException::class.java) { filterValue(Float.NaN) }
        assertTrue(ex.message!!.contains("non-finite", ignoreCase = true))
    }

    @Test
    fun `raises on an unsupported type`() {
        val ex = assertThrows(IllegalArgumentException::class.java) { filterValue(Any()) }
        assertTrue(ex.message!!.contains("unsupported operand", ignoreCase = true))
    }

    @Test
    fun `large and small exponent boundaries match JS Number toString`() {
        // ECMA-262 Number::toString notation-switch boundaries: fixed up to
        // 1e21 (exclusive), exponential at/after; fixed down to 1e-6
        // (inclusive), exponential below.
        assertEquals("100000000000000000000", filterValue(1e20))
        assertEquals("1e+21", filterValue(1e21))
        assertEquals("0.000001", filterValue(1e-6))
        assertEquals("1e-7", filterValue(1e-7))
        assertEquals("0.30000000000000004", filterValue(0.1 + 0.2))
    }

    @Test
    fun `a Float widens to its exact binary32 value, not its decimal literal`() {
        // 3.14f is not exactly 3.14 in binary32; widening to Double is exact
        // (no further precision loss), so the shortest round-trip digits of
        // the WIDENED value are longer than "3.14". Callers that need JS-Number
        // decimal fidelity should pass Double, not Float.
        assertEquals(filterValue(3.14f.toDouble()), filterValue(3.14f))
    }
}

class FormatJsNumberTest {
    @Test
    fun `renders integral doubles bare`() {
        assertEquals("1", formatJsNumber(1.0))
        assertEquals("100", formatJsNumber(100.0))
        assertEquals("-5", formatJsNumber(-5.0))
    }

    @Test
    fun `collapses negative zero to a bare zero`() {
        assertEquals("0", formatJsNumber(-0.0))
        assertEquals("0", formatJsNumber(0.0))
    }

    @Test
    fun `renders a simple fraction`() {
        assertEquals("2.5", formatJsNumber(2.5))
        assertEquals("3.14", formatJsNumber(3.14))
    }

    @Test
    fun `fixed notation up to and including 1e20`() {
        assertEquals("100000000000000000000", formatJsNumber(1e20))
    }

    @Test
    fun `exponential notation at 1e21`() {
        assertEquals("1e+21", formatJsNumber(1e21))
    }

    @Test
    fun `fixed notation at 1e-6`() {
        assertEquals("0.000001", formatJsNumber(1e-6))
    }

    @Test
    fun `exponential notation below 1e-6`() {
        assertEquals("1e-7", formatJsNumber(1e-7))
    }

    @Test
    fun `binary rounding artifact renders the full shortest round-trip digits`() {
        assertEquals("0.30000000000000004", formatJsNumber(0.1 + 0.2))
    }

    @Test
    fun `negative exponential values keep the sign before the mantissa`() {
        assertEquals("-1e-7", formatJsNumber(-1e-7))
        assertEquals("-1e+21", formatJsNumber(-1e21))
    }

    @Test
    fun `multi-digit mantissa in exponential notation gets a decimal point`() {
        assertEquals("1.1e+128", formatJsNumber(1.1e128))
    }

    @Test
    fun `extreme magnitudes round-trip`() {
        assertEquals("1.7976931348623157e+308", formatJsNumber(Double.MAX_VALUE))
        assertEquals("5e-324", formatJsNumber(Double.MIN_VALUE))
    }

    @Test
    fun `power-of-two magnitudes use the shorter asymmetric-interval candidate`() {
        // At a power of two, the double's rounding interval is asymmetric: the
        // gap down to the previous representable double is half the gap up to
        // the next one (the previous double sits in a lower binade with a
        // smaller ULP). A single-candidate nearest/HALF_EVEN search assumes a
        // symmetric interval and can therefore reject a shorter digit string
        // that legitimately round-trips, silently emitting one digit too many.
        // 2^-24's exact decimal expansion terminates at 17 digits
        // ("...90625"), but the true shortest round-tripping decimal is the
        // 16-digit "...9063" (rounding away from the exact value, into the
        // wider side of the interval) — verified against Python's repr()
        // (itself a correct shortest-round-trip implementation) and V8.
        assertEquals("5.960464477539063e-8", formatJsNumber(Math.pow(2.0, -24.0)))
        // A second, unrelated-magnitude power-of-two-adjacent fixture from the
        // same asymmetric-interval family.
        assertEquals("5.641232424577593e-278", formatJsNumber(5.641232424577593e-278))
    }
}

class FormatDateTest {
    @Test
    fun `formats an aware UTC instant`() {
        assertEquals("2026-06-16T00:00:00.000Z", formatDate(Instant.parse("2026-06-16T00:00:00Z")))
    }

    @Test
    fun `truncates sub-millisecond precision (floors, does not round)`() {
        val instant = Instant.parse("2026-01-02T03:04:05.678999999Z")
        assertEquals("2026-01-02T03:04:05.678Z", formatDate(instant))
    }

    @Test
    fun `zero-pads a sub-100ms fraction to three digits`() {
        val instant = Instant.parse("2026-01-02T03:04:05.005Z")
        assertEquals("2026-01-02T03:04:05.005Z", formatDate(instant))
    }
}

class ZbFilterTest {
    @Test
    fun `interpolates named placeholders`() {
        assertEquals(
            "status = 'pub' && n > 5",
            zbFilter("status = {:s} && n > {:n}", mapOf("s" to "pub", "n" to 5)),
        )
    }

    @Test
    fun `supports repeated placeholders and static text`() {
        assertEquals(
            "'x' = 'x' && b = true",
            zbFilter("{:a} = {:a} && b = {:b}", mapOf("a" to "x", "b" to true)),
        )
    }

    @Test
    fun `raises on an unknown placeholder`() {
        assertThrows(IllegalArgumentException::class.java) {
            zbFilter("x = {:missing}", emptyMap())
        }
    }

    @Test
    fun `raises on an unused param`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                zbFilter("x = {:a}", mapOf("a" to 1, "b" to 2))
            }
        assertTrue(ex.message!!.contains("unused", ignoreCase = true))
    }

    @Test
    fun `passes through an expression with no placeholders`() {
        assertEquals("status = \"published\"", zbFilter("status = \"published\"", emptyMap()))
    }

    @Test
    fun `injection attempt via placeholder stays inert`() {
        assertEquals(
            """name = '\' || 1=1 --'""",
            zbFilter("name = {:v}", mapOf("v" to "' || 1=1 --")),
        )
    }
}

class VectorSpecTest {
    @Test
    fun `formats field, metric, and json array`() {
        assertEquals("emb:cosine:[1,2.5]", vectorSpec("emb", listOf(1.0, 2.5), "cosine"))
    }

    @Test
    fun `omits the metric segment when absent`() {
        assertEquals("emb:[0.1,0.2]", vectorSpec("emb", listOf(0.1, 0.2)))
    }

    @Test
    fun `matches the typescript fixture values`() {
        assertEquals("embedding:[0.12,0.04]", vectorSpec("embedding", listOf(0.12, 0.04)))
        assertEquals("embedding:cosine:[1,2]", vectorSpec("embedding", listOf(1.0, 2.0), "cosine"))
        assertEquals("embedding:l2:[0.5]", vectorSpec("embedding", listOf(0.5), "l2"))
    }

    @Test
    fun `raises on a non-finite embedding value`() {
        assertThrows(IllegalArgumentException::class.java) { vectorSpec("e", listOf(Double.NaN)) }
        assertThrows(IllegalArgumentException::class.java) {
            vectorSpec("e", listOf(Double.POSITIVE_INFINITY))
        }
    }
}

class BuildListParamsTest {
    @Test
    fun `omits all absent params`() {
        assertTrue(buildListParams().isEmpty())
    }

    @Test
    fun `includes only provided params with wire names`() {
        val params =
            buildListParams(
                filter = "status = 'x'",
                sort = "-created",
                expand = "author",
                fields = "id,title",
                search = "hello",
                page = 2,
                perPage = 50,
                skipTotal = true,
                vector = "embedding:[0.1]",
            )
        assertEquals(
            mapOf(
                "filter" to "status = 'x'",
                "sort" to "-created",
                "expand" to "author",
                "fields" to "id,title",
                "search" to "hello",
                "page" to "2",
                "perPage" to "50",
                "skipTotal" to "true",
                "vector" to "embedding:[0.1]",
            ),
            params,
        )
    }

    @Test
    fun `never emits an empty cursor or limit when absent`() {
        val params = buildListParams(page = 1, perPage = 30)
        assertFalse(params.containsKey("cursor"))
        assertFalse(params.containsKey("limit"))
    }

    @Test
    fun `cursor mode params`() {
        assertEquals(
            mapOf("cursor" to "abc123", "limit" to "25", "skipTotal" to "false"),
            buildListParams(cursor = "abc123", limit = 25, skipTotal = false),
        )
    }

    @Test
    fun `an explicitly-passed empty string cursor is still emitted`() {
        // An explicit empty cursor means "first page" in cursor mode and must
        // not be conflated with an absent (null) cursor.
        assertEquals(mapOf("cursor" to ""), buildListParams(cursor = ""))
    }
}
