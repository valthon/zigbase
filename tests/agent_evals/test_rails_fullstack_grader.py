"""Deterministic positive and negative controls for the Rails full-stack eval."""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from evals.agents.graders.genesis import CommandResult
from evals.agents.graders.genesis import GradeFailure
from evals.agents.graders.rails_fullstack import (
    EXPECTED_PUBLIC,
    EXPECTED_UNSUPPORTED,
    REQUIRED_BROWSER_KINDS,
    _ndjson,
    _report,
    grade,
    inspect_completion,
    probe_backend_capture,
    probe_parity,
    run_rehearsal,
    verify_source,
)
from evals.agents.scenario import AgentScenario
from tools.rails.fullstack import reconcile, write_canonical
from tools.replay import zb_replay


REPO = Path(__file__).resolve().parents[2]
SCENARIO = REPO / "evals" / "agents" / "scenarios" / "rails-fullstack"
CHECKS = [
    "contracts",
    "route-map",
    "backend-parity",
    "browser-parity",
    "authorization",
    "doctor",
    "restart",
    "restore",
    "rollback",
    "cutover",
]


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
                "backend_operation_id": values.pop("operation", None),
                "auth": values.pop("auth", "public"),
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
            parity=[
                {"kind": "browser", "id": f"navigate:GET {path}", "control": "journey"}
            ],
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
        operation="listPosts",
        parity=[{"kind": "backend", "id": "list-posts", "control": "allowed"}],
    )
    add(
        "POST",
        "/posts",
        "posts",
        "create",
        operation="createPosts",
        auth="conditional",
        parity=[
            {
                "kind": "browser",
                "id": "submit_allowed:createPosts",
                "control": "allowed",
            },
            {"kind": "browser", "id": "submit_denied:createPosts", "control": "denied"},
            {
                "kind": "browser",
                "id": "validation_error:createPosts:title",
                "control": "validation",
            },
            {"kind": "backend", "id": "create-post-allowed", "control": "allowed"},
            {"kind": "backend", "id": "create-post-denied", "control": "denied"},
            {"kind": "backend", "id": "create-post-invalid", "control": "validation"},
        ],
    )
    add(
        "POST",
        "/registration",
        "registrations",
        "create",
        operation="createUsers",
        parity=[
            {"kind": "browser", "id": "signup:users", "control": "allowed"},
            {"kind": "backend", "id": "signup-user", "control": "allowed"},
        ],
    )
    add(
        "DELETE",
        "/session",
        "sessions",
        "destroy",
        surface="api",
        operation="logout",
        method_transform={
            "from": "DELETE",
            "to": "POST",
            "rationale": "ZigBase logout is exposed as an idempotent POST operation.",
        },
        parity=[
            {"kind": "backend", "id": "logout-allowed", "control": "allowed"},
            {"kind": "backend", "id": "logout-repeat", "control": "allowed"},
        ],
    )
    add(
        "POST",
        "/session",
        "sessions",
        "create",
        operation="authWithPassword",
        parity=[
            {"kind": "browser", "id": "signin:users", "control": "allowed"},
            {"kind": "backend", "id": "signin-user", "control": "allowed"},
            {"kind": "backend", "id": "signin-denied", "control": "denied"},
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
        source_dir / "backend-replay.json",
        source_dir / "backend-findings.ndjson",
        source_dir / "backend-capture.ndjson",
    )
    write_canonical(migration / "fullstack-manifest.json", manifest)
    evidence = json.loads((source_dir / "backend-evidence.json").read_text())
    report = {
        "zigbaseRailsFullstackReport": 1,
        "source": "source",
        "manifest": "migration/fullstack-manifest.json",
        "unresolved": [],
        "checks": CHECKS,
        "sameOrigin": True,
        "reviewedPublicRules": ["posts.list", "posts.view", "users.create"],
        "doctorErrors": 0,
        "doctorWarnings": ["posts.listRule", "posts.viewRule", "users.createRule"],
        "restart": evidence["restart"],
        "restore": evidence["restore"],
        "rollback": evidence["rollback"],
        "cutover": evidence["cutover"],
        "unsupported": EXPECTED_UNSUPPORTED,
    }
    (migration / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return target


class FakeCommands:
    def __init__(self):
        self.calls = []

    def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
        self.calls.append(argv)
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


def graded(target: Path, artifacts: Path, monkeypatch, commands=None):  # noqa: ANN001
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        payload = (
            b'{"token":"restored"}' if url.endswith("auth-with-password") else b"{}"
        )
        return 200, payload, "text/html"

    monkeypatch.setattr(
        "evals.agents.graders.rails_fullstack._request",
        request,
    )
    return grade(
        target,
        artifacts,
        commands=commands or FakeCommands(),
        binary_path=__file__,
        port_picker=iter(range(41000, 41020)).__next__,
        health_getter=lambda *args, **kwargs: {},
        parity_probe=lambda *args, **kwargs: ("restore@example.invalid", "password"),
        backend_probe=lambda *args, **kwargs: None,
        playwright_python=__file__,
    )


def test_scenario_loads_and_uses_only_the_fullstack_skill():
    scenario = AgentScenario.load(SCENARIO / "scenario.json")
    assert scenario.name == "rails-fullstack"
    assert scenario.skills == ("zigbase-migrate-rails-fullstack",)
    assert scenario.graders == ("rails-fullstack",)


def test_scenario_tool_is_the_exact_coordinator_shipped_by_the_repository():
    for relative in (
        Path("fullstack.py"),
        Path("_core.py"),
        Path("__init__.py"),
        Path("contracts/rails-handoff.v1.schema.json"),
        Path("contracts/rails-presentation.v1.schema.json"),
    ):
        assert (SCENARIO / "fixture" / "tools" / "rails" / relative).read_bytes() == (
            REPO / "tools" / "rails" / relative
        ).read_bytes()


def test_scenario_pins_the_shared_replay_contract_and_package_boundary():
    fixture_replay = SCENARIO / "fixture" / "tools" / "replay"
    assert (fixture_replay / "_contract.py").read_bytes() == (
        REPO / "tools" / "replay" / "_contract.py"
    ).read_bytes()
    assert (fixture_replay / "__init__.py").read_bytes() == (
        b'"""Replay contract helpers vendored for the pinned full-stack evaluation."""\n'
    )


def test_prompt_names_every_boundary_the_grader_enforces():
    prompt = " ".join((SCENARIO / "prompt.md").read_text().lower().split())
    for marker in (
        "leave `source/` byte-for-byte unchanged",
        "zigbaserailsfullstackdecisions",
        "zigbaserailsfullstackreport",
        "run it twice",
        "protected post/patch behavior",
        "allowed and denied",
        "reviewedpublicrules",
        "sameorigin",
        "restart",
        "restore",
        "rollback",
        "cutover",
        "rails_component_vue_unsupported",
    ):
        assert marker in prompt


def test_positive_workspace_scores_four(tmp_path, monkeypatch):
    report = graded(workspace(tmp_path), tmp_path / "artifacts", monkeypatch)
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


def test_unreviewed_public_rule_fails_rules_grade(tmp_path, monkeypatch):
    target = workspace(tmp_path)
    path = target / "migration" / "report.json"
    report = json.loads(path.read_text())
    report["reviewedPublicRules"].append("posts.create")
    path.write_text(json.dumps(report))
    result = graded(target, tmp_path / "artifacts", monkeypatch)
    assert result.completion is False


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


@pytest.mark.parametrize(
    "checks",
    [
        {check: True for check in CHECKS},
        [*CHECKS, 7],
        CHECKS[:-1],
    ],
    ids=["object", "non-string-entry", "missing-required-check"],
)
def test_report_checks_must_be_a_string_array_containing_every_required_check(
    tmp_path, checks
):
    target = workspace(tmp_path)
    path = target / "migration/report.json"
    report = json.loads(path.read_text(encoding="utf-8"))
    report["checks"] = checks
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    with pytest.raises(GradeFailure) as raised:
        _report(target)
    assert raised.value.code == "completion.report_claims"


def test_report_checks_may_name_additional_completed_checks(tmp_path):
    target = workspace(tmp_path)
    path = target / "migration/report.json"
    report = json.loads(path.read_text(encoding="utf-8"))
    report["checks"].append("playwright")
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    assert _report(target)["checks"] == [*CHECKS, "playwright"]


@pytest.mark.parametrize("field", ["restart", "restore", "rollback", "cutover"])
@pytest.mark.parametrize("value", [None, False, 0, [], {}, "", "   "])
def test_report_evidence_fields_require_non_empty_strings(tmp_path, field, value):
    target = workspace(tmp_path)
    path = target / "migration/report.json"
    report = json.loads(path.read_text(encoding="utf-8"))
    report[field] = value
    path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    with pytest.raises(GradeFailure) as raised:
        _report(target)
    assert raised.value.code == "completion.report_claims"


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
        lambda workspace_path: manifest,
    )

    with pytest.raises(GradeFailure) as raised:
        inspect_completion(target)
    assert raised.value.code == "tests.browser"
    assert "asset" in str(raised.value)


def test_report_text_cannot_replace_live_restore(tmp_path, monkeypatch):
    target = workspace(tmp_path)
    path = target / "migration" / "report.json"
    report = json.loads(path.read_text())
    report["restore"] = "trust me"
    path.write_text(json.dumps(report))
    result = graded(target, tmp_path / "artifacts", monkeypatch)
    assert result.completion is True and result.deployed is True


def test_generated_browser_runner_is_executed(tmp_path, monkeypatch):
    commands = FakeCommands()
    result = graded(workspace(tmp_path), tmp_path / "artifacts", monkeypatch, commands)
    assert result.tests_green is True
    assert any(
        str(arg).endswith("journey_playwright.py")
        for call in commands.calls
        for arg in call
    )


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
    tests_green, doctor, failures = run_rehearsal(
        target,
        tmp_path / "artifacts",
        FailingSchemaCommands(dry_run=dry_run),
        binary_path=__file__,
    )

    assert tests_green is False
    assert doctor is None
    assert [failure.code for failure in failures] == [expected_code]


def test_schema_dry_run_must_report_the_expected_plan(tmp_path):
    target = tmp_path / "workspace"
    target.mkdir()

    class MissingPlanCommands(FakeCommands):
        def run(self, argv, *, cwd, env=None, timeout=300):  # noqa: ANN001, ARG002
            if "schema" in argv and "--dry-run" in argv:
                return CommandResult(0, "{}")
            return super().run(argv, cwd=cwd, env=env, timeout=timeout)

    tests_green, doctor, failures = run_rehearsal(
        target,
        tmp_path / "artifacts",
        MissingPlanCommands(),
        binary_path=__file__,
    )

    assert tests_green is False
    assert doctor is None
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
        lambda workspace_path: ({}, {}, EXPECTED_PUBLIC),
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
        lambda workspace_path: ({}, {}, EXPECTED_PUBLIC),
    )

    def fail_fresh_parity(*args, **kwargs):  # noqa: ANN002, ANN003
        raise GradeFailure("tests.fresh_parity", "fresh parity failed")

    commands = FakeCommands()
    second = grade(
        target,
        tmp_path / "second-artifacts",
        commands=commands,
        binary_path=__file__,
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


def test_rehearsal_replaces_a_stale_regular_file(tmp_path):
    target = workspace(tmp_path)
    stale = target / ".rehearsal"
    stale.write_text("stale\n")

    tests_green, _, failures = run_rehearsal(
        target,
        tmp_path / "artifacts",
        FakeCommands(),
        binary_path=__file__,
        port_picker=iter(range(42000, 42010)).__next__,
        health_getter=lambda *args, **kwargs: {},
        parity_probe=lambda *args, **kwargs: ("restore@example.invalid", "password"),
        backend_probe=lambda *args, **kwargs: None,
        playwright_python=__file__,
    )

    assert tests_green is True
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
    passed, doctor, failures = run_rehearsal(
        target,
        tmp_path / "artifacts",
        commands,
        binary_path=__file__,
    )

    assert passed is False and doctor is None
    assert [(failure.code, failure.message) for failure in failures] == [
        (
            "rehearsal.cleanup",
            f"cannot clear stale rehearsal state at {stale}: fixture denies removal",
        )
    ]
    assert commands.calls == []
    assert (stale / "data.db").read_bytes() == b"must not be trusted"


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        (b"\xff\n", "line 1 is invalid JSON"),
        (b'{"id":"case","value":NaN}\n', "invalid JSON"),
        (b"[]\n", "must be a JSON object"),
    ],
    ids=["invalid-utf8", "non-finite-number", "non-object-row"],
)
def test_grader_ndjson_uses_the_strict_coordinator_reader(tmp_path, payload, message):
    path = tmp_path / "capture.ndjson"
    path.write_bytes(payload)

    with pytest.raises(GradeFailure, match=message) as raised:
        _ndjson(path, "tests.backend_capture")
    assert raised.value.code == "tests.backend_capture.invalid"


