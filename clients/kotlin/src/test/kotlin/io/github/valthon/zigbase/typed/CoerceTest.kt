package io.github.valthon.zigbase.typed

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

/**
 * Tests for `typed` metadata + wire coercion ([Meta.kt]/[Coerce.kt]), a port of
 * `clients/python/tests/test_typed_coerce.py` (metadata + coercion + expand
 * sections), itself a port of `clients/dart/lib/typed.dart`.
 */
private fun echo(r: JsonObject): JsonObject = r

class TypedCoreVersionTest {
    @Test
    fun `is 0_1_0`() {
        assertEquals("0.1.0", TYPED_CORE_VERSION)
    }
}

class FieldTypeTest {
    @Test
    fun `every member carries its wire string`() {
        assertEquals("text", FieldType.TEXT.wire)
        assertEquals("editor", FieldType.EDITOR.wire)
        assertEquals("email", FieldType.EMAIL.wire)
        assertEquals("url", FieldType.URL.wire)
        assertEquals("number", FieldType.NUMBER.wire)
        assertEquals("boolean", FieldType.BOOLEAN.wire)
        assertEquals("date", FieldType.DATE.wire)
        assertEquals("autodate", FieldType.AUTODATE.wire)
        assertEquals("select", FieldType.SELECT.wire)
        assertEquals("relation", FieldType.RELATION.wire)
        assertEquals("file", FieldType.FILE.wire)
        assertEquals("json", FieldType.JSON.wire)
    }
}

class NumberModeTest {
    @Test
    fun `has exactly float, integer, fixed`() {
        assertEquals(listOf(NumberMode.FLOAT, NumberMode.INTEGER, NumberMode.FIXED), NumberMode.entries)
    }
}

class FieldMetaTest {
    @Test
    fun `defaults`() {
        val meta = FieldMeta(type = FieldType.TEXT)
        assertEquals(FieldType.TEXT, meta.type)
        assertFalse(meta.multi)
        assertEquals(NumberMode.FLOAT, meta.mode)
        assertNull(meta.scale)
    }

    @Test
    fun `full construction`() {
        val meta = FieldMeta(type = FieldType.NUMBER, multi = true, mode = NumberMode.FIXED, scale = 2)
        assertTrue(meta.multi)
        assertEquals(NumberMode.FIXED, meta.mode)
        assertEquals(2, meta.scale)
    }
}

class CollectionMetaTest {
    @Test
    fun `defaults`() {
        val meta = CollectionMeta(name = "posts", fields = mapOf("title" to FieldMeta(type = FieldType.TEXT)))
        assertEquals("posts", meta.name)
        assertEquals(emptyList<String>(), meta.fileFields)
        assertEquals(emptyList<String>(), meta.expandable)
        assertFalse(meta.isAuth)
        assertNull(meta.searchable)
        assertNull(meta.tenant)
    }

    @Test
    fun `field returns meta for known field`() {
        val titleMeta = FieldMeta(type = FieldType.TEXT)
        val meta = CollectionMeta(name = "posts", fields = mapOf("title" to titleMeta))
        assertEquals(titleMeta, meta.field("title"))
    }

    @Test
    fun `field returns null for unknown field`() {
        val meta = CollectionMeta(name = "posts", fields = emptyMap())
        assertNull(meta.field("missing"))
    }

    @Test
    fun `full construction`() {
        val meta =
            CollectionMeta(
                name = "users",
                fields = mapOf("email" to FieldMeta(type = FieldType.EMAIL)),
                fileFields = listOf("avatar"),
                expandable = listOf("owner"),
                isAuth = true,
                searchable = listOf("email"),
                tenant = "org",
            )
        assertEquals(listOf("avatar"), meta.fileFields)
        assertEquals(listOf("owner"), meta.expandable)
        assertTrue(meta.isAuth)
        assertEquals(listOf("email"), meta.searchable)
        assertEquals("org", meta.tenant)
    }
}

class CoerceLongTest {
    @Test
    fun `accepts a whole json number`() {
        assertEquals(42L, coerceLong(JsonPrimitive(42)))
    }

    @Test
    fun `accepts a whole double as an integer`() {
        assertEquals(42L, coerceLong(JsonPrimitive(42.0)))
    }

    @Test
    fun `rejects a fractional json number`() {
        assertThrows(IllegalArgumentException::class.java) { coerceLong(JsonPrimitive(9.99)) }
    }

    @Test
    fun `accepts an integer string`() {
        assertEquals(42L, coerceLong(JsonPrimitive("42")))
    }

