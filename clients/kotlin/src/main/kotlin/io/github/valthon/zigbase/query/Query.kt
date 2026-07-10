package io.github.valthon.zigbase.query

import java.math.BigDecimal
import java.math.MathContext
import java.math.RoundingMode
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter

/**
 * Query helpers for the ZigBase API.
 *
 * Port of `clients/typescript/src/query.ts` (`filterValue`, `vectorSpec`),
 * with the named-placeholder `zbFilter("... {:key}", mapOf(...))` API and
 * reject-don't-coerce hardening from `clients/dart/lib/src/query.dart` and
 * `clients/python/src/zigbase/query.py`.
 *
 * `filterValue`/`zbFilter` are security-critical: the server's filter lexer
 * (`src/query/lexer.zig`) is the arbiter of the wire format, so the escaping
 * and number/date rendering here must byte-match the TypeScript/Python/Dart
 * SDKs exactly. See [formatJsNumber] for how JS `Number.prototype.toString()`
 * / `JSON.stringify()` formatting is reproduced on the JVM.
 */

private val ESCAPES =
    mapOf(
        '\\' to "\\\\",
        '\'' to "\\'",
        '\n' to "\\n",
        '\t' to "\\t",
        '\r' to "\\r",
    )

/**
 * Single-quotes [s] as a filter literal, escaping backslash/quote/CRLF/tab.
 *
 * The server lexer unescapes `\\`, `\'`, `\n`, `\t`, `\r` inside a quoted
 * string. Escaping exactly those bytes (and leaving everything else,
 * including a double quote, literal) means the closing single quote can
 * never appear unescaped — the literal can never be broken out of.
 */
private fun quoteString(s: String): String {
    val sb = StringBuilder(s.length + 2)
    sb.append('\'')
    for (c in s) {
        val esc = ESCAPES[c]
        if (esc != null) sb.append(esc) else sb.append(c)
    }
    sb.append('\'')
    return sb.toString()
}

/**
 * Extracts the shortest round-trip decimal digits of a positive finite
 * [value], returning `(digits, point)` such that `value == digits.toLong() *
 * 10^(point - digits.length)` and `digits` has no leading or trailing zero.
 *
 * This does NOT rely on [Double.toString]'s own digit count. The classic
 * (pre-JDK 19) `Double.toString` algorithm is documented (JDK-4511638) to
 * not always produce the *shortest* round-tripping decimal — only a correct
 * (round-tripping) one — and this SDK is pinned to JDK 17 (`mise.toml`).
 *
 * At each candidate precision `1..17` (the maximum any `double` ever needs)
 * this rounds [BigDecimal]'s *exact* binary expansion of [value] BOTH ways —
 * `FLOOR` and `CEILING` — rather than to a single nearest/`HALF_EVEN`
 * candidate. A single-candidate nearest search is only correct when the
 * decimal-to-binary rounding interval around [value] is symmetric, which it
 * is NOT at a power of two: the gap down to the previous representable
 * double there is half the gap up to the next one (the previous double sits
 * in a lower binade with a smaller ULP), so the true shortest round-tripping
 * decimal can require rounding *away* from the nearest digit sequence, into
 * the wider side of the interval — a case `HALF_EVEN` alone silently misses,
 * emitting one digit more than necessary. `Double.parseDouble` (via
 * `BigDecimal.doubleValue()`) is a correctly-rounded oracle, so testing both
 * directional candidates and accepting the first precision where either
 * round-trips is provably minimal regardless of `Double.toString`'s
 * behavior on any given JVM. When both candidates round-trip at the same
 * precision, ECMA-262's tie rule applies: prefer the one numerically closer
 * to the exact value, and on an exact tie prefer the one with an even last
 * digit.
 */
private fun shortestDigits(value: Double): Pair<String, Int> {
    val exact = BigDecimal(value)
    for (precision in 1..17) {
        val floor = exact.round(MathContext(precision, RoundingMode.FLOOR))
        val ceiling = exact.round(MathContext(precision, RoundingMode.CEILING))
        val floorRoundTrips = floor.toDouble() == value
        val ceilingRoundTrips = ceiling.toDouble() == value
        if (!floorRoundTrips && !ceilingRoundTrips) continue

        val chosen =
            when {
                floorRoundTrips && !ceilingRoundTrips -> {
                    floor
                }

                ceilingRoundTrips && !floorRoundTrips -> {
                    ceiling
                }

                else -> {
                    val distanceToFloor = exact.subtract(floor).abs()
                    val distanceToCeiling = ceiling.subtract(exact).abs()
                    val cmp = distanceToFloor.compareTo(distanceToCeiling)
                    val floorHasEvenLastDigit = !floor.unscaledValue().testBit(0)
                    when {
                        cmp < 0 -> floor
                        cmp > 0 -> ceiling
                        floorHasEvenLastDigit -> floor
                        else -> ceiling
                    }
                }
            }
        val digits = chosen.unscaledValue().abs().toString()
        val point = chosen.precision() - chosen.scale()
        return digits to point
    }
    // Unreachable: every finite double round-trips within 17 significant
    // decimal digits (Steele & White).
    error("shortestDigits: no round-tripping precision found for $value")
}

