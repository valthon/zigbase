"""Error model for the ZigBase API.

Port of clients/typescript/src/errors.ts, with the malformed-field-error
hardening from clients/dart/lib/src/errors.dart: a `data` entry that isn't a
`{code, message}` object of strings is skipped rather than defaulted, so
callers can't mistake "absent/malformed" for a real (if unusually empty)
field error.
"""

from __future__ import annotations

import json
from dataclasses import dataclass


@dataclass(frozen=True)
class FieldError:
    """A single field-level validation error from an API error response."""

    code: str
    message: str


class ZigbaseError(Exception):
    """Raised when the ZigBase API responds with a non-2xx status.

    ``status`` is the HTTP status; ``0`` denotes a client-side protocol
    violation (e.g. a non-advancing realtime/pagination cursor) rather than
    a response from the server.
    """

    status: int
    message: str
    data: dict[str, FieldError]
    url: str

    def __init__(
        self,
        *,
        status: int,
        message: str,
        data: dict[str, FieldError] | None = None,
        url: str,
    ) -> None:
        super().__init__(message)
        self.status = status
        self.message = message
        self.data = data if data is not None else {}
        self.url = url

    def __str__(self) -> str:
        return f"ZigbaseError({self.status}): {self.message} ({self.url})"


def parse_error_response(
    status: int,
    body_text: str,
    url: str,
    reason_phrase: str | None = None,
) -> ZigbaseError:
    """Build a `ZigbaseError` from a response body, which may not be JSON.

    Parses a `{message?, data?}` shaped JSON body, where `data` maps field
    names to `{code, message}` objects. When the body is not valid JSON (or
    not a JSON object), falls back to `reason_phrase`, then to a generic
    "Request failed with status {status}" message.
    """
    message = reason_phrase if reason_phrase else f"Request failed with status {status}"
    data: dict[str, FieldError] = {}

    try:
        decoded = json.loads(body_text)
        if isinstance(decoded, dict):
            raw_message = decoded.get("message")
            if isinstance(raw_message, str):
                message = raw_message

            raw_data = decoded.get("data")
            if isinstance(raw_data, dict):
                entries: dict[str, FieldError] = {}
                for key, value in raw_data.items():
                    if not isinstance(value, dict):
                        continue
                    raw_code = value.get("code")
                    raw_field_message = value.get("message")
                    if not isinstance(raw_code, str) or not isinstance(raw_field_message, str):
                        continue
                    entries[str(key)] = FieldError(code=raw_code, message=raw_field_message)
                data = entries
    except (json.JSONDecodeError, TypeError, ValueError):
        pass

    return ZigbaseError(status=status, message=message, data=data, url=url)


__all__ = ["FieldError", "ZigbaseError", "parse_error_response"]
