"""Deterministic positive and negative controls for the Rails full-stack eval."""

from __future__ import annotations

import io
import json
import shutil
import stat
import sys
import urllib.error
import urllib.request
from pathlib import Path

import pytest

from evals.agents.graders import _harness
from evals.agents.graders.genesis import CommandResult
from evals.agents.graders.genesis import GradeFailure
from evals.agents.graders.rails_fullstack import (
    EXPECTED_PUBLIC,
    PersistedState,
    REQUIRED_BROWSER_KINDS,
    _binary,
    _capture,
    _python_with_playwright,
    _probe_switched_target,
    _request,
    _shebang_interpreter,
    grade,
    inspect_completion,
    probe_backend_capture,
    probe_parity,
    run_rehearsal,
    run_restore,
    verify_source,
)
from evals.agents.scenario import AgentScenario
from tools.rails.fullstack import reconcile, write_canonical
from tools.replay import zb_replay


REPO = Path(__file__).resolve().parents[2]
SCENARIO = REPO / "evals" / "agents" / "scenarios" / "rails-fullstack"


def persisted_state() -> PersistedState:
    return PersistedState(
        "restore@example.invalid", "password", "post-id", "persisted title"
    )


def test_private_harness_writer_replaces_a_symlink_without_following_it(tmp_path):
    victim = tmp_path / "victim"
    victim.write_text("unchanged")
    output = tmp_path / "override.yml"
    output.symlink_to(victim)

    _harness.write_private_text(output, "replacement\n")

    assert victim.read_text() == "unchanged"
    assert output.read_text() == "replacement\n"
    assert not output.is_symlink()
    assert stat.S_IMODE(output.stat().st_mode) == 0o600


def test_shared_bounded_reader_accepts_regular_files_and_enforces_limit(tmp_path):
    artifact = tmp_path / "artifact.json"
    artifact.write_bytes(b"{}\n")

    assert _harness.read_bounded_regular(artifact, 3) == b"{}\n"
    with pytest.raises(ValueError, match="byte limit"):
        _harness.read_bounded_regular(artifact, 2)
    with pytest.raises(OSError, match="not a regular file"):
        _harness.read_bounded_regular(tmp_path, 1024)


def test_local_http_opener_never_uses_environment_proxies():
    proxies = [
        handler
        for handler in _harness._HTTP_OPENER.handlers
        if isinstance(handler, urllib.request.ProxyHandler)
    ]

    # build_opener elides a ProxyHandler with an explicitly empty mapping.  A
    # default build would instead install the environment-derived handler.
    assert proxies == []


def source(verb, path, controller, action):  # noqa: ANN001
    return {
        "verb": verb,
        "path": path,
        "controller": controller,
        "action": action,
        "occurrence": 1,
    }


def decisions():
    routes = []

    def add(verb, path, controller, action, **values):  # noqa: ANN001
        routes.append(
            {
                "source": source(verb, path, controller, action),
                "surface": values.pop("surface", "browser"),
                "disposition": values.pop("disposition", "migrated"),
                "parity": values.pop("parity", []),
                "rationale": values.pop(
                    "rationale", f"Reviewed disposition for {verb} {path}."
                ),
                **values,
            }
        )

    for path, controller, action in (
        ("/", "pages", "about"),
        ("/about", "pages", "about"),
        ("/linked", "pages", "linked"),
        ("/posts", "posts", "index"),
        ("/posts/new", "posts", "new"),
        ("/registration/new", "registrations", "new"),
        ("/session/new", "sessions", "new"),
        ("/stream", "pages", "stream"),
        ("/widgets", "pages", "widgets"),
    ):
        add(
            "GET",
            path,
            controller,
            action,
            parity=[{"kind": "browser", "id": f"navigate:GET {path}"}],
        )

    blockers = {
        "/broken": (
            "pages",
            "broken",
            "RAILS_TEMPLATE_PARSE_ERROR.app/views/pages/broken%2Ehtml%2Eerb.L2",
        ),
        "/help": (
            "pages",
            "help",
            "RAILS_HELPER_UNKNOWN.app/views/pages/help%2Ehtml%2Eerb.L1C18",
        ),
        "/links": (
            "pages",
            "links",
            "RAILS_ROUTE_HELPER_UNKNOWN.app/views/pages/links%2Ehtml%2Eerb.L1C5",
        ),
        "/live": (
            "pages",
            "live",
            "RAILS_COMPONENT_VUE_UNSUPPORTED.app/views/pages/live%2Ehtml%2Eerb.L1C33",
        ),
        "/posts/:id": (
            "posts",
            "show",
            "RAILS_ROUTE_DYNAMIC_SEGMENT.config/routes%2Erb.L14",
        ),
        "/posts/legacy": (
            "posts",
            "legacy",
            "RAILS_TEMPLATE_ENGINE_UNSUPPORTED.app/views/posts/legacy%2Ehtml%2Ehaml.engine",
        ),
    }
    for path, (controller, action, blocker) in blockers.items():
        add("GET", path, controller, action, disposition="blocked", blockers=[blocker])
    add("GET", "/old", "pages", "old", disposition="retained")
    add(
        "GET",
        "/feed",
        "posts",
        "feed",
        surface="api",
        parity=[{"kind": "backend", "id": "list-posts"}],
    )
    add(
        "POST",
        "/posts",
        "posts",
        "create",
        parity=[
            {
                "kind": "browser",
                "id": "submit_allowed:createPosts",
            },
            {"kind": "browser", "id": "submit_denied:createPosts"},
            {
                "kind": "browser",
                "id": "validation_error:createPosts:title",
            },
            {"kind": "backend", "id": "create-post-allowed"},
            {"kind": "backend", "id": "create-post-denied"},
            {"kind": "backend", "id": "create-post-invalid"},
        ],
    )
    add(
        "POST",
        "/registration",
        "registrations",
        "create",
        parity=[
            {"kind": "browser", "id": "signup:users"},
            {"kind": "backend", "id": "signup-user"},
        ],
    )
    add(
        "DELETE",
        "/session",
        "sessions",
        "destroy",
        surface="api",
        method_change_rationale="ZigBase logout is exposed as an idempotent POST operation.",
        parity=[
            {"kind": "backend", "id": "logout-allowed"},
            {"kind": "backend", "id": "logout-repeat"},
        ],
    )
    add(
        "POST",
        "/session",
        "sessions",
        "create",
        parity=[
            {"kind": "browser", "id": "signin:users"},
            {"kind": "backend", "id": "signin-user"},
            {"kind": "backend", "id": "signin-denied"},
        ],
    )
    return {"zigbaseRailsFullstackDecisions": 1, "routes": routes}


def workspace(tmp_path: Path) -> Path:
    target = tmp_path / "workspace"
    shutil.copytree(SCENARIO / "fixture", target)
    migration = target / "migration"
    migration.mkdir()
    security = target / "security"
    security.mkdir()
    public_rules = {
        "zigbasePublicRules": 1,
        "rules": [
            {
                "collection": collection,
                "operation": operation,
                "rule": "@public",
                "rationale": f"Reviewed fixture access for {collection}.{operation}.",
            }
            for collection, operation in (
                ("posts", "list"),
                ("posts", "view"),
                ("users", "create"),
            )
        ],
    }
    (security / "public-rules.json").write_text(
        json.dumps(public_rules, indent=2) + "\n"
    )
    (migration / "fullstack-decisions.json").write_text(
        json.dumps(decisions(), indent=2) + "\n"
    )
    source_dir = target / "source"
    manifest = reconcile(
        source_dir / "backend-routes.json",
        source_dir / "presentation.manifest.json",
        source_dir / "presentation.handoff.json",
        source_dir / "zigbase.openapi.json",
        migration / "fullstack-decisions.json",
        source_dir / "backend-findings.ndjson",
        source_dir / "backend-capture.ndjson",
    )
    write_canonical(migration / "fullstack-manifest.json", manifest)
    return target


