#!/usr/bin/env python3
"""Reconcile Rails backend and Zigapagos presentation migration evidence.

The Rails API converter and Zigapagos deliberately own different halves of a
migration.  This tool consumes their released artifacts and produces the one
route map used to decide whether a full-stack migration is complete.
"""

from __future__ import annotations

import argparse
from functools import lru_cache
import json
import re
import sys
import urllib.parse
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.rails._core import (
    JSON_LIMIT,
    RailsError,
    canonical_text,
    parse_json,
    read_bytes,
    read_json as core_read_json,
    read_json_with_sha256,
    validate_inventory_source,
    write_canonical_json,
)
from tools.replay._contract import EVIDENCE_CONTROLS, allowed_controls_for_status


FULLSTACK_VERSION = 1
RAILS_INVENTORY_VERSION = 1
PRESENTATION_SCHEMA = "zigapagos.rails-presentation/1"
HANDOFF_SCHEMA = "zigapagos.rails-handoff/1"
DECISIONS_VERSION = 1
REPLAY_VERSION = 1
MAX_INPUT_BYTES = JSON_LIMIT
MUTATING_VERBS = frozenset({"POST", "PUT", "PATCH", "DELETE"})
HTTP_VERBS = frozenset({"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})
AUTH_VALUES = frozenset(
    {
        "public",
        "authenticated",
        "conditional",
        "superuser",
        "path-secret",
        "not-applicable",
    }
)
DISPOSITIONS = frozenset({"migrated", "retained", "blocked", "retired"})
EXPECTED_DISPOSITIONS = {
    "blocked": frozenset({"blocked"}),
    "retained": frozenset({"retained", "retired"}),
    "migrated": frozenset({"migrated"}),
    "backend": frozenset({"migrated"}),
    "redirect": frozenset({"migrated", "retained"}),
}
EVIDENCE_KINDS = frozenset({"backend", "browser"})
SCHEMA_ROOT = Path(__file__).with_name("contracts")
PRESENTATION_SCHEMA_PATH = SCHEMA_ROOT / "rails-presentation.v1.schema.json"
HANDOFF_SCHEMA_PATH = SCHEMA_ROOT / "rails-handoff.v1.schema.json"
BROWSER_CONTROLS = {
    "navigate": "journey",
    "asset": "journey",
    "signup": "allowed",
    "signin": "allowed",
    "submit_allowed": "allowed",
    "submit_denied": "denied",
    "validation_error": "validation",
}
BUILTIN_ENDPOINTS = {
    "authWithPassword": ("public", "auth-with-password"),
    "authRefresh": ("authenticated", "auth-refresh"),
    "logout": ("public", "auth-logout"),
    "requestVerification": ("public", "request-verification"),
    "confirmVerification": ("public", "confirm-verification"),
    "requestPasswordReset": ("public", "request-password-reset"),
    "confirmPasswordReset": ("public", "confirm-password-reset"),
}
KNOWN_ENDPOINT_ACCESS = frozenset(
    {"public", "conditional", "authenticated", "superuser", "path-secret", "locked"}
)
CUSTOM_ENDPOINT_ACCESS = KNOWN_ENDPOINT_ACCESS - {"locked"}
SUPPORTED_SCHEMA_KEYWORDS = frozenset(
    {
        "$schema",
        "$id",
        "title",
        "description",
        "type",
        "properties",
        "required",
        "additionalProperties",
        "items",
        "enum",
        "const",
        "minimum",
        "oneOf",
    }
)


class FullstackError(RuntimeError):
    """The supplied artifacts cannot prove a complete full-stack migration."""


def read_json(path: Path, label: str) -> Any:
    try:
        return core_read_json(path, limit=MAX_INPUT_BYTES, label=label)
    except RailsError as exc:
        raise FullstackError(str(exc)) from exc


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise FullstackError(f"{label} must be a JSON object")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise FullstackError(f"{label} must be a JSON array")
    return value


def _schema_type_matches(value: Any, expected: str) -> bool:
    if expected == "null":
        return value is None
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    return False


def validate_schema(value: Any, schema: dict[str, Any], label: str = "$") -> None:
    """Validate the released Zigapagos schemas without a third-party runtime.

    The generated v1 schemas deliberately use a small JSON Schema subset. Keep
    this validator fail-closed if a future schema introduces an unsupported
    structural keyword; the schema id must be bumped before that shape is read.
    """
    structural = set(schema) - SUPPORTED_SCHEMA_KEYWORDS
    if structural:
        raise FullstackError(
            f"{label} schema uses unsupported keywords {sorted(structural)}"
        )

    if "oneOf" in schema:
        matches = 0
        for option in schema["oneOf"]:
            try:
                validate_schema(value, option, label)
                matches += 1
            except FullstackError:
                pass
        if matches != 1:
            raise FullstackError(
                f"{label} must match exactly one released schema variant; matched {matches}"
            )
        return

    expected = schema.get("type")
    if expected is not None:
        choices = expected if isinstance(expected, list) else [expected]
        if not all(isinstance(choice, str) for choice in choices) or not any(
            _schema_type_matches(value, choice) for choice in choices
        ):
            raise FullstackError(f"{label} does not match schema type {expected!r}")
    if "const" in schema and value != schema["const"]:
        raise FullstackError(f"{label} must equal {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        raise FullstackError(f"{label} is not one of {schema['enum']!r}")
    if "minimum" in schema and isinstance(value, int) and value < schema["minimum"]:
        raise FullstackError(f"{label} is below the schema minimum")

    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                raise FullstackError(
                    f"{label}.{key} is required by the released schema"
                )
        if schema.get("additionalProperties") is False:
            extra = set(value) - set(properties)
            if extra:
                raise FullstackError(f"{label} has unknown fields {sorted(extra)}")
        for key, child in value.items():
            if key in properties:
                validate_schema(child, properties[key], f"{label}.{key}")
    if isinstance(value, list) and "items" in schema:
        for index, child in enumerate(value):
            validate_schema(child, schema["items"], f"{label}[{index}]")


@lru_cache(maxsize=None)
def _released_schema(schema_path: Path) -> dict[str, Any]:
    label = f"released schema {schema_path.name}"
    return require_object(read_json(schema_path, label), label)


def validate_released_contract(value: Any, schema_path: Path, label: str) -> None:
    schema = _released_schema(schema_path)
    validate_schema(value, schema, label)


def text(value: Any, label: str, *, nullable: bool = False) -> str | None:
    if nullable and value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise FullstackError(f"{label} must be a non-empty string")
    return value


@dataclass(frozen=True)
class RouteIdentity:
    verb: str
    path: str
    controller: str | None
    action: str | None
    occurrence: int

    def wire(self) -> dict[str, Any]:
        return {
            "verb": self.verb,
            "path": self.path,
            "controller": self.controller,
            "action": self.action,
            "occurrence": self.occurrence,
        }

    def label(self) -> str:
        target = "#".join(part or "-" for part in (self.controller, self.action))
        return f"{self.verb} {self.path} ({target}) occurrence {self.occurrence}"

    def sort_key(self) -> tuple[str, str, str, str, int]:
        return (
            self.verb,
            self.path,
            self.controller or "",
            self.action or "",
            self.occurrence,
        )


def route_methods(verb: str) -> frozenset[str]:
    normalized = verb.upper()
    if normalized == "ANY":
        return HTTP_VERBS
    methods = normalized.split("|")
    if not methods or any(method not in HTTP_VERBS for method in methods):
        raise FullstackError(
            f"route.verb {verb!r} is not a supported Rails verb expression"
        )
    return frozenset(methods)


def route_allows_method(verb: str, method: str) -> bool:
    return method.upper() in route_methods(verb)


def route_is_mutating(verb: str) -> bool:
    return bool(route_methods(verb) & MUTATING_VERBS)


def _route_identity(route: dict[str, Any], occurrence: int) -> RouteIdentity:
    verb = text(route.get("verb"), "route.verb")
    path = text(route.get("path"), "route.path")
    controller = text(route.get("controller"), "route.controller", nullable=True)
    action = text(route.get("action"), "route.action", nullable=True)
    verb = verb.upper()
    route_methods(verb)
    return RouteIdentity(verb, path, controller, action, occurrence)


def _identities(
    routes: Iterable[dict[str, Any]],
) -> list[tuple[RouteIdentity, dict[str, Any]]]:
    seen: Counter[tuple[str, str, str | None, str | None]] = Counter()
    result = []
    for route in routes:
        base = (
            str(route.get("verb", "")).upper(),
            str(route.get("path", "")),
            route.get("controller"),
            route.get("action"),
        )
        seen[base] += 1
        result.append((_route_identity(route, seen[base]), route))
    return result


def _decision_identity(value: Any, label: str) -> RouteIdentity:
    source = require_object(value, label)
    occurrence = source.get("occurrence")
    if (
        not isinstance(occurrence, int)
        or isinstance(occurrence, bool)
        or occurrence < 1
    ):
        raise FullstackError(f"{label}.occurrence must be a positive integer")
    return _route_identity(source, occurrence)


def load_backend_routes(
    path: Path,
) -> tuple[list[tuple[RouteIdentity, dict[str, Any]]], dict[str, Any]]:
    try:
        raw_document, routes_sha256 = read_json_with_sha256(
            path, limit=MAX_INPUT_BYTES, label="Rails routes inventory"
        )
    except RailsError as exc:
        raise FullstackError(str(exc)) from exc
    document = require_object(raw_document, "Rails routes inventory")
    try:
        validate_inventory_source(document, name="routes", expected_mode="observed")
    except RailsError as exc:
        raise FullstackError(str(exc)) from exc
    routes = require_list(document.get("routes"), "Rails routes inventory.routes")
    if document.get("count") != len(routes):
        raise FullstackError("Rails routes inventory.count does not match routes[]")
    if not all(isinstance(route, dict) for route in routes):
        raise FullstackError("Rails routes inventory.routes[] must contain objects")
    return _identities(routes), {
        "version": RAILS_INVENTORY_VERSION,
        "source_mode": "observed",
        "routes_sha256": routes_sha256,
    }


def load_presentation(
    path: Path,
) -> tuple[dict[str, Any], list[tuple[RouteIdentity, dict[str, Any]]]]:
    document = require_object(
        read_json(path, "Zigapagos presentation manifest"), "presentation manifest"
    )
    validate_released_contract(
        document, PRESENTATION_SCHEMA_PATH, "presentation manifest"
    )
    if (
        document.get("schema") != PRESENTATION_SCHEMA
        or document.get("schema_version") != 1
    ):
        raise FullstackError(
            f"unsupported Zigapagos presentation contract; expected {PRESENTATION_SCHEMA}"
        )
    generator = require_object(
        document.get("generator"), "presentation manifest.generator"
    )
    if generator.get("tool") != "zigapagos":
        raise FullstackError("presentation manifest was not generated by zigapagos")
    text(generator.get("version"), "presentation manifest.generator.version")
    routes = require_list(document.get("routes"), "presentation manifest.routes")
    if not all(isinstance(route, dict) for route in routes):
        raise FullstackError("presentation manifest.routes[] must contain objects")
    return document, _identities(routes)


def load_handoff(path: Path) -> dict[str, Any]:
    document = require_object(read_json(path, "Zigapagos handoff"), "Zigapagos handoff")
    validate_released_contract(document, HANDOFF_SCHEMA_PATH, "Zigapagos handoff")
    if document.get("schema") != HANDOFF_SCHEMA or document.get("schema_version") != 1:
        raise FullstackError(
            f"unsupported Zigapagos handoff contract; expected {HANDOFF_SCHEMA}"
        )
    generator = require_object(document.get("generator"), "Zigapagos handoff.generator")
    if generator.get("tool") != "zigapagos":
        raise FullstackError("presentation handoff was not generated by zigapagos")
    if document.get("complete") is not True:
        raise FullstackError("Zigapagos handoff is incomplete")
    require_list(document.get("routes"), "Zigapagos handoff.routes")
    require_list(document.get("parity"), "Zigapagos handoff.parity")
    return document


def load_operations(
    path: Path,
) -> tuple[
    dict[str, dict[str, Any]],
    dict[tuple[str, str], dict[str, Any]],
    dict[str, Any],
    frozenset[str],
]:
    document = require_object(read_json(path, "ZigBase OpenAPI"), "ZigBase OpenAPI")
    openapi = text(document.get("openapi"), "ZigBase OpenAPI.openapi")
    if not openapi.startswith("3."):
        raise FullstackError("ZigBase backend contract must be OpenAPI 3.x")
    paths = require_object(document.get("paths"), "ZigBase OpenAPI.paths")
    components = require_object(
        document.get("components", {}), "ZigBase OpenAPI.components"
    )
    require_object(components.get("schemas", {}), "ZigBase OpenAPI.components.schemas")
    operations: dict[str, dict[str, Any]] = {}
    operations_by_route: dict[tuple[str, str], dict[str, Any]] = {}
    auth_collections: set[str] = set()
    for path_name, path_item in paths.items():
        if not isinstance(path_name, str) or not isinstance(path_item, dict):
            raise FullstackError("ZigBase OpenAPI paths must map strings to objects")
        for method, operation in path_item.items():
            if method.lower() not in {
                "get",
                "post",
                "put",
                "patch",
                "delete",
                "head",
                "options",
                "trace",
            }:
                continue
            if not isinstance(operation, dict) or not operation.get("operationId"):
                continue
            operation_id = text(operation["operationId"], "OpenAPI operationId")
            if operation_id in operations:
                raise FullstackError(f"duplicate OpenAPI operationId {operation_id!r}")
            collection = operation.get("x-zigbase-collection")
            collection_type = operation.get("x-zigbase-collection-type")
            if path_name.startswith("/api/collections/") and (
                not isinstance(collection, str)
                or not collection
                or collection_type not in {"auth", "base", "view"}
            ):
                raise FullstackError(
                    f"OpenAPI collection operation {operation_id!r} lacks current "
                    "x-zigbase-collection metadata; export it with the matching ZigBase release"
                )
            operation_record = {
                "operation_id": operation_id,
                "verb": method.upper(),
                "path": path_name,
                "collection": collection,
                "access": operation.get(
                    "x-zigbase-access", operation.get("x-zigbase-auth", "unknown")
                ),
            }
            if operation_id in BUILTIN_ENDPOINTS:
                builtin_access, builtin_suffix = BUILTIN_ENDPOINTS[operation_id]
                expected_path = (
                    f"/api/collections/{collection}/{builtin_suffix}"
                    if isinstance(collection, str)
                    else None
                )
                if (
                    method.upper() != "POST"
                    or collection_type != "auth"
                    or path_name != expected_path
                    or operation_record["access"] != builtin_access
                ):
                    raise FullstackError(
                        f"OpenAPI operationId {operation_id!r} is reserved for the "
                        f"POST auth-collection builtin {builtin_suffix!r}"
                    )
            operations[operation_id] = operation_record
            operations_by_route[(method.upper(), path_name)] = operation_record
            if collection_type is not None and collection_type not in {
                "auth",
                "base",
                "view",
            }:
                raise FullstackError(
                    f"OpenAPI operation {operation_id!r} has unsupported "
                    f"x-zigbase-collection-type {collection_type!r}"
                )
            if collection_type == "auth" and collection is not None:
                auth_collections.add(collection)
    info = require_object(document.get("info"), "ZigBase OpenAPI.info")
    contract = document.get("x-zigbase-contract-version", info.get("version"))
    text(contract, "ZigBase OpenAPI contract version")
    return (
        operations,
        operations_by_route,
        {"openapi": openapi, "contract_version": contract},
        frozenset(auth_collections),
    )


def _read_ndjson(path: Path, label: str) -> list[tuple[int, dict[str, Any]]]:
    try:
        lines = read_bytes(path, limit=MAX_INPUT_BYTES, label=label).splitlines()
    except RailsError as exc:
        raise FullstackError(f"cannot read {label}: {exc}") from exc
    rows = []
    for line_number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            row = parse_json(line, path=path, label=f"{label} line {line_number}")
        except RailsError as exc:
            raise FullstackError(f"{label} line {line_number} is invalid JSON") from exc
        rows.append((line_number, require_object(row, f"{label} line {line_number}")))
    return rows


def _backend_control(case: dict[str, Any], label: str) -> str | None:
    expect = require_object(case.get("expect"), f"{label}.expect")
    status = expect.get("status")
    if not isinstance(status, int) or isinstance(status, bool):
        raise FullstackError(f"{label}.expect.status must be an integer")
    if "control" not in expect:
        return None
    raw_control = expect["control"]
    control = text(raw_control, f"{label}.expect.control")
    allowed_controls = allowed_controls_for_status(status)
    if control not in allowed_controls:
        raise FullstackError(
            f"{label}.expect control {control!r} is incompatible with status {status}"
        )
    return control


def load_backend_evidence(
    summary_path: Path, findings_path: Path, capture_path: Path
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    summary = require_object(
        read_json(summary_path, "backend replay summary"), "backend replay summary"
    )
    if (
        summary.get("zigbaseReplay") != REPLAY_VERSION
        or summary.get("mode") != "replay"
    ):
        raise FullstackError("backend replay summary uses an unsupported contract")
    for field in ("total", "passed", "failed", "errors"):
        if (
            not isinstance(summary.get(field), int)
            or isinstance(summary[field], bool)
            or summary[field] < 0
        ):
            raise FullstackError(
                f"backend replay summary.{field} must be a non-negative integer"
            )
    if summary["total"] < 1 or summary["passed"] != summary["total"]:
        raise FullstackError("backend replay did not pass every case")
    if summary["failed"] or summary["errors"]:
        raise FullstackError("backend replay contains failures or transport errors")

    passed: set[str] = set()
    for line_number, finding in _read_ndjson(findings_path, "backend replay findings"):
        if finding.get("result") != "pass":
            raise FullstackError(
                f"backend replay findings line {line_number} is not a passing case"
            )
        case_id = text(
            finding.get("id"), f"backend replay findings line {line_number}.id"
        )
        if case_id in passed:
            raise FullstackError(f"duplicate backend replay case id {case_id!r}")
        passed.add(case_id)
    if len(passed) != summary["passed"]:
        raise FullstackError(
            "backend replay summary and findings disagree on passed case count"
        )
    cases: dict[str, dict[str, Any]] = {}
    for line_number, case in _read_ndjson(capture_path, "backend replay capture"):
        case_id = text(case.get("id"), f"backend replay capture line {line_number}.id")
        method = text(
            case.get("method"), f"backend replay capture case {case_id}.method"
        )
        case_path = text(
            case.get("path"), f"backend replay capture case {case_id}.path"
        )
        if case_id in cases:
            raise FullstackError(f"duplicate backend replay capture id {case_id!r}")
        cases[case_id] = {
            "id": case_id,
            "method": method.upper(),
            "path": case_path,
            "status": require_object(
                case.get("expect"), f"backend replay capture case {case_id}.expect"
            ).get("status"),
            "control": _backend_control(case, f"backend replay capture case {case_id}"),
        }
    if set(cases) != passed:
        raise FullstackError(
            "backend replay capture and passing findings name different cases"
        )
    return summary, cases


def _handoff_routes(document: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for index, raw in enumerate(document["routes"]):
        route = require_object(raw, f"Zigapagos handoff.routes[{index}]")
        route_id = text(
            route.get("route_id"), f"Zigapagos handoff.routes[{index}].route_id"
        )
        status = text(route.get("status"), f"Zigapagos handoff.routes[{index}].status")
        if status == "open":
            raise FullstackError(f"Zigapagos handoff route {route_id!r} is open")
        grouped[route_id].append(route)
    return grouped


def _pair_handoff_routes(
    presentation_routes: list[tuple[RouteIdentity, dict[str, Any]]],
    grouped: dict[str, list[dict[str, Any]]],
) -> dict[RouteIdentity, list[dict[str, Any]]]:
    """Preserve every handoff row, pairing only when v1 makes attribution provable."""
    identities_by_route_id: dict[str, list[RouteIdentity]] = defaultdict(list)
    for identity, route in presentation_routes:
        route_id = text(route.get("id"), "presentation route.id")
        identities_by_route_id[route_id].append(identity)

    paired: dict[RouteIdentity, list[dict[str, Any]]] = {}
    for route_id, identities in identities_by_route_id.items():
        candidates = grouped.get(route_id, [])
        if not candidates and any(
            route_methods(identity.verb).intersection({"GET", "HEAD"})
            for identity in identities
        ):
            raise FullstackError(
                f"handoff has no conversion row for presentation route {route_id!r}"
            )
        if not candidates:
            for identity in identities:
                paired[identity] = []
            continue
        if len(identities) == 1:
            paired[identities[0]] = candidates
        else:
            # rails-handoff/1 permits several outcomes for one source route but does
            # not serialize the producer's route_index. If route_id is duplicated,
            # retain and validate the complete ordered group on every occurrence
            # instead of guessing a boundary or dropping rows.
            for identity in identities:
                paired[identity] = candidates

    unknown = set(grouped) - set(identities_by_route_id)
    if unknown:
        raise FullstackError(
            f"handoff names routes absent from the presentation manifest: {sorted(unknown)}"
        )
    return paired


def _browser_evidence(document: dict[str, Any]) -> dict[str, dict[str, Any]]:
    evidence = {}
    for index, raw in enumerate(document["parity"]):
        item = require_object(raw, f"Zigapagos handoff.parity[{index}]")
        item_id = text(item.get("id"), f"Zigapagos handoff.parity[{index}].id")
        if item_id in evidence:
            raise FullstackError(f"duplicate browser parity id {item_id!r}")
        kind = text(item.get("kind"), f"Zigapagos handoff.parity[{index}].kind")
        if kind not in BROWSER_CONTROLS:
            raise FullstackError(
                f"Zigapagos handoff parity kind {kind!r} is unsupported"
            )
        evidence[item_id] = item
    return evidence


def _presentation_blockers(
    document: dict[str, Any],
) -> tuple[dict[str, dict[str, Any]], set[tuple[str, str | None]]]:
    findings = {}
    for item in document["findings"]:
        finding = require_object(item, "presentation finding")
        finding_id = text(finding.get("id"), "presentation finding.id")
        findings[finding_id] = finding
    blockers = set()
    for item in document["blockers"]:
        blocker = require_object(item, "presentation blocker")
        code = text(blocker.get("code"), "presentation blocker.code")
        route_id = text(
            blocker.get("route_id"), "presentation blocker.route_id", nullable=True
        )
        blockers.add((code, route_id))
    return findings, blockers


def _path_matches_template(template: str, captured: str) -> bool:
    """Match a replay path to an OpenAPI template without accepting extra segments."""
    template_segments = template.split("/")
    captured_segments = captured.split("/")
    if len(template_segments) != len(captured_segments):
        return False
    for expected, actual in zip(template_segments, captured_segments):
        if re.fullmatch(r"\{[^{}]+\}", expected):
            if re.fullmatch(r"\{\{[A-Za-z_][A-Za-z0-9_]*\}\}", actual):
                continue
            if (
                not actual
                or actual in {".", ".."}
                or any(
                    ord(character) < 0x20 or ord(character) == 0x7F
                    for character in actual
                )
                or re.fullmatch(
                    r"(?:[A-Za-z0-9._~!$&'()*+,;=:@-]|%[0-9A-Fa-f]{2})+",
                    actual,
                )
                is None
            ):
                return False
            decoded = urllib.parse.unquote_to_bytes(actual)
            if (
                decoded in {b".", b".."}
                or any(byte < 0x20 or byte == 0x7F for byte in decoded)
                or any(
                    delimiter in decoded
                    for delimiter in (b"/", b"\\", b"?", b"#", b"%")
                )
            ):
                return False
            continue
        if expected != actual:
            return False
    return True


def _validate_custom_path(path: str, label: str) -> None:
    """Require a canonical same-origin absolute path for custom endpoints."""
    if not path.startswith("/") or path.startswith("//"):
        raise FullstackError(
            f"{label} custom endpoint path must be a same-origin absolute path"
        )
    if "//" in path or any(delimiter in path for delimiter in ("\\", "?", "#")):
        raise FullstackError(f"{label} custom endpoint path is not canonical")
    if any(ord(character) < 0x20 or ord(character) == 0x7F for character in path):
        raise FullstackError(f"{label} custom endpoint path is not canonical")
    for segment in path.split("/")[1:]:
        if (
            segment in {".", ".."}
            or re.fullmatch(
                r"(?:[A-Za-z0-9._~!$&'()*+,;=:@-]|%[0-9A-Fa-f]{2})*", segment
            )
            is None
        ):
            raise FullstackError(f"{label} custom endpoint path is not canonical")
        decoded = urllib.parse.unquote_to_bytes(segment)
        if (
            decoded in {b".", b".."}
            or any(byte < 0x20 or byte == 0x7F for byte in decoded)
            or any(
                delimiter in decoded for delimiter in (b"/", b"\\", b"?", b"#", b"%")
            )
        ):
            raise FullstackError(f"{label} custom endpoint path is not canonical")
        try:
            decoded_text = decoded.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise FullstackError(
                f"{label} custom endpoint path is not canonical"
            ) from exc
        if urllib.parse.quote(decoded_text, safe="!$&'()*+,;=:@-._~") != segment:
            raise FullstackError(f"{label} custom endpoint path is not canonical")


def _parse_decisions(path: Path) -> dict[RouteIdentity, dict[str, Any]]:
    document = require_object(
        read_json(path, "full-stack decisions"), "full-stack decisions"
    )
    if document.get("zigbaseRailsFullstackDecisions") != DECISIONS_VERSION:
        raise FullstackError("unsupported full-stack decisions contract")
    decisions = {}
    for index, raw in enumerate(
        require_list(document.get("routes"), "full-stack decisions.routes")
    ):
        decision = require_object(raw, f"full-stack decisions.routes[{index}]")
        identity = _decision_identity(
            decision.get("source"), f"full-stack decisions.routes[{index}].source"
        )
        if identity in decisions:
            raise FullstackError(f"duplicate route decision for {identity.label()}")
        decisions[identity] = decision
    return decisions


def _validate_evidence(
    raw: Any,
    label: str,
    backend: dict[str, dict[str, Any]],
    browser: dict[str, dict[str, Any]],
    operation: dict[str, Any] | None,
    identity: RouteIdentity,
) -> tuple[list[dict[str, str]], set[str]]:
    result = []
    controls = set()
    seen = set()
    for index, item_raw in enumerate(require_list(raw, label)):
        item = require_object(item_raw, f"{label}[{index}]")
        kind = text(item.get("kind"), f"{label}[{index}].kind")
        evidence_id = text(item.get("id"), f"{label}[{index}].id")
        control = text(item.get("control"), f"{label}[{index}].control")
        if kind not in EVIDENCE_KINDS:
            raise FullstackError(f"{label}[{index}].kind must be backend or browser")
        if control not in EVIDENCE_CONTROLS:
            raise FullstackError(f"{label}[{index}].control is unsupported")
        if (kind, evidence_id) in seen:
            raise FullstackError(f"{label} repeats {kind} evidence {evidence_id!r}")
        seen.add((kind, evidence_id))
        if kind == "backend":
            source = backend.get(evidence_id)
            if source is None:
                raise FullstackError(
                    f"{label} names unknown passing backend case {evidence_id!r}"
                )
            expected_control = source["control"]
            if expected_control is None:
                raise FullstackError(
                    f"{label} backend case {evidence_id!r} has no producer control"
                )
            target_path = operation["path"] if operation is not None else identity.path
            method_matches = (
                source["method"] == operation["verb"]
                if operation is not None
                else route_allows_method(identity.verb, source["method"])
            )
            path_matches = (
                _path_matches_template(target_path, source["path"])
                if operation is not None
                else source["path"] == target_path
            )
            if not method_matches or not path_matches:
                target_method = (
                    operation["verb"] if operation is not None else identity.verb
                )
                raise FullstackError(
                    f"{label} backend case {evidence_id!r} does not exercise "
                    f"{target_method} {target_path}"
                )
        else:
            source = browser.get(evidence_id)
            if source is None:
                raise FullstackError(
                    f"{label} names unknown browser parity check {evidence_id!r}"
                )
            expected_control = BROWSER_CONTROLS[source["kind"]]
            expected_operation = source.get("expect", {}).get("operation_id")
            if expected_operation is not None and (
                operation is None or expected_operation != operation["operation_id"]
            ):
                raise FullstackError(
                    f"{label} browser evidence {evidence_id!r} exercises "
                    f"operation {expected_operation!r}, not the selected operation"
                )
            if (
                expected_operation is not None
                and source.get("url") != operation["path"]
            ):
                raise FullstackError(
                    f"{label} browser evidence {evidence_id!r} targets "
                    f"{source.get('url')!r}, not the selected operation path"
                )
            expected_method = source.get("expect", {}).get("method")
            if expected_method is not None and (
                operation is None or expected_method.upper() != operation["verb"]
            ):
                raise FullstackError(
                    f"{label} browser evidence {evidence_id!r} uses method "
                    f"{expected_method!r}, not the selected operation method"
                )
            if source["kind"] == "navigate" and source.get("url") != identity.path:
                raise FullstackError(
                    f"{label} navigation evidence {evidence_id!r} covers "
                    f"{source.get('url')!r}, not {identity.path!r}"
                )
            if source["kind"] == "asset":
                raise FullstackError(
                    f"{label} cannot use an asset check as route parity"
                )
            if source["kind"] in {"signup", "signin"} and (
                operation is None or source.get("url") != operation["path"]
            ):
                raise FullstackError(
                    f"{label} auth journey {evidence_id!r} does not exercise the selected endpoint"
                )
        if control != expected_control:
            raise FullstackError(
                f"{label} labels {evidence_id!r} as {control!r}; producer semantics require "
                f"{expected_control!r}"
            )
        controls.add(control)
        result.append({"kind": kind, "id": evidence_id, "control": control})
    return result, controls


def _endpoint_operation(
    endpoint: Any,
    operations: dict[str, dict[str, Any]],
    operations_by_route: dict[tuple[str, str], dict[str, Any]],
    auth_collections: frozenset[str],
    custom_access: Any,
    label: str,
) -> dict[str, Any] | None:
    if endpoint is None:
        if custom_access is not None:
            raise FullstackError(f"{label} declares backend_access without an endpoint")
        return None
    value = require_object(endpoint, label)
    operation_id = text(value.get("operation_id"), f"{label}.operation_id")
    verb = text(value.get("verb"), f"{label}.verb").upper()
    path = text(value.get("path"), f"{label}.path")
    operation = operations.get(operation_id)
    if operation is not None:
        if custom_access is not None:
            raise FullstackError(
                f"{label} cannot override an OpenAPI operation's access"
            )
        if operation["verb"] != verb or operation["path"] != path:
            raise FullstackError(
                f"{label} disagrees with OpenAPI operation {operation_id!r}: "
                f"handoff={verb} {path}, OpenAPI={operation['verb']} {operation['path']}"
            )
        return operation
    if operation_id.startswith("custom:"):
        if operation_id != f"custom:{path}":
            raise FullstackError(
                f"{label} custom operation id must be exactly 'custom:' plus its absolute path"
            )
        _validate_custom_path(path, label)
        access = text(custom_access, f"{label}.backend_access")
        if access not in CUSTOM_ENDPOINT_ACCESS:
            raise FullstackError(
                f"{label}.backend_access is unsupported for a custom endpoint"
            )
        if path.startswith("/api/collections/"):
            raise FullstackError(
                f"{label} custom endpoint uses the engine-owned /api/collections namespace"
            )
        collision = next(
            (
                candidate
                for (candidate_verb, template), candidate in operations_by_route.items()
                if candidate_verb == verb and _path_matches_template(template, path)
            ),
            None,
        )
        if collision is not None:
            raise FullstackError(
                f"{label} custom endpoint aliases OpenAPI operation "
                f"{collision['operation_id']!r}"
            )
        return {
            "operation_id": operation_id,
            "verb": verb,
            "path": path,
            "collection": None,
            "access": access,
        }
    if custom_access is not None:
        raise FullstackError(
            f"{label} declares backend_access for a non-custom endpoint"
        )
    if operation_id not in BUILTIN_ENDPOINTS:
        raise FullstackError(
            f"{label} names unknown endpoint operation {operation_id!r}"
        )
    access, suffix = BUILTIN_ENDPOINTS[operation_id]
    pattern = rf"/api/collections/([A-Za-z][A-Za-z0-9_]*)/{re.escape(suffix)}"
    match = re.fullmatch(pattern, path)
    if verb != "POST" or match is None:
        raise FullstackError(
            f"{label} builtin endpoint {operation_id!r} must be "
            f"POST /api/collections/<auth collection>/{suffix}"
        )
    if match.group(1) not in auth_collections:
        raise FullstackError(
            f"{label} builtin endpoint {operation_id!r} names non-auth collection "
            f"{match.group(1)!r}"
        )
    return {
        "operation_id": operation_id,
        "verb": verb,
        "path": path,
        "collection": None,
        "access": access,
        "builtin": True,
    }


def _validate_auth(operation: dict[str, Any] | None, auth: str, label: str) -> None:
    if operation is None:
        return
    access = operation["access"]
    if access not in KNOWN_ENDPOINT_ACCESS:
        raise FullstackError(
            f"{label} selects an operation with unsupported access {access!r}"
        )
    if access == "public" and auth != "public":
        raise FullstackError(
            f"{label} must be public because its selected operation is public"
        )
    if access in {
        "conditional",
        "authenticated",
        "superuser",
        "path-secret",
    } and auth in {
        "public",
        "not-applicable",
    }:
        raise FullstackError(
            f"{label} downgrades the selected operation's {access} access"
        )
    if access == "locked":
        raise FullstackError(
            f"{label} selects a locked operation that cannot serve migrated traffic"
        )


def reconcile(
    backend_routes_path: Path,
    presentation_path: Path,
    handoff_path: Path,
    openapi_path: Path,
    decisions_path: Path,
    replay_summary_path: Path,
    replay_findings_path: Path,
    replay_capture_path: Path,
) -> dict[str, Any]:
    backend_routes, backend_inventory_contract = load_backend_routes(
        backend_routes_path
    )
    presentation, presentation_routes = load_presentation(presentation_path)
    handoff = load_handoff(handoff_path)
    operations, operations_by_route, openapi_contract, auth_collections = (
        load_operations(openapi_path)
    )
    replay_summary, backend_evidence = load_backend_evidence(
        replay_summary_path, replay_findings_path, replay_capture_path
    )
    browser_evidence = _browser_evidence(handoff)
    presentation_findings, presentation_blockers = _presentation_blockers(presentation)
    decisions = _parse_decisions(decisions_path)

    presentation_generator = require_object(
        presentation["generator"], "presentation manifest.generator"
    )
    handoff_generator = require_object(handoff["generator"], "handoff.generator")
    if presentation_generator.get("version") != handoff_generator.get("version"):
        raise FullstackError(
            "presentation manifest and handoff generator versions disagree"
        )
    handoff_backend = require_object(
        handoff.get("backend"), "Zigapagos handoff.backend"
    )
    if handoff_backend.get("contract_version") != openapi_contract["contract_version"]:
        raise FullstackError(
            "Zigapagos handoff and ZigBase OpenAPI contract versions disagree"
        )

    backend_by_id = dict(backend_routes)
    presentation_by_id = dict(presentation_routes)
    identities = set(backend_by_id) | set(presentation_by_id)
    missing = sorted(identities - set(decisions), key=RouteIdentity.sort_key)
    extra = sorted(set(decisions) - identities, key=RouteIdentity.sort_key)
    if missing or extra:
        raise FullstackError(
            "route decision coverage mismatch: "
            f"missing={[route.label() for route in missing]} "
            f"extra={[route.label() for route in extra]}"
        )

    handoff_by_route_id = _handoff_routes(handoff)
    converted_by_identity = _pair_handoff_routes(
        presentation_routes, handoff_by_route_id
    )
    reconciled = []
    for identity in sorted(identities, key=RouteIdentity.sort_key):
        identity_label = identity.label()
        identity_methods = route_methods(identity.verb)
        backend = backend_by_id.get(identity)
        source_presentation = presentation_by_id.get(identity)
        converted = converted_by_identity.get(identity, [])

        decision = decisions[identity]
        disposition = text(
            decision.get("disposition"), f"decision for {identity_label}.disposition"
        )
        if disposition not in DISPOSITIONS:
            raise FullstackError(
                f"decision for {identity_label} has unsupported disposition"
            )
        rationale = text(
            decision.get("rationale"), f"decision for {identity_label}.rationale"
        )
        surface = text(
            decision.get("surface"), f"decision for {identity_label}.surface"
        )
        if surface not in {"browser", "api", "internal"}:
            raise FullstackError(
                f"decision for {identity_label}.surface is unsupported"
            )
        auth = text(decision.get("auth"), f"decision for {identity_label}.auth")
        if auth not in AUTH_VALUES:
            raise FullstackError(f"decision for {identity_label}.auth is unsupported")
        blockers = decision.get("blockers", [])
        if disposition != "blocked":
            if blockers != []:
                raise FullstackError(
                    f"{disposition} route {identity_label} must not name blockers"
                )
            blockers = []

        operation_id = decision.get("backend_operation_id")
        operation = None
        if operation_id is not None:
            operation_id = text(
                operation_id, f"decision for {identity_label}.backend_operation_id"
            )
            operation = operations.get(operation_id)

        converted_statuses = {row["status"] for row in converted}
        handoff_operations = []
        for index, row in enumerate(converted):
            if row.get("endpoint") is None:
                continue
            handoff_operation = _endpoint_operation(
                row["endpoint"],
                operations,
                operations_by_route,
                auth_collections,
                decision.get("backend_access"),
                f"handoff endpoint {index} for {identity_label}",
            )
            if operation_id != handoff_operation["operation_id"]:
                raise FullstackError(
                    f"decision for {identity_label} does not match the handoff endpoint "
                    f"{handoff_operation['operation_id']!r}"
                )
            handoff_operations.append(handoff_operation)
        if decision.get("backend_access") is not None and not handoff_operations:
            raise FullstackError(
                f"decision for {identity_label} declares backend_access without a custom endpoint"
            )
        if handoff_operations:
            operation_keys = {
                (item["operation_id"], item["verb"], item["path"], item["access"])
                for item in handoff_operations
            }
            if len(operation_keys) != 1:
                raise FullstackError(
                    f"handoff for {identity_label} names multiple backend endpoints; "
                    "the full-stack decision must select one unambiguous operation"
                )
            operation = handoff_operations[0]
        elif operation_id is not None and operation is None:
            raise FullstackError(
                f"decision for {identity_label} names unknown operation {operation_id!r}"
            )
        method_changes = (
            operation is not None and operation["verb"] not in identity_methods
        )
        method_transform = decision.get("method_transform")
        if method_changes:
            transform = require_object(
                method_transform,
                f"decision for {identity_label}.method_transform",
            )
            if set(transform) != {"from", "to", "rationale"}:
                raise FullstackError(
                    f"decision for {identity_label}.method_transform must contain exactly "
                    "from, to, and rationale"
                )
            source_method = (
                text(
                    transform.get("from"),
                    f"decision for {identity_label}.method_transform.from",
                )
                .strip()
                .upper()
            )
            target_method = (
                text(
                    transform.get("to"),
                    f"decision for {identity_label}.method_transform.to",
                )
                .strip()
                .upper()
            )
            transform_rationale = text(
                transform.get("rationale"),
                f"decision for {identity_label}.method_transform.rationale",
            ).strip()
            if (
                source_method not in identity_methods
                or target_method != operation["verb"]
            ):
                raise FullstackError(
                    f"decision for {identity_label}.method_transform does not declare "
                    f"a source method and selected target method {operation['verb']}"
                )
            method_transform = {
                "from": source_method,
                "to": target_method,
                "rationale": transform_rationale,
            }
        elif method_transform is not None:
            raise FullstackError(
                f"decision for {identity_label} declares an unnecessary method_transform"
            )
        _validate_auth(operation, auth, f"decision for {identity_label}.auth")

        evidence, controls = _validate_evidence(
            decision.get("parity"),
            f"decision for {identity_label}.parity",
            backend_evidence,
            browser_evidence,
            operation,
            identity,
        )
        if disposition == "migrated":
            if operation is None and not converted_statuses.intersection(
                {"migrated", "backend", "redirect"}
            ):
                raise FullstackError(
                    f"migrated route {identity_label} has no replacement artifact"
                )
            if not evidence:
                raise FullstackError(
                    f"migrated route {identity_label} has no parity evidence"
                )
            evidence_kinds = {item["kind"] for item in evidence}
            if surface == "browser" and "browser" not in evidence_kinds:
                raise FullstackError(
                    f"browser route {identity_label} has no browser parity evidence"
                )
            if surface == "api" and "backend" not in evidence_kinds:
                raise FullstackError(
                    f"API route {identity_label} has no backend parity evidence"
                )
            if route_is_mutating(identity.verb) and auth not in {
                "public",
                "not-applicable",
            }:
                if not {"allowed", "denied"}.issubset(controls):
                    raise FullstackError(
                        f"protected mutation {identity_label} needs allowed and denied parity controls"
                    )
        elif disposition == "blocked":
            if operation_id is not None:
                raise FullstackError(
                    f"blocked route {identity_label} cannot name a backend operation"
                )
            if (
                not isinstance(blockers, list)
                or not blockers
                or not all(isinstance(item, str) and item.strip() for item in blockers)
            ):
                raise FullstackError(
                    f"blocked route {identity_label} must name blocker ids"
                )
            if source_presentation is None:
                raise FullstackError(
                    f"blocked route {identity_label} has no authoritative presentation blocker"
                )
            route_id = text(
                source_presentation.get("id"),
                f"presentation route for {identity_label}.id",
            )
            direct_blocker_codes = {
                code
                for code, blocker_route_id in presentation_blockers
                if blocker_route_id is None or blocker_route_id == route_id
            }
            unknown_blockers = (
                set(blockers) - set(presentation_findings) - direct_blocker_codes
            )
            if unknown_blockers:
                raise FullstackError(
                    f"blocked route {identity_label} names unknown blocker ids "
                    f"{sorted(unknown_blockers)}"
                )
            route_finding_ids = set()
            converted_decision_ids = set()
            for index, row in enumerate(converted):
                route_finding_ids.update(
                    text(
                        item,
                        f"blocked handoff route {identity_label}[{index}].findings",
                    )
                    for item in require_list(
                        row.get("findings"),
                        f"blocked handoff route {identity_label}[{index}].findings",
                    )
                )
                converted_decision_raw = row.get("decision")
                if converted_decision_raw is not None:
                    converted_decision = require_object(
                        converted_decision_raw,
                        f"blocked handoff route {identity_label}[{index}].decision",
                    )
                    converted_decision_ids.add(
                        text(
                            converted_decision.get("id"),
                            f"blocked handoff route {identity_label}[{index}].decision.id",
                        )
                    )
            missing_decisions = converted_decision_ids - set(blockers)
            if missing_decisions:
                raise FullstackError(
                    f"blocked route {identity_label} omits handoff decisions "
                    f"{sorted(missing_decisions)}"
                )
            absent_decisions = converted_decision_ids - route_finding_ids
            if absent_decisions:
                raise FullstackError(
                    f"blocked handoff route {identity_label} decisions are absent from "
                    f"that route's findings: {sorted(absent_decisions)}"
                )
            unrelated_blockers = (
                set(blockers) - route_finding_ids - direct_blocker_codes
            )
            if unrelated_blockers:
                raise FullstackError(
                    f"blocked route {identity_label} names findings not attached to its "
                    f"handoff route: {sorted(unrelated_blockers)}"
                )
            for blocker in blockers:
                if blocker in direct_blocker_codes:
                    continue
                finding_route_id = presentation_findings[blocker].get("route_id")
                if finding_route_id is not None and finding_route_id != route_id:
                    raise FullstackError(
                        f"blocked route {identity_label} uses finding {blocker!r} "
                        f"attached to route {finding_route_id!r}"
                    )
        else:
            if operation_id is not None:
                raise FullstackError(
                    f"{disposition} route {identity_label} cannot name a backend operation"
                )

        for converted_status in converted_statuses:
            if (
                converted_status in EXPECTED_DISPOSITIONS
                and disposition not in EXPECTED_DISPOSITIONS[converted_status]
            ):
                raise FullstackError(
                    f"decision for {identity_label} contradicts handoff status "
                    f"{converted_status!r}"
                )

        if surface == "browser" and source_presentation is None:
            raise FullstackError(
                f"browser route {identity_label} is absent from presentation inventory"
            )
        if (
            surface == "internal"
            and backend is not None
            and backend.get("internal") is not True
        ):
            raise FullstackError(
                f"route {identity_label} is declared internal but Rails did not mark it internal"
            )

        reconciled.append(
            {
                "source": identity.wire(),
                "surface": surface,
                "disposition": disposition,
                "rationale": rationale,
                "backend_source": backend,
                "presentation_source": source_presentation,
                "backend": operation,
                "method_transform": method_transform,
                "presentation": converted,
                "auth": auth,
                "parity": evidence,
                "blockers": blockers,
            }
        )

    covered_presentation_blockers = {
        (code, route_id)
        for code, route_id in presentation_blockers
        if any(
            route["disposition"] == "blocked"
            and (
                route_id is None
                or (
                    route["presentation_source"] is not None
                    and route["presentation_source"].get("id") == route_id
                )
            )
            and any(
                blocker == code or blocker.startswith(code + ".")
                for blocker in route["blockers"]
            )
            for route in reconciled
        )
    }
    uncovered_presentation_blockers = (
        presentation_blockers - covered_presentation_blockers
    )
    if uncovered_presentation_blockers:
        raise FullstackError(
            "presentation blockers are not represented by blocked route decisions: "
            f"{sorted(uncovered_presentation_blockers, key=lambda item: (item[0], item[1] or ''))}"
        )

    return {
        "schema": "zigbase.rails-fullstack/1",
        "schema_version": FULLSTACK_VERSION,
        "contracts": {
            "zigbase_rails_inventory": backend_inventory_contract,
            "zigbase_openapi": openapi_contract,
            "zigapagos_presentation": {
                "schema": PRESENTATION_SCHEMA,
                "generator_version": presentation_generator["version"],
            },
            "zigapagos_handoff": {
                "schema": HANDOFF_SCHEMA,
                "generator_version": handoff_generator["version"],
            },
            "decisions": DECISIONS_VERSION,
            "backend_replay": REPLAY_VERSION,
        },
        "complete": True,
        "routes": reconciled,
        "parity": {
            "backend": replay_summary,
            "browser": list(browser_evidence.values()),
        },
    }


def canonical_json(document: dict[str, Any]) -> str:
    try:
        return canonical_text(document)
    except RailsError as exc:
        raise FullstackError(f"manifest contains a non-JSON value: {exc}") from exc


def write_canonical(path: Path, document: dict[str, Any]) -> None:
    try:
        write_canonical_json(path, document)
    except RailsError as exc:
        raise FullstackError(f"cannot write manifest at {path}: {exc}") from exc


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--backend-routes", required=True, type=Path)
    parser.add_argument("--presentation-manifest", required=True, type=Path)
    parser.add_argument("--presentation-handoff", required=True, type=Path)
    parser.add_argument("--backend-openapi", required=True, type=Path)
    parser.add_argument("--decisions", required=True, type=Path)
    parser.add_argument("--backend-replay", required=True, type=Path)
    parser.add_argument("--backend-findings", required=True, type=Path)
    parser.add_argument("--backend-capture", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        document = reconcile(
            args.backend_routes,
            args.presentation_manifest,
            args.presentation_handoff,
            args.backend_openapi,
            args.decisions,
            args.backend_replay,
            args.backend_findings,
            args.backend_capture,
        )
        write_canonical(args.out, document)
    except FullstackError as exc:
        print(f"rails-fullstack: {exc}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "zigbase_rails_fullstack": FULLSTACK_VERSION,
                "routes": len(document["routes"]),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
