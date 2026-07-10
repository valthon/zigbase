package io.github.valthon.zigbase.internal

import io.github.valthon.zigbase.FileArg
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.time.Instant

/**
 * Port of `clients/python/tests/test_multipart.py`, plus the JVM-specific
 * [FileArg.FromFile] buffering guarantee and Kotlin's stricter
 * non-finite-in-multipart-numbers posture (see [Body.kt][io.github.valthon.zigbase.internal]).
 */
class HasFileTest {
    @Test
    fun `false for a plain body`() {
        assertFalse(hasFile(mapOf("title" to "hi", "count" to 3)))
    }

    @Test
    fun `true for a top-level file`() {
        assertTrue(hasFile(mapOf("avatar" to FileArg.Bytes("a.png", byteArrayOf(1, 2, 3)))))
    }

    @Test
    fun `true for a file inside a top-level list`() {
        assertTrue(hasFile(mapOf("attachments" to listOf(FileArg.Bytes("a.png", byteArrayOf(1))))))
    }

    @Test
    fun `false for a file nested inside a non-top-level map`() {
        // Only top-level values/lists are scanned -- mirrors hasBlob's shallow scan.
        assertFalse(hasFile(mapOf("meta" to mapOf("avatar" to FileArg.Bytes("a.png", byteArrayOf(1))))))
    }
}

class EncodeBodyJsonPathTest {
    @Test
    fun `no-file body encodes as json with all supported types`() {
        val whenInstant = Instant.parse("2024-03-01T12:30:45.123Z")
        val result =
            encodeBody(
                mapOf(
                    "title" to "hi",
                    "count" to 3,
                    "big" to 9_000_000_000L,
                    "score" to 3.5,
                    "ok" to true,
                    "nothing" to null,
                    "when" to whenInstant,
                    "tags" to listOf("a", "b"),
                    "meta" to mapOf("x" to 1),
                ),
            )
        require(result is EncodedBody.Json)
        val obj = result.element
        assertEquals(JsonPrimitive("hi"), obj["title"])
        assertEquals(JsonPrimitive(3), obj["count"])
        assertEquals(JsonPrimitive(9_000_000_000L), obj["big"])
        assertEquals(JsonPrimitive(3.5), obj["score"])
        assertEquals(JsonPrimitive(true), obj["ok"])
        assertEquals(JsonNull, obj["nothing"])
        assertEquals(JsonPrimitive("2024-03-01T12:30:45.123Z"), obj["when"])
        assertEquals(listOf("a", "b"), (obj["tags"] as JsonArray).map { it.jsonPrimitive.content })
        assertEquals(1, obj["meta"]!!.jsonObject["x"]!!.jsonPrimitive.int)
    }

    @Test
    fun `Short and Byte widen to a long json number`() {
        val result =
            encodeBody(
                mapOf(
                    "small" to 7.toShort(),
                    "tiny" to 3.toByte(),
                ),
            )
        require(result is EncodedBody.Json)
        assertEquals(JsonPrimitive(7L), result.element["small"])
        assertEquals(JsonPrimitive(3L), result.element["tiny"])
    }