class FakeCommands:
    def __init__(self):
        self.calls = []

    def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
        self.calls.append(argv)
        if "-c" in argv and "import playwright" in argv[-1]:
            return CommandResult(0, "zigbase-playwright-import-ok\n")
        if "schema" in argv and "--dry-run" in argv:
            return CommandResult(
                0,
                json.dumps(
                    {
                        "zigbase_schema_apply": 1,
                        "dry_run": True,
                        "destructive": False,
                        "applied": [],
                        "apply_order": ["posts", "users"],
                    }
                ),
            )
        if "schema" in argv and "--dry-run" not in argv:
            data = Path(argv[argv.index("--data-dir") + 1])
            data.mkdir(parents=True, exist_ok=True)
            (data / "data.db").touch()
        if "doctor" in argv:
            rows = [
                {
                    "check": "public-rules-enumerated",
                    "severity": "warn",
                    "subject": subject,
                }
                for subject in ("posts.listRule", "posts.viewRule", "users.createRule")
            ]
            rows.append(
                {
                    "summary": True,
                    "production": True,
                    "checks": 1,
                    "errors": 0,
                    "warnings": 3,
                    "skipped": 0,
                }
            )
            return CommandResult(0, "\n".join(json.dumps(row) for row in rows))
        return CommandResult(0)


class FailingSchemaCommands(FakeCommands):
    def __init__(self, *, dry_run: bool):
        super().__init__()
        self.dry_run = dry_run

    def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
        if "schema" in argv and ("--dry-run" in argv) is self.dry_run:
            self.calls.append(argv)
            return CommandResult(7, stderr="schema failed")
        return super().run(argv, cwd=cwd, env=env, timeout=timeout)


class FailingDoctorCommands(FakeCommands):
    def __init__(self, returncode=7, **result_flags):  # noqa: ANN003
        super().__init__()
        self.returncode = returncode
        self.result_flags = result_flags

    def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
        result = super().run(argv, cwd=cwd, env=env, timeout=timeout)
        if "doctor" in argv:
            return CommandResult(
                self.returncode,
                result.stdout,
                "doctor failed" if self.returncode else "",
                **self.result_flags,
            )
        return result


def graded(target: Path, artifacts: Path, monkeypatch, commands=None):  # noqa: ANN001
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if url.endswith("auth-with-password"):
            payload = b'{"token":"restored"}'
        elif url.endswith("/records/post-id"):
            payload = b'{"id":"post-id","title":"persisted title"}'
        elif url.endswith("/records"):
            payload = b'{"items":[{"id":"post-id","title":"persisted title"}]}'
        else:
            payload = b"{}"
        return 200, payload, "text/html"

    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack._request",
        request,
    )
    return grade(
        target,
        artifacts,
        commands=commands or FakeCommands(),
        binary_path=sys.executable,
        port_picker=iter(range(41000, 41020)).__next__,
        health_getter=lambda *args, **kwargs: {},
        parity_probe=lambda *args, **kwargs: persisted_state(),
        backend_probe=lambda *args, **kwargs: None,
        persistence_probe=lambda *args, **kwargs: None,
        playwright_python=__file__,
    )


@pytest.mark.parametrize(
    "commands",
    [
        FailingDoctorCommands(),
        FailingDoctorCommands(returncode=0, timed_out=True),
        FailingDoctorCommands(returncode=0, output_truncated=True),
    ],
    ids=["nonzero", "timed-out", "truncated"],
)
def test_failed_doctor_cannot_receive_a_clean_rules_grade(
    tmp_path, monkeypatch, commands
):
    result = graded(
        workspace(tmp_path),
        tmp_path / "artifacts",
        monkeypatch,
        commands=commands,
    )

    assert result.rules_locked is False
    assert result.tests_green is False
    assert any(failure.code == "rules.doctor_failed" for failure in result.failures)


class HttpResponse:
    def __init__(self, payload: bytes, *, status: int = 200):
        self.payload = payload
        self.status = status
        self.headers = {"Content-Type": "application/json"}
        self.read_limit = None

    def read(self, limit=-1):  # noqa: ANN001
        self.read_limit = limit
        return self.payload if limit < 0 else self.payload[:limit]

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False


class HttpOpener:
    def __init__(self, outcome):  # noqa: ANN001
        self.outcome = outcome
        self.requests = []

    def open(self, request, *, timeout):  # noqa: ANN001
        self.requests.append((request, timeout))
        if isinstance(self.outcome, Exception):
            raise self.outcome
        return self.outcome


def http_error(url: str, status: int, payload: bytes, **headers):
    return urllib.error.HTTPError(
        url,
        status,
        "response",
        headers,
        io.BytesIO(payload),
    )


def test_request_preserves_redirect_status_and_never_forwards_secrets(monkeypatch):
    url = "http://target.invalid/private"
    destination = "https://collector.invalid/stolen"
    opener = HttpOpener(http_error(url, 302, b"redirect", Location=destination))
    monkeypatch.setattr(_harness, "_HTTP_OPENER", opener)

    status, payload, _ = _request("GET", url, token="grader-secret")

    assert (status, payload) == (302, b"redirect")
    assert len(opener.requests) == 1
    original = opener.requests[0][0]
    assert original.get_header("Authorization") == "Bearer grader-secret"
    assert (
        _harness._NoRedirectHandler().redirect_request(
            original,
            None,
            302,
            "Found",
            {"Location": destination},
            destination,
        )
        is None
    )


@pytest.mark.parametrize("status", [200, 500])
def test_request_rejects_oversized_success_and_error_bodies(monkeypatch, status):
    monkeypatch.setattr(_harness, "MAX_HTTP_RESPONSE_BYTES", 4)
    url = "http://target.invalid/large"
    outcome = (
        HttpResponse(b"12345", status=status)
        if status == 200
        else http_error(url, status, b"12345")
    )
    monkeypatch.setattr(_harness, "_HTTP_OPENER", HttpOpener(outcome))

    with pytest.raises(_harness.HttpResponseError, match="exceeds the 4-byte limit"):
        _request("GET", url)


@pytest.mark.parametrize("status", [200, 400])
def test_request_preserves_binary_success_and_error_bodies(monkeypatch, status):
    url = "http://target.invalid/not-text"
    outcome = (
        HttpResponse(b"\xff", status=status)
        if status == 200
        else http_error(url, status, b"\xff")
    )
    monkeypatch.setattr(_harness, "_HTTP_OPENER", HttpOpener(outcome))

    assert _request("GET", url)[:2] == (status, b"\xff")


def test_shared_health_reader_is_bounded(monkeypatch):
    monkeypatch.setattr(_harness, "MAX_HTTP_RESPONSE_BYTES", 8)
    response = HttpResponse(b'{"ok":true}')
    monkeypatch.setattr(_harness, "_HTTP_OPENER", HttpOpener(response))

    with pytest.raises(_harness.HttpResponseError, match="exceeds the 8-byte limit"):
        _harness.health_json("http://target.invalid/api/health", 1.0)
    assert response.read_limit == 9


@pytest.mark.parametrize(
    "payload",
    [
        b"null",
        b"{}",
        b'{"status":"down"}',
        b'{"status":"down","status":"ok"}',
        b'{"status":"ok","load":NaN}',
        b'{"status":"ok","load":1e999}',
        b"\xff",
    ],
)
def test_shared_health_reader_requires_strict_ok_object(monkeypatch, payload):
    monkeypatch.setattr(_harness, "_HTTP_OPENER", HttpOpener(HttpResponse(payload)))

    with pytest.raises(_harness.HttpResponseError):
        _harness.health_json("http://target.invalid/api/health", 1.0)


