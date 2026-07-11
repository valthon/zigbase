package io.github.valthon.zigbase

import io.github.valthon.zigbase.auth.AuthStore
import io.github.valthon.zigbase.auth.MemoryAuthStore
import io.github.valthon.zigbase.internal.RequestSpec
import io.github.valthon.zigbase.internal.Transport
import io.github.valthon.zigbase.internal.ensureObjectBody
import io.github.valthon.zigbase.realtime.KtorWebSocketConnector
import io.github.valthon.zigbase.realtime.RealtimeConnection
import io.github.valthon.zigbase.realtime.RealtimeService
import io.ktor.client.HttpClient
import io.ktor.client.statement.HttpResponse
import io.ktor.http.HttpMethod
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject

/*
 * The top-level entry point consumers construct: assembles a [Transport]
 * plus every service ([CollectionService] per collection name, [FilesService],
 * [AccountsService], [AnalyticsService], [SendersService]) around one
 * [AuthStore].
 *
 * Port of `ZigBase`/`AsyncZigBase` in `clients/python/src/zigbase/client.py`
 * (the hardened normative reference for the `close()`/ownership and
 * `withAccount` sibling contract -- three review cycles landed there),
 * cross-checked against `clients/dart/lib/src/client.dart`'s `ZigbaseClient`
 * for the same contract in a class-based idiom. Unlike collection.ts/
 * collection.dart's per-service constructor shape, every service here reads/
 * writes auth state through `Transport.authStore` (Task 6/7's design), so
 * this facade never has to pass `authStore` to a service explicitly.
 *
 * Ownership: a self-created `HttpClient` (no `httpClient` passed in) is
 * closed by [ZigbaseClient.close]; a caller-supplied one is not. [withAccount]
 * returns a sibling built by re-invoking this same constructor with this
 * instance's [authStore] and underlying `HttpClient` (via [Transport]'s
 * module-internal accessor) passed through verbatim as `httpClient` -- the
 * constructor's existing "an explicit `httpClient` is never owned" rule then
 * makes the sibling correctly never own the shared client, with no
 * sibling-specific code path. A login/logout via either client's [authStore]
 * is visible to both (same instance); closing the parent closes the shared
 * client for every sibling. [close] is idempotent (matching `httpx.Client
 * .close()`/`http.Client.close()`, which already tolerate repeated calls);
 * unlike `client.dart`'s `StateError` gate on every accessor after close,
 * this has no extra closed-guard -- using a closed client surfaces ktor's
 * own exception on the next request, exactly like the Python reference.
 *
 * `collection(name)` matches `client.ts`/`client.py`: a fresh
 * [CollectionService] instance on every call (no per-name cache) -- it is a
 * thin, stateless wrapper over [Transport], so caching would only save an
 * allocation, not identity-sensitive state.
 */

/**
 * The official ZigBase Kotlin client.
 *
 * ```kotlin
 * val zb = ZigbaseClient("http://127.0.0.1:8090")
 * zb.collection("users").authWithPassword("a@b.com", "secret")
 * val posts = zb.collection("posts").getList()
 * zb.close()
 * ```
 */
