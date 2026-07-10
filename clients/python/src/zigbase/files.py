"""File URL construction + the file-access token endpoint.

Port of clients/typescript/src/files.ts (`FilesService`); cross-checked
against clients/dart/lib/src/files.dart. `get_url`/`get_url_for` are pure
string builders -- no request, matching TS/Dart -- so `FilesService` takes
`base_url` as an explicit constructor argument (mirroring
`FilesService(transport, baseUrl)` in both references) rather than reading
it off the transport, which has no public `base_url` attribute.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any
from urllib.parse import urlencode

from zigbase._request import RequestSpec, encode_path_segment, ensure_object_body, require_str_field
from zigbase._transport import AsyncTransport, SyncTransport


def _file_collection(record: Mapping[str, Any]) -> str:
    """`record`'s collection: `collectionId`, falling back to
    `collectionName`. Raises `ValueError` naming the problem when a record
    has neither (matches `FileRecordRef.collectionId ?? collectionName`
    in files.ts / `getString('collectionId') ?? getString('collectionName')`
    in files.dart)."""
    col = record.get("collectionId") or record.get("collectionName")
    if not col:
        raise ValueError(
            "record has neither collectionId nor collectionName; cannot build a file URL"
        )
    return str(col)


def _build_file_url(
    base_url: str,
    collection: str,
    record_id: str,
    filename: str,
    *,
    download: bool,
    thumb: str | None,
    token: str | None,
) -> str:
    """`{base_url}/api/files/{collection}/{record_id}/{filename}`, each
    path segment individually `encode_path_segment`-ed, plus an optional
    `download=1`/`thumb=<spec>`/`token=<t>` query string in that order --
    byte-for-byte the shape files.ts/files.dart build."""
    base = base_url.rstrip("/")
    path = (
        f"{base}/api/files/{encode_path_segment(collection)}"
        f"/{encode_path_segment(record_id)}/{encode_path_segment(filename)}"
    )
    params: list[tuple[str, str]] = []
    if download:
        params.append(("download", "1"))
    if thumb:
        params.append(("thumb", thumb))
    if token:
        params.append(("token", token))
    if not params:
        return path
    return f"{path}?{urlencode(params)}"


class FilesService:
    """File URL construction + `POST /api/files/token`, over a `SyncTransport`."""

    def __init__(self, transport: SyncTransport, base_url: str) -> None:
        self._transport = transport
        self._base_url = base_url

    def get_url(
        self,
        record: Mapping[str, Any],
        filename: str,
        *,
        download: bool = False,
        thumb: str | None = None,
        token: str | None = None,
    ) -> str:
        """Build a file URL for `record` + `filename`. See `_file_collection`
        for how the collection is derived."""
        return self.get_url_for(
            _file_collection(record),
            str(record["id"]),
            filename,
            download=download,
            thumb=thumb,
            token=token,
        )

    def get_url_for(
        self,
        collection: str,
        record_id: str,
        filename: str,
        *,
        download: bool = False,
        thumb: str | None = None,
        token: str | None = None,
    ) -> str:
        """Build a file URL from an explicit `(collection, record_id, filename)`."""
        return _build_file_url(
            self._base_url,
            collection,
            record_id,
            filename,
            download=download,
            thumb=thumb,
            token=token,
        )

    def get_token(self) -> str:
        """`POST /api/files/token` -- mint a short-lived file-access token
        for embedding protected files (e.g. in an `<img>` tag). Raises when
        the response is missing `token` or it isn't a string, rather than
        silently defaulting to `""`."""
        body = self._transport.request(RequestSpec(method="POST", path="/api/files/token"))
        envelope = ensure_object_body(body, context="get_token")
        return require_str_field(envelope, "token", context="get_token")


class AsyncFilesService:
    """`FilesService`'s `asyncio` mirror, over an `AsyncTransport`. The pure
    URL builders (`get_url`/`get_url_for`) are identical, non-`async`
    methods -- only `get_token` awaits."""

    def __init__(self, transport: AsyncTransport, base_url: str) -> None:
        self._transport = transport
        self._base_url = base_url

    def get_url(
        self,
        record: Mapping[str, Any],
        filename: str,
        *,
        download: bool = False,
        thumb: str | None = None,
        token: str | None = None,
    ) -> str:
        """See `FilesService.get_url`."""
        return self.get_url_for(
            _file_collection(record),
            str(record["id"]),
            filename,
            download=download,
            thumb=thumb,
            token=token,
        )

    def get_url_for(
        self,
        collection: str,
        record_id: str,
        filename: str,
        *,
        download: bool = False,
        thumb: str | None = None,
        token: str | None = None,
    ) -> str:
        """See `FilesService.get_url_for`."""
        return _build_file_url(
            self._base_url,
            collection,
            record_id,
            filename,
            download=download,
            thumb=thumb,
            token=token,
        )

    async def get_token(self) -> str:
        """See `FilesService.get_token`."""
        body = await self._transport.request(RequestSpec(method="POST", path="/api/files/token"))
        envelope = ensure_object_body(body, context="get_token")
        return require_str_field(envelope, "token", context="get_token")


__all__ = ["AsyncFilesService", "FilesService"]