/**
 * Formats a finite [v] to match JS `Number.prototype.toString()` /
 * `JSON.stringify()` bytes exactly.
 *
 * Reproduces the ECMA-262 `Number::toString` notation rules (fixed notation
 * for a decimal-point position `n` in `(-6, 21]`, exponential otherwise) on
 * top of the digit/point pair from [shortestDigits], so integral doubles
 * render bare (`1`, not `1.0`) and the exponent notation-switch boundaries
 * match JS exactly.
 */
internal fun formatJsNumber(v: Double): String {
    if (v == 0.0) return "0" // collapses -0.0 -> "0", matching JS String(-0).
    val sign = if (v < 0) "-" else ""
    val (digits, n) = shortestDigits(kotlin.math.abs(v))
    val k = digits.length

    if (n in k..21) {
        return sign + digits + "0".repeat(n - k)
    }
    if (n in 1..21) {
        return sign + digits.substring(0, n) + "." + digits.substring(n)
    }
    if (n in -5..0) {
        return sign + "0." + "0".repeat(-n) + digits
    }

    val exp = n - 1
    val expStr = (if (exp >= 0) "+" else "-") + kotlin.math.abs(exp)
    val mantissa = if (k == 1) digits else "${digits[0]}.${digits.substring(1)}"
    return "$sign${mantissa}e$expStr"
}

private val DATE_FORMATTER: DateTimeFormatter =
    DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

/**
 * Formats [instant] as a UTC ISO-8601 literal clamped to millisecond
 * precision, matching JS `Date.prototype.toISOString()` byte-for-byte:
 * always exactly a 3-digit fraction and a trailing `Z`.
 *
 * Sub-millisecond precision is truncated (floored), not rounded —
 * [Instant.toEpochMilli] always floors correctly here (an `Instant`'s
 * nano-of-second is normalized to `[0, 999_999_999]` even for pre-1970
 * instants with a negative epoch second, so this never rounds a boundary
 * value the wrong way for negative timestamps).
 */
fun formatDate(instant: Instant): String {
    val truncated = Instant.ofEpochMilli(instant.toEpochMilli())
    return DATE_FORMATTER.format(truncated)
}

/**
 * Serializes a single interpolated value into a safe filter operand.
 *
 * `null` -> `null`; `Boolean` -> `true`/`false`; `Int`/`Long` -> decimal;
 * finite `Double` -> [formatJsNumber] (integral doubles render bare: `1`,
 * not `1.0`); finite `Float` -> widened to `Double` (see note below) then
 * [formatJsNumber]; `Instant`/`OffsetDateTime` -> single-quoted
 * [formatDate] (an `OffsetDateTime` is converted to UTC first; this SDK has
 * no "naive datetime" type, unlike the Python/Dart ports — pass an
 * `Instant` or `OffsetDateTime` explicitly rather than a zone-less type).
 * `String` -> single-quoted and escaped (see [quoteString]). Any other type
 * — including `List`/`Map` (array/object operands are ambiguous; expand
 * them yourself, e.g. into an `||` chain or a native `in (...)` clause) and
 * non-finite numbers — throws [IllegalArgumentException] rather than
 * silently coercing.
 *
 * A `Float` is widened to `Double` via an *exact* binary32->binary64
 * conversion (no decimal re-parsing), so its rendered digits reflect the
 * float's true binary value, not the shortest decimal a human might have
 * typed (e.g. `3.14f` widens to `3.140000104904175`, not `3.14`). Callers
 * that need JS-`Number` decimal fidelity should pass `Double`.
 */
fun filterValue(value: Any?): String =
    when (value) {
        null -> {
            "null"
        }

        is Boolean -> {
            if (value) "true" else "false"
        }

        is Int -> {
            value.toString()
        }

        is Long -> {
            value.toString()
        }

        is Double -> {
            if (!value.isFinite()) {
                throw IllegalArgumentException("filter: non-finite number operand: $value")
            }
            formatJsNumber(value)
        }

        is Float -> {
            if (!value.isFinite()) {
                throw IllegalArgumentException("filter: non-finite number operand: $value")
            }
            formatJsNumber(value.toDouble())
        }

        is Instant -> {
            quoteString(formatDate(value))
        }

        is OffsetDateTime -> {
            quoteString(formatDate(value.toInstant()))
        }

        is String -> {
            quoteString(value)
        }

        is List<*> -> {
            throw IllegalArgumentException(
                "filter: array operands are ambiguous; expand them yourself (e.g. build an `||` chain): $value",
            )
        }

        else -> {
            throw IllegalArgumentException(
                "filter: unsupported operand type: ${value::class.simpleName}: $value",
            )
        }
    }

