"""Deterministic artifact and live-behavior grader for the Rails API migration.

The four grades answer four different questions, and each is meant to be able to fail
on its own:

* ``completion`` — did the agent produce an honest, complete migration record? Bound to
  the snapshot it was made from, every blocker decided with a rationale, and the scope
  gate answered. A Rails migration that quietly implies it moved the frontend fails
  here however good the data is.
* ``rules_locked`` — is the public surface exactly the one that was reviewed? Blank is
  Locked in ZigBase, so the risk is not omission but an unreviewed ``@public``.
* ``tests_green`` — does the boundary the agent wrote pass, and does the running target
  actually enforce the semantics the guide demands, including the denied cases?
* ``deployed`` — does a fresh target survive the rehearsal: restart with the rehashed
  credential intact, and a backup restored into a *second* target.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sqlite3
import stat
import tempfile
from pathlib import Path
from typing import Any, Callable

from tools.rails import rails2zb

from ..result import EvalFailure
from . import GradeReport
from ._harness import (
    EVAL_ENVIRONMENT,
    canonical_executable,
    free_port,
    health_json,
    json_http_request,
    read_bounded_regular,
    regular_file_inventory,
    require_command_success,
    served_target,
    strict_json_loads,
    strict_utf8,
)
from .genesis import (
    Commands,
    DoctorReport,
    GradeFailure,
    SubprocessCommands,
    _failure,
    _wait_http,
    parse_doctor_ndjson,
    prepare_grader_scratch,
)

MAX_JSON_BYTES = 4 * 1024 * 1024
MAX_SOURCE_FILE_BYTES = 16 * 1024 * 1024
MAX_SOURCE_TOTAL_BYTES = 64 * 1024 * 1024
PINNED_SOURCE = (
    Path(__file__).resolve().parents[1] / "scenarios/rails-api/fixture/source"
)


#: Every row of the frozen snapshot, including the club `default_scope` hides. A
#: migration that reads through the model loses that one and looks correct doing it.
EXPECTED_ROWS = {
    "clubs": 3,
    "comments": 3,
    "events": 3,
    "flags": 2,
    "memberships": 4,
    "notifications": 1,
    "posts": 4,
    "users": 4,
}

#: Anonymous signup, and nothing else. The recorded HTTP corpus exercises it.
EXPECTED_PUBLIC = frozenset({("users", "create")})

#: The agent's own report. Exact: an extra field is drift, a missing one is a claim
#: withheld.
REPORT_FIELDS = {
    "zigbaseRailsMigrationReport",
    "railsVersion",
    "sourceMode",
    "bundle",
    "frontend",
    "publicRules",
    "checks",
    "unresolved",
    "rollback",
}

REQUIRED_CHECKS = {
    "scope",
    "bundle",
    "determinism",
    "rules",
    "auth",
    "rehash",
    "authorization",
    "parity",
    "timestamps",
    "files",
    "restart",
    "restore",
}

#: Nothing that could carry a credential belongs in a report that gets pasted around.
FORBIDDEN_REPORT_MARKERS = (
    "$2a$",
    "$2b$",
    "$2y$",
    "$argon2",
    "$zblegacy$",
    "secret_key_base",
    "password_digest",
    "-----BEGIN",
)

#: A claim that the frontend moved, and the negations that contain one verbatim.
#: Substring matching alone inverts meaning: "no frontend is migrated" is an honest
#: denial that CONTAINS "frontend is migrated", and the first version of this grader
#: rejected it as the very claim it was denying. Each claim is only a claim when no
#: negation immediately precedes it.
FRONTEND_CLAIMS = (
    "views were migrated",
    "views are migrated",
    "frontend was migrated",
    "frontend is migrated",
    "migrated the frontend",
    "migrated the views",
)

#: Words that turn a claim into its denial when they appear shortly before it. A
#: negation is not always adjacent — "no Rails frontend is migrated" puts a word in
#: between — so the few preceding words are searched rather than just the last one.
CLAIM_NEGATIONS = frozenset({"no", "not", "never", "nothing", "none", "neither"})
NEGATION_WINDOW = 4

#: Any of these says the frontend did not move. Requiring one exact phrase would fail
#: correct reports on wording, which measures the agent's phrasing rather than its work.
FRONTEND_DENIALS = (
    "not migrated",
    "never migrated",
    "were not ported",
    "not ported",
    "no frontend",
    "nothing was migrated from",
    "no rails frontend",
    "no presentation",
)

#: The rehearsal runs offline against a disposable target. A fixed secret keeps the
#: rehash-survives-restart check meaningful: a fresh one each boot would invalidate
#: every token and mask a credential that did not actually migrate.

LOGIN_EMAIL = "ada@example.test"
LOGIN_PASSWORD = "ada-password-1"

#: A second migrated user, who owns none of ada's rows. Owner-scoping is only
#: observable from an actor with nothing to see.
OTHER_EMAIL = "brian@example.test"
OTHER_PASSWORD = "brian-password-2"

#: `clubs.id=1` as the source recorded it (db/seeds.rb). Compared literally: a
#: `startswith("20")` check matched ZigBase's own write-time value and so could not
#: fail until the next century.
SEEDED_CLUB_CREATED = "2024-01-15T10:00:00Z"

#: The one Active Storage attachment in the snapshot, at the path the file route serves
#: it from once `install-files` has placed it.
MIGRATED_FILE_PATH = "/api/files/posts/1/morning-pages-cover.png"


def _json(path: Path, label: str) -> Any:
    try:
        raw = read_bounded_regular(path, MAX_JSON_BYTES)
        return strict_json_loads(strict_utf8(raw, str(path)))
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(
            f"completion.{label}_unreadable", f"{label} is unreadable: {exc}"
        ) from exc


def _source_files(root: Path) -> dict[Path, tuple[Path, int]]:
    try:
        return regular_file_inventory(
            root,
            ignored=lambda relative: (
                "__pycache__" in relative.parts
                or relative.suffix in {".pyc", ".pyo"}
                or relative.name.endswith(("-wal", "-shm"))
            ),
            maximum_file=MAX_SOURCE_FILE_BYTES,
            maximum_total=MAX_SOURCE_TOTAL_BYTES,
        )
    except ValueError as exc:
        raise GradeFailure("source.changed", f"source snapshot changed: {exc}") from exc
    except OSError as exc:
        raise GradeFailure(
            "source.unreadable", f"cannot inspect source: {exc}"
        ) from exc


def _verify_frozen_source(source: Path) -> None:
    expected = _source_files(PINNED_SOURCE)
    actual = _source_files(source)
    if set(expected) != set(actual) or any(
        actual[relative][1] != expected_size
        for relative, (_, expected_size) in expected.items()
    ):
        raise GradeFailure("source.changed", "source snapshot differs from the fixture")
    try:
        for relative, (expected_path, _) in expected.items():
            if read_bounded_regular(
                expected_path, MAX_SOURCE_FILE_BYTES
            ) != read_bounded_regular(actual[relative][0], MAX_SOURCE_FILE_BYTES):
                raise GradeFailure(
                    "source.changed", f"source artifact changed: {relative}"
                )
    except GradeFailure:
        raise
    except (OSError, ValueError) as exc:
        raise GradeFailure("source.unreadable", f"cannot read source: {exc}") from exc


def verify_source(source: Path) -> dict[str, Any]:
    """The snapshot must be exactly the one shipped, and still observed.

    The prompt says to leave `source/` byte-for-byte unchanged. An agent that edited the
    inventory to make a blocker disappear would otherwise grade as a clean migration.
    """
    freeze = _json(source / "freeze.json", "freeze")
    if freeze.get("rails_version") != "8.1.3.1":
        raise GradeFailure(
            "source.wrong_revision",
            f"the snapshot reports Rails {freeze.get('rails_version')!r}, not 8.1.3.1",
        )
    _verify_frozen_source(source)
    loaded = rails2zb.load_source(source)
    if loaded.mode != "observed":
        raise GradeFailure(
            "source.not_observed",
            f"the inventory is {loaded.mode!r}; an inferred one may not be reported as observed",
        )
    return {"inventory_sha256": rails2zb._inventory_digest(loaded), "mode": loaded.mode}


def _schema_public_rules(schema: Any) -> frozenset[tuple[str, str]]:
    """(collection, action) for every rule the emitted schema leaves open to anyone."""
    collections = schema.get("collections") if isinstance(schema, dict) else None
    if not isinstance(collections, list):
        raise GradeFailure(
            "completion.schema_shape", "schema.json has no collections array"
        )
    return frozenset(
        (collection["name"], key[: -len("Rule")])
        for collection in collections
        for key, value in collection.items()
        if key.endswith("Rule") and value == rails2zb.PUBLIC_RULE
    )


def load_reviewed_public_inventory(path: Path) -> frozenset[tuple[str, str]]:
    """`security/public-rules.json` — the compact reviewed contract, exactly."""
    value = _json(path, "public_rules")
    if not isinstance(value, dict) or set(value) != {"zigbasePublicRules", "rules"}:
        raise GradeFailure(
            "rules.inventory_shape",
            "public-rules.json must carry exactly zigbasePublicRules and rules",
        )
    if value["zigbasePublicRules"] != 1:
        raise GradeFailure(
            "rules.inventory_version", "unsupported public-rules version"
        )
    rules = value["rules"]
    if not isinstance(rules, list) or not all(isinstance(name, str) for name in rules):
        raise GradeFailure("rules.inventory_shape", "rules must be an array of strings")
    parsed = set()
    for name in rules:
        collection, _, action = name.partition(".")
        if not collection or not action:
            raise GradeFailure(
                "rules.inventory_shape", f"{name!r} is not `collection.action`"
            )
        parsed.add((collection, action))
    return frozenset(parsed)


def _validate_report(workspace: Path) -> dict[str, Any]:
    report = _json(workspace / "migration" / "report.json", "report")
    if not isinstance(report, dict):
        raise GradeFailure("completion.report_shape", "report.json must be an object")
    if set(report) != REPORT_FIELDS:
        missing = sorted(REPORT_FIELDS - set(report))
        extra = sorted(set(report) - REPORT_FIELDS)
        raise GradeFailure(
            "completion.report_fields",
            f"report field drift — missing={missing} extra={extra}",
        )
    if report["zigbaseRailsMigrationReport"] != 1:
        raise GradeFailure("completion.report_version", "unsupported report version")
    if report["sourceMode"] != "observed":
        raise GradeFailure(
            "completion.report_inferred",
            "an inferred inventory may not be reported as observed",
        )
    if report["unresolved"]:
        raise GradeFailure(
            "completion.unresolved",
            f"the migration reports unresolved work: {report['unresolved']}",
        )
    missing_checks = REQUIRED_CHECKS - set(report["checks"])
    if missing_checks:
        raise GradeFailure(
            "completion.checks", f"checks omitted: {sorted(missing_checks)}"
        )
    if report["bundle"] != "migration/bundle":
        raise GradeFailure(
            "completion.report_bundle",
            f"the report points at {report['bundle']!r}; the bundle this grader read is "
            f"migration/bundle, so the report describes something else",
        )
    if not str(report["rollback"]).strip():
        raise GradeFailure("completion.rollback", "the rollback unit is not described")

    frontend = str(report["frontend"])
    if not frontend.strip():
        raise GradeFailure(
            "completion.scope_gate",
            "the report does not state what happened to the Rails frontend",
        )
    lowered = " ".join(frontend.lower().split())
    for claim in FRONTEND_CLAIMS:
        index = lowered.find(claim)
        while index != -1:
            preceding = lowered[:index].split()[-NEGATION_WINDOW:]
            if not CLAIM_NEGATIONS.intersection(preceding):
                raise GradeFailure(
                    "completion.scope_gate",
                    f"the report claims Rails views or frontend behavior were "
                    f"migrated: {claim!r}",
                )
            index = lowered.find(claim, index + 1)
    if not any(denial in lowered for denial in FRONTEND_DENIALS):
        raise GradeFailure(
            "completion.scope_gate",
            "the report must say plainly that the Rails frontend did not migrate",
        )

    serialized = json.dumps(report)
    for marker in FORBIDDEN_REPORT_MARKERS:
        if marker in serialized:
            raise GradeFailure(
                "completion.report_secret", f"the report carries {marker!r}"
            )
    return report


def _verify_determinism(workspace: Path, source: Path) -> None:
    """Re-extract and compare, rather than believe the report.

    The prompt demands a bundle that is byte-identical across two separate runs and the
    report must list a `determinism` check — but a check nobody performs is a claim, and
    this grader was accepting the word for the deed. Extraction is offline and cheap, so
    the honest thing is to do it again.
    """
    decisions = rails2zb.load_decisions(workspace / "decisions.json")
    loaded = rails2zb.load_source(source)
    with tempfile.TemporaryDirectory(dir=workspace) as scratch:
        second = Path(scratch) / "bundle"
        try:
            rails2zb.extract(loaded, decisions, second)
        except rails2zb.RailsError as exc:
            raise GradeFailure(
                "completion.not_reproducible",
                f"the bundle could not be produced again from the same inputs: {exc}",
            ) from exc
        recorded = _json(workspace / "migration" / "bundle" / "hashes.json", "hashes")[
            "outputs"
        ]
        repeated = _json(second / "hashes.json", "hashes")["outputs"]
        if {e["path"]: e["sha256"] for e in recorded} != {
            e["path"]: e["sha256"] for e in repeated
        }:
            raise GradeFailure(
                "completion.nondeterministic",
                "a second extraction from the same source and decisions produced "
                "different bytes",
            )


def _verify_decisions(workspace: Path, source: Path) -> None:
    """Every blocker decided, with a rationale, against THIS snapshot's findings."""
    decisions = rails2zb.load_decisions(workspace / "decisions.json")
    findings = rails2zb.build_findings(rails2zb.load_source(source))
    try:
        rails2zb.reconcile(findings, decisions, artifact_root=workspace)
    except rails2zb.RailsError as exc:
        raise GradeFailure(
            "completion.decisions", f"decisions do not reconcile: {exc}"
        ) from exc
    thin = sorted(
        fid
        for fid, decision in decisions.items()
        if len(decision.rationale.strip()) < 12
    )
    if thin:
        raise GradeFailure(
            "completion.rationales",
            f"these decisions carry no usable rationale: {thin[:5]}",
        )


