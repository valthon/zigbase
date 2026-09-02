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
from tools.replay._contract import EVIDENCE_CONTROLS
from tools.replay.zb_replay import ReplayError, load_capture


FULLSTACK_VERSION = 1
OPENAPI_CONTRACT_VERSION = "1"
RAILS_INVENTORY_VERSION = 1
PRESENTATION_SCHEMA = "zigapagos.rails-presentation/1"
HANDOFF_SCHEMA = "zigapagos.rails-handoff/1"
DECISIONS_VERSION = 1
REPLAY_VERSION = 1
MAX_INPUT_BYTES = JSON_LIMIT
MUTATING_VERBS = frozenset({"POST", "PUT", "PATCH", "DELETE"})
HTTP_VERBS = frozenset({"GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"})
OPENAPI_METHODS = frozenset(method.lower() for method in HTTP_VERBS)
OPENAPI_OPERATION_KEYS = OPENAPI_METHODS | {"trace"}
OPENAPI_PATH_ITEM_METADATA = frozenset(
    {"$ref", "summary", "description", "servers", "parameters"}
)
COLLECTION_TYPES = frozenset({"auth", "base", "view"})
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
KNOWN_ENDPOINT_ACCESS = frozenset(
    {"public", "conditional", "authenticated", "superuser", "path-secret", "locked"}
)
CUSTOM_ENDPOINT_ACCESS = KNOWN_ENDPOINT_ACCESS - {"locked"}
SUPPORTED_BUILTIN_OPERATIONS = {
    "authWithPassword": (
        "POST",
        "/api/collections/{collection}/auth-with-password",
        "public",
        "auth",
    ),
    "authRefresh": (
        "POST",
        "/api/collections/{collection}/auth-refresh",
        "authenticated",
        "auth",
    ),
    "logout": (
        "POST",
        "/api/collections/{collection}/auth-logout",
        "public",
        "auth",
    ),
    "requestVerification": (
        "POST",
        "/api/collections/{collection}/request-verification",
        "public",
        "auth",
    ),
    "confirmVerification": (
        "POST",
        "/api/collections/{collection}/confirm-verification",
        "public",
        "auth",
    ),
    "requestPasswordReset": (
        "POST",
        "/api/collections/{collection}/request-password-reset",
        "public",
        "auth",
    ),
    "confirmPasswordReset": (
        "POST",
        "/api/collections/{collection}/confirm-password-reset",
        "public",
        "auth",
    ),
}
REQUIRED_OPENAPI_COVERAGE_KEYS = frozenset(
    {
        "collections",
        "consumerRoutes",
        "admin",
        "realtime",
        "fileBytes",
        "allAuthMethods",
    }
)
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
SUPPORTED_SCHEMA_TYPES = frozenset(
    {"null", "object", "array", "string", "integer", "boolean"}
)


class FullstackError(RuntimeError):
    """A tool, input, or contract error prevents reconciliation."""


class IncompleteMigrationError(FullstackError):
    """Valid artifacts require migration judgment or more proof."""


class CoordinatorArgumentParser(argparse.ArgumentParser):
    def error(self, message: str) -> None:
        raise FullstackError(f"invalid command line: {message}")


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


def _json_value_equal(left: Any, right: Any) -> bool:
    """Compare JSON values without Python's bool/int equivalence."""
    if isinstance(left, bool) or isinstance(right, bool):
        return isinstance(left, bool) and isinstance(right, bool) and left == right
    if left is None or right is None:
        return left is None and right is None
    if isinstance(left, (int, float)) and isinstance(right, (int, float)):
        return left == right
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return set(left) == set(right) and all(
            _json_value_equal(value, right[key]) for key, value in left.items()
        )
    if isinstance(left, list):
        return len(left) == len(right) and all(
            _json_value_equal(a, b) for a, b in zip(left, right, strict=True)
        )
    return left == right


