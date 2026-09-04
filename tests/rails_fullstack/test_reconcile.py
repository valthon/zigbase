"""Contract tests for the full Rails migration reconciliation seam."""

from __future__ import annotations

import copy
import json
import math
import re
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from tools.rails import fullstack as fullstack_module
from tools.rails.fullstack import (
    OPENAPI_CONTRACT_VERSION,
    FullstackError,
    _browser_url_matches_route,
    _endpoint_operation,
    _path_matches_template,
    _route_patterns_overlap,
    _operation_access,
    load_backend_routes,
    validate_schema,
    main,
    reconcile,
    write_canonical,
)

REPO = Path(__file__).resolve().parents[2]
REAL_OPENAPI = json.loads(
    (
        REPO
        / "evals/agents/scenarios/rails-fullstack/fixture/source/zigbase.openapi.json"
    ).read_text()
)
BUILTIN_OPERATIONS = {
    "authWithPassword": ("public", "auth-with-password"),
    "authRefresh": ("authenticated", "auth-refresh"),
    "logout": ("public", "auth-logout"),
    "requestVerification": ("public", "request-verification"),
    "confirmVerification": ("public", "confirm-verification"),
    "requestPasswordReset": ("public", "request-password-reset"),
    "confirmPasswordReset": ("public", "confirm-password-reset"),
}
RESERVED_ROUTES = REAL_OPENAPI["x-zigbase-reserved-routes"]
RESERVED_PREFIXES = REAL_OPENAPI["x-zigbase-reserved-prefixes"]
EXPORTED_GATES = {
    "admin": True,
    "analytics": True,
    "senders": True,
    "mail_webhook": True,
    "tenancy": True,
    "webauthn": True,
    "magic_link": True,
    "oauth2": True,
    "mail_unsubscribe": True,
}


def dump(path: Path, value) -> Path:  # noqa: ANN001
    path.write_text(json.dumps(value, indent=2) + "\n")
    return path


def route(verb: str, path: str, controller: str, action: str, **extra):
    return {
        "verb": verb,
        "path": path,
        "controller": controller,
        "action": action,
        **extra,
    }


def presentation_route(verb: str, path: str, controller: str, action: str, **extra):
    return {
        **route(verb, path, controller, action),
        "id": f"{verb} {path}",
        "name": None,
        "source": {"file": "config/routes.rb", "line": 1},
        "origin": "static_ast",
        "confidence": "certain",
        "reason": "fixture route",
        "candidates": [],
        **extra,
    }


@pytest.fixture
def documents():
    backend_routes = {
        "source": "observed",
        "count": 3,
        "routes": [
            route("GET", "/posts", "posts", "index", internal=False, source="observed"),
            route(
                "POST", "/posts", "posts", "create", internal=False, source="observed"
            ),
            route(
                "PATCH",
                "/posts/:id",
                "posts",
                "update",
                internal=False,
                source="observed",
            ),
        ],
    }
    presentation = {
        "schema": "zigapagos.rails-presentation/1",
        "schema_version": 1,
        "generator": {"tool": "zigapagos", "version": "0.5.0"},
        "source": {
            "framework": "rails",
            "version": {"value": "8.1.3.1", "evidence": "Gemfile.lock"},
            "root_evidence": ["config/routes.rb", "app/views"],
        },
        "discovery": {
            "route_mode": "static_ast",
            "ruby": {"available": True, "version": "4.0.1"},
        },
        "routes": [
            {
                **presentation_route("GET", "/posts", "posts", "index"),
                "classification": "content",
                "templates": ["app/views/posts/index.html.erb"],
                "layout": "app/views/layouts/application.html.erb",
            },
            {
                **presentation_route("POST", "/posts", "posts", "create"),
                "classification": "backend",
                "templates": [],
                "layout": None,
            },
        ],
        "templates": [],
        "assets": [],
        "integrations": [],
        "blockers": [],
        "findings": [],
    }
    handoff = {
        "schema": "zigapagos.rails-handoff/1",
        "schema_version": 1,
        "generator": {"tool": "zigapagos", "version": "0.5.0"},
        "backend": {
            "file": "openapi.json",
            "contract_version": OPENAPI_CONTRACT_VERSION,
        },
        "complete": True,
        "routes": [
            {
                "route_id": "GET /posts",
                "status": "migrated",
                "artifacts": ["content/posts/index.smd"],
                "endpoint": None,
                "decision": None,
                "findings": [],
                "note": None,
            },
            {
                "route_id": "POST /posts",
                "status": "backend",
                "artifacts": ["components/forms/posts_new.island.tsx"],
                "endpoint": {
                    "operation_id": "createPosts",
                    "verb": "POST",
                    "path": "/api/collections/posts/records",
                },
                "decision": None,
                "findings": [],
                "note": None,
            },
        ],
        "assets": [],
        "redirects": [],
        "parity": [
            {
                "id": "navigate-posts",
                "kind": "navigate",
                "url": "/posts",
                "expect": {"status": 200, "title": "Posts", "h1": "Posts", "links": []},
            },
            {
                "id": "create-post-allowed",
                "kind": "submit_allowed",
                "url": "/api/collections/posts/records",
                "expect": {
                    "status_family": 2,
                    "operation_id": "createPosts",
                    "method": "POST",
                    "collection": "posts",
                    "page_url": "/posts",
                    "fields": [],
                },
            },
            {
                "id": "create-post-denied",
                "kind": "submit_denied",
                "url": "/api/collections/posts/records",
                "expect": {
                    "statuses": [401, 403],
                    "operation_id": "createPosts",
                    "method": "POST",
                    "collection": "posts",
                    "fields": [],
                },
            },
            {
                "id": "create-post-invalid",
                "kind": "validation_error",
                "url": "/api/collections/posts/records",
                "expect": {
                    "status": 400,
                    "operation_id": "createPosts",
                    "method": "POST",
                    "collection": "posts",
                    "page_url": "/posts",
                    "field": "title",
                    "fields": [],
                },
            },
        ],
    }
    openapi = {
        "openapi": "3.1.2",
        "info": {"title": "Replacement", "version": "1.0.0"},
        "x-zigbase-contract-version": OPENAPI_CONTRACT_VERSION,
        "x-zigbase-gates": dict(EXPORTED_GATES),
        "x-zigbase-feature-public-route": "/api/state",
        "x-zigbase-reserved-routes": [dict(route) for route in RESERVED_ROUTES],
        "x-zigbase-reserved-prefixes": [dict(prefix) for prefix in RESERVED_PREFIXES],
        "x-zigbase-builtin-operations": [
            {
                "operationId": operation_id,
                "method": "POST",
                "path": f"/api/collections/{{collection}}/{suffix}",
                "access": access,
                "collectionType": "auth",
            }
            for operation_id, (access, suffix) in BUILTIN_OPERATIONS.items()
        ],
        "x-zigbase-coverage": {
            "collections": True,
            "consumerRoutes": False,
            "admin": False,
            "realtime": False,
            "fileBytes": False,
            "allAuthMethods": False,
        },
        "paths": {
            "/api/collections/posts/records": {
                "get": {
                    "operationId": "listPosts",
                    "x-zigbase-access": "public",
                    "x-zigbase-collection": "posts",
                    "x-zigbase-collection-type": "base",
                },
                "post": {
                    "operationId": "createPosts",
                    "x-zigbase-access": "conditional",
                    "x-zigbase-collection": "posts",
                    "x-zigbase-collection-type": "base",
                    "requestBody": {
                        "content": {
                            "application/json": {
                                "schema": {"$ref": "#/components/schemas/PostsCreate"}
                            }
                        }
                    },
                },
            },
            "/api/collections/posts/records/{id}": {
                "patch": {
                    "operationId": "updatePosts",
                    "x-zigbase-access": "conditional",
                    "x-zigbase-collection": "posts",
                    "x-zigbase-collection-type": "base",
                }
            },
            "/api/collections/users/records": {
                "post": {
                    "operationId": "createUsers",
                    "x-zigbase-access": "public",
                    "x-zigbase-collection": "users",
                    "x-zigbase-collection-type": "auth",
                    "requestBody": {
                        "content": {
                            "application/json": {
                                "schema": {"$ref": "#/components/schemas/UsersCreate"}
                            }
                        }
                    },
                }
            },
        },
        "components": {
            "schemas": {
                "PostsCreate": {
                    "type": "object",
                    "properties": {"title": {"type": "string"}},
                },
                "UsersCreate": {
                    "type": "object",
                    "properties": {
                        "password": {"type": "string", "writeOnly": True},
                        "passwordConfirm": {"type": "string", "writeOnly": True},
                    },
                },
            }
        },
    }
    decisions = {
        "zigbaseRailsFullstackDecisions": 1,
        "routes": [
            {
                "source": {
                    "verb": "GET",
                    "path": "/posts",
                    "controller": "posts",
                    "action": "index",
                    "occurrence": 1,
                },
                "surface": "browser",
                "disposition": "migrated",
                "parity": [{"kind": "browser", "id": "navigate-posts"}],
                "rationale": "Converted the index page and preserved its route.",
            },
            {
                "source": {
                    "verb": "POST",
                    "path": "/posts",
                    "controller": "posts",
                    "action": "create",
                    "occurrence": 1,
                },
                "surface": "browser",
                "disposition": "migrated",
                "parity": [
                    {"kind": "browser", "id": "create-post-allowed"},
                    {"kind": "browser", "id": "create-post-denied"},
                    {"kind": "browser", "id": "create-post-invalid"},
                ],
                "rationale": "The form island submits to the locked replacement operation.",
            },
            {
                "source": {
                    "verb": "PATCH",
                    "path": "/posts/:id",
                    "controller": "posts",
                    "action": "update",
                    "occurrence": 1,
                },
                "surface": "api",
                "disposition": "migrated",
                "backend_operation_id": "updatePosts",
                "parity": [
                    {"kind": "backend", "id": "update-owner"},
                    {"kind": "backend", "id": "update-other"},
                ],
                "rationale": "The custom API client now uses updatePosts.",
            },
        ],
    }
    findings = [
        {"id": "list-posts", "result": "pass", "diff": []},
        {"id": "update-owner", "result": "pass", "diff": []},
        {"id": "update-other", "result": "pass", "diff": []},
    ]
    capture = [
        {
            "id": "list-posts",
            "method": "GET",
            "path": "/api/collections/posts/records",
            "expect": {"status": 200, "control": "allowed"},
        },
        {
            "id": "update-owner",
            "method": "PATCH",
            "path": "/api/collections/posts/records/{{id}}",
            "expect": {"status": 200, "control": "allowed"},
        },
        {
            "id": "update-other",
            "method": "PATCH",
            "path": "/api/collections/posts/records/{{id}}",
            "expect": {"status": 403, "control": "denied"},
        },
    ]
    return {
        "backend_routes": backend_routes,
        "presentation": presentation,
        "handoff": handoff,
        "openapi": openapi,
        "decisions": decisions,
        "findings": findings,
        "capture": capture,
    }