def _verify_bundle(
    workspace: Path, source: Path, expected_inventory: str
) -> dict[str, Any]:
    bundle = workspace / "migration" / "bundle"
    emitted = _json(bundle / "report.json", "bundle_report")
    if emitted.get("inventorySha256") != expected_inventory:
        raise GradeFailure(
            "completion.bundle_unbound",
            "the bundle was not built from this snapshot's inventory",
        )
    hashes = _json(bundle / "hashes.json", "hashes")
    if (
        not isinstance(hashes, dict)
        or set(hashes) != {"zigbaseRailsHashes", "outputs"}
        or hashes["zigbaseRailsHashes"] != 1
        or not isinstance(hashes["outputs"], list)
    ):
        raise GradeFailure(
            "completion.bundle_unattested", "hashes.json has an invalid envelope"
        )
    recorded: dict[str, tuple[int, str]] = {}
    for index, entry in enumerate(hashes["outputs"]):
        if not isinstance(entry, dict) or set(entry) != {"path", "bytes", "sha256"}:
            raise GradeFailure(
                "completion.bundle_unattested",
                f"hashes.json output {index} has an invalid shape",
            )
        relative, size, digest = entry["path"], entry["bytes"], entry["sha256"]
        relative_path = Path(relative) if isinstance(relative, str) else Path()
        if (
            not isinstance(relative, str)
            or not relative
            or relative_path.is_absolute()
            or ".." in relative_path.parts
            or "\\" in relative
            or "\x00" in relative
            or isinstance(size, bool)
            or not isinstance(size, int)
            or size < 0
            or not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise GradeFailure(
                "completion.bundle_unattested",
                f"hashes.json output {index} has invalid values",
            )
        if relative in recorded:
            raise GradeFailure(
                "completion.bundle_unattested",
                f"hashes.json repeats output path {relative!r}",
            )
        recorded[relative] = (size, digest)
    on_disk: dict[str, tuple[Path, int]] = {}
    total = 0
    try:
        for path in bundle.rglob("*"):
            relative = path.relative_to(bundle).as_posix()
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode) or not (
                stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)
            ):
                raise GradeFailure(
                    "completion.bundle_unsafe", f"unsafe bundle artifact: {relative}"
                )
            if stat.S_ISDIR(metadata.st_mode) or path.name == "hashes.json":
                continue
            if metadata.st_size > MAX_SOURCE_FILE_BYTES:
                raise GradeFailure(
                    "completion.bundle_unsafe", f"oversized bundle artifact: {relative}"
                )
            total += metadata.st_size
            if total > MAX_SOURCE_TOTAL_BYTES:
                raise GradeFailure(
                    "completion.bundle_unsafe", "migration bundle is oversized"
                )
            on_disk[relative] = (path, metadata.st_size)
    except OSError as exc:
        raise GradeFailure(
            "completion.bundle_unsafe", f"cannot inspect migration bundle: {exc}"
        ) from exc
    if set(recorded) != set(on_disk):
        raise GradeFailure(
            "completion.bundle_unattested",
            "hashes.json does not cover exactly the bundle's outputs",
        )
    for relative, (recorded_size, digest) in recorded.items():
        if on_disk[relative][1] != recorded_size:
            raise GradeFailure(
                "completion.bundle_corrupt",
                f"{relative} does not match its recorded size",
            )
        try:
            payload = read_bounded_regular(on_disk[relative][0], MAX_SOURCE_FILE_BYTES)
        except (OSError, ValueError) as exc:
            raise GradeFailure(
                "completion.bundle_unsafe",
                f"cannot safely read bundle artifact {relative}: {exc}",
            ) from exc
        if hashlib.sha256(payload).hexdigest() != digest:
            raise GradeFailure(
                "completion.bundle_corrupt",
                f"{relative} does not match its recorded hash",
            )
    counts = {entry["collection"]: entry["rows"] for entry in emitted["collections"]}
    if counts != EXPECTED_ROWS:
        raise GradeFailure(
            "completion.rows",
            f"row counts do not match the snapshot: {counts} != {EXPECTED_ROWS}",
        )
    return emitted


