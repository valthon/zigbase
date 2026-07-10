"""Pure request description used by the sync/async transports.

Port of the `RequestOptions` shape in clients/typescript/src/transport.ts.
Nothing here performs I/O -- `RequestSpec` is just data, and
`encode_path_segment` is a pure string transform. `_transport.py` is the
module that actually sends a `RequestSpec` over the wire.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote

from zigbase.errors import ZigbaseError


@dataclass
class RequestSpec:
    """One logical HTTP request, before header/auth/body assembly.

    `path` is the request path (e.g. `/api/collections/posts/records`) with
    any dynamic segments already percent-encoded via `encode_path_segment` --
    the transport concatenates it onto the base URL verbatim. `body`, when
    present, is encoded by `zigbase._multipart.encode_body` (JSON, or
    multipart if it contains a file). `is_refresh` marks the transport's own
    `auth-refresh` call so a 401 on it propagates instead of recursing into
    the single-flight refresh path.
    """

    method: str
    path: str
    query: dict[str, str] | None = None
    body: Mapping[str, Any] | None = None
    skip_auth: bool = False
    is_refresh: bool = False
    headers: dict[str, str] | None = None
    timeout: float | None = None


def encode_path_segment(s: str) -> str:
    """Percent-encode a single path segment, escaping `/` like every other
    reserved character (`safe=""`) since a caller-supplied id/name must never
    be interpreted as introducing a new path segment."""
    return quote(s, safe="")


def ensure_object_body(body: Any, *, context: str) -> dict[str, Any]:
    """Guard the boundary between `_decode_response`'s `Any` and every
    service helper that expects a JSON object envelope.

    `_decode_response` returns `None` for a 204/empty body on ANY 2xx
    response -- the transport has no way to know a given endpoint's
    contract promises an object. Without this guard, service helpers used
    to `typing.cast(dict, body)` that `None` (or any other non-dict) and
    then crash with a bare `AttributeError` on the first `.get(...)`. We'd
    rather fail loudly with a clear `ZigbaseError` than let a malformed 2xx
    masquerade as a value -- matching the SDK's reject-don't-coerce
    posture (e.g. the non-advancing-cursor guard in collection.py)."""
    if not isinstance(body, dict):
        raise ZigbaseError(
            status=0,
            message=f"Expected a JSON object response ({context}).",
            url="",
        )
    return body


def require_str_field(envelope: Mapping[str, Any], key: str, *, context: str) -> str:
    """Extract a mandatory string field (e.g. `token`) from a parsed JSON
    envelope, raising a clear `ZigbaseError` when it is missing or not a
    `str` -- matching the TS/Dart SDKs, which throw on a malformed response
    rather than silently defaulting a mandatory field to `""`. An empty
    string IS a valid value (some flows legitimately return one) -- only
    absence or a wrong type raises."""
    value = envelope.get(key)
    if not isinstance(value, str):
        raise ZigbaseError(
            status=0,
            message=f"Expected a string '{key}' in response ({context}).",
            url="",
        )
    return value


__all__ = ["RequestSpec", "encode_path_segment", "ensure_object_body", "require_str_field"]