def materialize(tmp_path: Path, documents):
    values = copy.deepcopy(documents)
    paths = {
        key: dump(tmp_path / f"{key}.json", values[key])
        for key in (
            "backend_routes",
            "presentation",
            "handoff",
            "openapi",
            "decisions",
        )
    }
    findings = tmp_path / "backend-findings.ndjson"
    findings.write_text("".join(json.dumps(item) + "\n" for item in values["findings"]))
    paths["findings"] = findings
    capture = tmp_path / "backend-capture.ndjson"
    capture.write_text("".join(json.dumps(item) + "\n" for item in values["capture"]))
    paths["capture"] = capture
    return paths


def run(paths):
    return reconcile(
        paths["backend_routes"],
        paths["presentation"],
        paths["handoff"],
        paths["openapi"],
        paths["decisions"],
        paths["findings"],
        paths["capture"],
    )


def cli_args(paths, out):
    return [
        "--backend-routes",
        str(paths["backend_routes"]),
        "--presentation-manifest",
        str(paths["presentation"]),
        "--presentation-handoff",
        str(paths["handoff"]),
        "--backend-openapi",
        str(paths["openapi"]),
        "--decisions",
        str(paths["decisions"]),
        "--backend-findings",
        str(paths["findings"]),
        "--backend-capture",
        str(paths["capture"]),
        "--out",
        str(out),
    ]


def create_decision(documents):
    return next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["action"] == "create"
    )


def create_handoff(documents):
    return next(
        item
        for item in documents["handoff"]["routes"]
        if item["route_id"] == "POST /posts"
    )


def mark_consumer_routes(documents):
    documents["openapi"]["x-zigbase-coverage"]["consumerRoutes"] = True


def rewrite_create_verb(documents, verb, source_path="/submit"):
    operation_verb = verb.split("|", 1)[0]
    backend = next(
        row for row in documents["backend_routes"]["routes"] if row["verb"] == "POST"
    )
    backend["verb"] = verb
    backend["path"] = source_path
    presentation = next(
        row for row in documents["presentation"]["routes"] if row["verb"] == "POST"
    )
    presentation["verb"] = verb
    presentation["path"] = source_path
    presentation["id"] = f"{verb} {source_path}"
    handoff = create_handoff(documents)
    handoff["route_id"] = f"{verb} {source_path}"
    create_decision(documents)["source"].update(verb=verb, path=source_path)
    paths = documents["openapi"]["paths"]["/api/collections/posts/records"]
    operation = paths.pop("post")
    target_path = "/api/collections/posts/records"
    if operation_verb == "POST":
        paths["post"] = operation
    else:
        mark_consumer_routes(documents)
        target_path = "/api/migration/posts"
        operation["x-zigbase-auth"] = operation.pop("x-zigbase-access")
        operation.pop("x-zigbase-collection")
        operation.pop("x-zigbase-collection-type")
        documents["openapi"]["paths"][target_path] = {operation_verb.lower(): operation}
        handoff["endpoint"].update(verb=operation_verb, path=target_path)
    for recipe in documents["handoff"]["parity"]:
        if recipe["id"].startswith("create-post-"):
            recipe["url"] = target_path
            recipe["expect"]["method"] = operation_verb
            if operation_verb != "POST":
                recipe["expect"]["collection"] = None


def select_custom_create_endpoint(documents, path="/reports", access="authenticated"):
    operation_id = f"custom:{path}"
    create_handoff(documents)["endpoint"] = {
        "operation_id": operation_id,
        "verb": "POST",
        "path": path,
    }
    decision = create_decision(documents)
    decision["backend_access"] = access
    for recipe in documents["handoff"]["parity"]:
        if recipe["id"].startswith("create-post-"):
            recipe["url"] = path
            recipe["expect"]["operation_id"] = operation_id
            recipe["expect"]["collection"] = None


def test_reconciles_every_route_without_claiming_cutover_readiness(tmp_path, documents):
    result = run(materialize(tmp_path, documents))
    assert result["schema"] == "zigbase.rails-fullstack/1"
    assert result["needs_review"] is False
    assert len(result["routes"]) == 3
    assert result["contracts"]["zigapagos_presentation"] == {
        "schema": "zigapagos.rails-presentation/1",
        "generator_version": "0.5.0",
    }
    create = next(row for row in result["routes"] if row["source"]["verb"] == "POST")
    assert create["backend"]["operation_id"] == "createPosts"
    assert create["presentation"][0]["artifacts"] == [
        "components/forms/posts_new.island.tsx"
    ]
    assert {e["control"] for e in create["parity"]} >= {
        "allowed",
        "denied",
        "validation",
    }


@pytest.mark.parametrize(("field", "value"), [("controller", []), ("action", {})])
def test_backend_route_identity_validates_fields_before_occurrence_counting(
    tmp_path, documents, field, value
):
    documents["backend_routes"]["routes"][0][field] = value
    with pytest.raises(
        FullstackError, match=rf"route\.{field} must be a non-empty string"
    ):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(("field", "value"), [("controller", []), ("action", {})])
def test_presentation_route_identity_rejects_unhashable_fields_at_schema_boundary(
    tmp_path, documents, field, value
):
    documents["presentation"]["routes"][0][field] = value
    with pytest.raises(FullstackError):
        run(materialize(tmp_path, documents))


def test_reconciles_numeric_v1_replay_ids_without_rewriting_them(tmp_path, documents):
    for row in documents["capture"]:
        if row["id"] == "update-owner":
            row["id"] = 42
    for row in documents["findings"]:
        if row["id"] == "update-owner":
            row["id"] = 42
    update = next(
        row
        for row in documents["decisions"]["routes"]
        if row["source"]["verb"] == "PATCH"
    )
    next(item for item in update["parity"] if item["id"] == "update-owner")["id"] = 42

    result = run(materialize(tmp_path, documents))
    migrated = next(row for row in result["routes"] if row["source"]["verb"] == "PATCH")
    assert any(
        item["id"] == 42 and type(item["id"]) is int for item in migrated["parity"]
    )


def test_replay_identity_keeps_integer_float_and_boolean_one_distinct(
    tmp_path, documents
):
    replacements = {"update-owner": 1, "update-other": True}
    for collection in (documents["capture"], documents["findings"]):
        for row in collection:
            if row["id"] in replacements:
                row["id"] = replacements[row["id"]]
    update = next(
        row
        for row in documents["decisions"]["routes"]
        if row["source"]["verb"] == "PATCH"
    )
    for item in update["parity"]:
        if item["id"] in replacements:
            item["id"] = replacements[item["id"]]
    documents["capture"].append(
        {
            "id": 1.0,
            "method": "PATCH",
            "path": "/api/collections/posts/records/{{id}}",
            "expect": {"status": 200, "control": "allowed"},
        }
    )
    documents["findings"].append({"id": 1.0, "result": "pass", "diff": []})
    update["parity"].append({"kind": "backend", "id": 1.0})

    result = run(materialize(tmp_path, documents))
    migrated = next(row for row in result["routes"] if row["source"]["verb"] == "PATCH")
    identities = {
        (type(item["id"]).__name__, item["id"]) for item in migrated["parity"]
    }
    assert ("int", 1) in identities
    assert ("float", 1.0) in identities
    assert ("bool", True) in identities


def test_output_is_byte_deterministic(tmp_path, documents):
    result = run(materialize(tmp_path, documents))
    one, two = tmp_path / "one.json", tmp_path / "two.json"
    write_canonical(one, result)
    write_canonical(two, run(materialize(tmp_path, documents)))
    assert one.read_bytes() == two.read_bytes()


def test_refuses_an_incompatible_presentation_contract(tmp_path, documents):
    documents["presentation"]["schema"] = "zigapagos.rails-presentation/2"
    with pytest.raises(
        FullstackError, match="unsupported Zigapagos presentation.*contract"
    ):
        run(materialize(tmp_path, documents))


def test_refuses_when_either_tool_is_incomplete(tmp_path, documents):
    documents["handoff"]["complete"] = False
    with pytest.raises(FullstackError, match="handoff is incomplete"):
        run(materialize(tmp_path, documents))


def test_refuses_when_the_handoff_used_a_different_backend_contract(
    tmp_path, documents
):
    documents["handoff"]["backend"]["contract_version"] = "2.0.0"
    with pytest.raises(FullstackError, match="OpenAPI contract versions disagree"):
        run(materialize(tmp_path, documents))


def test_refuses_a_source_route_without_a_disposition(tmp_path, documents):
    documents["decisions"]["routes"].pop()
    with pytest.raises(FullstackError, match="route decision coverage mismatch"):
        run(materialize(tmp_path, documents))


def test_refuses_a_protected_mutation_without_both_controls(tmp_path, documents):
    update = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "PATCH"
    )
    update["parity"].pop()
    with pytest.raises(
        FullstackError, match="needs allowed and denied parity controls"
    ):
        run(materialize(tmp_path, documents))


def test_refuses_a_browser_route_with_only_backend_parity(tmp_path, documents):
    index = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "GET"
    )
    index["backend_operation_id"] = "listPosts"
    index["parity"] = [{"kind": "backend", "id": "list-posts"}]
    with pytest.raises(FullstackError, match="has no browser parity evidence"):
        run(materialize(tmp_path, documents))


def test_refuses_repeating_a_handoff_owned_operation(tmp_path, documents):
    create = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "POST"
    )
    create["backend_operation_id"] = "updatePosts"
    with pytest.raises(FullstackError, match="must omit backend_operation_id"):
        run(materialize(tmp_path, documents))


def test_refuses_a_claim_about_parity_that_did_not_pass(tmp_path, documents):
    documents["findings"][1]["result"] = "fail"
    with pytest.raises(FullstackError, match="is not a passing case"):
        run(materialize(tmp_path, documents))


def test_a_blocked_route_needs_a_stable_blocker_id(tmp_path, documents):
    update = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "PATCH"
    )
    update.pop("backend_operation_id")
    update.update(disposition="blocked", parity=[], blockers=[])
    with pytest.raises(FullstackError, match="must name blocker ids"):
        run(materialize(tmp_path, documents))


def test_locked_endpoint_access_is_never_compatible():
    with pytest.raises(FullstackError, match="locked operation"):
        _operation_access({"access": "locked"}, "route operation")


def test_refuses_a_reduced_presentation_document(tmp_path, documents):
    del documents["presentation"]["templates"]
    with pytest.raises(
        FullstackError, match="templates is required by the released schema"
    ):
        run(materialize(tmp_path, documents))


