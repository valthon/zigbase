package io.github.valthon.zigbase

import io.github.valthon.zigbase.errors.ZigbaseException
import io.github.valthon.zigbase.internal.RequestSpec
import io.github.valthon.zigbase.internal.Transport
import io.github.valthon.zigbase.internal.booleanField
import io.github.valthon.zigbase.internal.encodePathSegment
import io.github.valthon.zigbase.internal.ensureObjectBody
import io.github.valthon.zigbase.internal.parseCursorPage
import io.github.valthon.zigbase.internal.recordItemsField
import io.github.valthon.zigbase.internal.requireStringField
import io.github.valthon.zigbase.internal.stringOrNullField
import io.github.valthon.zigbase.internal.unwrapJsonObjectItems
import io.github.valthon.zigbase.query.buildListParams
import io.ktor.http.HttpMethod
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

/*
 * Per-collection record CRUD + pagination + auth.
 *
 * Port of `CollectionService`/`AsyncCollectionService` in
 * `clients/python/src/zigbase/collection.py` (the hardened normative
 * reference for the auth half -- `requireStringField` on `token`,
 * token-only save on OAuth2 complete, try/finally store clears),
 * cross-checked against `clients/typescript/src/collection.ts` (the wire
 * truth -- its synthesized-404 message on `getFirstListItem` and
 * `changePassword`'s re-auth identity choice win verbatim) and
 * `clients/dart/lib/src/collection.dart`.
 *
 * Unlike collection.ts/collection.dart (which take an `AuthStore` as a
 * separate constructor argument), this reads/writes auth state through
 * `transport.authStore` -- the transport already owns one.
 */

/** The actions the current principal may perform on a specific record. */
data class Abilities(
    val view: Boolean,
    val update: Boolean,
    val delete: Boolean,
)

/**
 * Response shape from the password/refresh/OAuth2-complete auth endpoints.
 *
 * [record] is `null` for [CollectionService.authWithOAuth2]'s response (the
 * `/auth/oauth2/complete` endpoint sets cookies directly and does not
 * return a record); [meta] is provider-specific OAuth2 metadata, populated
 * from the envelope on password/refresh responses but always `null` on
 * [CollectionService.authWithOAuth2] (that endpoint has no metadata to
 * report).
 */
data class AuthResponse(
    val token: String,
    val record: ZbRecord?,
    val meta: JsonObject?,
)

/**
 * Per-collection record CRUD + pagination, over a [Transport].
 *
 * Constructed internally -- obtain one from the top-level client rather than
 * calling this constructor directly.
 */
