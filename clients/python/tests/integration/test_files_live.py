"""Live-server file upload/URL coverage.

Multipart create (auto-detected from a `(filename, bytes)` file value) round
-tripped through `files.get_url_for` and a plain HTTP GET. Mirrors
`clients/dart/test/integration/integration_test.dart`'s
"file upload (MultipartFile) + fetch bytes via files.getUrl" test.
"""

from __future__ import annotations

import httpx
import pytest

from zigbase import AsyncZigBase, ZigBase

pytestmark = pytest.mark.integration


def test_multipart_file_upload_and_fetch_url(client: ZigBase) -> None:
    posts = client.collection("posts")
    created = posts.create({"title": "With cover", "cover": ("cover.txt", b"hello-file")})
    cover_name = created["cover"]
    assert cover_name

    url = client.files.get_url_for("posts", created["id"], cover_name)
    # @public collection: no auth needed to fetch the file.
    resp = httpx.get(url, timeout=5.0)
    assert resp.status_code == 200
    assert resp.content == b"hello-file"


async def test_multipart_file_upload_and_fetch_url_async(async_client: AsyncZigBase) -> None:
    posts = async_client.collection("posts")
    created = await posts.create(
        {"title": "With cover async", "cover": ("cover.txt", b"hello-file-async")}
    )
    cover_name = created["cover"]
    assert cover_name

    url = async_client.files.get_url_for("posts", created["id"], cover_name)
    async with httpx.AsyncClient() as http:
        resp = await http.get(url, timeout=5.0)
    assert resp.status_code == 200
    assert resp.content == b"hello-file-async"
