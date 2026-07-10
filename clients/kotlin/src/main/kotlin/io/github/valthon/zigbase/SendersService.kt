package io.github.valthon.zigbase

import io.github.valthon.zigbase.internal.RequestSpec
import io.github.valthon.zigbase.internal.Transport
import io.github.valthon.zigbase.internal.booleanField
import io.github.valthon.zigbase.internal.encodePathSegment
import io.github.valthon.zigbase.internal.ensureObjectBody
import io.github.valthon.zigbase.internal.unwrapJsonObjectItems
import io.ktor.http.HttpMethod
import kotlinx.serialization.json.JsonObject

/*
 * Verified sender-identity management. `list` requires ZigBase >= 0.10.0
 * (the `{items}` envelope); `create`/`verify` exist as of 0.9.0. All three
 * verbs are account-scoped exactly like the record API (`withAccount` /
 * the `zb_account` cookie / superuser header).
 *
 * Port of `SendersService`/`AsyncSendersService` in
 * `clients/python/src/zigbase/senders.py`, cross-checked against
 * `clients/typescript/src/senders.ts` and `clients/dart/lib/src/senders.dart`
 * and src/api/senders.zig.
 */

/**
 * Verified sender-identity management, over a [Transport].
 *
 * Constructed internally -- obtain one from the top-level client rather than
 * calling this constructor directly.
 */
class SendersService internal constructor(
    private val transport: Transport,
) {
    /**
     * `GET /api/senders` -- the active account's sender identities.
     * Unwraps `{items}`. Requires ZigBase >= 0.10.0.
     */
    suspend fun list(): List<JsonObject> {
        val body = transport.request(RequestSpec(HttpMethod.Get, "/api/senders"))
        return unwrapJsonObjectItems(body, "list")
    }

    /**
     * `POST /api/senders` -- request verification of a From address. The
     * token is EMAILED to that address, never returned. 201 pending / 200
     * already-verified; throws a 429
     * [io.github.valthon.zigbase.errors.ZigbaseException] when a re-send
     * is throttled.
     */
    suspend fun create(email: String): JsonObject {
        val body = transport.request(RequestSpec(HttpMethod.Post, "/api/senders", body = mapOf("email" to email)))
        return ensureObjectBody(body, "create")
    }

    /**
     * `POST /api/senders/:id/verify` -- confirms a pending identity.
     * Returns the `verified` flag from the `{verified: bool}` response
     * (200, not 204 -- src/api/senders.zig always answers with a body).
     * 404 for a wrong token/account/id (deliberate non-oracle).
     */
    suspend fun verify(
        senderId: String,
        token: String,
    ): Boolean {
        val body =
            transport.request(
                RequestSpec(
                    HttpMethod.Post,
                    "/api/senders/${encodePathSegment(senderId)}/verify",
                    body = mapOf("token" to token),
                ),
            )
        return booleanField(ensureObjectBody(body, "verify"), "verified")
    }
}
