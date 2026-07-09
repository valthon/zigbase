"""PKCE (RFC 7636) verifier/challenge helpers for the OAuth2 authorization-code flow.

Port of clients/typescript/src/pkce.ts / clients/dart/lib/src/pkce.dart.
`secrets` (rather than `random`) supplies the randomness -- the verifier is a
credential, not a display token.
"""

from __future__ import annotations

import base64
import hashlib
import secrets

_UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"


def generate_code_verifier(length: int = 64) -> str:
    """A random PKCE verifier drawn from the RFC 7636 unreserved charset
    (`[A-Za-z0-9-._~]`). The default `64` sits inside RFC 7636's required
    43-128 character range; also reusable at other lengths (e.g. an OAuth2
    `state` value)."""
    return "".join(secrets.choice(_UNRESERVED) for _ in range(length))


def code_challenge_s256(verifier: str) -> str:
    """The S256 PKCE challenge for `verifier`: the base64url encoding
    (unpadded) of `sha256(ascii(verifier))`."""
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    return base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")


__all__ = ["code_challenge_s256", "generate_code_verifier"]