private val PLACEHOLDER_RE = Regex("""\{:([A-Za-z_][A-Za-z0-9_]*)\}""")

/**
 * Interpolates named `{:name}` placeholders in [expr] with
 * `filterValue(params[name])`.
 *
 * Static text outside placeholders passes through verbatim.
 *
 * ```kotlin
 * zbFilter("status = {:s} && n > {:n}", mapOf("s" to "it's", "n" to 5))
 * // => "status = 'it\\'s' && n > 5"
 * ```
 *
 * Throws [IllegalArgumentException] if [expr] references a name absent from
 * [params], or if [params] contains a key never referenced by [expr] — a
 * stricter, reject-don't-coerce posture than the Dart port, which only
 * checks the former (matches `clients/python/src/zigbase/query.py`).
 */
fun zbFilter(
    expr: String,
    params: Map<String, Any?>,
): String {
    val used = mutableSetOf<String>()
    val result =
        PLACEHOLDER_RE.replace(expr) { match ->
            val name = match.groupValues[1]
            if (!params.containsKey(name)) {
                throw IllegalArgumentException("zbFilter: unknown placeholder {:$name}")
            }
            used.add(name)
            filterValue(params[name])
        }
    val unused = params.keys - used
    if (unused.isNotEmpty()) {
        throw IllegalArgumentException("zbFilter: unused param(s): ${unused.sorted().joinToString(", ")}")
    }
    return result
}

/**
 * Serializes a nearest-neighbor query to the `<field>[:metric]:<json-embedding>`
 * wire spec of `GET /api/collections/:col/records?vector=…`.
 *
 * Requires ZigBase >= 0.9.0 built with `-Dvector=true` (a default build
 * answers 400 "Vector search is not enabled in this build."). Vector search
 * is offset-only — the server rejects it in cursor mode. [metric] is passed
 * through verbatim, not validated (matching the TS SDK, whose `"cosine" |
 * "l2"` union is a compile-time-only constraint with no runtime check, and
 * the Python/Dart ports, which likewise do not validate it) — the server is
 * the validating authority; the server defaults to cosine when omitted or
 * blank. Throws [IllegalArgumentException] on a non-finite [embedding]
 * element (same posture as [filterValue]).
 *
 * The embedding is rendered with the same byte format as JS
 * `JSON.stringify(values)` (comma-separated, no whitespace, integral
 * doubles bare) since the TS SDK builds this spec via `JSON.stringify` and
 * every SDK must produce identical wire bytes.
 */
fun vectorSpec(
    field: String,
    embedding: List<Double>,
    metric: String? = null,
): String {
    val parts =
        embedding.map { v ->
            if (!v.isFinite()) {
                throw IllegalArgumentException("vectorSpec: non-finite embedding value: $v")
            }
            formatJsNumber(v)
        }
    val metricPart = if (!metric.isNullOrEmpty()) ":$metric" else ""
    return "$field$metricPart:[${parts.joinToString(",")}]"
}

/**
 * Builds the wire query-string params for `GET /api/collections/:col/records`.
 *
 * Emits wire param names (`perPage`, `skipTotal`, ...) and **omits** any
 * parameter left `null` — an empty string is a distinct, meaningful value
 * (e.g. `cursor=""` means "first page" in cursor mode) and is always
 * emitted when explicitly passed. Presence of `cursor`/`limit` vs.
 * `page`/`perPage` is what selects cursor vs. offset mode server-side, so
 * callers must not pass default/placeholder values for the mode they are
 * not using.
 */
fun buildListParams(
    filter: String? = null,
    sort: String? = null,
    expand: String? = null,
    fields: String? = null,
    search: String? = null,
    page: Int? = null,
    perPage: Int? = null,
    cursor: String? = null,
    limit: Int? = null,
    skipTotal: Boolean? = null,
    vector: String? = null,
): Map<String, String> {
    val params = LinkedHashMap<String, String>()
    filter?.let { params["filter"] = it }
    sort?.let { params["sort"] = it }
    expand?.let { params["expand"] = it }
    fields?.let { params["fields"] = it }
    search?.let { params["search"] = it }
    page?.let { params["page"] = it.toString() }
    perPage?.let { params["perPage"] = it.toString() }
    cursor?.let { params["cursor"] = it }
    limit?.let { params["limit"] = it.toString() }
    skipTotal?.let { params["skipTotal"] = if (it) "true" else "false" }
    vector?.let { params["vector"] = it }
    return params
}
