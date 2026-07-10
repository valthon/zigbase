package io.github.valthon.zigbase.auth

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.attribute.PosixFilePermissions
import java.util.Base64
import java.util.concurrent.CyclicBarrier
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlin.io.path.isRegularFile
import kotlin.io.path.listDirectoryEntries
import kotlin.io.path.readText

private fun b64url(bytes: ByteArray): String = Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)

private fun b64url(text: String): String = b64url(text.toByteArray(StandardCharsets.UTF_8))

/** Hand-assembles a JWT (unsigned "sig" segment) from a JSON payload body. */
private fun makeJwt(payloadJson: String): String {
    val header = b64url("""{"alg":"HS256","typ":"JWT"}""")
    val body = b64url(payloadJson)
    return "$header.$body.sig"
}

private fun validToken(): String {
    val exp = System.currentTimeMillis() / 1000 + 3600
    return makeJwt("""{"id":"u1","exp":$exp}""")
}

private fun expiredToken(): String {
    val exp = System.currentTimeMillis() / 1000 - 10
    return makeJwt("""{"id":"u1","exp":$exp}""")
}

private fun jsonRecord(
    id: String,
    email: String? = null,
): JsonObject =
    buildJsonObject {
        put("id", id)
        if (email != null) put("email", email)
    }

class MemoryAuthStoreRoundTripTest {
    @Test
    fun `starts empty`() {
        val store = MemoryAuthStore()
        assertNull(store.token)
        assertNull(store.record)
        assertFalse(store.isValid)
    }

    @Test
    fun `save then clear round trips`() {
        val store = MemoryAuthStore()
        val token = validToken()
        val record = jsonRecord("u1", "a@b.com")

        store.save(token, record)
        assertEquals(token, store.token)
        assertEquals(record, store.record)

        store.clear()
        assertNull(store.token)
        assertNull(store.record)
    }

    @Test
    fun `save accepts a null record`() {
        val store = MemoryAuthStore()
        val token = validToken()
        store.save(token, null)
        assertEquals(token, store.token)
        assertNull(store.record)
    }
}

class IsValidTest {
    @Test
    fun `true for a valid unexpired token`() {
        val store = MemoryAuthStore()
        store.save(validToken(), null)
        assertTrue(store.isValid)
    }

    @Test
    fun `false for an expired token`() {
        val store = MemoryAuthStore()
        store.save(expiredToken(), null)
        assertFalse(store.isValid)
    }

    @Test
    fun `false when no token is present`() {
        val store = MemoryAuthStore()
        assertFalse(store.isValid)
    }
}

class OnChangeTest {
    @Test
    fun `fires on save`() {
        val store = MemoryAuthStore()
        val calls = mutableListOf<Pair<String?, JsonObject?>>()
        store.onChange { token, record -> calls.add(token to record) }

        val token = validToken()
        val record = jsonRecord("u1")
        store.save(token, record)

        assertEquals(listOf(token to record), calls)
    }

    @Test
    fun `fires on clear`() {
        val store = MemoryAuthStore()
        store.save(validToken(), jsonRecord("u1"))
        val calls = mutableListOf<Pair<String?, JsonObject?>>()
        store.onChange { token, record -> calls.add(token to record) }

        store.clear()

        assertEquals(listOf<Pair<String?, JsonObject?>>(null to null), calls)
    }

    @Test
    fun `fires after state has already changed`() {
        val store = MemoryAuthStore()
        val observed = mutableListOf<String?>()
        store.onChange { _, _ -> observed.add(store.token) }

        val token = validToken()
        store.save(token, null)

        assertEquals(listOf(token), observed)
    }

    @Test
    fun `unsubscribe stops further notifications`() {
        val store = MemoryAuthStore()
        val calls = mutableListOf<String?>()
        val unsubscribe = store.onChange { token, _ -> calls.add(token) }

        store.save(validToken(), null)
        unsubscribe()
        store.clear()

        assertEquals(1, calls.size)
    }