def inspect_completion(
    workspace: Path,
) -> tuple[dict[str, Any] | None, list[EvalFailure]]:
    """Everything gradeable without a running target."""
    failures: list[EvalFailure] = []
    try:
        source = workspace / "source"
        verified = verify_source(source)
        report = _validate_report(workspace)
        _verify_decisions(workspace, source)
        emitted = _verify_bundle(workspace, source, verified["inventory_sha256"])
        _verify_determinism(workspace, source)

        if report["railsVersion"] != emitted["railsVersion"]:
            raise GradeFailure(
                "completion.version_mismatch",
                "the report and the bundle disagree about the Rails version",
            )

        return report, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (rails2zb.RailsError, OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("completion.error", f"{type(exc).__name__}: {exc}"))
    return None, failures


def inspect_rules(workspace: Path, report: dict[str, Any] | None) -> list[EvalFailure]:
    """Whether the public surface is the reviewed one — on its own.

    Split out of `inspect_completion` deliberately. These raise `rules.*`, and
    `completion` is false whenever a `rules.*` failure appears, so leaving them inside
    the completion pass meant a purely authorization defect also sank an otherwise
    honest and complete migration record. Two grades moving for one fault tells the
    reader less than either grade alone.
    """
    failures: list[EvalFailure] = []
    try:
        schema = _json(workspace / "migration" / "bundle" / "schema.json", "schema")
        public = _schema_public_rules(schema)
        reviewed = load_reviewed_public_inventory(
            workspace / "security" / "public-rules.json"
        )
        if public != reviewed:
            raise GradeFailure(
                "rules.unreviewed_public",
                f"the schema grants {sorted(public)} but {sorted(reviewed)} was reviewed",
            )
        if public != EXPECTED_PUBLIC:
            raise GradeFailure(
                "rules.unexpected_public",
                f"the public surface is {sorted(public)}, not {sorted(EXPECTED_PUBLIC)}",
            )
        if report is not None and set(report["publicRules"]) != {
            f"{c}.{a}" for c, a in reviewed
        }:
            raise GradeFailure(
                "rules.report_drift",
                "the report's publicRules and the reviewed inventory disagree",
            )
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (rails2zb.RailsError, OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("rules.error", f"{type(exc).__name__}: {exc}"))
    return failures