    @Test
    fun `accepts a whole decimal string`() {
        assertEquals(42L, coerceLong(JsonPrimitive("42.0")))
    }

    @Test
    fun `rejects a fractional string`() {
        assertThrows(IllegalArgumentException::class.java) { coerceLong(JsonPrimitive("9.99")) }
    }

    @Test
    fun `rejects a whole json number outside Long range`() {
        // Would silently clamp to Long.MAX_VALUE under a bare toLong().
        assertThrows(IllegalArgumentException::class.java) { coerceLong(JsonPrimitive(1e30)) }
        assertThrows(IllegalArgumentException::class.java) { coerceLong(JsonPrimitive(-1e30)) }
    }

    @Test
    fun `rejects a whole string outside Long range`() {
        assertThrows(IllegalArgumentException::class.java) { coerceLong(JsonPrimitive("1e30")) }
    }

    @Test
    fun `accepts a large whole value still inside Long range`() {
        // 1e18 < 2^63: representable and must NOT be rejected by the range guard.
        assertEquals(1_000_000_000_000_000_000L, coerceLong(JsonPrimitive(1e18)))
    }

    @Test
    fun `empty string returns fallback`() {
        assertEquals(7L, coerceLong(JsonPrimitive(""), 7L))
    }

    @Test
    fun `unparseable string returns fallback`() {
        assertEquals(7L, coerceLong(JsonPrimitive("not-a-number"), 7L))
    }

    @Test
    fun `absent value returns fallback`() {
        assertEquals(3L, coerceLong(null, 3L))
    }

    @Test
    fun `json null returns fallback`() {
        assertEquals(3L, coerceLong(JsonNull, 3L))
    }

    @Test
    fun `default fallback is zero`() {
        assertEquals(0L, coerceLong(null))
    }

    @Test
    fun `boolean falls through to fallback`() {
        assertEquals(9L, coerceLong(JsonPrimitive(true), 9L))
        assertEquals(9L, coerceLong(JsonPrimitive(false), 9L))
        assertEquals(0L, coerceLong(JsonPrimitive(true)))
    }
}

class CoerceDoubleTest {
    @Test
    fun `accepts a json integer`() {
        assertEquals(42.0, coerceDouble(JsonPrimitive(42)))
    }

    @Test
    fun `accepts a json double`() {
        assertEquals(9.99, coerceDouble(JsonPrimitive(9.99)))
    }

    @Test
    fun `accepts a numeric string`() {
        assertEquals(9.99, coerceDouble(JsonPrimitive("9.99")))
    }

    @Test
    fun `empty string returns fallback`() {
        assertEquals(1.5, coerceDouble(JsonPrimitive(""), 1.5))
    }

    @Test
    fun `unparseable string returns fallback`() {
        assertEquals(1.5, coerceDouble(JsonPrimitive("nope"), 1.5))
    }

    @Test
    fun `absent value returns fallback`() {
        assertEquals(2.5, coerceDouble(null, 2.5))
    }

    @Test
    fun `default fallback is zero`() {
        assertEquals(0.0, coerceDouble(null))
    }

    @Test
    fun `boolean falls through to fallback`() {
        assertEquals(9.5, coerceDouble(JsonPrimitive(true), 9.5))
        assertEquals(9.5, coerceDouble(JsonPrimitive(false), 9.5))
    }
}

class CoerceStringTest {
    @Test
    fun `accepts a string`() {
        assertEquals("hello", coerceString(JsonPrimitive("hello")))
    }

    @Test
    fun `non-string returns fallback`() {
        assertEquals("x", coerceString(JsonPrimitive(42), "x"))
    }

    @Test
    fun `absent value returns fallback`() {
        assertEquals("", coerceString(null))
    }

    @Test
    fun `default fallback is empty string`() {
        assertEquals("", coerceString(JsonPrimitive(123)))
    }
}

class CoerceBooleanTest {
    @Test
    fun `accepts true`() {
        assertTrue(coerceBoolean(JsonPrimitive(true)))
    }

    @Test
    fun `accepts false`() {
        assertFalse(coerceBoolean(JsonPrimitive(false)))
    }

    @Test
    fun `non-boolean returns fallback`() {
        assertFalse(coerceBoolean(JsonPrimitive("true"), false))
        assertFalse(coerceBoolean(JsonPrimitive(1), false))
    }

    @Test
    fun `absent value returns fallback`() {
        assertTrue(coerceBoolean(null, true))
    }

    @Test
    fun `default fallback is false`() {
        assertFalse(coerceBoolean(null))
    }
}

