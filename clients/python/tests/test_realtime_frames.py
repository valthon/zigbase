"""Tests for zigbase.realtime's frame codec and the fake test connector.

Port of the frame-shape assertions in clients/typescript/test/realtime.test.ts
and clients/dart/test/realtime_test.dart, cross-checked against the wire
grammar in src/realtime/protocol.zig.
"""

import asyncio
import json

import pytest

from tests.support.fake_connector import FakeConnectorFactory
from zigbase.realtime import (
    decode_frame,
    encode_auth,
    encode_subscribe,
    encode_unsubscribe,
    realtime_url,
)


class TestEncodeAuth:
    def test_encodes_action_and_token(self) -> None:
        assert json.loads(encode_auth("tok123")) == {"action": "auth", "token": "tok123"}

    def test_empty_token_round_trips(self) -> None:
        # The empty string de-auths the connection server-side -- it must
        # still be sent verbatim, not omitted.
        assert json.loads(encode_auth("")) == {"action": "auth", "token": ""}


class TestEncodeSubscribe:
    def test_without_filter_omits_the_filter_key(self) -> None:
        frame = json.loads(encode_subscribe("posts", None))
        assert frame == {"action": "subscribe", "topic": "posts"}
        assert "filter" not in frame

    def test_with_filter_includes_it(self) -> None:
        frame = json.loads(encode_subscribe("posts", "status='live'"))
        assert frame == {"action": "subscribe", "topic": "posts", "filter": "status='live'"}


class TestEncodeUnsubscribe:
    def test_encodes_action_and_topic(self) -> None:
        assert json.loads(encode_unsubscribe("posts")) == {
            "action": "unsubscribe",
            "topic": "posts",
        }


class TestDecodeFrame:
    def test_decodes_a_json_object(self) -> None:
        assert decode_frame('{"type":"ack","topic":"posts"}') == {
            "type": "ack",
            "topic": "posts",
        }

    def test_decodes_utf8_bytes(self) -> None:
        assert decode_frame(b'{"type":"connect","clientId":"c1"}') == {
            "type": "connect",
            "clientId": "c1",
        }

    def test_drops_malformed_json(self) -> None:
        assert decode_frame("{not json") is None

    def test_drops_a_json_array(self) -> None:
        assert decode_frame("[1, 2, 3]") is None

    def test_drops_a_json_number(self) -> None:
        assert decode_frame("42") is None

    def test_drops_a_json_string(self) -> None:
        assert decode_frame('"hello"') is None

    def test_drops_invalid_utf8_bytes(self) -> None:
        assert decode_frame(b"\xff\xfe not utf8") is None


class TestRealtimeUrl:
    def test_http_maps_to_ws(self) -> None:
        assert realtime_url("http://localhost:8090") == "ws://localhost:8090/api/realtime"

    def test_https_maps_to_wss(self) -> None:
        assert realtime_url("https://example.com") == "wss://example.com/api/realtime"

    def test_strips_all_trailing_slashes(self) -> None:
        assert realtime_url("http://localhost:8090///") == "ws://localhost:8090/api/realtime"

    def test_no_trailing_slash_is_unaffected(self) -> None:
        assert realtime_url("https://api.example.com") == "wss://api.example.com/api/realtime"


class TestFakeConnector:
    async def test_connect_records_the_url_and_the_connection(self) -> None:
        factory = FakeConnectorFactory()
        conn = await factory.connect("ws://x/api/realtime")
        assert factory.connections == [conn]
        assert factory.last is conn

    async def test_send_captures_decoded_frames(self) -> None:
        factory = FakeConnectorFactory()
        conn = await factory.connect("ws://x/api/realtime")
        await conn.send(encode_subscribe("posts", None))
        assert conn.sent == [{"action": "subscribe", "topic": "posts"}]
        assert conn.subscribe_frames == [{"action": "subscribe", "topic": "posts"}]
        assert conn.unsubscribe_frames == []

    async def test_push_is_delivered_via_recv(self) -> None:
        factory = FakeConnectorFactory()
        conn = await factory.connect("ws://x/api/realtime")

        received: list[str | bytes] = []

        async def reader() -> None:
            async for msg in conn.recv():
                received.append(msg)

        task = asyncio.create_task(reader())
        await asyncio.sleep(0)  # let the reader start awaiting
        await conn.push({"type": "connect", "clientId": "c1"})
        await conn.server_close()
        await task

        assert len(received) == 1
        assert json.loads(received[0]) == {"type": "connect", "clientId": "c1"}

    async def test_server_close_ends_recv_iteration(self) -> None:
        factory = FakeConnectorFactory()
        conn = await factory.connect("ws://x/api/realtime")

        async def reader() -> list[str | bytes]:
            return [msg async for msg in conn.recv()]

        task = asyncio.create_task(reader())
        await asyncio.sleep(0)
        await conn.server_close()
        result = await asyncio.wait_for(task, timeout=1)
        assert result == []

    async def test_pending_failures_raise_connection_error_then_succeed(self) -> None:
        factory = FakeConnectorFactory()
        factory.pending_failures = 2

        with pytest.raises(ConnectionError):
            await factory.connect("ws://x/api/realtime")
        with pytest.raises(ConnectionError):
            await factory.connect("ws://x/api/realtime")

        conn = await factory.connect("ws://x/api/realtime")
        assert factory.connections == [conn]

    async def test_gate_parks_connect_until_set(self) -> None:
        factory = FakeConnectorFactory()
        factory.gate = asyncio.Event()

        connected = False

        async def connector() -> None:
            nonlocal connected
            await factory.connect("ws://x/api/realtime")
            connected = True

        task = asyncio.create_task(connector())
        await asyncio.sleep(0)
        assert connected is False

        factory.gate.set()
        await task
        assert connected is True

    def test_last_raises_before_any_connection(self) -> None:
        factory = FakeConnectorFactory()
        with pytest.raises(RuntimeError):
            _ = factory.last
