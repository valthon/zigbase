"""Body encoding: JSON passthrough or multipart auto-detection.

Port of `hasBlob`/`toFormData` in clients/typescript/src/records.ts, plus the
buffer-file-bytes-once-for-retry and loud-rejection-of-non-encodable-values
hardening from clients/dart/lib/src/records.dart (`encodeMultipart`) and
clients/dart/lib/src/transport.dart.

Python has no `undefined`, so the TS "undefined is skipped, null becomes an
empty-string field" rule collapses to one case here: a key absent from
`body` is simply never iterated (the Python equivalent of "skipped"), and an
explicit `None` value becomes `""`. Every `None` a Python caller can produce
therefore maps to what TS calls `null`, never to what TS calls `undefined`.
"""

from __future__ import annotations

import json
import os
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime
from typing import IO, Any

from zigbase.query import format_date

FileArg = IO[bytes] | tuple[str, bytes] | tuple[str, bytes, str]


@dataclass
class EncodedBody:
    """The result of `encode_body`: either a JSON body, or multipart parts.

    Exactly one of (`json_body`) or (`fields`, `files`) is non-`None`. File
    content has already been read into `bytes` at encode time, so `files`
    can be handed to a retrying transport (e.g. rebuilt into a fresh httpx
    `files=` payload) any number of times without re-reading a stream that
    may have already been exhausted or closed.
    """

    json_body: dict[str, Any] | None
    fields: list[tuple[str, str]] | None
    files: list[tuple[str, tuple[str, bytes, str | None]]] | None


def _is_file(value: Any) -> bool:
    if isinstance(value, tuple) and len(value) in (2, 3):
        filename, content = value[0], value[1]
        return isinstance(filename, str) and isinstance(content, (bytes, bytearray))
    return callable(getattr(value, "read", None))


def has_file(body: Mapping[str, Any]) -> bool:
    """True when `body` contains a file value (or a list of them) at the top
    level, meaning the request must be sent as multipart/form-data instead
    of JSON. Mirrors `hasBlob`: only top-level values and top-level lists are
    scanned -- a file nested inside a plain dict value is not detected."""
    for value in body.values():
        if _is_file(value):
            return True
        if isinstance(value, list) and any(_is_file(item) for item in value):
            return True
    return False


def _read_file_arg(value: FileArg) -> tuple[str, bytes, str | None]:
    if isinstance(value, tuple):
        if len(value) == 2:
            filename, content = value
            content_type: str | None = None
        else:
            filename, content, content_type = value
        return filename, bytes(content), content_type

    content = value.read()
    if isinstance(content, str):
        content = content.encode("utf-8")
    name = getattr(value, "name", None)
    filename = os.path.basename(name) if isinstance(name, str) and name else "file"
    return filename, bytes(content), None


def _json_default(obj: Any) -> Any:
    if isinstance(obj, datetime):
        return format_date(obj)
    raise TypeError(f"Object of type {type(obj).__name__} is not JSON-encodable")


def _json_safe_value(value: Any, key: str) -> Any:
    """Convert `value` for the JSON path: `datetime` -> `format_date`
    (recursively, matching what `JSON.stringify` does for a nested TS
    `Date` via `toJSON`), otherwise validate JSON-encodability. Raises
    `TypeError` naming `key` rather than silently producing bad JSON."""
    try:
        encoded = json.dumps(value, default=_json_default, allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise TypeError(f"encode_body: value for key {key!r} is not JSON-encodable") from exc
    result: Any = json.loads(encoded)
    return result


def _json_field(value: Any, key: str) -> str:
    try:
        return json.dumps(value, default=_json_default, allow_nan=False)
    except (TypeError, ValueError) as exc:
        raise TypeError(
            f"encode_body: value nested under key {key!r} is not JSON-encodable"
        ) from exc


def _encode_scalar_field(key: str, value: Any) -> str:
    if isinstance(value, datetime):
        return format_date(value)
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (dict, list)):
        return _json_field(value, key)
    return str(value)


def encode_body(body: Mapping[str, Any]) -> EncodedBody:
    """Encode `body` as JSON, or as multipart parts if it contains a file.

    JSON path: every value is passed through `_json_safe_value` (which also
    formats nested `datetime`s), so the result is guaranteed
    `json.dumps`-safe; a non-JSON-encodable value raises `TypeError` naming
    its top-level key rather than being silently dropped.

    Multipart path (byte parity with TS `toFormData`): `None` -> `""`;
    `datetime` -> `format_date`; nested `dict`/nested `list` -> `json.dumps`;
    a top-level `list` is iterated element-wise, one form part per element
    with the key repeated (files as files, `None` elements dropped, other
    elements encoded by the same rules as a scalar field); other scalars ->
    `str()`, with `bool` rendered as lowercase `true`/`false`.
    """
    if not has_file(body):
        json_body = {key: _json_safe_value(value, key) for key, value in body.items()}
        return EncodedBody(json_body=json_body, fields=None, files=None)

    fields: list[tuple[str, str]] = []
    files: list[tuple[str, tuple[str, bytes, str | None]]] = []

    for key, value in body.items():
        if _is_file(value):
            files.append((key, _read_file_arg(value)))
        elif value is None:
            fields.append((key, ""))
        elif isinstance(value, list):
            for item in value:
                if _is_file(item):
                    files.append((key, _read_file_arg(item)))
                elif item is None:
                    continue
                else:
                    fields.append((key, _encode_scalar_field(key, item)))
        else:
            fields.append((key, _encode_scalar_field(key, value)))

    return EncodedBody(json_body=None, fields=fields, files=files)


__all__ = ["EncodedBody", "FileArg", "encode_body", "has_file"]