def test_shared_health_reader_accepts_ok_with_real_metadata(monkeypatch):
    payload = b'{"status":"ok","backend":"sqlite","versions":{}}'
    monkeypatch.setattr(_harness, "_HTTP_OPENER", HttpOpener(HttpResponse(payload)))

    assert (
        _harness.health_json("http://target.invalid/api/health", 1.0)["status"] == "ok"
    )


@pytest.mark.parametrize("status", [201, 202, 204])
def test_shared_health_reader_requires_http_200(monkeypatch, status):
    monkeypatch.setattr(
        _harness,
        "_HTTP_OPENER",
        HttpOpener(HttpResponse(b'{"status":"ok"}', status=status)),
    )

    with pytest.raises(_harness.HttpResponseError, match="not 200"):
        _harness.health_json("http://target.invalid/api/health", 1.0)


def test_scenario_loads_and_uses_only_the_fullstack_skill():
    scenario = AgentScenario.load(SCENARIO / "scenario.json")
    assert scenario.name == "rails-fullstack"
    assert scenario.skills == ("zigbase-migrate-rails-fullstack",)
    assert scenario.graders == ("rails-fullstack",)


def test_scenario_materializes_the_canonical_coordinator_and_replay_tool():
    scenario = AgentScenario.load(SCENARIO / "scenario.json")
    assert set(scenario.repository_files) >= {
        "tools/rails/fullstack.py",
        "tools/rails/contracts/rails-handoff.v1.schema.json",
        "tools/rails/contracts/rails-presentation.v1.schema.json",
        "tools/replay/zb_replay.py",
    }


def test_prompt_names_every_boundary_the_grader_enforces():
    prompt = " ".join((SCENARIO / "prompt.md").read_text().lower().split())
    for marker in (
        "leave `source/` byte-for-byte unchanged",
        "zigbaserailsfullstackdecisions",
        "run it twice",
        "protected post/patch behavior",
        "allowed and denied",
        "zigbasepublicrules",
        "restart",
        "restore",
        "rollback",
        "cutover",
        "rails_component_vue_unsupported",
    ):
        assert marker in prompt


def test_positive_workspace_scores_four(tmp_path, monkeypatch):
    target = workspace(tmp_path)
    credential_path = target / ".rehearsal/restore-probe.json"

    class NoCredentialFileCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            assert not credential_path.exists()
            result = super().run(argv, cwd=cwd, env=env, timeout=timeout)
            assert not credential_path.exists()
            return result

    report = graded(
        target,
        tmp_path / "artifacts",
        monkeypatch,
        NoCredentialFileCommands(),
    )
    assert report.failures == ()
    assert (
        report.completion,
        report.rules_locked,
        report.tests_green,
        report.deployed,
    ) == (
        True,
        True,
        True,
        True,
    )
    assert not credential_path.exists()


def test_source_mutation_only_cannot_pass(tmp_path, monkeypatch):
    target = workspace(tmp_path)
    path = target / "source" / "backend-routes.json"
    path.write_text(path.read_text().replace('"count": 21', '"count": 20'))
    report = graded(target, tmp_path / "artifacts", monkeypatch)
    assert report.completion is False
    assert any(failure.code == "source.changed" for failure in report.failures)


def test_generated_python_caches_do_not_change_the_frozen_source(tmp_path):
    copied = tmp_path / "source"
    shutil.copytree(SCENARIO / "fixture/source", copied)
    cache = copied / "presentation-target/test/__pycache__"
    cache.mkdir(parents=True, exist_ok=True)
    (cache / "journey_playwright.cpython-314.pyc").write_bytes(b"generated bytecode")
    (copied / "standalone.pyc").write_bytes(b"generated bytecode")
    (copied / "standalone.pyo").write_bytes(b"optimized bytecode")

    verify_source(copied)


def test_unrelated_extra_source_file_is_rejected(tmp_path):
    copied = tmp_path / "source"
    shutil.copytree(SCENARIO / "fixture/source", copied)
    (copied / "invented-evidence.json").write_text("{}\n")

    with pytest.raises(GradeFailure) as raised:
        verify_source(copied)
    assert raised.value.code == "source.changed"


def test_oversized_extra_source_file_is_rejected_before_reading(tmp_path, monkeypatch):
    copied = tmp_path / "source"
    shutil.copytree(SCENARIO / "fixture/source", copied)
    oversized = copied / "invented-evidence.json"
    with oversized.open("wb") as stream:
        stream.truncate(16 * 1024 * 1024 + 1)

    def refuse_read(path, maximum):  # noqa: ANN001, ARG001
        if path == oversized:
            pytest.fail("oversized source artifact was read")
        return _harness.read_bounded_regular(path, maximum)

    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.read_bounded_regular", refuse_read
    )
    with pytest.raises(GradeFailure) as raised:
        verify_source(copied)
    assert raised.value.code == "source.changed"


def test_source_size_drift_is_rejected_before_payload_reads(tmp_path, monkeypatch):
    copied = tmp_path / "source"
    shutil.copytree(SCENARIO / "fixture/source", copied)
    changed = copied / "backend-routes.json"
    changed.write_bytes(changed.read_bytes() + b" ")

    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.read_bounded_regular",
        lambda *_args: pytest.fail("size-drifted source artifact was read"),
    )
    with pytest.raises(GradeFailure) as raised:
        verify_source(copied)
    assert raised.value.code == "source.changed"


def test_backend_inventory_provenance_is_visible_in_the_canonical_manifest(tmp_path):
    target = workspace(tmp_path)
    manifest = json.loads(
        (target / "migration/fullstack-manifest.json").read_text(encoding="utf-8")
    )

    inventory = manifest["contracts"]["zigbase_rails_inventory"]
    assert inventory["version"] == 1
    assert inventory["source_mode"] == "observed"
    assert len(inventory["routes_sha256"]) == 64
    assert set(inventory["routes_sha256"]) <= set("0123456789abcdef")


@pytest.mark.parametrize("source_mode", [None, "inferred"])
def test_grader_refuses_a_non_observed_backend_inventory_even_if_it_is_pinned(
    tmp_path, monkeypatch, source_mode
):
    target = workspace(tmp_path)
    routes_path = target / "source/backend-routes.json"
    routes = json.loads(routes_path.read_text(encoding="utf-8"))
    if source_mode is None:
        routes.pop("source")
    else:
        routes["source"] = source_mode
    routes_path.write_text(json.dumps(routes, indent=2) + "\n", encoding="utf-8")

    # Treat these bytes as the pinned snapshot so this reaches the coordinator's
    # provenance gate rather than stopping at the independent immutability gate.
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.PINNED_SOURCE", target / "source"
    )
    with pytest.raises(GradeFailure) as raised:
        inspect_completion(target)
    assert raised.value.code == "completion.reconcile"
    assert "observed" in str(raised.value)


def test_backend_inventory_source_marker_is_part_of_the_frozen_source(
    tmp_path, monkeypatch
):
    target = workspace(tmp_path)
    routes_path = target / "source/backend-routes.json"
    routes = json.loads(routes_path.read_text(encoding="utf-8"))
    routes["source"] = "inferred"
    routes_path.write_text(json.dumps(routes, indent=2) + "\n", encoding="utf-8")

    result = graded(target, tmp_path / "artifacts", monkeypatch)
    assert result.completion is False
    assert any(failure.code == "source.changed" for failure in result.failures)


def test_public_rule_inventory_is_required(tmp_path):
    target = workspace(tmp_path)
    (target / "security/public-rules.json").unlink()

    with pytest.raises(GradeFailure) as raised:
        inspect_completion(target)
    assert raised.value.code == "rules.inventory_invalid"