def test_grader_ndjson_rejects_oversized_input(tmp_path, monkeypatch):
    path = tmp_path / "capture.ndjson"
    path.write_text('{"id":"case"}\n', encoding="utf-8")
    monkeypatch.setattr("tools.rails.fullstack.MAX_INPUT_BYTES", 8)

    with pytest.raises(GradeFailure, match="exceeds the 8-byte limit") as raised:
        _ndjson(path, "tests.backend_capture")
    assert raised.value.code == "tests.backend_capture.invalid"


def test_grader_ndjson_rejects_duplicate_case_ids(tmp_path):
    path = tmp_path / "capture.ndjson"
    path.write_text('{"id":"same"}\n{"id":"same"}\n', encoding="utf-8")

    with pytest.raises(GradeFailure, match="duplicate case id 'same'") as raised:
        _ndjson(path, "tests.backend_capture")
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


def test_live_validation_requires_the_producer_status():
    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if url.endswith("/records") and "passwordConfirm" in kwargs.get("body", {}):
            return 201, b"{}", "application/json"
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"token"}', "application/json"
        if kwargs.get("token") and kwargs.get("body", {}).get("title") == "":
            return 422, b"{}", "application/json"
        return 403, b"{}", "application/json"

    with pytest.raises(GradeFailure, match="invalid create returned 422"):
        probe_parity("http://target", typed_handoff(), http_request=request)


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
    with pytest.raises(GradeFailure, match="returned 200, not 201"):
        probe_backend_capture(
            "http://target",
            capture,
            ("user@example.invalid", "password"),
            http_request=request,
            send_case=lambda *args: (200, {}),
        )