def _validate_schema_definition(schema: Any, label: str) -> dict[str, Any]:
    if not isinstance(schema, dict):
        raise FullstackError(f"{label} must be a JSON Schema object")
    unsupported = set(schema) - SUPPORTED_SCHEMA_KEYWORDS
    if unsupported:
        raise FullstackError(
            f"{label} schema uses unsupported keywords {sorted(unsupported)}"
        )
    for keyword in ("$schema", "$id", "title", "description"):
        if keyword in schema and not isinstance(schema[keyword], str):
            raise FullstackError(f"{label}.{keyword} must be a string")
    raw_type = schema.get("type")
    types: list[str] = []
    if raw_type is not None:
        types = raw_type if isinstance(raw_type, list) else [raw_type]
        if (
            not types
            or not all(isinstance(item, str) for item in types)
            or len(types) != len(set(types))
            or not set(types) <= SUPPORTED_SCHEMA_TYPES
        ):
            raise FullstackError(f"{label}.type uses an unsupported schema type")
    properties = schema.get("properties", {})
    if not isinstance(properties, dict):
        raise FullstackError(f"{label}.properties must be an object")
    if "properties" in schema and "object" not in types:
        raise FullstackError(f"{label}.properties requires object type")
    for name, child in properties.items():
        if not isinstance(name, str):
            raise FullstackError(f"{label}.properties keys must be strings")
        _validate_schema_definition(child, f"{label}.properties.{name}")
    if "required" in schema:
        required = schema["required"]
        if (
            "object" not in types
            or not isinstance(required, list)
            or not all(isinstance(item, str) and item for item in required)
            or len(required) != len(set(required))
            or not set(required) <= set(properties)
        ):
            raise FullstackError(
                f"{label}.required must be unique property names for an object schema"
            )
    if "additionalProperties" in schema and (
        "object" not in types or not isinstance(schema["additionalProperties"], bool)
    ):
        raise FullstackError(
            f"{label}.additionalProperties must be a boolean for an object schema"
        )
    if "items" in schema:
        if "array" not in types:
            raise FullstackError(f"{label}.items requires array type")
        _validate_schema_definition(schema["items"], f"{label}.items")
    if "enum" in schema:
        enum = schema["enum"]
        if (
            not isinstance(enum, list)
            or not enum
            or any(
                _json_value_equal(value, prior)
                for index, value in enumerate(enum)
                for prior in enum[:index]
            )
        ):
            raise FullstackError(
                f"{label}.enum must be a non-empty array of unique values"
            )
    if "minimum" in schema and (
        "integer" not in types
        or not isinstance(schema["minimum"], int)
        or isinstance(schema["minimum"], bool)
    ):
        raise FullstackError(f"{label}.minimum must be an integer for integer type")
    if "oneOf" in schema:
        options = schema["oneOf"]
        if not isinstance(options, list) or not options:
            raise FullstackError(f"{label}.oneOf must be a non-empty array")
        for index, option in enumerate(options):
            _validate_schema_definition(option, f"{label}.oneOf[{index}]")
    return schema


def _validate_schema_value(value: Any, schema: dict[str, Any], label: str) -> None:
    if "oneOf" in schema:
        matches = 0
        for option in schema["oneOf"]:
            try:
                _validate_schema_value(value, option, label)
                matches += 1
            except FullstackError:
                pass
        if matches != 1:
            raise FullstackError(
                f"{label} must match exactly one released schema variant; matched {matches}"
            )
    expected = schema.get("type")
    if expected is not None:
        choices = expected if isinstance(expected, list) else [expected]
        if not all(isinstance(choice, str) for choice in choices) or not any(
            _schema_type_matches(value, choice) for choice in choices
        ):
            raise FullstackError(f"{label} does not match schema type {expected!r}")
    if "const" in schema and not _json_value_equal(value, schema["const"]):
        raise FullstackError(f"{label} must equal {schema['const']!r}")
    if "enum" in schema and not any(
        _json_value_equal(value, candidate) for candidate in schema["enum"]
    ):
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
                _validate_schema_value(child, properties[key], f"{label}.{key}")
    if isinstance(value, list) and "items" in schema:
        for index, child in enumerate(value):
            _validate_schema_value(child, schema["items"], f"{label}[{index}]")


def validate_schema(value: Any, schema: dict[str, Any], label: str = "$") -> None:
    """Validate a value against the supported released-schema subset."""
    _validate_schema_definition(schema, label)
    _validate_schema_value(value, schema, label)


@lru_cache(maxsize=None)
def _released_schema(schema_path: Path) -> dict[str, Any]:
    label = f"released schema {schema_path.name}"
    return _validate_schema_definition(read_json(schema_path, label), label)


def validate_released_contract(value: Any, schema_path: Path, label: str) -> None:
    schema = _released_schema(schema_path)
    _validate_schema_value(value, schema, label)


def text(value: Any, label: str, *, nullable: bool = False) -> str | None:
    if nullable and value is None:
        return None
    if not isinstance(value, str) or not value.strip():
        raise FullstackError(f"{label} must be a non-empty string")
    return value


def replay_case_identity(
    value: Any, label: str
) -> tuple[str, str | int | float | bool]:
    """Return the v1 replay identity without collapsing JSON scalar types."""
    if (
        not isinstance(value, (str, int, float, bool))
        or not value
        or isinstance(value, str)
        and (not value.strip() or value != value.strip())
    ):
        raise FullstackError(f"{label} must be a non-empty JSON scalar")
    return type(value).__name__, value


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
        validated = _route_identity(route, 1)
        base = (
            validated.verb,
            validated.path,
            validated.controller,
            validated.action,
        )
        seen[base] += 1
        result.append(
            (
                RouteIdentity(
                    validated.verb,
                    validated.path,
                    validated.controller,
                    validated.action,
                    seen[base],
                ),
                route,
            )
        )
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


