"""Tests for `zigbase.pkce`.

Mirrors clients/typescript/test/pkce.test.ts and
clients/dart/test/pkce_test.dart.
"""

from __future__ import annotations

import base64
import hashlib

from zigbase.pkce import code_challenge_s256, generate_code_verifier

_UNRESERVED = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")


def test_generate_code_verifier_default_length_and_charset() -> None:
    verifier = generate_code_verifier()
    assert len(verifier) == 64
    assert set(verifier) <= _UNRESERVED


def test_generate_code_verifier_custom_length() -> None:
    verifier = generate_code_verifier(32)
    assert len(verifier) == 32
    assert set(verifier) <= _UNRESERVED


def test_generate_code_verifier_is_random() -> None:
    assert generate_code_verifier() != generate_code_verifier()


def test_code_challenge_s256_vector() -> None:
    verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    expected = (
        base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest())
        .decode("ascii")
        .rstrip("=")
    )
    assert code_challenge_s256(verifier) == expected


def test_code_challenge_s256_is_base64url_no_padding() -> None:
    challenge = code_challenge_s256(generate_code_verifier())
    assert "=" not in challenge
    assert "+" not in challenge
    assert "/" not in challenge


def test_code_challenge_s256_deterministic() -> None:
    verifier = generate_code_verifier()
    assert code_challenge_s256(verifier) == code_challenge_s256(verifier)
