import os, re, socket, subprocess, tempfile, time, shutil, pathlib, pytest
import json, urllib.request, urllib.error
from playwright.sync_api import sync_playwright
from _bin import resolve_binary

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]

# SUITE-WIDE foreground pin. Every server this suite spawns — the fixtures
# below, but also the ~25 inline `{**os.environ, ...}` spawns in
# test_static_files / test_scheduler / test_import / test_file_range /
# test_mail_unsubscribe, and the example-app fixture binaries (dating-server,
# blog, import-fixture) — is a FOREGROUND child the test terminates itself.
#
# `serve` auto-backgrounds when it detects an AI-agent environment
# (CLAUDECODE etc., see serve_control.detectAgent). Under an agent-driven run
# that turns every one of those spawns into: parent exits after readiness ->
# the fixture's terminate() hits an already-dead pid -> the real, detached
# server survives the test. That is how a single suite run stranded ~85 servers
# holding ports and fds, which in turn starved later tests of resources.
#
# Setting it here (module import = every xdist worker, before any spawn) covers
# every present AND future spawn site in this suite, instead of relying on ~25
# call sites each remembering the pin. The individual fixtures below still pass
# it explicitly, which is redundant but documents the requirement where the
# process is actually created. CI runners set no agent vars, so this is a no-op
# there; it only matters for local/agent-driven runs.
#
# Assigned, not setdefault: no test in this suite wants a backgrounded server,
# so an inherited ZIGBASE_SERVE_BACKGROUND=1 would be a mistake to honor.
os.environ["ZIGBASE_SERVE_BACKGROUND"] = "0"

def _free_port():
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

@pytest.fixture(scope="session")
def binary():
    return resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")

# `superuser create` hashes the password with argon2id (deliberately CPU-slow),
# and every per-test server fixture used to pay it fresh. Instead seed ONE
# template data dir per binary (a single `data.db` with the superuser row — no
# WAL/lock/JWT files, since it's only ever created, never served against) and
# copytree it into each test's tempdir. `serve` then provisions collections as
# normal per test. Keyed by binary path (the zigbase and auth2 builds differ);
# memoized per worker process (each xdist worker builds its own once).
_su_templates = {}

def _su_template_for(binary):
    tmpl = _su_templates.get(binary)
    if tmpl is None:
        tmpl = tempfile.mkdtemp(prefix="zb_tmpl_")
        try:
            subprocess.run([binary, "superuser", "create", "--email", "admin@x.io",
                            "--password", "adminpassword", "--data-dir", tmpl], check=True)
        except Exception:
            shutil.rmtree(tmpl, ignore_errors=True)
            raise
        _su_templates[binary] = tmpl
    return tmpl

@pytest.fixture(scope="session", autouse=True)
def _cleanup_su_templates():
    yield
    for p in _su_templates.values():
        shutil.rmtree(p, ignore_errors=True)

@pytest.fixture()
def server(binary, request):
    data = tempfile.mkdtemp(prefix="zb_admin_")
    shutil.copytree(_su_template_for(binary), data, dirs_exist_ok=True)
    port = _free_port()
    extra_env = getattr(request, "param", None) or {}
    env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_HTTP_PORT": str(port),
           # The harness owns this process as a FOREGROUND child (terminate() in the
           # finally). Without the pin, running the suite from inside an AI-agent
           # session (CLAUDECODE etc.) would trigger serve's auto-backgrounding: the
           # parent exits after readiness, terminate() hits the dead parent, and the
           # detached child leaks past the test.
           "ZIGBASE_SERVE_BACKGROUND": "0", **extra_env}
    # Plain-HTTP local test server: opt out of Secure cookies (default-on) so the
    # browser stores the auth/CSRF cookies over http://; the default loopback bind
    # and auto-generated JWT secret are exactly what we want.
    log_path = os.path.join(data, "server.log")
    with open(log_path, "wb") as log:
        proc = subprocess.Popen([binary, "serve", "--insecure-cookies"], env=env,
                                stdout=log, stderr=subprocess.STDOUT)
    base = f"http://127.0.0.1:{port}"
    try:
        _wait_reachable_or_fail(proc, port, log_path)
        yield base
    finally:
        try:
            _stop_server(proc)
        finally:
            shutil.rmtree(data, ignore_errors=True)

# Launching Chromium (~0.5s) once per test dominated the wall time of the (now
# parallel) suite. Reuse ONE browser process per test session — under pytest-xdist
# each worker is a separate process, so this is one Chromium per worker. Each test
# still gets a fresh, isolated browser context (cookies/storage) + page, which is
# cheap (~ms) to create.
@pytest.fixture(scope="session")
def _playwright():
    with sync_playwright() as pw:
        yield pw