def _binary(binary_path: str | None = None) -> str:
    candidate = binary_path or os.environ.get("ZIGBASE_EVAL_BINARY")
    if not candidate:
        raise GradeFailure(
            "rehearsal.binary_missing",
            "ZIGBASE_EVAL_BINARY is not set; the rehearsal needs the pinned binary",
        )
    resolved = canonical_executable(candidate)
    if resolved is None:
        raise GradeFailure(
            "rehearsal.binary_missing", f"no regular executable binary at {candidate}"
        )
    return str(resolved)


def _request(
    method: str, url: str, *, token: str | None = None, body: Any = None
) -> tuple[int, bytes]:
    status, payload, _ = json_http_request(method, url, token=token, body=body)
    return status, payload


def _response_json(payload: bytes, code: str) -> dict[str, Any]:
    try:
        value = strict_json_loads(strict_utf8(payload, f"{code} response"))
    except (ValueError, json.JSONDecodeError) as exc:
        raise GradeFailure(code, "target returned malformed JSON") from exc
    if not isinstance(value, dict):
        raise GradeFailure(code, "target response is not a JSON object")
    return value


def _run_ok(result: Any, code: str, what: str) -> None:
    require_command_success(result, code, what, GradeFailure)


def _check_rehearsal_start(result: Any) -> None:
    _run_ok(result, "rehearsal.serve", "starting the rehearsal server")


