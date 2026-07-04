import pathlib

from conftest import login, api_request, csrf

def _seed_file_collection(page, col="assets"):
    api_request(page, "POST", "/api/collections", {"name": col, "type": "base",
        "fields": [{"id": "", "name": "img", "type": "file", "options": {"maxSelect": 1}}]})

def _write_png(dirpath):
    png_bytes = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32  # valid PNG magic + padding
    path = pathlib.Path(dirpath) / "_fixtures_1x1.png"
    path.write_bytes(png_bytes)
    return path

def test_files_view_storage_strip_and_picker(page):
    login(page)
    _seed_file_collection(page)
    page.goto("/_/#/files")
    page.wait_for_selector('[data-test=files-view]')
    # storage strip fetched from GET /api/files/config
    page.wait_for_selector('[data-test=storage-backend]')
    assert page.inner_text('[data-test=storage-backend]').strip() != ""
    # collection picker lists the file-field collection
    page.wait_for_selector('[data-test=files-collection]')
    page.select_option('[data-test=files-collection]', "assets")

def test_files_browse_shows_record_file(page, tmp_path):
    login(page)
    _seed_file_collection(page)
    # seed a record WITH a file via multipart, direct API (no UI form for this)
    png_bytes = _write_png(tmp_path).read_bytes()
    r = page.request.post("/api/collections/assets/records",
        multipart={"img": {"name": "pic.png", "mimeType": "image/png", "buffer": png_bytes}},
        headers={"X-CSRF-Token": csrf(page)})
    assert r.ok, r.text()
    page.goto("/_/#/files")
    page.wait_for_selector('[data-test=files-view]')
    page.select_option('[data-test=files-collection]', "assets")
    page.wait_for_selector('[data-test=file-record-row]')
    # the record's image field renders a thumbnail
    page.click('[data-test=file-record-row]')
    page.wait_for_selector('[data-test=file-thumb]')
    src = page.get_attribute('[data-test=file-thumb]', 'src')
    assert src.startswith('/api/files/assets/') and src.endswith('.png')

def test_files_upload_and_remove(page, tmp_path):
    login(page)
    _seed_file_collection(page)
    # a record with no file yet
    api_request(page, "POST", "/api/collections/assets/records", {})
    page.goto("/_/#/files")
    page.wait_for_selector('[data-test=files-view]')
    page.select_option('[data-test=files-collection]', "assets")
    page.wait_for_selector('[data-test=file-record-row]')
    page.click('[data-test=file-record-row]')
    page.wait_for_selector('[data-test=file-drawer]')
    png = _write_png(tmp_path)
    page.set_input_files('[data-test=file-upload]', str(png))
    page.wait_for_selector('[data-test=file-drawer] [data-test=file-thumb]')
    # remove it
    page.once("dialog", lambda d: d.accept())
    page.click('[data-test=file-remove]')
    page.wait_for_function("!document.querySelector('[data-test=file-drawer] [data-test=file-thumb]')")