class CoerceStringListTest {
    @Test
    fun `list of strings passthrough`() {
        val arr =
            buildJsonArray {
                add(JsonPrimitive("a"))
                add(JsonPrimitive("b"))
            }
        assertEquals(listOf("a", "b"), coerceStringList(arr))
    }

    @Test
    fun `list of mixed values is stringified via each element's content`() {
        val arr =
            buildJsonArray {
                add(JsonPrimitive("a"))
                add(JsonPrimitive(1))
                add(JsonPrimitive(true))
            }
        assertEquals(listOf("a", "1", "true"), coerceStringList(arr))
    }

    @Test
    fun `single nonempty string is wrapped`() {
        assertEquals(listOf("a"), coerceStringList(JsonPrimitive("a")))
    }

    @Test
    fun `empty string returns empty list`() {
        assertEquals(emptyList<String>(), coerceStringList(JsonPrimitive("")))
    }

    @Test
    fun `absent value returns empty list`() {
        assertEquals(emptyList<String>(), coerceStringList(null))
    }

    @Test
    fun `empty array returns empty list`() {
        assertEquals(emptyList<String>(), coerceStringList(buildJsonArray {}))
    }

    @Test
    fun `scalar non-string returns empty list`() {
        assertEquals(emptyList<String>(), coerceStringList(JsonPrimitive(42)))
    }
}

class CoerceLongListTest {
    @Test
    fun `list of json integers`() {
        val arr =
            buildJsonArray {
                add(1)
                add(2)
                add(3)
            }
        assertEquals(listOf(1L, 2L, 3L), coerceLongList(arr))
    }

    @Test
    fun `list of decimal strings`() {
        val arr =
            buildJsonArray {
                add("1")
                add("2.0")
            }
        assertEquals(listOf(1L, 2L), coerceLongList(arr))
    }

    @Test
    fun `list with a fractional element raises`() {
        val arr =
            buildJsonArray {
                add(1)
                add("2.5")
            }
        assertThrows(IllegalArgumentException::class.java) { coerceLongList(arr) }
    }

    @Test
    fun `absent value returns empty list`() {
        assertEquals(emptyList<Long>(), coerceLongList(null))
    }

    @Test
    fun `scalar returns empty list`() {
        assertEquals(emptyList<Long>(), coerceLongList(JsonPrimitive(5)))
    }

    @Test
    fun `empty list returns empty list`() {
        assertEquals(emptyList<Long>(), coerceLongList(buildJsonArray {}))
    }

    @Test
    fun `boolean element falls through to its fallback`() {
        val arr =
            buildJsonArray {
                add(1)
                add(true)
                add(3)
            }
        assertEquals(listOf(1L, 0L, 3L), coerceLongList(arr))
    }
}

class CoerceDoubleListTest {
    @Test
    fun `list of numbers`() {
        val arr =
            buildJsonArray {
                add(1)
                add(2.5)
                add("3.5")
            }
        assertEquals(listOf(1.0, 2.5, 3.5), coerceDoubleList(arr))
    }

    @Test
    fun `absent value returns empty list`() {
        assertEquals(emptyList<Double>(), coerceDoubleList(null))
    }

    @Test
    fun `scalar returns empty list`() {
        assertEquals(emptyList<Double>(), coerceDoubleList(JsonPrimitive(5.0)))
    }

    @Test
    fun `empty list returns empty list`() {
        assertEquals(emptyList<Double>(), coerceDoubleList(buildJsonArray {}))
    }

    @Test
    fun `boolean element falls through to its fallback`() {
        val arr =
            buildJsonArray {
                add(1.0)
                add(false)
            }
        assertEquals(listOf(1.0, 0.0), coerceDoubleList(arr))
    }
}

class EncodeIntTest {
    @Test
    fun `encodes a positive value`() {
        assertEquals("42", encodeInt(42L))
    }

    @Test
    fun `encodes a negative value`() {
        assertEquals("-7", encodeInt(-7L))
    }

    @Test
    fun `encodes zero`() {
        assertEquals("0", encodeInt(0L))
    }

    @Test
    fun `null returns null`() {
        assertNull(encodeInt(null))
    }
}

class EncodeFixedTest {
    @Test
    fun `rounds to scale`() {
        assertEquals("9.99", encodeFixed(9.99, 2))
    }

    @Test
    fun `pads to scale`() {
        assertEquals("5.00", encodeFixed(5.0, 2))
    }

    @Test
    fun `scale zero renders no decimal point`() {
        assertEquals("5", encodeFixed(5.4, 0))
    }