def _rehearsal_teardown_failure(result: Any) -> EvalFailure | None:
    if isinstance(result, Exception):
        return _failure(
            "tests.teardown",
            f"the rehearsal server stop command failed: {type(result).__name__}: {result}",
        )
    return (
        None
        if result.returncode == 0
        else _failure(
            "tests.teardown",
            "the rehearsal server did not stop; a later run would find the data dir "
            "owned by an orphan",
        )
    )


def _check_deployment_start(result: Any) -> None:
    _run_ok(result, "deployment.serve", "starting a server on the restored copy")


def _deployment_teardown_failure(result: Any) -> EvalFailure | None:
    if isinstance(result, Exception):
        return _failure(
            "deployment.teardown",
            f"the restored server stop command failed: {type(result).__name__}: {result}",
        )
    return (
        None
        if result.returncode == 0
        else _failure("deployment.teardown", "the restored server did not stop")
    )


def probe_behavior(
    base: str, *, http_request: Callable[..., tuple[int, bytes]] = _request
) -> None:
    """The semantics the guide demands, against a running target.

    Verified against the real server rather than assumed, because the first version of
    this function asserted the wrong thing: it expected `401` for an unauthenticated
    list. ZigBase does not answer `401` there — an access rule that hides every row is
    not an authentication failure, so the list succeeds and is EMPTY. That is precisely
    the semantic the guide tells the operator not to "fix", and encoding it backwards
    here would have failed every correct migration.
    """
    status, payload = http_request(
        "POST",
        f"{base}/api/collections/users/auth-with-password",
        body={"identity": LOGIN_EMAIL, "password": LOGIN_PASSWORD},
    )
    if status != 200:
        raise GradeFailure(
            "parity.legacy_login",
            f"the migrated bcrypt credential did not log in ({status})",
        )
    token = _response_json(payload, "parity.legacy_login").get("token")
    if not token:
        raise GradeFailure("parity.legacy_login", "login returned no token")

    # A rule that hides every row: 200 and an empty array, never 401 or 403.
    status, payload = http_request("GET", f"{base}/api/collections/posts/records")
    if status != 200:
        raise GradeFailure(
            "parity.empty_list",
            f"an unauthenticated list returned {status}; a rule hiding every row "
            f"answers 200 with an empty array",
        )
    if _response_json(payload, "parity.empty_list").get("items") != []:
        raise GradeFailure("parity.empty_list", "an unauthenticated list leaked rows")

    # A single record the caller may not see is CONCEALED, not announced.
    status, _ = http_request("GET", f"{base}/api/collections/posts/records/1")
    if status != 404:
        raise GradeFailure(
            "parity.concealment",
            f"a record the caller may not see returned {status}; it must be 404",
        )

    # Owner-scoping, from BOTH sides. Asserting only that the owner sees their row is
    # satisfied by a rule that scopes nothing — every row in this collection belongs to
    # the login user — so the load-bearing half is the second actor seeing none.
    status, payload = http_request(
        "GET", f"{base}/api/collections/notifications/records", token=token
    )
    if status != 200:
        raise GradeFailure(
            "parity.owner_scope", f"an owner-scoped list returned {status}, not 200"
        )
    if (
        len(_response_json(payload, "parity.owner_scope").get("items") or [])
        != EXPECTED_ROWS["notifications"]
    ):
        raise GradeFailure(
            "parity.owner_scope", "the owner cannot see their own notification"
        )

    status, payload = http_request(
        "POST",
        f"{base}/api/collections/users/auth-with-password",
        body={"identity": OTHER_EMAIL, "password": OTHER_PASSWORD},
    )
    if status != 200:
        raise GradeFailure(
            "parity.legacy_login",
            f"the second migrated credential did not log in ({status})",
        )
    other = _response_json(payload, "parity.legacy_login").get("token")
    status, payload = http_request(
        "GET", f"{base}/api/collections/notifications/records", token=other
    )
    if status != 200 or (
        _response_json(payload, "parity.owner_scope").get("items") or []
    ):
        raise GradeFailure(
            "parity.owner_scope",
            "a second actor can see notifications belonging to someone else",
        )

    # An Active Storage blob the install placed, fetched over the file route. The
    # installer's return value was discarded and no probe touched a blob, so `files`
    # was a claim: an empty manifest installs zero files and reports success.
    status, payload = http_request("GET", f"{base}{MIGRATED_FILE_PATH}", token=token)
    if status != 200 or not payload:
        raise GradeFailure(
            "parity.files",
            f"the migrated attachment did not serve from {MIGRATED_FILE_PATH} ({status})",
        )
    # And the file route is rule-scoped like the record it hangs off: the owning post is
    # visible only to an authenticated caller, so an anonymous fetch is concealed rather
    # than served. Installing the bytes is not the same as protecting them.
    status, _ = http_request("GET", f"{base}{MIGRATED_FILE_PATH}")
    if status != 404:
        raise GradeFailure(
            "parity.files",
            f"an anonymous fetch of a migrated attachment returned {status}; the file "
            f"route must conceal it as 404 like the record it belongs to",
        )

    # Public signup exists, and still validates.
    status, _ = http_request(
        "POST",
        f"{base}/api/collections/users/records",
        body={"email": "not-an-email"},
    )
    if status not in (400, 422):
        raise GradeFailure(
            "parity.validation",
            f"an invalid signup returned {status}, not a validation failure",
        )