def test_live_logout_is_anonymous_and_repeatable():
    logout_headers = []

    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        if url.endswith("auth-with-password"):
            return 200, b'{"token":"token"}', "application/json"
        raise AssertionError("capture requests must use the replay transport")

    def send_case(base, case, variables, timeout):  # noqa: ANN001, ARG001
        resolved = zb_replay.substitute(case, variables)
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


def test_backend_capture_uses_semantics_and_replay_transport_not_ids_or_order():
    sent = []

    def request(method, url, **kwargs):  # noqa: ANN001, ARG001
        assert url.endswith("auth-with-password")
        return 200, b'{"token":"setup-token"}', "application/json"

    def send_case(base, case, variables, timeout):  # noqa: ANN001, ARG001
        resolved = zb_replay.substitute(case, variables)
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


def test_live_failure_sinks_tests_grade(tmp_path, monkeypatch):
    target = workspace(tmp_path)

    def fail_probe(*args, **kwargs):  # noqa: ANN002, ANN003
        raise ValueError("live target mismatch")

    monkeypatch.setattr("evals.agents.graders.rails_fullstack.probe_parity", fail_probe)
    result = grade(
        target,
        tmp_path / "artifacts",
        commands=FakeCommands(),
        binary_path=__file__,
        port_picker=iter(range(42000, 42020)).__next__,
        health_getter=lambda *args, **kwargs: {},
        parity_probe=fail_probe,
        backend_probe=lambda *args, **kwargs: None,
        playwright_python=__file__,
    )
    assert result.tests_green is False
