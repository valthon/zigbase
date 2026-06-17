import os, re, socket, subprocess, tempfile, time, shutil, pathlib, pytest
from playwright.sync_api import sync_playwright

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]

def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

@pytest.fixture(scope="session")
def binary():
    subprocess.run(ZIG + ["build"], cwd=REPO, check=True)
    return str(REPO / "zig-out" / "bin" / "zigbase")

@pytest.fixture()
def server(binary):
    data = tempfile.mkdtemp(prefix="zb_admin_")
    subprocess.run([binary, "superuser", "create", "--email", "admin@x.io", "--password", "adminpassword", "--data-dir", data], check=True)
    port = _free_port()
    env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_HTTP_PORT": str(port)}
    # Plain-HTTP local test server: opt out of Secure cookies (default-on) so the
    # browser stores the auth/CSRF cookies over http://; the default loopback bind
    # and auto-generated JWT secret are exactly what we want.
    proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    for _ in range(50):
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2): break
        except OSError: time.sleep(0.1)
    base = f"http://127.0.0.1:{port}"
    try:
        yield base
    finally:
        proc.terminate(); proc.wait(timeout=5); shutil.rmtree(data, ignore_errors=True)

@pytest.fixture()
def page(server):
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        ctx = browser.new_context(base_url=server)
        pg = ctx.new_page()
        yield pg
        ctx.close(); browser.close()

def login(page):
    page.goto("/_/#/login")
    page.fill('[data-test=email]', 'admin@x.io')
    page.fill('[data-test=password]', 'adminpassword')
    page.click('[data-test=login-submit]')
    page.wait_for_selector('[data-test=nav-collections]', timeout=5000)

def save_collection_and_wait(page):
    """Click the schema editor's Save and block until the app's post-save
    full-document reload has fully COMPLETED.

    On a successful save, app.js's SchemaEditor.save() ends with
    `location.assign('/_/?saved=<ts>#/collections/<name>/records')` — a full
    document reload (new path query busts the doc cache). If a test issues its
    own `page.goto(...)` while that reload is still in flight, the two
    navigations collide and Playwright aborts the goto (net::ERR_ABORTED).

    Synchronize on the reload instead of racing it: wait for the `saved=` URL to
    land and for the network to go idle, so no navigation is in flight when the
    caller continues. Only use this on the SUCCESS path — on a validation error
    the app stays on the editor and never reloads.
    """
    # Capture the post-save reload as a first-class navigation: expect_navigation
    # arms a waiter BEFORE the click fires, so we can't miss the location.assign()
    # that save() schedules, and it resolves only once that navigation has
    # actually committed to the `?saved=<ts>` URL. This guarantees the reload is
    # no longer in flight when we return — a later page.goto() can't collide with
    # it (which is what produced the net::ERR_ABORTED flake).
    # Match the URL with a regex, not a glob: Playwright's URL glob treats `?` as
    # a single-char wildcard, so a literal `/_/?saved=` query never matches a glob
    # pattern. A regex on `saved=` is unambiguous.
    with page.expect_navigation(url=re.compile(r"[?&]saved="), wait_until="commit"):
        page.click('[data-test=save-collection]')
    # The reload has committed (the old in-flight navigation is done). Now wait
    # for the freshly-loaded document to finish loading + go network-idle
    # (collections fetch + render) before handing control back, so the caller's
    # next page.goto() targets a fully-settled page.
    page.wait_for_load_state("load")
    page.wait_for_load_state("networkidle")


def csrf(page):
    for c in page.context.cookies():
        if c["name"] == "zb_csrf":
            return c["value"]
    return ""

def api_request(page, method, path, body=None):
    headers = {"X-CSRF-Token": csrf(page)}
    if body is not None:
        headers["Content-Type"] = "application/json"
    r = page.request.fetch(path, method=method, headers=headers, data=(__import__("json").dumps(body) if body is not None else None))
    return r