@pytest.mark.parametrize("mutation", ["missing", "extra"])
def test_public_rule_inventory_must_exactly_match_the_live_public_surface(
    tmp_path, mutation
):
    target = workspace(tmp_path)
    path = target / "security/public-rules.json"
    inventory = json.loads(path.read_text(encoding="utf-8"))
    if mutation == "missing":
        inventory["rules"].pop()
    else:
        inventory["rules"].append(
            {
                "collection": "posts",
                "operation": "create",
                "rule": "@public",
                "rationale": "This invented public write must not be accepted.",
            }
        )
    path.write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")

    with pytest.raises(GradeFailure) as raised:
        inspect_completion(target)
    assert raised.value.code == "rules.inventory_drift"


@pytest.mark.parametrize("rationale", ["", "   ", None, False, 0])
def test_every_reviewed_public_rule_requires_a_non_empty_string_rationale(
    tmp_path, rationale
):
    target = workspace(tmp_path)
    path = target / "security/public-rules.json"
    inventory = json.loads(path.read_text(encoding="utf-8"))
    inventory["rules"][0]["rationale"] = rationale
    path.write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")

    with pytest.raises(GradeFailure) as raised:
        inspect_completion(target)
    assert raised.value.code == "rules.inventory_invalid"


def test_public_rule_entries_refuse_unreviewed_fields(tmp_path):
    target = workspace(tmp_path)
    path = target / "security/public-rules.json"
    inventory = json.loads(path.read_text(encoding="utf-8"))
    inventory["rules"][0]["approved"] = True
    path.write_text(json.dumps(inventory, indent=2) + "\n", encoding="utf-8")

    with pytest.raises(GradeFailure) as raised:
        inspect_completion(target)
    assert raised.value.code == "rules.inventory_invalid"


def test_missing_browser_control_fails_tests_grade(tmp_path, monkeypatch):
    target = workspace(tmp_path)
    manifest_path = target / "migration" / "fullstack-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["parity"]["browser"] = [
        item
        for item in manifest["parity"]["browser"]
        if item["kind"] != "submit_denied"
    ]
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    result = graded(target, tmp_path / "artifacts", monkeypatch)
    assert result.completion is False
    assert any(
        failure.code == "completion.manifest_drift" for failure in result.failures
    )


def test_completion_drift_with_clean_doctor_has_no_doctor_failure(
    tmp_path, monkeypatch
):
    target = workspace(tmp_path)
    manifest_path = target / "migration/fullstack-manifest.json"
    manifest_path.write_text("{}\n", encoding="utf-8")

    result = graded(target, tmp_path / "artifacts", monkeypatch)

    assert result.completion is False
    assert result.rules_locked is False
    assert "completion.manifest_drift" in {failure.code for failure in result.failures}
    assert not any(
        failure.code.startswith("rules.doctor") for failure in result.failures
    )


def test_canonical_manifest_is_read_once(tmp_path, monkeypatch):
    target = workspace(tmp_path)
    manifest_path = target / "migration/fullstack-manifest.json"
    original = _harness.read_bounded_regular
    reads = 0

    def read_bytes(path, maximum):  # noqa: ANN001
        nonlocal reads
        if path == manifest_path:
            reads += 1
        return original(path, maximum)

    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.read_bounded_regular", read_bytes
    )

    inspect_completion(target)

    assert reads == 1


def test_manifest_read_errors_are_structured(tmp_path, monkeypatch):
    target = workspace(tmp_path)
    manifest_path = target / "migration/fullstack-manifest.json"
    original = _harness.read_bounded_regular

    def read_bytes(path, maximum):  # noqa: ANN001
        if path == manifest_path:
            raise PermissionError("manifest denied")
        return original(path, maximum)

    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.read_bounded_regular", read_bytes
    )

    with pytest.raises(GradeFailure) as raised:
        inspect_completion(target)
    assert raised.value.code == "completion.manifest.invalid"


def test_missing_browser_kind_remains_an_independent_grader_constraint(
    tmp_path, monkeypatch
):
    target = tmp_path / "workspace"
    migration = target / "migration"
    migration.mkdir(parents=True)
    manifest = {
        "parity": {
            "browser": [{"kind": kind} for kind in REQUIRED_BROWSER_KINDS - {"asset"}]
        }
    }
    write_canonical(migration / "fullstack-manifest.json", manifest)
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.verify_source", lambda source: None
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack._expected_manifest",
        lambda workspace_path, source=None: manifest,
    )

    with pytest.raises(GradeFailure) as raised:
        inspect_completion(target)
    assert raised.value.code == "tests.browser"
    assert "asset" in str(raised.value)


def test_generated_browser_runner_is_executed(tmp_path, monkeypatch):
    commands = FakeCommands()
    result = graded(workspace(tmp_path), tmp_path / "artifacts", monkeypatch, commands)
    assert result.tests_green is True
    assert any(
        str(arg).endswith("journey_playwright.py")
        for call in commands.calls
        for arg in call
    )


def _executable(path: Path, text: str = "") -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return str(path)


def test_binary_resolution_cannot_switch_to_a_workspace_relative_collision(
    tmp_path, monkeypatch
):
    host = tmp_path / "host"
    workspace_path = tmp_path / "workspace"
    host.mkdir()
    workspace_path.mkdir()
    trusted = _executable(host / "bin/zigbase")
    untrusted = _executable(workspace_path / "bin/zigbase")
    monkeypatch.chdir(host)

    assert _binary("bin/zigbase") == str(Path(trusted).resolve())
    assert _binary("bin/zigbase") != str(Path(untrusted).resolve())


def test_binary_symlink_is_resolved_once_to_its_regular_executable(tmp_path):
    trusted = Path(_executable(tmp_path / "trusted-zigbase"))
    link = tmp_path / "zigbase-link"
    link.symlink_to(trusted)

    assert _binary(str(link)) == str(trusted.resolve())


@pytest.mark.parametrize("name", [".home", ".tmp"])
def test_fullstack_rehearsal_refuses_non_directory_scratch_before_commands(
    tmp_path, name
):
    target = tmp_path / "workspace"
    target.mkdir()
    unsafe = target / name
    unsafe.write_text("not a directory", encoding="utf-8")
    commands = FakeCommands()

    green, doctor, credentials, failures = run_rehearsal(
        target, commands, binary_path=sys.executable
    )

    assert green is False and doctor is None and credentials is None
    assert [failure.code for failure in failures] == ["environment.scratch_unsafe"]
    assert commands.calls == []


def test_playwright_relative_candidate_cannot_switch_at_workspace_cwd(
    tmp_path, monkeypatch
):
    host = tmp_path / "host"
    workspace_path = tmp_path / "workspace"
    host.mkdir()
    workspace_path.mkdir()
    trusted = _executable(host / "bin/python")
    untrusted = _executable(workspace_path / "bin/python")
    monkeypatch.chdir(host)
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.sys.executable", str(host / "missing")
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.shutil.which", lambda _name: None
    )

    class CollisionCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            self.calls.append(argv)
            return CommandResult(0, "zigbase-playwright-import-ok\n")

    commands = CollisionCommands()
    selected = _python_with_playwright(commands, workspace_path, "bin/python")

    assert selected == str(Path(trusted).resolve())
    assert selected != str(Path(untrusted).resolve())
    assert commands.calls[0][0] == str(Path(trusted).resolve())


def test_playwright_python_resolves_an_env_shebang(tmp_path, monkeypatch):
    interpreter = _executable(tmp_path / "python3")
    launcher = _executable(tmp_path / "playwright", "#!/usr/bin/env python3\n")
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.sys.executable", str(tmp_path / "missing")
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.shutil.which",
        lambda name: {"playwright": launcher, "python3": interpreter}.get(name),
    )
    commands = FakeCommands()

    assert _python_with_playwright(commands, tmp_path) == interpreter


