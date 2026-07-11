package io.github.valthon.zigbase.realtime

import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/*
 * Realtime (WebSocket) uplink/downlink frame codec.
 *
 * Port of the codec section of `clients/python/src/zigbase/realtime.py`
 * (`encode_auth`/`encode_subscribe`/`encode_unsubscribe`/`decode_frame`/
 * `realtime_url`) -- frame shapes are byte-identical across every ZigBase
 * SDK client. The wire protocol itself is authoritative in `src/realtime/`
 * on the server:
 *
 *  - Uplink: `{"action":"auth","token":...}`,
 *    `{"action":"subscribe","topic":...,"filter"?:...}` (the `filter` key is
 *    omitted -- never sent as JSON `null` -- when no filter is given),
 *    `{"action":"unsubscribe","topic":...}`.
 *  - Downlink, dispatched on `type`: `connect`, `auth`, `ack`, `event`,
 *    `signal`/`message`, `error`. Dispatch/validation of the decoded shape
 *    happens in the service that consumes [decodeFrame], not here.
 */

/** Encodes an `auth` uplink frame. The empty string de-auths the connection. */
internal fun encodeAuth(token: String): String =
    buildJsonObject {
        put("action", "auth")
        put("token", token)
    }.toString()

/**
 * Encodes a `subscribe` uplink frame.
 *
 * The `filter` key is omitted entirely when [filter] is `null` -- it is
 * never sent as a JSON `null`.
 */
internal fun encodeSubscribe(
    topic: String,
    filter: String?,
): String =
    buildJsonObject {
        put("action", "subscribe")
        put("topic", topic)
        if (filter != null) put("filter", filter)
    }.toString()

/** Encodes an `unsubscribe` uplink frame. */
internal fun encodeUnsubscribe(topic: String): String =
    buildJsonObject {
        put("action", "unsubscribe")
        put("topic", topic)
    }.toString()

/**
 * Decodes one downlink frame.
 *
 * Returns the parsed object for any JSON *object*; returns `null` (drop)
 * for malformed JSON and any JSON value that isn't an object (array,
 * number, string, bool, null).
 */
internal fun decodeFrame(text: String): JsonObject? {
    val parsed =
        try {
            Json.parseToJsonElement(text)
        } catch (e: SerializationException) {
            return null
        }
    return parsed as? JsonObject
}

/**
 * Maps an http(s) base URL to its `ws(s)://.../api/realtime` endpoint.
 *
 * `http` -> `ws`, `https` -> `wss` (a single `http` -> `ws` prefix swap
 * handles both, since `https` already carries the trailing `s`); all
 * trailing slashes are stripped before appending the path.
 */
internal fun realtimeUrl(baseUrl: String): String {
    var url = baseUrl
    if (url.startsWith("http")) {
        url = "ws" + url.substring(4)
    }
    url = url.trimEnd('/')
    return "$url/api/realtime"
}