def test_refuses_an_invented_blocker_id(tmp_path, documents):
    index_decision = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "GET"
    )
    blocker_id = "RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L1C1"
    index_decision.update(
        disposition="blocked",
        parity=[],
        blockers=["INVENTED_BLOCKER"],
    )
    documents["presentation"]["blockers"] = [
        {
            "code": "RAILS_HELPER_UNKNOWN",
            "severity": "warn",
            "integrity": False,
            "source": {"file": "app/views/posts/index.html.erb", "line": 1},
            "message": "unknown helper",
            "route_id": None,
        }
    ]
    documents["presentation"]["findings"] = [
        {
            "id": blocker_id,
            "code": "RAILS_HELPER_UNKNOWN",
            "severity": "warn",
            "source": {"file": "app/views/posts/index.html.erb", "line": 1},
            "route_id": "GET /posts",
            "message": "unknown helper",
            "choices": ["blocked"],
            "requires_artifact": False,
        }
    ]
    handoff_route = next(
        item
        for item in documents["handoff"]["routes"]
        if item["route_id"] == "GET /posts"
    )
    handoff_route.update(
        status="blocked",
        artifacts=[],
        decision={
            "id": blocker_id,
            "choice": "blocked",
            "rationale": "unsupported helper",
        },
        findings=[blocker_id],
    )
    with pytest.raises(FullstackError, match="unknown blocker ids"):
        run(materialize(tmp_path, documents))


def test_refuses_duplicate_presentation_finding_join_keys(tmp_path, documents):
    finding = {
        "id": "RAILS_HELPER_UNKNOWN.shared",
        "code": "RAILS_HELPER_UNKNOWN",
        "severity": "warn",
        "source": {"file": "app/views/posts/index.html.erb", "line": 1},
        "route_id": "GET /posts",
        "message": "unknown helper",
        "choices": ["island"],
        "requires_artifact": False,
    }
    conflicting = {
        **finding,
        "route_id": "POST /posts",
        "message": "same join key, different question",
        "choices": ["blocked"],
    }
    documents["presentation"]["findings"] = [finding, conflicting]

    with pytest.raises(FullstackError, match="duplicate presentation finding id"):
        run(materialize(tmp_path, documents))


def test_refuses_a_backend_route_mapped_to_the_wrong_method(tmp_path, documents):
    update = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "PATCH"
    )
    update["backend_operation_id"] = "listPosts"
    update["parity"] = [{"kind": "backend", "id": "list-posts"}]
    with pytest.raises(FullstackError, match="method_change_rationale"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("cwd", [REPO, None])
def test_documented_direct_script_invocation_imports_from_any_cwd(tmp_path, cwd):
    working_directory = tmp_path if cwd is None else cwd
    script = (
        Path("tools/rails/fullstack.py")
        if working_directory == REPO
        else REPO / "tools/rails/fullstack.py"
    )
    result = subprocess.run(
        [sys.executable, str(script), "--help"],
        cwd=working_directory,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "--backend-routes" in result.stdout


def test_refuses_a_handoff_endpoint_path_drift(tmp_path, documents):
    handoff_route = next(
        item
        for item in documents["handoff"]["routes"]
        if item["route_id"] == "POST /posts"
    )
    handoff_route["endpoint"]["path"] = "/api/collections/comments/records"
    with pytest.raises(FullstackError, match="disagrees with OpenAPI operation"):
        run(materialize(tmp_path, documents))


def test_refuses_a_browser_recipe_method_drift(tmp_path, documents):
    recipe = next(
        item
        for item in documents["handoff"]["parity"]
        if item["id"] == "create-post-allowed"
    )
    recipe["expect"]["method"] = "PUT"
    with pytest.raises(FullstackError, match="uses method 'PUT'"):
        run(materialize(tmp_path, documents))


def test_refuses_a_browser_recipe_collection_drift(tmp_path, documents):
    recipe = next(
        item
        for item in documents["handoff"]["parity"]
        if item["id"] == "create-post-allowed"
    )
    recipe["expect"]["collection"] = "users"
    with pytest.raises(FullstackError, match="selected operation collection 'posts'"):
        run(materialize(tmp_path, documents))


def test_explicit_method_transform_can_map_an_unrelated_route_to_logout(
    tmp_path, documents
):
    handoff_route = next(
        item
        for item in documents["handoff"]["routes"]
        if item["route_id"] == "GET /posts"
    )
    handoff_route.update(
        status="backend",
        artifacts=[],
        endpoint={
            "operation_id": "logout",
            "verb": "POST",
            "path": "/api/collections/users/auth-logout",
        },
    )
    decision = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "GET"
    )
    decision.update(
        surface="api",
        method_change_rationale="the legacy index route is intentionally being repurposed",
        parity=[{"kind": "backend", "id": "logout"}],
    )
    documents["findings"].append({"id": "logout", "result": "pass", "diff": []})
    documents["capture"].append(
        {
            "id": "logout",
            "method": "POST",
            "path": "/api/collections/users/auth-logout",
            "expect": {"status": 204, "control": "allowed"},
        }
    )
    result = run(materialize(tmp_path, documents))
    assert result["needs_review"] is False


def test_refuses_a_builtin_logout_identity_on_a_records_endpoint(tmp_path, documents):
    handoff_route = next(
        item
        for item in documents["handoff"]["routes"]
        if item["route_id"] == "POST /posts"
    )
    handoff_route["endpoint"] = {
        "operation_id": "logout",
        "verb": "POST",
        "path": "/api/collections/users/records",
    }
    with pytest.raises(FullstackError, match="builtin endpoint 'logout' must be POST"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "operation_id,suffix",
    [("logout", "auth-logout"), ("authWithPassword", "auth-with-password")],
)
def test_refuses_builtin_auth_operations_on_non_auth_collections(
    tmp_path, documents, operation_id, suffix
):
    handoff_route = next(
        item
        for item in documents["handoff"]["routes"]
        if item["route_id"] == "POST /posts"
    )
    handoff_route["endpoint"] = {
        "operation_id": operation_id,
        "verb": "POST",
        "path": f"/api/collections/posts/{suffix}",
    }
    with pytest.raises(FullstackError, match="names non-auth collection 'posts'"):
        run(materialize(tmp_path, documents))


def test_accepts_additive_well_formed_exported_builtin_operation(tmp_path, documents):
    operation_id = "futureAuthAction"
    path_template = "/api/collections/{collection}/future-auth"
    target_path = "/api/collections/users/future-auth"
    documents["openapi"]["x-zigbase-reserved-routes"].append(
        {"method": "POST", "path": path_template}
    )
    documents["openapi"]["x-zigbase-builtin-operations"].append(
        {
            "operationId": operation_id,
            "method": "POST",
            "path": path_template,
            "access": "conditional",
            "collectionType": "auth",
        }
    )
    create_handoff(documents)["endpoint"] = {
        "operation_id": operation_id,
        "verb": "POST",
        "path": target_path,
    }
    for row in documents["handoff"]["parity"]:
        if row["id"].startswith("create-post-"):
            row["url"] = target_path
            row["expect"]["operation_id"] = operation_id
            row["expect"]["collection"] = "users"

    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_refuses_a_blocker_absent_from_the_route_findings(tmp_path, documents):
    blocker_id = "RAILS_HELPER_UNKNOWN.app/views/posts/index%2Ehtml%2Eerb.L1C1"
    documents["presentation"]["blockers"] = [
        {
            "code": "RAILS_HELPER_UNKNOWN",
            "severity": "warn",
            "integrity": False,
            "source": {"file": "app/views/posts/index.html.erb", "line": 1},
            "message": "unknown helper",
            "route_id": None,
        }
    ]
    documents["presentation"]["findings"] = [
        {
            "id": blocker_id,
            "code": "RAILS_HELPER_UNKNOWN",
            "severity": "warn",
            "source": {"file": "app/views/posts/index.html.erb", "line": 1},
            "route_id": "GET /posts",
            "message": "unknown helper",
            "choices": ["blocked"],
            "requires_artifact": False,
        }
    ]
    handoff_route = next(
        item
        for item in documents["handoff"]["routes"]
        if item["route_id"] == "GET /posts"
    )
    handoff_route.update(
        status="blocked",
        artifacts=[],
        decision={
            "id": blocker_id,
            "choice": "blocked",
            "rationale": "unsupported helper",
        },
        findings=[],
    )
    decision = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "GET"
    )
    decision.update(
        disposition="blocked",
        parity=[],
        blockers=[blocker_id],
    )
    with pytest.raises(FullstackError, match="absent from that route's findings"):
        run(materialize(tmp_path, documents))


def test_one_presentation_route_preserves_every_ordered_handoff_outcome(
    tmp_path, documents
):
    documents["handoff"]["routes"].append(
        {
            "route_id": "GET /posts",
            "status": "migrated",
            "artifacts": ["content/posts/alternate.smd"],
            "endpoint": None,
            "decision": None,
            "findings": [],
            "note": "A second producer outcome for the same source route.",
        }
    )

    result = run(materialize(tmp_path, documents))
    posts = next(
        row
        for row in result["routes"]
        if row["source"]["verb"] == "GET" and row["source"]["path"] == "/posts"
    )
    assert [row["artifacts"] for row in posts["presentation"]] == [
        ["content/posts/index.smd"],
        ["content/posts/alternate.smd"],
    ]


@pytest.mark.parametrize("verb", ["POST", "PATCH", "PUT", "DELETE"])
def test_non_get_presentation_route_may_have_no_handoff_row(tmp_path, documents, verb):
    rewrite_create_verb(documents, verb)
    documents["handoff"]["routes"] = [
        row
        for row in documents["handoff"]["routes"]
        if row["route_id"] != f"{verb} /submit"
    ]
    create_decision(documents)["backend_operation_id"] = "createPosts"

    result = run(materialize(tmp_path, documents))
    create = next(
        row
        for row in result["routes"]
        if row["source"]["verb"] == verb and row["source"]["path"] == "/submit"
    )
    assert create["backend"]["operation_id"] == "createPosts"
    assert create["presentation"] == []


@pytest.mark.parametrize("verb", ["GET", "HEAD", "GET|POST"])
def test_get_or_head_presentation_route_requires_a_handoff_row(
    tmp_path, documents, verb
):
    rewrite_create_verb(documents, verb)
    documents["handoff"]["routes"] = [
        row
        for row in documents["handoff"]["routes"]
        if row["route_id"] != f"{verb} /submit"
    ]

    with pytest.raises(FullstackError, match="no conversion row"):
        run(materialize(tmp_path, documents))


