package io.github.valthon.zigbase.internal

import io.github.valthon.zigbase.auth.AuthStore
import io.github.valthon.zigbase.errors.ZigbaseException
import io.github.valthon.zigbase.errors.parseErrorResponse
import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.request.forms.MultiPartFormDataContent
import io.ktor.client.request.forms.formData
import io.ktor.client.request.headers
import io.ktor.client.request.parameter
import io.ktor.client.request.request
import io.ktor.client.request.setBody
import io.ktor.client.statement.HttpResponse
import io.ktor.client.statement.bodyAsText
import io.ktor.http.ContentType
import io.ktor.http.Headers
import io.ktor.http.HttpHeaders
import io.ktor.http.HttpMethod
import io.ktor.http.HttpStatusCode
import io.ktor.http.contentType
import io.ktor.http.isSuccess
import io.ktor.http.quote
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/*
 * The HTTP engine every ZigBase Kotlin service builds on: header assembly,
 * JSON/multipart bodies, the 401 single-flight refresh state machine, and
 * 429 backoff.
 *
 * Port of `SyncTransport`/`AsyncTransport` in
 * `clients/python/src/zigbase/_transport.py` (the normative reference --
 * every hardening there, from three review cycles, is a requirement here,
 * not an option), with the header/body shape cross-checked against
 * `clients/typescript/src/transport.ts` and the single-flight-lock shape
 * mirroring `clients/dart/lib/src/transport.dart`'s `_awaitRefresh`.
 *
 * 429 backoff retries for any HTTP method, matching transport.ts/
 * transport.dart (neither gates on idempotency): a 429 is a rejection
 * before the request is processed, so retrying it can't duplicate a
 * write's side effect.
 */

private const val MAX_BACKOFF_MS = 30_000L

/**
 * The HTTP engine every service builds on.
 *
 * A self-created `HttpClient(CIO)` is owned by this [Transport] and closed
 * by [close]; a caller-supplied [httpClient] is never closed here (it
 * outlives this transport).
 */
