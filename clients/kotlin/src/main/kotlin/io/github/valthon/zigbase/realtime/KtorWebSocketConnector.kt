package io.github.valthon.zigbase.realtime

import io.ktor.client.HttpClient
import io.ktor.client.engine.cio.CIO
import io.ktor.client.plugins.websocket.DefaultClientWebSocketSession
import io.ktor.client.plugins.websocket.WebSockets
import io.ktor.client.plugins.websocket.webSocketSession
import io.ktor.websocket.Frame
import io.ktor.websocket.close
import io.ktor.websocket.readText
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.channels.ReceiveChannel
import kotlinx.coroutines.launch

/*
 * The production [RealtimeConnection] connector: a ktor CIO `HttpClient`
 * with the `WebSockets` plugin installed, wrapping a
 * `DefaultClientWebSocketSession` into a [RealtimeConnection].
 *
 * The `HttpClient` this class builds is a resource
 * [io.github.valthon.zigbase.ZigbaseClient] owns: it's created lazily on
 * first [io.github.valthon.zigbase.ZigbaseClient.realtime] access (when no
 * test connector is injected) and closed by
 * [io.github.valthon.zigbase.ZigbaseClient.close] via [close] below -- see
 * that class for the ownership wiring. An injected fake connector (tests)
 * never touches this class at all.
 */

/**
 * Builds and owns the `HttpClient` backing the default ktor-CIO WebSocket
 * connector.
 *
 * [connect] is the `suspend (String) -> RealtimeConnection` [RealtimeService]
 * expects; [close] tears down the underlying `HttpClient` (and, with it,
 * every WebSocket session it ever opened) -- the actual mechanism that
 * severs the live connection for the default connector, since
 * [RealtimeService.shutdown] (unlike its suspend [RealtimeService.close])
 * never itself calls the (suspend) `RealtimeConnection.close`.
 */
internal class KtorWebSocketConnector(
    private val client: HttpClient = HttpClient(CIO) { install(WebSockets) },
) {
    val connect: suspend (String) -> RealtimeConnection = { url ->
        KtorRealtimeConnection(client.webSocketSession(url))
    }

    fun close() {
        client.close()
    }
}

/**
 * Adapts a `DefaultClientWebSocketSession` to [RealtimeConnection]: a pump
 * coroutine (launched on the session's own [kotlinx.coroutines.CoroutineScope])
 * reads [Frame]s off `session.incoming`, forwards `Frame.Text` payloads into
 * [incoming], drops any other frame type (ktor's `WebSockets` plugin answers
 * ping/pong itself), and closes [incoming] the moment `session.incoming`
 * closes for any reason -- a clean peer close, an abnormal drop, or this
 * side calling [close] -- matching [RealtimeConnection.incoming]'s
 * documented close-on-death contract.
 */
private class KtorRealtimeConnection(
    private val session: DefaultClientWebSocketSession,
) : RealtimeConnection {
    private val channel = Channel<String>(Channel.UNLIMITED)

    init {
        session.launch {
            try {
                for (frame in session.incoming) {
                    if (frame is Frame.Text) channel.send(frame.readText())
                }
            } finally {
                channel.close()
            }
        }
    }

    override suspend fun send(text: String) {
        session.send(Frame.Text(text))
    }

    override val incoming: ReceiveChannel<String> get() = channel

    override suspend fun close() {
        session.close()
    }
}