@pytest.fixture(scope="session")
def _browser(_playwright):
    browser = _playwright.chromium.launch()
    yield browser
    browser.close()

@pytest.fixture()
def page(_browser, server):
    ctx = _browser.new_context(base_url=server)
    pg = ctx.new_page()
    yield pg
    ctx.close()


# ---------------------------------------------------------------------------
# auth-round-2 fixture (fixtures/auth2): table-mode sessions + a registered
# beforeAuthSuccess hook, for the browser suite's F1-F3 login/session coverage.
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def auth2_binary():
    """The auth-round-2 fixture server: .session_store = .table + a registered
    beforeAuthSuccess (fixtures/auth2). Honors the CI-prebuilt override."""
    override = os.environ.get("ZIGBASE_TEST_AUTH2_BINARY")
    if override:
        if not pathlib.Path(override).exists():
            raise FileNotFoundError(f"ZIGBASE_TEST_AUTH2_BINARY={override} does not exist")
        return override
    subprocess.run(ZIG + ["build", "auth2-server"], cwd=REPO, check=True)
    path = REPO / "zig-out" / "bin" / "auth2-server"
    assert path.exists(), f"auth2-server not built at {path}"
    return str(path)

def _stop_server(proc):
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=5)


def _wait_reachable_or_fail(proc, port, log_path, timeout_s=5.0):
    """Require HTTP health readiness, not merely an open socket; raise instead of returning
    silently if the server dies early or never comes up. A fixture that raises here
    fails cleanly at setup, instead of yielding a base URL nothing is listening on and
    leaving every test in the fixture to fail later with a generic connection error."""
    deadline = time.monotonic() + timeout_s
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            break  # process already exited; no point polling further
        try:
            with opener.open(f"http://127.0.0.1:{port}/api/health", timeout=0.2) as response:
                body = json.load(response)
                if response.status == 200 and isinstance(body, dict) and body.get("status") == "ok":
                    return
        except (OSError, ValueError, urllib.error.URLError):
            pass
        time.sleep(0.1)
    _stop_server(proc)
    output = pathlib.Path(log_path).read_text(errors="replace") if pathlib.Path(log_path).exists() else "<no output captured>"
    raise AssertionError(f"server on port {port} never became reachable (exit={proc.returncode}):\n{output}")

@pytest.fixture()
def auth2_server(auth2_binary):
    """A live table-mode server with the beforeAuthSuccess fixture hook registered."""
    data = tempfile.mkdtemp(prefix="zb_auth2_")
    shutil.copytree(_su_template_for(auth2_binary), data, dirs_exist_ok=True)
    port = _free_port()
    # Foreground pin: see the server fixture's comment on ZIGBASE_SERVE_BACKGROUND.
    env = {**os.environ, "ZIGBASE_DATA_DIR": data, "ZIGBASE_HTTP_PORT": str(port),
           "ZIGBASE_SERVE_BACKGROUND": "0"}
    log_path = os.path.join(data, "server.log")
    with open(log_path, "wb") as log:
        proc = subprocess.Popen([auth2_binary, "serve", "--insecure-cookies"], env=env,
                                stdout=log, stderr=subprocess.STDOUT)
    try:
        _wait_reachable_or_fail(proc, port, log_path)
    except AssertionError:
        shutil.rmtree(data, ignore_errors=True)
        raise
    try:
        yield f"http://127.0.0.1:{port}"
    finally:
        try:
            _stop_server(proc)
        finally:
            shutil.rmtree(data, ignore_errors=True)

@pytest.fixture()
def auth2_page(_browser, auth2_server):
    ctx = _browser.new_context(base_url=auth2_server)
    pg = ctx.new_page()
    yield pg
    ctx.close()


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
    # Click Save, then synchronize on the post-save reload via wait_for_url.
    # wait_for_url resolves once the URL has committed to `?saved=<ts>` — and if
    # the reload already landed before this call runs, it resolves immediately
    # (it checks the current URL), so we can't miss the location.assign() that
    # save() schedules. After save the app stays on the `?saved=` URL (no
    # away-navigation), so there's no transient-URL hazard. This guarantees the
    # reload is no longer in flight when we return — a later page.goto() can't
    # collide with it (which is what produced the net::ERR_ABORTED flake).
    # (wait_for_url over the deprecated, racy expect_navigation per Playwright.)
    # Match the URL with a regex, not a glob: Playwright's URL glob treats `?` as
    # a single-char wildcard, so a literal `/_/?saved=` query never matches a glob
    # pattern. A regex on `saved=` is unambiguous.
    page.click('[data-test=save-collection]')
    page.wait_for_url(re.compile(r"[?&]saved="), wait_until="commit")
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