def test_playwright_shebang_probe_rejects_an_oversized_launcher(tmp_path):
    launcher = _executable(tmp_path / "playwright")
    launcher_path = Path(launcher)
    launcher_path.write_bytes(b"ELF" + b"x" * 4096)

    assert _shebang_interpreter(launcher) is None


def test_playwright_shebang_probe_only_reads_the_bounded_first_line(
    tmp_path, monkeypatch
):
    interpreter = _executable(tmp_path / "python3")
    launcher = _executable(
        tmp_path / "playwright", "#!/usr/bin/env python3\n" + "x" * 100_000
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.shutil.which",
        lambda name: interpreter if name == "python3" else None,
    )

    assert _shebang_interpreter(launcher) == interpreter


def test_playwright_python_never_executes_an_arbitrary_shebang(tmp_path, monkeypatch):
    shell = _executable(tmp_path / "shell")
    launcher = _executable(tmp_path / "playwright", f"#!{shell}\n")
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.sys.executable", str(tmp_path / "missing")
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.shutil.which",
        lambda name: launcher if name == "playwright" else None,
    )
    commands = FakeCommands()

    with pytest.raises(GradeFailure) as raised:
        _python_with_playwright(commands, tmp_path)
    assert raised.value.code == "environment.playwright_missing"
    assert commands.calls == []


def test_playwright_python_rejects_a_non_python_shim_and_uses_system_python(
    tmp_path, monkeypatch
):
    shim = _executable(tmp_path / "shim")
    system_python = _executable(tmp_path / "python")
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.sys.executable", system_python
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.shutil.which", lambda name: None
    )

    class InterpreterCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            self.calls.append(argv)
            return CommandResult(
                0,
                "zigbase-playwright-import-ok\n" if argv[0] == system_python else "",
            )

    assert (
        _python_with_playwright(InterpreterCommands(), tmp_path, shim) == system_python
    )


def test_playwright_python_reports_missing_module_as_environment_failure(
    tmp_path, monkeypatch
):
    configured = _executable(tmp_path / "configured-python")
    system_python = _executable(tmp_path / "system-python")
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.sys.executable", system_python
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.shutil.which", lambda name: None
    )

    class MissingModuleCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            self.calls.append(argv)
            return CommandResult(1, stderr="No module named playwright")

    with pytest.raises(GradeFailure) as raised:
        _python_with_playwright(MissingModuleCommands(), tmp_path, configured)
    assert raised.value.code == "environment.playwright_missing"


@pytest.mark.parametrize(
    ("dry_run", "expected_code"),
    [
        (True, "rehearsal.schema_dry_run"),
        (False, "rehearsal.schema_apply"),
    ],
)
def test_schema_dry_run_and_apply_failures_are_distinct(
    tmp_path, dry_run, expected_code
):
    target = tmp_path / "workspace"
    target.mkdir()
    tests_green, doctor, credentials, failures = run_rehearsal(
        target,
        FailingSchemaCommands(dry_run=dry_run),
        binary_path=sys.executable,
    )

    assert tests_green is False
    assert doctor is None
    assert credentials is None
    assert [failure.code for failure in failures] == [expected_code]


def test_schema_dry_run_must_report_the_expected_plan(tmp_path):
    target = tmp_path / "workspace"
    target.mkdir()

    class MissingPlanCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            if "schema" in argv and "--dry-run" in argv:
                return CommandResult(0, "{}")
            return super().run(argv, cwd=cwd, env=env, timeout=timeout)

    tests_green, doctor, credentials, failures = run_rehearsal(
        target,
        MissingPlanCommands(),
        binary_path=sys.executable,
    )

    assert tests_green is False
    assert doctor is None
    assert credentials is None
    assert [failure.code for failure in failures] == ["rehearsal.schema_dry_run_plan"]


def test_cutover_and_rollback_both_boot_a_target(tmp_path, monkeypatch):
    commands = FakeCommands()
    result = graded(workspace(tmp_path), tmp_path / "artifacts", monkeypatch, commands)
    starts = [
        call for call in commands.calls if "serve" in call and "--background" in call
    ]
    assert result.deployed is True
    assert len(starts) == 4
    assert any("restored" in arg for call in starts for arg in call)


def test_binary_missing_cannot_claim_rules_locked_or_repeat_the_failure(
    tmp_path, monkeypatch
):
    target = tmp_path / "workspace"
    target.mkdir()
    monkeypatch.delenv("ZIGBASE_EVAL_BINARY", raising=False)
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.inspect_completion",
        lambda workspace_path, **kwargs: ({}, EXPECTED_PUBLIC),
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.verify_source", lambda source: {}
    )

    result = grade(
        target,
        tmp_path / "artifacts",
        commands=FakeCommands(),
        binary_path=None,
    )

    codes = [failure.code for failure in result.failures]
    assert result.completion is True
    assert result.rules_locked is False
    assert result.tests_green is False
    assert result.deployed is False
    assert codes.count("rehearsal.binary_missing") == 1
    assert codes.count("rules.doctor_skipped") == 1
    assert "deployment.no_target" not in codes


def test_failed_regrade_cannot_restore_stale_rehearsal_state(tmp_path, monkeypatch):
    target = tmp_path / "workspace"
    source_dir = target / "source"
    source_dir.mkdir(parents=True)
    (source_dir / "presentation.handoff.json").write_text(
        '{"parity":[]}\n', encoding="utf-8"
    )
    stale = target / ".rehearsal"
    (stale / "data").mkdir(parents=True)
    (stale / "data/data.db").write_bytes(b"stale database")
    (stale / "restore-probe.json").write_text(
        '{"email":"stale@example.invalid","password":"stale"}\n',
        encoding="utf-8",
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.inspect_completion",
        lambda workspace_path, **kwargs: ({}, EXPECTED_PUBLIC),
    )
    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.verify_source",
        lambda source: {
            Path("presentation.handoff.json"): (
                source / "presentation.handoff.json"
            ).read_bytes()
        },
    )

    def fail_fresh_parity(*args, **kwargs):  # noqa: ANN002, ANN003
        raise GradeFailure("tests.fresh_parity", "fresh parity failed")

    commands = FakeCommands()
    second = grade(
        target,
        tmp_path / "second-artifacts",
        commands=commands,
        binary_path=sys.executable,
        port_picker=iter(range(43000, 43020)).__next__,
        health_getter=lambda *args, **kwargs: {},
        parity_probe=fail_fresh_parity,
        backend_probe=lambda *args, **kwargs: None,
        playwright_python=__file__,
    )

    starts = [
        call for call in commands.calls if "serve" in call and "--background" in call
    ]
    stops = [call for call in commands.calls if call[1:3] == ["serve", "stop"]]
    assert second.completion is True and second.rules_locked is True
    assert second.tests_green is False and second.deployed is False
    assert [failure.code for failure in second.failures] == ["tests.fresh_parity"]
    assert len(starts) == 1
    assert len(stops) == 1
    assert not (target / ".rehearsal/restore-probe.json").exists()


def test_teardown_failure_is_structured_and_sinks_live_grade(tmp_path, monkeypatch):
    target = workspace(tmp_path)
    credential_path = target / ".rehearsal/restore-probe.json"

    class StopFailureCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            assert not credential_path.exists()
            if argv[1:3] == ["serve", "stop"]:
                self.calls.append(argv)
                return CommandResult(1, stderr="stop failed")
            return super().run(argv, cwd=cwd, env=env, timeout=timeout)

    result = graded(
        target,
        tmp_path / "artifacts",
        monkeypatch,
        StopFailureCommands(),
    )

    assert result.tests_green is False
    assert result.deployed is False
    assert "rehearsal.teardown" in {failure.code for failure in result.failures}
    assert not credential_path.exists()


