package io.github.valthon.zigbase.realtime

import kotlinx.coroutines.channels.ReceiveChannel

/**
 * The transport contract a connector hands back per connection attempt.
 *
 * Port of `RealtimeConnection` (a `Protocol`) in
 * `clients/python/src/zigbase/realtime.py`. [incoming] mirrors the shape of
 * a ktor `DefaultClientWebSocketSession.incoming` channel: a
 * `ReceiveChannel<String>` of downlink frame payloads that CLOSES when the
 * underlying connection dies -- a clean peer close or an unexpected drop
 * alike -- so a consumer's `for (frame in incoming)` loop (or a bare
 * `receive()`) ends with [kotlinx.coroutines.channels.ClosedReceiveChannelException]
 * rather than needing a separate "connection closed" signal. [send] writes
 * one uplink frame; [close] tears the connection down from this side.
 */
internal interface RealtimeConnection {
    suspend fun send(text: String)

    val incoming: ReceiveChannel<String>

    suspend fun close()
}