    @Test
    fun `a throwing listener does not block the next listener`() {
        val store = MemoryAuthStore()
        val calls = mutableListOf<String>()

        store.onChange { _, _ -> throw RuntimeException("boom") }
        store.onChange { _, _ -> calls.add("called") }

        store.save(validToken(), null)

        assertEquals(listOf("called"), calls)
    }

    @Test
    fun `a listener that unsubscribes itself during emit is safe`() {
        val store = MemoryAuthStore()
        val calls = mutableListOf<String>()
        lateinit var unsubscribe: () -> Unit
        unsubscribe =
            store.onChange { _, _ ->
                calls.add("first")
                unsubscribe()
            }
        store.onChange { _, _ -> calls.add("second") }

        store.save(validToken(), null)
        store.save(validToken(), null)

        // First save: both listeners fire (snapshot taken before the first
        // listener unsubscribes itself). Second save: only the second
        // listener remains.
        assertEquals(listOf("first", "second", "second"), calls)
    }

    @Test
    fun `a listener that subscribes another listener during emit is safe`() {
        val store = MemoryAuthStore()
        val calls = mutableListOf<String>()
        store.onChange { _, _ ->
            calls.add("outer")
            store.onChange { _, _ -> calls.add("inner") }
        }

        store.save(validToken(), null)
        store.save(validToken(), null)

        // The listener subscribed during the first emit is not part of that
        // emit's snapshot, but does fire on the second.
        assertEquals(listOf("outer", "outer", "inner"), calls)
    }
}

class FileAuthStoreTest {
    @Test
    fun `starts empty when file is missing`(
        @TempDir tmpDir: Path,
    ) {
        val store = FileAuthStore(tmpDir.resolve("auth.json"))
        assertNull(store.token)
        assertNull(store.record)
    }

    @Test
    fun `save persists to disk and creates parent dirs`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("nested").resolve("dir").resolve("auth.json")
        val store = FileAuthStore(path)
        val token = validToken()
        val record = jsonRecord("u1")

        store.save(token, record)

