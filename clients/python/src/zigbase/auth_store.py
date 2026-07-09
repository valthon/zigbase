"""Auth token/record storage with change notification.

Port of clients/typescript/src/auth-store.ts: `BaseAuthStore` and
`MemoryAuthStore` map directly. TS's browser-only `LocalAuthStore` /
`CookieAuthStore` have no Python analogue and are not ported; `FileAuthStore`
is the Python-specific persistence story for CLI/script use instead.

`FileAuthStore` writes are atomic (write-to-temp + `os.replace`) and the file
is created `0600` (owner read/write only) -- it holds a live auth token.
"""

from __future__ import annotations

import contextlib
import json
import os
from abc import ABC
from collections.abc import Callable
from pathlib import Path
from typing import Any

from zigbase._jwt import is_token_expired

AuthChangeCallback = Callable[[str | None, dict[str, Any] | None], None]


class AuthStore(ABC):  # noqa: B024 -- deliberately no abstractmethod; all plumbing lives here
    """Holds the current auth token/record and notifies listeners of changes.

    Not meant to be used directly -- construct a `MemoryAuthStore` or
    `FileAuthStore`. Kept as an `ABC` (rather than a concrete class) so it
    reads as the shared contract it is in the TS/Dart SDKs, even though every
    method is already implemented here.
    """

    def __init__(self) -> None:
        self._token: str | None = None
        self._record: dict[str, Any] | None = None
        self._listeners: list[AuthChangeCallback] = []

    @property
    def token(self) -> str | None:
        return self._token

    @property
    def record(self) -> dict[str, Any] | None:
        return self._record

    @property
    def is_valid(self) -> bool:
        """Whether a token is present and not (client-side) expired.

        This is a client-side UX signal only (e.g. to decide whether to skip
        an auth-refresh call) -- the server is always the source of truth.
        """
        return self._token is not None and not is_token_expired(self._token)

    def save(self, token: str | None, record: dict[str, Any] | None) -> None:
        self._token = token
        self._record = record
        self._emit()

    def clear(self) -> None:
        self._token = None
        self._record = None
        self._emit()

    def on_change(self, cb: AuthChangeCallback) -> Callable[[], None]:
        """Register `cb` to be called on every `save`/`clear`. Returns an unsubscribe function."""
        self._listeners.append(cb)

        def unsubscribe() -> None:
            if cb in self._listeners:
                self._listeners.remove(cb)

        return unsubscribe

    def _emit(self) -> None:
        for cb in list(self._listeners):
            # a raising listener must not stop the rest from running
            with contextlib.suppress(Exception):
                cb(self._token, self._record)


class MemoryAuthStore(AuthStore):
    """In-process, non-persistent auth store. The default."""


class FileAuthStore(AuthStore):
    """JSON-file-backed auth store, for CLI/script use across process runs.

    Loads eagerly on construction. Per repo philosophy, an unreadable file
    (missing, unparsable, wrong shape) is treated as nonexistent: the store
    simply starts empty rather than raising.
    """

    def __init__(self, path: str | os.PathLike[str]) -> None:
        super().__init__()
        self._path = Path(path)
        self._load()

    def _load(self) -> None:
        try:
            raw = self._path.read_text(encoding="utf-8")
            parsed = json.loads(raw)
        except (OSError, ValueError):
            # OSError: missing/unreadable file. ValueError covers both
            # UnicodeDecodeError (non-UTF-8 bytes, e.g. a crash-truncated
            # write) and json.JSONDecodeError -- both are ValueError
            # subclasses. Any of these = start empty, per repo philosophy.
            return

        if not isinstance(parsed, dict):
            return

        token = parsed.get("token")
        record = parsed.get("record")
        self._token = token if isinstance(token, str) else None
        self._record = record if isinstance(record, dict) else None

    def _write(self, token: str | None, record: dict[str, Any] | None) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps({"token": token, "record": record})
        tmp_path = self._path.with_name(f"{self._path.name}.tmp.{os.getpid()}")
        try:
            self._write_new_file(tmp_path, payload)
        except FileExistsError:
            # A stale temp file from a prior crashed run of this same pid
            # (e.g. a reused pid across reboots) -- clear it and retry once.
            tmp_path.unlink()
            self._write_new_file(tmp_path, payload)
        try:
            os.replace(tmp_path, self._path)
        finally:
            # os.replace only leaves tmp_path behind if it raised.
            if tmp_path.exists():
                tmp_path.unlink()

    @staticmethod
    def _write_new_file(tmp_path: Path, payload: str) -> None:
        fd = os.open(tmp_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(payload)
        except BaseException:
            with contextlib.suppress(OSError):
                tmp_path.unlink()
            raise

    def save(self, token: str | None, record: dict[str, Any] | None) -> None:
        self._write(token, record)
        super().save(token, record)

    def clear(self) -> None:
        self._write(None, None)
        super().clear()


__all__ = ["AuthChangeCallback", "AuthStore", "FileAuthStore", "MemoryAuthStore"]