    @Test
    fun `null returns null`() {
        assertNull(encodeFixed(null, 2))
    }

    @Test
    fun `an exact binary tie rounds half up`() {
        // 0.125 is exactly representable in binary float, so this is a true
        // tie at the rendered scale; a naive String_format-style
        // round-half-to-even would render "0.12" instead.
        assertEquals("0.13", encodeFixed(0.125, 2))
    }

    @Test
    fun `an apparent tie strictly below the binary value rounds down`() {
        // 2.675 is NOT exactly representable: its nearest binary double is
        // ~2.67499999999999982..., i.e. strictly below the tie, so it rounds
        // down to "2.67" when quantizing the exact binary value.
        assertEquals("2.67", encodeFixed(2.675, 2))
    }
}

class ExpandOneTest {
    @Test
    fun `present single expand`() {
        val record =
            buildJsonObject {
                put("id", "1")
                put(
                    "expand",
                    buildJsonObject {
                        put(
                            "owner",
                            buildJsonObject {
                                put("id", "u1")
                                put("name", "Ada")
                            },
                        )
                    },
                )
            }
        val result = expandOne(record, "owner", ::echo)
        assertEquals(
            buildJsonObject {
                put("id", "u1")
                put("name", "Ada")
            },
            result,
        )
    }

    @Test
    fun `absent key returns null`() {
        val record =
            buildJsonObject {
                put("id", "1")
                put("expand", buildJsonObject {})
            }
        assertNull(expandOne(record, "owner", ::echo))
    }

    @Test
    fun `no expand block returns null`() {
        val record = buildJsonObject { put("id", "1") }
        assertNull(expandOne(record, "owner", ::echo))
    }

    @Test
    fun `expand value not an object returns null`() {
        val record =
            buildJsonObject {
                put("id", "1")
                put(
                    "expand",
                    buildJsonObject {
                        put(
                            "owner",
                            buildJsonArray {
                                add(1)
                                add(2)
                            },
                        )
                    },
                )
            }
        assertNull(expandOne(record, "owner", ::echo))
    }

    @Test
    fun `expand block not an object returns null`() {
        val record =
            buildJsonObject {
                put("id", "1")
                put("expand", "nope")
            }
        assertNull(expandOne(record, "owner", ::echo))
    }
}

class ExpandManyTest {
    @Test
    fun `present list expand`() {
        val record =
            buildJsonObject {
                put("id", "1")
                put(
                    "expand",
                    buildJsonObject {
                        put(
                            "tags",
                            buildJsonArray {
                                add(buildJsonObject { put("id", "t1") })
                                add(buildJsonObject { put("id", "t2") })
                            },
                        )
                    },
                )
            }
        val result = expandMany(record, "tags", ::echo)
        assertEquals(listOf(buildJsonObject { put("id", "t1") }, buildJsonObject { put("id", "t2") }), result)
    }

    @Test
    fun `absent key returns empty list`() {
        val record =
            buildJsonObject {
                put("id", "1")
                put("expand", buildJsonObject {})
            }
        assertEquals(emptyList<JsonObject>(), expandMany(record, "tags", ::echo))
    }

    @Test
    fun `no expand block returns empty list`() {
        val record = buildJsonObject { put("id", "1") }
        assertEquals(emptyList<JsonObject>(), expandMany(record, "tags", ::echo))
    }

    @Test
    fun `expand value not a list returns empty list`() {
        val record =
            buildJsonObject {
                put("id", "1")
                put("expand", buildJsonObject { put("tags", buildJsonObject { put("id", "t1") }) })
            }
        assertEquals(emptyList<JsonObject>(), expandMany(record, "tags", ::echo))
    }

    @Test
    fun `non-object items are skipped`() {
        val record =
            buildJsonObject {
                put("id", "1")
                put(
                    "expand",
                    buildJsonObject {
                        put(
                            "tags",
                            buildJsonArray {
                                add(buildJsonObject { put("id", "t1") })
                                add(JsonPrimitive("bad"))
                                add(JsonPrimitive(5))
                            },
                        )
                    },
                )
            }
        assertEquals(listOf(buildJsonObject { put("id", "t1") }), expandMany(record, "tags", ::echo))
    }

    @Test
    fun `empty expand block key returns empty list`() {
        val record =
            buildJsonObject {
                put("id", "1")
                put("expand", buildJsonObject { put("tags", buildJsonArray {}) })
            }
        assertEquals(emptyList<JsonObject>(), expandMany(record, "tags", ::echo))
    }
}
