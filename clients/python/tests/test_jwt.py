"""Tests for zigbase._jwt, a port of clients/typescript/src/jwt.ts."""

import base64
import json
import time

from zigbase._jwt import decode_jwt_payload, is_token_expired


def _make_jwt(payload: dict[str, object]) -> str:
    header = base64.urlsafe_b64encode(json.dumps({"alg": "HS256", "typ": "JWT"}).encode()).rstrip(
        b"="
    )
    body = base64.urlsafe_b64encode(json.dumps(payload).encode()).rstrip(b"=")
    return f"{header.decode()}.{body.decode()}.sig"


class TestDecodeJwtPayload:
    def test_round_trips_a_hand_built_token(self) -> None:
        segment = base64.urlsafe_b64encode(
            json.dumps({"id": "u1", "exp": 9999999999}).encode()
        ).rstrip(b"=")
        token = f"header.{segment.decode()}.sig"
        payload = decode_jwt_payload(token)
        assert payload is not None
        assert payload["id"] == "u1"
        assert payload["exp"] == 9999999999

    def test_decodes_the_payload_segment(self) -> None:
        token = _make_jwt({"id": "u1", "collection": "users", "exp": 9999999999})
        payload = decode_jwt_payload(token)
        assert payload is not None
        assert payload["id"] == "u1"
        assert payload["collection"] == "users"

    def test_returns_none_for_malformed_tokens(self) -> None:
        assert decode_jwt_payload("not-a-jwt") is None
        assert decode_jwt_payload("") is None
        assert decode_jwt_payload("a.b") is None
        assert decode_jwt_payload("a..c") is None
        assert decode_jwt_payload("a.!!!notbase64.c") is None

    def test_returns_none_when_payload_is_not_a_json_object(self) -> None:
        segment = base64.urlsafe_b64encode(json.dumps([1, 2, 3]).encode()).rstrip(b"=")
        token = f"header.{segment.decode()}.sig"
        assert decode_jwt_payload(token) is None


class TestIsTokenExpired:
    def test_false_for_far_future_exp(self) -> None:
        now = int(time.time())
        assert is_token_expired(_make_jwt({"exp": now + 3600})) is False

    def test_true_for_past_exp(self) -> None:
        now = int(time.time())
        assert is_token_expired(_make_jwt({"exp": now - 10})) is True

    def test_true_for_missing_exp(self) -> None:
        assert is_token_expired(_make_jwt({"id": "u1"})) is True

    def test_true_for_malformed_token(self) -> None:
        assert is_token_expired("garbage") is True

    def test_leeway_pushes_a_near_future_exp_into_expired(self) -> None:
        now = int(time.time())
        assert is_token_expired(_make_jwt({"exp": now + 5}), leeway_seconds=30) is True
        assert is_token_expired(_make_jwt({"exp": now + 5})) is False