def test_ambiguous_duplicate_route_ids_are_rejected(tmp_path, documents):
    documents["presentation"]["routes"].append(
        {
            **presentation_route("GET", "/posts", "admin", "index"),
            "classification": "content",
            "templates": ["app/views/admin/index.html.erb"],
            "layout": "app/views/layouts/application.html.erb",
        }
    )
    for artifact in ("content/shared/a.smd", "content/shared/b.smd"):
        documents["handoff"]["routes"].append(
            {
                "route_id": "GET /posts",
                "status": "migrated",
                "artifacts": [artifact],
                "endpoint": None,
                "decision": None,
                "findings": [],
                "note": None,
            }
        )
    documents["decisions"]["routes"].append(
        {
            "source": {
                "verb": "GET",
                "path": "/posts",
                "controller": "admin",
                "action": "index",
                "occurrence": 1,
            },
            "surface": "browser",
            "disposition": "migrated",
            "parity": [{"kind": "browser", "id": "navigate-posts"}],
            "rationale": "The v1 handoff group cannot prove an occurrence boundary.",
        }
    )

    with pytest.raises(FullstackError, match="cannot attribute.*occurrence"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("access", ["superuser", "path-secret"])
def test_refuses_a_typed_route_access_downgrade(tmp_path, documents, access):
    operation = documents["openapi"]["paths"]["/api/collections/posts/records"]["post"]
    operation.pop("x-zigbase-access")
    operation["x-zigbase-auth"] = access
    with pytest.raises(FullstackError, match="lacks x-zigbase-access"):
        run(materialize(tmp_path, documents))


def test_refuses_an_unknown_openapi_access_value(tmp_path, documents):
    documents["openapi"]["paths"]["/api/collections/posts/records"]["post"][
        "x-zigbase-access"
    ] = "trusted-ish"
    with pytest.raises(FullstackError, match="unsupported access 'trusted-ish'"):
        run(materialize(tmp_path, documents))


def test_refuses_contradictory_openapi_access_extensions(tmp_path, documents):
    operation = documents["openapi"]["paths"]["/api/collections/posts/records"]["post"]
    operation["x-zigbase-auth"] = "authenticated"
    with pytest.raises(FullstackError, match="contradictory access metadata"):
        run(materialize(tmp_path, documents))


def test_collection_resource_allows_equal_redundant_access_extensions(
    tmp_path, documents
):
    operation = documents["openapi"]["paths"]["/api/collections/posts/records"]["post"]
    operation["x-zigbase-auth"] = operation["x-zigbase-access"]
    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_consumer_route_requires_consumer_auth_provenance(tmp_path, documents):
    mark_consumer_routes(documents)
    documents["openapi"]["paths"]["/reports"] = {
        "get": {"operationId": "reports", "x-zigbase-access": "public"}
    }
    with pytest.raises(FullstackError, match="lacks x-zigbase-auth"):
        run(materialize(tmp_path, documents))


def test_consumer_route_under_collection_prefix_does_not_require_resource_markers(
    tmp_path, documents
):
    mark_consumer_routes(documents)
    documents["openapi"]["paths"]["/api/collections/posts/publish"] = {
        "post": {"operationId": "publishPosts", "x-zigbase-auth": "authenticated"}
    }
    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_collection_gated_consumer_auth_is_preserved_in_reconciled_backend(
    tmp_path, documents
):
    mark_consumer_routes(documents)
    documents["openapi"]["paths"]["/api/profile/me"] = {
        "get": {
            "operationId": "profileMe",
            "x-zigbase-auth": "authenticated",
            "x-zigbase-auth-collection": "users",
            "x-zigbase-allow-superuser": False,
        }
    }
    handoff_route = next(
        item
        for item in documents["handoff"]["routes"]
        if item["route_id"] == "GET /posts"
    )
    handoff_route["endpoint"] = {
        "operation_id": "profileMe",
        "verb": "GET",
        "path": "/api/profile/me",
    }
    result = run(materialize(tmp_path, documents))
    migrated = next(row for row in result["routes"] if row["source"]["verb"] == "GET")
    assert migrated["backend"]["auth_collection"] == "users"
    assert migrated["backend"]["allow_superuser"] is False


@pytest.mark.parametrize(
    "metadata",
    [
        {"x-zigbase-auth-collection": "users"},
        {"x-zigbase-allow-superuser": False},
        {
            "x-zigbase-auth-collection": "users",
            "x-zigbase-allow-superuser": "yes",
        },
        {
            "x-zigbase-auth": "public",
            "x-zigbase-auth-collection": "users",
            "x-zigbase-allow-superuser": False,
        },
    ],
)
def test_collection_gated_consumer_auth_metadata_is_coherent(
    tmp_path, documents, metadata
):
    mark_consumer_routes(documents)
    operation = {"operationId": "profileMe", "x-zigbase-auth": "authenticated"}
    operation.update(metadata)
    documents["openapi"]["paths"]["/api/profile/me"] = {"get": operation}
    with pytest.raises(FullstackError, match="authentication|declare both"):
        run(materialize(tmp_path, documents))


def test_accepts_a_reviewed_custom_endpoint_contract(tmp_path, documents):
    select_custom_create_endpoint(documents)
    result = run(materialize(tmp_path, documents))
    create = next(row for row in result["routes"] if row["source"]["verb"] == "POST")
    assert create["backend"] == {
        "operation_id": "custom:/reports",
        "verb": "POST",
        "path": "/reports",
        "collection": None,
        "collection_type": None,
        "access": "authenticated",
    }


@pytest.mark.parametrize("captured", ["/reports/42", "/reports/{{report_id}}"])
def test_dynamic_custom_endpoint_accepts_backend_replay_evidence(
    tmp_path, documents, captured
):
    select_custom_create_endpoint(
        documents, path="/reports/:report_id", access="public"
    )
    decision = create_decision(documents)
    decision["surface"] = "api"
    decision["parity"] = [{"kind": "backend", "id": "custom-report"}]
    documents["capture"].append(
        {
            "id": "custom-report",
            "method": "POST",
            "path": captured,
            "expect": {"status": 200, "control": "allowed"},
        }
    )
    documents["findings"].append({"id": "custom-report", "result": "pass", "diff": []})

    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_refuses_a_custom_endpoint_without_reviewed_access(tmp_path, documents):
    select_custom_create_endpoint(documents)
    del create_decision(documents)["backend_access"]
    with pytest.raises(
        FullstackError, match="backend_access must be a non-empty string"
    ):
        run(materialize(tmp_path, documents))


def test_refuses_a_custom_endpoint_that_aliases_openapi(tmp_path, documents):
    select_custom_create_endpoint(
        documents, path="/api/collections/posts/records", access="conditional"
    )
    with pytest.raises(FullstackError, match="aliases engine-owned route"):
        run(materialize(tmp_path, documents))


def test_refuses_a_custom_endpoint_that_concretizes_an_openapi_template(
    tmp_path, documents
):
    mark_consumer_routes(documents)
    documents["openapi"]["paths"]["/reports/{id}"] = {
        "post": {"operationId": "replaceReport", "x-zigbase-auth": "public"}
    }
    select_custom_create_endpoint(documents, path="/reports/abc", access="public")
    with pytest.raises(
        FullstackError, match="aliases OpenAPI operation 'replaceReport'"
    ):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "path",
    [
        "//evil.example/path",
        "/reports//one",
        "/reports/.",
        "/reports/..",
        "/reports\\one",
        "/reports?all=true",
        "/reports#top",
        "/reports/%2fadmin",
        "/reports/%5cadmin",
        "/reports/%2e%2e",
        "/reports/%252fadmin",
        "/reports/%41dmin",
        "/reports/%c3%a9",
        "/reports/%FF",
        "/reports/%ZZ",
        "/reports/:2invalid",
        "/reports/:",
        "/reports/\x00",
    ],
)
def test_refuses_noncanonical_custom_endpoint_paths(tmp_path, documents, path):
    select_custom_create_endpoint(documents, path=path, access="public")
    with pytest.raises(FullstackError, match="same-origin absolute|not canonical"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("collection", ["users", "posts"])
def test_custom_endpoints_cannot_alias_builtin_collection_paths(
    tmp_path, documents, collection
):
    select_custom_create_endpoint(
        documents,
        path=f"/api/collections/{collection}/auth-refresh",
        access="public",
    )
    with pytest.raises(FullstackError, match="aliases engine-owned route"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    ("method", "template"),
    [(row["method"], row["path"]) for row in RESERVED_ROUTES],
)
def test_custom_endpoint_rejects_every_exported_engine_route(method, template):
    path = re.sub(r"\{[^{}]+\}", "value", template)
    contract = {
        "reserved_routes": ((method, template),),
        "reserved_prefixes": (),
        "builtin_endpoints": {},
    }
    with pytest.raises(FullstackError, match="aliases engine-owned route"):
        _endpoint_operation(
            {"operation_id": f"custom:{path}", "verb": method, "path": path},
            {},
            {},
            frozenset(),
            contract,
            "public",
            "endpoint",
        )


def test_custom_collection_prefix_route_is_preserved_when_not_engine_owned():
    path = "/api/collections/posts/publish"
    operation = _endpoint_operation(
        {"operation_id": f"custom:{path}", "verb": "POST", "path": path},
        {},
        {},
        frozenset(),
        {
            "reserved_routes": tuple(
                (row["method"], row["path"]) for row in RESERVED_ROUTES
            ),
            "reserved_prefixes": (),
            "builtin_endpoints": {},
        },
        "authenticated",
        "endpoint",
    )
    assert operation["path"] == path


@pytest.mark.parametrize("operation", [None, [], {}, {"operationId": ""}])
def test_every_openapi_http_operation_requires_a_nonempty_operation_id(
    tmp_path, documents, operation
):
    mark_consumer_routes(documents)
    documents["openapi"]["paths"]["/reports"] = {"get": operation}
    with pytest.raises(FullstackError, match=r"GET /reports(?:\.operationId)?"):
        run(materialize(tmp_path, documents))


def test_missing_operation_id_cannot_hide_a_custom_route_collision(tmp_path, documents):
    mark_consumer_routes(documents)
    documents["openapi"]["paths"]["/reports"] = {
        "post": {"x-zigbase-auth": "authenticated"}
    }
    select_custom_create_endpoint(documents)
    with pytest.raises(FullstackError, match=r"POST /reports\.operationId"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("path", ["/_", "/_/health", "/_/deep/health"])
def test_custom_endpoint_rejects_every_admin_prefix_depth(tmp_path, documents, path):
    select_custom_create_endpoint(documents, path=path, access="public")
    with pytest.raises(FullstackError, match="engine-owned admin prefix /_"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("prefixes", [(), (("/_", "admin"),)])
def test_custom_endpoint_preserves_admin_prefix_gate_and_segment_boundary(prefixes):
    path = "/_/deep" if not prefixes else "/__"
    operation = _endpoint_operation(
        {"operation_id": f"custom:{path}", "verb": "POST", "path": path},
        {},
        {},
        frozenset(),
        {
            "reserved_routes": (),
            "reserved_prefixes": prefixes,
            "builtin_endpoints": {},
        },
        "public",
        "endpoint",
    )
    assert operation["path"] == path


@pytest.mark.parametrize("path", ["/:tenant", "/:tenant/settings"])
def test_custom_endpoint_capture_cannot_alias_admin_prefix(tmp_path, documents, path):
    select_custom_create_endpoint(documents, path=path, access="public")
    with pytest.raises(FullstackError, match="engine-owned admin prefix /_"):
        run(materialize(tmp_path, documents))


def test_custom_endpoint_rejects_a_method_zigbase_cannot_declare(tmp_path, documents):
    select_custom_create_endpoint(documents)
    create_handoff(documents)["endpoint"]["verb"] = "BREW"
    for recipe in documents["handoff"]["parity"]:
        if recipe["id"].startswith("create-post-"):
            recipe["expect"]["method"] = "BREW"
    with pytest.raises(
        FullstackError, match="custom endpoint verb 'BREW' is unsupported"
    ):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "path",
    ["/api//broken", "/api/:id", "/api/{bad-name}", "/api/{id}/{id}", "/api/%41"],
)
def test_refuses_noncanonical_reserved_route_metadata(tmp_path, documents, path):
    documents["openapi"]["x-zigbase-reserved-routes"].append(
        {"method": "GET", "path": path}
    )
    with pytest.raises(FullstackError, match="reserved route metadata.*invalid"):
        run(materialize(tmp_path, documents))


def test_refuses_noncanonical_builtin_route_metadata(tmp_path, documents):
    documents["openapi"]["x-zigbase-builtin-operations"][0]["path"] = "/api//broken"
    with pytest.raises(FullstackError, match="builtin operation metadata.*invalid"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "prefix",
    ["/_/", "//_", "/_//health", "/_?query", "/_#fragment", "/{admin}", "/_\x00"],
)
def test_refuses_noncanonical_reserved_prefix_metadata(tmp_path, documents, prefix):
    documents["openapi"]["x-zigbase-reserved-prefixes"] = [
        {"path": prefix, "source": "admin"}
    ]
    with pytest.raises(FullstackError, match="reserved prefix metadata.*invalid"):
        run(materialize(tmp_path, documents))


def test_requires_reserved_prefix_metadata(tmp_path, documents):
    del documents["openapi"]["x-zigbase-reserved-prefixes"]
    with pytest.raises(FullstackError, match="x-zigbase-reserved-prefixes"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    ("admin", "prefixes"),
    [
        (True, []),
        (False, [{"path": "/_", "source": "admin"}]),
        (True, [{"path": "/_", "source": "made-up"}]),
    ],
)
def test_reserved_prefix_metadata_must_exactly_match_the_admin_gate(
    tmp_path, documents, admin, prefixes
):
    documents["openapi"]["x-zigbase-gates"]["admin"] = admin
    documents["openapi"]["x-zigbase-reserved-prefixes"] = prefixes
    with pytest.raises(FullstackError, match="reserved-prefixes.*gates.admin"):
        run(materialize(tmp_path, documents))


def test_reserved_prefix_metadata_tolerates_additive_engine_prefixes(
    tmp_path, documents
):
    documents["openapi"]["x-zigbase-reserved-prefixes"].append(
        {"path": "/future", "source": "future-engine"}
    )
    assert run(materialize(tmp_path, documents))["needs_review"] is False


@pytest.mark.parametrize("method", ["GET", "HEAD"])
def test_feature_public_route_requires_both_reserved_methods(
    tmp_path, documents, method
):
    documents["openapi"]["x-zigbase-reserved-routes"] = [
        row
        for row in documents["openapi"]["x-zigbase-reserved-routes"]
        if not (row["method"] == method and row["path"] == "/api/state")
    ]
    with pytest.raises(FullstackError, match="must reserve GET and HEAD"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("gates", [None, {**EXPORTED_GATES, "admin": 1}])
def test_exported_gate_metadata_is_required_and_boolean(tmp_path, documents, gates):
    if gates is None:
        del documents["openapi"]["x-zigbase-gates"]
    else:
        documents["openapi"]["x-zigbase-gates"] = gates
    with pytest.raises(FullstackError, match="x-zigbase-gates"):
        run(materialize(tmp_path, documents))


def test_exported_gate_metadata_allows_new_or_unneeded_boolean_gates(
    tmp_path, documents
):
    documents["openapi"]["x-zigbase-gates"]["future"] = True

    assert run(materialize(tmp_path, documents))["needs_review"] is False


@pytest.mark.parametrize(
    "operation", [None, {"operationId": "traceMe", "x-zigbase-auth": "public"}]
)
def test_trace_operations_are_rejected_instead_of_silently_ignored(
    tmp_path, documents, operation
):
    documents["openapi"]["paths"]["/trace"] = {"trace": operation}
    with pytest.raises(
        FullstackError, match="TRACE /trace uses an unsupported HTTP method"
    ):
        run(materialize(tmp_path, documents))


def test_legitimate_openapi_path_item_metadata_and_extensions_are_ignored(
    tmp_path, documents
):
    path_item = documents["openapi"]["paths"]["/api/collections/posts/records"]
    path_item.update(
        {
            "summary": "Posts",
            "description": "Post operations",
            "parameters": [],
            "servers": [],
            "x-documentation": {"group": "posts"},
        }
    )

    assert run(materialize(tmp_path, documents))["needs_review"] is False


@pytest.mark.parametrize("field", ["gett", "connect", "totallyNotOpenApi"])
def test_unknown_openapi_path_item_fields_are_rejected(tmp_path, documents, field):
    documents["openapi"]["paths"]["/trace"] = {field: {"operationId": "hidden"}}
    with pytest.raises(FullstackError, match="unsupported field"):
        run(materialize(tmp_path, documents))


def test_refuses_the_undocumented_bare_custom_operation_id(tmp_path, documents):
    select_custom_create_endpoint(documents)
    create_handoff(documents)["endpoint"]["operation_id"] = "custom"
    with pytest.raises(
        FullstackError, match="backend_access for a non-custom endpoint"
    ):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    ("target", "key"),
    [
        ("root", "routes_typo"),
        ("route", "backend_operationid"),
        ("source", "occurence"),
        ("evidence", "contorl"),
    ],
)
def test_decision_contract_rejects_unknown_keys(tmp_path, documents, target, key):
    decision = create_decision(documents)
    values = {
        "root": documents["decisions"],
        "route": decision,
        "source": decision["source"],
        "evidence": decision["parity"][0],
    }
    values[target][key] = "typo"

    with pytest.raises(FullstackError, match=key):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("key", ["surface", "disposition", "parity", "rationale"])
def test_decision_contract_names_missing_required_keys(tmp_path, documents, key):
    del create_decision(documents)[key]
    with pytest.raises(FullstackError, match=key):
        run(materialize(tmp_path, documents))


def test_refuses_a_custom_operation_id_path_mismatch(tmp_path, documents):
    select_custom_create_endpoint(documents)
    create_handoff(documents)["endpoint"]["operation_id"] = "custom:/elsewhere"
    with pytest.raises(
        FullstackError, match="must be exactly 'custom:' plus its absolute path"
    ):
        run(materialize(tmp_path, documents))


def test_operationless_backend_evidence_is_bound_to_the_source_route(
    tmp_path, documents
):
    index = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "GET"
    )
    index.update(
        surface="api",
        parity=[{"kind": "backend", "id": "list-posts"}],
    )
    with pytest.raises(FullstackError, match="does not exercise GET /posts"):
        run(materialize(tmp_path, documents))


def test_operationless_backend_evidence_accepts_the_exact_source_route(
    tmp_path, documents
):
    index = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "GET"
    )
    index.update(
        surface="api",
        parity=[{"kind": "backend", "id": "source-posts"}],
    )
    documents["capture"].append(
        {
            "id": "source-posts",
            "method": "GET",
            "path": "/posts",
            "expect": {"status": 200, "control": "allowed"},
        }
    )
    documents["findings"].append({"id": "source-posts", "result": "pass", "diff": []})
    assert run(materialize(tmp_path, documents))["needs_review"] is False