def _load_zigapagos(
    path: Path, schema_path: Path, schema_id: str, label: str
) -> dict[str, Any]:
    document = require_object(read_json(path, label), label)
    validate_released_contract(document, schema_path, label)
    if document["schema"] != schema_id or document["schema_version"] != 1:
        raise FullstackError(
            f"unsupported {label} contract; expected {schema_id} version 1"
        )
    generator = document["generator"]
    if generator["tool"] != "zigapagos":
        raise FullstackError(f"{label} was not generated by zigapagos")
    if not generator["version"].strip():
        raise FullstackError(f"{label}.generator.version must be a non-empty string")
    return document


def load_presentation(
    path: Path,
) -> tuple[dict[str, Any], list[tuple[RouteIdentity, dict[str, Any]]]]:
    document = _load_zigapagos(
        path,
        PRESENTATION_SCHEMA_PATH,
        PRESENTATION_SCHEMA,
        "Zigapagos presentation manifest",
    )
    return document, _identities(document["routes"])


def load_handoff(path: Path) -> dict[str, Any]:
    document = _load_zigapagos(
        path, HANDOFF_SCHEMA_PATH, HANDOFF_SCHEMA, "Zigapagos handoff"
    )
    if document.get("complete") is not True:
        raise IncompleteMigrationError("Zigapagos handoff is incomplete")
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
    gates = require_object(
        document.get("x-zigbase-gates"), "ZigBase OpenAPI.x-zigbase-gates"
    )
    if not all(isinstance(enabled, bool) for enabled in gates.values()):
        raise FullstackError("ZigBase OpenAPI.x-zigbase-gates values must be boolean")
    feature_marker = "x-zigbase-feature-public-route"
    if feature_marker not in document:
        raise FullstackError(f"ZigBase OpenAPI.{feature_marker} is required")
    feature_public_route = document[feature_marker]
    if feature_public_route is not None:
        feature_public_route = text(
            feature_public_route, f"ZigBase OpenAPI.{feature_marker}"
        )
        _validate_custom_path(feature_public_route, f"ZigBase OpenAPI.{feature_marker}")
        if any(
            segment.startswith(":") for segment in feature_public_route.split("/")[1:]
        ):
            raise FullstackError(
                f"ZigBase OpenAPI.{feature_marker} is not a canonical fixed route"
            )
    coverage = require_object(
        document.get("x-zigbase-coverage"), "ZigBase OpenAPI.x-zigbase-coverage"
    )
    if not REQUIRED_OPENAPI_COVERAGE_KEYS <= set(coverage) or not all(
        isinstance(value, bool) for value in coverage.values()
    ):
        raise FullstackError(
            "ZigBase OpenAPI.x-zigbase-coverage must contain the required boolean fields"
        )
    if coverage["collections"] is not True or any(
        coverage[field]
        for field in ("admin", "realtime", "fileBytes", "allAuthMethods")
    ):
        raise FullstackError(
            "ZigBase OpenAPI.x-zigbase-coverage disagrees with the supported exporter coverage"
        )
    reserved_routes: list[tuple[str, str]] = []
    reserved_route_keys: set[tuple[str, str]] = set()
    for index, raw in enumerate(
        require_list(
            document.get("x-zigbase-reserved-routes"),
            "ZigBase OpenAPI.x-zigbase-reserved-routes",
        )
    ):
        item = require_object(raw, f"reserved route metadata[{index}]")
        if set(item) != {"method", "path"}:
            raise FullstackError(
                f"reserved route metadata[{index}] must contain exactly method and path"
            )
        method = text(
            item.get("method"), f"reserved route metadata[{index}].method"
        ).upper()
        path_template = text(item.get("path"), f"reserved route metadata[{index}].path")
        if method not in HTTP_VERBS or not _openapi_path_is_canonical(path_template):
            raise FullstackError(f"reserved route metadata[{index}] is invalid")
        key = (method, re.sub(r"\{[^{}]+\}", "{}", path_template))
        if key in reserved_route_keys:
            raise FullstackError(
                f"duplicate reserved route metadata {method} {path_template}"
            )
        reserved_route_keys.add(key)
        reserved_routes.append((method, path_template))
    reserved_prefixes: list[tuple[str, str]] = []
    seen_reserved_prefixes: set[str] = set()
    for index, raw in enumerate(
        require_list(
            document.get("x-zigbase-reserved-prefixes"),
            "ZigBase OpenAPI.x-zigbase-reserved-prefixes",
        )
    ):
        item = require_object(raw, f"reserved prefix metadata[{index}]")
        if set(item) != {"path", "source"}:
            raise FullstackError(
                f"reserved prefix metadata[{index}] must contain exactly path and source"
            )
        prefix = text(item.get("path"), f"reserved prefix metadata[{index}].path")
        source = text(item.get("source"), f"reserved prefix metadata[{index}].source")
        if (
            not prefix.startswith("/")
            or prefix.startswith("//")
            or prefix.endswith("/")
            or "//" in prefix
            or any(delimiter in prefix for delimiter in ("\\", "?", "#", "{", "}"))
            or any(
                ord(character) < 0x20 or ord(character) == 0x7F for character in prefix
            )
        ):
            raise FullstackError(f"reserved prefix metadata[{index}] is invalid")
        if prefix in seen_reserved_prefixes:
            raise FullstackError(f"duplicate reserved prefix metadata {prefix}")
        seen_reserved_prefixes.add(prefix)
        reserved_prefixes.append((prefix, source))
    if not isinstance(gates.get("admin"), bool):
        raise FullstackError("ZigBase OpenAPI.x-zigbase-gates.admin must be boolean")
    expected_reserved_prefixes = {("/_", "admin")} if gates["admin"] else set()
    if set(reserved_prefixes) != expected_reserved_prefixes:
        raise FullstackError(
            "ZigBase OpenAPI.x-zigbase-reserved-prefixes disagrees with "
            "x-zigbase-gates.admin"
        )
    if feature_public_route is not None:
        required_feature_routes = {
            ("GET", feature_public_route),
            ("HEAD", feature_public_route),
        }
        if not required_feature_routes <= reserved_route_keys:
            raise FullstackError(
                "ZigBase OpenAPI.x-zigbase-reserved-routes must reserve GET and HEAD "
                "for x-zigbase-feature-public-route"
            )
    builtin_endpoints: dict[str, dict[str, str]] = {}
    for index, raw in enumerate(
        require_list(
            document.get("x-zigbase-builtin-operations"),
            "ZigBase OpenAPI.x-zigbase-builtin-operations",
        )
    ):
        item = require_object(raw, f"builtin operation metadata[{index}]")
        if set(item) != {
            "operationId",
            "method",
            "path",
            "access",
            "collectionType",
        }:
            raise FullstackError(
                f"builtin operation metadata[{index}] has an unsupported shape"
            )
        operation_id = text(
            item.get("operationId"), f"builtin operation metadata[{index}].operationId"
        )
        if operation_id in builtin_endpoints:
            raise FullstackError(f"duplicate builtin operationId {operation_id!r}")
        builtin = {
            "method": text(
                item.get("method"), f"builtin operation metadata[{index}].method"
            ).upper(),
            "path": text(item.get("path"), f"builtin operation metadata[{index}].path"),
            "access": text(
                item.get("access"), f"builtin operation metadata[{index}].access"
            ),
            "collection_type": text(
                item.get("collectionType"),
                f"builtin operation metadata[{index}].collectionType",
            ),
        }
        placeholders = re.findall(r"\{[A-Za-z_][A-Za-z0-9_]*\}", builtin["path"])
        if (
            builtin["method"] not in HTTP_VERBS
            or builtin["access"] not in KNOWN_ENDPOINT_ACCESS
            or builtin["collection_type"] not in COLLECTION_TYPES
            or not _openapi_path_is_canonical(builtin["path"])
            or len(placeholders) != 1
            or "{" in builtin["path"].replace(placeholders[0], "")
            or "}" in builtin["path"].replace(placeholders[0], "")
        ):
            raise FullstackError(f"builtin operation metadata[{index}] is invalid")
        builtin["path"] = builtin["path"].replace(placeholders[0], "{collection}", 1)
        builtin_key = (
            builtin["method"],
            re.sub(r"\{[^{}]+\}", "{}", builtin["path"]),
        )
        if builtin_key not in reserved_route_keys:
            raise FullstackError(
                f"builtin operation metadata[{index}] is not an exported reserved route"
            )
        builtin_endpoints[operation_id] = builtin
    exported_builtins = {
        operation_id: (
            builtin["method"],
            builtin["path"],
            builtin["access"],
            builtin["collection_type"],
        )
        for operation_id, builtin in builtin_endpoints.items()
    }
    if any(
        exported_builtins.get(operation_id) != expected
        for operation_id, expected in SUPPORTED_BUILTIN_OPERATIONS.items()
    ):
        raise FullstackError(
            "exported builtin operation metadata lacks a supported "
            "Rails full-stack migration contract"
        )
    operations: dict[str, dict[str, Any]] = {}
    operations_by_route: dict[tuple[str, str], dict[str, Any]] = {}
    auth_collections: set[str] = set()
    collection_types: dict[str, str] = {}
    consumer_routes_present = False
    for path_name, path_item in paths.items():
        if not isinstance(path_name, str) or not isinstance(path_item, dict):
            raise FullstackError("ZigBase OpenAPI paths must map strings to objects")
        if not _openapi_path_is_canonical(path_name):
            raise FullstackError(f"ZigBase OpenAPI path {path_name!r} is not canonical")
        for method, operation in path_item.items():
            normalized_method = method.lower()
            if normalized_method in OPENAPI_OPERATION_KEYS - OPENAPI_METHODS:
                raise FullstackError(
                    f"OpenAPI operation {method.upper()} {path_name} uses an unsupported HTTP method"
                )
            if normalized_method not in OPENAPI_METHODS:
                if method in OPENAPI_PATH_ITEM_METADATA or method.startswith("x-"):
                    continue
                raise FullstackError(
                    f"OpenAPI path item {path_name} has unsupported field {method!r}"
                )
            if not isinstance(operation, dict):
                raise FullstackError(
                    f"OpenAPI operation {method.upper()} {path_name} must be an object"
                )
            operation_id = text(
                operation.get("operationId"),
                f"OpenAPI operation {method.upper()} {path_name}.operationId",
            )
            if operation_id in operations:
                raise FullstackError(f"duplicate OpenAPI operationId {operation_id!r}")
            collection = operation.get("x-zigbase-collection")
            collection_type = operation.get("x-zigbase-collection-type")
            if (collection is None) != (collection_type is None):
                raise FullstackError(
                    f"OpenAPI operation {operation_id!r} must declare both collection markers"
                )
            if collection_type is not None and (
                not isinstance(collection_type, str)
                or collection_type not in COLLECTION_TYPES
            ):
                raise FullstackError(
                    f"OpenAPI operation {operation_id!r} has unsupported "
                    f"x-zigbase-collection-type {collection_type!r}"
                )
            if collection is not None:
                collection = text(
                    collection,
                    f"OpenAPI operation {operation_id!r}.x-zigbase-collection",
                )
                if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", collection) is None:
                    raise FullstackError(
                        f"OpenAPI operation {operation_id!r} has an invalid collection marker"
                    )
                previous_type = collection_types.get(collection)
                if previous_type is not None and previous_type != collection_type:
                    raise FullstackError(
                        f"OpenAPI collection {collection!r} has inconsistent collection types"
                    )
                collection_types[collection] = collection_type
                collection_root = f"/api/collections/{collection}/records"
                allowed_resource_methods = {
                    collection_root: {"GET", "POST"},
                    collection_root + "/{id}": {"GET", "PATCH", "DELETE"},
                }
                if method.upper() not in allowed_resource_methods.get(path_name, set()):
                    raise FullstackError(
                        f"OpenAPI operation {operation_id!r} carries collection markers "
                        "outside its engine-owned collection method and route"
                    )
            resource_operation = collection is not None
            if not resource_operation:
                consumer_routes_present = True
            access_extension = operation.get("x-zigbase-access")
            auth_extension = operation.get("x-zigbase-auth")
            if (
                access_extension is not None
                and auth_extension is not None
                and access_extension != auth_extension
            ):
                raise FullstackError(
                    f"OpenAPI operation {operation_id!r} has contradictory access metadata"
                )
            if resource_operation:
                if access_extension is None:
                    raise FullstackError(
                        f"OpenAPI resource operation {operation_id!r} lacks x-zigbase-access"
                    )
                operation_access = access_extension
            else:
                if auth_extension is None:
                    raise FullstackError(
                        f"OpenAPI consumer operation {operation_id!r} lacks x-zigbase-auth"
                    )
                operation_access = auth_extension
            if (
                not isinstance(operation_access, str)
                or operation_access not in KNOWN_ENDPOINT_ACCESS
            ):
                raise FullstackError(
                    f"OpenAPI operation {operation_id!r} has unsupported access "
                    f"{operation_access!r}"
                )
            auth_collection = operation.get("x-zigbase-auth-collection")
            allow_superuser = operation.get("x-zigbase-allow-superuser")
            if (auth_collection is None) != (allow_superuser is None):
                raise FullstackError(
                    f"OpenAPI operation {operation_id!r} must declare both "
                    "x-zigbase-auth-collection and x-zigbase-allow-superuser"
                )
            if auth_collection is not None:
                auth_collection = text(
                    auth_collection,
                    f"OpenAPI operation {operation_id!r}.x-zigbase-auth-collection",
                )
                if (
                    resource_operation
                    or operation_access != "authenticated"
                    or not isinstance(allow_superuser, bool)
                ):
                    raise FullstackError(
                        f"OpenAPI operation {operation_id!r} has invalid "
                        "collection-specific authentication metadata"
                    )
            operation_record = {
                "operation_id": operation_id,
                "verb": method.upper(),
                "path": path_name,
                "collection": collection,
                "collection_type": collection_type,
                "access": operation_access,
            }
            if auth_collection is not None:
                operation_record["auth_collection"] = auth_collection
                operation_record["allow_superuser"] = allow_superuser
            if operation_id in builtin_endpoints:
                raise FullstackError(
                    f"OpenAPI path operationId {operation_id!r} collides with exported "
                    "builtin operation metadata"
                )
            operations[operation_id] = operation_record
            route_key = (method.upper(), path_name)
            if route_key in operations_by_route:
                raise FullstackError(
                    f"duplicate OpenAPI route operation {route_key[0]} {path_name}"
                )
            operations_by_route[route_key] = operation_record
            if collection_type == "auth" and collection is not None:
                auth_collections.add(collection)
    if coverage["consumerRoutes"] is not consumer_routes_present:
        raise FullstackError(
            "ZigBase OpenAPI.x-zigbase-coverage.consumerRoutes disagrees with paths"
        )
    exported_contract = text(
        document.get("x-zigbase-contract-version"),
        "ZigBase OpenAPI.x-zigbase-contract-version",
    )
    if exported_contract != OPENAPI_CONTRACT_VERSION:
        raise FullstackError(
            "ZigBase OpenAPI contract version marker is unsupported; "
            f"expected {OPENAPI_CONTRACT_VERSION!r}"
        )
    return (
        operations,
        operations_by_route,
        {
            "openapi": openapi,
            "contract_version": exported_contract,
            "reserved_routes": tuple(reserved_routes),
            "reserved_prefixes": tuple(reserved_prefixes),
            "builtin_endpoints": builtin_endpoints,
        },
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


def load_backend_evidence(
    summary_path: Path, findings_path: Path, capture_path: Path
) -> tuple[
    dict[str, Any],
    dict[tuple[str, str | int | float | bool], dict[str, Any]],
]:
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
        raise IncompleteMigrationError("backend replay did not pass every case")
    if summary["failed"] or summary["errors"]:
        raise IncompleteMigrationError(
            "backend replay contains failures or transport errors"
        )

    passed: set[tuple[str, str | int | float | bool]] = set()
    for line_number, finding in _read_ndjson(findings_path, "backend replay findings"):
        if finding.get("result") != "pass":
            raise IncompleteMigrationError(
                f"backend replay findings line {line_number} is not a passing case"
            )
        case_id = replay_case_identity(
            finding.get("id"), f"backend replay findings line {line_number}.id"
        )
        if case_id in passed:
            raise FullstackError(f"duplicate backend replay case id {case_id!r}")
        passed.add(case_id)
    if len(passed) != summary["passed"]:
        raise FullstackError(
            "backend replay summary and findings disagree on passed case count"
        )
    cases: dict[tuple[str, str | int | float | bool], dict[str, Any]] = {}
    try:
        capture_cases = load_capture(capture_path, mode="capture")
    except ReplayError as exc:
        raise FullstackError(f"invalid backend replay capture: {exc}") from exc
    for case in capture_cases:
        raw_case_id = case["id"]
        case_id = replay_case_identity(raw_case_id, "backend replay capture.id")
        expect = case.get("expect") or {}
        cases[case_id] = {
            "id": raw_case_id,
            "method": case["method"].upper(),
            "path": case["path"],
            "status": expect.get("status"),
            "control": expect.get("control"),
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
        if finding_id in findings:
            raise FullstackError(f"duplicate presentation finding id {finding_id!r}")
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


def _segment_is_canonical(segment: str, *, allow_empty: bool = False) -> bool:
    if (not segment and not allow_empty) or segment in {".", ".."}:
        return False
    return re.fullmatch(r"[A-Za-z0-9._~!$&'()*+,;=:@-]*", segment) is not None


def _openapi_path_is_canonical(path: str) -> bool:
    if not path.startswith("/") or path.startswith("//") or path.endswith("/"):
        return path == "/"
    captures = set()
    for segment in path.split("/")[1:]:
        match = re.fullmatch(r"\{([A-Za-z_][A-Za-z0-9_]*)\}", segment)
        if match:
            if match.group(1) in captures:
                return False
            captures.add(match.group(1))
            continue
        if segment.startswith(":"):
            return False
        if not _segment_is_canonical(segment):
            return False
    return True


def _captured_segment_is_canonical(segment: str) -> bool:
    if not segment or segment in {".", ".."}:
        return False
    if re.search(r"%(?![0-9A-Fa-f]{2})", segment):
        return False
    unescaped = re.sub(r"%[0-9A-Fa-f]{2}", "", segment)
    safe = "!$&'()*+,;=:@-._~"
    if any(
        character.isascii() and not character.isalnum() and character not in safe
        for character in unescaped
    ):
        return False
    try:
        decoded = urllib.parse.unquote_to_bytes(segment)
    except UnicodeEncodeError:
        return False
    if (
        decoded in {b".", b".."}
        or any(byte < 0x20 or byte == 0x7F for byte in decoded)
        or any(delimiter in decoded for delimiter in (b"/", b"\\", b"?", b"#", b"%"))
    ):
        return False
    try:
        decoded_text = decoded.decode("utf-8")
    except UnicodeDecodeError:
        return False
    try:
        canonical = urllib.parse.quote(decoded_text, safe=safe)
        original = urllib.parse.quote(segment, safe=safe + "%")
    except UnicodeEncodeError:
        return False
    return canonical == original


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
            if not _captured_segment_is_canonical(actual):
                return False
            continue
        if expected != actual:
            return False
    return True


def _browser_url_matches_route(route: str, url: str | None) -> bool:
    """Match a concrete same-origin browser URL to one Rails/OpenAPI route pattern."""
    if (
        not isinstance(url, str)
        or not url.startswith("/")
        or url.startswith("//")
        or any(ord(character) < 0x20 or ord(character) == 0x7F for character in url)
    ):
        return False
    try:
        parsed = urllib.parse.urlsplit(url)
    except ValueError:
        return False
    if parsed.scheme or parsed.netloc or not parsed.path.startswith("/"):
        return False
    expected_segments = route.split("/")
    actual_segments = parsed.path.split("/")
    if len(expected_segments) != len(actual_segments):
        return False
    for expected, actual in zip(expected_segments, actual_segments):
        if re.fullmatch(r":[A-Za-z_][A-Za-z0-9_]*", expected) or re.fullmatch(
            r"\{[A-Za-z_][A-Za-z0-9_]*\}", expected
        ):
            if not _captured_segment_is_canonical(actual):
                return False
        elif expected != actual:
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
        if not _segment_is_canonical(segment, allow_empty=path == "/"):
            raise FullstackError(f"{label} custom endpoint path is not canonical")


def _path_matches_reserved_prefix(path: str, prefix: str) -> bool:
    return path == prefix or path.startswith(prefix + "/")


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
    backend: dict[tuple[str, str | int | float | bool], dict[str, Any]],
    browser: dict[str, dict[str, Any]],
    operation: dict[str, Any] | None,
    identity: RouteIdentity,
) -> tuple[list[dict[str, Any]], set[str]]:
    result = []
    controls = set()
    seen = set()
    for index, item_raw in enumerate(require_list(raw, label)):
        item = require_object(item_raw, f"{label}[{index}]")
        kind = text(item.get("kind"), f"{label}[{index}].kind")
        control = text(item.get("control"), f"{label}[{index}].control")
        if kind not in EVIDENCE_KINDS:
            raise FullstackError(f"{label}[{index}].kind must be backend or browser")
        raw_evidence_id = item.get("id")
        evidence_id = (
            replay_case_identity(raw_evidence_id, f"{label}[{index}].id")
            if kind == "backend"
            else text(raw_evidence_id, f"{label}[{index}].id")
        )
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
            if expected_operation is not None and not _browser_url_matches_route(
                operation["path"], source.get("url")
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
            expected_collection = source.get("expect", {}).get("collection")
            if expected_collection is not None and (
                operation is None or expected_collection != operation.get("collection")
            ):
                selected_collection = (
                    operation.get("collection") if operation is not None else None
                )
                raise FullstackError(
                    f"{label} browser evidence {evidence_id!r} names collection "
                    f"{expected_collection!r}, not the selected operation collection "
                    f"{selected_collection!r}"
                )
            if source["kind"] == "navigate" and not _browser_url_matches_route(
                identity.path, source.get("url")
            ):
                raise FullstackError(
                    f"{label} navigation evidence {evidence_id!r} covers "
                    f"{source.get('url')!r}, not {identity.path!r}"
                )
            if source["kind"] == "asset":
                raise FullstackError(
                    f"{label} cannot use an asset check as route parity"
                )
            if source["kind"] in {"signup", "signin"} and (
                operation is None
                or not _browser_url_matches_route(operation["path"], source.get("url"))
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
        result.append({"kind": kind, "id": raw_evidence_id, "control": control})
    return result, controls


def _endpoint_operation(
    endpoint: Any,
    operations: dict[str, dict[str, Any]],
    operations_by_route: dict[tuple[str, str], dict[str, Any]],
    auth_collections: frozenset[str],
    openapi_contract: dict[str, Any],
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
        prefix_collision = next(
            (
                (prefix, source)
                for prefix, source in openapi_contract["reserved_prefixes"]
                if _path_matches_reserved_prefix(path, prefix)
            ),
            None,
        )
        if prefix_collision is not None:
            prefix, source = prefix_collision
            raise FullstackError(
                f"{label} custom endpoint aliases engine-owned {source} prefix {prefix}"
            )
        reserved = next(
            (
                template
                for reserved_method, template in openapi_contract["reserved_routes"]
                if reserved_method == verb and _path_matches_template(template, path)
            ),
            None,
        )
        if reserved is not None:
            raise FullstackError(
                f"{label} custom endpoint aliases engine-owned route {verb} {reserved}"
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
            "collection_type": None,
            "access": access,
        }
    if custom_access is not None:
        raise FullstackError(
            f"{label} declares backend_access for a non-custom endpoint"
        )
    builtin = openapi_contract["builtin_endpoints"].get(operation_id)
    if operation_id not in SUPPORTED_BUILTIN_OPERATIONS or builtin is None:
        raise FullstackError(
            f"{label} names unknown endpoint operation {operation_id!r}"
        )
    pattern = re.escape(builtin["path"]).replace(
        re.escape("{collection}"), r"([A-Za-z][A-Za-z0-9_]*)"
    )
    match = re.fullmatch(pattern, path)
    if verb != builtin["method"] or match is None:
        raise FullstackError(
            f"{label} builtin endpoint {operation_id!r} must be "
            f"{builtin['method']} {builtin['path']}"
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
        "collection": match.group(1),
        "collection_type": builtin["collection_type"],
        "access": builtin["access"],
    }


def _validate_auth(operation: dict[str, Any] | None, auth: str, label: str) -> None:
    if operation is None:
        return
    access = operation["access"]
    if access not in KNOWN_ENDPOINT_ACCESS:
        raise FullstackError(
            f"{label} selects an operation with unsupported access {access!r}"
        )
    if access == "locked":
        raise FullstackError(
            f"{label} selects a locked operation that cannot serve migrated traffic"
        )
    if auth != access:
        raise IncompleteMigrationError(
            f"{label} must exactly match the selected operation's {access!r} access; "
            f"got {auth!r}"
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

    presentation_generator = presentation["generator"]
    handoff_generator = handoff["generator"]
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
        error_type = IncompleteMigrationError if missing else FullstackError
        raise error_type(
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
                openapi_contract,
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
                raise IncompleteMigrationError(
                    f"migrated route {identity_label} has no replacement artifact"
                )
            if not evidence:
                raise IncompleteMigrationError(
                    f"migrated route {identity_label} has no parity evidence"
                )
            evidence_kinds = {item["kind"] for item in evidence}
            if surface == "browser" and "browser" not in evidence_kinds:
                raise IncompleteMigrationError(
                    f"browser route {identity_label} has no browser parity evidence"
                )
            if surface == "api" and "backend" not in evidence_kinds:
                raise IncompleteMigrationError(
                    f"API route {identity_label} has no backend parity evidence"
                )
            if route_is_mutating(identity.verb) and auth not in {
                "public",
                "not-applicable",
            }:
                if not {"allowed", "denied"}.issubset(controls):
                    raise IncompleteMigrationError(
                        f"protected mutation {identity_label} needs allowed and denied parity controls"
                    )
        elif disposition == "blocked":
            if operation_id is not None:
                raise FullstackError(
                    f"blocked route {identity_label} cannot name a backend operation"
                )
            if not isinstance(blockers, list) or not all(
                isinstance(item, str) and item.strip() for item in blockers
            ):
                raise FullstackError(
                    f"blocked route {identity_label} blockers must be non-empty strings"
                )
            if not blockers:
                raise IncompleteMigrationError(
                    f"blocked route {identity_label} must name blocker ids"
                )
            if source_presentation is None:
                raise IncompleteMigrationError(
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
                raise IncompleteMigrationError(
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
        raise IncompleteMigrationError(
            "presentation blockers are not represented by blocked route decisions: "
            f"{sorted(uncovered_presentation_blockers, key=lambda item: (item[0], item[1] or ''))}"
        )

    return {
        "schema": "zigbase.rails-fullstack/1",
        "schema_version": FULLSTACK_VERSION,
        "contracts": {
            "zigbase_rails_inventory": backend_inventory_contract,
            "zigbase_openapi": {
                "openapi": openapi_contract["openapi"],
                "contract_version": openapi_contract["contract_version"],
            },
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
    parser = CoordinatorArgumentParser(description=__doc__)
    parser.add_argument("--backend-routes", required=True, type=Path)
    parser.add_argument("--presentation-manifest", required=True, type=Path)
    parser.add_argument("--presentation-handoff", required=True, type=Path)
    parser.add_argument("--backend-openapi", required=True, type=Path)
    parser.add_argument("--decisions", required=True, type=Path)
    parser.add_argument("--backend-replay", required=True, type=Path)
    parser.add_argument("--backend-findings", required=True, type=Path)
    parser.add_argument("--backend-capture", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    try:
        args = parser.parse_args(argv)
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
    except IncompleteMigrationError as exc:
        print(f"rails-fullstack: {exc}", file=sys.stderr)
        return 2
    except FullstackError as exc:
        print(f"rails-fullstack: {exc}", file=sys.stderr)
        return 1
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