def test_restore_stop_failure_is_attributed_to_deployment(tmp_path, monkeypatch):
    target = tmp_path / "workspace"
    shutil.copytree(SCENARIO / "fixture", target)
    rehearsal_data = target / ".rehearsal/data"
    rehearsal_data.mkdir(parents=True)
    (rehearsal_data / "data.db").touch()

    class StopFailureCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            if argv[1:3] == ["serve", "stop"]:
                self.calls.append(argv)
                return CommandResult(1, stderr="stop failed")
            return super().run(argv, cwd=cwd, env=env, timeout=timeout)

    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if url.endswith("auth-with-password"):
            payload = b'{"token":"restored"}'
        elif url.endswith("/records/post-id"):
            payload = b'{"id":"post-id","title":"persisted title"}'
        else:
            payload = b'{"items":[{"id":"post-id","title":"persisted title"}]}'
        return 200, payload, "application/json"

    monkeypatch.setattr("evals.agents.graders.rails_fullstack._request", request)
    deployed, failures = run_restore(
        target,
        StopFailureCommands(),
        persisted_state(),
        binary_path=sys.executable,
        port_picker=lambda: 44000,
        health_getter=lambda *args, **kwargs: {},
    )

    assert deployed is False
    assert [failure.code for failure in failures] == ["deployment.teardown"]


@pytest.mark.parametrize("drift", ["missing-record", "empty-list", "wrong-title"])
def test_switched_target_requires_the_same_persisted_post(monkeypatch, drift):
    state = persisted_state()

    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"restored"}', "application/json"
        if url.endswith("/records/post-id"):
            if drift == "missing-record":
                return 404, b'{"code":"not_found"}', "application/json"
            title = "changed" if drift == "wrong-title" else state.post_title
            return (
                200,
                json.dumps({"id": state.post_id, "title": title}).encode(),
                "application/json",
            )
        items = (
            []
            if drift == "empty-list"
            else [{"id": state.post_id, "title": state.post_title}]
        )
        return 200, json.dumps({"items": items}).encode(), "application/json"

    monkeypatch.setattr("evals.agents.graders.rails_fullstack._request", request)
    with pytest.raises(GradeFailure, match="preserve post|does not contain"):
        _probe_switched_target("http://target", state, "restart")


def test_failed_start_still_attempts_stop(tmp_path):
    target = tmp_path / "workspace"
    shutil.copytree(SCENARIO / "fixture", target)

    class StartFailureCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            if "serve" in argv and "--background" in argv:
                self.calls.append(argv)
                return CommandResult(9, stderr="start failed")
            return super().run(argv, cwd=cwd, env=env, timeout=timeout)

    commands = StartFailureCommands()
    passed, _, _, failures = run_rehearsal(
        target,
        commands,
        binary_path=sys.executable,
        port_picker=lambda: 44001,
        playwright_python=__file__,
    )

    assert passed is False
    assert [failure.code for failure in failures] == ["rehearsal.serve"]
    assert len([call for call in commands.calls if "--background" in call]) == 1
    assert len([call for call in commands.calls if call[1:3] == ["serve", "stop"]]) == 1


def test_start_and_stop_exceptions_are_both_structured(tmp_path):
    target = tmp_path / "workspace"
    shutil.copytree(SCENARIO / "fixture", target)

    class ExplodingLifecycleCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            if "serve" in argv and "--background" in argv:
                self.calls.append(argv)
                raise RuntimeError("start exploded")
            if argv[1:3] == ["serve", "stop"]:
                self.calls.append(argv)
                raise OSError("stop exploded")
            return super().run(argv, cwd=cwd, env=env, timeout=timeout)

    commands = ExplodingLifecycleCommands()
    passed, _, _, failures = run_rehearsal(
        target,
        commands,
        binary_path=sys.executable,
        port_picker=lambda: 44002,
        playwright_python=__file__,
    )

    assert passed is False
    assert [failure.code for failure in failures] == [
        "rehearsal.teardown",
        "rehearsal.error",
    ]
    assert "OSError: stop exploded" in failures[0].message
    assert "RuntimeError: start exploded" in failures[1].message
    assert len([call for call in commands.calls if "--background" in call]) == 1
    assert len([call for call in commands.calls if call[1:3] == ["serve", "stop"]]) == 1


def test_rehearsal_replaces_a_stale_regular_file(tmp_path):
    target = workspace(tmp_path)
    stale = target / ".rehearsal"
    stale.write_text("stale\n")

    tests_green, _, credentials, failures = run_rehearsal(
        target,
        FakeCommands(),
        binary_path=sys.executable,
        port_picker=iter(range(42000, 42010)).__next__,
        health_getter=lambda *args, **kwargs: {},
        parity_probe=lambda *args, **kwargs: persisted_state(),
        backend_probe=lambda *args, **kwargs: None,
        persistence_probe=lambda *args, **kwargs: None,
        playwright_python=__file__,
    )

    assert tests_green is True
    assert credentials == persisted_state()
    assert failures == []
    assert stale.is_dir()


def test_rehearsal_cleanup_failure_is_precise_and_stops_the_run(tmp_path, monkeypatch):
    target = tmp_path / "workspace"
    stale = target / ".rehearsal"
    stale.mkdir(parents=True)
    (stale / "data.db").write_bytes(b"must not be trusted")
    commands = FakeCommands()

    def refuse_cleanup(path):  # noqa: ANN001
        assert path == stale
        raise PermissionError("fixture denies removal")

    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.shutil.rmtree", refuse_cleanup
    )
    passed, doctor, credentials, failures = run_rehearsal(
        target,
        commands,
        binary_path=sys.executable,
    )

    assert passed is False and doctor is None
    assert credentials is None
    assert [(failure.code, failure.message) for failure in failures] == [
        (
            "rehearsal.cleanup",
            f"cannot clear stale rehearsal state at {stale}: fixture denies removal",
        )
    ]
    assert commands.calls == []
    assert (stale / "data.db").read_bytes() == b"must not be trusted"


def test_untrusted_source_prevents_every_rehearsal_command(tmp_path):
    target = tmp_path / "workspace"
    shutil.copytree(SCENARIO / "fixture", target)
    (target / "source/backend-capture.ndjson").write_text("mutated\n")
    commands = FakeCommands()

    result = grade(
        target,
        tmp_path / "artifacts",
        commands=commands,
        binary_path=sys.executable,
    )

    assert result.completion is False
    assert result.tests_green is False
    assert result.deployed is False
    assert [failure.code for failure in result.failures] == ["source.changed"]
    assert commands.calls == []


def test_source_read_errors_are_structured_and_prevent_execution(tmp_path, monkeypatch):
    target = tmp_path / "workspace"
    shutil.copytree(SCENARIO / "fixture", target)
    blocked = target / "source/backend-capture.ndjson"
    original = _harness.read_bounded_regular

    def read_bytes(path, maximum):  # noqa: ANN001
        if path == blocked:
            raise PermissionError("source denied")
        return original(path, maximum)

    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack.read_bounded_regular", read_bytes
    )
    commands = FakeCommands()
    result = grade(target, tmp_path / "artifacts", commands=commands)

    assert [failure.code for failure in result.failures] == ["source.unreadable"]
    assert commands.calls == []


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        (b"\xff\n", "not UTF-8"),
        (b'{"id":"case","value":NaN}\n', "not JSON"),
        (b"[]\n", "must be a JSON object"),
    ],
    ids=["invalid-utf8", "non-finite-number", "non-object-row"],
)
def test_grader_ndjson_uses_the_strict_coordinator_reader(tmp_path, payload, message):
    path = tmp_path / "capture.ndjson"
    path.write_bytes(payload)

    with pytest.raises(GradeFailure, match=message) as raised:
        _capture(path, "tests.backend_capture")
    assert raised.value.code == "tests.backend_capture.invalid"