@pytest.mark.parametrize("captured", ["/posts/123", "/posts/{{id}}"])
def test_operationless_backend_evidence_matches_dynamic_source_route(
    tmp_path, documents, captured
):
    decision = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "GET"
    )
    for key in ("backend_routes", "presentation"):
        route = documents[key]["routes"][0]
        route["path"] = "/posts/:id"
        route["id"] = "GET /posts/:id"
    documents["handoff"]["routes"][0]["route_id"] = "GET /posts/:id"
    decision["source"]["path"] = "/posts/:id"
    decision.update(
        surface="api",
        parity=[{"kind": "backend", "id": "source-post"}],
    )
    documents["capture"].append(
        {
            "id": "source-post",
            "method": "GET",
            "path": captured,
            "expect": {"status": 200, "control": "allowed"},
        }
    )
    documents["findings"].append({"id": "source-post", "result": "pass", "diff": []})

    assert run(materialize(tmp_path, documents))["needs_review"] is False


@pytest.mark.parametrize(
    "captured_path",
    [
        "/api/collections/posts/records/{{id}}",
        "/api/collections/posts/records/post-123",
    ],
)
def test_operation_evidence_matches_dynamic_openapi_path_segments(
    tmp_path, documents, captured_path
):
    for case in documents["capture"]:
        if case["id"].startswith("update-"):
            case["path"] = captured_path
    assert run(materialize(tmp_path, documents))["needs_review"] is False


@pytest.mark.parametrize(
    ("captured_path", "message"),
    [
        ("/api/collections/comments/records/post-123", "does not exercise PATCH"),
        ("/api/collections/posts/records/post-123/extra", "does not exercise PATCH"),
        ("/api/collections/posts/records", "does not exercise PATCH"),
        ("/api/collections/posts/records/{id}", "does not exercise PATCH"),
    ],
)
def test_operation_evidence_rejects_nonmatching_dynamic_paths(
    tmp_path, documents, captured_path, message
):
    next(case for case in documents["capture"] if case["id"] == "update-owner")[
        "path"
    ] = captured_path
    with pytest.raises(FullstackError, match=message):
        run(materialize(tmp_path, documents))


def test_accepts_404_as_denied_concealment_evidence(tmp_path, documents):
    denied = next(item for item in documents["capture"] if item["id"] == "update-other")
    denied["expect"]["status"] = 404
    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_refuses_a_404_case_relabelled_as_allowed(tmp_path, documents):
    denied = next(item for item in documents["capture"] if item["id"] == "update-other")
    denied["expect"].update(status=404, control="allowed")
    with pytest.raises(
        FullstackError, match="control 'allowed' is incompatible with status 404"
    ):
        run(materialize(tmp_path, documents))


def test_uncited_capture_does_not_need_a_fullstack_control(tmp_path, documents):
    uncited = next(item for item in documents["capture"] if item["id"] == "list-posts")
    uncited["expect"] = {"status": 500}
    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_cited_capture_requires_a_producer_control(tmp_path, documents):
    owner = next(item for item in documents["capture"] if item["id"] == "update-owner")
    del owner["expect"]["control"]
    with pytest.raises(FullstackError, match="has no producer control"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("verb", ["GET|PATCH", "ANY"])
def test_compound_mutating_verbs_require_allowed_and_denied_controls(
    tmp_path, documents, verb
):
    backend = next(
        item
        for item in documents["backend_routes"]["routes"]
        if item["verb"] == "PATCH"
    )
    backend["verb"] = verb
    decision = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "PATCH"
    )
    decision["source"]["verb"] = verb
    decision["parity"] = [{"kind": "backend", "id": "update-owner"}]
    with pytest.raises(
        FullstackError, match="needs allowed and denied parity controls"
    ):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("verb", ["GET|POST", "ANY"])
