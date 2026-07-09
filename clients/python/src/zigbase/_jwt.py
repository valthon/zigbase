"""JWT payload decoding, without signature verification.

Port of clients/typescript/src/jwt.ts. The client never verifies a token's
signature (only the server can, holding the secret); these helpers only read
claims to drive client-side behavior like pre-emptive refresh.
"""

from __future__ import annotations

import base64
import json
import time
from typing import Any


def decode_jwt_payload(token: str) -> dict[str, Any] | None:
    """Decode the payload segment of a JWT, or `None` for malformed input.

    Returns `None` for anything that isn't a string with exactly three
    dot-separated segments, an empty payload segment, invalid base64url, or
    a payload that doesn't decode to a JSON object.
    """
    parts = token.split(".")
    if len(parts) != 3 or not parts[1]:
        return None

    try:
        segment = parts[1]
        padded = segment + "=" * (-len(segment) % 4)
        decoded_bytes = base64.urlsafe_b64decode(padded)
        payload = json.loads(decoded_bytes.decode("utf-8"))
    except Exception:
        return None

    return payload if isinstance(payload, dict) else None


def is_token_expired(token: str, leeway_seconds: int = 0) -> bool:
    """Return `True` when `token` is expired (or has no readable `exp` claim).

    `leeway_seconds` is subtracted from `exp` before comparing to the
    current time, so a token can be treated as expired slightly before its
    real expiry (e.g. to account for clock skew or in-flight request
    latency).
    """
    payload = decode_jwt_payload(token)
    exp = payload.get("exp") if payload is not None else None
    if not isinstance(exp, (int, float)) or isinstance(exp, bool):
        return True

    now = int(time.time())
    return exp - leeway_seconds <= now


__all__ = ["decode_jwt_payload", "is_token_expired"]