def _inspect_database(data_dir: Path) -> None:
    """Timestamps and the rehash, read from the target rather than from a summary."""
    database = data_dir / "data.db"
    if not database.is_file():
        raise GradeFailure("rehearsal.no_database", f"no target database at {database}")
    connection = sqlite3.connect(database)
    try:
        digest = connection.execute(
            "SELECT passwordHash FROM users WHERE email = ?", (LOGIN_EMAIL,)
        ).fetchone()
        if not digest:
            raise GradeFailure(
                "rehearsal.missing_user", f"{LOGIN_EMAIL} did not migrate"
            )
        if not str(digest[0]).startswith("$argon2"):
            raise GradeFailure(
                "rehearsal.no_rehash",
                "the legacy bcrypt digest was not rehashed to argon2id on login",
            )
        # Counts from the target's own tables, not from a rule-scoped list: `flags` and
        # `notifications` are owner-scoped, so an HTTP count measures what one actor may
        # see and would read 1 of 2 flags as a missing row. The guide says to verify
        # counts directly rather than trust a summary; this is that.
        for collection, expected in sorted(EXPECTED_ROWS.items()):
            actual = connection.execute(
                f'SELECT COUNT(*) FROM "{collection}"'  # noqa: S608 - fixed names
            ).fetchone()[0]
            if actual != expected:
                raise GradeFailure(
                    "rehearsal.target_rows",
                    f"{collection} holds {actual} rows on the target, not {expected}",
                )

        created = connection.execute(
            "SELECT created FROM clubs WHERE id = '1'"
        ).fetchone()
        if not created or str(created[0]) != SEEDED_CLUB_CREATED:
            raise GradeFailure(
                "rehearsal.timestamps",
                f"clubs.1 was imported with created={created and created[0]!r}, not the "
                f"source's {SEEDED_CLUB_CREATED!r}; --preserve-timestamps did not apply",
            )
    finally:
        connection.close()