def test_compound_routes_cannot_be_claimed_by_one_backend_operation(
    tmp_path, documents, verb
):
    handoff = create_handoff(documents)
    decision = create_decision(documents)
    rewrite_create_verb(documents, "GET|POST")
    if verb == "ANY":
        backend = next(
            item
            for item in documents["backend_routes"]["routes"]
            if item["verb"] == "GET|POST"
        )
        backend["verb"] = "ANY"
        presentation = next(
            item
            for item in documents["presentation"]["routes"]
            if item["verb"] == "GET|POST"
        )
        presentation["verb"] = "ANY"
        presentation["id"] = "ANY /submit"
        handoff["route_id"] = "ANY /submit"
        decision["source"]["verb"] = "ANY"
    with pytest.raises(
        FullstackError,
        match="compound route .* cannot be proven by one backend operation",
    ):
        run(materialize(tmp_path, documents))


def test_refuses_an_invalid_compound_verb(tmp_path, documents):
    documents["backend_routes"]["routes"][0]["verb"] = "GET|EXPLODE"
    with pytest.raises(FullstackError, match="not a supported Rails verb expression"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("controller", ["devise/sessions", "users/sessions"])
def test_namespaced_sessions_destroy_can_use_the_reviewed_logout_transform(
    tmp_path, documents, controller
):
    backend = next(
        item for item in documents["backend_routes"]["routes"] if item["verb"] == "POST"
    )
    backend.update(
        verb="DELETE", path="/users/sign_out", controller=controller, action="destroy"
    )
    presentation = next(
        item for item in documents["presentation"]["routes"] if item["verb"] == "POST"
    )
    presentation.update(
        verb="DELETE",
        path="/users/sign_out",
        controller=controller,
        action="destroy",
        id="DELETE /users/sign_out",
    )
    handoff = create_handoff(documents)
    handoff.update(
        route_id="DELETE /users/sign_out",
        endpoint={
            "operation_id": "logout",
            "verb": "POST",
            "path": "/api/collections/users/auth-logout",
        },
    )
    decision = create_decision(documents)
    decision.update(
        source={
            "verb": "DELETE",
            "path": "/users/sign_out",
            "controller": controller,
            "action": "destroy",
            "occurrence": 1,
        },
        method_change_rationale="the auth collection exposes logout as a POST action",
        parity=[{"kind": "browser", "id": "create-post-allowed"}],
    )
    recipe = next(
        item
        for item in documents["handoff"]["parity"]
        if item["id"] == "create-post-allowed"
    )
    recipe["url"] = "/api/collections/users/auth-logout"
    recipe["expect"].update(operation_id="logout", method="POST", collection="users")
    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_reviewed_put_to_patch_transform_is_recorded(tmp_path, documents):
    backend = next(
        item
        for item in documents["backend_routes"]["routes"]
        if item["verb"] == "PATCH"
    )
    backend["verb"] = "PUT"
    decision = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "PATCH"
    )
    decision["source"]["verb"] = "PUT"
    decision["method_change_rationale"] = (
        "  the generated update operation uses PATCH semantics  "
    )
    result = run(materialize(tmp_path, documents))
    update = next(row for row in result["routes"] if row["source"]["verb"] == "PUT")
    assert update["method_transform"] == {
        "from": "PUT",
        "to": "PATCH",
        "rationale": "the generated update operation uses PATCH semantics",
    }


def test_read_to_protected_mutation_requires_denied_evidence(tmp_path, documents):
    backend = next(
        item
        for item in documents["backend_routes"]["routes"]
        if item["verb"] == "PATCH"
    )
    backend["verb"] = "GET"
    decision = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "PATCH"
    )
    decision["source"]["verb"] = "GET"
    decision["method_change_rationale"] = (
        "the replacement intentionally uses mutation semantics"
    )
    decision["parity"] = [{"kind": "backend", "id": "update-owner"}]
    with pytest.raises(
        FullstackError,
        match="protected mutation .* needs allowed and denied parity controls",
    ):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "rationale",
    [None, "", "   ", [], {}],
)
def test_refuses_invalid_method_change_rationale(tmp_path, documents, rationale):
    backend = next(
        item
        for item in documents["backend_routes"]["routes"]
        if item["verb"] == "PATCH"
    )
    backend["verb"] = "PUT"
    decision = next(
        item
        for item in documents["decisions"]["routes"]
        if item["source"]["verb"] == "PATCH"
    )
    decision["source"]["verb"] = "PUT"
    decision["method_change_rationale"] = rationale
    with pytest.raises(FullstackError, match="method_change_rationale"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "operation_id,access,suffix",
    [
        (operation_id, access, suffix)
        for operation_id, (access, suffix) in BUILTIN_OPERATIONS.items()
    ],
)
def test_all_standard_builtin_auth_endpoints_are_recognized(
    tmp_path, documents, operation_id, access, suffix
):
    endpoint_path = f"/api/collections/users/{suffix}"
    create_handoff(documents)["endpoint"] = {
        "operation_id": operation_id,
        "verb": "POST",
        "path": endpoint_path,
    }
    decision = create_decision(documents)
    selected_evidence = [{"kind": "browser", "id": "create-post-allowed"}]
    allowed = next(
        row
        for row in documents["handoff"]["parity"]
        if row["id"] == "create-post-allowed"
    )
    allowed["url"] = endpoint_path
    allowed["expect"].update(
        operation_id=operation_id, method="POST", collection="users"
    )
    if access != "public":
        denied = next(
            row
            for row in documents["handoff"]["parity"]
            if row["id"] == "create-post-denied"
        )
        denied["url"] = endpoint_path
        denied["expect"].update(
            operation_id=operation_id, method="POST", collection="users"
        )
        selected_evidence.append({"kind": "browser", "id": "create-post-denied"})
    decision["parity"] = selected_evidence
    assert run(materialize(tmp_path, documents))["needs_review"] is False


@pytest.mark.parametrize("operation_id", BUILTIN_OPERATIONS)
def test_generic_openapi_operations_cannot_claim_reserved_builtin_ids(
    tmp_path, documents, operation_id
):
    documents["openapi"]["paths"]["/api/collections/posts/records"]["get"][
        "operationId"
    ] = operation_id
    with pytest.raises(
        FullstackError,
        match=rf"OpenAPI path operationId {operation_id!r} collides with exported builtin",
    ):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("operation_id", BUILTIN_OPERATIONS)
def test_custom_openapi_routes_cannot_claim_reserved_builtin_ids(
    tmp_path, documents, operation_id
):
    mark_consumer_routes(documents)
    documents["openapi"]["paths"]["/reports"] = {
        "get": {"operationId": operation_id, "x-zigbase-auth": "public"}
    }
    with pytest.raises(
        FullstackError,
        match=rf"OpenAPI path operationId {operation_id!r} collides with exported builtin",
    ):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "captured",
    [
        "/records/plain-id",
        "/records/a.b_c~d!$&'()*+,;=:@-",
        "/records/caf%C3%A9",
        "/records/café",
        "/records/{{id}}",
        "/records/{{record_id}}",
        "/records/caf%c3%a9",
        "/records/caf%C3%a9?include=owner",
    ],
)
def test_path_template_accepts_safe_concrete_segments_and_exact_placeholders(captured):
    assert _path_matches_template("/records/{id}", captured)


@pytest.mark.parametrize("template", ["/records/{id}", "/records/:id"])
def test_both_capture_spellings_match_concrete_and_replay_paths(template):
    assert _path_matches_template(template, "/records/42")
    assert _path_matches_template(template, "/records/{{record_id}}")


def test_route_pattern_overlap_is_symmetric_across_capture_spellings():
    assert _route_patterns_overlap("/records/{id}", "/records/:record_id")
    assert _route_patterns_overlap("/records/:record_id", "/records/{id}")
    assert _route_patterns_overlap("/records/:id", "/records/fixed")
    assert not _route_patterns_overlap("/records/:id", "/other/:id")


@pytest.mark.parametrize(
    "pattern,url",
    [
        ("/posts/:id", "/posts/post-123"),
        ("/posts/:id", "/posts/caf%C3%A9"),
        ("/posts/:id", "/posts/café"),
        ("/teams/:team/posts/:id", "/teams/acme/posts/post-123?tab=edit#body"),
        ("/records/{id}", "/records/post-123"),
    ],
)
def test_browser_urls_match_dynamic_route_segments(pattern, url):
    assert _browser_url_matches_route(pattern, url)


@pytest.mark.parametrize(
    "url",
    [
        "/other/post-123",
        "/posts",
        "/posts/",
        "/posts/a/b",
        "/posts/a%2Fb",
        "https://example.test/posts/1",
        " /posts/a",
        "///posts/a",
        "/posts/a\n",
        "//[",
    ],
)
def test_browser_urls_must_concretely_match_the_selected_route(url):
    assert not _browser_url_matches_route("/posts/:id", url)


def test_reconcile_accepts_concrete_navigation_for_a_dynamic_rails_route(
    tmp_path, documents
):
    documents["backend_routes"]["routes"][0]["path"] = "/posts/:id"
    documents["backend_routes"]["routes"][0]["id"] = "GET /posts/:id"
    documents["presentation"]["routes"][0]["path"] = "/posts/:id"
    documents["presentation"]["routes"][0]["id"] = "GET /posts/:id"
    documents["handoff"]["routes"][0]["route_id"] = "GET /posts/:id"
    documents["handoff"]["parity"][0]["url"] = "/posts/post-123"
    documents["decisions"]["routes"][0]["source"]["path"] = "/posts/:id"

    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_reconcile_accepts_raw_unicode_navigation_for_a_dynamic_rails_route(
    tmp_path, documents
):
    documents["backend_routes"]["routes"][0]["path"] = "/posts/:id"
    documents["backend_routes"]["routes"][0]["id"] = "GET /posts/:id"
    documents["presentation"]["routes"][0]["path"] = "/posts/:id"
    documents["presentation"]["routes"][0]["id"] = "GET /posts/:id"
    documents["handoff"]["routes"][0]["route_id"] = "GET /posts/:id"
    documents["handoff"]["parity"][0]["url"] = "/posts/café"
    documents["decisions"]["routes"][0]["source"]["path"] = "/posts/:id"

    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_reconcile_accepts_raw_unicode_backend_capture(tmp_path, documents):
    owner = next(case for case in documents["capture"] if case["id"] == "update-owner")
    owner["path"] = "/api/collections/posts/records/café"

    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_reconcile_accepts_concrete_browser_evidence_for_a_dynamic_operation(
    tmp_path, documents
):
    collection_path = "/api/collections/posts/records"
    operation = documents["openapi"]["paths"][collection_path].pop("post")
    operation["x-zigbase-auth"] = operation.pop("x-zigbase-access")
    operation.pop("x-zigbase-collection")
    operation.pop("x-zigbase-collection-type")
    documents["openapi"]["paths"]["/api/records/{id}"] = {"post": operation}
    mark_consumer_routes(documents)
    create_handoff(documents)["endpoint"]["path"] = "/api/records/{id}"
    for recipe in documents["handoff"]["parity"]:
        if recipe["id"].startswith("create-post-"):
            recipe["url"] = "/api/records/post-123"
            recipe["expect"]["collection"] = None

    assert run(materialize(tmp_path, documents))["needs_review"] is False


