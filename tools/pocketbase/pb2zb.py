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
import re
import sqlite3
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SOURCE_VERSION = "0.39.11"
INVENTORY_VERSION = 1
DECISIONS_VERSION = 1
MAX_SCHEMA_BYTES = 32 * 1024 * 1024
MAX_COLLECTIONS = 10_000
MAX_FIELDS_PER_COLLECTION = 10_000

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
    r'^CREATE\s+(?:(UNIQUE)\s+)?INDEX\s+"?[A-Za-z][A-Za-z0-9_]*"?\s+'
    r'ON\s+"?([A-Za-z][A-Za-z0-9_]*)"?\s*\(([^)]+)\)\s*$',
    re.IGNORECASE,
)
SIMPLE_INDEX_FIELD = re.compile(
    r'^"?([A-Za-z][A-Za-z0-9_]*)"?(?:\s+(?:ASC|DESC))?$', re.IGNORECASE
)
RULE_KEYS = (
    "listRule",
    "viewRule",
    "createRule",
    "updateRule",
    "deleteRule",
    "manageRule",
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
    for suffix in ("-wal", "-shm"):
        sidecar = Path(f"{database}{suffix}")
        if sidecar.exists():
            raise PocketBaseError(
                f"snapshot has SQLite sidecar {sidecar.name}; stop PocketBase and make a consistent backup"
            )
    try:
        connection = sqlite3.connect(f"file:{database.resolve()}?mode=ro", uri=True)
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
        expected_columns = {"id", "created", "updated"}
        expected_columns.update(
            str(field["name"])
            for field in collection.get("fields", [])
            if not bool(field.get("system"))
        )
        if (collection.get("type") or "base") == "auth":
            expected_columns.update(
                {"email", "emailVisibility", "verified", "passwordHash", "tokenKey"}
            )
        missing = sorted(expected_columns - columns)
        if missing:
            raise PocketBaseError(
                f"snapshot table {name!r} is missing exported columns: {', '.join(missing)}"
            )


def _rule_requires_replacement(rule: str) -> bool:
    return "@collection." in rule or "_via_" in rule or "@request.context" in rule


def _simple_index(index: str, collection_name: str, fields: set[str]) -> bool:
    match = SIMPLE_INDEX.fullmatch(index.strip().rstrip(";"))
    if not match or match.group(2) != collection_name:
        return False
    parts = [part.strip() for part in match.group(3).split(",")]
    if not parts:
        return False
    parsed = [SIMPLE_INDEX_FIELD.fullmatch(part) for part in parts]
    return all(match is not None and match.group(1) in fields for match in parsed)


def _finding_id(*parts: str) -> str:
    return ".".join(part.replace(".", "_") for part in parts)


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

        for field in fields:
            field_id = str(field["id"])
            field_name = str(field["name"])
            field_type = str(field["type"])
            if bool(field.get("system")):
                continue
            if field_type == "file":
                has_file_fields = True
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
            if not IDENTIFIER.fullmatch(field_name):
                findings.append(
                    Finding(
                        _finding_id("field", collection_id, field_id, "identifier"),
                        "blocker",
                        "FieldIdentifierRequiresReplacement",
                        f"Field {name}.{field_name} is not a valid ZigBase identifier.",
                        ("replacement", "omit"),
                        True,
                    )
                )

        for key in RULE_KEYS:
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
            if not _simple_index(
                str(index), name, field_names | {"id", "created", "updated"}
            ):
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
        if finding.requires_artifact and not decision.artifact:
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


def build_inventory(schema_path: Path, pb_data: Path) -> dict[str, Any]:
    collections = load_schema(schema_path)
    connection, database = _open_snapshot(pb_data)
    try:
        _check_snapshot_shape(connection, collections)
    finally:
        connection.close()
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
    return root


def main(argv: list[str] | None = None) -> int:
    try:
        args = parser().parse_args(argv)
        return int(args.handler(args))
    except PocketBaseError as exc:
        print(f"pb2zb: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