def test_grader_ndjson_rejects_oversized_input(tmp_path, monkeypatch):
    path = tmp_path / "capture.ndjson"
    path.write_text(
        '{"id":"case","method":"GET","path":"/records"}\n',
        encoding="utf-8",
    )
    monkeypatch.setattr("tools.replay.zb_replay.MAX_CAPTURE_BYTES", 8)

    with pytest.raises(GradeFailure, match="exceeds the 8-byte limit") as raised:
        _capture(path, "tests.backend_capture")
    assert raised.value.code == "tests.backend_capture.invalid"


def test_grader_ndjson_rejects_duplicate_case_ids(tmp_path):
    path = tmp_path / "capture.ndjson"
    path.write_text(
        '{"id":"same","method":"GET","path":"/records"}\n'
        '{"id":"same","method":"GET","path":"/records"}\n',
        encoding="utf-8",
    )

    with pytest.raises(GradeFailure, match="duplicate case id 'same'") as raised:
        _capture(path, "tests.backend_capture")
    assert raised.value.code == "tests.backend_capture.invalid"


def test_grader_capture_rejects_status_incompatible_control(tmp_path):
    path = tmp_path / "capture.ndjson"
    path.write_text(
        json.dumps(
            {
                "id": "impossible",
                "method": "GET",
                "path": "/records",
                "expect": {"status": 200, "control": "denied"},
            }
        )
        + "\n",
        encoding="utf-8",
    )

    with pytest.raises(GradeFailure, match="incompatible") as raised:
        _capture(path, "tests.backend_capture")
    assert raised.value.code == "tests.backend_capture.invalid"


def typed_handoff():
    handoff = json.loads(
        (SCENARIO / "fixture/source/presentation.handoff.json").read_text()
    )
    return {
        "parity": [
            row for row in handoff["parity"] if row["kind"] not in {"navigate", "asset"}
        ]
    }


def test_live_signup_requires_the_producer_status():
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        return 200, b"{}", "application/json"

    with pytest.raises(GradeFailure, match="signup returned 200"):
        probe_parity("http://target", typed_handoff(), http_request=request)


@pytest.mark.parametrize(
    "kind",
    ["signup", "signin", "submit_allowed", "submit_denied", "validation_error"],
)
def test_live_parity_requires_one_stateful_check_per_kind(kind):
    handoff = typed_handoff()
    duplicate = next(row for row in handoff["parity"] if row["kind"] == kind).copy()
    duplicate["id"] += "-duplicate"
    handoff["parity"].append(duplicate)

    with pytest.raises(GradeFailure, match=f"exactly one {kind}"):
        probe_parity(
            "http://target",
            handoff,
            http_request=lambda *_args, **_kwargs: pytest.fail("HTTP ran first"),
        )


def test_live_validation_requires_the_producer_status():
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if method == "GET" and url.endswith("/posts/records"):
            return 200, b'{"items":[]}', "application/json"
        if url.endswith("/records") and "passwordConfirm" in kwargs.get("body", {}):
            return 201, b"{}", "application/json"
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"token"}', "application/json"
        if kwargs.get("token") and kwargs.get("body", {}).get("title") == "":
            return 422, b"{}", "application/json"
        return 403, b"{}", "application/json"

    with pytest.raises(GradeFailure, match="invalid create returned 422"):
        probe_parity("http://target", typed_handoff(), http_request=request)


def test_navigation_http_probe_checks_status_and_content_type_only():
    handoff = typed_handoff()
    handoff["parity"].insert(
        0,
        {
            "id": "navigate",
            "kind": "navigate",
            "url": "/page",
            "expect": {
                "status": 200,
                "title": "Posts & notes",
                "h1": "Posts today",
                "links": ["/real"],
            },
        },
    )

    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if method == "GET" and url.endswith("/posts/records"):
            return 200, b'{"items":[]}', "application/json"
        if method == "GET":
            return (
                200,
                b'<title class="page">Posts &amp; notes</title>'
                b'<h1 class="page">Posts <em>today</em></h1>'
                b'<!-- href="/fake" --><script>"href=/fake"</script>'
                b'<a data-id="1" href="/real">go</a>',
                "text/html; charset=utf-8",
            )
        body = kwargs.get("body", {})
        if url.endswith("/users/records"):
            return 201, b"{}", "application/json"
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"token"}', "application/json"
        if not kwargs.get("token"):
            return 403, b"{}", "application/json"
        if body.get("title") == "":
            return 400, b"{}", "application/json"
        return (
            201,
            b'{"id":"post-id","title":"zigapagos parity"}',
            "application/json",
        )

    # Browser-visible title, heading, and links belong to the Playwright journey;
    # the HTTP probe deliberately does not approximate a browser DOM/CSS engine.
    state = probe_parity("http://target", handoff, http_request=request)
    assert state.post_id == "post-id"

    def wrong_content_type(method, url, **kwargs):  # noqa: ANN001, ARG001
        status, payload, content_type = request(method, url, **kwargs)
        return status, payload, "application/json" if method == "GET" else content_type

    with pytest.raises(GradeFailure, match="not text/html"):
        probe_parity("http://target", handoff, http_request=wrong_content_type)


def test_generated_browser_runner_owns_visible_navigation_assertions():
    runner = (
        SCENARIO / "fixture/source/presentation-target/test/journey_playwright.py"
    ).read_text()
    assert 'r["kind"] == "navigate"' in runner
    assert "page.title()" in runner
    assert 'page.locator("h1:visible")' in runner
    assert 'page.locator("a:visible")' in runner


def test_asset_parity_requires_the_exact_normalized_media_type():
    handoff = typed_handoff()
    handoff["parity"].insert(
        0,
        {
            "id": "asset",
            "kind": "asset",
            "url": "/logo.png",
            "expect": {"status": 200, "content_type": "image/png"},
        },
    )

    with pytest.raises(GradeFailure, match="image/png-malformed"):
        probe_parity(
            "http://target",
            handoff,
            http_request=lambda *_args, **_kwargs: (
                200,
                b"not a png",
                "image/png-malformed",
            ),
        )


def test_denied_mutation_must_leave_collection_state_unchanged():
    records = [{"id": "existing", "title": "before"}]

    def request(method, url, **kwargs):  # noqa: ANN001
        if method == "GET" and url.endswith("/posts/records"):
            return 200, json.dumps({"items": records}).encode(), "application/json"
        if url.endswith("/users/records"):
            return 201, b"{}", "application/json"
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"token"}', "application/json"
        if (
            method == "POST"
            and url.endswith("/posts/records")
            and not kwargs.get("token")
        ):
            # Preserve the identity set while mutating durable state: an id-only
            # before/after assertion would miss this authorization failure.
            records[0]["title"] = "changed despite denial"
            return 403, b"{}", "application/json"
        pytest.fail(f"unexpected request: {method} {url}")

    with pytest.raises(GradeFailure, match="denied create changed") as raised:
        probe_parity("http://target", typed_handoff(), http_request=request)
    assert raised.value.code == "tests.denied_state"


