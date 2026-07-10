package io.github.valthon.zigbase.auth

import io.github.valthon.zigbase.jwt.isTokenExpired
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.channels.SeekableByteChannel
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermissions
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock

/**
 * Callback invoked on every [AuthStore.save] / [AuthStore.clear].
 *
 * Port of `AuthChangeListener` (TypeScript) / `AuthChangeCallback` (Python)
 * in `clients/typescript/src/auth-store.ts` / `clients/python/src/zigbase/auth_store.py`.
 */
typealias AuthChangeListener = (String?, JsonObject?) -> Unit

/**
 * Holds the current auth token/record and notifies listeners of changes.
 *
 * Port of `BaseAuthStore` (TypeScript) / `AuthStore` (Python -- an `ABC`
 * with every method already implemented). Kotlin follows the Python shape:
 * this is an abstract class only because an interface can't hold the
 * mutable state (`token`, `record`, the listener list) the shared plumbing
 * needs -- every member below is already implemented, so construct
 * [MemoryAuthStore] or [FileAuthStore] rather than subclassing this
 * directly.
 *
 * Thread-safety: `token`/`record` reads and the `save`/`clear` state
 * mutation are synchronized on an internal lock, so a single instance is
 * safe to share and call from multiple coroutines or threads concurrently
 * (e.g. a background token-refresh job racing request handlers). Listener
 * callbacks run *outside* the lock -- after the state change they announce
 * has already been committed -- so a slow or misbehaving listener can't
 * block other threads' state updates or reads.
 */
abstract class AuthStore protected constructor() {
    private val lock = ReentrantLock()
    private var currentToken: String? = null
    private var currentRecord: JsonObject? = null
    private val listeners = CopyOnWriteArrayList<AuthChangeListener>()

    val token: String?
        get() = lock.withLock { currentToken }

    val record: JsonObject?
        get() = lock.withLock { currentRecord }

    /**
     * Whether a token is present and not (client-side) expired.
     *
     * This is a client-side UX signal only (e.g. to decide whether to skip
     * an auth-refresh call) -- the server is always the source of truth.
     */
    val isValid: Boolean
        get() {
            val current = lock.withLock { currentToken } ?: return false
            return !isTokenExpired(current)
        }

    open fun save(
        token: String?,
        record: JsonObject?,
    ) {
        lock.withLock {
            currentToken = token
            currentRecord = record
        }
        notifyListeners(token, record)
    }

    open fun clear() {
        lock.withLock {
            currentToken = null
            currentRecord = null
        }
        notifyListeners(null, null)
    }

    /** Registers [cb] to run on every [save]/[clear]. Returns an unsubscribe function. */
    fun onChange(cb: AuthChangeListener): () -> Unit {
        listeners.add(cb)
        return { listeners.remove(cb) }
    }

    /** Sets state without notifying listeners; for subclass eager-load on construction. */
    protected fun restoreQuietly(
        token: String?,
        record: JsonObject?,
    ) {
        lock.withLock {
            currentToken = token
            currentRecord = record
        }
    }

    private fun notifyListeners(
        token: String?,
        record: JsonObject?,
    ) {
        // CopyOnWriteArrayList's iterator is a point-in-time snapshot, so a
        // listener that subscribes/unsubscribes during this loop can't
        // corrupt the iteration (it just won't be reflected until the next
        // emit).
        for (cb in listeners) {
            try {
                cb(token, record)
            } catch (e: Exception) {
                // A raising listener must not stop the rest from running.
            }
        }
    }
}

/** In-process, non-persistent auth store. The default. */
class MemoryAuthStore : AuthStore()

/**
 * JSON-file-backed auth store, for CLI/script use across process runs.
 *
 * Port of `FileAuthStore` in `clients/python/src/zigbase/auth_store.py`
 * (TypeScript has no filesystem analogue; its `LocalAuthStore` /
 * `CookieAuthStore` are browser/HTTP-specific and are not ported). Loads
 * eagerly on construction. Per repo philosophy, an unreadable file
 * (missing, a directory, unparsable JSON, wrong shape, or not valid UTF-8)
 * is treated as nonexistent: the store simply starts empty rather than
 * raising.
 *
 * Writes are atomic and the file is created with owner-only (`0600`)
 * permissions, since it holds a live auth token: each `save`/`clear`
 * writes a same-directory temp file -- named uniquely per *call* (not just
 * per process), so concurrent writers on the same store never collide on
 * the exclusive-create step below -- then `Files.move(..., ATOMIC_MOVE)`s
 * it into place. The temp file is cleaned up if either step fails.
 */