@pytest.mark.parametrize("url", ["//[", " /posts/a", "///posts/a", "/posts/a\n"])
def test_reconcile_reports_invalid_browser_urls_without_a_traceback(
    tmp_path, documents, url
):
    documents["handoff"]["parity"][0]["url"] = url
    with pytest.raises(FullstackError, match="navigation evidence"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "segment",
    [
        "",
        ".",
        "..",
        "%2e",
        "%2E%2E",
        "a/b",
        r"a\b",
        "%2f",
        "%2F",
        "a%2Fb",
        "%5c",
        "%5C",
        "a%5Cb",
        "%252f",
        "%255c",
        "a%3Fquery",
        "a%23fragment",
        "\x00",
        "\x1f",
        "\x7f",
        "%00",
        "%1F",
        "%7f",
        "has space",
        "%",
        "%ZZ",
        "[bracket]",
        "{id}",
        "{{}}",
    ],
)
def test_path_template_rejects_unsafe_concrete_segments(segment):
    assert not _path_matches_template("/records/{id}", f"/records/{segment}")


@pytest.mark.parametrize(
    "segment",
    [
        ".",
        "..",
        "%2e",
        "%2E%2E",
        "a/b",
        r"a\b",
        "a%2Fb",
        "a%5Cb",
        "%252f",
        "a%3Fquery",
        "a%23fragment",
        "\x00",
        "\x1f",
        "\x7f",
        "%00",
        "%1F",
        "%7f",
        "has space",
        "%",
        "%ZZ",
        "[bracket]",
        "{id}",
        "{{}}",
    ],
)
def test_reconcile_rejects_unsafe_concrete_capture_segments(
    tmp_path, documents, segment
):
    owner = next(case for case in documents["capture"] if case["id"] == "update-owner")
    owner["path"] = f"/api/collections/posts/records/{segment}"
    with pytest.raises(
        FullstackError,
        match="does not exercise PATCH|invalid backend replay capture",
    ):
        run(materialize(tmp_path, documents))


def test_hidden_password_fields_do_not_spoof_an_auth_collection(tmp_path, documents):
    users = documents["openapi"]["paths"]["/api/collections/users/records"]["post"]
    users["x-zigbase-collection-type"] = "base"
    create_handoff(documents)["endpoint"] = {
        "operation_id": "logout",
        "verb": "POST",
        "path": "/api/collections/users/auth-logout",
    }
    with pytest.raises(FullstackError, match="names non-auth collection 'users'"):
        run(materialize(tmp_path, documents))


def test_collection_operation_requires_current_collection_metadata(tmp_path, documents):
    del documents["openapi"]["paths"]["/api/collections/posts/records"]["get"][
        "x-zigbase-collection"
    ]
    with pytest.raises(FullstackError, match="must declare both collection markers"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "path",
    [
        "relative",
        "//host/path",
        "/api//records",
        "/api/:id",
        "/api/{bad-name}",
        "/api/{id}/{id}",
        "/api/%41",
    ],
)
def test_openapi_paths_must_use_the_exporter_route_grammar(tmp_path, documents, path):
    item = documents["openapi"]["paths"].pop("/api/collections/posts/records")
    documents["openapi"]["paths"][path] = item
    with pytest.raises(FullstackError, match="OpenAPI path .* is not canonical"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    "collection,path,method",
    [
        ("users", "/api/spoof", "post"),
        ("a/b", "/api/collections/a/b/records", "post"),
    ],
)
def test_collection_markers_are_bound_to_engine_collection_namespace(
    tmp_path, documents, collection, path, method
):
    operation = documents["openapi"]["paths"]["/api/collections/users/records"].pop(
        "post"
    )
    operation["x-zigbase-collection"] = collection
    if collection == "posts":
        operation["x-zigbase-collection-type"] = "base"
    documents["openapi"]["paths"][path] = {method: operation}
    with pytest.raises(
        FullstackError,
        match="invalid collection marker|outside its engine-owned collection namespace",
    ):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("value", [[], {}])
def test_collection_operation_rejects_non_string_collection_type(
    tmp_path, documents, value
):
    operation = documents["openapi"]["paths"]["/api/collections/posts/records"]["get"]
    operation["x-zigbase-collection-type"] = value
    with pytest.raises(FullstackError, match="unsupported x-zigbase-collection-type"):
        run(materialize(tmp_path, documents))


def test_collection_operations_require_one_consistent_collection_type(
    tmp_path, documents
):
    operation = documents["openapi"]["paths"]["/api/collections/posts/records"]["get"]
    operation["x-zigbase-collection-type"] = "auth"
    with pytest.raises(FullstackError, match="inconsistent collection types"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("value", [["posts"], {"name": "posts"}, 7, True, ""])
def test_collection_operation_requires_a_nonempty_string_collection_name(
    tmp_path, documents, value
):
    operation = documents["openapi"]["paths"]["/api/collections/posts/records"]["get"]
    operation["x-zigbase-collection"] = value

    with pytest.raises(FullstackError, match="x-zigbase-collection.*non-empty string"):
        run(materialize(tmp_path, documents))


def test_additional_exported_builtin_metadata_does_not_break_supported_contract(
    tmp_path, documents
):
    documents["openapi"]["x-zigbase-reserved-routes"].append(
        {
            "method": "POST",
            "path": "/api/collections/{col}/future-auth-action",
        }
    )
    documents["openapi"]["x-zigbase-builtin-operations"].append(
        {
            "operationId": "futureAuthAction",
            "method": "POST",
            "path": "/api/collections/{collection}/future-auth-action",
            "access": "authenticated",
            "collectionType": "auth",
        }
    )
    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_builtin_metadata_must_name_an_exported_reserved_route(tmp_path, documents):
    documents["openapi"]["x-zigbase-reserved-routes"] = [
        route
        for route in documents["openapi"]["x-zigbase-reserved-routes"]
        if route["path"] != "/api/collections/{col}/auth-refresh"
    ]
    with pytest.raises(FullstackError, match="not an exported reserved route"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize("coverage", [None, {}, {"collections": 1}])
def test_openapi_coverage_requires_known_boolean_fields(tmp_path, documents, coverage):
    if coverage is None:
        del documents["openapi"]["x-zigbase-coverage"]
    else:
        documents["openapi"]["x-zigbase-coverage"] = coverage
    with pytest.raises(FullstackError, match="x-zigbase-coverage"):
        run(materialize(tmp_path, documents))


def test_openapi_coverage_allows_new_boolean_capabilities(tmp_path, documents):
    documents["openapi"]["x-zigbase-coverage"]["future"] = True

    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_openapi_coverage_rejects_a_new_nonboolean_capability(tmp_path, documents):
    documents["openapi"]["x-zigbase-coverage"]["future"] = 1

    with pytest.raises(FullstackError, match="required boolean fields"):
        run(materialize(tmp_path, documents))


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("collections", False),
        ("admin", True),
        ("realtime", True),
        ("fileBytes", True),
        ("allAuthMethods", True),
    ],
)
def test_openapi_coverage_must_match_supported_exporter_scope(
    tmp_path, documents, field, value
):
    documents["openapi"]["x-zigbase-coverage"][field] = value
    with pytest.raises(FullstackError, match="disagrees with the supported exporter"):
        run(materialize(tmp_path, documents))


def test_openapi_consumer_route_coverage_must_match_paths(tmp_path, documents):
    documents["openapi"]["paths"]["/reports"] = {
        "get": {"operationId": "reports", "x-zigbase-auth": "public"}
    }
    with pytest.raises(FullstackError, match="coverage.consumerRoutes"):
        run(materialize(tmp_path, documents))

    mark_consumer_routes(documents)
    assert run(materialize(tmp_path, documents))["needs_review"] is False

    del documents["openapi"]["paths"]["/reports"]
    with pytest.raises(FullstackError, match="coverage.consumerRoutes"):
        run(materialize(tmp_path, documents))


def test_contract_version_marker_is_required_and_fixed(tmp_path, documents):
    del documents["openapi"]["x-zigbase-contract-version"]
    with pytest.raises(FullstackError, match="x-zigbase-contract-version"):
        run(materialize(tmp_path, documents))

    documents["openapi"]["x-zigbase-contract-version"] = "2.0.0"
    with pytest.raises(FullstackError, match="version marker is unsupported"):
        run(materialize(tmp_path, documents))


def test_application_api_version_is_independent_of_exporter_contract(
    tmp_path, documents
):
    documents["openapi"]["info"]["version"] = "2026-08"
    result = run(materialize(tmp_path, documents))
    assert result["contracts"]["zigbase_openapi"] == {
        "openapi": "3.1.2",
        "contract_version": OPENAPI_CONTRACT_VERSION,
    }


def test_builtin_metadata_accepts_the_exporters_actual_collection_placeholder(
    tmp_path, documents
):
    for operation in documents["openapi"]["x-zigbase-builtin-operations"]:
        operation["path"] = operation["path"].replace("{collection}", "{col}")

    assert run(materialize(tmp_path, documents))["needs_review"] is False


def test_backend_evidence_rejects_present_null_control(tmp_path, documents):
    documents["capture"][0]["expect"]["control"] = None
    with pytest.raises(
        FullstackError, match="expect.control must be a non-empty string"
    ):
        run(materialize(tmp_path, documents))


def test_ndjson_diagnostic_uses_physical_line_number(tmp_path, documents):
    paths = materialize(tmp_path, documents)
    paths["findings"].write_text("\n{}\nnot-json\n")
    with pytest.raises(
        FullstackError, match=r"backend replay findings line 3 is invalid JSON"
    ):
        run(paths)


def test_refuses_non_finite_numbers_in_source_artifacts(tmp_path, documents):
    documents["backend_routes"]["routes"][0]["weight"] = math.nan
    with pytest.raises(FullstackError, match="non-finite JSON number NaN"):
        run(materialize(tmp_path, documents))


def test_refuses_json_exponent_overflow_in_source_artifacts(tmp_path, documents):
    paths = materialize(tmp_path, documents)
    payload = paths["backend_routes"].read_text()
    assert '"count": 3' in payload
    paths["backend_routes"].write_text(payload.replace('"count": 3', '"count": 1e999'))

    with pytest.raises(FullstackError, match="non-finite JSON number 1e999"):
        run(paths)


@pytest.mark.parametrize(
    "schema",
    [
        {"oneOf": [{"type": "integer"}, {"type": "string", "pattern": "^a"}]},
        {"type": "object", "properties": {"value": {"anyOf": []}}},
        {"type": "array", "items": {"type": "string", "format": "uuid"}},
    ],
)
def test_schema_prevalidation_rejects_unsupported_keywords_at_any_depth(schema):
    with pytest.raises(FullstackError, match="unsupported keywords"):
        validate_schema(3, schema)