def test_validation_failure_must_leave_collection_state_unchanged():
    records = [{"id": "existing", "title": "before"}]

    def request(method, url, **kwargs):  # noqa: ANN001
        if method == "GET" and url.endswith("/posts/records"):
            return 200, json.dumps({"items": records}).encode(), "application/json"
        if url.endswith("/users/records"):
            return 201, b"{}", "application/json"
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"token"}', "application/json"
        if (
            method == "POST"
            and url.endswith("/posts/records")
            and not kwargs.get("token")
        ):
            return 403, b"{}", "application/json"
        if kwargs.get("body", {}).get("title") == "":
            records[0]["title"] = "changed despite validation failure"
            return 400, b"{}", "application/json"
        pytest.fail(f"unexpected request: {method} {url}")

    with pytest.raises(GradeFailure, match="invalid create changed") as raised:
        probe_parity("http://target", typed_handoff(), http_request=request)
    assert raised.value.code == "tests.validation_state"


def test_live_backend_capture_requires_the_exact_status():
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"token"}', "application/json"
        return 200, b"{}", "application/json"

    capture = [
        {
            "id": "list-posts",
            "method": "GET",
            "path": "/api/collections/posts/records",
            "expect": {"status": 201},
        }
    ]
    with pytest.raises(GradeFailure, match='"expected": 201'):
        probe_backend_capture(
            "http://target",
            capture,
            ("user@example.invalid", "password"),
            http_request=request,
            send_case=lambda *args: (200, {}),
        )


def test_live_backend_capture_reports_body_diff_without_requiring_status():
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        return 200, b'{"token":"token"}', "application/json"

    capture = [
        {
            "id": "body",
            "method": "GET",
            "path": "/records",
            "expect": {"bodySubset": {"title": "expected"}},
        }
    ]
    with pytest.raises(GradeFailure, match="expected") as raised:
        probe_backend_capture(
            "http://target",
            capture,
            ("user@example.invalid", "password"),
            http_request=request,
            send_case=lambda *args: (200, {"title": "actual"}),
        )
    assert raised.value.code == "tests.backend_capture"


def test_live_backend_capture_accepts_a_null_expectation():
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"token"}', "application/json"
        return 204, b"", "application/json"

    probe_backend_capture(
        "http://target",
        [{"id": "health", "method": "GET", "path": "/api/health", "expect": None}],
        ("user@example.invalid", "password"),
        http_request=request,
        send_case=lambda *args: (204, None),
    )


def test_backend_capture_contains_unknown_placeholders():
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        return 200, b'{"token":"token"}', "application/json"

    capture = [
        {
            "id": "unknown-variable",
            "method": "GET",
            "path": "/records/{{unknown}}",
            "expect": {"status": 200, "control": "allowed"},
        }
    ]
    with pytest.raises(GradeFailure, match="unresolved placeholder") as raised:
        probe_backend_capture(
            "http://target",
            capture,
            ("user@example.invalid", "password"),
            http_request=request,
            send_case=lambda *args: pytest.fail("transport must not run"),
        )
    assert raised.value.code == "tests.backend_capture"


def test_backend_capture_leaves_unexpected_transport_errors_for_harness_containment():
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        return 200, b'{"token":"token"}', "application/json"

    capture = [
        {
            "id": "transport-bug",
            "method": "GET",
            "path": "/records",
            "expect": {"status": 200, "control": "allowed"},
        }
    ]

    def explode(*args):  # noqa: ANN002
        raise RuntimeError("transport exploded")

    with pytest.raises(RuntimeError, match="transport exploded"):
        probe_backend_capture(
            "http://target",
            capture,
            ("user@example.invalid", "password"),
            http_request=request,
            send_case=explode,
        )


def test_live_logout_is_anonymous_and_repeatable():
    logout_headers = []

    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"token"}', "application/json"
        raise AssertionError("capture requests must use the replay transport")

    def send_case(base, resolved, timeout):  # noqa: ANN001, ARG001
        logout_headers.append(resolved.get("headers", {}))
        return 204, None

    capture = [
        {
            "id": case_id,
            "method": "POST",
            "path": "/api/collections/users/auth-logout",
            "expect": {"status": 204, "control": "allowed"},
        }
        for case_id in ("logout-allowed", "logout-repeat")
    ]
    probe_backend_capture(
        "http://target",
        capture,
        ("user@example.invalid", "password"),
        http_request=request,
        send_case=send_case,
    )
    assert logout_headers == [{}, {}]


def test_backend_capture_uses_semantics_and_replay_transport_not_ids_or_order(
    monkeypatch,
):
    sent = []
    substitutions = []
    substitute = zb_replay.substitute

    def substitute_once(case, variables):  # noqa: ANN001
        if isinstance(case, dict) and "id" in case and "method" in case:
            substitutions.append(case["id"])
        return substitute(case, variables)

    monkeypatch.setattr(zb_replay, "substitute", substitute_once)

    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        assert url.endswith("auth-with-password")
        return 200, b'{"token":"setup-token"}', "application/json"

    def send_case(base, resolved, timeout):  # noqa: ANN001, ARG001
        sent.append(resolved)
        path = resolved["path"]
        control = resolved["expect"].get("control")
        if path == "/api/collections/users/records":
            assert resolved["body"]["email"].startswith("capture+")
            assert resolved["body"]["passwordConfirm"] == resolved["body"]["password"]
            return 201, {"id": "user-id"}
        if path == "/api/collections/posts/records" and resolved["method"] == "POST":
            return 201, {"id": "record-id"}
        if path == "/api/collections/users/auth-with-password":
            assert resolved["body"]["identity"].startswith("capture+")
            if control == "denied":
                assert resolved["body"]["password"] == "wrong-password"
                return 400, {}
            assert resolved["body"]["password"].startswith("capture-")
            return 200, {"token": "capture-token"}
        assert path == "/api/collections/posts/records/record-id"
        assert resolved["query"] == {"expand": "author"}
        assert resolved["headers"]["X-Probe"] == "kept"
        return 200, {"id": "record-id"}

    capture = [
        {
            "id": "renamed-view",
            "method": "GET",
            "path": "/api/collections/posts/records/{{id}}",
            "query": {"expand": "author"},
            "headers": {"X-Probe": "kept"},
            "expect": {"status": 200, "control": "allowed"},
        },
        {
            "id": "renamed-signin-denial",
            "method": "POST",
            "path": "/api/collections/users/auth-with-password",
            "expect": {"status": 400, "control": "denied"},
        },
        {
            "id": "renamed-signin-success",
            "method": "POST",
            "path": "/api/collections/users/auth-with-password",
            "expect": {"status": 200, "control": "allowed"},
        },
        {
            "id": "renamed-signup",
            "method": "POST",
            "path": "/api/collections/users/records",
            "expect": {"status": 201, "control": "allowed"},
        },
        {
            "id": "renamed-create",
            "method": "POST",
            "path": "/api/collections/posts/records",
            "expect": {"status": 201, "control": "allowed"},
        },
    ]

    probe_backend_capture(
        "http://target",
        capture,
        ("user@example.invalid", "password"),
        http_request=request,
        send_case=send_case,
    )

    assert sent[-1]["id"] == "renamed-view"
    assert sorted(substitutions) == sorted(case["id"] for case in capture)


def test_live_failure_sinks_tests_grade(tmp_path, monkeypatch):
    target = workspace(tmp_path)

    def fail_probe(*args, **kwargs):  # noqa: ANN002, ANN003
        raise ValueError("live target mismatch")

    monkeypatch.setattr("evals.agents.graders.rails_fullstack.probe_parity", fail_probe)
    result = grade(
        target,
        tmp_path / "artifacts",
        commands=FakeCommands(),
        binary_path=sys.executable,
        port_picker=iter(range(42000, 42020)).__next__,
        health_getter=lambda *args, **kwargs: {},
        parity_probe=fail_probe,
        backend_probe=lambda *args, **kwargs: None,
        playwright_python=__file__,
    )
    assert result.tests_green is False
    assert "rehearsal.error" in {failure.code for failure in result.failures}
