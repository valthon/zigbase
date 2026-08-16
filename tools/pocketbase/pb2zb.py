#!/usr/bin/env python3
"""Inventory and convert an offline PocketBase snapshot for ZigBase.

The schema contract is PocketBase's public collection export. SQLite is opened read-only and is
used only to verify that the exported collections match the stopped snapshot. Conversion and file
installation are added by the later implementation tasks; this module already freezes the
inventory and durable-decision contracts they consume.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import shutil
import sqlite3
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SOURCE_VERSION = "0.39.11"
INVENTORY_VERSION = 1
DECISIONS_VERSION = 1
MAX_SCHEMA_BYTES = 32 * 1024 * 1024
MAX_COLLECTIONS = 10_000
MAX_FIELDS_PER_COLLECTION = 10_000
MAX_REPLACEMENT_BYTES = 4 * 1024 * 1024
MAX_NDJSON_LINE_BYTES = 1024 * 1024
BCRYPT = re.compile(r"^\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}$")
BCRYPT_DIGEST_COLUMN = "__zigbase_bcrypt_digest"

COLLECTION_TYPES = frozenset({"base", "auth", "view"})
DIRECT_FIELD_TYPES = frozenset(
    {
        "autodate",
        "bool",
        "date",
        "editor",
        "email",
        "file",
        "json",
        "number",
        "relation",
        "select",
        "text",
        "url",
    }
)
IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
POCKETBASE_ID = re.compile(r"^[A-Za-z0-9_]+$")
SIMPLE_INDEX = re.compile(
    r'^CREATE\s+(?:(UNIQUE)\s+)?INDEX\s+[`"]?([A-Za-z][A-Za-z0-9_]*)[`"]?\s+'
    r'ON\s+[`"]?([A-Za-z][A-Za-z0-9_]*)[`"]?\s*\(([^)]+)\)\s*$',
    re.IGNORECASE,
)
SIMPLE_INDEX_FIELD = re.compile(r'^[`"]?([A-Za-z][A-Za-z0-9_]*)[`"]?$', re.IGNORECASE)
RESERVED_FIELD_NAMES = frozenset(
    {
        "id",
        "created",
        "updated",
        "email",
        "username",
        "passwordhash",
        "tokenkey",
        "verified",
        "token_epoch",
    }
)
RULE_KEYS = (
    "listRule",
    "viewRule",
    "createRule",
    "updateRule",
    "deleteRule",
    "manageRule",
    "authRule",
)


class PocketBaseError(Exception):
    """A bounded, user-actionable input or tool failure."""


@dataclass(frozen=True)
class Finding:
    """Stable migration finding. Message prose is deliberately not part of its identity."""

    id: str
    severity: str
    code: str
    message: str
    choices: tuple[str, ...] = ()
    requires_artifact: bool = False

    def to_dict(self) -> dict[str, Any]:
        value: dict[str, Any] = {
            "id": self.id,
            "severity": self.severity,
            "code": self.code,
            "message": self.message,
        }
        if self.choices:
            value["choices"] = list(self.choices)
        if self.requires_artifact:
            value["requiresArtifact"] = True
        return value


@dataclass(frozen=True)
class Decision:
    id: str
    choice: str
    rationale: str
    artifact: str | None = None


@dataclass(frozen=True, order=True)
class FileReference:
    source_collection_id: str
    target_collection: str
    record_id: str
    filename: str


def _read_json(path: Path, *, limit: int, label: str) -> Any:
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise PocketBaseError(f"cannot stat {label} {path}: {exc}") from exc
    if size > limit:
        raise PocketBaseError(f"{label} exceeds the {limit}-byte limit: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise PocketBaseError(f"cannot read {label} {path}: {exc}") from exc


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as exc:
        raise PocketBaseError(f"cannot hash {path}: {exc}") from exc
    return digest.hexdigest()


def _required_string(value: dict[str, Any], key: str, where: str) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result:
        raise PocketBaseError(f"{where}.{key} must be a non-empty string")
    return result


def load_schema(path: Path) -> list[dict[str, Any]]:
    """Load the public PocketBase collection-export array with structural bounds."""
    value = _read_json(path, limit=MAX_SCHEMA_BYTES, label="PocketBase schema export")
    if not isinstance(value, list):
        raise PocketBaseError(
            "PocketBase schema export must be a JSON array of collections"
        )
    if len(value) > MAX_COLLECTIONS:
        raise PocketBaseError(
            f"schema export exceeds the {MAX_COLLECTIONS}-collection limit"
        )

    collection_ids: set[str] = set()
    collection_names: set[str] = set()
    for index, collection in enumerate(value):
        where = f"collections[{index}]"
        if not isinstance(collection, dict):
            raise PocketBaseError(f"{where} must be an object")
        collection_id = _required_string(collection, "id", where)
        name = _required_string(collection, "name", where)
        if "system" in collection and not isinstance(collection["system"], bool):
            raise PocketBaseError(f"{where}.system must be a boolean")
        if not POCKETBASE_ID.fullmatch(collection_id):
            raise PocketBaseError(f"{where}.id is not a valid PocketBase identifier")
        collection_type = collection.get("type") or "base"
        if collection_type not in COLLECTION_TYPES:
            raise PocketBaseError(f"{where}.type is unsupported: {collection_type!r}")
        if collection_id in collection_ids:
            raise PocketBaseError(f"duplicate collection id: {collection_id!r}")
        if name in collection_names:
            raise PocketBaseError(f"duplicate collection name: {name!r}")
        collection_ids.add(collection_id)
        collection_names.add(name)
        fields = collection.get("fields", [])
        if not isinstance(fields, list):
            raise PocketBaseError(f"{where}.fields must be an array")
        if len(fields) > MAX_FIELDS_PER_COLLECTION:
            raise PocketBaseError(
                f"{where}.fields exceeds the {MAX_FIELDS_PER_COLLECTION}-field limit"
            )
        field_ids: set[str] = set()
        field_names: set[str] = set()
        for field_index, field in enumerate(fields):
            field_where = f"{where}.fields[{field_index}]"
            if not isinstance(field, dict):
                raise PocketBaseError(f"{field_where} must be an object")
            field_id = _required_string(field, "id", field_where)
            field_name = _required_string(field, "name", field_where)
            _required_string(field, "type", field_where)
            for boolean_key in ("required", "system", "hidden"):
                if boolean_key in field and not isinstance(field[boolean_key], bool):
                    raise PocketBaseError(
                        f"{field_where}.{boolean_key} must be a boolean"
                    )
            if not POCKETBASE_ID.fullmatch(field_id):
                raise PocketBaseError(
                    f"{field_where}.id is not a valid PocketBase identifier"
                )
            if field_id in field_ids:
                raise PocketBaseError(f"duplicate field id in {name!r}: {field_id!r}")
            if field_name in field_names:
                raise PocketBaseError(
                    f"duplicate field name in {name!r}: {field_name!r}"
                )
            field_ids.add(field_id)
            field_names.add(field_name)
        indexes = collection.get("indexes", [])
        if not isinstance(indexes, list) or not all(
            isinstance(item, str) for item in indexes
        ):
            raise PocketBaseError(f"{where}.indexes must be an array of strings")
        for key in RULE_KEYS:
            rule = collection.get(key)
            if rule is not None and not isinstance(rule, str):
                raise PocketBaseError(f"{where}.{key} must be a string or null")
    for collection in value:
        for field in collection.get("fields", []):
            if field.get("system") or field["type"] != "relation":
                continue
            options = (
                field.get("options") if isinstance(field.get("options"), dict) else {}
            )
            target = field.get("collectionId") or options.get("collectionId")
            if not isinstance(target, str) or target not in collection_ids:
                raise PocketBaseError(
                    f"relation field {collection['name']}.{field['name']} targets an unknown exported collection id"
                )
    return value


def _open_snapshot(pb_data: Path) -> tuple[sqlite3.Connection, Path]:
    if not pb_data.is_dir():
        raise PocketBaseError(f"PocketBase data directory does not exist: {pb_data}")
    database = pb_data / "data.db"
    if not database.is_file():
        raise PocketBaseError(f"PocketBase snapshot is missing {database}")
    if database.is_symlink():
        raise PocketBaseError("PocketBase data.db must not be a symbolic link")
    for suffix in ("-wal", "-shm"):
        sidecar = Path(f"{database}{suffix}")
        if sidecar.exists():
            raise PocketBaseError(
                f"snapshot has SQLite sidecar {sidecar.name}; stop PocketBase and make a consistent backup"
            )
    try:
        connection = sqlite3.connect(
            f"{database.resolve().as_uri()}?mode=ro&immutable=1", uri=True
        )
        connection.execute("PRAGMA query_only=ON")
    except sqlite3.Error as exc:
        raise PocketBaseError(
            f"cannot open PocketBase database read-only: {exc}"
        ) from exc
    return connection, database


def _snapshot_tables(connection: sqlite3.Connection) -> dict[str, str]:
    try:
        rows = connection.execute(
            "SELECT name, type FROM sqlite_master WHERE type IN ('table','view')"
        ).fetchall()
    except sqlite3.Error as exc:
        raise PocketBaseError(f"cannot inventory PocketBase tables: {exc}") from exc
    return {str(name): str(kind) for name, kind in rows}


def _table_columns(connection: sqlite3.Connection, name: str) -> set[str]:
    try:
        rows = connection.execute(
            "SELECT name FROM pragma_table_info(?)", (name,)
        ).fetchall()
    except sqlite3.Error as exc:
        raise PocketBaseError(
            f"cannot inspect PocketBase table {name!r}: {exc}"
        ) from exc
    return {str(row[0]) for row in rows}


def _check_snapshot_shape(
    connection: sqlite3.Connection, collections: list[dict[str, Any]]
) -> None:
    tables = _snapshot_tables(connection)
    for collection in collections:
        name = str(collection["name"])
        expected_kind = (
            "view" if (collection.get("type") or "base") == "view" else "table"
        )
        if tables.get(name) != expected_kind:
            raise PocketBaseError(
                f"exported collection {name!r} expects a SQLite {expected_kind}, but the snapshot does not match"
            )
        columns = _table_columns(connection, name)
        kind = collection.get("type") or "base"
        expected_columns = {"id"}
        expected_columns.update(
            str(field["name"])
            for field in collection.get("fields", [])
            if not bool(field.get("system")) and kind != "view"
        )
        if kind == "auth":
            expected_columns.update(
                {"email", "emailVisibility", "verified", "password", "tokenKey"}
            )
        missing = sorted(expected_columns - columns)
        if missing:
            raise PocketBaseError(
                f"snapshot table {name!r} is missing exported columns: {', '.join(missing)}"
            )


def _rule_requires_replacement(rule: str) -> bool:
    """Conservatively reject PocketBase rule surface ZigBase cannot preserve."""
    if (
        "@collection." in rule
        or "_via_" in rule
        or re.search(r"@request\.(?:body|query|headers|context)(?:\.|\b)", rule)
        or re.search(r":[A-Za-z][A-Za-z0-9_]*", rule)
        or re.search(r"\?(?:=|!=|>|>=|<|<=|~)", rule)
    ):
        return True
    for macro in re.findall(r"@[A-Za-z][A-Za-z0-9_.]*", rule):
        if macro in {"@request.method", "@request.auth.id"}:
            continue
        if macro.startswith("@request.auth.") and macro not in {
            "@request.auth.collectionName",
            "@request.auth.verified",
        }:
            continue
        return True
    return False


def _parse_simple_index(
    index: str, collection_name: str, fields: set[str]
) -> dict[str, Any] | None:
    match = SIMPLE_INDEX.fullmatch(index.strip().rstrip(";"))
    if not match or match.group(3) != collection_name:
        return None
    parts = [part.strip() for part in match.group(4).split(",")]
    if not parts:
        return None
    parsed = [SIMPLE_INDEX_FIELD.fullmatch(part) for part in parts]
    if not all(field is not None and field.group(1) in fields for field in parsed):
        return None
    return {
        "name": match.group(2),
        "fields": [field.group(1) for field in parsed if field is not None],
        "unique": match.group(1) is not None,
    }


def _is_pocketbase_auth_system_index(index: str, collection: dict[str, Any]) -> bool:
    if (collection.get("type") or "base") != "auth":
        return False
    normalized = " ".join(index.replace("`", "").replace('"', "").split())
    collection_id = str(collection["id"])
    name = str(collection["name"])
    return normalized in {
        f"CREATE UNIQUE INDEX idx_tokenKey_{collection_id} ON {name} (tokenKey)",
        f"CREATE UNIQUE INDEX idx_email_{collection_id} ON {name} (email) WHERE email != ''",
    }


def _finding_id(*parts: str) -> str:
    return ".".join(part.replace(".", "_") for part in parts)


def _has_values(value: Any) -> bool:
    return isinstance(value, list) and bool(value)


def _positive_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and value > 0


def _field_option_finding(
    collection_id: str, field: dict[str, Any], message: str
) -> Finding:
    return Finding(
        _finding_id("field", collection_id, str(field["id"]), "options"),
        "blocker",
        "FieldOptionsRequireReplacement",
        message,
        ("replacement", "omit"),
        True,
    )


def _is_source_timestamp_field(field: dict[str, Any]) -> bool:
    return field.get("type") == "autodate" and field.get("name") in {
        "created",
        "updated",
    }


def _is_verified_auth_rule(rule: Any) -> bool:
    return (
        isinstance(rule, str)
        and re.fullmatch(r"\s*verified\s*=\s*true\s*", rule, re.IGNORECASE) is not None
    )


def _auth_profiles_are_owner_scoped(collection: dict[str, Any]) -> bool:
    owner_rules = {
        "id = @request.auth.id",
        "@request.auth.id = id",
    }
    for key in ("listRule", "viewRule"):
        rule = collection.get(key)
        if rule is not None and rule.strip() not in owner_rules:
            return False
    return True


def _unsupported_field_options(
    collection_id: str, collection_name: str, field: dict[str, Any]
) -> Finding | None:
    field_type = str(field["type"])
    label = f"Field {collection_name}.{field['name']}"
    if field.get("primaryKey"):
        return _field_option_finding(
            collection_id,
            field,
            f"{label} is a custom primary key, which requires replacement.",
        )
    if field_type == "text" and field.get("autogeneratePattern"):
        return _field_option_finding(
            collection_id,
            field,
            f"{label} auto-generates values, which ZigBase fields do not.",
        )
    if field_type in {"email", "url"} and (
        _has_values(field.get("exceptDomains")) or _has_values(field.get("onlyDomains"))
    ):
        return _field_option_finding(
            collection_id,
            field,
            f"{label} has domain allow/deny behavior requiring replacement.",
        )
    if field_type == "editor" and (
        bool(field.get("convertURLs")) or _positive_number(field.get("maxSize"))
    ):
        return _field_option_finding(
            collection_id,
            field,
            f"{label} has editor conversion/size behavior requiring replacement.",
        )
    if field_type == "file" and (
        bool(field.get("protected")) or _has_values(field.get("thumbs"))
    ):
        return _field_option_finding(
            collection_id,
            field,
            f"{label} has protected/thumbnail behavior requiring replacement.",
        )
    return None


def collect_findings(collections: list[dict[str, Any]], pb_data: Path) -> list[Finding]:
    findings: list[Finding] = []
    has_file_fields = False
    for collection in collections:
        collection_id = str(collection["id"])
        name = str(collection["name"])
        kind = str(collection.get("type") or "base")
        fields = collection.get("fields", [])
        field_names = {str(field["name"]) for field in fields}

        is_system = bool(collection.get("system")) or name.startswith("_")
        if is_system:
            findings.append(
                Finding(
                    _finding_id("collection", collection_id, "system"),
                    "decision",
                    "SystemCollectionRequiresOmission",
                    f"PocketBase system collection {name!r} is not migrated as application data.",
                    ("omit",),
                )
            )
            continue
        if not IDENTIFIER.fullmatch(name):
            findings.append(
                Finding(
                    _finding_id("collection", collection_id, "identifier"),
                    "blocker",
                    "CollectionIdentifierRequiresReplacement",
                    f"Collection {name!r} is not a valid ZigBase identifier.",
                    ("replacement", "omit"),
                    True,
                )
            )
        if kind == "view":
            findings.append(
                Finding(
                    _finding_id("collection", collection_id, "view"),
                    "blocker",
                    "ViewCollectionRequiresReplacement",
                    f"View collection {name!r} contains SQL semantics ZigBase cannot translate automatically.",
                    ("replacement", "materialize"),
                    True,
                )
            )
        if kind == "auth":
            findings.append(
                Finding(
                    _finding_id("collection", collection_id, "authConfig"),
                    "decision",
                    "AuthCollectionConfigurationRequiresReview",
                    f"Auth collection {name!r} needs review of password, OAuth, MFA, OTP, token, and mail-template behavior.",
                    ("reviewed",),
                )
            )
            for method in ("oauth2", "mfa", "otp"):
                config = collection.get(method)
                if isinstance(config, dict) and config.get("enabled") is True:
                    findings.append(
                        Finding(
                            _finding_id(
                                "collection", collection_id, method, "replacement"
                            ),
                            "blocker",
                            "AuthMethodRequiresReplacement",
                            f"Auth collection {name!r} enables PocketBase {method}, which requires replacement code/configuration.",
                            ("replacement",),
                            True,
                        )
                    )
            password_auth = collection.get("passwordAuth")
            if (
                isinstance(password_auth, dict)
                and password_auth.get("enabled") is False
            ):
                findings.append(
                    Finding(
                        _finding_id(
                            "collection", collection_id, "passwordAuth", "replacement"
                        ),
                        "blocker",
                        "DisabledPasswordAuthRequiresReplacement",
                        f"Auth collection {name!r} disables password login; ZigBase migration must preserve that behavior explicitly.",
                        ("replacement",),
                        True,
                    )
                )
            auth_rule = collection.get("authRule")
            if not _is_verified_auth_rule(auth_rule):
                findings.append(
                    Finding(
                        _finding_id(
                            "collection", collection_id, "authRule", "replacement"
                        ),
                        "blocker",
                        "AuthRuleRequiresReplacement",
                        f"Auth collection {name!r} has a disabled or non-verification PocketBase authRule that ZigBase cannot preserve automatically.",
                        ("replacement",),
                        True,
                    )
                )
            if not _auth_profiles_are_owner_scoped(collection):
                findings.append(
                    Finding(
                        _finding_id(
                            "collection", collection_id, "emailVisibility", "review"
                        ),
                        "decision",
                        "EmailVisibilityRequiresReview",
                        f"Auth collection {name!r} can expose non-owner profiles, but ZigBase does not preserve PocketBase's per-record emailVisibility behavior.",
                        ("reviewed",),
                    )
                )

        for field in fields:
            field_id = str(field["id"])
            field_name = str(field["name"])
            field_type = str(field["type"])
            if bool(field.get("system")):
                if (
                    kind == "auth"
                    and field_name == "email"
                    and (
                        _has_values(field.get("exceptDomains"))
                        or _has_values(field.get("onlyDomains"))
                    )
                ):
                    findings.append(
                        _field_option_finding(
                            collection_id,
                            field,
                            f"Field {name}.{field_name} has domain allow/deny behavior requiring replacement.",
                        )
                    )
                continue
            if _is_source_timestamp_field(field):
                continue
            if field_type == "file":
                has_file_fields = True
            if field_type == "autodate":
                findings.append(
                    Finding(
                        _finding_id("field", collection_id, field_id, "autodate"),
                        "decision",
                        "AutoDateRequiresMapping",
                        f"Field {name}.{field_name} needs a history-preserving date mapping or replacement behavior.",
                        ("date", "replacement", "omit"),
                        True,
                    )
                )
            if option_finding := _unsupported_field_options(collection_id, name, field):
                findings.append(option_finding)
            if field.get("hidden") is True:
                findings.append(
                    Finding(
                        _finding_id("field", collection_id, field_id, "hidden"),
                        "blocker",
                        "HiddenFieldWriteProtectionRequiresReplacement",
                        f"Field {name}.{field_name} is PocketBase-hidden and therefore write-protected; ZigBase hidden fields are read-hidden but remain client-writable.",
                        ("replacement", "omit"),
                        True,
                    )
                )
            if field_type == "geoPoint":
                findings.append(
                    Finding(
                        _finding_id("field", collection_id, field_id, "geoPoint"),
                        "decision",
                        "GeoPointRequiresMapping",
                        f"Field {name}.{field_name} needs an explicit value-only mapping or omission.",
                        ("json", "omit"),
                    )
                )
            elif field_type not in DIRECT_FIELD_TYPES:
                findings.append(
                    Finding(
                        _finding_id("field", collection_id, field_id, "unsupported"),
                        "blocker",
                        "UnknownFieldTypeRequiresReplacement",
                        f"Field {name}.{field_name} has unsupported PocketBase type {field_type!r}.",
                        ("replacement", "omit"),
                        True,
                    )
                )
            if (
                not IDENTIFIER.fullmatch(field_name)
                or field_name.casefold() in RESERVED_FIELD_NAMES
            ):
                findings.append(
                    Finding(
                        _finding_id("field", collection_id, field_id, "identifier"),
                        "blocker",
                        "FieldIdentifierRequiresReplacement",
                        f"Field {name}.{field_name} is not a valid ZigBase user-field identifier or uses a reserved system name.",
                        ("replacement", "omit"),
                        True,
                    )
                )

        for key in RULE_KEYS:
            if key == "authRule":
                continue
            rule = collection.get(key)
            if rule is None:
                continue
            if rule == "":
                findings.append(
                    Finding(
                        _finding_id("rule", collection_id, key, "public"),
                        "decision",
                        "PublicRuleRequiresReview",
                        f"Rule {name}.{key} allows anonymous access and will map to @public.",
                        ("public",),
                    )
                )
            if key == "manageRule" or (rule and _rule_requires_replacement(str(rule))):
                findings.append(
                    Finding(
                        _finding_id("rule", collection_id, key, "replacement"),
                        "blocker",
                        "PocketBaseRuleRequiresReplacement",
                        f"Rule {name}.{key} uses PocketBase-only semantics.",
                        ("replacement",),
                        True,
                    )
                )

        for index_number, index in enumerate(collection.get("indexes", [])):
            if _is_pocketbase_auth_system_index(str(index), collection):
                continue
            if _parse_simple_index(str(index), name, field_names) is None:
                index_id = hashlib.sha256(str(index).encode()).hexdigest()[:16]
                findings.append(
                    Finding(
                        _finding_id("index", collection_id, index_id, "replacement"),
                        "blocker",
                        "ComplexIndexRequiresReplacement",
                        f"Index {index_number} on {name!r} is not a simple column index.",
                        ("replacement", "omit"),
                        True,
                    )
                )

    project_root = pb_data.parent
    if has_file_fields:
        findings.append(
            Finding(
                "source.file_storage.confirmation",
                "decision",
                "FileStorageSnapshotRequiresConfirmation",
                "The public schema export does not prove whether file bytes came from local storage or S3.",
                ("local-snapshot", "materialized-s3"),
            )
        )
    hooks = project_root / "pb_hooks"
    if hooks.is_dir() and any(path.is_file() for path in hooks.rglob("*")):
        findings.append(
            Finding(
                "source.pb_hooks.replacement",
                "blocker",
                "PocketBaseHooksRequireReplacement",
                "The snapshot project contains PocketBase hooks that require reviewed replacement code.",
                ("replacement",),
                True,
            )
        )
    migrations = project_root / "pb_migrations"
    if migrations.is_dir() and any(path.is_file() for path in migrations.rglob("*")):
        findings.append(
            Finding(
                "source.pb_migrations.review",
                "info",
                "PocketBaseMigrationsPresent",
                "Review PocketBase migrations for behavior not represented by the current schema export.",
            )
        )
    # A PocketBase Go extension is conventionally rooted by go.mod/main.go. Avoid a recursive
    # scan here: `pb_data` may have a broad parent on an operator's machine, and inventory must
    # have bounded filesystem reach.
    if (project_root / "go.mod").is_file() or (project_root / "main.go").is_file():
        findings.append(
            Finding(
                "source.custom_go.replacement",
                "blocker",
                "PocketBaseGoCodeRequiresReplacement",
                "The snapshot project contains custom Go code that requires reviewed replacement code.",
                ("replacement",),
                True,
            )
        )
    return sorted(findings, key=lambda finding: finding.id)


def load_decisions(path: Path) -> tuple[str, tuple[Decision, ...]]:
    value = _read_json(path, limit=4 * 1024 * 1024, label="PocketBase decisions")
    if not isinstance(value, dict):
        raise PocketBaseError("decisions document must be an object")
    expected = {"zigbasePocketBaseDecisions", "sourceVersion", "decisions"}
    if set(value) != expected:
        raise PocketBaseError(
            "decisions document has missing or unknown top-level keys"
        )
    if value["zigbasePocketBaseDecisions"] != DECISIONS_VERSION:
        raise PocketBaseError("unsupported PocketBase decisions version")
    source_version = value["sourceVersion"]
    if source_version != SOURCE_VERSION:
        raise PocketBaseError(
            f"decisions sourceVersion must be {SOURCE_VERSION!r}, got {source_version!r}"
        )
    raw_decisions = value["decisions"]
    if not isinstance(raw_decisions, list):
        raise PocketBaseError("decisions must be an array")
    result: list[Decision] = []
    seen: set[str] = set()
    for index, raw in enumerate(raw_decisions):
        if not isinstance(raw, dict):
            raise PocketBaseError(f"decisions[{index}] must be an object")
        allowed = {"id", "choice", "rationale", "artifact"}
        if not {"id", "choice", "rationale"}.issubset(raw) or not set(raw).issubset(
            allowed
        ):
            raise PocketBaseError(f"decisions[{index}] has missing or unknown keys")
        decision_id = _required_string(raw, "id", f"decisions[{index}]")
        choice = _required_string(raw, "choice", f"decisions[{index}]")
        rationale = _required_string(raw, "rationale", f"decisions[{index}]").strip()
        if not rationale:
            raise PocketBaseError(f"decisions[{index}].rationale must not be blank")
        artifact = raw.get("artifact")
        if artifact is not None and (
            not isinstance(artifact, str) or not artifact.strip()
        ):
            raise PocketBaseError(
                f"decisions[{index}].artifact must be a non-empty string"
            )
        if decision_id in seen:
            raise PocketBaseError(f"duplicate decision id: {decision_id!r}")
        seen.add(decision_id)
        result.append(Decision(decision_id, choice, rationale, artifact))
    return source_version, tuple(result)


def reconcile_decisions(
    findings: list[Finding], decisions: tuple[Decision, ...]
) -> None:
    required = {finding.id: finding for finding in findings if finding.choices}
    supplied = {decision.id: decision for decision in decisions}
    stale = sorted(set(supplied) - set(required))
    missing = sorted(set(required) - set(supplied))
    if stale:
        raise PocketBaseError(f"unknown or stale decisions: {', '.join(stale)}")
    if missing:
        raise PocketBaseError(f"unacknowledged findings: {', '.join(missing)}")
    for decision_id in sorted(required):
        finding = required[decision_id]
        decision = supplied[decision_id]
        if decision.choice not in finding.choices:
            raise PocketBaseError(
                f"decision {decision_id!r} choice must be one of {list(finding.choices)!r}"
            )
        if (
            finding.requires_artifact
            and decision.choice not in {"omit", "date"}
            and not decision.artifact
        ):
            raise PocketBaseError(
                f"decision {decision_id!r} requires a replacement artifact"
            )
        if decision.artifact:
            artifact = Path(decision.artifact)
            if (
                artifact.is_absolute()
                or ".." in artifact.parts
                or artifact == Path(".")
                or "\\" in decision.artifact
                or "\x00" in decision.artifact
            ):
                raise PocketBaseError(
                    f"decision {decision_id!r} artifact must be a safe relative path"
                )


def _build_inventory(
    schema_path: Path,
    pb_data: Path,
    collections: list[dict[str, Any]],
    connection: sqlite3.Connection,
    database: Path,
) -> dict[str, Any]:
    _check_snapshot_shape(connection, collections)
    findings = collect_findings(collections, pb_data)
    decisions = sum(finding.severity == "decision" for finding in findings)
    blockers = sum(finding.severity == "blocker" for finding in findings)
    infos = sum(finding.severity == "info" for finding in findings)
    collection_inventory = [
        {
            "id": collection["id"],
            "name": collection["name"],
            "type": collection.get("type") or "base",
            "fields": len(collection.get("fields", [])),
            "indexes": len(collection.get("indexes", [])),
        }
        for collection in sorted(
            collections, key=lambda item: (str(item["name"]), str(item["id"]))
        )
    ]
    return {
        "zigbasePocketBaseInventory": INVENTORY_VERSION,
        "sourceVersion": SOURCE_VERSION,
        "schemaSha256": _sha256(schema_path),
        "databaseSha256": _sha256(database),
        "collections": collection_inventory,
        "findings": [finding.to_dict() for finding in findings],
        "summary": {
            "collections": len(collections),
            "decisions": decisions,
            "blockers": blockers,
            "info": infos,
        },
    }


def build_inventory(schema_path: Path, pb_data: Path) -> dict[str, Any]:
    collections = load_schema(schema_path)
    connection, database = _open_snapshot(pb_data)
    try:
        return _build_inventory(schema_path, pb_data, collections, connection, database)
    finally:
        connection.close()


def _decision_map(decisions: tuple[Decision, ...]) -> dict[str, Decision]:
    return {decision.id: decision for decision in decisions}


def _path_contains_symlink(root: Path, relative: Path) -> bool:
    current = root
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            return True
    return False


def _safe_artifact_path(decisions_path: Path, decision: Decision) -> Path:
    if not decision.artifact:
        raise PocketBaseError(f"decision {decision.id!r} has no replacement artifact")
    root = decisions_path.parent.resolve()
    relative = Path(decision.artifact)
    candidate = (root / relative).resolve()
    if (
        not candidate.is_relative_to(root)
        or not candidate.is_file()
        or _path_contains_symlink(root, relative)
    ):
        raise PocketBaseError(
            f"decision {decision.id!r} replacement artifact is missing, unsafe, or not a regular file"
        )
    if candidate.stat().st_size > MAX_REPLACEMENT_BYTES:
        raise PocketBaseError(
            f"decision {decision.id!r} replacement artifact exceeds {MAX_REPLACEMENT_BYTES} bytes"
        )
    return candidate


def _replacement_value(
    decisions_path: Path, decision: Decision, expected_kind: str
) -> Any:
    path = _safe_artifact_path(decisions_path, decision)
    value = _read_json(path, limit=MAX_REPLACEMENT_BYTES, label="replacement artifact")
    if not isinstance(value, dict) or set(value) != {
        "zigbasePocketBaseReplacement",
        "finding",
        "kind",
        "value",
    }:
        raise PocketBaseError(
            f"replacement artifact for {decision.id!r} has an invalid contract"
        )
    if (
        value["zigbasePocketBaseReplacement"] != 1
        or value["finding"] != decision.id
        or value["kind"] != expected_kind
    ):
        raise PocketBaseError(
            f"replacement artifact for {decision.id!r} does not match its finding/kind"
        )
    return value["value"]


def _positive_int(value: Any, default: int = 0) -> int:
    if isinstance(value, int) and not isinstance(value, bool) and value > 0:
        return value
    return default


def _bounded_positive_int(value: Any, default: int, maximum: int, label: str) -> int:
    result = _positive_int(value, default)
    if result > maximum:
        raise PocketBaseError(f"{label} exceeds ZigBase's supported range")
    return result


def _optional_number(value: Any) -> int | float | None:
    if (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and (not isinstance(value, float) or math.isfinite(value))
    ):
        return value
    return None


def _field_options(
    field: dict[str, Any], collection_names: dict[str, str]
) -> dict[str, Any]:
    field_type = str(field["type"])
    if field_type in {"email", "url", "editor", "bool"}:
        return {}
    if field_type == "text":
        result: dict[str, Any] = {}
        if minimum := _bounded_positive_int(
            field.get("min"), 0, 2**32 - 1, f"field {field['name']} min"
        ):
            result["min"] = minimum
        if maximum := _bounded_positive_int(
            field.get("max"), 0, 2**32 - 1, f"field {field['name']} max"
        ):
            result["max"] = maximum
        if isinstance(field.get("pattern"), str) and field["pattern"]:
            result["pattern"] = field["pattern"]
        return result
    if field_type == "date":
        return {
            key: field[key]
            for key in ("min", "max")
            if isinstance(field.get(key), str) and field[key]
        }
    if field_type == "autodate":
        return {
            "onCreate": field.get("onCreate") is not False,
            "onUpdate": field.get("onUpdate") is True,
        }
    if field_type == "number":
        result = {"mode": "int" if field.get("onlyInt") is True else "float"}
        for key in ("min", "max"):
            if (number := _optional_number(field.get(key))) is not None:
                result[key] = number
        return result
    if field_type in {"json", "file"}:
        result = {}
        maximum_limit = 2**32 - 1 if field_type == "json" else 2**64 - 1
        if maximum := _bounded_positive_int(
            field.get("maxSize"), 0, maximum_limit, f"field {field['name']} maxSize"
        ):
            result["maxSize"] = maximum
        if field_type == "json":
            return result
        result["maxSelect"] = _bounded_positive_int(
            field.get("maxSelect"), 1, 2**32 - 1, f"field {field['name']} maxSelect"
        )
        mime_types = field.get("mimeTypes")
        if isinstance(mime_types, list) and all(
            isinstance(item, str) for item in mime_types
        ):
            if mime_types:
                result["mimeTypes"] = mime_types
        return result
    if field_type == "select":
        values = field.get("values")
        if not isinstance(values, list) or not all(
            isinstance(item, str) for item in values
        ):
            raise PocketBaseError(f"select field {field['name']!r} has invalid values")
        return {
            "values": values,
            "maxSelect": _bounded_positive_int(
                field.get("maxSelect"), 1, 2**32 - 1, f"field {field['name']} maxSelect"
            ),
        }
    if field_type == "relation":
        raw_options = (
            field.get("options") if isinstance(field.get("options"), dict) else {}
        )
        target = field.get("collectionId") or raw_options.get("collectionId")
        result = {
            "targetCollectionId": collection_names[str(target)],
            "cascadeDelete": field.get("cascadeDelete") is True,
            "maxSelect": _bounded_positive_int(
                field.get("maxSelect"), 1, 2**32 - 1, f"field {field['name']} maxSelect"
            ),
        }
        if minimum := _bounded_positive_int(
            field.get("minSelect"), 0, 2**32 - 1, f"field {field['name']} minSelect"
        ):
            result["minSelect"] = minimum
        return result
    if field_type == "geoPoint":
        return {}
    raise PocketBaseError(f"unsupported field type during extraction: {field_type!r}")


def _field_findings(
    findings: list[Finding], collection_id: str, field_id: str
) -> list[Finding]:
    prefix = f"field.{collection_id}.{field_id}."
    return [finding for finding in findings if finding.id.startswith(prefix)]


def _map_field(
    field: dict[str, Any],
    collection: dict[str, Any],
    collection_names: dict[str, str],
    findings: list[Finding],
    decisions: dict[str, Decision],
    decisions_path: Path,
) -> dict[str, Any] | None:
    related = _field_findings(findings, str(collection["id"]), str(field["id"]))
    replacements: list[Any] = []
    mapped_to_date = False
    for finding in related:
        decision = decisions[finding.id]
        if decision.choice == "omit":
            return None
        if decision.choice == "date":
            mapped_to_date = True
        if decision.choice == "replacement":
            replacements.append(_replacement_value(decisions_path, decision, "field"))
    if replacements:
        if any(value != replacements[0] for value in replacements[1:]):
            raise PocketBaseError(
                f"field {collection['name']}.{field['name']} has conflicting replacement artifacts"
            )
        if not isinstance(replacements[0], dict):
            raise PocketBaseError("field replacement value must be an object")
        return replacements[0]

    field_type = (
        "date"
        if mapped_to_date
        else "json"
        if str(field["type"]) == "geoPoint"
        else str(field["type"])
    )
    return {
        "id": field["id"],
        "name": field["name"],
        "required": field.get("required") is True,
        "unique": False,
        "encrypted": False,
        "searchable": False,
        "hidden": field.get("hidden") is True,
        "type": field_type,
        "options": {} if mapped_to_date else _field_options(field, collection_names),
    }


def _map_rule(
    collection: dict[str, Any],
    key: str,
    decisions: dict[str, Decision],
    decisions_path: Path,
) -> str | None:
    rule = collection.get(key)
    collection_id = str(collection["id"])
    if rule == "":
        decision = decisions[_finding_id("rule", collection_id, key, "public")]
        if decision.choice != "public":
            raise PocketBaseError(
                f"public rule decision for {collection['name']}.{key} is invalid"
            )
        return "@public"
    replacement_id = _finding_id("rule", collection_id, key, "replacement")
    if replacement_id in decisions:
        value = _replacement_value(decisions_path, decisions[replacement_id], "rule")
        if value is not None and not isinstance(value, str):
            raise PocketBaseError("rule replacement value must be a string or null")
        return value
    return rule


def _auth_options(collection: dict[str, Any]) -> dict[str, Any]:
    password = collection.get("passwordAuth")
    password = password if isinstance(password, dict) else {}
    identities = password.get("identityFields", ["email"])
    if (
        not isinstance(identities, list)
        or not identities
        or not all(isinstance(item, str) for item in identities)
    ):
        raise PocketBaseError(
            f"auth collection {collection['name']!r} has invalid identityFields"
        )
    password_field = next(
        (
            field
            for field in collection.get("fields", [])
            if field.get("system") is True and field.get("type") == "password"
        ),
        None,
    )
    minimum = password_field.get("min", 8) if password_field is not None else 8
    if (
        not isinstance(minimum, int)
        or isinstance(minimum, bool)
        or not 1 <= minimum <= 255
    ):
        raise PocketBaseError(
            f"auth collection {collection['name']!r} has invalid minPasswordLength"
        )
    return {
        "auth": {
            "identityFields": identities,
            "minPasswordLength": minimum,
            "require_verified": _is_verified_auth_rule(collection.get("authRule")),
        }
    }


def _map_collection(
    collection: dict[str, Any],
    collection_names: dict[str, str],
    findings: list[Finding],
    decisions: dict[str, Decision],
    decisions_path: Path,
) -> dict[str, Any] | None:
    collection_id = str(collection["id"])
    system_id = _finding_id("collection", collection_id, "system")
    if system_id in decisions:
        return None
    for suffix in ("identifier", "view"):
        finding_id = _finding_id("collection", collection_id, suffix)
        if finding_id not in decisions:
            continue
        decision = decisions[finding_id]
        if decision.choice == "omit":
            return None
        value = _replacement_value(decisions_path, decision, "collection")
        if not isinstance(value, dict):
            raise PocketBaseError("collection replacement value must be an object")
        return value

    mapped_fields = [
        mapped
        for field in sorted(
            (
                field
                for field in collection.get("fields", [])
                if not field.get("system") and not _is_source_timestamp_field(field)
            ),
            key=lambda item: (str(item["name"]), str(item["id"])),
        )
        if (
            mapped := _map_field(
                field,
                collection,
                collection_names,
                findings,
                decisions,
                decisions_path,
            )
        )
        is not None
    ]
    field_names = {str(field["name"]) for field in collection.get("fields", [])}
    indexes: list[dict[str, Any]] = []
    for index in collection.get("indexes", []):
        if _is_pocketbase_auth_system_index(str(index), collection):
            continue
        parsed = _parse_simple_index(
            str(index),
            str(collection["name"]),
            field_names,
        )
        if parsed is not None:
            indexes.append(parsed)
            continue
        finding_id = _finding_id(
            "index",
            collection_id,
            hashlib.sha256(str(index).encode()).hexdigest()[:16],
            "replacement",
        )
        decision = decisions[finding_id]
        if decision.choice == "omit":
            continue
        value = _replacement_value(decisions_path, decision, "index")
        if not isinstance(value, dict):
            raise PocketBaseError("index replacement value must be an object")
        indexes.append(value)
    kind = str(collection.get("type") or "base")
    return {
        "name": collection["name"],
        "type": kind,
        "fields": mapped_fields,
        "indexes": sorted(indexes, key=lambda item: str(item.get("name", ""))),
        "listRule": _map_rule(collection, "listRule", decisions, decisions_path),
        "viewRule": _map_rule(collection, "viewRule", decisions, decisions_path),
        "createRule": _map_rule(collection, "createRule", decisions, decisions_path),
        "updateRule": _map_rule(collection, "updateRule", decisions, decisions_path),
        "deleteRule": _map_rule(collection, "deleteRule", decisions, decisions_path),
        "options": _auth_options(collection) if kind == "auth" else {},
    }


def build_schema(
    collections: list[dict[str, Any]],
    findings: list[Finding],
    decisions: tuple[Decision, ...],
    decisions_path: Path,
) -> dict[str, Any]:
    collection_names = {str(item["id"]): str(item["name"]) for item in collections}
    by_id = _decision_map(decisions)
    mapped = [
        result
        for collection in sorted(
            collections, key=lambda item: (str(item["name"]), str(item["id"]))
        )
        if (
            result := _map_collection(
                collection, collection_names, findings, by_id, decisions_path
            )
        )
        is not None
    ]
    result = {"zigbaseSchema": 1, "collections": mapped}
    _validate_target_schema_links(result)
    return result


def _validate_target_schema_links(document: dict[str, Any]) -> None:
    collections = document["collections"]
    names = [collection.get("name") for collection in collections]
    if not all(isinstance(name, str) and IDENTIFIER.fullmatch(name) for name in names):
        raise PocketBaseError("target schema contains an invalid collection name")
    if len(set(names)) != len(names):
        raise PocketBaseError("target schema contains duplicate collection names")
    name_set = set(names)
    for collection in collections:
        fields = collection.get("fields")
        indexes = collection.get("indexes")
        if not isinstance(fields, list) or not isinstance(indexes, list):
            raise PocketBaseError(
                "target schema collection fields/indexes must be arrays"
            )
        field_names = [field.get("name") for field in fields if isinstance(field, dict)]
        if (
            len(field_names) != len(fields)
            or not all(
                isinstance(field_name, str) and IDENTIFIER.fullmatch(field_name)
                for field_name in field_names
            )
            or len(set(field_names)) != len(field_names)
            or any(
                field_name.casefold() in RESERVED_FIELD_NAMES
                for field_name in field_names
                if isinstance(field_name, str)
            )
        ):
            raise PocketBaseError(
                f"target collection {collection['name']!r} has invalid or duplicate fields"
            )
        for field in fields:
            if field.get("type") != "relation":
                continue
            options = field.get("options")
            target = (
                options.get("targetCollectionId") if isinstance(options, dict) else None
            )
            if target not in name_set:
                raise PocketBaseError(
                    f"target relation {collection['name']}.{field.get('name')} points to an omitted/unknown collection"
                )
        for index in indexes:
            index_fields = index.get("fields") if isinstance(index, dict) else None
            if not isinstance(index_fields, list) or not all(
                field in field_names for field in index_fields
            ):
                raise PocketBaseError(
                    f"target collection {collection['name']!r} has an index over an omitted/unknown field"
                )


def _quote_identifier(name: str) -> str:
    """The only helper allowed to place an exported identifier into SQLite SQL."""
    return '"' + name.replace('"', '""') + '"'


def _decode_json_storage(value: Any, label: str) -> Any:
    if value is None:
        return None
    if not isinstance(value, str):
        raise PocketBaseError(f"{label} is not JSON text in the PocketBase snapshot")
    try:
        return json.loads(value)
    except json.JSONDecodeError as exc:
        raise PocketBaseError(f"{label} contains invalid JSON") from exc


def _convert_value(field: dict[str, Any], mapped: dict[str, Any], value: Any) -> Any:
    if value is None:
        return None
    field_type = str(field["type"])
    label = str(field["name"])
    if (
        value == ""
        and field_type in {"select", "relation"}
        and _positive_int(field.get("maxSelect"), 1) == 1
        and field.get("required") is not True
    ):
        return None
    if field_type == "bool":
        if value not in (0, 1, False, True):
            raise PocketBaseError(
                f"field {label!r} contains a non-boolean SQLite value"
            )
        return bool(value)
    if field_type == "number":
        if not isinstance(value, (int, float)) or isinstance(value, bool):
            raise PocketBaseError(f"field {label!r} contains a non-number SQLite value")
        return value
    if field_type in {"json", "geoPoint"}:
        return _decode_json_storage(value, f"field {label!r}")
    if (
        field_type in {"select", "relation", "file"}
        and _positive_int(field.get("maxSelect"), 1) > 1
    ):
        decoded = _decode_json_storage(value, f"field {label!r}")
        if not isinstance(decoded, list):
            raise PocketBaseError(f"multi-value field {label!r} is not a JSON array")
        return decoded
    if field_type not in DIRECT_FIELD_TYPES and field_type != "geoPoint":
        raise PocketBaseError(
            f"field {label!r} needs an external row-value transform before extraction"
        )
    if not isinstance(value, str):
        raise PocketBaseError(f"field {label!r} contains a non-string SQLite value")
    return value


def _validate_stored_filename(filename: Any, label: str) -> str:
    if (
        not isinstance(filename, str)
        or not filename
        or filename in {".", ".."}
        or "/" in filename
        or "\\" in filename
        or "\x00" in filename
        or Path(filename).is_absolute()
    ):
        raise PocketBaseError(f"{label} contains an unsafe stored filename")
    return filename


def _record_file_references(
    source_field: dict[str, Any],
    value: Any,
    source_collection_id: str,
    target_collection: str,
    record_id: str,
) -> list[FileReference]:
    if source_field["type"] != "file" or value is None or value == "":
        return []
    values = value if isinstance(value, list) else [value]
    return [
        FileReference(
            source_collection_id,
            target_collection,
            record_id,
            _validate_stored_filename(
                filename, f"file field {target_collection}.{source_field['name']}"
            ),
        )
        for filename in values
    ]


def _source_to_target_fields(
    collection: dict[str, Any],
    collection_names: dict[str, str],
    findings: list[Finding],
    decisions: dict[str, Decision],
    decisions_path: Path,
) -> list[tuple[dict[str, Any], dict[str, Any]]]:
    pairs: list[tuple[dict[str, Any], dict[str, Any]]] = []
    for field in collection.get("fields", []):
        if field.get("system") or _is_source_timestamp_field(field):
            continue
        mapped = _map_field(
            field, collection, collection_names, findings, decisions, decisions_path
        )
        if mapped is not None:
            pairs.append((field, mapped))
    return pairs


def _row_query(
    collection: dict[str, Any], source_fields: list[dict[str, Any]], columns: set[str]
) -> tuple[str, list[str]]:
    selected = [name for name in ("id", "created", "updated") if name in columns]
    if (collection.get("type") or "base") == "auth":
        selected.extend(
            BCRYPT_DIGEST_COLUMN if name == "password" else name
            for name in ("email", "username", "verified", "password")
            if name in columns
        )
    selected.extend(str(field["name"]) for field in source_fields)
    selected = list(dict.fromkeys(selected))
    sql = (
        "SELECT "
        + ",".join(
            (
                _quote_identifier("password")
                + " AS "
                + _quote_identifier(BCRYPT_DIGEST_COLUMN)
                if name == BCRYPT_DIGEST_COLUMN
                else _quote_identifier(name)
            )
            for name in selected
        )
        + " FROM "
        + _quote_identifier(str(collection["name"]))
        + ' ORDER BY "id"'
    )
    return sql, selected


def _write_ndjson_rows(
    connection: sqlite3.Connection,
    destination: Path,
    collection: dict[str, Any],
    target_collection: str,
    field_pairs: list[tuple[dict[str, Any], dict[str, Any]]],
) -> tuple[int, list[FileReference]]:
    columns = _table_columns(connection, str(collection["name"]))
    query, selected = _row_query(collection, [pair[0] for pair in field_pairs], columns)
    try:
        cursor = connection.execute(query)
        destination.parent.mkdir(parents=True, exist_ok=True)
        count = 0
        file_references: list[FileReference] = []
        with destination.open("w", encoding="utf-8", newline="\n") as output:
            for raw_values in cursor:
                raw = dict(zip(selected, raw_values, strict=True))
                record_id = raw.get("id")
                if not isinstance(record_id, str) or not POCKETBASE_ID.fullmatch(
                    record_id
                ):
                    raise PocketBaseError(
                        f"collection {collection['name']!r} has an invalid record id"
                    )
                record: dict[str, Any] = {"id": record_id}
                for timestamp in ("created", "updated"):
                    value = raw.get(timestamp)
                    if value is not None:
                        if not isinstance(value, str) or not value:
                            raise PocketBaseError(
                                f"record {collection['name']}.{record_id} has an invalid source {timestamp} timestamp"
                            )
                        record[timestamp] = value
                if (collection.get("type") or "base") == "auth":
                    password_hash = raw.get(BCRYPT_DIGEST_COLUMN)
                    if not isinstance(password_hash, str) or not BCRYPT.fullmatch(
                        password_hash
                    ):
                        raise PocketBaseError(
                            f"auth record {collection['name']}.{record_id} has no supported bcrypt credential"
                        )
                    record["passwordHash"] = password_hash
                    if isinstance(raw.get("email"), str):
                        record["email"] = raw["email"]
                    if isinstance(raw.get("username"), str) and raw["username"]:
                        record["username"] = raw["username"]
                    record["verified"] = bool(raw.get("verified"))
                for source_field, mapped_field in field_pairs:
                    converted = _convert_value(
                        source_field, mapped_field, raw.get(str(source_field["name"]))
                    )
                    record[str(mapped_field["name"])] = converted
                    file_references.extend(
                        _record_file_references(
                            source_field,
                            converted,
                            str(collection["id"]),
                            target_collection,
                            record_id,
                        )
                    )
                line = json.dumps(
                    record, ensure_ascii=False, sort_keys=True, separators=(",", ":")
                )
                if len(line.encode()) > MAX_NDJSON_LINE_BYTES:
                    raise PocketBaseError(
                        f"record {collection['name']}.{record_id} exceeds the ZigBase NDJSON line limit"
                    )
                output.write(line + "\n")
                count += 1
    except (OSError, sqlite3.Error) as exc:
        raise PocketBaseError(
            f"cannot extract rows for collection {collection['name']!r}: {exc}"
        ) from exc
    return count, file_references


def _canonical_decisions(
    decisions: tuple[Decision, ...], bundled_artifacts: dict[str, str]
) -> dict[str, Any]:
    values: list[dict[str, Any]] = []
    for decision in sorted(decisions, key=lambda item: item.id):
        value = {
            "id": decision.id,
            "choice": decision.choice,
            "rationale": decision.rationale,
        }
        if decision.artifact:
            value["artifact"] = bundled_artifacts[decision.id]
        values.append(value)
    return {
        "zigbasePocketBaseDecisions": DECISIONS_VERSION,
        "sourceVersion": SOURCE_VERSION,
        "decisions": values,
    }


def _write_canonical_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, indent=2, ensure_ascii=False, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def _output_entries(root: Path) -> list[dict[str, Any]]:
    entries: list[dict[str, Any]] = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        if path.name == "zigbase-pocketbase-bundle.json":
            continue
        entries.append(
            {
                "path": path.relative_to(root).as_posix(),
                "bytes": path.stat().st_size,
                "sha256": _sha256(path),
            }
        )
    return entries


def _copy_replacement_artifacts(
    stage: Path, decisions_path: Path, decisions: tuple[Decision, ...]
) -> list[dict[str, Any]]:
    copied: list[dict[str, Any]] = []
    for decision in sorted(decisions, key=lambda item: item.id):
        if not decision.artifact:
            continue
        source = _safe_artifact_path(decisions_path, decision)
        digest = _sha256(source)
        safe_name = re.sub(r"[^A-Za-z0-9_.-]", "_", source.name)
        relative = Path("replacements") / f"{digest[:16]}-{safe_name}"
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target, follow_symlinks=False)
        copied.append(
            {"finding": decision.id, "path": relative.as_posix(), "sha256": digest}
        )
    return copied


def _scan_regular_tree(root: Path, label: str) -> set[Path]:
    if not root.exists():
        return set()
    if root.is_symlink() or not root.is_dir():
        raise PocketBaseError(f"{label} must be a real directory, not a symbolic link")
    files: set[Path] = set()

    def visit(directory: Path, relative: Path) -> None:
        try:
            children = sorted(directory.iterdir(), key=lambda item: item.name)
        except OSError as exc:
            raise PocketBaseError(f"cannot inspect {label}: {exc}") from exc
        for child in children:
            child_relative = relative / child.name
            if child.is_symlink():
                raise PocketBaseError(
                    f"{label} contains a symbolic link: {child_relative.as_posix()}"
                )
            if child.is_dir():
                visit(child, child_relative)
            elif child.is_file():
                files.add(child_relative)
            else:
                raise PocketBaseError(
                    f"{label} contains a non-regular object: {child_relative.as_posix()}"
                )

    visit(root, Path())
    return files


def _copy_file_bytes(source: Path, destination: Path) -> tuple[int, str]:
    destination.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    size = 0
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(source, flags)
        with os.fdopen(descriptor, "rb") as input_file:
            with destination.open("xb") as output_file:
                while chunk := input_file.read(1024 * 1024):
                    output_file.write(chunk)
                    digest.update(chunk)
                    size += len(chunk)
    except OSError as exc:
        raise PocketBaseError(f"cannot copy PocketBase file {source}: {exc}") from exc
    return size, digest.hexdigest()


def _stage_referenced_files(
    stage: Path, pb_data: Path, references: list[FileReference]
) -> tuple[list[dict[str, Any]], list[str]]:
    storage = pb_data / "storage"
    available = _scan_regular_tree(storage, "PocketBase storage")
    referenced_sources: set[Path] = set()
    destinations: dict[Path, Path] = {}
    staged_destinations: set[Path] = set()
    entries: list[dict[str, Any]] = []
    for reference in sorted(set(references)):
        source_relative = (
            Path(reference.source_collection_id)
            / reference.record_id
            / reference.filename
        )
        if source_relative not in available:
            raise PocketBaseError(
                f"referenced PocketBase file is missing: {source_relative.as_posix()}"
            )
        destination_relative = (
            Path("storage")
            / reference.target_collection
            / reference.record_id
            / reference.filename
        )
        previous = destinations.setdefault(destination_relative, source_relative)
        if previous != source_relative:
            raise PocketBaseError(
                f"multiple PocketBase files map to {destination_relative.as_posix()}"
            )
        if destination_relative in staged_destinations:
            continue
        referenced_sources.add(source_relative)
        staged_destinations.add(destination_relative)
        size, digest = _copy_file_bytes(
            storage / source_relative, stage / destination_relative
        )
        entries.append(
            {
                "sourcePath": source_relative.as_posix(),
                "path": destination_relative.as_posix(),
                "bytes": size,
                "sha256": digest,
            }
        )
    unreferenced = sorted(
        path.as_posix() for path in available.difference(referenced_sources)
    )
    return entries, unreferenced


def _prepare_output_directory(out: Path) -> None:
    if out.exists():
        if not out.is_dir() or any(out.iterdir()):
            raise PocketBaseError(
                f"bundle output must not exist or must be an empty directory: {out}"
            )
    out.parent.mkdir(parents=True, exist_ok=True)


def _extract_bundle_from_snapshot(
    schema_path: Path,
    pb_data: Path,
    decisions_path: Path,
    out: Path,
    connection: sqlite3.Connection,
    database: Path,
) -> dict[str, Any]:
    _ensure_output_outside_sources(out, schema_path, pb_data)
    if out.resolve() == decisions_path.resolve():
        raise PocketBaseError("bundle output must not overwrite the decisions document")
    _prepare_output_directory(out)
    collections = load_schema(schema_path)
    inventory = _build_inventory(
        schema_path, pb_data, collections, connection, database
    )
    findings = [
        Finding(
            value["id"],
            value["severity"],
            value["code"],
            value["message"],
            tuple(value.get("choices", [])),
            bool(value.get("requiresArtifact")),
        )
        for value in inventory["findings"]
    ]
    _, decisions = load_decisions(decisions_path)
    reconcile_decisions(findings, decisions)
    target_schema = build_schema(collections, findings, decisions, decisions_path)
    decision_by_id = _decision_map(decisions)
    collection_names = {str(item["id"]): str(item["name"]) for item in collections}

    stage_path = Path(tempfile.mkdtemp(prefix=".pb2zb-", dir=out.parent))
    try:
        _write_canonical_json(stage_path / "inventory.json", inventory)
        _write_canonical_json(stage_path / "schema.json", target_schema)
        replacements = _copy_replacement_artifacts(
            stage_path, decisions_path, decisions
        )
        _write_canonical_json(
            stage_path / "decisions.json",
            _canonical_decisions(
                decisions, {entry["finding"]: entry["path"] for entry in replacements}
            ),
        )

        row_counts: dict[str, int] = {}
        auth_imports: list[dict[str, Any]] = []
        ordinary_entries: list[dict[str, Any]] = []
        file_references: list[FileReference] = []
        for collection in sorted(
            collections, key=lambda item: (str(item["name"]), str(item["id"]))
        ):
            target = _map_collection(
                collection,
                collection_names,
                findings,
                decision_by_id,
                decisions_path,
            )
            if target is None:
                continue
            pairs = _source_to_target_fields(
                collection,
                collection_names,
                findings,
                decision_by_id,
                decisions_path,
            )
            name = str(target["name"])
            is_auth = (collection.get("type") or "base") == "auth"
            relative = (
                Path("imports") / "auth" / f"{name}.ndjson"
                if is_auth
                else Path("imports") / f"{name}.ndjson"
            )
            count, collection_file_references = _write_ndjson_rows(
                connection,
                stage_path / relative,
                collection,
                name,
                pairs,
            )
            file_references.extend(collection_file_references)
            row_counts[name] = count
            if is_auth:
                auth_imports.append(
                    {"collection": name, "file": relative.as_posix(), "rows": count}
                )
            else:
                ordinary_entries.append({"collection": name, "file": f"{name}.ndjson"})
        storage_files, unreferenced_storage = _stage_referenced_files(
            stage_path, pb_data, file_references
        )
        manifest = {
            "zigbaseImportManifest": 1,
            "collections": ordinary_entries,
        }
        _write_canonical_json(stage_path / "imports" / "manifest.json", manifest)
        if inventory["schemaSha256"] != _sha256(schema_path) or inventory[
            "databaseSha256"
        ] != _sha256(database):
            raise PocketBaseError(
                "PocketBase source changed during extraction; retry from a stopped snapshot"
            )
        root_manifest = {
            "zigbasePocketBaseBundle": 1,
            "sourceVersion": SOURCE_VERSION,
            "schemaSha256": inventory["schemaSha256"],
            "databaseSha256": inventory["databaseSha256"],
            "decisionsSha256": _sha256(decisions_path),
            "collections": len(target_schema["collections"]),
            "rows": sum(row_counts.values()),
            "rowCounts": dict(sorted(row_counts.items())),
            "authImports": auth_imports,
            "ordinaryManifest": "imports/manifest.json",
            "files": len(storage_files),
            "storageFiles": storage_files,
            "unreferencedStorage": unreferenced_storage,
            "replacementArtifacts": replacements,
            "outputs": _output_entries(stage_path),
        }
        _write_canonical_json(
            stage_path / "zigbase-pocketbase-bundle.json", root_manifest
        )
        if out.exists():
            out.rmdir()
        stage_path.replace(out)
    except Exception:
        shutil.rmtree(stage_path, ignore_errors=True)
        raise
    return root_manifest


def extract_bundle(
    schema_path: Path, pb_data: Path, decisions_path: Path, out: Path
) -> dict[str, Any]:
    connection, database = _open_snapshot(pb_data)
    try:
        return _extract_bundle_from_snapshot(
            schema_path, pb_data, decisions_path, out, connection, database
        )
    finally:
        connection.close()


def verify_bundle(bundle: Path) -> dict[str, Any]:
    manifest_path = bundle / "zigbase-pocketbase-bundle.json"
    if bundle.is_symlink() or manifest_path.is_symlink():
        raise PocketBaseError(
            "PocketBase bundle and its manifest must not be symbolic links"
        )
    value = _read_json(
        manifest_path, limit=MAX_SCHEMA_BYTES, label="PocketBase bundle manifest"
    )
    if not isinstance(value, dict) or value.get("zigbasePocketBaseBundle") != 1:
        raise PocketBaseError("unsupported or invalid PocketBase bundle manifest")
    outputs = value.get("outputs")
    if not isinstance(outputs, list):
        raise PocketBaseError("PocketBase bundle manifest outputs must be an array")
    expected: set[str] = set()
    root = bundle.resolve(strict=True)
    for index, entry in enumerate(outputs):
        if not isinstance(entry, dict) or set(entry) != {"path", "bytes", "sha256"}:
            raise PocketBaseError(f"bundle output entry {index} has an invalid shape")
        relative = entry["path"]
        if not isinstance(relative, str) or not relative:
            raise PocketBaseError(f"bundle output entry {index} has an invalid path")
        path = Path(relative)
        if (
            path.is_absolute()
            or ".." in path.parts
            or "\\" in relative
            or "\x00" in relative
        ):
            raise PocketBaseError(f"bundle output entry {index} has an unsafe path")
        if relative in expected:
            raise PocketBaseError(f"bundle output path is duplicated: {relative}")
        expected.add(relative)
        target = (root / path).resolve()
        if (
            not target.is_relative_to(root)
            or not target.is_file()
            or _path_contains_symlink(root, path)
        ):
            raise PocketBaseError(f"bundle output is missing or unsafe: {relative}")
        if (
            target.stat().st_size != entry["bytes"]
            or _sha256(target) != entry["sha256"]
        ):
            raise PocketBaseError(f"bundle output digest mismatch: {relative}")
    actual = {
        path.as_posix()
        for path in _scan_regular_tree(bundle, "PocketBase bundle")
        if path.as_posix() != "zigbase-pocketbase-bundle.json"
    }
    if actual != expected:
        raise PocketBaseError("bundle contains missing or unmanifested files")
    return value


def _unsafe_relative_path(relative: str) -> bool:
    path = Path(relative)
    return (
        not relative
        or path.is_absolute()
        or ".." in path.parts
        or "\\" in relative
        or "\x00" in relative
    )


def _absolute_path_contains_symlink(path: Path) -> bool:
    absolute = path.absolute()
    current = Path(absolute.anchor)
    for part in absolute.parts[1:]:
        current = current / part
        if current.is_symlink():
            return True
    return False


def _file_install_plan(
    bundle: Path, target_data_dir: Path, manifest: dict[str, Any]
) -> list[tuple[Path, Path, int, str, bool]]:
    storage_files = manifest.get("storageFiles")
    if not isinstance(storage_files, list):
        raise PocketBaseError("PocketBase bundle storageFiles must be an array")
    outputs = {
        entry["path"]: entry
        for entry in manifest["outputs"]
        if isinstance(entry, dict) and isinstance(entry.get("path"), str)
    }
    bundle_root = bundle.resolve(strict=True)
    target_absolute = target_data_dir.absolute()
    if _absolute_path_contains_symlink(target_absolute):
        raise PocketBaseError("target data directory path contains a symbolic link")
    target_resolved = target_absolute.resolve()
    if target_resolved.is_relative_to(bundle_root) or bundle_root.is_relative_to(
        target_resolved
    ):
        raise PocketBaseError("target data directory must not overlap the bundle")

    plan: list[tuple[Path, Path, int, str, bool]] = []
    destinations: set[Path] = set()
    for index, entry in enumerate(storage_files):
        if not isinstance(entry, dict) or set(entry) != {
            "sourcePath",
            "path",
            "bytes",
            "sha256",
        }:
            raise PocketBaseError(f"storage file entry {index} has an invalid shape")
        relative = entry["path"]
        size = entry["bytes"]
        digest = entry["sha256"]
        if not isinstance(relative, str) or _unsafe_relative_path(relative):
            raise PocketBaseError(f"storage file entry {index} has an unsafe path")
        path = Path(relative)
        if (
            len(path.parts) != 4
            or path.parts[0] != "storage"
            or not IDENTIFIER.fullmatch(path.parts[1])
            or not POCKETBASE_ID.fullmatch(path.parts[2])
        ):
            raise PocketBaseError(f"storage file entry {index} has an unsafe path")
        _validate_stored_filename(path.parts[3], f"storage file entry {index}")
        if (
            not isinstance(size, int)
            or isinstance(size, bool)
            or size < 0
            or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest) is None
        ):
            raise PocketBaseError(f"storage file entry {index} has invalid metadata")
        output = outputs.get(relative)
        if (
            output is None
            or output.get("bytes") != size
            or output.get("sha256") != digest
        ):
            raise PocketBaseError(
                f"storage file entry {index} does not match the verified bundle outputs"
            )
        source = bundle_root / path
        destination = target_resolved / path
        if destination in destinations:
            raise PocketBaseError(
                f"duplicate file installation destination: {relative}"
            )
        destinations.add(destination)
        if _absolute_path_contains_symlink(destination):
            raise PocketBaseError(f"target path contains a symbolic link: {relative}")
        current = target_resolved
        for part in path.parts[:-1]:
            current = current / part
            if current.exists() and not current.is_dir():
                raise PocketBaseError(
                    f"target directory path is not a directory: {current}"
                )
        exists = destination.exists()
        if exists:
            if not destination.is_file() or _sha256(destination) != digest:
                raise PocketBaseError(
                    f"different file already exists at target: {relative}"
                )
            if destination.stat().st_size != size:
                raise PocketBaseError(
                    f"different file already exists at target: {relative}"
                )
        plan.append((source, destination, size, digest, exists))
    return plan


def _mkdir_restrictive(path: Path) -> None:
    missing: list[Path] = []
    current = path
    while not current.exists():
        missing.append(current)
        current = current.parent
    if current.is_symlink() or not current.is_dir():
        raise PocketBaseError(f"cannot create target directory beneath {current}")
    for directory in reversed(missing):
        try:
            directory.mkdir(mode=0o700)
        except FileExistsError:
            if directory.is_symlink() or not directory.is_dir():
                raise PocketBaseError(f"unsafe target directory appeared: {directory}")


def _install_file_atomic(source: Path, destination: Path, digest: str) -> bool:
    _mkdir_restrictive(destination.parent)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".pb2zb-", dir=destination.parent
    )
    temporary = Path(temporary_name)
    descriptor_open = True
    try:
        os.fchmod(descriptor, 0o600)
        copied_digest = hashlib.sha256()
        source_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        source_descriptor = os.open(source, source_flags)
        with os.fdopen(source_descriptor, "rb") as input_file:
            with os.fdopen(descriptor, "wb") as output_file:
                descriptor_open = False
                while chunk := input_file.read(1024 * 1024):
                    output_file.write(chunk)
                    copied_digest.update(chunk)
                output_file.flush()
                os.fsync(output_file.fileno())
        if copied_digest.hexdigest() != digest:
            raise PocketBaseError("bundle file changed while it was being installed")
        try:
            os.link(temporary, destination, follow_symlinks=False)
            return True
        except FileExistsError:
            if destination.is_symlink() or not destination.is_file():
                raise PocketBaseError(f"unsafe target appeared: {destination}")
            if _sha256(destination) != digest:
                raise PocketBaseError(
                    f"different file appeared at target: {destination}"
                )
            return False
    except OSError as exc:
        raise PocketBaseError(f"cannot install file at {destination}: {exc}") from exc
    finally:
        if descriptor_open:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def install_files(bundle: Path, target_data_dir: Path) -> dict[str, int]:
    manifest = verify_bundle(bundle)
    plan = _file_install_plan(bundle, target_data_dir, manifest)
    installed = 0
    reused = 0
    for source, destination, _size, digest, exists in plan:
        if exists:
            reused += 1
        elif _install_file_atomic(source, destination, digest):
            installed += 1
        else:
            reused += 1
    return {"files": len(plan), "installed": installed, "reused": reused}


def _write_json(path: Path, value: Any) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    except OSError as exc:
        raise PocketBaseError(f"cannot write {path}: {exc}") from exc


def _ensure_output_outside_sources(out: Path, schema: Path, pb_data: Path) -> None:
    """Refuse an output that could overwrite any part of the source snapshot."""
    try:
        resolved_out = out.resolve()
        resolved_schema = schema.resolve(strict=True)
        resolved_data = pb_data.resolve(strict=True)
    except OSError as exc:
        raise PocketBaseError(f"cannot resolve inventory paths safely: {exc}") from exc
    if resolved_out == resolved_schema or resolved_out.is_relative_to(resolved_data):
        raise PocketBaseError(
            "inventory output must be outside the source schema and pb_data tree"
        )


def cmd_inventory(args: argparse.Namespace) -> int:
    _ensure_output_outside_sources(args.out, args.schema, args.pb_data)
    inventory = build_inventory(args.schema, args.pb_data)
    _write_json(args.out, inventory)
    summary = inventory["summary"]
    print(
        json.dumps(
            {
                "zigbase_pocketbase_inventory": INVENTORY_VERSION,
                "out": str(args.out),
                "collections": summary["collections"],
                "decisions": summary["decisions"],
                "blockers": summary["blockers"],
            },
            separators=(",", ":"),
        )
    )
    return 2 if summary["decisions"] or summary["blockers"] else 0


def cmd_extract(args: argparse.Namespace) -> int:
    manifest = extract_bundle(args.schema, args.pb_data, args.decisions, args.out)
    print(
        json.dumps(
            {
                "zigbase_pocketbase_bundle": 1,
                "out": str(args.out),
                "collections": manifest["collections"],
                "rows": manifest["rows"],
                "files": manifest["files"],
            },
            separators=(",", ":"),
        )
    )
    return 0


def cmd_install_files(args: argparse.Namespace) -> int:
    result = install_files(args.bundle, args.target_data_dir)
    print(
        json.dumps(
            {"zigbase_pocketbase_file_install": 1, **result}, separators=(",", ":")
        )
    )
    return 0


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    commands = root.add_subparsers(dest="command", required=True)
    inventory = commands.add_parser(
        "inventory", help="inventory an offline PocketBase snapshot"
    )
    inventory.add_argument("--schema", type=Path, required=True)
    inventory.add_argument("--pb-data", type=Path, required=True)
    inventory.add_argument("--out", type=Path, required=True)
    inventory.set_defaults(handler=cmd_inventory)
    extract = commands.add_parser(
        "extract", help="extract a reviewed ZigBase migration bundle"
    )
    extract.add_argument("--schema", type=Path, required=True)
    extract.add_argument("--pb-data", type=Path, required=True)
    extract.add_argument("--decisions", type=Path, required=True)
    extract.add_argument("--out", type=Path, required=True)
    extract.set_defaults(handler=cmd_extract)
    install = commands.add_parser(
        "install-files", help="install verified bundle files into a ZigBase data dir"
    )
    install.add_argument("--bundle", type=Path, required=True)
    install.add_argument("--target-data-dir", type=Path, required=True)
    install.set_defaults(handler=cmd_install_files)
    return root


def main(argv: list[str] | None = None) -> int:
    try:
        args = parser().parse_args(argv)
        return int(args.handler(args))
    except (PocketBaseError, OSError, sqlite3.Error) as exc:
        print(f"pb2zb: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