internal class Transport internal constructor(
    baseUrl: String,
    val authStore: AuthStore,
    private val authCollection: String? = null,
    private val autoRefresh: Boolean = false,
    private val accountId: String? = null,
    private val lang: String? = null,
    private val maxRetries: Int = 3,
    httpClient: HttpClient? = null,
    private val delayFn: suspend (Long) -> Unit = { delay(it) },
) {
    private val baseUrl: String = baseUrl.trimEnd('/')
    private val ownsClient = httpClient == null
    private val client: HttpClient = httpClient ?: HttpClient(CIO)

    /**
     * The underlying `HttpClient`, exposed module-internally so
     * [io.github.valthon.zigbase.ZigbaseClient.withAccount] can pass it
     * through verbatim to a sibling's [Transport] -- the same "an explicit
     * `httpClient` is never owned" rule that already governs [ownsClient]
     * then makes the sibling correctly never own the shared client, with no
     * sibling-specific code path. Not part of the public SDK surface.
     */
    internal val httpClient: HttpClient
        get() = client

    // The single-flight 401 refresh. The first 401 starts it; every 401
    // that lands while it runs joins the SAME flight and then retries its
    // own request once (still bounded per-exchange by `didRefresh` in
    // `exchange`), so a parallel burst of expired-token requests all
    // succeed after exactly one refresh call. `refreshGuard` only ever
    // protects the tiny check-and-set of `refreshFlight` -- it is never
    // held across the network call or a waiter's `flight.await()`, so it
    // cannot deadlock against itself or against a waiter.
    private val refreshGuard = Mutex()
    private var refreshFlight: CompletableDeferred<Unit>? = null

    /** Closes the underlying `HttpClient`, but only if this transport created it. */
    fun close() {
        if (ownsClient) client.close()
    }

    /**
     * Escape hatch: performs exactly one HTTP call and returns the
     * [HttpResponse] as-is -- no error mapping, no 401 refresh, no 429
     * retry. Auth/lang/account headers and body encoding still apply.
     */
    suspend fun rawRequest(spec: RequestSpec): HttpResponse = performOnce(spec)

    /**
     * Performs [spec], following the 401-refresh/429-backoff state machine,
     * and returns the parsed JSON body (or `null` for a 204/empty body).
     * Throws [ZigbaseException] for a non-2xx response that survives that
     * state machine.
     */
    suspend fun request(spec: RequestSpec): JsonElement? {
        val response = exchange(spec)
        return decodeResponse(response)
    }

    // --- internals ---------------------------------------------------------

    private suspend fun performOnce(spec: RequestSpec): HttpResponse {
        val url = baseUrl + spec.path
        val headerMap =
            buildHeaders(
                spec.headers,
                token = authStore.token,
                skipAuth = spec.skipAuth,
                lang = lang,
                accountId = accountId,
            )
        return client.request(url) {
            method = spec.method
            spec.query?.forEach { (k, v) -> parameter(k, v) }
            headers { headerMap.forEach { (k, v) -> append(k, v) } }
            // A GET body is dropped, matching transport.ts's `buildRequestInit`
            // and transport.dart's `_perform` (both gate on method != GET).
            if (spec.body != null && spec.method != HttpMethod.Get) {
                when (val encoded = encodeBody(spec.body)) {
                    is EncodedBody.Json -> {
                        contentType(ContentType.Application.Json)
                        setBody(encoded.element.toString())
                    }

                    is EncodedBody.Multipart -> {
                        // Never set Content-Type manually (rule 6):
                        // MultiPartFormDataContent derives the multipart
                        // boundary itself.
                        setBody(
                            MultiPartFormDataContent(
                                formData {
                                    for ((key, value) in encoded.fields) append(key, value)
                                    for (file in encoded.files) {
                                        append(
                                            file.key,
                                            file.content,
                                            Headers.build {
                                                if (file.contentType != null) {
                                                    append(HttpHeaders.ContentType, file.contentType)
                                                }
                                                // `quote()` (ktor's RFC 2616 quoted-string
                                                // encoder) escapes `\` and `"` so a filename
                                                // containing either can't prematurely terminate
                                                // this parameter's quoted-string value.
                                                append(HttpHeaders.ContentDisposition, "filename=${file.filename.quote()}")
                                            },
                                        )
                                    }
                                },
                            ),
                        )
                    }
                }
            }
        }
    }

    private suspend fun exchange(spec: RequestSpec): HttpResponse {
        var didRefresh = false
        var attempt = 0

        while (true) {
            val response = performOnce(spec)

            if (response.status.isSuccess()) {
                return response
            }

            if (response.status == HttpStatusCode.Unauthorized &&
                autoRefresh &&
                authCollection != null &&
                !didRefresh &&
                !spec.skipAuth &&
                !spec.isRefresh &&
                authStore.token != null
            ) {
                didRefresh = true
                try {
                    awaitRefresh()
                    continue
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    // Refresh failed -- fall through and raise this
                    // request's ORIGINAL 401 below, not the refresh error.
                }
            }

            if (response.status == HttpStatusCode.TooManyRequests && attempt < maxRetries) {
                val delayMs = computeBackoff(response.headers[HttpHeaders.RetryAfter], attempt)
                attempt += 1
                delayFn(delayMs)
                continue
            }

            throw parseErrorResponse(
                response.status.value,
                response.bodyAsText(),
                response.call.request.url
                    .toString(),
                response.status.description.ifBlank { null },
            )
        }
    }

    /** Joins the in-flight refresh, or becomes its owner and starts it. */
    private suspend fun awaitRefresh() {
        val (flight, isOwner) =
            refreshGuard.withLock {
                val existing = refreshFlight
                if (existing != null) {
                    existing to false
                } else {
                    val created = CompletableDeferred<Unit>()
                    refreshFlight = created
                    created to true
                }
            }

        if (!isOwner) {
            flight.await()
            return
        }

        try {
            performRefresh()
            flight.complete(Unit)
        } catch (e: Throwable) {
            // Settled on every BaseException path, including
            // CancellationException, so a cancelled owner can't strand its
            // waiters awaiting a flight that will never complete.
            flight.completeExceptionally(e)
            throw e
        } finally {
            // Runs even if this coroutine was cancelled (NonCancellable),
            // so the flight slot is always cleared -- otherwise a
            // cancelled owner would permanently wedge every future 401
            // into joining a flight nobody will ever complete.
            withContext(NonCancellable) {
                refreshGuard.withLock { refreshFlight = null }
            }
        }
    }

    private suspend fun performRefresh() {
        val collection = checkNotNull(authCollection) { "performRefresh called without an authCollection" }
        val spec =
            RequestSpec(
                method = HttpMethod.Post,
                path = "/api/collections/$collection/auth-refresh",
                isRefresh = true,
            )
        val result = request(spec)
        val (token, record) = parseRefreshResult(result, spec.path)
        authStore.save(token, record)
    }
}

/**
 * Assembles the effective request headers (rule 1): `Authorization` and
 * `Accept-Language` are always (re)applied on top of any caller-supplied
 * header of the same name; `X-Account-Id` is applied only when the caller
 * hasn't already set it -- so a per-request `X-Account-Id` wins over the
 * transport-wide `accountId`, matching transport.ts/transport.dart.
 */
private fun buildHeaders(
    specHeaders: Map<String, String>?,
    token: String?,
    skipAuth: Boolean,
    lang: String?,
    accountId: String?,
): Map<String, String> {
    val headers = LinkedHashMap<String, String>()
    specHeaders?.forEach { (k, v) -> headers[k] = v }
    if (!skipAuth && token != null) {
        setHeader(headers, "Authorization", "Bearer $token")
    }
    if (lang != null) {
        setHeader(headers, "Accept-Language", lang)
    }
    if (accountId != null && !hasHeader(headers, "X-Account-Id")) {
        setHeader(headers, "X-Account-Id", accountId)
    }
    return headers
}

