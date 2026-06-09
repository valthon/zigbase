import os, socket, subprocess, tempfile, time, shutil, pathlib, pytest
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
    proc = subprocess.Popen([binary, "serve"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
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
