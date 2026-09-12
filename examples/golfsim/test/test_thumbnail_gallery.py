"""Exercise the built Golfsim island in Chromium; backend transforms are tested separately.

Run after frontend/build.sh: python -m pytest test/test_thumbnail_gallery.py -q
"""

import base64
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
from threading import Thread

import pytest
from playwright.sync_api import sync_playwright


DIST = Path(__file__).resolve().parents[1] / "frontend" / "dist"
PNG = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aJ1sAAAAASUVORK5CYII=")


@pytest.mark.parametrize("enabled,fail_derivative", [(False, False), (True, False), (True, True)])
def test_gallery_uses_compiled_profile_and_falls_back_once(enabled, fail_derivative):
    assert (DIST / "index.html").is_file(), "build the Golfsim frontend first"
    server = ThreadingHTTPServer(("127.0.0.1", 0), partial(SimpleHTTPRequestHandler, directory=str(DIST)))
    thread = Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch()
            try:
                page = browser.new_page()
                errors = []
                page.on("pageerror", lambda error: errors.append(str(error)))
                page.route("**/api/golfsim/health", lambda route: route.fulfill(
                    content_type="application/json", body=json.dumps({"status": "ok", "app": "golfsim", "thumbnail_profile": "card" if enabled else None})))
                page.route("**/api/collections/listings/records**", lambda route: route.fulfill(
                    content_type="application/json", body=json.dumps({"items": [{"id": "listing", "title": "Photo listing", "photos": ["one.png", "two.jpeg", "three.webp"], "hourly_rate": 20}], "totalItems": 1, "totalPages": 1, "page": 1, "perPage": 30})))
                requested = []

                def image(route):
                    path = route.request.url.split("/api/files/", 1)[1]
                    requested.append(path)
                    # Failed originals also exercise the no-retry-loop guard.
                    route.fulfill(status=503 if fail_derivative else 200,
                                  content_type="image/png", body=b"" if fail_derivative else PNG)

                page.route("**/api/files/**", image)
                page.goto(f"http://127.0.0.1:{server.server_port}/")
                page.wait_for_function("document.querySelectorAll('img[alt=\"Photo listing\"]').length === 3")
                expected = 6 if fail_derivative else 3
                page.wait_for_function("n => performance.getEntriesByType('resource').filter(e => e.name.includes('/api/files/')).length >= n", arg=expected)
                page.wait_for_timeout(150)
                assert not errors
                assert len(requested) == expected
                assert sum(path.endswith("/thumbnail/card") for path in requested) == (3 if enabled else 0)
                assert sum(not path.endswith("/thumbnail/card") for path in requested) == (3 if not enabled or fail_derivative else 0)
            finally:
                browser.close()
    finally:
        server.shutdown()
        server.server_close()
        thread.join()