        assertTrue(Files.exists(path))
        val onDisk = Json.parseToJsonElement(path.readText(StandardCharsets.UTF_8)).let { it as JsonObject }
        assertEquals(token, onDisk["token"]!!.let { (it as kotlinx.serialization.json.JsonPrimitive).content })
        assertEquals(record, onDisk["record"])
    }

    @Test
    fun `persists across instances`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        val token = validToken()
        val record = jsonRecord("u1")
        FileAuthStore(path).save(token, record)

        val reloaded = FileAuthStore(path)

        assertEquals(token, reloaded.token)
        assertEquals(record, reloaded.record)
    }

    @Test
    fun `clear persists nulls`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        val store = FileAuthStore(path)
        store.save(validToken(), jsonRecord("u1"))

        store.clear()

        val onDisk = Json.parseToJsonElement(path.readText(StandardCharsets.UTF_8)) as JsonObject
        assertTrue(onDisk["token"] is kotlinx.serialization.json.JsonNull)
        assertTrue(onDisk["record"] is kotlinx.serialization.json.JsonNull)

        val reloaded = FileAuthStore(path)
        assertNull(reloaded.token)
        assertNull(reloaded.record)
    }

    @Test
    fun `malformed json starts empty`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        Files.writeString(path, "{not valid json")

        val store = FileAuthStore(path)

        assertNull(store.token)
        assertNull(store.record)
    }

    @Test
    fun `non-object json starts empty`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        Files.writeString(path, "[1, 2, 3]")

        val store = FileAuthStore(path)

        assertNull(store.token)
        assertNull(store.record)
    }

    @Test
    fun `non-UTF8 bytes start empty`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        // A byte-order-mark-like prefix followed by garbage -- not valid UTF-8.
        Files.write(path, byteArrayOf(0xFF.toByte(), 0xFE.toByte(), 0x00, 0x01, 'g'.code.toByte()))

        val store = FileAuthStore(path)

        assertNull(store.token)
        assertNull(store.record)
    }

    @Test
    fun `directory-as-file starts empty`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        Files.createDirectory(path)

        val store = FileAuthStore(path)

        assertNull(store.token)
        assertNull(store.record)
    }

    @Test
    fun `on change still fires for a file-backed store`(
        @TempDir tmpDir: Path,
    ) {
        val store = FileAuthStore(tmpDir.resolve("auth.json"))
        val calls = mutableListOf<String?>()
        store.onChange { token, _ -> calls.add(token) }

        val token = validToken()
        store.save(token, null)

        assertEquals(listOf(token), calls)
    }

    @Test
    fun `save creates the file with owner-only permissions`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        val store = FileAuthStore(path)

        store.save(validToken(), jsonRecord("u1"))

        val perms = Files.getPosixFilePermissions(path)
        assertEquals(PosixFilePermissions.fromString("rw-------"), perms)
    }

    @Test
    fun `clear preserves owner-only permissions`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        val store = FileAuthStore(path)
        store.save(validToken(), jsonRecord("u1"))

        store.clear()

        val perms = Files.getPosixFilePermissions(path)
        assertEquals(PosixFilePermissions.fromString("rw-------"), perms)
    }

    @Test
    fun `overwriting an existing store replaces content atomically`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        val store = FileAuthStore(path)
        store.save(validToken(), jsonRecord("u1", "old@example.com"))

        val secondToken = validToken()
        store.save(secondToken, jsonRecord("u1", "new@example.com"))

        val onDisk = Json.parseToJsonElement(path.readText(StandardCharsets.UTF_8)) as JsonObject
        assertEquals(jsonRecord("u1", "new@example.com"), onDisk["record"])
    }

    @Test
    fun `save leaves no leftover temp file`(
        @TempDir tmpDir: Path,
    ) {
        val path = tmpDir.resolve("auth.json")
        val store = FileAuthStore(path)

        store.save(validToken(), jsonRecord("u1"))

        val leftovers = tmpDir.listDirectoryEntries().filter { it.isRegularFile() && it.fileName.toString() != "auth.json" }
        assertTrue(leftovers.isEmpty())
    }

    @Test
    fun `concurrent saves from multiple threads never raise and leave no temp files`(
        @TempDir tmpDir: Path,
    ) {
        // Regression guard: the temp filename must be unique per *call*, not
        // just per process -- otherwise concurrent same-process writers can
        // collide on the exclusive-create step. See AuthStore.kt for detail.
        val path = tmpDir.resolve("auth.json")
        val store = FileAuthStore(path)
        val threadCount = 8
        val iterations = 25
        val barrier = CyclicBarrier(threadCount)
        val errorCount = AtomicInteger(0)
        val pool = Executors.newFixedThreadPool(threadCount)

        try {
            val futures =
                (0 until threadCount).map { idx ->
                    pool.submit {
                        barrier.await()
                        try {
                            repeat(iterations) { i ->
                                store.save(validToken(), jsonRecord("u$idx-$i"))
                            }
                        } catch (e: Throwable) {
                            errorCount.incrementAndGet()
                        }
                    }
                }
            futures.forEach { it.get(30, TimeUnit.SECONDS) }
        } finally {
            pool.shutdown()
        }

        assertEquals(0, errorCount.get())

        val onDisk = Json.parseToJsonElement(path.readText(StandardCharsets.UTF_8)) as JsonObject
        assertTrue(onDisk["token"] is kotlinx.serialization.json.JsonPrimitive)

        val perms = Files.getPosixFilePermissions(path)
        assertEquals(PosixFilePermissions.fromString("rw-------"), perms)

        val leftovers = tmpDir.listDirectoryEntries().filter { it.isRegularFile() && it.fileName.toString() != "auth.json" }
        assertTrue(leftovers.isEmpty())
    }
}