class FileAuthStore(
    path: Path,
) : AuthStore() {
    private val path: Path = path.toAbsolutePath()

    init {
        load()
    }

    private fun load() {
        if (!Files.isRegularFile(this.path)) return

        val bytes =
            try {
                Files.readAllBytes(this.path)
            } catch (e: IOException) {
                return
            }

        val text =
            try {
                decodeStrictUtf8(bytes)
            } catch (e: CharacterCodingException) {
                return
            }

        val parsed =
            try {
                Json.parseToJsonElement(text)
            } catch (e: SerializationException) {
                return
            }

        val obj = parsed as? JsonObject ?: return
        val loadedToken = (obj["token"] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val loadedRecord = obj["record"] as? JsonObject
        restoreQuietly(loadedToken, loadedRecord)
    }

    override fun save(
        token: String?,
        record: JsonObject?,
    ) {
        write(token, record)
        super.save(token, record)
    }

    override fun clear() {
        write(null, null)
        super.clear()
    }

    private fun write(
        token: String?,
        record: JsonObject?,
    ) {
        val parent = path.parent
        if (parent != null) Files.createDirectories(parent)

        val payload =
            buildJsonObject {
                put("token", token?.let { JsonPrimitive(it) } ?: JsonNull)
                put("record", record ?: JsonNull)
            }.toString()

        val tmpPath = path.resolveSibling("${path.fileName}.tmp.$pid.${randomHex()}")
        writeNewFile(tmpPath, payload)
        try {
            Files.move(tmpPath, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (e: Exception) {
            Files.deleteIfExists(tmpPath)
            throw e
        }
    }

    private fun writeNewFile(
        tmpPath: Path,
        payload: String,
    ) {
        try {
            openOwnerOnlyChannel(tmpPath).use { channel ->
                channel.write(ByteBuffer.wrap(payload.toByteArray(StandardCharsets.UTF_8)))
            }
        } catch (e: Exception) {
            Files.deleteIfExists(tmpPath)
            throw e
        }
    }

    private companion object {
        val pid: Long = ProcessHandle.current().pid()
        val secureRandom = SecureRandom()

        fun randomHex(byteCount: Int = 4): String {
            val bytes = ByteArray(byteCount)
            secureRandom.nextBytes(bytes)
            return bytes.joinToString("") { "%02x".format(it) }
        }
    }
}

/**
 * Opens [tmpPath] for exclusive create+write, restricted to the owner.
 *
 * Prefers the POSIX `rw-------` file-attribute form: the permissions are
 * applied by the same syscall that creates the file, so there is never a
 * window where the file briefly exists world-readable. On a filesystem
 * without POSIX permission support (e.g. a Windows JVM, or FAT/exFAT even
 * on Linux/macOS), `Files.newByteChannel` rejects the POSIX
 * [java.nio.file.attribute.FileAttribute] with [UnsupportedOperationException];
 * this falls back to plain creation plus a best-effort
 * [newPlainChannelWithBestEffortOwnerOnly] restriction. That fallback isn't
 * atomic -- there's a brief window post-create, pre-`setReadable` where the
 * file has the filesystem's default permissions -- but it's the closest a
 * non-POSIX filesystem allows, and mirrors the Python port's
 * `os.open(..., 0o600)` (itself a no-op mode on Windows).
 */
internal fun openOwnerOnlyChannel(tmpPath: Path): SeekableByteChannel =
    try {
        newPosixOwnerOnlyChannel(tmpPath)
    } catch (e: UnsupportedOperationException) {
        newPlainChannelWithBestEffortOwnerOnly(tmpPath)
    }

private fun newPosixOwnerOnlyChannel(tmpPath: Path): SeekableByteChannel {
    val ownerOnly = PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------"))
    return Files.newByteChannel(tmpPath, setOf(StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE), ownerOnly)
}

/**
 * Non-POSIX fallback for [openOwnerOnlyChannel]: creates [tmpPath] with the
 * filesystem's default permissions, then narrows it to owner-read/write via
 * [java.io.File.setReadable]/[java.io.File.setWritable]. Each call's boolean
 * result is ignored (best-effort, matching the no-throw-on-Windows semantics
 * the Python port relies on for its own POSIX-mode `os.open` call) --
 * exercised directly (rather than only through the
 * [UnsupportedOperationException] catch above, which isn't reproducible on
 * a POSIX CI runner) by a unit test asserting the resulting permissions.
 */
internal fun newPlainChannelWithBestEffortOwnerOnly(tmpPath: Path): SeekableByteChannel {
    val channel = Files.newByteChannel(tmpPath, setOf(StandardOpenOption.CREATE_NEW, StandardOpenOption.WRITE))
    val file = tmpPath.toFile()
    file.setReadable(false, false)
    file.setReadable(true, true)
    file.setWritable(false, false)
    file.setWritable(true, true)
    return channel
}

private fun decodeStrictUtf8(bytes: ByteArray): String {
    val decoder =
        StandardCharsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
    return decoder.decode(ByteBuffer.wrap(bytes)).toString()
}