def run_rehearsal(
    workspace: Path,
    artifacts: Path,
    commands: Commands,
    *,
    port_picker: Callable[[], int] = free_port,
    binary_path: str | None = None,
    behavior_probe: Callable[..., None] = probe_behavior,
    database_inspector: Callable[..., None] = _inspect_database,
    file_installer: Callable[..., dict[str, int]] = rails2zb.install_files,
    health_getter: Callable[..., Any] = health_json,
    health_attempts: int = 30,
) -> tuple[bool, DoctorReport | None, list[EvalFailure]]:
    failures: list[EvalFailure] = []
    doctor: DoctorReport | None = None
    try:
        binary = _binary(binary_path)
        bundle = workspace / "migration" / "bundle"
        target = workspace / ".rehearsal" / "data"
        target.mkdir(parents=True, exist_ok=True)
        # `_grader_environment` points HOME and TMPDIR at these, and the runner creates
        # them when it stages a workspace — but a grader pointed at an existing
        # workspace has no runner behind it, and facil.io needs a real TMPDIR to open
        # its cluster socket. Without them `serve` dies with a FATAL nobody would trace
        # back to a missing directory.
        prepare_grader_scratch(workspace)
        env = dict(EVAL_ENVIRONMENT)

        _run_ok(
            commands.run(
                [
                    binary,
                    "schema",
                    "apply",
                    "--data-dir",
                    str(target),
                    "--dry-run",
                    str(bundle / "schema.json"),
                ],
                cwd=workspace,
                env=env,
            ),
            "rehearsal.schema_dry_run",
            "the schema dry run",
        )
        _run_ok(
            commands.run(
                [
                    binary,
                    "schema",
                    "apply",
                    "--data-dir",
                    str(target),
                    str(bundle / "schema.json"),
                ],
                cwd=workspace,
                env=env,
            ),
            "rehearsal.schema_apply",
            "applying the schema",
        )
        _run_ok(
            commands.run(
                [
                    binary,
                    "import",
                    "--data-dir",
                    str(target),
                    "--collection",
                    "users",
                    "--legacy-hashes",
                    "bcrypt",
                    "--preserve-timestamps",
                    str(bundle / "auth" / "users.ndjson"),
                ],
                cwd=workspace,
                env=env,
            ),
            "rehearsal.auth_import",
            "importing auth",
        )
        _run_ok(
            commands.run(
                [
                    binary,
                    "import",
                    "--data-dir",
                    str(target),
                    "--manifest",
                    str(bundle / "manifest.json"),
                    "--preserve-timestamps",
                ],
                cwd=workspace,
                env=env,
            ),
            "rehearsal.data_import",
            "importing ordinary data",
        )
        # `install_files(bundle, source_root, data_dir)`: the blobs are read from the
        # frozen snapshot and placed under the target's own storage layout.
        file_installer(bundle, workspace / "source", target)

        doctor_result = commands.run(
            [binary, "doctor", "--data-dir", str(target), "--production", "--json"],
            cwd=workspace,
            env=env,
        )
        # `doctor` exits non-zero when it finds errors, which is a finding rather than a
        # crash — but truncated output silently loses the summary line and surfaces as a
        # malformed-NDJSON failure that reads like the target's fault.
        if doctor_result.output_truncated:
            raise GradeFailure(
                "rules.doctor_truncated",
                "doctor output was truncated, so its summary cannot be trusted",
            )
        doctor = parse_doctor_ndjson(doctor_result.stdout)

        with served_target(
            commands,
            binary,
            workspace,
            target,
            port_picker(),
            health_getter,
            _wait_http,
            failures,
            _check_rehearsal_start,
            _rehearsal_teardown_failure,
            health_attempts=health_attempts,
        ) as base:
            # `--background` rather than a Popen: `serve` DETACHES on its own inside any
            # AI-agent environment (src/serve_control.zig sniffs CLAUDECODE and friends),
            # so a foreground child forks and exits and `terminate()` kills a corpse --
            # leaving a live server holding the port and the data dir, and letting the
            # restore copy a database out from under a running writer. Going through
            # `commands.run` also keeps the server on the same allowlisted environment
            # every other command gets, so `doctor` judges the configuration that is
            # actually serving.
            behavior_probe(base)
            database_inspector(target)
        return True, doctor, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (rails2zb.RailsError, OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("rehearsal.error", f"{type(exc).__name__}: {exc}"))
    return False, doctor, failures


def run_agent_boundary(
    workspace: Path,
    commands: Commands,
    *,
    binary_path: str | None = None,
) -> tuple[bool, list[EvalFailure]]:
    """Run mutable agent-authored code only after every trusted live probe is done."""
    failures: list[EvalFailure] = []
    try:
        binary = _binary(binary_path)
        result = commands.run(
            [
                "python3",
                "-m",
                "unittest",
                "discover",
                "-s",
                "tests",
                "-p",
                "test_migration.py",
            ],
            cwd=workspace,
            env={**EVAL_ENVIRONMENT, "ZIGBASE_BINARY": binary},
        )
        _run_ok(result, "tests.boundary_failed", "the agent's migration boundary")
        return True, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (OSError, TypeError, ValueError) as exc:
        failures.append(
            _failure("tests.boundary_error", f"{type(exc).__name__}: {exc}")
        )
    return False, failures


