import tempfile, pathlib
from conftest import login, api_request


def test_file_upload_through_drawer(page):
    login(page)
    api_request(page, "POST", "/api/collections", {
        "name": "gallery", "type": "base",
        "fields": [
            {"id": "", "name": "caption", "type": "text", "options": {}},
            {"id": "", "name": "image", "type": "file", "options": {"maxSelect": 1}},
        ],
        "listRule": "", "viewRule": "", "createRule": "", "updateRule": "", "deleteRule": "",
    })
    page.reload()
    page.goto("/_/?t=1#/collections/gallery/records")
    page.wait_for_selector('[data-test=records-view]')

    page.click('[data-test=new-record]')
    page.wait_for_selector('[data-test=record-drawer]')
    page.fill('[data-test=in-caption]', 'A photo')

    png = pathlib.Path(tempfile.mkdtemp()) / "pic.png"
    png.write_bytes(b"\x89PNG\r\n\x1a\n" + b"\x00" * 32)  # valid PNG magic + padding
    page.set_input_files('[data-test=in-image]', str(png))

    page.click('[data-test=record-save]')
    page.wait_for_selector('[data-test=row]', timeout=6000)

    rows = page.locator('[data-test=rows]').inner_text()
    assert "A photo" in rows
    assert ".png" in rows  # stored filename column

    # Stronger: the stored file actually serves as an image.
    r = api_request(page, "GET", "/api/collections/gallery/records?perPage=1")
    item = r.json()["items"][0]
    rid, fname = item["id"], item["image"]
    assert fname.endswith(".png")
    resp = page.request.get(f"/api/files/gallery/{rid}/{fname}")
    assert resp.status == 200
    assert resp.headers.get("content-type", "").startswith("image/")
