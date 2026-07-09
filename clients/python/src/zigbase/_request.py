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


__all__ = ["RequestSpec", "encode_path_segment"]