def run_restore(
    workspace: Path,
    artifacts: Path,
    commands: Commands,
    *,
    binary_path: str | None = None,
    port_picker: Callable[[], int] = free_port,
    health_getter: Callable[..., Any] = health_json,
    health_attempts: int = 30,
    restore_probe: Callable[..., None] = None,  # type: ignore[assignment]
    database_inspector: Callable[..., None] = _inspect_database,
) -> tuple[bool, list[EvalFailure]]:
    """The rehearsal's last obligation: the target survives being restored elsewhere.

    ZigBase has no `backup` subcommand and does not need one — for SQLite the documented
    portable backup is a stop and a copy of the whole data directory, which captures
    `data.db`, its WAL state, uploaded files and `.jwt_secret` together
    (docs/deployment.md). Anything less is not a rollback unit: restore the database
    without `.jwt_secret` and every migrated session is void.

    So this copies the rehearsed target, verifies its database directly, boots a server
    on the copy, and proves the migrated credential still logs in there. Authorization
    semantics stay in ``tests_green``; repeating one here would let one rule defect sink
    two supposedly independent grades. A backup that cannot serve is not a backup.
    """
    failures: list[EvalFailure] = []
    try:
        binary = _binary(binary_path)
        target = workspace / ".rehearsal" / "data"
        second = workspace / ".rehearsal" / "restored"
        if not target.is_dir():
            raise GradeFailure(
                "deployment.no_target", "the rehearsal left no target to restore from"
            )
        if second.exists():
            shutil.rmtree(second)
        shutil.copytree(target, second)
        # Completeness by comparison, not by naming files. The data dir holds `data.db`,
        # its WAL state, uploaded files and — only when the server generated rather than
        # was given one — `.jwt_secret`. Requiring that filename fails a deployment
        # whose secret comes from the environment, which is the ordinary production
        # shape; requiring the copy to match the original catches a partial backup
        # either way.
        # No `original - copied` comparison: `copytree` produced `second` from `target`
        # two statements earlier, so comparing them compares a directory with its own
        # copy and can only ever pass. What is worth proving is that the copy SERVES.
        if not (second / "data.db").is_file():
            raise GradeFailure(
                "deployment.incomplete_unit", "the copied backup has no data.db"
            )

        with served_target(
            commands,
            binary,
            workspace,
            second,
            port_picker(),
            health_getter,
            _wait_http,
            failures,
            _check_deployment_start,
            _deployment_teardown_failure,
            health_attempts=health_attempts,
        ) as base:
            database_inspector(second)
            (restore_probe or _probe_restored)(base)
        return True, failures
    except GradeFailure as exc:
        failures.append(_failure(exc.code, str(exc)))
    except (OSError, KeyError, TypeError, ValueError) as exc:
        failures.append(_failure("deployment.error", f"{type(exc).__name__}: {exc}"))
    return False, failures


def _probe_restored(
    base: str, *, http_request: Callable[..., tuple[int, bytes]] = _request
) -> None:
    """The restored copy must serve the migration, not merely boot."""
    status, payload = http_request(
        "POST",
        f"{base}/api/collections/users/auth-with-password",
        body={"identity": LOGIN_EMAIL, "password": LOGIN_PASSWORD},
    )
    if status != 200:
        raise GradeFailure(
            "deployment.restored_login",
            f"the migrated credential did not log in against the restored copy ({status})",
        )
    if not _response_json(payload, "restore.legacy_login").get("token"):
        raise GradeFailure(
            "deployment.restored_login",
            "login against the restored copy returned no token",
        )


def grade(
    workspace: Path,
    artifacts: Path,
    *,
    commands: Commands | None = None,
    port_picker: Callable[[], int] = free_port,
    binary_path: str | None = None,
    behavior_probe: Callable[..., None] = probe_behavior,
    database_inspector: Callable[..., None] = _inspect_database,
    file_installer: Callable[..., dict[str, int]] = rails2zb.install_files,
    health_getter: Callable[..., Any] = health_json,
    health_attempts: int = 30,
    restore_probe: Callable[..., None] | None = None,
) -> GradeReport:
    artifacts.mkdir(parents=True, exist_ok=True)
    commands = commands or SubprocessCommands(artifacts)

    report, completion_failures = inspect_completion(workspace)
    rules_failures = inspect_rules(workspace, report)
    failures = list(completion_failures) + list(rules_failures)

    tests_green, doctor, rehearsal_failures = run_rehearsal(
        workspace,
        artifacts,
        commands,
        port_picker=port_picker,
        binary_path=binary_path,
        behavior_probe=behavior_probe,
        database_inspector=database_inspector,
        file_installer=file_installer,
        health_getter=health_getter,
        health_attempts=health_attempts,
    )
    failures.extend(rehearsal_failures)

    deployed, restore_failures = run_restore(
        workspace,
        artifacts,
        commands,
        binary_path=binary_path,
        port_picker=port_picker,
        health_getter=health_getter,
        health_attempts=health_attempts,
        restore_probe=restore_probe,
        database_inspector=database_inspector,
    )
    failures.extend(restore_failures)

    boundary_green, boundary_failures = run_agent_boundary(
        workspace, commands, binary_path=binary_path
    )
    failures.extend(boundary_failures)
    tests_green = tests_green and boundary_green

    # `rules_locked` does not depend on the rehearsal reaching doctor. Every step before
    # the doctor call — schema apply, either import — used to leave `doctor` None and so
    # sink this grade alongside `tests_green`, which says nothing about authorization.
    # The static half stands on its own; doctor only ever tightens it.
    rules_locked = not rules_failures and (
        doctor is None
        or (doctor.public_rules == EXPECTED_PUBLIC and doctor.errors == 0)
    )
    completion = report is not None and not any(
        failure.code.startswith(("completion.", "source."))
        for failure in completion_failures
    )
    return GradeReport(completion, rules_locked, tests_green, deployed, tuple(failures))
