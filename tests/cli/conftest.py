import json, os, pathlib, shutil, socket, subprocess, tempfile, time
import pytest
from _bin import resolve_binary

REPO = pathlib.Path(__file__).resolve().parents[2]

# Every env var `serve_control.detectAgent` (src/serve_control.zig) sniffs, plus
# the two generic conventions it also checks (AGENT, AI_AGENT). This suite
# needs a clean, non-agent baseline by default (only test_agent_env_* and
# test_the_opt_out_env_* deliberately opt back in) — but pytest itself may be
# invoked FROM inside one of these agent environments (Claude Code, etc.), in
# which case the ambient var would otherwise leak into every child `zigbase`
# process and silently flip it into auto-background mode. CI runners don't set
# any of these, so this is a no-op there; it only matters for local/agent-driven
# runs of this suite itself.
_AGENT_ENV_VARS = (
    "CLAUDECODE", "CODEX_THREAD_ID", "GEMINI_CLI", "CODEIUM_EDITOR_APP_ROOT",
    "AIDER_API_KEY", "OZ_RUN_ID", "AMP_CURRENT_THREAD_ID", "AUGMENT_AGENT",
    "QWEN_CODE", "ANTIGRAVITY_AGENT", "PI_CODING_AGENT", "OPENCODE", "CRUSH",
    "CURSOR_TRACE_ID", "PAGER", "AGENT", "AI_AGENT",
)


def clean_env(extra=None):
    """os.environ with every agent-detection var stripped, plus overrides."""
    base = {k: v for k, v in os.environ.items() if k not in _AGENT_ENV_VARS}
    base.update(extra or {})
    return base


@pytest.fixture(scope="session")
def binary():
    return resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase")


@pytest.fixture()
def data_dir():
    d = tempfile.mkdtemp(prefix="zb_cli_")
    yield d
    # Stop anything still running against this dir BEFORE removing it: a test
    # that fails partway through never reaches its own `serve stop`, and the
    # bare rmtree this used to be left that server alive, holding a deleted
    # data dir and its port for the rest of the session. `serve stop` is
    # idempotent and exits 0 when there is nothing to stop, so this is a no-op
    # on the happy path; failures are swallowed because teardown must not
    # convert a test failure into an error.
    try:
        subprocess.run([resolve_binary("ZIGBASE_TEST_BINARY", REPO, "zigbase"),
                        "serve", "stop", "--data-dir", d],
                       capture_output=True, timeout=30, env=clean_env())
    except Exception:
        pass
    shutil.rmtree(d, ignore_errors=True)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def run(binary, *args, env=None, timeout=60):
    """Run a zigbase CLI command to completion; return CompletedProcess.

    The child env is the agent-detection-scrubbed baseline (see clean_env)
    plus any explicit overrides — so plain invocations get deterministic
    non-agent behavior even when pytest itself runs inside an agent.
    """
    return subprocess.run(
        [binary, *args],
        capture_output=True, text=True, timeout=timeout,
        env=clean_env(env),
    )


def status_json(binary, data_dir):
    """`serve status --json` -> (parsed_object, exit_code). Asserts the shared
    convention: exactly one JSON object on stdout, nothing else."""
    p = run(binary, "serve", "status", "--json", "--data-dir", data_dir)
    lines = [l for l in p.stdout.splitlines() if l.strip()]
    assert len(lines) == 1, f"expected exactly one JSON object on stdout, got {p.stdout!r}"
    return json.loads(lines[0]), p.returncode


def wait_until(predicate, timeout_s=20.0, interval_s=0.1):
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval_s)
    return False


def wait_running(binary, data_dir, timeout_s=20.0):
    """Poll `serve status --json` until it reports the FULL `.running` shape
    (exit 0), not `.starting` (live flock, serve.json not yet written).

    A plain foreground `zigbase serve` process answers /api/health as soon as
    zap's accept loop starts, which races the readiness-verifier thread that
    writes serve.json ~100ms later (see serve_control.zig's Verifier — this is
    a documented race window, ".starting is the real race window"). A test
    that polls /api/health and then immediately shells out to `serve status`
    can genuinely observe `.starting` and get a status dict with only
    `running`/`starting` keys. This closes that window instead of asserting
    on it as if it were instantaneous.
    """
    result = {}

    def ready():
        st, code = status_json(binary, data_dir)
        result["st"], result["code"] = st, code
        return code == 0

    assert wait_until(ready, timeout_s=timeout_s), f"never reached .running: {result}"
    return result["st"], result["code"]