class CollectionService internal constructor(
    private val transport: Transport,
    val name: String,
) {
    private fun collectionBase(): String = "/api/collections/${encodePathSegment(name)}"

    private fun recordsBase(): String = "${collectionBase()}/records"

    private fun recordPath(id: String): String = "${recordsBase()}/${encodePathSegment(id)}"

    // -----------------------------------------------------------------
    // Auth
    // -----------------------------------------------------------------

    /**
     * `POST /auth-with-password` with `{identity, password}`, `skipAuth =
     * true`. Saves `{token, record}` to the transport's auth store.
     */
    suspend fun authWithPassword(
        identity: String,
        password: String,
    ): AuthResponse {
        val body =
            transport.request(
                RequestSpec(
                    HttpMethod.Post,
                    "${collectionBase()}/auth-with-password",
                    body = mapOf("identity" to identity, "password" to password),
                    skipAuth = true,
                ),
            )
        val auth = parseAuthResponse(body, "authWithPassword")
        transport.authStore.save(auth.token, auth.record?.raw)
        return auth
    }

    /**
     * `POST /auth-refresh` with an empty body. Carries the bearer header
     * (not [RequestSpec.skipAuth]) but is exempt from the transport's
     * single-flight 401-refresh branch ([RequestSpec.isRefresh]) -- a 401
     * here propagates instead of recursing into its own refresh. Saves the
     * response to the transport's auth store.
     */
    suspend fun authRefresh(): AuthResponse {
        val body =
            transport.request(
                RequestSpec(
                    HttpMethod.Post,
                    "${collectionBase()}/auth-refresh",
                    body = emptyMap(),
                    isRefresh = true,
                ),
            )
        val auth = parseAuthResponse(body, "authRefresh")
        transport.authStore.save(auth.token, auth.record?.raw)
        return auth
    }

    /** `GET /auth/oauth2/providers` -- unwraps the house `{items}` list envelope. */
    suspend fun listAuthProviders(): List<JsonObject> {
        val body = transport.request(RequestSpec(HttpMethod.Get, "${collectionBase()}/auth/oauth2/providers"))
        return unwrapJsonObjectItems(body, "listAuthProviders")
    }

    /**
     * `POST /auth/oauth2/initiate` with `{provider}` -- `{authURL,
     * clientId, scopes, state}`, passed through verbatim.
     */
    suspend fun oauth2Init(provider: String): JsonObject {
        val body =
            transport.request(
                RequestSpec(
                    HttpMethod.Post,
                    "${collectionBase()}/auth/oauth2/initiate",
                    body = mapOf("provider" to provider),
                ),
            )
        return ensureObjectBody(body, "oauth2Init")
    }

    /**
     * `POST /auth/oauth2/complete`, `skipAuth = true`. The endpoint sets
     * `zb_auth`/`zb_csrf` cookies directly and does not return a record;
     * only the token is stored/returned ([AuthResponse.record] is `null`).
     * [state] is omitted from the request body entirely when `null`.
     */
    suspend fun authWithOAuth2(
        provider: String,
        code: String,
        codeVerifier: String,
        redirectUrl: String,
        state: String? = null,
    ): AuthResponse {
        val requestBody =
            linkedMapOf<String, Any?>(
                "provider" to provider,
                "code" to code,
                "codeVerifier" to codeVerifier,
                "redirectUrl" to redirectUrl,
            )
        if (state != null) requestBody["state"] = state
        val body =
            transport.request(
                RequestSpec(
                    HttpMethod.Post,
                    "${collectionBase()}/auth/oauth2/complete",
                    body = requestBody,
                    skipAuth = true,
                ),
            )
        val token = requireStringField(ensureObjectBody(body, "authWithOAuth2"), "token", "authWithOAuth2")
        transport.authStore.save(token, null)
        return AuthResponse(token = token, record = null, meta = null)
    }

    /** `POST /auth-logout`. Clears the auth store even when the request fails. */
    suspend fun logout() {
        try {
            transport.request(RequestSpec(HttpMethod.Post, "${collectionBase()}/auth-logout"))
        } finally {
            transport.authStore.clear()
        }
    }

    /** `POST /request-verification` with `{email}`. */
    suspend fun requestVerification(email: String) {
        transport.request(
            RequestSpec(HttpMethod.Post, "${collectionBase()}/request-verification", body = mapOf("email" to email)),
        )
    }

    /** `POST /confirm-verification` with `{token}`, `skipAuth = true`. */
    suspend fun confirmVerification(token: String) {
        transport.request(
            RequestSpec(
                HttpMethod.Post,
                "${collectionBase()}/confirm-verification",
                body = mapOf("token" to token),
                skipAuth = true,
            ),
        )
    }

    /** `POST /request-password-reset` with `{email}`. */
    suspend fun requestPasswordReset(email: String) {
        transport.request(
            RequestSpec(
                HttpMethod.Post,
                "${collectionBase()}/request-password-reset",
                body = mapOf("email" to email),
            ),
        )
    }

    /** `POST /confirm-password-reset` with `{token, password}`, `skipAuth = true`. */
    suspend fun confirmPasswordReset(
        token: String,
        password: String,
    ) {
        transport.request(
            RequestSpec(
                HttpMethod.Post,
                "${collectionBase()}/confirm-password-reset",
                body = mapOf("token" to token, "password" to password),
                skipAuth = true,
            ),
        )
    }

    /**
     * `PATCH /records/:id` with `{password, oldPassword}` (requires ZigBase
     * >= 0.10.0). The server verifies [oldPassword] against the TARGET
     * record (superusers exempt) and rotates its tokenKey -- every
     * outstanding session dies. When the auth store's current principal IS
     * the target record, this additionally re-runs [authWithPassword] with
     * the stored identity (`email`, falling back to `username`) and the
     * new password, so a bearer-token client stays logged in too (a
     * harmless extra login in cookie mode). The auth store is read only
     * AFTER [update] completes, so a store mutation that lands during the
     * update call is observed.
     */
    suspend fun changePassword(
        recordId: String,
        oldPassword: String,
        newPassword: String,
    ): ZbRecord {
        val rec = update(recordId, mapOf("password" to newPassword, "oldPassword" to oldPassword))
        val identity = changePasswordReauthIdentity(transport.authStore.record, recordId)
        if (identity != null) {
            authWithPassword(identity, newPassword)
        }
        return rec
    }

    /**
     * `GET /auth/sessions` -- the caller's active sessions, newest first
     * (requires `.auth.session.store = .table`; `.epoch` mode answers
     * 404). Unwraps `{items}`; wire keys stay snake_case as received
     * (`last_seen`, `user_agent`, `is_current`).
     */
    suspend fun listSessions(): List<JsonObject> {
        val body = transport.request(RequestSpec(HttpMethod.Get, "${collectionBase()}/auth/sessions"))
        return unwrapJsonObjectItems(body, "listSessions")
    }

    /** `DELETE /auth/sessions/:id` -- "log out THIS device" (table mode only). */
    suspend fun revokeSession(sessionId: String) {
        transport.request(
            RequestSpec(HttpMethod.Delete, "${collectionBase()}/auth/sessions/${encodePathSegment(sessionId)}"),
        )
    }

    /**
     * `DELETE /auth/sessions` -- "log out everywhere". Clears the auth
     * store even when the request fails (parity with [logout]).
     */
    suspend fun revokeAllSessions() {
        try {
            transport.request(RequestSpec(HttpMethod.Delete, "${collectionBase()}/auth/sessions"))
        } finally {
            transport.authStore.clear()
        }
    }

    // -----------------------------------------------------------------
    // Records (offset + cursor pagination)
    // -----------------------------------------------------------------

    /**
     * `GET /records` (offset pagination). [perPage] is clamped to the server
     * max of 500. [skipTotal] is sent only when `true` -- offset mode
     * already includes totals by default.
     */
    suspend fun getList(
        page: Int = 1,
        perPage: Int = 30,
        filter: String? = null,
        sort: String? = null,
        expand: String? = null,
        fields: String? = null,
        search: String? = null,
        skipTotal: Boolean = false,
        vector: String? = null,
    ): ListResult {
        val query =
            buildListParams(
                filter = filter,
                sort = sort,
                expand = expand,
                fields = fields,
                search = search,
                page = page,
                perPage = perPage.coerceIn(1, 500),
                skipTotal = if (skipTotal) true else null,
                vector = vector,
            )
        val body = transport.request(RequestSpec(HttpMethod.Get, recordsBase(), query = query))
        return parseListResult(body, "getList")
    }

    /** `GET /records/:id`. */
    suspend fun getOne(
        id: String,
        expand: String? = null,
        fields: String? = null,
    ): ZbRecord {
        val query = buildListParams(expand = expand, fields = fields)
        val body = transport.request(RequestSpec(HttpMethod.Get, recordPath(id), query = query))
        return ZbRecord(ensureObjectBody(body, "getOne"))
    }

    /**
     * `getList(1, 1, skipTotal = true, filter = filter, ...)` sugar. Throws a
     * synthesized 404 [ZigbaseException] ("No record found matching the
     * filter.") when nothing matches.
     */
    suspend fun getFirstListItem(
        filter: String,
        sort: String? = null,
        expand: String? = null,
        fields: String? = null,
        search: String? = null,
        vector: String? = null,
    ): ZbRecord {
        val result =
            getList(
                page = 1,
                perPage = 1,
                filter = filter,
                sort = sort,
                expand = expand,
                fields = fields,
                search = search,
                skipTotal = true,
                vector = vector,
            )
        return result.items.firstOrNull() ?: throw ZigbaseException(
            status = 404,
            message = "No record found matching the filter.",
            url = recordsBase(),
        )
    }

    /** `POST /records`. Auto-switches to multipart when [body] contains a [FileArg]. */
    suspend fun create(
        body: Map<String, Any?>,
        expand: String? = null,
        fields: String? = null,
    ): ZbRecord {
        val query = buildListParams(expand = expand, fields = fields)
        val res = transport.request(RequestSpec(HttpMethod.Post, recordsBase(), query = query, body = body))
        return ZbRecord(ensureObjectBody(res, "create"))
    }

    /** `PATCH /records/:id`. Auto-switches to multipart when [body] contains a [FileArg]. */
    suspend fun update(
        id: String,
        body: Map<String, Any?>,
        expand: String? = null,
        fields: String? = null,
    ): ZbRecord {
        val query = buildListParams(expand = expand, fields = fields)
        val res = transport.request(RequestSpec(HttpMethod.Patch, recordPath(id), query = query, body = body))
        return ZbRecord(ensureObjectBody(res, "update"))
    }

    /** `DELETE /records/:id`. */
    suspend fun delete(id: String) {
        transport.request(RequestSpec(HttpMethod.Delete, recordPath(id)))
    }

    /**
     * `GET /records/:id/abilities` -- the actions the current principal may
     * perform on this record (requires ZigBase >= 0.9.0).
     */
    suspend fun getAbilities(id: String): Abilities {
        val body = transport.request(RequestSpec(HttpMethod.Get, "${recordPath(id)}/abilities"))
        val envelope = ensureObjectBody(body, "getAbilities")
        return Abilities(
            view = booleanField(envelope, "view"),
            update = booleanField(envelope, "update"),
            delete = booleanField(envelope, "delete"),
        )
    }

    /**
     * Native server-side cursor (keyset) pagination. The server mints the
     * opaque `nextCursor`/`prevCursor` tokens; this forwards whatever it
     * received and never decodes or synthesizes one. An absent OR empty
     * [cursor] requests the FIRST cursor page (both are omitted from the
     * request entirely), matching every sibling SDK's `getPage` wrapper. By
     * default the server skips the total count; pass [withTotal] to include
     * [CursorPage.totalItems].
     */
    suspend fun getPage(
        cursor: String? = null,
        limit: Int? = null,
        withTotal: Boolean = false,
        filter: String? = null,
        sort: String? = null,
        expand: String? = null,
        fields: String? = null,
        search: String? = null,
    ): CursorPage {
        val query =
            buildListParams(
                filter = filter,
                sort = sort,
                expand = expand,
                fields = fields,
                search = search,
                // A non-empty cursor requests that page; an absent OR empty
                // cursor means "first page" and is omitted entirely -- matching
                // every sibling SDK's own getPage wrapper (Python collection.py
                // `cursor if cursor else None`, TS collection.ts, Dart
                // collection.dart), which all normalize "" -> omitted here even
                // though the underlying buildListParams primitive would emit an
                // explicitly-passed "" verbatim.
                cursor = cursor?.takeIf { it.isNotEmpty() },
                limit = limit ?: 30,
                skipTotal = if (withTotal) false else null,
            )
        val body = transport.request(RequestSpec(HttpMethod.Get, recordsBase(), query = query))
        return parseCursorPage(body, "getPage")
    }

    /**
     * Iterates every matching record, following the server's `nextCursor`.
     *
     * Raises a status-0 [ZigbaseException] if the server returns a
     * non-advancing cursor page (an empty page that still claims `hasNext`,
     * or a `nextCursor` identical to the one just used) -- a guard against a
     * misbehaving server spinning this forever.
     */
    fun iterate(
        batch: Int = 100,
        filter: String? = null,
        sort: String? = null,
        expand: String? = null,
        fields: String? = null,
        search: String? = null,
    ): Flow<ZbRecord> =
        flow {
            var usedCursor: String? = null
            var page =
                getPage(limit = batch, filter = filter, sort = sort, expand = expand, fields = fields, search = search)
            while (true) {
                for (item in page.items) emit(item)
                if (!page.hasNext || page.nextCursor.isNullOrEmpty()) return@flow
                if (page.items.isEmpty() || page.nextCursor == usedCursor) {
                    throw ZigbaseException(
                        status = 0,
                        message =
                            "iterate(): the server returned a non-advancing cursor page " +
                                "(empty page or a repeated cursor); aborting to avoid an infinite loop.",
                        url = recordsBase(),
                    )
                }
                usedCursor = page.nextCursor
                page =
                    getPage(
                        cursor = usedCursor,
                        limit = batch,
                        filter = filter,
                        sort = sort,
                        expand = expand,
                        fields = fields,
                        search = search,
                    )
            }
        }

    /** Accumulates every matching record into a list via [iterate]'s native cursor engine. */
    suspend fun getFullList(
        batch: Int = 100,
        filter: String? = null,
        sort: String? = null,
        expand: String? = null,
        fields: String? = null,
        search: String? = null,
    ): List<ZbRecord> {
        val out = mutableListOf<ZbRecord>()
        iterate(batch, filter, sort, expand, fields, search).collect { out.add(it) }
        return out
    }
}

