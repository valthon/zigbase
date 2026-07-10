package io.github.valthon.zigbase.integration

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.jupiter.api.Assumptions
import java.io.IOException
import java.net.ServerSocket
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpRequest.BodyPublishers
import java.net.http.HttpResponse.BodyHandlers
import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import java.time.Instant
import java.util.concurrent.TimeUnit

/*
 * Live-server integration harness: a companion-object launcher (mirroring
 * `clients/dart/test/integration/harness.dart`'s free-port/temp-dir/superuser
 * -CLI/health-poll launch mechanics and `clients/python/tests/integration
 * /conftest.py`'s bootstrap shapes), rather than a JUnit5 extension -- this
 * repo has exactly one live-server test class, so the simpler companion
 * object plus a `@BeforeAll`/`@AfterAll` pair on that class gives "one server
 * per suite run" with no cross-class store plumbing.
 *
 * Setup (superuser token fetch, collection bootstrap) goes over a plain JDK
 * `HttpClient` rather than the SDK under test -- matching every sibling
 * harness (Python's `httpx`, Dart's `package:http`, TypeScript's raw
 * `fetch`), so a bug in the SDK's own request path can never make the fixture
 * itself unable to start.
 */

const val SUPERUSER_EMAIL = "admin@test.local"
const val SUPERUSER_PASSWORD = "test-password-123"

private const val START_ATTEMPTS = 5
private val HEALTH_TIMEOUT: Duration = Duration.ofSeconds(20)

/** A launched, healthy test server plus the superuser token seeded into it. */
class LaunchedServer internal constructor(
    val baseUrl: String,
    val superuserToken: String,
    private val process: Process,
    private val dataDir: Path,
) {
    /** SIGTERM (destroy) the server, escalating to SIGKILL after 5s, then remove its tempdir. */
    fun stop() {
        process.destroy()
        val exited = process.waitFor(5, TimeUnit.SECONDS)
        if (!exited) {
            process.destroyForcibly()
            process.waitFor(5, TimeUnit.SECONDS)
        }
        dataDir.toFile().deleteRecursively()
    }
}

/**
 * `ZIGBASE_TEST_BINARY`, or `null` when unset -- callers guard on this via
 * [requireBinaryOrSkip] before touching the filesystem or a process.
 */
fun testBinaryPath(): String? = System.getenv("ZIGBASE_TEST_BINARY")?.takeIf { it.isNotBlank() }

/**
 * `Assumptions.assumeTrue`-based skip guard for a `@BeforeAll`: when
 * `ZIGBASE_TEST_BINARY` is unset, aborts the whole class as SKIPPED (not
 * failed) -- verified via `gradle integrationTest` output showing "skipped",
 * never "failed", when the env var is absent.
 */
fun requireBinaryOrSkip(): String {
    val bin = testBinaryPath()
    Assumptions.assumeTrue(bin != null, "ZIGBASE_TEST_BINARY not set; skipping live-server integration tests")
    return bin!!
}

private fun freePort(): Int = ServerSocket(0).use { it.localPort }

// The default client negotiates HTTP/2 (an `Upgrade: h2c` cleartext-upgrade
// attempt on every request), which facil.io -- HTTP/1.1 only -- answers with
// a flat 400 instead of falling back. Pin to HTTP/1.1 explicitly.
private val http: HttpClient = HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).build()

/** Polls `GET <baseUrl>/api/health` until it answers 200, aborting immediately if [process] exits first. */
private fun waitForHealth(
    baseUrl: String,
    process: Process,
    timeout: Duration,
) {
    val deadline = Instant.now().plus(timeout)
    while (Instant.now().isBefore(deadline)) {
        if (!process.isAlive) {
            throw IllegalStateException("server exited before becoming healthy (code=${process.exitValue()})")
        }
        try {
            val req =
                HttpRequest
                    .newBuilder(URI.create("$baseUrl/api/health"))
                    .timeout(Duration.ofSeconds(1))
                    .GET()
                    .build()
            val res = http.send(req, BodyHandlers.discarding())
            if (res.statusCode() == 200) return
        } catch (e: IOException) {
            // not up yet
        }
        Thread.sleep(150)
    }
    throw IllegalStateException("server did not become healthy within $timeout")
}

/** `POST {baseUrl}/api/collections/_superusers/auth-with-password` -- returns the bearer token. */
private fun fetchSuperuserToken(baseUrl: String): String {
    val payload =
        buildJsonObject {
            put("identity", SUPERUSER_EMAIL)
            put("password", SUPERUSER_PASSWORD)
        }.toString()
    val req =
        HttpRequest
            .newBuilder(URI.create("$baseUrl/api/collections/_superusers/auth-with-password"))
            .timeout(Duration.ofSeconds(5))
            .header("content-type", "application/json")
            .POST(BodyPublishers.ofString(payload))
            .build()
    val res = http.send(req, BodyHandlers.ofString())
    if (res.statusCode() != 200) {
        throw IllegalStateException("superuser auth failed: ${res.statusCode()} ${res.body()}")
    }
    val token = Json.parseToJsonElement(res.body()).jsonObjectOrThrow()["token"]
    return (token as? JsonPrimitive)?.content
        ?: throw IllegalStateException("superuser auth response missing token: ${res.body()}")
}