def test_schema_prevalidation_cannot_hide_drift_behind_a_matching_oneof_branch():
    with pytest.raises(FullstackError, match="pattern"):
        validate_schema(
            3,
            {
                "oneOf": [
                    {"type": "integer"},
                    {"type": "string", "pattern": "^a"},
                ]
            },
        )


def test_schema_definition_is_validated_once_not_per_value_node(monkeypatch):
    calls = 0
    original = fullstack_module._validate_schema_definition

    def counted(schema, label):  # noqa: ANN001
        nonlocal calls
        calls += 1
        return original(schema, label)

    monkeypatch.setattr(fullstack_module, "_validate_schema_definition", counted)
    validate_schema(list(range(20)), {"type": "array", "items": {"type": "integer"}})

    assert calls == 2  # root definition plus its one child definition


@pytest.mark.parametrize(
    ("schema", "message"),
    [
        ({"type": ["integer", "future"]}, "unsupported schema type"),
        ({"type": []}, "unsupported schema type"),
        ({"type": ["integer", "integer"]}, "unsupported schema type"),
        (
            {
                "type": "object",
                "properties": {"id": {"type": "integer"}},
                "required": "id",
            },
            "required must be unique property names",
        ),
        (
            {"type": "object", "properties": {}, "required": ["missing"]},
            "required must be unique property names",
        ),
        (
            {"type": "object", "additionalProperties": {}},
            "additionalProperties must be a boolean",
        ),
        ({"type": "string", "items": {"type": "string"}}, "items requires array"),
        ({"type": "string", "enum": []}, "enum must be a non-empty array"),
        ({"type": "integer", "minimum": True}, "minimum must be an integer"),
        ({"type": "object", "title": 3}, "title must be a string"),
    ],
)
def test_schema_prevalidation_rejects_unsupported_keyword_value_grammar(
    schema, message
):
    with pytest.raises(FullstackError, match=message):
        validate_schema(3, schema)


def test_schema_value_drift_cannot_hide_behind_a_matching_oneof_branch():
    with pytest.raises(FullstackError, match="unsupported schema type"):
        validate_schema(
            3,
            {
                "oneOf": [
                    {"type": "integer"},
                    {"type": ["string", "future"]},
                ]
            },
        )


def test_schema_enum_and_const_keep_json_booleans_distinct_from_integers():
    validate_schema(True, {"enum": [True, 1], "const": True})
    with pytest.raises(FullstackError, match="must equal"):
        validate_schema(1, {"const": True})


def test_canonical_writer_refuses_non_finite_numbers(tmp_path):
    with pytest.raises(FullstackError, match="cannot write manifest"):
        write_canonical(tmp_path / "manifest.json", {"weight": math.nan})


def test_canonical_writer_uses_safe_default_and_preserves_existing_mode(tmp_path):
    path = tmp_path / "manifest.json"
    write_canonical(path, {"version": 1})
    assert stat.S_IMODE(path.stat().st_mode) == 0o644
    path.chmod(0o640)
    write_canonical(path, {"version": 2})
    assert stat.S_IMODE(path.stat().st_mode) == 0o640


def test_manifest_blocker_without_finding_or_handoff_decision_can_block_route(
    tmp_path, documents
):
    code = "RAILS_TEMPLATE_UNREADABLE"
    documents["presentation"]["blockers"] = [
        {
            "code": code,
            "severity": "error",
            "integrity": True,
            "source": {"file": "app/views/posts/index.html.erb", "line": 1},
            "message": "template could not be read",
            "route_id": "GET /posts",
        }
    ]
    documents["handoff"]["routes"][0].update(
        status="blocked", artifacts=[], decision=None, findings=[]
    )
    documents["decisions"]["routes"][0].update(
        disposition="blocked", parity=[], blockers=[code]
    )
    result = run(materialize(tmp_path, documents))
    assert result["needs_review"] is True


def test_a_backend_route_cannot_be_accounted_away_as_blocked(tmp_path, documents):
    finding_id = "RAILS_BACKEND_ENDPOINT.config/routes%2Erb.L1.POST.posts"
    documents["presentation"]["findings"] = [
        {
            "id": finding_id,
            "code": "RAILS_BACKEND_ENDPOINT",
            "severity": "warn",
            "source": {"file": "config/routes.rb", "line": 1},
            "route_id": "POST /posts",
            "message": "route needs a backend operation",
            "choices": ["retain", "blocked"],
            "requires_artifact": False,
        }
    ]
    handoff = next(
        row
        for row in documents["handoff"]["routes"]
        if row["route_id"] == "POST /posts"
    )
    handoff.update(
        status="backend",
        artifacts=[],
        endpoint=None,
        decision={"id": finding_id, "choice": "blocked", "rationale": "unsupported"},
        findings=[finding_id],
    )
    decision = next(
        row
        for row in documents["decisions"]["routes"]
        if row["source"]["verb"] == "POST"
    )
    decision.update(disposition="blocked", parity=[], blockers=[finding_id])

    with pytest.raises(FullstackError, match="contradicts handoff status 'backend'"):
        run(materialize(tmp_path, documents))


def test_atomic_output_does_not_follow_the_legacy_temp_symlink(tmp_path, documents):
    result = run(materialize(tmp_path, documents))
    victim = tmp_path / "victim.txt"
    victim.write_text("keep me\n")
    (tmp_path / "manifest.json.tmp").symlink_to(victim)
    write_canonical(tmp_path / "manifest.json", result)
    assert victim.read_text() == "keep me\n"
    assert json.loads((tmp_path / "manifest.json").read_text()) == result


@pytest.mark.parametrize("bad_blockers", [None, {"x": 1}, 7, "finding", ["finding"]])
@pytest.mark.parametrize("disposition", ["migrated", "retained"])
def test_nonblocked_routes_require_an_empty_blocker_list(
    tmp_path, documents, disposition, bad_blockers
):
    decision = next(
        row
        for row in documents["decisions"]["routes"]
        if row["source"]["verb"] == "GET"
    )
    decision["disposition"] = disposition
    decision["blockers"] = bad_blockers
    if disposition != "migrated":
        documents["handoff"]["routes"][0]["status"] = "retained"
    with pytest.raises(FullstackError, match="must not name blockers"):
        run(materialize(tmp_path, documents))


def test_route_specific_blocker_is_not_covered_by_another_route(tmp_path, documents):
    code = "RAILS_HELPER_UNKNOWN"
    finding_id = f"{code}.get-posts"
    documents["presentation"]["blockers"] = [
        {
            "code": code,
            "severity": "warn",
            "integrity": False,
            "source": {"file": "app/views/posts/index.html.erb", "line": 1},
            "message": "unknown helper",
            "route_id": route_id,
        }
        for route_id in ("GET /posts", "POST /posts")
    ]
    documents["presentation"]["findings"] = [
        {
            "id": finding_id,
            "code": code,
            "severity": "warn",
            "source": {"file": "app/views/posts/index.html.erb", "line": 1},
            "route_id": "GET /posts",
            "message": "unknown helper",
            "choices": ["blocked"],
            "requires_artifact": False,
        }
    ]
    documents["handoff"]["routes"][0].update(
        status="blocked",
        artifacts=[],
        decision={"id": finding_id, "choice": "blocked", "rationale": "unsupported"},
        findings=[finding_id],
    )
    documents["decisions"]["routes"][0].update(
        disposition="blocked", parity=[], blockers=[finding_id]
    )
    with pytest.raises(FullstackError, match="POST /posts"):
        run(materialize(tmp_path, documents))

    documents["presentation"]["blockers"] = documents["presentation"]["blockers"][:1]
    result = run(materialize(tmp_path, documents))
    assert result["needs_review"] is True
    documents["presentation"]["blockers"][0]["route_id"] = None
    result = run(materialize(tmp_path, documents))
    assert result["needs_review"] is True


def test_cli_reports_output_filesystem_errors_without_a_traceback(
    tmp_path, documents, capsys
):
    paths = materialize(tmp_path, documents)
    argv = cli_args(paths, tmp_path)
    assert main(argv) == 1
    stderr = capsys.readouterr().err
    assert stderr.startswith("rails-fullstack: cannot write manifest")
    assert "Traceback" not in stderr


def test_cli_uses_exit_1_for_malformed_input(tmp_path, documents, capsys):
    paths = materialize(tmp_path, documents)
    paths["backend_routes"].write_text("not json\n")
    assert main(cli_args(paths, tmp_path / "manifest.json")) == 1
    assert "cannot read Rails routes inventory" in capsys.readouterr().err


def test_cli_uses_exit_1_for_argument_errors(capsys):
    assert main([]) == 1
    stderr = capsys.readouterr().err
    assert stderr.startswith("rails-fullstack: invalid command line:")
    assert "required" in stderr
    assert "Traceback" not in stderr


def test_cli_uses_exit_2_when_valid_artifacts_need_more_work(
    tmp_path, documents, capsys
):
    documents["handoff"]["complete"] = False
    paths = materialize(tmp_path, documents)
    assert main(cli_args(paths, tmp_path / "manifest.json")) == 2
    assert "handoff is incomplete" in capsys.readouterr().err


@pytest.mark.parametrize(
    "proof_gap",
    [
        "missing-decision",
        "missing-replacement",
        "missing-parity",
        "missing-control",
        "uncovered-blocker",
    ],
)
def test_cli_uses_exit_2_for_each_valid_but_incomplete_proof_class(
    tmp_path, documents, capsys, proof_gap
):
    if proof_gap == "missing-decision":
        documents["decisions"]["routes"].pop()
    elif proof_gap == "missing-replacement":
        documents["handoff"]["routes"][0].update(status="blocked", artifacts=[])
    elif proof_gap == "missing-parity":
        documents["decisions"]["routes"][0]["parity"] = []
    elif proof_gap == "missing-control":
        documents["decisions"]["routes"][2]["parity"].pop()
    else:
        documents["presentation"]["blockers"] = [
            {
                "code": "RAILS_HELPER_UNKNOWN",
                "severity": "warn",
                "integrity": False,
                "source": {"file": "app/views/posts/index.html.erb", "line": 1},
                "message": "unknown helper",
                "route_id": "GET /posts",
            }
        ]

    paths = materialize(tmp_path, documents)
    assert main(cli_args(paths, tmp_path / "manifest.json")) == 2
    assert capsys.readouterr().err.startswith("rails-fullstack:")


def test_shared_reader_accepts_inventory_above_the_legacy_16_mib_limit(tmp_path):
    inventory = {
        "source": "observed",
        "count": 1,
        "routes": [
            route(
                "GET",
                "/large",
                "large",
                "index",
                source="observed",
                padding="x" * (17 * 1024 * 1024),
            )
        ],
    }
    path = dump(tmp_path / "routes.json", inventory)
    routes, contract = load_backend_routes(path)
    assert len(routes) == 1
    assert contract["routes_sha256"]