private fun intField(
    obj: JsonObject,
    key: String,
): Int = (obj[key] as? JsonPrimitive)?.intOrNull ?: 0

/**
 * Parses a `{token, record?, meta?}` auth envelope. `token` is mandatory --
 * a missing/non-string `token` raises rather than silently defaulting to
 * `""`, matching TS/Python/Dart's throw-on-malformed-response behavior.
 * `record`/`meta` fall back to `null` when absent or not shaped as an
 * object -- those two stay optional.
 */
private fun parseAuthResponse(
    body: JsonElement?,
    context: String,
): AuthResponse {
    val envelope = ensureObjectBody(body, context)
    val rawRecord = envelope["record"] as? JsonObject
    val rawMeta = envelope["meta"] as? JsonObject
    return AuthResponse(
        token = requireStringField(envelope, "token", context),
        record = rawRecord?.let(::ZbRecord),
        meta = rawMeta,
    )
}

/**
 * Whether [CollectionService.changePassword] should re-authenticate: the
 * auth store's [principal] must BE the record whose password was just
 * changed ([targetId]). Returns the identity (`email`, falling back to
 * `username`) to re-auth with, or `null` if no re-auth is needed.
 */
private fun changePasswordReauthIdentity(
    principal: JsonObject?,
    targetId: String,
): String? {
    if (principal == null || stringOrNullField(principal, "id") != targetId) return null
    return stringOrNullField(principal, "email") ?: stringOrNullField(principal, "username")
}

private fun parseListResult(
    body: JsonElement?,
    context: String,
): ListResult {
    val envelope = ensureObjectBody(body, context)
    return ListResult(
        page = intField(envelope, "page"),
        perPage = intField(envelope, "perPage"),
        totalItems = intField(envelope, "totalItems"),
        totalPages = intField(envelope, "totalPages"),
        items = recordItemsField(envelope),
    )
}