private fun JsonElement.jsonObjectOrThrow(): JsonObject =
    this as? JsonObject ?: throw IllegalStateException("expected a JSON object, got: $this")

/**
 * Spawn `binary superuser create` + `binary serve --insecure-cookies` on a
 * free port, retrying on a fresh port + tempdir when a start attempt fails
 * (e.g. a lost port-collision race causes the zap listener to exit early).
 */
fun startServer(binary: String): LaunchedServer {
    var lastError: Exception? = null
    repeat(START_ATTEMPTS) {
        val dataDir = Files.createTempDirectory("zb_kt_it_")
        val suProc =
            ProcessBuilder(
                binary,
                "superuser",
                "create",
                "--email",
                SUPERUSER_EMAIL,
                "--password",
                SUPERUSER_PASSWORD,
                "--data-dir",
                dataDir.toString(),
            ).redirectErrorStream(true).start()
        val suOutput = suProc.inputStream.bufferedReader().readText()
        val suExit = suProc.waitFor()
        if (suExit != 0) {
            dataDir.toFile().deleteRecursively()
            throw IllegalStateException("superuser create failed (exit $suExit): $suOutput")
        }

        val port = freePort()
        val serveProc =
            ProcessBuilder(
                binary,
                "serve",
                "--http-port",
                port.toString(),
                "--data-dir",
                dataDir.toString(),
                "--insecure-cookies",
            ).redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start()
        val baseUrl = "http://127.0.0.1:$port"
        try {
            waitForHealth(baseUrl, serveProc, HEALTH_TIMEOUT)
            val token = fetchSuperuserToken(baseUrl)
            return LaunchedServer(baseUrl, token, serveProc, dataDir)
        } catch (e: Exception) {
            lastError = e
            serveProc.destroyForcibly()
            serveProc.waitFor(5, TimeUnit.SECONDS)
            dataDir.toFile().deleteRecursively()
        }
    }
    throw IllegalStateException("server did not start after $START_ATTEMPTS attempts: $lastError")
}

/** `POST {baseUrl}/api/collections` as the superuser -- throws with the response body on failure. */
fun createCollection(
    baseUrl: String,
    token: String,
    definition: JsonObject,
) {
    val req =
        HttpRequest
            .newBuilder(URI.create("$baseUrl/api/collections"))
            .timeout(Duration.ofSeconds(5))
            .header("content-type", "application/json")
            .header("authorization", "Bearer $token")
            .POST(BodyPublishers.ofString(definition.toString()))
            .build()
    val res = http.send(req, BodyHandlers.ofString())
    if (res.statusCode() >= 300) {
        throw IllegalStateException("create collection '${definition["name"]}' failed: ${res.statusCode()} ${res.body()}")
    }
}

/**
 * A `@public` base collection: required text `title`, numeric `views`,
 * single-select file `cover`. Mirrors `conftest.py`'s `_posts_definition`.
 */
fun postsDefinition(name: String): JsonObject =
    buildJsonObject {
        put("name", name)
        put("type", "base")
        put(
            "fields",
            buildJsonArray {
                add(
                    buildJsonObject {
                        put("id", "")
                        put("name", "title")
                        put("type", "text")
                        put("required", true)
                        put("options", buildJsonObject {})
                    },
                )
                add(
                    buildJsonObject {
                        put("id", "")
                        put("name", "views")
                        put("type", "number")
                        put("options", buildJsonObject {})
                    },
                )
                add(
                    buildJsonObject {
                        put("id", "")
                        put("name", "cover")
                        put("type", "file")
                        put("options", buildJsonObject { put("maxSelect", 1) })
                    },
                )
            },
        )
        put("listRule", "@public")
        put("viewRule", "@public")
        put("createRule", "@public")
        put("updateRule", "@public")
        put("deleteRule", "@public")
    }

/**
 * No rule keys set at all -- blank, i.e. Locked (superusers only) per
 * `rules.zig`'s safe-by-default policy -- for the anon-403 coverage. Mirrors
 * `conftest.py`'s `_locked_definition`.
 */
fun lockedDefinition(name: String): JsonObject =
    buildJsonObject {
        put("name", name)
        put("type", "base")
        put(
            "fields",
            buildJsonArray {
                add(
                    buildJsonObject {
                        put("id", "")
                        put("name", "title")
                        put("type", "text")
                        put("options", buildJsonObject {})
                    },
                )
            },
        )
    }

/**
 * An auth-type collection for the password-auth/refresh/logout coverage.
 * `createRule` stays Locked (default) -- records are always seeded by the
 * superuser client, never via public signup. `viewRule`/`listRule` are
 * scoped to the caller's own record (`@request.auth.id = id`), giving the
 * auth-refresh test a genuinely auth-gated endpoint to prove the refreshed
 * token against, and denying anon access with a real (not accidental) 404.
 * Mirrors `conftest.py`'s `_members_definition`.
 */
fun membersDefinition(name: String): JsonObject =
    buildJsonObject {
        put("name", name)
        put("type", "auth")
        put(
            "fields",
            buildJsonArray {
                add(
                    buildJsonObject {
                        put("id", "")
                        put("name", "name")
                        put("type", "text")
                        put("options", buildJsonObject {})
                    },
                )
            },
        )
        put("viewRule", "@request.auth.id = id")
        put("listRule", "@request.auth.id = id")
    }