class ZigbaseClient(
    baseUrl: String,
    authStore: AuthStore = MemoryAuthStore(),
    autoRefresh: Boolean = false,
    authCollection: String? = null,
    accountId: String? = null,
    lang: String? = null,
    maxRetries: Int = 3,
    httpClient: HttpClient? = null,
    onRealtimeError: ((String) -> Unit)? = null,
) : AutoCloseable {
    /** The normalized base URL (no trailing slash). */
    val baseUrl: String = normalizeBaseUrl(baseUrl)

    /** The auth store backing every service built from this client. */
    val authStore: AuthStore = authStore

    private val autoRefresh = autoRefresh
    private val authCollection = authCollection
    private val lang = lang
    private val maxRetries = maxRetries
    private val onRealtimeError = onRealtimeError
    private val ownsClient = httpClient == null
    private val transport: Transport =
        Transport(
            this.baseUrl,
            authStore,
            authCollection = authCollection,
            autoRefresh = autoRefresh,
            accountId = accountId,
            lang = lang,
            maxRetries = maxRetries,
            httpClient = httpClient,
        )
    private var closed = false

    private var filesService: FilesService? = null
    private var accountsService: AccountsService? = null
    private var analyticsService: AnalyticsService? = null
    private var sendersService: SendersService? = null

    /** The underlying `HttpClient`, exposed module-internally for test identity assertions. Not part of the public SDK surface. */
    internal val httpClientForTesting: HttpClient
        get() = transport.httpClient

    // Set (only) when `realtime` builds its own default connector -- i.e.
    // `realtimeConnectorForTesting` was unset at first access -- so `close`
    // knows there's an owned `HttpClient` to tear down. `@Volatile`: written
    // once inside `realtimeDelegate`'s synchronized initializer, read from
    // `close()` on (potentially) a different thread.
    @Volatile
    private var realtimeConnectorOwned: KtorWebSocketConnector? = null

    /**
     * Test-only connector injection point, mirroring [httpClientForTesting]:
     * `realtimeConnector` cannot be a public constructor parameter (its type
     * names the internal [RealtimeConnection]), so a test sets this field
     * BEFORE ever touching [realtime] to swap in a fake connector. `null`
     * (the default) uses the production ktor-CIO WebSocket connector.
     */
    internal var realtimeConnectorForTesting: (suspend (String) -> RealtimeConnection)? = null

    // `LazyThreadSafetyMode.SYNCHRONIZED` (not the unsynchronized pattern the
    // other lazily-cached services above use): a duplicated [RealtimeService]
    // on a concurrent-first-access race would leak a whole coroutine scope,
    // unlike the other services above, which are cheap, stateless wrappers
    // where a duplicate is harmless. The initializer itself never suspends
    // (constructing [KtorWebSocketConnector]/[RealtimeService] is plain
    // object setup), so nothing suspends while this lock is held.
    private val realtimeDelegate =
        lazy(LazyThreadSafetyMode.SYNCHRONIZED) {
            val injected = realtimeConnectorForTesting
            val connector: suspend (String) -> RealtimeConnection =
                if (injected != null) {
                    injected
                } else {
                    val owned = KtorWebSocketConnector()
                    realtimeConnectorOwned = owned
                    owned.connect
                }
            RealtimeService(baseUrl, transport.authStore, connector, onRealtimeError)
        }

    /**
     * Lazily-created, cached [RealtimeService] -- the same instance on every
     * access. Uses the injected [realtimeConnectorForTesting] connector when
     * set (test-only); otherwise the production ktor-CIO WebSocket connector,
     * whose backing `HttpClient` this instance then owns and closes in
     * [close]. A [withAccount] sibling gets its own, independent instance
     * (its own scope, its own connection).
     */
    val realtime: RealtimeService
        get() = realtimeDelegate.value

    /**
     * A [CollectionService] bound to [name]. Matches `client.ts`/
     * `client.py`'s `collection()`: a fresh instance every call, no
     * per-name cache.
     */
    fun collection(name: String): CollectionService = CollectionService(transport, name)

    /** Lazily-created, cached [FilesService]. */
    val files: FilesService
        get() = filesService ?: FilesService(transport, baseUrl).also { filesService = it }

    /** Lazily-created, cached [AccountsService]. */
    val accounts: AccountsService
        get() = accountsService ?: AccountsService(transport).also { accountsService = it }

    /** Lazily-created, cached [AnalyticsService]. */
    val analytics: AnalyticsService
        get() = analyticsService ?: AnalyticsService(transport).also { analyticsService = it }

    /** Lazily-created, cached [SendersService]. */
    val senders: SendersService
        get() = sendersService ?: SendersService(transport).also { sendersService = it }

    /**
     * Issues a request through the shared [Transport] and returns its
     * parsed JSON body (or `null` for a 204/empty body): the auth header,
     * 401 auto-refresh, and 429 backoff all apply, exactly as for every
     * service call (they share this same transport).
     */
    suspend fun send(
        method: HttpMethod,
        path: String,
        query: Map<String, String>? = null,
        body: Map<String, Any?>? = null,
        headers: Map<String, String>? = null,
    ): JsonElement? = transport.request(RequestSpec(method, path, query = query, body = body, headers = headers))

    /**
     * Escape hatch: returns the [HttpResponse] as-is -- no JSON parsing, no
     * error mapping, no 401 refresh, no 429 retry. Accepts the same
     * `query`/`body`/`headers` as [send]; auth/lang/account headers and
     * body encoding still apply.
     */
    suspend fun rawRequest(
        method: HttpMethod,
        path: String,
        query: Map<String, String>? = null,
        body: Map<String, Any?>? = null,
        headers: Map<String, String>? = null,
    ): HttpResponse = transport.rawRequest(RequestSpec(method, path, query = query, body = body, headers = headers))

    /** `GET /api/health`. */
    suspend fun health(): JsonObject = ensureObjectBody(send(HttpMethod.Get, "/api/health"), "health")

    /**
     * A sibling [ZigbaseClient] sharing this instance's [authStore] and
     * underlying `HttpClient` (a login/logout on either is visible to
     * both), but sending `X-Account-Id: <accountId>` on every request. See
     * the class doc for the [close] ownership implications.
     */
    fun withAccount(accountId: String): ZigbaseClient =
        ZigbaseClient(
            baseUrl = baseUrl,
            authStore = authStore,
            autoRefresh = autoRefresh,
            authCollection = authCollection,
            accountId = accountId,
            lang = lang,
            maxRetries = maxRetries,
            httpClient = transport.httpClient,
            onRealtimeError = onRealtimeError,
        ).also { it.realtimeConnectorForTesting = realtimeConnectorForTesting }

    /**
     * Tears down [realtime] (if it was ever created) before closing the
     * underlying `HttpClient` -- but only if this instance created it (no
     * `httpClient` was passed in, including every [withAccount] sibling).
     * Idempotent.
     *
     * [realtime]'s own [RealtimeService.close] is `suspend`; this method
     * isn't (it overrides `AutoCloseable.close`), so it calls
     * [RealtimeService.shutdown] instead -- see that method's doc. When
     * [realtime] built the default connector (no test connector was
     * injected), the owned [KtorWebSocketConnector] is closed right after:
     * that's what actually severs the live WebSocket connection for the
     * production path (an injected fake connector, by contrast, owns no
     * resource of its own to close here).
     */
    override fun close() {
        if (closed) return
        closed = true
        if (realtimeDelegate.isInitialized()) {
            realtimeDelegate.value.shutdown()
            realtimeConnectorOwned?.close()
        }
        if (ownsClient) transport.close()
    }
}

private fun normalizeBaseUrl(baseUrl: String): String = baseUrl.trimEnd('/')