    @Test
    fun `rejects a non-encodable value naming the key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(mapOf("good_key" to "ok", "bad_key" to StringBuilder("nope")))
            }
        assertTrue(ex.message!!.contains("bad_key"))
    }

    @Test
    fun `rejects a BigDecimal naming the key and the type`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(mapOf("good_key" to "ok", "bad_key" to java.math.BigDecimal("1.1")))
            }
        assertTrue(ex.message!!.contains("bad_key"))
        assertTrue(ex.message!!.contains("BigDecimal"))
    }

    @Test
    fun `rejects a BigInteger naming the key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(mapOf("good_key" to "ok", "bad_key" to java.math.BigInteger.TEN))
            }
        assertTrue(ex.message!!.contains("bad_key"))
    }

    @Test
    fun `rejects NaN naming the key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(mapOf("good_key" to "ok", "bad_key" to Double.NaN))
            }
        assertTrue(ex.message!!.contains("bad_key"))
    }

    @Test
    fun `rejects Infinity naming the key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(mapOf("good_key" to "ok", "bad_key" to Double.POSITIVE_INFINITY))
            }
        assertTrue(ex.message!!.contains("bad_key"))
    }

    @Test
    fun `rejects a non-finite value nested inside a map naming the top-level key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(mapOf("meta" to mapOf("bad" to Double.NaN)))
            }
        assertTrue(ex.message!!.contains("meta"))
    }

    @Test
    fun `rejects a non-encodable value nested inside a map naming the top-level key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(mapOf("meta" to mapOf("bad" to StringBuilder("nope"))))
            }
        assertTrue(ex.message!!.contains("meta"))
    }

    @Test
    fun `rejects a file nested inside a map naming the top-level key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(mapOf("meta" to mapOf("avatar" to FileArg.Bytes("a.png", byteArrayOf(1)))))
            }
        assertTrue(ex.message!!.contains("meta"))
    }
}

class EncodeBodyMultipartPathTest {
    @Test
    fun `file at top level flips to multipart`() {
        val result = encodeBody(mapOf("title" to "hi", "avatar" to FileArg.Bytes("a.png", byteArrayOf(1, 2, 3))))
        require(result is EncodedBody.Multipart)
        assertTrue(("title" to "hi") in result.fields)
        assertEquals(1, result.files.size)
        val file = result.files[0]
        assertEquals("avatar", file.key)
        assertEquals("a.png", file.filename)
        assertTrue(byteArrayOf(1, 2, 3).contentEquals(file.content))
    }

    @Test
    fun `list of files repeats the key`() {
        val result =
            encodeBody(
                mapOf(
                    "attachments" to
                        listOf(
                            FileArg.Bytes("a.txt", "aaa".toByteArray()),
                            FileArg.Bytes("b.txt", "bbb".toByteArray()),
                        ),
                ),
            )
        require(result is EncodedBody.Multipart)
        assertEquals(listOf("attachments", "attachments"), result.files.map { it.key })
        assertEquals("a.txt", result.files[0].filename)
        assertEquals("b.txt", result.files[1].filename)
    }

    @Test
    fun `null becomes an empty-string field`() {
        val result = encodeBody(mapOf("nothing" to null, "avatar" to FileArg.Bytes("a.png", byteArrayOf(1))))
        require(result is EncodedBody.Multipart)
        assertTrue(("nothing" to "") in result.fields)
    }

    @Test
    fun `null inside a list is dropped`() {
        val result =
            encodeBody(
                mapOf(
                    "tags" to listOf("a", null, "b"),
                    "avatar" to FileArg.Bytes("a.png", byteArrayOf(1)),
                ),
            )
        require(result is EncodedBody.Multipart)
        assertEquals(listOf("a", "b"), result.fields.filter { it.first == "tags" }.map { it.second })
    }

    @Test
    fun `nested map is json-encoded as one field`() {
        val result =
            encodeBody(
                mapOf(
                    "meta" to mapOf("a" to 1, "b" to "x"),
                    "avatar" to FileArg.Bytes("a.png", byteArrayOf(1)),
                ),
            )
        require(result is EncodedBody.Multipart)
        val metaFields = result.fields.filter { it.first == "meta" }
        assertEquals(1, metaFields.size)
        assertTrue(metaFields[0].second.contains("\"a\":1"))
        assertTrue(metaFields[0].second.contains("\"b\":\"x\""))
    }

    @Test
    fun `instant field is formatted`() {
        val result =
            encodeBody(
                mapOf(
                    "when" to Instant.parse("2024-03-01T12:30:45.123Z"),
                    "avatar" to FileArg.Bytes("a.png", byteArrayOf(1)),
                ),
            )
        require(result is EncodedBody.Multipart)
        assertTrue(("when" to "2024-03-01T12:30:45.123Z") in result.fields)
    }

    @Test
    fun `bools render as lowercase`() {
        val result =
            encodeBody(
                mapOf(
                    "a" to true,
                    "b" to false,
                    "avatar" to FileArg.Bytes("a.png", byteArrayOf(1)),
                ),
            )
        require(result is EncodedBody.Multipart)
        assertTrue(("a" to "true") in result.fields)
        assertTrue(("b" to "false") in result.fields)
    }

    @Test
    fun `scalars stringify`() {
        val result =
            encodeBody(
                mapOf(
                    "n" to 5,
                    "f" to 3.5,
                    "avatar" to FileArg.Bytes("a.png", byteArrayOf(1)),
                ),
            )
        require(result is EncodedBody.Multipart)
        assertTrue(("n" to "5") in result.fields)
        assertTrue(("f" to "3.5") in result.fields)
    }

    @Test
    fun `Short and Byte stringify like any other scalar`() {
        val result =
            encodeBody(
                mapOf(
                    "small" to 7.toShort(),
                    "tiny" to 3.toByte(),
                    "avatar" to FileArg.Bytes("a.png", byteArrayOf(1)),
                ),
            )
        require(result is EncodedBody.Multipart)
        assertTrue(("small" to "7") in result.fields)
        assertTrue(("tiny" to "3") in result.fields)
    }

    @Test
    fun `nested non-finite value inside a map names the top-level key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(
                    mapOf(
                        "meta" to mapOf("bad" to Double.NaN),
                        "avatar" to FileArg.Bytes("a.png", byteArrayOf(1)),
                    ),
                )
            }
        assertTrue(ex.message!!.contains("meta"))
    }

    @Test
    fun `nested non-encodable value inside a map names the top-level key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(
                    mapOf(
                        "meta" to mapOf("bad" to StringBuilder("nope")),
                        "avatar" to FileArg.Bytes("a.png", byteArrayOf(1)),
                    ),
                )
            }
        assertTrue(ex.message!!.contains("meta"))
    }

    @Test
    fun `file nested inside a map names the top-level key`() {
        val ex =
            assertThrows(IllegalArgumentException::class.java) {
                encodeBody(
                    mapOf(
                        "meta" to mapOf("avatar" to FileArg.Bytes("a.png", byteArrayOf(1))),
                        "other_avatar" to FileArg.Bytes("a.png", byteArrayOf(1)),
                    ),
                )
            }
        assertTrue(ex.message!!.contains("meta"))
    }

    @Test
    fun `FromFile bytes are read once and buffered at encode time`() {
        val tmp = Files.createTempFile("body-test", ".txt")
        try {
            Files.write(tmp, "AAA".toByteArray(StandardCharsets.UTF_8))
            val result = encodeBody(mapOf("avatar" to FileArg.FromFile(tmp.toFile())))
            require(result is EncodedBody.Multipart)
            val buffered = result.files[0].content

            // Mutate the file after encoding; the already-encoded bytes must
            // not reflect it -- proves the read happened once at encode
            // time, not lazily whenever `content` is accessed.
            Files.write(tmp, "BBB".toByteArray(StandardCharsets.UTF_8))

            assertTrue("AAA".toByteArray(StandardCharsets.UTF_8).contentEquals(buffered))
            assertTrue("AAA".toByteArray(StandardCharsets.UTF_8).contentEquals(result.files[0].content))
            assertEquals(tmp.fileName.toString(), result.files[0].filename)
        } finally {
            Files.deleteIfExists(tmp)
        }
    }
}
