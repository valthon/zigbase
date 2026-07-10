package io.github.valthon.zigbase

import io.github.valthon.zigbase.internal.RequestSpec
import io.github.valthon.zigbase.internal.Transport
import io.github.valthon.zigbase.internal.encodePathSegment
import io.github.valthon.zigbase.internal.ensureObjectBody
import io.ktor.http.HttpMethod
import kotlinx.serialization.json.JsonObject

/*
 * Multi-tenancy account activation (requires ZigBase >= 0.9.0 with
 * `.tenancy` enabled).
 *
 * Port of `AccountsService`/`AsyncAccountsService` in
 * `clients/python/src/zigbase/accounts.py`, cross-checked against
 * `clients/typescript/src/accounts.ts` and `clients/dart/lib/src/accounts.dart`.
 * The `{account, role}` envelope is confirmed against src/api/accounts.zig.
 */

/**
 * `POST /api/accounts/:id/activate`, over a [Transport].
 *
 * Constructed internally -- obtain one from the top-level client rather than
 * calling this constructor directly.
 */
class AccountsService internal constructor(
    private val transport: Transport,
) {
    /**
     * Verifies an ACTIVE membership, sets the signed `zb_account` cookie
     * (same-origin browser apps), and returns `{account, role}`. 403 when
     * not a member; 404 when tenancy is disabled. API/SSR clients should
     * prefer a dedicated `X-Account-Id`-scoped client -- the SDK never
     * reads the cookie itself.
     */
    suspend fun activate(accountId: String): JsonObject {
        val body =
            transport.request(
                RequestSpec(HttpMethod.Post, "/api/accounts/${encodePathSegment(accountId)}/activate"),
            )
        return ensureObjectBody(body, "activate")
    }
}