/**
 * Sets [name] to [value], first removing any existing key that matches
 * case-insensitively -- so a spec header like `"authorization"` can't
 * survive alongside our canonically-cased `"Authorization"`.
 */
private fun setHeader(
    headers: MutableMap<String, String>,
    name: String,
    value: String,
) {
    headers.keys.filter { it.equals(name, ignoreCase = true) }.forEach { headers.remove(it) }
    headers[name] = value
}

private fun hasHeader(
    headers: Map<String, String>,
    name: String,
): Boolean = headers.keys.any { it.equals(name, ignoreCase = true) }

/**
 * Decodes a 2xx response body (rule 2): 204 or an empty body -> `null`;
 * otherwise parsed JSON.
 */
private suspend fun decodeResponse(response: HttpResponse): JsonElement? {
    if (response.status == HttpStatusCode.NoContent) return null
    val text = response.bodyAsText()
    if (text.isEmpty()) return null
    return Json.parseToJsonElement(text)
}

/**
 * 429 backoff delay (rule 4): a positive, finite numeric `Retry-After` is
 * honored verbatim (seconds, converted to milliseconds); otherwise an
 * exponential delay (`200ms * 2^attempt`) capped at [MAX_BACKOFF_MS].
 */
private fun computeBackoff(
    retryAfter: String?,
    attempt: Int,
): Long {
    if (retryAfter != null) {
        val seconds = retryAfter.toDoubleOrNull()
        if (seconds != null && seconds.isFinite() && seconds > 0) {
            return (seconds * 1000).toLong()
        }
    }
    // Capping the shift (not just the result) matters: past attempt 55 or
    // so, `200L shl attempt` itself overflows/wraps to a negative or tiny
    // Long, and `minOf` against a negative wrapped value would then return
    // that instead of the intended cap.
    return minOf(200L shl attempt.coerceAtMost(20), MAX_BACKOFF_MS)
}

/**
 * Extracts `(token, record)` from an `auth-refresh` 2xx body (mirroring
 * transport.ts's untyped property access, which the JS engine resolves
 * without a runtime shape check).
 *
 * An EMPTY body (204, or a 2xx with no text) decodes to `null` here and to
 * `undefined` in JS; accessing `.token` on `undefined` THROWS a
 * `TypeError` there, which fails the refresh and lets the caller's
 * ORIGINAL 401 propagate without touching the auth store -- so this
 * throws too, rather than silently overwriting a valid token/record with
 * `null`. A body that parses but isn't shaped like `{token, record}` (a
 * list, string, number, or an object missing `"token"`) does NOT throw in
 * JS -- `.token` on any of those is simply `undefined`, and
 * `authStore.save(undefined, undefined)` proceeds -- so that case still
 * clears the store below rather than raising, matching that silent
 * behavior too.
 */
private fun parseRefreshResult(
    result: JsonElement?,
    path: String,
): Pair<String?, JsonObject?> {
    if (result == null) {
        throw ZigbaseException(status = 0, message = "auth-refresh returned an empty response body.", url = path)
    }
    val obj = result as? JsonObject
    val token = (obj?.get("token") as? JsonPrimitive)?.takeIf { it.isString }?.content
    val record = obj?.get("record") as? JsonObject
    return token to record
}

/**
 * Guards the boundary between [Transport.request]'s `JsonElement?` and
 * every service helper that expects a JSON object envelope.
 *
 * [Transport.request] returns `null` for a 204/empty body on ANY 2xx
 * response -- the transport has no way to know a given endpoint's
 * contract promises an object. Without this guard, service helpers would
 * crash with a bare `NullPointerException`/`ClassCastException` on the
 * first member access. Fails loudly with a clear [ZigbaseException]
 * instead, matching the SDK's reject-don't-coerce posture.
 */
internal fun ensureObjectBody(
    element: JsonElement?,
    context: String,
): JsonObject {
    if (element !is JsonObject) {
        throw ZigbaseException(status = 0, message = "Expected a JSON object response ($context).", url = "")
    }
    return element
}

/**
 * Extracts a mandatory string field (e.g. `token`) from a parsed JSON
 * envelope, raising a clear [ZigbaseException] when it is missing or not a
 * string -- matching the TS/Python/Dart SDKs, which throw on a malformed
 * response rather than silently defaulting a mandatory field to `""`. An
 * empty string IS a valid value (some flows legitimately return one) --
 * only absence or a wrong type raises.
 */
internal fun requireStringField(
    obj: JsonObject,
    key: String,
    context: String,
): String {
    val value = obj[key]
    if (value !is JsonPrimitive || !value.isString) {
        throw ZigbaseException(status = 0, message = "Expected a string '$key' in response ($context).", url = "")
    }
    return value.content
}
