#!/usr/bin/env python3
"""rails2zb — offline Rails-to-ZigBase migration converter.

Three subcommands, in the order they must be run:

    inventory     enumerate findings from a frozen source; exit 2 == judgment required
    extract       emit a deterministic bundle once every finding has a decision
    install-files place Active Storage blobs into a ZigBase data directory

The converter never parses Ruby and never boots the application. It consumes the frozen
source bundle produced by ``export_source.rb`` (observed) or by the documented static
fallback (inferred), and refuses to treat the two as interchangeable.
"""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import math
import re
import string
import sqlite3
import sys
from dataclasses import dataclass
from dataclasses import field as dataclass_field
from pathlib import Path
from typing import Any

if __package__ in (None, ""):  # direct `python3 tools/rails/rails2zb.py`
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.rails._core import (  # noqa: E402
    Decision,
    Finding,
    INFERRED,
    OBSERVED,
    RailsError,
    _private_parent,
    compact_summary,
    ensure_output_outside_source,
    finding_id,
    install_file_atomic,
    read_bytes,
    read_json,
    required_string,
    sha256_file,
    split_id,
    validate_inventory_source,
    write_canonical_json,
    write_ndjson,
)

INVENTORY_VERSION = 1
DECISIONS_VERSION = 1
BUNDLE_VERSION = 1

INVENTORY_FILES = (
    "routes",
    "models",
    "schema",
    "storage",
    "jobs",
    "counts",
    "auth",
    "versions",
)

# Rails owns these tables; they are never ordinary collections in the target.
RAILS_INTERNAL_TABLES = frozenset(
    {
        "schema_migrations",
        "ar_internal_metadata",
        "active_storage_blobs",
        "active_storage_attachments",
        "active_storage_variant_records",
        "action_text_rich_texts",
        "action_mailbox_inbound_emails",
    }
)

# A bcrypt digest, and nothing else. Matching this does NOT make a digest importable:
# Devise mixes a configured pepper into the plaintext before hashing, so a peppered
# digest matches here and still fails every login. See `_credential_findings`.
BCRYPT = re.compile(r"^\$2[aby]\$\d\d\$[./A-Za-z0-9]{53}$")

# Rails column type -> ZigBase field type. Anything absent becomes a finding, not a guess.
TYPE_MAP = {
    "string": "text",
    "text": "text",
    "integer": "number",
    "bigint": "number",
    "float": "number",
    "decimal": "number",
    "boolean": "bool",
    "datetime": "date",
    "date": "date",
    "timestamp": "date",
    "json": "json",
    "jsonb": "json",
    "uuid": "text",
}

# `ActiveModel::Type::Boolean::FALSE_VALUES`, the string members, verbatim and
# CASE-SENSITIVE. Rails reads every other non-empty value as true -- `False` and `Off`
# included, because they are not in this set. That is the trap: a column literally
# spelling `False` is true to the application, so neither reading can be applied
# quietly, and `coerce` refuses rather than choose.
RAILS_FALSE_STRINGS = frozenset({"0", "f", "F", "false", "FALSE", "off", "OFF"})

# Rails writes these; ZigBase owns `created`/`updated` itself.
TIMESTAMP_COLUMNS = ("created_at", "updated_at")

# What ZigBase's file route will serve verbatim (src/files/naming.zig `isSafe`).
# ASCII only: Python's `str.isalnum` accepts `é`, which the target does not.
SERVABLE_CHARACTERS = frozenset(string.ascii_letters + string.digits + "._-")

# Choices that claim a replacement was built, and so must name it. Everything else --
# `omit`, `retire`, `accept-no-default`, `out-of-scope`, `locked`, `public` -- is a
# decision to NOT build something, and has nothing to point at.
IMPLEMENTATION_CHOICES = frozenset(
    {
        "replacement",
        "hook",
        "rule",
        "route",
        "job",
        "field",
        "collection",
        "expression",
        "rekey",
        "rename",
    }
)

# ZigBase's identifier charset gate, applied at collection creation.
IDENTIFIER = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")

# Names the ZigBase engine owns on every collection (src/schema.zig
# `isSystemFieldName`), compared case-insensitively because SQLite column names collide
# that way. A field carrying one of these is DROPPED by `schema apply` rather than
# refused, so emitting one loses the column's data with an exit status of 0.
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
# Of those, the three an auth collection legitimately carries as DATA: the auth import
# maps them onto the engine's own fields, so a Rails `email` column on a table with a
# password digest is exactly right and must not raise a finding.
AUTH_MAPPED_FIELD_NAMES = frozenset({"email", "username", "verified"})
# ...and the Rails column types each of them can actually BE. The engine reads
# `verified` only as a boolean (src/import.zig), so an integer column of that name
# travels and is then silently ignored -- the same silent loss, one layer down.
AUTH_MAPPED_FIELD_TYPES = {
    "email": frozenset({"string", "text", "uuid"}),
    "username": frozenset({"string", "text", "uuid"}),
    "verified": frozenset({"boolean"}),
}


# A searchable collection `posts` provisions an FTS5 shadow table `posts_fts`, so the
# suffix is reserved (src/schema.zig `fts_suffix`); unlike a reserved FIELD name this one
# is refused rather than dropped, but refused at `schema apply` is still far too late.
FTS_SUFFIX = "_fts"


def _is_reserved_collection_name(name: str) -> bool:
    return name.endswith(FTS_SUFFIX)


def _reserved_here(
    name: str,
    *,
    is_auth: bool,
    literal: bool,
    column_type: str | None = None,
) -> bool:
    """Is this name unusable for a field on this collection?

    The auth exemption belongs to a SCALAR column that genuinely is the collection's
    email, username or verified flag. A name merely DERIVED from a column -- a relation
    that lost its `_id`, an attachment -- never inherits it, whether it arrived that way
    or was renamed there: `verified_id` is a foreign key, the engine reads `verified` as
    a boolean, and the linkage vanished end to end with a clean exit.

    `column_type` narrows it further where the source type is known: the engine ignores
    a non-boolean `verified` just as quietly.
    """
    lowered = name.lower()
    if lowered not in RESERVED_FIELD_NAMES:
        return False
    if not literal or not is_auth:
        return True
    allowed = AUTH_MAPPED_FIELD_TYPES.get(lowered)
    if allowed is None:
        return True  # engine-owned even on an auth collection
    return column_type is not None and column_type not in allowed


# ---------------------------------------------------------------------------
# Source
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Source:
    root: Path
    database: Path | None
    mode: str
    routes: dict[str, Any]
    models: dict[str, Any]
    schema: dict[str, Any]
    storage: dict[str, Any]
    jobs: dict[str, Any]
    counts: dict[str, Any]
    auth: dict[str, Any]
    versions: dict[str, Any]
    # Relations whose key names more than one column, lifted out of the inventory at
    # load time so no consumer below ever meets one. Reported as findings, never
    # silently dropped.
    composite_keys: list[dict[str, Any]] = dataclass_field(default_factory=list)

    def model_for_table(self, table: str) -> dict[str, Any] | None:
        # An STI hierarchy maps several classes onto one table; the base class is the
        # one that describes it, so prefer it and fall back to the first match.
        candidates = [m for m in self.models["models"] if m.get("table_name") == table]
        for model in candidates:
            sti = model.get("sti") or {}
            if not sti.get("enabled") or sti.get("is_base_class"):
                return model
        return candidates[0] if candidates else None

    def migratable_tables(self) -> list[dict[str, Any]]:
        return [
            t
            for t in self.schema["tables"]
            if t["name"] not in RAILS_INTERNAL_TABLES
            and not t["name"].startswith("solid_")
        ]


def _is_composite(value: Any) -> bool:
    """A key naming more than one column, in either shape the extractor can produce.

    Faithful (a list) from a current extractor, and the `["a_id", "b_id"]` string that
    an older one produced by calling `.to_s` on the Array. The string form is matched
    too so that a stale exporter run against a new converter is refused rather than
    quietly treated as a column with a very odd name -- there is no attempt to recover
    the member names from it, because Ruby's `inspect` is not a format to parse.
    """
    if isinstance(value, (list, tuple)):
        return len(value) > 1
    return isinstance(value, str) and value.startswith("[") and value.endswith("]")


def _lift_composite_keys(schema: dict[str, Any], models: dict[str, Any]) -> list[dict]:
    """Remove every composite-keyed relation from the inventory, and report them.

    A ZigBase relation holds ONE record id, so none of these can travel however they
    are decided. Removing them here is what keeps that true for the rest of the file:
    a list is unhashable and a bracketed string is the name of nothing, and between
    them they reached a dict key, a set, a tuple and a SQL identifier -- surfacing as
    an unhandled TypeError in the first three and, in the last, a raw
    `sqlite3.OperationalError` from a quoted column that does not exist. Lifted here,
    every consumer downstream keeps the single-column key it has always assumed.
    """
    lifted: list[dict] = []
    for table in schema.get("tables") or []:
        keeping = []
        for fk in table.get("foreign_keys") or []:
            if _is_composite(fk.get("column")) or _is_composite(fk.get("primary_key")):
                lifted.append(
                    {
                        "kind": "foreign_key",
                        "table": table.get("name"),
                        "columns": fk.get("column"),
                        "to_table": fk.get("to_table"),
                    }
                )
                continue
            keeping.append(fk)
        if table.get("foreign_keys") is not None:
            table["foreign_keys"] = keeping
    for model in models.get("models") or []:
        keeping = []
        for association in model.get("associations") or []:
            if _is_composite(association.get("foreign_key")):
                lifted.append(
                    {
                        "kind": "association",
                        "table": model.get("table_name"),
                        "model": model.get("name"),
                        "name": association.get("name"),
                        "columns": association.get("foreign_key"),
                        "to_table": association.get("table_name"),
                    }
                )
                continue
            keeping.append(association)
        if model.get("associations") is not None:
            model["associations"] = keeping
    return lifted


def load_source(root: Path) -> Source:
    inventory = root / "inventory"
    if not inventory.is_dir():
        raise RailsError(f"source has no inventory directory: {inventory}")

    payloads: dict[str, Any] = {}
    for name in INVENTORY_FILES:
        path = inventory / f"{name}.json"
        if not path.is_file():
            raise RailsError(f"source inventory is incomplete: {path} is missing")
        payloads[name] = read_json(path, label=f"{name}.json")

    mode = payloads["versions"].get("source")
    if mode not in (OBSERVED, INFERRED):
        raise RailsError(
            "inventory does not declare a source mode of 'observed' or 'inferred'"
        )

    # A bundle that mixes the two is the failure this whole distinction exists to
    # prevent: one inferred record in an otherwise observed inventory would let a guess
    # ride along as if the framework had reported it.
    for name in INVENTORY_FILES:
        validate_inventory_source(payloads[name], name=name, expected_mode=mode)

    # Loading stays adapter-neutral, because the inventory is: `export_source.rb` reads
    # whatever connection the application booted. Only row EXTRACTION needs the frozen
    # SQLite file, so both that requirement and the adapter gate live in `require_sqlite`
    # and run from `extract` -- putting them here would reject `inventory` on a Postgres
    # source, which is exactly the workflow the guide tells those users to follow.
    candidates = (
        sorted((root / "db").glob("*.sqlite3")) if (root / "db").is_dir() else []
    )

    return Source(
        root=root,
        database=candidates[0] if len(candidates) == 1 else None,
        mode=mode,
        routes=payloads["routes"],
        models=payloads["models"],
        schema=payloads["schema"],
        storage=payloads["storage"],
        jobs=payloads["jobs"],
        counts=payloads["counts"],
        auth=payloads["auth"],
        versions=payloads["versions"],
        composite_keys=_lift_composite_keys(payloads["schema"], payloads["models"]),
    )


# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Finding catalogue — the single source of truth
# ---------------------------------------------------------------------------
#
# Every finding the converter can raise, with the choices it offers and how each is
# honoured. This exists because a test that enumerated findings from ONE fixture only
# ever saw the six codes that fixture happened to trigger: a reviewer reintroduced a
# flagship bug in a seventh and the whole suite stayed green. Enumerating from here is
# code-bounded, so a new finding must declare itself even if no fixture produces it.
#
#   "consumes": choices the CONVERTER acts on. Each must change what it emits.
#   "external": choices that record work done elsewhere. No output difference expected.
#
# `_blocker`/`_decision`/`_info` assert their call sites against this table, so the two
# cannot drift.

FINDING_CATALOG: dict[str, dict[str, frozenset[str]]] = {
    "InventoryIsInferred": {
        "consumes": frozenset(),
        "external": frozenset({"accept-inferred", "re-run-observed"}),
    },
    "DevisePepperBreaksImport": {
        "consumes": frozenset({"reset-passwords"}),
        "external": frozenset({"confirmed-no-pepper"}),
    },
    "DeviseWithoutPepper": {"consumes": frozenset(), "external": frozenset()},
    "ExternalIdentitiesCannotMigrate": {
        "consumes": frozenset(),
        "external": frozenset({"passwordless-rollout", "out-of-scope"}),
    },
    "OAuthTokensNeverMigrate": {"consumes": frozenset(), "external": frozenset()},
    "AuthMechanismUnrecognized": {
        "consumes": frozenset(),
        "external": frozenset({"replacement", "reset-passwords", "out-of-scope"}),
    },
    "DeviseModuleBehaviorNotReproduced": {
        "consumes": frozenset(),
        "external": frozenset({"replacement", "omit"}),
    },
    "DefaultScopeHidesRows": {
        "consumes": frozenset(),
        "external": frozenset({"replacement", "omit"}),
    },
    "EncryptedAttributeCannotMigrate": {
        "consumes": frozenset(),
        "external": frozenset({"rekey", "retire"}),
    },
    "SingleTableInheritance": {
        "consumes": frozenset({"omit"}),
        "external": frozenset({"replacement"}),
    },
    "PolymorphicAssociation": {
        "consumes": frozenset({"omit"}),
        "external": frozenset({"replacement"}),
    },
    "SerializedAttribute": {
        "consumes": frozenset({"json", "text"}),
        "external": frozenset(),
    },
    "ConditionalValidatorIsCode": {
        "consumes": frozenset(),
        "external": frozenset({"hook", "rule", "omit"}),
    },
    "ValidationsNotReproduced": {
        "consumes": frozenset(),
        "external": frozenset({"hook", "field", "omit"}),
    },
    "DependentBehaviorNotReproduced": {
        "consumes": frozenset({"cascade"}),
        "external": frozenset({"hook", "omit"}),
    },
    "DatabaseTrigger": {
        "consumes": frozenset(),
        "external": frozenset({"hook", "job", "omit"}),
    },
    "DatabaseView": {
        "consumes": frozenset(),
        "external": frozenset({"collection", "route", "omit"}),
    },
    "TableNameRejected": {
        "consumes": frozenset({"rename", "omit"}),
        "external": frozenset(),
    },
    "ColumnTypeUnmapped": {"consumes": frozenset({"omit"}), "external": frozenset()},
    "AccessRulesRequireReview": {
        "consumes": frozenset({"locked", "public", "expression"}),
        "external": frozenset(),
    },
    "CatalogInspectionUnsupported": {
        "consumes": frozenset(),
        "external": frozenset({"inventoried-by-hand", "omit"}),
    },
    "CheckConstraintsUnreadable": {
        "consumes": frozenset(),
        "external": frozenset({"inventoried-by-hand", "omit"}),
    },
    "CheckConstraintNeedsReplacement": {
        "consumes": frozenset(),
        "external": frozenset({"replacement", "omit"}),
    },
    "ColumnDefaultNotReproduced": {
        "consumes": frozenset({"omit"}),
        "external": frozenset({"hook", "accept-no-default"}),
    },
    "ForeignKeyActionUnsupported": {
        "consumes": frozenset({"omit"}),
        "external": frozenset({"replacement"}),
    },
    "NonStandardPrimaryKey": {"consumes": frozenset({"omit"}), "external": frozenset()},
    "ForeignKeyTargetsNonIdColumn": {
        "consumes": frozenset({"omit"}),
        "external": frozenset(),
    },
    "AssociationWithoutForeignKey": {
        "consumes": frozenset({"relation"}),
        "external": frozenset({"omit"}),
    },
    "CredentialColumnMustNotMigrate": {
        "consumes": frozenset({"omit"}),
        "external": frozenset({"keep"}),
    },
    "RoutesNeedDisposition": {
        "consumes": frozenset(),
        "external": frozenset({"replacement", "omit"}),
    },
    "JobsNeedDisposition": {
        "consumes": frozenset(),
        "external": frozenset({"replacement", "omit"}),
    },
    "ActionTextContentNotMigrated": {
        "consumes": frozenset(),
        "external": frozenset({"replacement", "omit"}),
    },
    "CascadeContradictsRestrict": {
        # Only `cascade` changes the bundle. `hook` names an implementation the operator
        # builds outside it, and `omit` accepts the emitted default -- so the two are
        # byte-identical here, and calling either one "consuming" would be a claim the
        # bundle cannot back.
        "consumes": frozenset({"cascade"}),
        "external": frozenset({"hook", "omit"}),
    },
    "RelationColumnCannotTravel": {
        "consumes": frozenset(),
        "external": frozenset(),
    },
    "AttachmentNameCollision": {
        "consumes": frozenset({"rename", "omit"}),
        "external": frozenset(),
    },
    "AuthCollectionRelation": {
        "consumes": frozenset({"omit"}),
        # `keep` is an explicit acceptance: the operator has a plan for the links and
        # does not want the column dropped. Nothing in the converter acts on it.
        "external": frozenset({"keep"}),
    },
    "NullableTimestampColumn": {
        "consumes": frozenset({"separate-import", "omit"}),
        "external": frozenset(),
    },
    "TableHasNoTimestamps": {
        "consumes": frozenset({"separate-import", "omit"}),
        "external": frozenset(),
    },
    "NoUpdatedAtColumn": {"consumes": frozenset(), "external": frozenset()},
    # No choices: a ZigBase relation holds ONE record id, so a composite-keyed relation
    # cannot travel however it is answered. The columns themselves still travel as
    # ordinary numbers, so there is nothing to drop either -- it is a fact to record,
    # not a decision to take.
    "CompositeKeyRelation": {"consumes": frozenset(), "external": frozenset()},
    "PartialIndexPredicate": {
        "consumes": frozenset({"replacement", "omit"}),
        "external": frozenset(),
    },
    "ReservedFieldName": {
        "consumes": frozenset({"rename", "omit"}),
        "external": frozenset(),
    },
    "ColumnNameRejected": {
        "consumes": frozenset({"rename", "omit"}),
        "external": frozenset(),
    },
    "ForeignKeysUnreadable": {"consumes": frozenset({"omit"}), "external": frozenset()},
    "ForeignKeyInspectionUnsupported": {
        "consumes": frozenset({"omit"}),
        "external": frozenset(),
    },
}


def _catalogued(code: str, choices: tuple[str, ...]) -> tuple[str, ...]:
    """Assert a call site matches the catalogue, so the two cannot drift."""
    entry = FINDING_CATALOG.get(code)
    if entry is None:
        raise RailsError(f"finding {code!r} is not in FINDING_CATALOG")
    declared = entry["consumes"] | entry["external"]
    # A subset is legitimate: a finding may narrow its offer when a choice cannot be
    # honoured for that particular subject -- `cascade` is withheld when no database
    # foreign key exists. What must never happen is offering a choice the catalogue
    # does not declare, because nothing would be obliged to consume it.
    undeclared = set(choices) - declared
    if undeclared:
        raise RailsError(
            f"finding {code!r} offers undeclared choices {sorted(undeclared)}; "
            f"the catalogue declares {sorted(declared)}"
        )
    return choices


def _blocker(fid: str, code: str, message: str, choices: tuple[str, ...]) -> Finding:
    return Finding(fid, "blocker", code, message, _catalogued(code, choices), True)


def _decision(fid: str, code: str, message: str, choices: tuple[str, ...]) -> Finding:
    return Finding(fid, "decision", code, message, _catalogued(code, choices), False)


def _info(fid: str, code: str, message: str) -> Finding:
    return Finding(fid, "info", code, message, _catalogued(code, ()))


def _mode_findings(src: Source) -> list[Finding]:
    if src.mode == OBSERVED:
        return []
    # An inferred inventory is a list of questions. Make that a finding rather than a
    # footnote, so a report built on one cannot read as if the framework was consulted.
    return [
        _blocker(
            "source.inferred",
            "InventoryIsInferred",
            "the inventory was read statically, not observed from a booted application; "
            "routes, associations, validations, enums, default scopes, encrypted "
            "attributes, triggers and views may all be wrong or missing",
            ("accept-inferred", "re-run-observed"),
        )
    ]


def _model_findings(src: Source) -> list[Finding]:
    out: list[Finding] = []
    for model in src.models["models"]:
        name = model["name"]

        scope = model.get("default_scope") or {}
        if scope.get("present"):
            out.append(
                _blocker(
                    finding_id("model", name, "default_scope"),
                    "DefaultScopeHidesRows",
                    f"{name} declares a default_scope; extraction reads through unscoped "
                    f"so hidden rows are preserved, but every behavior that relied on the "
                    f"scope must be re-expressed in the target",
                    ("replacement", "omit"),
                )
            )

        for attribute in model.get("encrypted_attributes") or []:
            out.append(
                _blocker(
                    finding_id("model", name, "encrypted", attribute["attribute"]),
                    "EncryptedAttributeCannotMigrate",
                    f"{name}.{attribute['attribute']} is Active Record encrypted; "
                    f"ciphertext is bound to the source key and never migrates",
                    ("rekey", "retire"),
                )
            )

        sti = model.get("sti") or {}
        if sti.get("enabled") and sti.get("is_base_class") and sti.get("subclasses"):
            out.append(
                _blocker(
                    finding_id("model", name, "sti"),
                    "SingleTableInheritance",
                    f"{name} is an STI base for {', '.join(sti['subclasses'])} on one "
                    f"table; no automatic collection shape exists",
                    ("omit", "replacement"),
                )
            )

        for association in model.get("associations") or []:
            if association.get("polymorphic"):
                out.append(
                    _blocker(
                        finding_id(
                            "association", name, association["name"], "polymorphic"
                        ),
                        "PolymorphicAssociation",
                        f"{name}.{association['name']} is polymorphic; a ZigBase relation "
                        f"targets exactly one collection",
                        ("omit", "replacement"),
                    )
                )

        for attribute in model.get("serialized_attributes") or []:
            out.append(
                _decision(
                    finding_id("model", name, "serialized", attribute["attribute"]),
                    "SerializedAttribute",
                    f"{name}.{attribute['attribute']} is serialized by "
                    f"{attribute.get('coder', 'an unknown coder')}; confirm the target "
                    f"representation",
                    ("json", "text"),
                )
            )

        association_names = {a["name"] for a in model.get("associations") or []}
        for validator in model.get("validators") or []:
            options = validator.get("options") or {}
            conditional = options.get("if") or options.get("unless")
            if conditional is None:
                continue
            if _is_belongs_to_presence(validator, options, association_names):
                # `belongs_to_required_by_default` synthesizes one of these for every
                # association. They are framework boilerplate, already expressed by the
                # relation field's `required`, and flagging them buries the handful of
                # conditionals a human actually wrote.
                continue
            described = (
                "a proc" if isinstance(conditional, dict) else f"`{conditional}`"
            )
            out.append(
                _decision(
                    finding_id(
                        "validator", name, validator["attribute"], validator["kind"]
                    ),
                    "ConditionalValidatorIsCode",
                    f"{name}.{validator['attribute']} has a conditional "
                    f"{validator['kind']} validation guarded by {described}, which "
                    f"cannot be converted mechanically",
                    ("hook", "rule", "omit"),
                )
            )
    return out


def _is_belongs_to_presence(
    validator: dict[str, Any], options: dict[str, Any], associations: set[str]
) -> bool:
    return (
        validator.get("kind") == "presence"
        and validator.get("attribute") in associations
        and options.get("message") == "required"
    )


def _partial_index_findings(src: Source) -> list[Finding]:
    out: list[Finding] = []
    for table in src.migratable_tables():
        for index in table.get("indexes") or []:
            if not index.get("where"):
                continue
            out.append(
                _blocker(
                    finding_id("index", table["name"], index["name"], "where"),
                    "PartialIndexPredicate",
                    f"index {index['name']} on {table['name']} is partial "
                    f"(WHERE {index['where']}); the predicate names source columns and "
                    f"values that extraction renames or decodes, so it cannot be copied "
                    f"verbatim — supply a reviewed target predicate as the artifact, or "
                    f"omit the index",
                    ("replacement", "omit"),
                )
            )
    return out


def _catalog_findings(src: Source) -> list[Finding]:
    """Refuse to read an unreadable catalog as an empty one."""
    # `is not True`, not `is False`: an inventory recorded by an older extractor has no
    # such key at all, and reading that silence as "supported" reinstates exactly the bug
    # this finding exists to prevent.
    if src.schema.get("catalog_supported") is not True:
        return [
            _blocker(
                "schema.catalog.unsupported",
                "CatalogInspectionUnsupported",
                f"trigger and view inspection is implemented for SQLite only; on "
                f"{src.versions.get('adapter')} the extractor could not read the catalog, "
                f"so an empty trigger/view list here means UNKNOWN, not none — inventory "
                f"them by hand before deciding",
                ("inventoried-by-hand", "omit"),
            )
        ]
    return []


def _constraint_findings(src: Source) -> list[Finding]:
    out: list[Finding] = []
    for table in src.migratable_tables():
        constraints = table.get("check_constraints")
        if constraints is None:
            out.append(
                _blocker(
                    finding_id("table", table["name"], "check_constraints"),
                    "CheckConstraintsUnreadable",
                    f"the adapter could not report check constraints for "
                    f"{table['name']}; absence here is unknown, not none",
                    ("inventoried-by-hand", "omit"),
                )
            )
            continue
        for ordinal, constraint in enumerate(constraints):
            # An unnamed constraint would otherwise stringify to the literal "None", so
            # two of them on one table would collapse into a single actionable id and one
            # decision would silently cover two different expressions.
            label = constraint.get("name") or f"unnamed-{ordinal}"
            out.append(
                _blocker(
                    finding_id("constraint", table["name"], str(label)),
                    "CheckConstraintNeedsReplacement",
                    f"{table['name']} has a check constraint "
                    f"({constraint.get('expression')}); ZigBase has no equivalent, so it "
                    f"needs a hook or rule replacement, or a decision to drop it",
                    ("replacement", "omit"),
                )
            )
    return out


def _default_findings(src: Source) -> list[Finding]:
    """A column default is behavior the target does not reproduce.

    Rails applies it on INSERT; the imported rows already carry their values, so the
    data is fine -- but every write AFTER the migration loses it. `users.role DEFAULT 0`
    becoming a required field with no default is a behavior change, not a formatting one.
    """
    out: list[Finding] = []
    for table in src.migratable_tables():
        for column in table["columns"]:
            if column["name"] in TIMESTAMP_COLUMNS or column["name"] == "id":
                continue
            default = column.get("default")
            function = column.get("default_function")
            if default is None and not function:
                continue
            shown = function or default
            out.append(
                _decision(
                    finding_id("column", table["name"], column["name"], "default"),
                    "ColumnDefaultNotReproduced",
                    f"{table['name']}.{column['name']} defaults to {shown!r} in the "
                    f"source; imported rows keep their values, but writes after cutover "
                    f"will not get this default",
                    ("hook", "accept-no-default", "omit"),
                )
            )
    return out


def _foreign_key_findings(src: Source) -> list[Finding]:
    """`ON DELETE CASCADE` is behavior, and silence about it is a data-loss risk."""
    out: list[Finding] = []
    for table in src.migratable_tables():
        for fk in table.get("foreign_keys") or []:
            if fk.get("to_table") in RAILS_INTERNAL_TABLES:
                continue
            on_delete = (fk.get("on_delete") or "").lower()
            on_update = (fk.get("on_update") or "").lower()
            if not on_delete and not on_update:
                continue
            # `cascade` maps exactly onto a relation's cascadeDelete; nothing else does.
            if on_delete in ("", "cascade") and not on_update:
                continue
            out.append(
                _blocker(
                    finding_id("fk", table["name"], fk["column"], "action"),
                    "ForeignKeyActionUnsupported",
                    f"{table['name']}.{fk['column']} declares "
                    f"on_delete={fk.get('on_delete')!r} on_update={fk.get('on_update')!r}; "
                    f"only ON DELETE CASCADE maps onto a ZigBase relation, so this needs "
                    f"a replacement or an explicit decision to drop the action",
                    ("replacement", "omit"),
                )
            )
    return out


def _foreign_key_visibility_findings(src: Source) -> list[Finding]:
    """`foreign_keys: null` means the adapter could not answer, not that there are none.

    Same unknown-versus-none trap already closed for catalogs and check constraints: a
    silent `[]` here would flatten every relation in the schema without a word.
    """
    if src.schema.get("foreign_keys_supported") is not True:
        return [
            _blocker(
                "schema.foreign_keys.unsupported",
                "ForeignKeyInspectionUnsupported",
                f"the {src.versions.get('adapter')} adapter did not report whether it "
                f"can read foreign keys, so no relation in this schema can be trusted",
                ("omit",),
            )
        ]
    out: list[Finding] = []
    for table in src.migratable_tables():
        if table.get("foreign_keys") is None:
            out.append(
                _blocker(
                    finding_id("table", table["name"], "foreign_keys"),
                    "ForeignKeysUnreadable",
                    f"foreign-key inspection failed for {table['name']}; absence here is "
                    f"unknown, not none, so its relations cannot be trusted",
                    ("omit",),
                )
            )
    return out


def _identity_findings(src: Source) -> list[Finding]:
    """Identity is the one thing a migration cannot get wrong quietly.

    Extraction reads and writes `id`. A table keyed by anything else, or a foreign key
    pointing at a non-`id` column, would emit values that look like record ids and are
    not -- so both are refused rather than converted.
    """
    out: list[Finding] = []
    for table in src.migratable_tables():
        primary = table.get("primary_key")
        if primary != "id":
            # A Rails 7.1 composite key arrives as a list. Name it as one rather than
            # printing a Python repr at the operator: "keyed by ['a', 'b']" reads like
            # a bug in the tool, and the reason it cannot travel is worth stating --
            # a ZigBase record is keyed by one `id`, so there is nothing to map two to.
            described = (
                f"a composite primary key ({', '.join(str(p) for p in primary)})"
                if isinstance(primary, (list, tuple))
                else f"{primary!r}"
            )
            out.append(
                _blocker(
                    finding_id("table", table["name"], "primary_key"),
                    "NonStandardPrimaryKey",
                    f"{table['name']} is keyed by {described}, not `id`; extraction reads "
                    f"and preserves `id`, so this table cannot be migrated faithfully "
                    f"and extraction cannot re-key it, so the only faithful options are "
                    f"a hand-built import or leaving this table behind",
                    ("omit",),
                )
            )
        for fk in table.get("foreign_keys") or []:
            if fk.get("to_table") in RAILS_INTERNAL_TABLES:
                continue
            target = fk.get("primary_key")
            if target and target != "id":
                out.append(
                    _blocker(
                        finding_id("fk", table["name"], fk["column"], "target_key"),
                        "ForeignKeyTargetsNonIdColumn",
                        f"{table['name']}.{fk['column']} references "
                        f"{fk['to_table']}.{target}, not its `id`; emitting those values "
                        f"as relation ids would point at records that do not exist",
                        ("omit",),
                    )
                )
    return out


def _cascade_contradiction_findings(src: Source) -> list[Finding]:
    """`ON DELETE CASCADE` in the database, `restrict_with_*` in the application.

    Both are true of the source and they say opposite things: delete through Active
    Record and Rails raises `DeleteRestrictionError` with the rows intact; delete through
    SQL and the database removes them. The target has only one layer, so mirroring the
    database silently discards a protection the application enforces on every ordinary
    delete. Which one the operator meant is not ours to guess.
    """
    if src.schema.get("foreign_keys_supported") is not True:
        # The adapter would not say whether it can read foreign keys; every array here
        # is unknown, and `ForeignKeyInspectionUnsupported` already governs that.
        return []
    protected = _restrict_protected(src)
    out: list[Finding] = []
    for table in src.migratable_tables():
        for fk in table.get("foreign_keys") or []:
            column = fk.get("column")
            if (table["name"], column) not in protected:
                continue
            if (fk.get("on_delete") or "").lower() != "cascade":
                continue
            if (fk.get("primary_key") or "id") != "id":
                # `ForeignKeyTargetsNonIdColumn` offers only `omit`, so this relation is
                # certain to be dropped and neither answer here could ever apply.
                #
                # Read exactly as `_identity_findings` reads it (`if target and target
                # != "id"`), which is what decides whether that finding is raised at
                # all. Testing `not in (None, "id")` disagreed about `""`: this check
                # skipped as though the relation would be dropped, while the finding
                # that drops it was never raised -- so the relation was emitted, the
                # database cascade vanished, and no decision was ever offered.
                continue
            if _relation_emitted_for(src, table["name"], column, fk.get("to_table")):
                continue  # no relation is emitted for it at all
            out.append(
                _blocker(
                    finding_id("fk", table["name"], str(column), "cascade_vs_restrict"),
                    "CascadeContradictsRestrict",
                    f"{table['name']}.{column} has ON DELETE CASCADE in the database "
                    f"while a model declares `restrict_with_*` on the same rows. The "
                    f"target has one layer: `cascade` keeps the database's behaviour, "
                    f"`hook` carries the application's refusal as a before-delete hook, "
                    f"and `omit` accepts neither — the parent deletes and this relation "
                    f"is set to null",
                    ("cascade", "hook", "omit"),
                )
            )
    return out


def _unmigratable_relation_findings(src: Source) -> list[Finding]:
    """A database foreign key sitting on a column whose value cannot travel.

    `add_foreign_key :profiles, :users, column: :id` -- the shared-primary-key idiom --
    is real, and the primary key becomes the record id rather than a relation field. So
    are foreign keys on Rails timestamps and on a password digest. Every other way a
    relation disappears raises something (encryption, polymorphism, an unreadable key);
    this one flattened the graph in silence, which is the exact sin the association
    findings exist to prevent. Reported, not adjudicated: there is nothing to choose.
    """
    digests = _auth_tables(src)
    out: list[Finding] = []
    for table in src.migratable_tables():
        name = table["name"]
        unmigratable = _primary_key_names(table) | set(TIMESTAMP_COLUMNS)
        if name in digests:
            unmigratable.add(digests[name])
        for fk in table.get("foreign_keys") or []:
            column = fk.get("column")
            if (
                column not in unmigratable
                or fk.get("to_table") in RAILS_INTERNAL_TABLES
            ):
                continue
            out.append(
                _info(
                    finding_id("fk", name, column, "unmigratable"),
                    "RelationColumnCannotTravel",
                    f"{name}.{column} has a database foreign key to "
                    f"{fk.get('to_table')}, but that column's value does not travel "
                    f"(it is the primary key, a Rails timestamp, or a password "
                    f"digest), so no relation field is emitted for it",
                )
            )
    return out


def _association_findings(src: Source) -> list[Finding]:
    """A `belongs_to` with no database foreign key is still a relation.

    Relations are derived from database FKs. Rails does not require one -- `belongs_to
    :user` with a plain `user_id` column and no `foreign_key: true` is extremely common,
    especially in older schemas. Those became ordinary number fields with no finding, so
    the graph silently flattened.
    """
    out: list[Finding] = []
    fk_columns: dict[str, set[str]] = {}
    for table in src.migratable_tables():
        fk_columns[table["name"]] = {
            # Not a key into one of Rails' own tables: `map_tables` emits no relation
            # for those, so treating one as "already a relation" withheld the promotion
            # from a `belongs_to` that could genuinely have carried one. This set and
            # `_relation_bearing_columns` answer the same question and must agree.
            fk["column"]
            for fk in (table.get("foreign_keys") or [])
            if fk.get("to_table") not in RAILS_INTERNAL_TABLES
        }

    for model in src.models["models"]:
        table = model.get("table_name")
        if table not in fk_columns:
            continue
        columns = {
            c["name"]
            for t in src.migratable_tables()
            if t["name"] == table
            for c in t["columns"]
        }
        for association in model.get("associations") or []:
            if not _bearable_belongs_to(association):
                continue
            column = association.get("foreign_key")
            if not column or column not in columns:
                continue
            if column in fk_columns[table]:
                continue  # a real database FK; already a relation
            out.append(
                _blocker(
                    finding_id(
                        "association", model["name"], association["name"], "nofk"
                    ),
                    "AssociationWithoutForeignKey",
                    f"{model['name']}.{association['name']} is a belongs_to on "
                    f"{table}.{column} with no database foreign key, so extraction would "
                    f"emit an ordinary number instead of a relation",
                    ("relation", "omit"),
                )
            )
    return out


# Devise and Doorkeeper keep single-use credentials in ordinary columns. They are
# credentials, not data, and the guide promises they never migrate.
CREDENTIAL_COLUMNS = frozenset(
    {
        "reset_password_token",
        "confirmation_token",
        "unlock_token",
        "remember_token",
        "invitation_token",
        "authentication_token",
        "encrypted_otp_secret",
        "otp_secret",
        "token",
        "refresh_token",
    }
)


def _credential_column_findings(src: Source) -> list[Finding]:
    """Only `encrypted_password` was stripped; the rest became ordinary fields.

    A reset or confirmation token in the target is a live credential that the source
    already considers spent, and shipping one contradicts the guide's own promise.
    """
    out: list[Finding] = []
    login_digests = _auth_tables(src)
    for table in src.migratable_tables():
        for column in table["columns"]:
            # A `*_digest` column that is NOT the login credential is a bcrypt digest of
            # a live token -- `remember_digest`, `activation_digest`, `reset_digest` --
            # and migrating one hands the target a working credential the source thinks
            # it controls.
            other_digest = column["name"].endswith("_digest") and column[
                "name"
            ] != login_digests.get(table["name"])
            if column["name"] not in CREDENTIAL_COLUMNS and not other_digest:
                continue
            out.append(
                _blocker(
                    finding_id("column", table["name"], column["name"], "credential"),
                    "CredentialColumnMustNotMigrate",
                    f"{table['name']}.{column['name']} holds credential material; "
                    f"sessions and tokens never migrate, so this column must be dropped "
                    f"or explicitly justified",
                    ("omit", "keep"),
                )
            )
    return out


def _devise_state_findings(src: Source) -> list[Finding]:
    """A migrated hash does not imply equivalent login behavior."""
    devise = src.auth.get("devise") or {}
    if not devise.get("present"):
        return []
    modules = {
        m for entry in devise.get("models") or [] for m in entry.get("modules") or []
    }
    out: list[Finding] = []
    for module in sorted(
        modules & {"confirmable", "lockable", "timeoutable", "trackable"}
    ):
        out.append(
            _blocker(
                finding_id("auth", "devise", module),
                "DeviseModuleBehaviorNotReproduced",
                f"Devise {module} governs whether an account may sign in at all "
                f"(confirmation state, lock state, session lifetime); importing the "
                f"digest does not carry it, so it needs an explicit mapping or a decision",
                ("replacement", "omit"),
            )
        )
    return out


def _behavior_findings(src: Source) -> list[Finding]:
    """Routes, jobs and storage are observed and then never adjudicated.

    The guide requires a disposition for every client-visible route, every queued job and
    every mailer. Loading them into `Source` and never turning them into findings meant a
    custom endpoint could be migrated with no decision recorded anywhere.
    """
    out: list[Finding] = []
    routes = [r for r in src.routes.get("routes") or [] if not r.get("internal")]
    if routes:
        out.append(
            _blocker(
                "routes.disposition",
                "RoutesNeedDisposition",
                f"{len(routes)} client-visible routes were observed; each needs a target "
                f"(collection API, hook, typed route, or deliberate retirement) and none "
                f"is derivable automatically",
                ("replacement", "omit"),
            )
        )
    jobs = [j for j in src.jobs.get("jobs") or [] if j.get("application_owned")]
    if jobs:
        out.append(
            _blocker(
                "jobs.disposition",
                "JobsNeedDisposition",
                f"{len(jobs)} application Active Job classes were observed "
                f"(adapter: {src.jobs.get('configured_adapter')}); queued work, retries "
                f"and mailers do not migrate on their own",
                ("replacement", "omit"),
            )
        )
    action_text = src.models.get("action_text") or {}
    rich_text = bool(
        action_text.get("models_with_rich_text") or action_text.get("row_count")
    )
    if rich_text:
        out.append(
            _blocker(
                "actiontext.content",
                "ActionTextContentNotMigrated",
                "Action Text rich-text bodies live in `action_text_rich_texts`, which is "
                "treated as a Rails-internal table and never extracted; their content and "
                "embedded attachments would disappear silently",
                ("replacement", "omit"),
            )
        )
    return out


def _validation_findings(src: Source) -> list[Finding]:
    """Validations decide which writes are accepted after cutover."""
    out: list[Finding] = []
    for model in src.models["models"]:
        kinds = sorted(
            {
                v["kind"]
                for v in model.get("validators") or []
                if v.get("kind") not in ("presence",)
            }
        )
        if not kinds:
            continue
        out.append(
            _decision(
                finding_id("model", model["name"], "validations"),
                "ValidationsNotReproduced",
                f"{model['name']} declares {', '.join(kinds)} validations; ZigBase field "
                f"options cover only some of these, so the rest need a hook or an "
                f"explicit decision to drop them",
                ("hook", "field", "omit"),
            )
        )
    for model in src.models["models"]:
        attachments = {a["name"] for a in (model.get("attachments") or [])}
        dependent_associations = [
            a
            for a in model.get("associations") or []
            if a.get("dependent")
            # `has_one_attached :cover` generates `cover_attachment`; the operator did
            # not declare that behaviour, and file cleanup travels with the file field.
            # Only the generated ones are hidden -- a hand-written association onto an
            # Active Storage table is real, and the caveat now describes it accurately.
            and a["name"].removesuffix("_attachments").removesuffix("_attachment")
            not in attachments
        ]
        dependents = sorted({a["name"] for a in dependent_associations})
        if not dependents:
            continue
        # Offer `cascade` only where it can be honoured. `cascadeDelete` rides on a
        # relation, and relations come from database foreign keys -- a polymorphic
        # `has_many ... as: :flaggable` has a `flaggable_id` column and no foreign key,
        # so the choice would be recorded and silently do nothing.
        protected = _restrict_protected(src)

        def _uncovered(association: dict[str, Any]) -> str | None:
            """Why a cascade decision would not cover this association, or None."""
            if association.get("through") is not None:
                return (
                    "it runs through another association, so it fires when a "
                    "different table's rows are deleted"
                )
            if association.get("macro") == "belongs_to":
                return "it runs the other way: destroying the child destroys the parent"
            if not _cascades_children(association):
                return None  # a restrict or nullify is not a cascade to begin with
            pair = (association.get("table_name"), association.get("foreign_key"))
            reason = _relation_emitted_for(src, *pair, model.get("table_name"))
            if reason is not None:
                return reason
            if pair in protected:
                # Another model refuses to delete these rows, and that refusal wins --
                # so offering `cascade` for them would record a choice nothing honours.
                return "another model refuses the delete"
            return None

        def _honourable(association: dict[str, Any]) -> bool:
            return (
                _is_direct_child_association(association)
                and _cascades_children(association)
                and _uncovered(association) is None
            )

        cascadable = any(_honourable(a) for a in dependent_associations)
        # Name what a cascade decision will NOT cover, rather than applying it to the
        # honourable subset in silence.
        # Name each uncovered association WITH ITS REASON. "No database foreign key"
        # is simply untrue of a through or belongs_to dependent, and telling an operator
        # that about an association whose semantics differ is worse than saying nothing.
        reasons = sorted(
            f"{a['name']}: {_uncovered(a)}"
            for a in dependent_associations
            if _uncovered(a) is not None
        )
        caveat = (
            f" (a cascade decision cannot cover {'; '.join(reasons)})"
            if reasons
            else ""
        )
        out.append(
            _decision(
                finding_id("model", model["name"], "dependent"),
                "DependentBehaviorNotReproduced",
                f"{model['name']} declares dependent behavior on "
                f"{', '.join(dependents)}; deletion semantics do not migrate with the "
                f"rows{caveat}",
                ("hook", "cascade", "omit") if cascadable else ("hook", "omit"),
            )
        )
    return out


def _unmigratable_relation_columns(src: Source, entry: dict[str, Any]) -> set[str]:
    """Columns of `entry` that never become a relation field, whatever points at them.

    The same set `map_tables` skips: the primary key becomes the record id, Rails
    timestamps become `created`/`updated`, a password digest becomes `passwordHash`, and
    ciphertext does not travel at all.
    """
    encrypted = _encrypted_columns(src).get(entry["name"], set())
    digests = _auth_tables(src)
    columns = _primary_key_names(entry) | set(TIMESTAMP_COLUMNS) | encrypted
    if entry["name"] in digests:
        columns.add(digests[entry["name"]])
    return columns


def _relation_emitted_for(
    src: Source,
    table: str | None,
    column: str | None,
    target: str | None = None,
) -> str | None:
    """Why `(table, column)` does NOT become a relation field, or None if it does.

    One predicate for three layers that used to disagree: the finding offered `cascade`
    on a pair the emission skipped, the inert-decision check counted it as honoured, and
    the decision was then recorded and did nothing -- exactly what that check exists to
    prevent. `target`, when given, is the table the relation must point AT: a cascade
    decided on one model must not flip `cascadeDelete` on a relation into another.
    """
    if not table or not column:
        return "its table or foreign key is not recorded"
    entry = next((t for t in src.migratable_tables() if t["name"] == table), None)
    if entry is None:
        return f"{table!r} is not a table this migration extracts"
    fk = next(
        (f for f in (entry.get("foreign_keys") or []) if f.get("column") == column),
        None,
    )
    if fk is None:
        return "no database foreign key"
    # Rails' own tables never become collections, and `map_tables` skips a foreign key
    # into one outright -- so no relation is emitted however the pair is decided. Left
    # out, this predicate disagreed with the emission it exists to mirror, and the
    # contradiction finding offered `cascade` on a column that has no relation to
    # cascade: byte-identical bundles for all three choices.
    if fk.get("to_table") in RAILS_INTERNAL_TABLES:
        return (
            f"its foreign key points at {fk.get('to_table')!r}, which Rails owns and "
            f"this migration never turns into a collection"
        )
    # A falsy target must REFUSE, never fall through: a model whose `table_name` the
    # extractor could not read would otherwise skip the back-pointing requirement
    # entirely and reinstate the cross-table cascade this check exists to stop.
    if fk.get("to_table") != target:
        return f"its foreign key points at {fk.get('to_table')!r}, not at this model"
    if column in _unmigratable_relation_columns(src, entry):
        return (
            "its foreign key sits on a column that never becomes a relation (the "
            "primary key, a Rails timestamp, a password digest or an encrypted value)"
        )
    return None


def _timestamp_findings(src: Source) -> list[Finding]:
    out: list[Finding] = []
    for table in src.migratable_tables():
        names = {c["name"] for c in table["columns"]}
        if "created_at" not in names:
            # `--preserve-timestamps` is applied to the whole manifest and ZigBase
            # requires BOTH values on every row, so such a table extracts cleanly and
            # then fails the documented import.
            #
            # `updated_at` alone lands here too. Mirroring it into `created` the way the
            # opposite case mirrors created into updated would FABRICATE a creation time
            # -- "last touched" is not "made" -- so this is a decision, not a courtesy.
            missing = (
                "neither created_at nor updated_at"
                if "updated_at" not in names
                else "no created_at (only updated_at)"
            )
            out.append(
                _blocker(
                    finding_id("table", table["name"], "no_timestamps"),
                    "TableHasNoTimestamps",
                    f"{table['name']} has {missing}, so it cannot "
                    f"be imported with --preserve-timestamps, which the documented "
                    f"workflow applies to every manifest entry",
                    ("separate-import", "omit"),
                )
            )
            continue
        nullable = sorted(
            column["name"]
            for column in table["columns"]
            if column["name"] in TIMESTAMP_COLUMNS and column.get("null", True)
        )
        if nullable:
            # Rails <= 4 wrote `t.timestamps` as NULLABLE columns, and legacy apps are
            # exactly the population being re-platformed. The column-level gate above
            # sees a timestamp and waves the table through; a row whose VALUE is NULL
            # then emits no `created`, rides the main manifest, and fails the documented
            # `--preserve-timestamps` import. Value-agnostic on purpose, so it protects
            # the Postgres path too.
            out.append(
                _blocker(
                    finding_id("table", table["name"], "nullable_timestamps"),
                    "NullableTimestampColumn",
                    f"{table['name']} declares {', '.join(nullable)} as nullable, so a "
                    f"row may carry no timestamp at all; ZigBase requires both values on "
                    f"every row imported with --preserve-timestamps",
                    ("separate-import", "omit"),
                )
            )
        if "updated_at" not in names:
            out.append(
                _info(
                    finding_id("table", table["name"], "updated_at"),
                    "NoUpdatedAtColumn",
                    f"{table['name']} records created_at but not updated_at; extraction "
                    f"mirrors created into updated so the row can be imported with "
                    f"--preserve-timestamps, which reads as never-updated",
                )
            )
    return out


def _schema_findings(src: Source) -> list[Finding]:
    out: list[Finding] = []
    for trigger in src.schema.get("triggers") or []:
        out.append(
            _blocker(
                finding_id("schema", "trigger", trigger["name"]),
                "DatabaseTrigger",
                f"trigger {trigger['name']} on {trigger['table']} maintains state outside "
                f"the application; nothing in the target reproduces it automatically",
                ("hook", "job", "omit"),
            )
        )
    for view in src.schema.get("views") or []:
        out.append(
            _blocker(
                finding_id("schema", "view", view["name"]),
                "DatabaseView",
                f"view {view['name']} is computed by the database and has no collection "
                f"equivalent",
                ("route", "collection", "omit"),
            )
        )

    auth_tables = _auth_tables(src)
    for table in src.migratable_tables():
        name = table["name"]
        if not IDENTIFIER.match(name) or _is_reserved_collection_name(name):
            out.append(
                _blocker(
                    finding_id("table", name, "identifier"),
                    "TableNameRejected",
                    f"table {name!r} is not a usable ZigBase collection name"
                    + (
                        f" (the {FTS_SUFFIX!r} suffix is reserved for full-text search "
                        f"shadow tables)"
                        if _is_reserved_collection_name(name)
                        else ""
                    ),
                    ("rename", "omit"),
                )
            )
        for column in table["columns"]:
            if column["name"] == "id" or column["name"] in TIMESTAMP_COLUMNS:
                continue
            # A foreign-key column becomes a RELATION field, which is never the auth
            # collection's own email/username/verified however it is spelled. A
            is_fk = column["name"] in _relation_bearing_columns(src, name)
            if _reserved_here(
                column["name"],
                is_auth=name in auth_tables,
                literal=not is_fk,
                column_type=column["type"],
            ) and column["name"] not in _primary_key_names(table):
                out.append(
                    _blocker(
                        finding_id("column", name, column["name"], "reserved"),
                        "ReservedFieldName",
                        f"column {name}.{column['name']!r} collides with a field name "
                        f"the ZigBase engine owns; `schema apply` DROPS such a field "
                        f"instead of refusing it, so the column's data would be lost "
                        f"with a clean exit — rename it or drop it deliberately",
                        ("rename", "omit"),
                    )
                )
            if not IDENTIFIER.match(column["name"]):
                out.append(
                    _blocker(
                        finding_id("column", name, column["name"], "identifier"),
                        "ColumnNameRejected",
                        f"column {name}.{column['name']!r} is not a valid ZigBase field "
                        f"identifier; supply a replacement name as the artifact, or drop "
                        f"the column",
                        ("rename", "omit"),
                    )
                )
            if column["type"] not in TYPE_MAP:
                out.append(
                    _blocker(
                        finding_id("column", name, column["name"], "type"),
                        "ColumnTypeUnmapped",
                        f"{name}.{column['name']} has Rails type {column['type']!r} with "
                        f"no ZigBase equivalent",
                        ("omit",),
                    )
                )

        if name in auth_tables:
            # An auth file is imported on its own -- no manifest, and so none of the
            # strip-then-patch ordering the manifest importer uses for relations. A
            # relation OUT of an auth collection therefore cannot resolve in any
            # documented order: auth-first fails on the target row, and manifest-first
            # fails because ordinary rows relate back to the auth collection. A
            # self-relation fails the same way on any forward reference.
            for column in sorted(_relation_bearing_columns(src, name)):
                out.append(
                    _blocker(
                        finding_id("column", name, column, "auth_relation"),
                        "AuthCollectionRelation",
                        f"{name}.{column} is a relation out of an auth collection, and "
                        f"auth files are imported one at a time with no ordering "
                        f"machinery; no documented import order resolves it. Drop the "
                        f"relation, or keep it and re-establish the links yourself "
                        f"after the import",
                        ("omit", "keep"),
                    )
                )

        for attachment in sorted(
            a["name"]
            for a in ((src.model_for_table(name) or {}).get("attachments") or [])
        ):
            # An attachment is a file field; it is never the collection's own auth
            # identity. It has no second name to fall back to on its own, but the
            # operator can supply one, so both choices are real.
            if not IDENTIFIER.match(attachment):
                # Ruby permits `has_one_attached :_draft`; the target requires a leading
                # letter. Columns and tables were both held to this gate and attachments
                # were not, so the field reached `schema apply` and failed there -- after
                # earlier collections had already been created.
                out.append(
                    _blocker(
                        finding_id("attachment", name, attachment, "identifier"),
                        "ColumnNameRejected",
                        f"the Active Storage attachment {name}.{attachment!r} is not a "
                        f"valid ZigBase field identifier; supply a replacement name as "
                        f"the artifact, or drop the attachment",
                        ("rename", "omit"),
                    )
                )
            if attachment.lower() in {c["name"].lower() for c in table["columns"]}:
                # A Paperclip or CarrierWave column left in place beside the Active
                # Storage attachment that replaced it -- an ordinary shape after that
                # migration. Both names are valid and unreserved, so no other gate sees
                # them; without a finding the operator met a refusal at extraction
                # naming a decision that did not exist.
                out.append(
                    _blocker(
                        finding_id("attachment", name, attachment, "collision"),
                        "AttachmentNameCollision",
                        f"the Active Storage attachment {name}.{attachment!r} has the "
                        f"same name as a column on that table; rename the attachment's "
                        f"field, or drop the attachment",
                        ("rename", "omit"),
                    )
                )
            if _reserved_here(attachment, is_auth=name in auth_tables, literal=False):
                out.append(
                    _blocker(
                        finding_id("attachment", name, attachment, "reserved"),
                        "ReservedFieldName",
                        f"the Active Storage attachment {name}.{attachment!r} collides "
                        f"with a field name the ZigBase engine owns; `schema apply` "
                        f"DROPS such a field instead of refusing it — rename it or drop "
                        f"it deliberately",
                        ("rename", "omit"),
                    )
                )

        # Access rules are the one thing a converter must never infer. A blank rule in
        # ZigBase means locked, so silence is safe -- but silence is also almost never
        # what the source did, so force the choice.
        out.append(
            _decision(
                finding_id("table", name, "rules"),
                "AccessRulesRequireReview",
                f"collection {name} needs explicit list/view/create/update/delete rules; "
                f"unset means locked to superusers",
                ("locked", "public", "expression"),
            )
        )
    return out


def _credential_findings(src: Source) -> list[Finding]:
    out: list[Finding] = []
    auth = src.auth

    devise = auth.get("devise") or {}
    if devise.get("present"):
        pepper = devise.get("pepper_configured")
        if pepper is not False:
            # True means peppered; None means the value could not be read. Both are
            # blockers, because importing a peppered digest succeeds and then fails
            # every login, and that is indistinguishable from success until cutover.
            out.append(
                _blocker(
                    "auth.devise.pepper",
                    "DevisePepperBreaksImport",
                    "Devise has a configured pepper (or its state could not be read); a "
                    "peppered digest is byte-indistinguishable from an ordinary bcrypt "
                    "hash and will fail every login after import",
                    ("reset-passwords", "confirmed-no-pepper"),
                )
            )
        else:
            out.append(
                _info(
                    "auth.devise.present",
                    "DeviseWithoutPepper",
                    "Devise is present with no configured pepper; its bcrypt digests are "
                    "importable, subject to per-row validation",
                )
            )

    omniauth = auth.get("omniauth") or {}
    if omniauth.get("present"):
        providers = ", ".join(omniauth.get("providers") or []) or "unnamed providers"
        out.append(
            _blocker(
                "auth.omniauth.identities",
                "ExternalIdentitiesCannotMigrate",
                f"OmniAuth is configured ({providers}); ZigBase stores provider linkage in "
                f"the engine-owned _externalAuths table, which the import path refuses, so "
                f"a migrated external-identity account has no way to sign in",
                ("passwordless-rollout", "out-of-scope"),
            )
        )

    if (auth.get("doorkeeper") or {}).get("present"):
        out.append(
            _info(
                "auth.doorkeeper.tokens",
                "OAuthTokensNeverMigrate",
                "Doorkeeper is present; its access and refresh tokens are credentials and "
                "are never migrated",
            )
        )

    if not devise.get("present") and not auth.get("has_secure_password"):
        out.append(
            _blocker(
                "auth.mechanism.unknown",
                "AuthMechanismUnrecognized",
                "no Devise model and no has_secure_password model were observed; the "
                "credential mechanism must be identified before any auth import",
                ("replacement", "reset-passwords", "out-of-scope"),
            )
        )
    return out


def require_sqlite(src: Source) -> Path:
    """Return the frozen database, or refuse with the reason extraction cannot proceed.

    Called only from the paths that read rows. `inventory` deliberately does not call it:
    findings and durable decisions come from the adapter-neutral observed inventory, and
    a Postgres or MySQL operator needs exactly that half before exporting their rows
    through the generic NDJSON path.
    """
    adapter = str(src.versions.get("adapter") or "unknown")
    if adapter.lower() not in ("sqlite", "sqlite3"):
        raise RailsError(
            f"extraction reads rows from a frozen SQLite file; this inventory was "
            f"observed on {adapter}. The inventory and its decisions are adapter-neutral "
            f"and remain usable — export the rows separately and follow the generic "
            f"NDJSON path in docs/migration-tools.md."
        )
    if src.database is None:
        raise RailsError(
            f"expected exactly one .sqlite3 database under {src.root / 'db'} for "
            f"extraction"
        )
    return src.database


def _composite_key_findings(src: Source) -> list[Finding]:
    """Report every relation lifted out for naming more than one column.

    Rails 7.1 composite keys are the reason this exists. Silence was the old behavior
    in the association case — the graph simply flattened — and this file's whole
    argument is that a migration may lose a capability but must never lose it quietly.
    """
    out: list[Finding] = []
    for index, entry in enumerate(src.composite_keys):
        columns = entry.get("columns")
        named = (
            ", ".join(str(part) for part in columns)
            if isinstance(columns, (list, tuple))
            else str(columns)
        )
        if entry["kind"] == "association":
            subject = f"{entry['model']}.{entry['name']}"
            fid = finding_id(
                "association", str(entry["model"]), str(entry["name"]), "composite"
            )
        else:
            subject = f"{entry['table']} -> {entry.get('to_table')}"
            fid = finding_id("fk", str(entry["table"]), str(index), "composite")
        out.append(
            _info(
                fid,
                "CompositeKeyRelation",
                f"{subject} is keyed by more than one column ({named}); a ZigBase "
                f"relation holds one record id, so no relation is emitted for it. The "
                f"columns still travel as ordinary numbers — re-establish the link "
                f"yourself if the target collection needs it",
            )
        )
    return out


def build_findings(src: Source) -> list[Finding]:
    findings = (
        _mode_findings(src)
        + _credential_findings(src)
        + _model_findings(src)
        + _schema_findings(src)
        + _timestamp_findings(src)
        + _partial_index_findings(src)
        + _catalog_findings(src)
        + _constraint_findings(src)
        + _default_findings(src)
        + _foreign_key_findings(src)
        + _identity_findings(src)
        + _foreign_key_visibility_findings(src)
        + _association_findings(src)
        + _composite_key_findings(src)
        + _unmigratable_relation_findings(src)
        + _cascade_contradiction_findings(src)
        + _credential_column_findings(src)
        + _devise_state_findings(src)
        + _behavior_findings(src)
        + _validation_findings(src)
    )
    return _reject_duplicate_ids(sorted(findings, key=lambda f: f.id))


def _reject_duplicate_ids(ordered: list[Finding]) -> list[Finding]:
    """A duplicate id means one decision would silently answer two different findings."""
    seen: set[str] = set()
    for finding in ordered:
        if finding.id in seen:
            raise RailsError(f"duplicate finding id: {finding.id}")
        seen.add(finding.id)
    return ordered


def build_inventory(src: Source) -> dict[str, Any]:
    findings = build_findings(src)
    tables = src.migratable_tables()
    counts = {t["table"]: t for t in src.counts["tables"]}

    collections = [
        {
            "table": table["name"],
            "model": (src.model_for_table(table["name"]) or {}).get("name"),
            "columns": len(table["columns"]),
            "indexes": len(table.get("indexes") or []),
            "rows": (counts.get(table["name"]) or {}).get("unscoped_count"),
            "rowsHiddenByDefaultScope": (counts.get(table["name"]) or {}).get(
                "hidden_by_default_scope"
            ),
        }
        for table in sorted(tables, key=lambda t: t["name"])
    ]

    severities = [f.severity for f in findings]
    return {
        "zigbaseRailsInventory": INVENTORY_VERSION,
        "sourceMode": src.mode,
        "railsVersion": src.versions.get("rails_version"),
        "rubyVersion": src.versions.get("ruby_version"),
        "adapter": src.versions.get("adapter"),
        "schemaFormat": src.versions.get("schema_format"),
        "apiOnly": src.versions.get("api_only"),
        "databaseSha256": sha256_file(src.database) if src.database else None,
        "collections": collections,
        "findings": [f.to_dict() for f in findings],
        "summary": {
            "collections": len(collections),
            "blockers": severities.count("blocker"),
            "decisions": severities.count("decision"),
            "info": severities.count("info"),
        },
    }


# ---------------------------------------------------------------------------
# Decisions
# ---------------------------------------------------------------------------


def load_decisions(path: Path) -> dict[str, Decision]:
    return load_decisions_from_value(read_json(path, label="decisions"))


def load_decisions_from_value(value: Any) -> dict[str, Decision]:
    if not isinstance(value, dict) or set(value) != {
        "zigbaseRailsDecisions",
        "decisions",
    }:
        raise RailsError(
            "decisions must be an object with exactly "
            "'zigbaseRailsDecisions' and 'decisions'"
        )
    if value["zigbaseRailsDecisions"] != DECISIONS_VERSION:
        raise RailsError(
            f"unsupported decisions version: {value['zigbaseRailsDecisions']!r}"
        )
    entries = value["decisions"]
    if not isinstance(entries, list):
        raise RailsError("decisions.decisions must be an array")

    out: dict[str, Decision] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise RailsError(f"decisions[{index}] must be an object")
        where = f"decisions[{index}]"
        fid = required_string(entry, "id", where)
        if fid in out:
            raise RailsError(f"duplicate decision for finding {fid!r}")
        artifact = entry.get("artifact")
        if artifact is not None and (
            not isinstance(artifact, str) or not artifact.strip()
        ):
            # Whitespace counts as empty. A `" "` expression artifact passed every check
            # and then resolved to Locked on all five actions -- the silent outcome the
            # decision contract exists to prevent, and the one direction an operator
            # reviewing a rule would never think to double-check.
            raise RailsError(
                f"{where}.artifact must be a non-empty string when present"
            )
        out[fid] = Decision(
            id=fid,
            choice=required_string(entry, "choice", where),
            rationale=required_string(entry, "rationale", where),
            artifact=artifact,
        )
    return out


def _artifact_is_inline(fid: str, choice: str) -> bool:
    """Is this decision's artifact the replacement TEXT, or a path to a file?

    Deciding by CHOICE was ambiguous: `replacement` means a predicate string on a
    partial-index finding and a file path everywhere else. The finding says which.
    """
    if choice == "expression":
        return True  # an access rule; the artifact IS the rule
    if choice == "rename":
        return True  # the artifact IS the new collection name
    parts = split_id(fid)
    return parts[0] == "index" and parts[-1] == "where"


def _refuse_contradictory_decisions(decisions: dict[str, Decision]) -> None:
    """One subject, two decisions that cannot both be honoured.

    A single column or attachment can carry more than one blocker at once -- a name that
    both collides with a sibling and is engine-owned, say -- and each is decided
    separately. Renaming it under one and dropping it under the other left the outcome
    to whichever consumer ran last; two renames left it to the ORDER OF LINES in the
    decisions file. Tables have been refused for exactly this since early on; the
    per-subject namespaces had no equivalent.
    """
    by_subject: dict[tuple[str, str, str], list[Decision]] = {}
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) == 4 and parts[0] in ("column", "attachment"):
            by_subject.setdefault((parts[0], parts[1], parts[2]), []).append(decision)
    for (kind, table, subject), taken in sorted(by_subject.items()):
        choices = {d.choice for d in taken}
        # EVERY non-omit choice in these namespaces asserts the subject migrates --
        # `keep` on a credential column, `hook` on a default, `rename` on a name. Only
        # `rename` was checked, so a reviewed `keep` beside an omit was recorded and
        # then silently discarded, because `_omitted_columns` matches any suffix.
        keeping = sorted(choices - {"omit"})
        if "omit" in choices and keeping:
            raise RailsError(
                f"the {kind} {table}.{subject!r} is omitted and also "
                f"{', '.join(repr(c) for c in keeping)}; those decisions contradict "
                f"each other, so neither can be honoured"
            )
        renames = {(d.artifact or "").strip() for d in taken if d.choice == "rename"}
        if len(renames) > 1:
            raise RailsError(
                f"the {kind} {table}.{subject!r} is renamed to more than one name "
                f"({', '.join(sorted(repr(r) for r in renames))}); which one applies "
                f"would depend on the order of the decisions file"
            )


def reconcile(
    findings: list[Finding],
    decisions: dict[str, Decision],
    *,
    artifact_root: Path | None = None,
) -> None:
    """Every finding needs a decision; every decision needs a finding."""
    _refuse_contradictory_decisions(decisions)
    by_id = {f.id: f for f in findings}
    # `info` findings are reported, not adjudicated: there is nothing for an operator to
    # choose. Requiring a decision for one would be busywork that devalues the real ones.
    actionable = {f.id for f in findings if f.severity in ("blocker", "decision")}
    missing = sorted(actionable - set(decisions))
    if missing:
        raise RailsError(
            "no decision recorded for: "
            + ", ".join(missing[:20])
            + (f" (and {len(missing) - 20} more)" if len(missing) > 20 else "")
        )
    unknown = sorted(set(decisions) - set(by_id))
    if unknown:
        raise RailsError("decisions reference unknown findings: " + ", ".join(unknown))

    for fid, decision in sorted(decisions.items()):
        finding = by_id[fid]
        if finding.choices and decision.choice not in finding.choices:
            raise RailsError(
                f"decision {fid!r} chose {decision.choice!r}; "
                f"expected one of {', '.join(finding.choices)}"
            )
        if finding.requires_artifact and decision.choice not in (
            "omit",
            "out-of-scope",
        ):
            if not decision.artifact:
                raise RailsError(
                    f"decision {fid!r} replaces behavior and needs a typed artifact"
                )
        # Some choices assert that something was BUILT -- a hook, a rule, a typed route.
        # Recording one with no artifact documents an implementation that does not exist,
        # which is worse than an honest `omit`. `expression` is the sharpest case: without
        # its artifact `_rule_for` returns None, which ZigBase reads as Locked, so a
        # reviewed decision to open access ships as the exact opposite of itself.
        inline = _artifact_is_inline(fid, decision.choice)
        if inline and decision.artifact:
            continue  # the artifact IS the text (a rule, a predicate), not a path
        if decision.choice in IMPLEMENTATION_CHOICES and not decision.artifact:
            raise RailsError(
                f"decision {fid!r} chose {decision.choice!r}, which asserts a replacement "
                f"exists, but carries no artifact naming it"
            )
        # A path to a file that does not exist is the same lie as no artifact at all,
        # just harder to notice. Only checked when the caller says where artifacts live.
        if artifact_root is not None and decision.artifact and not inline:
            target = artifact_root / decision.artifact
            if not target.is_file():
                raise RailsError(
                    f"decision {fid!r} names artifact {decision.artifact!r}, which does "
                    f"not exist under {artifact_root}"
                )


# ---------------------------------------------------------------------------
# Value coercion
# ---------------------------------------------------------------------------

# Rails stores naive UTC in SQLite: "2024-01-15 09:00:00[.ffffff]". ZigBase wants
# RFC3339. Nothing here consults the clock or a local timezone.
# Seconds are optional in the engine's own grammar (src/datetime.zig), and `\Z` rather
# than `$` so a trailing newline is not silently accepted and normalized away.
_RAILS_DATETIME = re.compile(
    r"\A(?P<date>\d{4}-\d{2}-\d{2})(?:[ T](?P<time>\d{2}:\d{2}(?::\d{2})?)"
    r"(?P<frac>\.\d+)?(?P<tz>Z|[+-]\d{2}:?\d{2})?)?\Z"
)


def _is_leap(year: int) -> bool:
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)


def _days_in_month(year: int, month: int) -> int:
    if month == 2 and _is_leap(year):
        return 29
    return (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)[month - 1]


_EMITTED_TIMESTAMP = re.compile(r"\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z\Z")


def _emitted_timestamp(source: Any, emitted: str) -> str:
    """Last gate before a timestamp leaves this function.

    The target's parser is fixed-width, so a single unpadded field is rejected outright
    -- and that is precisely how a pre-1000 year escaped: well-formed to every check
    upstream, malformed on the way out, hashed and certified either way. One assertion
    on the emitted text catches this and anything like it.
    """
    if not _EMITTED_TIMESTAMP.match(emitted):
        raise RailsError(
            f"converting {source!r} produced {emitted!r}, which is not a timestamp the "
            f"target can parse"
        )
    return emitted


def _days_from_civil(year: int, month: int, day: int) -> int:
    """Howard Hinnant's algorithm, as `src/datetime.zig` uses; floor division throughout
    so it stays correct for year 0 and earlier."""
    year -= month <= 2
    # The published algorithm compensates for C's TRUNCATING division; Python's `//`
    # already floors, so the compensation double-counts on negative years -- at every
    # adjusted year of -2 or below, in fact. Only -1 is reachable here (input year 0000
    # with month <= 2), and there the two forms happen to agree; in `_civil_from_days`
    # the same compensation WAS reachable and shifted year 0 by a day. Both use plain
    # floor division so the pair stays symmetric and correct by construction.
    era = year // 400
    year_of_era = year - era * 400
    month_position = month + (-3 if month > 2 else 9)
    day_of_year = (153 * month_position + 2) // 5 + day - 1
    day_of_era = year_of_era * 365 + year_of_era // 4 - year_of_era // 100 + day_of_year
    return era * 146097 + day_of_era - 719468


def _civil_from_days(days: int) -> tuple[int, int, int]:
    days += 719468
    era = days // 146097  # floor division: see the note in `_days_from_civil`
    day_of_era = days - era * 146097
    year_of_era = (
        day_of_era - day_of_era // 1460 + day_of_era // 36524 - day_of_era // 146096
    ) // 365
    year = year_of_era + era * 400
    day_of_year = day_of_era - (
        365 * year_of_era + year_of_era // 4 - year_of_era // 100
    )
    month_position = (5 * day_of_year + 2) // 153
    day = day_of_year - (153 * month_position + 2) // 5 + 1
    month = month_position + (3 if month_position < 10 else -9)
    return year + (month <= 2), month, day


def _refuse_impossible_datetime(value: str, date: str, time: str | None) -> None:
    """Range-check the components, mirroring src/datetime.zig.

    The pattern above is digit-shaped only, so `0000-00-00 00:00:00` -- the canonical
    legacy-MySQL zero date, and exactly the vintage of application this converter is
    for -- passed straight through, was hashed and certified, and then killed the import
    partway with earlier collections already committed. `2024-02-30` and `24:00:00` did
    the same.

    Deliberately NOT `datetime.datetime`: its minimum year is 1, while the engine
    accepts year 0000, so validating that way would refuse values the target imports.
    """
    year, month, day = (int(part) for part in date.split("-"))
    if not 1 <= month <= 12 or not 1 <= day <= _days_in_month(year, month):
        raise RailsError(f"impossible date: {value!r}")
    if time is not None:
        parts = [int(part) for part in time.split(":")]
        hour, minute, second = parts[0], parts[1], (parts[2] if len(parts) > 2 else 0)
        if hour > 23 or minute > 59 or second > 59:
            raise RailsError(f"impossible time of day: {value!r}")


def to_rfc3339(value: Any) -> str | None:
    """Normalize a Rails timestamp to RFC3339 UTC without losing or inventing anything.

    Two things this must not do, both of which corrupt rather than merely degrade:
    silently drop sub-second precision, and relabel an offset as UTC. Rails writes naive
    UTC into SQLite, but `structure.sql` dumps, Postgres exports and hand-edited fixtures
    all carry offsets, and rewriting `09:00+05:00` as `09:00Z` moves the row five hours.
    """
    if value is None or value == "":
        return None
    if not isinstance(value, str):
        raise RailsError(f"expected a datetime string, got {type(value).__name__}")
    match = _RAILS_DATETIME.match(value)
    if not match:
        raise RailsError(f"unrecognized datetime value: {value!r}")

    _refuse_impossible_datetime(value, match.group("date"), match.group("time"))

    # A `date` column has no time part. TYPE_MAP advertises `date` as supported, so
    # raising on `2024-01-15` made a declared-supported type unextractable; midnight UTC
    # is the only reading that does not invent information.
    if match.group("time") is None:
        return f"{match.group('date')}T00:00:00Z"

    frac = match.group("frac") or ""
    tz = match.group("tz")
    time = match.group("time")
    if len(time) == 5:  # seconds are optional in the grammar; the target wants them
        if match.group("frac"):
            # `09:30.5` is fractional MINUTES in ISO 8601, and the engine refuses the
            # shape outright. Reading it as `.5` seconds would invent a meaning the
            # source never had.
            raise RailsError(f"a fractional part needs a seconds field: {value!r}")
        time = f"{time}:00"
    if tz in (None, "Z"):
        # Already UTC (Rails' own on-disk shape); no arithmetic, so no rounding.
        return _emitted_timestamp(value, f"{match.group('date')}T{time}{frac}Z")

    # An explicit offset has to be converted, not stripped -- but NOT through
    # `datetime`: `strftime('%Y')` does not zero-pad on glibc, so a pre-1000 year came
    # out as `499-12-31T...`, which the target's fixed-width parser rejects outright;
    # and `astimezone` raises OverflowError at the edges of its own supported range,
    # which is narrower than the engine's. Component arithmetic has neither problem and
    # matches what `src/datetime.zig` does.
    sign = -1 if tz[0] == "-" else 1
    digits = tz[1:].replace(":", "")
    offset_hours, offset_minutes = int(digits[:2]), int(digits[2:])
    # The engine refuses these (src/datetime.zig), and silently converting a corrupt or
    # typo'd offset MOVES the row instead of halting -- the one thing this tool must
    # never do. `fromisoformat` used to reject `+30:00` for us; nothing did after the
    # component rewrite, and nothing ever rejected `+05:99`.
    if offset_hours > 23 or offset_minutes > 59:
        raise RailsError(f"impossible UTC offset: {value!r}")
    offset = sign * (offset_hours * 3600 + offset_minutes * 60)
    year, month, day = (int(part) for part in match.group("date").split("-"))
    hour, minute, second = (int(part) for part in time.split(":"))
    moment = (
        _days_from_civil(year, month, day) * 86400
        + hour * 3600
        + minute * 60
        + second
        - offset
    )
    days, rest = divmod(moment, 86400)
    year, month, day = _civil_from_days(days)
    hour, rest = divmod(rest, 3600)
    minute, second = divmod(rest, 60)
    if not 0 <= year <= 9999:
        raise RailsError(f"datetime moves outside the representable range: {value!r}")
    return _emitted_timestamp(
        value,
        f"{year:04d}-{month:02d}-{day:02d}T{hour:02d}:{minute:02d}:{second:02d}{frac}Z",
    )


def coerce(
    value: Any,
    field_type: str,
    enum: dict[str, Any] | None,
    *,
    number_mode: str | None = None,
) -> Any:
    if value is None:
        return None
    if enum is not None:
        # An integer-backed enum stores the ordinal; the label is the meaning, and the
        # label is what the target's select field holds.
        labels = {v: k for k, v in (enum.get("values") or {}).items()}
        if value in labels:
            return labels[value]
        if value in (enum.get("values") or {}):
            return value
        raise RailsError(f"value {value!r} is not a member of the enum")
    if field_type == "date":
        return to_rfc3339(value)
    if field_type == "bool":
        # Older Rails/SQLite schemas store booleans as 't'/'f' text. `bool('f')` is True,
        # which silently inverts every false value in an upgraded application.
        #
        # This mapping is deliberately NOT Rails': `cast_value` treats anything outside
        # FALSE_VALUES as true, so it reads `banana` as true and, because its emptiness
        # test is the exact `== ""`, reads `  false  ` as true as well. Guessing true for
        # a value nobody recognizes is the behavior an application can afford and a
        # migration cannot, so unknown values are refused and surrounding whitespace is
        # stripped before the comparison. Where Rails IS followed is the empty string,
        # which it reads as nil rather than false — see below.
        #
        # The false side is matched case-SENSITIVELY, against Rails' own set. Folding
        # case there inverts values instead of normalizing them: `FALSE_VALUES` holds
        # `false` and `FALSE` but not `False`, so Rails reads `False` as TRUE, and a
        # `.lower()` turned it into False — silently, and in exactly the direction this
        # branch opens by warning about. The true side may still be folded, because
        # anything outside the set is true to Rails whatever its case.
        if isinstance(value, str):
            stripped = value.strip()
            lowered = stripped.lower()
            # The false side is compared against the RAW value, not the stripped one,
            # for the same reason it is compared case-sensitively: Rails does not strip
            # either. `cast_value(" false ")` is not `""` and is not in FALSE_VALUES, so
            # the application read that row as TRUE, and quietly writing False for it is
            # the very inversion the case rule above exists to prevent. Padding is only
            # safe to ignore on the true side, where every spelling is true anyway.
            # `''` is NULL, not false. `ActiveModel::Type::Boolean#cast_value` returns
            # nil for the empty string and only then consults FALSE_VALUES, so the
            # application read this row as "unset" (whitespace-only lands here too, by
            # the strip above; Rails would call that true, and "a space means true" is
            # not a reading worth preserving). Folding it to false is a side taken
            # on the operator's behalf on a column whose whole point is which side it
            # is on -- and it is silent, because `false` is a perfectly valid value.
            if lowered == "":
                return None
            if value in RAILS_FALSE_STRINGS:
                return False
            if lowered in ("t", "true", "1", "on"):
                return True
            if lowered in {word.lower() for word in RAILS_FALSE_STRINGS}:
                raise RailsError(
                    f"boolean value {value!r} spells a false word in a form Rails does "
                    f"not recognize as false — it differs from `"
                    f"{', '.join(sorted(RAILS_FALSE_STRINGS))}` by case or surrounding "
                    f"whitespace — so the application read it as TRUE; fix the value "
                    f"rather than let either reading be chosen here"
                )
            raise RailsError(f"unrecognized boolean value: {value!r}")
        return bool(value)
    if field_type == "number":
        # SQLite has dynamic typing: an INTEGER column will hold the text 'banana'
        # without complaint. The inventory says number, the data disagrees, and passing
        # it through emitted a JSON string into a number field -- refused by the target
        # partway through the import, after earlier collections had committed.
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise RailsError(
                f"a number column holds {value!r}, which is not a number; the inventory "
                f"and the database disagree about this column"
            )
        if isinstance(value, float) and not math.isfinite(value):
            # SQLite stores a REAL infinity happily. JSON cannot represent one, and the
            # bundle would be malformed while `hashes.json` certified it.
            raise RailsError(
                f"a number column holds {value!r}, which JSON cannot represent"
            )
        if number_mode == "int" and isinstance(value, float) and not value.is_integer():
            # SQLite keeps a REAL's storage class even in an INTEGER column, and the
            # target refuses a fractional value for an int-mode field.
            raise RailsError(
                f"an integer column holds {value!r}; the target refuses a fractional "
                f"value for an integer field"
            )
        if (
            number_mode == "int"
            and isinstance(value, float)
            and not -(2**63) < value < 2**63
        ):
            # Only the REAL storage class can get here: SQLite integers are already
            # i64. The target renders the float and then overflows converting it.
            raise RailsError(
                f"an integer column holds {value!r}, which is outside the range the "
                f"target can store"
            )
        return value
    if field_type == "json":
        # SQLite stores JSON as TEXT, so the driver hands back a string. Passing it
        # through emits `"{\"a\":1}"` -- a JSON *string* -- where the target expects an
        # object. Parse it; a value that does not parse is a real inconsistency and must
        # not be smuggled through as text.
        if isinstance(value, (dict, list)):
            return value
        if isinstance(value, str):
            try:
                return json.loads(value)
            except json.JSONDecodeError as exc:
                raise RailsError(
                    f"a json column holds text that is not JSON: {value[:60]!r}"
                ) from exc
        return value
    if isinstance(value, bytes):
        raise RailsError(
            f"a binary value ({value[:24]!r}{'…' if len(value) > 24 else ''}) cannot be "
            f"represented as text"
        )
    return value if isinstance(value, str) else str(value)


# ---------------------------------------------------------------------------
# Schema document
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Mapped:
    """One source table, resolved into everything extraction needs."""

    table: str
    collection: str
    is_auth: bool
    model: dict[str, Any] | None
    columns: list[dict[str, Any]]
    indexes: list[dict[str, Any]]
    fields: list[dict[str, Any]]
    relations: dict[str, str]
    enums: dict[str, dict[str, Any]]
    digest_column: str | None
    attachments: dict[str, str]
    # relation column -> the field name actually emitted for it; `author_id` normally
    # becomes `author`, but keeps its full name where that would collide.
    field_names: dict[str, str]
    # attachment name -> the field name emitted for it; kept apart from `field_names`
    # because a column may legitimately carry the same name.
    attachment_names: dict[str, str]


def _auth_tables(src: Source) -> dict[str, str]:
    """table -> digest column, for every table that carries a password digest."""
    out: dict[str, str] = {}
    # Group by TABLE first: two Active Record models can share one table, and judging
    # each entry alone let the genuinely ambiguous case through with the winner decided
    # by which model name sorted first.
    by_table: dict[str, dict[str, set[str]]] = {}
    for entry in src.auth.get("has_secure_password") or []:
        table = entry.get("table_name")
        digests = entry.get("digest_columns") or []
        if not table or not digests:
            continue
        grouped = by_table.setdefault(
            table, {"attributes": set(), "digests": set(), "legacy": False}
        )
        grouped["digests"].update(digests)
        grouped["attributes"].update(entry.get("attributes") or [])
        # One pre-1.1 entry means the table has no trustworthy disambiguation at all.
        grouped["legacy"] = grouped["legacy"] or "attributes" not in entry

    for table, grouped in sorted(by_table.items()):
        digests = sorted(grouped["digests"])
        attributes = [] if grouped["legacy"] else sorted(grouped["attributes"])
        # `digest_columns` is every `*_digest` column on the table, which on the most
        # ordinary Rails app is several: `remember_digest`, `activation_digest` and
        # `reset_digest` sit beside `password_digest` and are digests of live TOKENS,
        # not the login credential. Refusing on their count blocked that whole shape at
        # `inventory`, with no findings file and so no decision to record. `attributes`
        # is the disambiguation the extractor already did: it lists only the prefixes
        # that have a real `authenticate_*` reader.
        if len(attributes) > 1:
            raise RailsError(
                f"{table} has several secure passwords "
                f"({', '.join(f'{a}_digest' for a in sorted(attributes))}); which one is "
                f"the login credential must be decided, not guessed"
            )
        if attributes:
            column = f"{attributes[0]}_digest"
            if column not in digests:
                raise RailsError(
                    f"{table} declares `has_secure_password :{attributes[0]}` but has no "
                    f"{column!r} column; the inventory contradicts itself"
                )
            out[table] = column
        elif len(digests) > 1:
            # An inventory from an older extractor, with no `attributes` to go on.
            raise RailsError(
                f"{table} has several password digests ({', '.join(digests)}); which "
                f"one is the login credential must be decided, not guessed"
            )
        else:
            out[table] = digests[0]
    for entry in (src.auth.get("devise") or {}).get("models") or []:
        table = entry.get("table_name")
        if not table:
            continue
        if table in out and out[table] != "encrypted_password":
            # Both authentication stacks on one model. Which column is the login
            # credential is exactly as unknowable as it is with two digests, and
            # `setdefault` answered it silently by keeping whichever was seen first.
            raise RailsError(
                f"{table} carries both `has_secure_password` ({out[table]}) and Devise "
                f"(encrypted_password); which one is the login credential must be "
                f"decided, not guessed"
            )
        out.setdefault(table, "encrypted_password")
    return out


def _serialized_choices(decisions: dict[str, Decision]) -> dict[str, dict[str, str]]:
    """model -> attribute -> chosen representation, from `model.<M>.serialized.<attr>`."""
    out: dict[str, dict[str, str]] = {}
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) == 4 and parts[0] == "model" and parts[2] == "serialized":
            out.setdefault(parts[1], {})[parts[3]] = decision.choice
    return out


def _encrypted_columns(src: Source) -> dict[str, set[str]]:
    """table -> encrypted attribute names.

    Ciphertext is bound to the source key and is meaningless in the target, so it is
    dropped unconditionally. The operator's decision governs what *replaces* the
    attribute, never whether the ciphertext travels -- emitting it would ship an opaque
    blob into the target dressed as data.
    """
    out: dict[str, set[str]] = {}
    for model in src.models["models"]:
        table = model.get("table_name")
        names = {a["attribute"] for a in model.get("encrypted_attributes") or []}
        if table and names:
            out.setdefault(table, set()).update(names)
    return out


# Suffixes of `table.<name>.<suffix>` findings whose `omit` means "do not migrate this
# table at all". Every other table-scoped finding is about one aspect of it, so matching
# on the `table.` prefix alone made `table.users.check_constraints: omit` silently drop
# the entire users table -- direct data loss from a decision about constraints.
TABLE_OMITTING_FINDINGS = frozenset(
    {
        "identifier",
        "primary_key",
        "no_timestamps",
        "nullable_timestamps",
        "foreign_keys",
    }
)


def _sti_omitted_tables(src: Source, decisions: dict[str, Decision]) -> set[str]:
    """`model.<M>.sti: omit` names a MODEL; the table it drops has to be resolved."""
    out: set[str] = set()
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) == 3 and parts[0] == "model" and parts[2] == "sti":
            if decision.choice != "omit":
                continue
            model = next(
                (m for m in src.models["models"] if m["name"] == parts[1]), None
            )
            if model and model.get("table_name"):
                out.add(model["table_name"])
    return out


def _polymorphic_omitted_columns(
    src: Source, decisions: dict[str, Decision]
) -> set[tuple[str, str]]:
    """`association.<M>.<a>.polymorphic: omit` drops the `_type`/`_id` pair."""
    out: set[tuple[str, str]] = set()
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) != 4 or parts[0] != "association" or parts[3] != "polymorphic":
            continue
        if decision.choice != "omit":
            continue
        model = next((m for m in src.models["models"] if m["name"] == parts[1]), None)
        if not model or not model.get("table_name"):
            continue
        association = next(
            (a for a in model.get("associations") or [] if a["name"] == parts[2]), None
        )
        # The exporter records the real columns. Deriving `<name>_type`/`<name>_id` was
        # a guess that silently dropped nothing whenever they differ -- e.g.
        # `belongs_to :subject, polymorphic: true, foreign_key: :flaggable_id`.
        column = (association or {}).get("foreign_key") or f"{parts[2]}_id"
        recorded_type = (association or {}).get("foreign_type")
        # `subject_ref` would otherwise become `subject__type`. Only strip a real `_id`.
        base = column[:-3] if column.endswith("_id") else column
        type_column = recorded_type or f"{base}_type"
        out.add((model["table_name"], column))
        out.add((model["table_name"], type_column))
    return out


def _renamed_tables(decisions: dict[str, Decision]) -> dict[str, str]:
    """`table.<t>.identifier: rename` carries the new name as its artifact."""
    out: dict[str, str] = {}
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if (
            len(parts) == 3
            and parts[0] == "table"
            and parts[2] == "identifier"
            and decision.choice == "rename"
            and decision.artifact
        ):
            out[parts[1]] = decision.artifact.strip()
    return out


# What a `dependent` option does to the CHILD rows when the owner is destroyed.
# `delete_all` is the has_many spelling, `delete` the has_one one, and `destroy_async`
# is Rails' recommendation for large associations -- all three remove the children, so
# all three are cascades in effect.
CASCADING_DEPENDENTS = frozenset({"destroy", "delete_all", "destroy_async", "delete"})


def _is_direct_child_association(association: dict[str, Any]) -> bool:
    """Does `(table_name, foreign_key)` name rows this owner's deletion cascades to?

    Only for a direct `has_many`/`has_one`. A `has_many :through` delegates its foreign
    key to the SOURCE reflection, so it exports the intermediate model's own pair while
    its `dependent` fires on a different table's deletion entirely -- and a `belongs_to`
    with `dependent` runs the opposite way, destroying the PARENT when the child goes.
    Reading the pair without the macro made both look like ordinary cascades.
    """
    return association.get("through") is None and association.get("macro") in (
        "has_many",
        "has_one",
    )


def _cascades_children(association: dict[str, Any]) -> bool:
    return str(association.get("dependent") or "") in CASCADING_DEPENDENTS


def _restrict_protected(src: Source) -> set[tuple[str, str]]:
    """(table, column) pairs some model declares `restrict_with_*` on.

    A restrict declaration from ANY model protects those rows: guarding only within the
    decided model let an STI sibling's `dependent: :destroy` cascade rows its parent
    explicitly refuses to delete.
    """
    protected: set[tuple[str, str]] = set()
    for model in src.models["models"]:
        for association in model.get("associations") or []:
            if not _is_direct_child_association(association):
                continue
            if str(association.get("dependent") or "").startswith("restrict"):
                target = association.get("table_name")
                column = association.get("foreign_key")
                if target and column:
                    protected.add((target, column))
    return protected


def _cascadable_pairs(model: dict[str, Any]) -> set[tuple[str, str]]:
    """(table, column) pairs a `cascade` decision on this model would act on."""
    out: set[tuple[str, str]] = set()
    for association in model.get("associations") or []:
        if not _is_direct_child_association(association) or not _cascades_children(
            association
        ):
            continue
        target = association.get("table_name")
        column = association.get("foreign_key")
        if target and column:
            out.add((target, column))
    return out


def _cascade_decisions(
    src: Source, decisions: dict[str, Decision]
) -> set[tuple[str, str]]:
    """`model.<M>.dependent: cascade` -> (table, column) pairs that cascade on delete."""
    out: set[tuple[str, str]] = set()
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) != 3 or parts[0] != "model" or parts[2] != "dependent":
            continue
        if decision.choice != "cascade":
            continue
        model = next((m for m in src.models["models"] if m["name"] == parts[1]), None)
        if not model:
            continue
        for association in model.get("associations") or []:
            # ONLY the cascading dependents mean "remove the children".
            # `restrict_with_error` and `restrict_with_exception` mean the opposite --
            # Rails REFUSES the delete -- so cascading them would destroy rows the
            # source protects. A through or belongs_to association is not this model's
            # child cascade at all, whatever its pair looks like.
            if not _is_direct_child_association(association) or not _cascades_children(
                association
            ):
                continue
            target = association.get("table_name")
            column = association.get("foreign_key")
            # The relation must point back at THIS model's table, and must actually be
            # emitted -- a global set of bare pairs flipped `cascadeDelete` on relations
            # into other tables entirely.
            if (
                target
                and column
                and _relation_emitted_for(src, target, column, model.get("table_name"))
                is None
            ):
                out.add((target, column))

    return out - _restrict_protected(src)


def _declared_relations(
    src: Source, decisions: dict[str, Decision], table: str
) -> dict[str, str]:
    """column -> target table, for associations an operator promoted to relations."""
    out: dict[str, str] = {}
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) != 4 or parts[0] != "association" or parts[3] != "nofk":
            continue
        if decision.choice != "relation":
            continue
        model = next((m for m in src.models["models"] if m["name"] == parts[1]), None)
        if model is None or model.get("table_name") != table:
            continue
        association = next(
            (a for a in model.get("associations") or [] if a["name"] == parts[2]), None
        )
        if association is None:
            continue
        target = association.get("table_name")
        column = association.get("foreign_key")
        if target and column:
            # Key by COLUMN: `author_id` and `editor_id` both point at `users`, and
            # keying by target silently dropped one of them.
            if out.get(column, target) != target:
                # Two models on one table promoting the SAME column to DIFFERENT
                # targets. Reachable through STI, where a base class and a subclass each
                # declare a `belongs_to` on it and each gets its own finding. Assigning
                # would let whichever decision the file happens to list last win, which
                # is the one thing this converter never does quietly -- every other
                # incompatible pair is refused by name.
                raise RailsError(
                    f"{table}.{column} is decided to become a relation to both "
                    f"{out[column]!r} and {target!r}; a column carries one relation, so "
                    f"those decisions contradict each other"
                )
            out[column] = target
    return out


def _renamed_attachments(decisions: dict[str, Decision]) -> dict[tuple[str, str], str]:
    """(table, attachment) -> the field name an operator supplied for it.

    Separate from the column map on purpose: both are keyed by NAME, and a column and
    an attachment can legitimately share one -- which is the whole point of the
    collision finding. A single map applied the rename to both and collided again.
    """
    out: dict[tuple[str, str], str] = {}
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) == 4 and parts[0] == "attachment" and decision.choice == "rename":
            replacement = (decision.artifact or "").strip()
            # `is_auth=False` is the substantive part: an attachment is a file field,
            # never a collection's own identity, so no engine-owned name is available to
            # it on any table. (`literal` cannot change that outcome here.)
            if not IDENTIFIER.match(replacement) or _reserved_here(
                replacement, is_auth=False, literal=False
            ):
                raise RailsError(
                    f"rename of the attachment {parts[1]}.{parts[2]!r} to "
                    f"{replacement!r} is not a usable ZigBase field name"
                )
            out[(parts[1], parts[2])] = replacement
    return out


def _omitted_attachments(decisions: dict[str, Decision]) -> set[tuple[str, str]]:
    """(table, attachment) pairs an `attachment.…` decision says to drop.

    Kept out of the `column.` namespace deliberately: the colliding NAME belongs to a
    real column as well, and an omit here must drop only the attachment.
    """
    out: set[tuple[str, str]] = set()
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) == 4 and parts[0] == "attachment" and decision.choice == "omit":
            out.add((parts[1], parts[2]))
    return out


def _omitted_columns(decisions: dict[str, Decision]) -> set[tuple[str, str]]:
    """(table, column) pairs a decision says to drop.

    Column-scoped findings offered `omit` and nothing consumed it, so a credential column
    decided away was still emitted and its values still shipped -- the finding existed
    precisely because those columns must never migrate.
    """
    dropped: set[tuple[str, str]] = set()
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) == 4 and parts[0] == "column" and decision.choice == "omit":
            dropped.add((parts[1], parts[2]))
    return dropped


def _omitted_tables(decisions: dict[str, Decision]) -> set[str]:
    omitted: set[str] = set()
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if (
            len(parts) == 3
            and parts[0] == "table"
            and parts[2] in TABLE_OMITTING_FINDINGS
            and decision.choice == "omit"
        ):
            omitted.add(parts[1])
    return omitted


def _cascade_blocked_by(
    src: Source,
    decisions: dict[str, Decision],
    table: str,
    column: str,
    owner_table: str | None,
    *,
    omitted: set[str],
    dropped_columns: set[tuple[str, str]],
    protected: set[tuple[str, str]] | None = None,
) -> str | None:
    """Why no cascade can ride `(table, column)` under these decisions, or None.

    The ONE place that answers this. It used to be computed independently in the
    emission, in the honoured check, and in each new decision's consult -- so every new
    decision kind hand-copied the guard list, and round 31 both proved that gets missed
    and then missed it again in the same commit.
    """
    if table in omitted:
        return "its table is omitted"
    structural = _relation_emitted_for(src, table, column, owner_table)
    if structural is not None:
        return structural
    untrusted = decisions.get("schema.foreign_keys.unsupported")
    if untrusted is not None and untrusted.choice == "omit":
        return (
            "this schema's foreign keys were decided untrustworthy, so no relation is "
            "derived from one"
        )
    if (table, column) in dropped_columns:
        return "the column it rides on is omitted"
    target_key = decisions.get(finding_id("fk", table, column, "target_key"))
    if target_key is not None and target_key.choice == "omit":
        return "the relation was dropped for pointing at a column other than `id`"
    action = decisions.get(finding_id("fk", table, column, "action"))
    if action is not None and action.choice == "omit":
        return "its foreign-key action was dropped"
    if protected is not None and (table, column) in protected:
        return "another model refuses the delete"
    return None


def _refuse_inert_decisions(src: Source, decisions: dict[str, Decision]) -> None:
    """A decision that keeps something, beside one elsewhere that drops it.

    `_refuse_contradictory_decisions` groups by subject, which cannot see an omit that
    reaches a subject from ANOTHER namespace: a polymorphic association drops the two
    columns it names, and a table-level omit drops everything. Deliberately narrow --
    reconcile forces a decision on every column finding of a table that is later
    omitted, and those are inert but harmless, so only a choice that positively asserts
    the subject migrates counts.
    """
    # A decision about a table that is going away entirely is inert but harmless --
    # reconcile FORCES one for every column finding on it -- so neither scan below looks
    # at those tables. Refusing there is noise the operator cannot act on meaningfully.
    omitted = _omitted_tables(decisions) | _sti_omitted_tables(src, decisions)
    dropped_columns = {
        pair
        for pair in _polymorphic_omitted_columns(src, decisions)
        | _omitted_columns(decisions)
        if pair[0] not in omitted
    }
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if (
            len(parts) == 4
            and parts[0] == "column"
            and decision.choice != "omit"
            and (parts[1], parts[2]) in dropped_columns
        ):
            raise RailsError(
                f"{parts[1]}.{parts[2]!r} is {decision.choice!r} here, and another "
                f"decision drops that column; those decisions contradict each other"
            )

    # A `nofk: relation` promotes a column to a relation -- an assertion that it
    # migrates, arriving from the association namespace, which the per-subject grouping
    # cannot see.
    # A column the source itself cannot carry across counts too: encryption drops the
    # value, and the primary key becomes the record id. Promoting one is an assertion
    # that it migrates, so say so rather than filtering it away in silence.
    encrypted = _encrypted_columns(src)
    digests = _auth_tables(src)
    unmigratable = {
        (entry["name"], column)
        for entry in src.migratable_tables()
        for column in (
            encrypted.get(entry["name"], set())
            | _primary_key_names(entry)
            | set(TIMESTAMP_COLUMNS)
            | ({digests[entry["name"]]} if entry["name"] in digests else set())
        )
    }
    # `- omitted` is load-bearing for the `unmigratable` check below: the exemption
    # baked into `dropped_columns` bears only on the first refusal, so without this a
    # promotion on a doomed table was refused for a reason that no longer applies.
    for table in {t["name"] for t in src.migratable_tables()} - omitted:
        for column in _declared_relations(src, decisions, table):
            if (table, column) in dropped_columns:
                raise RailsError(
                    f"{table}.{column!r} is promoted to a relation, and also omitted; "
                    f"those decisions contradict each other"
                )
            if (table, column) in unmigratable:
                raise RailsError(
                    f"{table}.{column!r} is promoted to a relation, but its value "
                    f"cannot travel — it is encrypted, a primary key, a Rails timestamp "
                    f"or a password digest, none of which the bundle carries"
                )

    # `dependent: cascade` says these relations cascade on delete. Refused only when the
    # decision becomes FULLY inert: a cascade covers every child of one model, so
    # dropping ONE of them leaves the others to act on -- and `dependent` is a single
    # model-level decision, so refusing per pair would make "drop one child, cascade the
    # rest" inexpressible. Pairs with no database foreign key are excluded because the
    # finding's own text already tells the operator a cascade cannot cover them.
    # Per DECISION, not pooled: `cascaded` gathered every model's pairs together, so
    # whether one model's cascade was honoured depended on an unrelated model's choice,
    # and pre-filtering before the emptiness test made "everything filtered away" look
    # like "nothing was decided".
    protected = _restrict_protected(src)
    # The contradiction decision is a claim about one foreign key's delete behaviour, so
    # it needs the same guard list -- it was born with none of it.
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) != 4 or parts[3] != "cascade_vs_restrict":
            continue
        if decision.choice != "cascade":
            continue
        entry = next(
            (t for t in src.migratable_tables() if t["name"] == parts[1]), None
        )
        fk = next(
            (
                f
                for f in ((entry or {}).get("foreign_keys") or [])
                if f.get("column") == parts[2]
            ),
            None,
        )
        blocked = _cascade_blocked_by(
            src,
            decisions,
            parts[1],
            parts[2],
            (fk or {}).get("to_table"),
            omitted=omitted,
            dropped_columns=dropped_columns,
        )
        if blocked:
            raise RailsError(
                f"{parts[1]}.{parts[2]!r} is decided to keep its database cascade, but "
                f"{blocked}; those decisions contradict each other"
            )

    for fid, decision in decisions.items():
        parts = split_id(fid)
        if len(parts) != 3 or parts[0] != "model" or parts[2] != "dependent":
            continue
        if decision.choice != "cascade":
            continue
        model = next((m for m in src.models["models"] if m["name"] == parts[1]), None)
        if model is None:
            continue
        pairs = _cascadable_pairs(model)
        if not pairs:
            continue
        honoured = []
        blocked_because: list[str] = []
        for table, column in sorted(pairs):
            reason = _cascade_blocked_by(
                src,
                decisions,
                table,
                column,
                model.get("table_name"),
                omitted=omitted,
                dropped_columns=dropped_columns,
                protected=protected,
            )
            if reason:
                blocked_because.append(reason)
                continue
            honoured.append(f"{table}.{column}")
        if not honoured:
            raise RailsError(
                f"{parts[1]} is decided to cascade on delete, and not one of the "
                f"relations it covers can carry it "
                f"({', '.join(f'{t}.{c}' for t, c in sorted(pairs))}): "
                # Every distinct reason, not the first pair's: which one comes first
                # depends only on sort order, and the operator needs all of them. No
                # empty fallback: `pairs` is non-empty by the check above, and each pair
                # either records a non-empty reason or lands in `honoured`, so reaching
                # here with nothing to say is not a state this loop can be in.
                f"{'; '.join(sorted(set(blocked_because)))}; the "
                f"decision would be recorded and do nothing"
            )

    for fid, decision in decisions.items():
        parts = split_id(fid)
        # `rename` is caught by the both-renamed-and-omitted check below with a better
        # message; `separate-import` asserts the table is imported, and was inert.
        if (
            len(parts) == 3
            and parts[0] == "table"
            and parts[1] in omitted
            and decision.choice == "separate-import"
        ):
            raise RailsError(
                f"{parts[1]} is routed to its own import and also omitted; those "
                f"decisions contradict each other, so neither can be honoured"
            )


def map_tables(src: Source, decisions: dict[str, Decision]) -> list[Mapped]:
    _refuse_inert_decisions(src, decisions)
    auth_tables = _auth_tables(src)
    encrypted = _encrypted_columns(src)
    serialized_choice = _serialized_choices(decisions)
    omitted = _omitted_tables(decisions) | _sti_omitted_tables(src, decisions)
    # `omit` and `rename` on one table are contradictory; refuse rather than pick.
    both = omitted & set(_renamed_tables(decisions))
    if both:
        raise RailsError(
            f"these tables are both renamed and omitted: {', '.join(sorted(both))}"
        )
    dropped_columns = _omitted_columns(decisions) | _polymorphic_omitted_columns(
        src, decisions
    )
    renamed = _renamed_tables(decisions)
    renamed_columns = _renamed_columns(src, decisions)
    renamed_attachments = _renamed_attachments(decisions)
    dropped_attachments = _omitted_attachments(decisions)
    for original, replacement in sorted(renamed.items()):
        # The finding exists BECAUSE the old name failed this gate; accepting any string
        # as its replacement would just move the failure to `schema apply`.
        if not IDENTIFIER.match(replacement) or _is_reserved_collection_name(
            replacement
        ):
            raise RailsError(
                f"rename of {original!r} to {replacement!r} is not a usable ZigBase "
                f"collection name"
            )
    existing = {t["name"].lower() for t in src.migratable_tables()}
    collisions = sorted(name for name in renamed.values() if name.lower() in existing)
    if collisions:
        raise RailsError(
            f"rename would collide with existing collections: {', '.join(collisions)}"
        )
    if len({name.lower() for name in renamed.values()}) != len(renamed):
        raise RailsError("two tables were renamed to the same collection")
    cascading = _cascade_decisions(src, decisions)
    restrict_protected = _restrict_protected(src)
    # The adapter would not say whether it can read foreign keys, so the per-table
    # arrays are unknown rather than authoritative. `omit` on that blocker used to be
    # recorded and then ignored: every relation was still emitted from exactly the data
    # the finding said could not be trusted. Honour it -- only relations the operator
    # declared themselves survive.
    fk_blocker = decisions.get("schema.foreign_keys.unsupported")
    fk_untrusted = fk_blocker is not None and fk_blocker.choice == "omit"
    # A foreign key whose target is not `id` emits ids that point at nothing; an `omit`
    # decision drops the RELATION, keeping the table.
    dropped_relations = {
        (parts[1], parts[2])
        for parts in (split_id(fid) for fid in decisions)
        if len(parts) == 4
        and parts[0] == "fk"
        and parts[3] == "target_key"
        and decisions[".".join(parts)].choice == "omit"
    }

    pending: list[Mapped] = []
    for table in sorted(src.migratable_tables(), key=lambda t: t["name"]):
        name = table["name"]
        if name in omitted:
            continue
        model = src.model_for_table(name)
        enums = (model or {}).get("enums") or {}
        digest_column = auth_tables.get(name)
        encrypted_here = encrypted.get(name, set())

        skipped_columns = {
            column["name"]
            for column in table["columns"]
            if column["name"] in _primary_key_names(table)
            or column["name"] in TIMESTAMP_COLUMNS
            # a digest becomes passwordHash on the auth import, never a field;
            # ciphertext never migrates; a dropped column was decided away
            or (digest_column and column["name"] == digest_column)
            or column["name"] in encrypted_here
            or (name, column["name"]) in dropped_columns
        }

        relations: dict[str, str] = {}
        cascades: dict[str, bool] = {}
        # A `belongs_to` with no database foreign key is still a relation when the
        # operator says so. Offering the choice and then deriving relations only from
        # database FKs made the decision inert.
        for column, target_table in _declared_relations(src, decisions, name).items():
            # No skip check: `_refuse_inert_decisions` has already refused a promotion
            # of a column that cannot travel, so nothing skipped reaches here.
            relations[column] = renamed.get(target_table, target_table)
        for fk in [] if fk_untrusted else (table.get("foreign_keys") or []):
            if fk.get("to_table") in RAILS_INTERNAL_TABLES:
                continue
            if (name, fk["column"]) in dropped_relations:
                continue
            if fk["column"] in skipped_columns:
                # No field is emitted for a skipped column and no value ships, so this
                # is not a relation. Leaving one here made three consumers believe in it:
                # the dangling-name check refused a perfectly consistent schema (drop the
                # target table AND the referring column), the orphan-value check refused
                # rows whose value never travels, and the manifest ordering counted a
                # crossing that is not one. Filtering only DECISION-dropped columns left
                # every other skip route -- an encrypted foreign key, a shared primary
                # key -- wedged in exactly the same way, with no decision to resolve it.
                continue
            relations[fk["column"]] = renamed.get(fk["to_table"], fk["to_table"])
            # `omit` on an unsupported FK action means DROP the action -- keeping the
            # destructive half of `ON DELETE CASCADE ON UPDATE CASCADE` while recording
            # a decision to drop it is the opposite of what was asked.
            action_decision = decisions.get(
                finding_id("fk", name, fk["column"], "action")
            )
            if action_decision is not None and action_decision.choice == "omit":
                cascades[fk["column"]] = False
            else:
                database_cascade = (fk.get("on_delete") or "").lower() == "cascade"
                if database_cascade and (name, fk["column"]) in restrict_protected:
                    # The source contradicts itself here and the operator has said which
                    # half to keep. Only `cascade` keeps a source behaviour: the target
                    # emits ON DELETE SET NULL when `cascadeDelete` is false, so the
                    # other answers accept orphaning and carry the refusal, if at all,
                    # in a hook.
                    contradiction = decisions.get(
                        finding_id("fk", name, fk["column"], "cascade_vs_restrict")
                    )
                    database_cascade = (
                        contradiction is not None and contradiction.choice == "cascade"
                    )
                cascades[fk["column"]] = (
                    database_cascade or (name, fk["column"]) in cascading
                )

        attachments = {
            a["name"]: a.get("macro", "has_one_attached")
            for a in ((model or {}).get("attachments") or [])
            # Only `attachment.…` decisions drop an attachment. A column-scoped omit
            # names a COLUMN, and since the two may share a name it must not reach in
            # here and take the attachment with it.
            if (name, a["name"]) not in dropped_attachments
        }

        field_names, attachment_names = _field_names(
            name,
            table,
            relations,
            attachments,
            skipped_columns,
            renamed_columns,
            digest_column is not None,
            renamed_attachments,
        )

        fields: list[dict[str, Any]] = []
        for column in table["columns"]:
            cname = column["name"]
            if cname in skipped_columns:
                continue
            if cname in relations:
                fields.append(
                    {
                        "id": "",
                        "name": field_names[cname],
                        "type": "relation",
                        "required": not column.get("null", True),
                        "options": {
                            "targetCollectionId": relations[cname],
                            # Mirror the source: ON DELETE CASCADE is behavior, and
                            # defaulting every relation to False silently drops it.
                            "cascadeDelete": cascades.get(cname, False),
                            "maxSelect": 1,
                        },
                    }
                )
                continue
            if cname in enums:
                fields.append(
                    {
                        "id": "",
                        "name": field_names[cname],
                        "type": "select",
                        "required": not column.get("null", True),
                        "options": {
                            "values": sorted((enums[cname].get("values") or {}).keys()),
                            "maxSelect": 1,
                        },
                    }
                )
                continue
            field_type = TYPE_MAP.get(column["type"])
            if field_type is None:
                raise RailsError(
                    f"{name}.{cname}: unmapped column type {column['type']!r}; the only "
                    f"honoured decision for it is `omit`"
                )
            # A serialized attribute's decision picks its target representation. Reading
            # the decision and then emitting the raw column type made the choice a
            # formality -- `json` produced `text` regardless.
            serialized = serialized_choice.get((model or {}).get("name", ""), {}).get(
                cname
            )
            if serialized in ("json", "text"):
                field_type = serialized
            options: dict[str, Any] = {}
            if field_type == "number":
                options["mode"] = (
                    "int" if column["type"] in ("integer", "bigint") else "float"
                )
            fields.append(
                {
                    "id": "",
                    "name": field_names[cname],
                    "type": field_type,
                    "required": not column.get("null", True),
                    "options": options,
                }
            )

        for attachment, macro in sorted(attachments.items()):
            fields.append(
                {
                    "id": "",
                    "name": attachment_names[attachment],
                    "type": "file",
                    "options": (
                        {} if macro == "has_one_attached" else {"maxSelect": 0}
                    ),
                }
            )

        pending.append(
            Mapped(
                table=name,
                collection=renamed.get(name, name),
                is_auth=digest_column is not None,
                model=model,
                columns=table["columns"],
                indexes=list(table.get("indexes") or []),
                fields=fields,
                relations=relations,
                enums=enums,
                digest_column=digest_column,
                attachments=attachments,
                field_names=field_names,
                attachment_names=attachment_names,
            )
        )
    # A dropped table leaves every relation into it dangling. `schema apply` would
    # refuse the document, but only after the operator believed the decision was safe;
    # naming the offenders here is the difference between a clear refusal and a puzzle.
    surviving = {entry.collection for entry in pending}
    dangling = sorted(
        f"{entry.collection}.{entry.field_names.get(column, column)} -> {target}"
        for entry in pending
        for column, target in entry.relations.items()
        if target not in surviving
    )
    if dangling:
        raise RailsError(
            "omitting a table left relations pointing at nothing: "
            + ", ".join(dangling)
            + " — omit the referring collections too, or keep the target"
        )
    return pending


def _relation_columns(
    src: Source, decisions: dict[str, Decision], table: str
) -> set[str]:
    """Every column on `table` that becomes a relation field.

    Both kinds count: a real database foreign key, and a `belongs_to` the operator
    decided to honour as a relation. A gate that saw only the first let a renamed
    association claim an engine-owned name.

    Narrower than `_relation_bearing_columns`, and deliberately: this asks what a
    relation IS, after the decisions, while that one asks what one COULD be, before
    them. So an undecided `belongs_to` counts there and not here. What must not differ
    is the foreign key into a Rails-owned table — no relation is emitted for it under
    any decision, and counting it here made this function's own first sentence false.
    """
    # Two decisions remove a relation the schema declares, and both must be honoured
    # here or "after the decisions" is not what this returns: `foreign_keys.unsupported:
    # omit` says no relation is derived from a key at all, and `fk.<t>.<c>.target_key:
    # omit` drops one relation. A column left literal at emission but counted here is
    # refused a rename that the same column, un-decided, would be allowed.
    untrusted = decisions.get("schema.foreign_keys.unsupported")
    if untrusted is not None and untrusted.choice == "omit":
        columns: set[str] = set()
    else:
        dropped = {
            parts[2]
            for parts in (split_id(fid) for fid in decisions)
            if len(parts) == 4
            and parts[0] == "fk"
            and parts[1] == table
            and parts[3] == "target_key"
            and decisions[".".join(parts)].choice == "omit"
        }
        columns = {
            fk["column"]
            for entry in src.migratable_tables()
            if entry["name"] == table
            for fk in (entry.get("foreign_keys") or [])
            if fk.get("to_table") not in RAILS_INTERNAL_TABLES
            and fk.get("column") not in dropped
        }
    return columns | set(_declared_relations(src, decisions, table))


def _primary_key_names(entry: dict[str, Any]) -> set[str]:
    """The primary key column(s) of `entry`, as a set.

    Rails 7.1 composite primary keys arrive as a LIST — `connection.primary_key` returns
    the whole array once there is more than one — and every site that put the raw value
    into a set died on `unhashable type: 'list'`, taking down the whole findings phase
    with a Python traceback before `NonStandardPrimaryKey` could quarantine the table.

    The three other shapes are preserved exactly as they were read before: absent means
    the Rails default `id`; an explicit null is the extractor's `rescue nil` and matches
    no column at all, which is not the same as `id`; a string is itself.
    """
    if "primary_key" not in entry:
        return {"id"}
    key = entry["primary_key"]
    if isinstance(key, (list, tuple)):
        return {str(part) for part in key}
    if key is None:
        return set()
    return {key}


def _bearable_belongs_to(association: dict[str, Any]) -> bool:
    """Could a relation ever ride this `belongs_to`?

    Three reasons it could not, and every caller needs all three -- a caller that
    checked two of them raised a blocker for the third, on a premise untrue of it.

    Polymorphic: `_polymorphic_findings` governs the `_type`/`_id` pair, no promotion is
    ever offered for it, and there is no single target table to point at. Rails-internal
    target: those tables never become collections, so a promoted relation could not
    resolve -- `map_tables` refuses it with advice the operator cannot follow. Unknown
    target: the extractor writes null when `r.klass` raises, which an association naming
    a class that no longer exists does -- ordinary legacy cruft. `_declared_relations`
    drops a promotion with no target, so offering one was a choice recorded and honoured
    nowhere, and the catalogue's claim that `relation` is consumed was false for it.
    """
    return (
        association.get("macro") == "belongs_to"
        and not association.get("polymorphic")
        and bool(association.get("table_name"))
        and association.get("table_name") not in RAILS_INTERNAL_TABLES
    )


def _relation_bearing_columns(src: Source, table: str) -> set[str]:
    """Columns of `table` that a relation could be emitted for.

    Both a database foreign key and a bare `belongs_to` count: the key emits a relation
    outright, and the declaration alone can be promoted to one by decision, so a gate
    that saw only real keys left both of that finding's choices broken.

    This must agree with `_association_findings`, which asks the same question one
    association at a time. Every way the two drifted apart produced the same defect --
    a blocker whose premise was untrue of the column it named -- so the shared parts
    are `_bearable_belongs_to` and the checks below rather than restatements.
    """
    entry = next((t for t in src.migratable_tables() if t["name"] == table), None)
    # A column the table does not have cannot bear anything. `_association_findings`
    # has always required this; the helper did not, and so raised a blocker naming a
    # column a later migration had dropped -- with both of its answers inert.
    present = {c["name"] for c in ((entry or {}).get("columns") or [])}
    keys = {
        fk["column"]
        for fk in ((entry or {}).get("foreign_keys") or [])
        if fk.get("to_table") not in RAILS_INTERNAL_TABLES
    }
    # EVERY model on this table, not `model_for_table`, which answers with the STI base
    # alone. `_association_findings` iterates all of them, so a subclass-declared
    # `belongs_to` was offered promotion to a relation that this helper could not see --
    # and the auth blocker that catches the unresolvable import was therefore never
    # raised for it. A Devise `User`/`Admin` hierarchy is the ordinary shape.
    declared = {
        association.get("foreign_key")
        for model in src.models["models"]
        if model.get("table_name") == table
        for association in model.get("associations") or []
        if _bearable_belongs_to(association)
    }
    return {column for column in keys | declared if column and column in present}


def _renamed_columns(
    src: Source, decisions: dict[str, Decision]
) -> dict[tuple[str, str], str]:
    """(table, column) -> the field name an operator supplied for it."""
    auth_tables = _auth_tables(src)
    types = {
        (entry["name"], column["name"]): column["type"]
        for entry in src.migratable_tables()
        for column in entry["columns"]
    }
    # Attachment renames are gated in `_renamed_attachments`, in their own namespace.
    # This function now sees only real columns, so it must not demote one to non-literal
    # merely because an attachment happens to share its source name.
    out: dict[tuple[str, str], str] = {}
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if (
            len(parts) == 4
            and parts[0] == "column"
            and parts[3] in ("identifier", "reserved")
            and decision.choice == "rename"
        ):
            table, column = parts[1], parts[2]
            replacement = (decision.artifact or "").strip()
            # The finding exists BECAUSE the old name failed one of these gates, so the
            # replacement has to clear BOTH -- renaming `bad col` to `id` was accepted
            # and then replaced every record's primary id with that column's value. A
            # renamed RELATION is still a relation, so it gets no auth exemption either.
            if not IDENTIFIER.match(replacement) or _reserved_here(
                replacement,
                is_auth=table in auth_tables,
                literal=column not in _relation_columns(src, decisions, table),
                column_type=types.get((table, column)),
            ):
                raise RailsError(
                    f"rename of {table}.{column!r} to {replacement!r} is not a "
                    f"usable ZigBase field name"
                )
            out[(table, column)] = replacement
    return out


def _relation_field_name(column: str) -> str:
    return column[:-3] if column.endswith("_id") else column


def _field_names(
    table_name: str,
    table: dict[str, Any],
    relations: dict[str, str],
    attachments: dict[str, str],
    skipped: set[str],
    renames: dict[tuple[str, str], str],
    is_auth: bool,
    attachment_renames: dict[tuple[str, str], str] | None = None,
) -> tuple[dict[str, str], dict[str, str]]:
    """Resolve the emitted field name for every column, and refuse any collision.

    `author_id` becoming the relation field `author` is only safe while nothing else
    claims that name. A denormalised `author` column beside `author_id` -- a common
    Rails shape -- produced two fields called `author`, and because rows are built into
    a dict the second silently overwrote the first: the column's data never reached the
    NDJSON, and the bundle was attested as clean. Where stripping `_id` would collide,
    keep the full column name instead; it is valid, unambiguous, and loses nothing.
    """
    attachment_renames = attachment_renames or {}
    # Columns and attachments get SEPARATE maps sharing one `taken` set: both are keyed
    # by name, and a column and an attachment may legitimately carry the same one --
    # that collision is exactly what the finding is for. A single map let one overwrite
    # the other and emitted both under the survivor's name.
    attached: dict[str, str] = {}
    resolved: dict[str, str] = {}
    taken: dict[str, str] = {}
    kinds: dict[str, str] = {}

    def claim(
        column: str,
        candidate: str,
        *,
        literal: bool,
        column_type: str | None = None,
        kind: str = "column",
    ) -> None:
        # ZigBase compares field names case-insensitively (SQLite columns collide that
        # way), so `Name` beside `name` is a duplicate there and must be one here.
        key = candidate.lower()
        owner = taken.get(key)
        if owner is not None:
            # Printing the same qualified name twice told the operator nothing when the
            # two subjects were a column and an attachment sharing it.
            raise RailsError(
                f"{table_name}: {kind} {column!r} and {kinds[owner]} {owner!r} both "
                f"resolve to the field {candidate!r}; rename or omit one of them"
            )
        kinds[column] = kind
        if _reserved_here(
            candidate, is_auth=is_auth, literal=literal, column_type=column_type
        ):
            # Reached only when no decision covers the column: `schema apply` drops such
            # a field silently, so shipping it would lose the data with a clean exit.
            raise RailsError(
                f"{table_name}.{column} would be emitted as {candidate!r}, which the "
                f"ZigBase engine owns; rename or omit it"
            )
        if literal and is_auth and key in AUTH_MAPPED_FIELD_NAMES:
            # The engine matches record keys with `std.mem.eql` (src/import.zig
            # `findField`), so an `Email` column has to travel as `email` or the auth
            # import simply never sees it.
            candidate = key
        taken[key] = column
        (attached if kind == "attachment" else resolved)[column] = candidate

    for column in table["columns"]:
        name = column["name"]
        if name in skipped or name in relations:
            continue
        # A scalar column is literal whether it kept its own name or the operator chose
        # one: both are deliberate. Only a DERIVED name loses the auth exemption.
        claim(
            name,
            renames.get((table_name, name), name),
            literal=True,
            column_type=column["type"],
        )
    for attachment in sorted(attachments):
        # An attachment has no second name to fall back to on its own, and it is never
        # the auth collection's own `email`/`username`/`verified` whatever it is called
        # -- but the operator may have supplied one, and the finding invites them to.
        claim(
            attachment,
            attachment_renames.get((table_name, attachment), attachment),
            literal=False,
            kind="attachment",
        )
    for column in sorted(relations):
        # No `skipped` check: `map_tables` excludes every skipped column from
        # `relations` before this runs, so the two sets are disjoint by construction.
        renamed = renames.get((table_name, column))
        if renamed is not None:
            # A renamed relation is still a relation, so `literal=False` is this
            # column's classification, not a judgement call. `_renamed_columns` reaches
            # the same value from the same inputs (`column not in _relation_columns`,
            # false for everything this loop iterates) and raises first, which makes the
            # reserved-name arm below unreachable rather than merely untested -- a
            # mutation of this argument survives every test by construction. It stays as
            # the backstop that would decide if that earlier gate were ever loosened.
            claim(column, renamed, literal=False)
            continue
        candidate = _relation_field_name(column)
        # A DERIVED name never inherits the auth exemption: `verified_id` is a relation
        # to some other collection, not the auth `verified` flag, and letting it claim
        # that name filtered the relation out of the schema while every record still
        # carried a target id under a key the engine reads as a boolean.
        if candidate.lower() in taken or _reserved_here(
            candidate, is_auth=is_auth, literal=False
        ):
            candidate = column
        claim(column, candidate, literal=False, kind="relation")
    return resolved, attached


def _schema_fields(entry: Mapped) -> list[dict[str, Any]]:
    """The fields the schema document DECLARES.

    An auth collection's `email`/`username`/`verified` are injected by the engine, so
    declaring them again is redundant -- and `schema apply` drops such a field rather
    than refusing it, which means the bundle would silently depend on that leniency.
    The values still travel: the record keeps the column, and the auth import maps it.
    """
    if not entry.is_auth:
        return entry.fields
    return [f for f in entry.fields if f["name"].lower() not in AUTH_MAPPED_FIELD_NAMES]


def _indexes_for(
    entry: Mapped,
    predicates: dict[tuple[str, str], str] | None = None,
    declared: set[str] | None = None,
) -> list[dict[str, Any]]:
    """Carry indexes across, renaming any column that became a relation field.

    An index over a column the converter dropped (a password digest, a Rails
    timestamp) cannot be expressed against the target and is skipped rather than
    emitted against a field that does not exist.
    """
    predicates = predicates or {}
    out = []
    for index in sorted(entry.indexes, key=lambda i: i["name"]):
        # Resolve through field_names by KEY, never by falling back to the raw column.
        # A dropped `author` column beside a relation `author_id` fell back to "author"
        # -- the name the relation had just inherited -- and emitted the source column's
        # UNIQUE index over the relation field, silently making it one-post-per-user.
        if not all(c in entry.field_names for c in index["columns"]):
            continue
        fields = [entry.field_names[c] for c in index["columns"]]
        # An index may only name a field the document actually declares.
        if declared is not None and not all(f in declared for f in fields):
            continue
        emitted: dict[str, Any] = {
            "name": index["name"],
            "fields": fields,
            "unique": bool(index.get("unique")),
        }
        # A partial index's predicate is written against SOURCE columns and SOURCE
        # values, and extraction changes both: `author_id` becomes the relation field
        # `author`, and an integer-backed enum becomes its label. Copying the SQL
        # verbatim can therefore produce an index that is invalid, or valid and subtly
        # wrong. Dropping it silently is no better -- `UNIQUE(x) WHERE y IS NULL` would
        # become globally unique. So the operator supplies a reviewed predicate as the
        # decision's artifact, or the index is omitted; this converter does not translate
        # SQL it cannot verify.
        replacement = predicates.get((entry.table, index["name"]))
        if index.get("where") and replacement is None:
            continue
        if replacement:
            emitted["where"] = replacement
        out.append(emitted)
    return out


#: The one rule expression that means "anyone", including anonymous callers.
PUBLIC_RULE = "@public"

RULE_ACTIONS = ("list", "view", "create", "update", "delete")
# `list  = @public` (two spaces, or a tab) matched neither prefix form, so the mixed-form
# refusal never fired and the literal line shipped as the rule for all five actions.
_ACTION_LINE = re.compile(rf"^({'|'.join(RULE_ACTIONS)})\s*=")


def _rules_for(decisions: dict[str, Decision], table: str) -> dict[str, str | None]:
    """Resolve all five access rules for one collection.

    The finding asks for list/view/create/update/delete, so a decision has to be able to
    say something about each. Applying one expression to list+view and hard-locking the
    other three could not express an authenticated write or an intentional public signup
    -- the two shapes a real migration most often needs.

    An `expression` artifact may be either a single rule applied to every action, or a
    per-action mapping written as `action=expression` lines. Anything unnamed stays
    locked, because Locked is the safe default and silence must not open access.
    """
    decision = decisions.get(finding_id("table", table, "rules"))
    if decision is None or decision.choice == "locked":
        return {action: None for action in RULE_ACTIONS}
    if decision.choice == "public":
        return {action: PUBLIC_RULE for action in RULE_ACTIONS}

    artifact = (decision.artifact or "").strip()
    lines = [line.strip() for line in artifact.splitlines() if line.strip()]
    # Detect the per-action form by SHAPE: every line must begin `<action> =`. Dispatching
    # on "does the artifact contain '='" was wrong for nearly every real rule, because
    # `!=`, `>=` and `?=` all contain one -- `@request.auth.id != ''` was read as an
    # action named `@request.auth.id !`.
    per_action = bool(lines) and all(_ACTION_LINE.match(line) for line in lines)
    some_match = any(_ACTION_LINE.match(line) for line in lines)
    if some_match and not per_action:
        # Half a per-action block collapses into one multiline expression that includes
        # the `list =` text. Fail loudly rather than ship something nobody wrote.
        raise RailsError(
            f"rule decision for {table!r} mixes per-action lines with free text; use "
            f"either one expression or a complete `<action> = …` line per action"
        )
    if not per_action:
        # One expression, every action.
        return {action: artifact or None for action in RULE_ACTIONS}

    # Unnamed actions stay Locked, so start empty and fill in what the artifact names:
    # a pre-filled map cannot tell "not mentioned" from "mentioned twice".
    resolved: dict[str, str | None] = {}
    for line in lines:
        # No unknown-action check: `per_action` above is `all(_ACTION_LINE.match(...))`,
        # and that pattern is anchored to the five names, so reaching this loop already
        # proves every line names one of them. A line that does not is refused eight
        # lines up, as mixed form. Fuzzing every one-to-three-line combination of
        # adversarial fragments never reached a sixth action.
        action, _, expression = line.partition("=")
        action = action.strip()
        if action in resolved:
            # Two lines for one action: the last silently won, so half a reviewed rule
            # set was discarded without a word.
            raise RailsError(
                f"rule decision for {table!r} names {action!r} more than once; "
                f"give each action exactly one expression"
            )
        resolved[action] = expression.strip() or None
    return {action: resolved.get(action) for action in RULE_ACTIONS}


def build_schema_document(
    mapped: list[Mapped], decisions: dict[str, Decision]
) -> dict[str, Any]:
    # A reviewed partial-index predicate rides on its finding's decision artifact.
    predicates = _index_predicates(decisions)

    collections = []
    for entry in mapped:
        rules = _rules_for(decisions, entry.table)
        fields = _schema_fields(entry)
        collections.append(
            {
                "name": entry.collection,
                "type": "auth" if entry.is_auth else "base",
                "fields": fields,
                "indexes": _indexes_for(entry, predicates, {f["name"] for f in fields}),
                "listRule": rules["list"],
                "viewRule": rules["view"],
                "createRule": rules["create"],
                "updateRule": rules["update"],
                "deleteRule": rules["delete"],
            }
        )
    return {"zigbaseSchema": 1, "collections": collections}


def _index_predicates(decisions: dict[str, Decision]) -> dict[tuple[str, str], str]:
    """Reviewed partial-index predicates, keyed by (source table, index name)."""
    predicates: dict[tuple[str, str], str] = {}
    for fid, decision in decisions.items():
        parts = split_id(fid)
        if (
            len(parts) == 4
            and parts[0] == "index"
            and parts[-1] == "where"
            and decision.choice == "replacement"
            and decision.artifact
        ):
            # Keyed on the CHOICE: an `omit` decision that happens to carry an artifact
            # was emitting the index anyway, against the operator's stated intent.
            # Keyed by (table, index) because an index name is only unique per source.
            predicates[(parts[1], parts[2])] = decision.artifact
    return predicates


# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------


def _decode_text(raw: bytes) -> str:
    """Decode a TEXT value, refusing rather than raising through the driver.

    Latin-1 bytes in a TEXT column are ordinary in an application old enough to be worth
    migrating. The driver raised `OperationalError` mid-iteration and `main` handles only
    RailsError, so the operator got a bare traceback; and the target stores UTF-8, so
    there is nothing to convert this into safely.
    """
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RailsError(
            f"the source holds text that is not valid UTF-8 ({raw[:40]!r}); the target "
            f"stores UTF-8, so the source encoding has to be fixed first"
        ) from exc


def _connect(database: Path) -> sqlite3.Connection:
    # Read-only, so the frozen source cannot be mutated even by accident.
    conn = sqlite3.connect(f"file:{database}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    conn.text_factory = _decode_text
    return conn


def _quote(identifier: str) -> str:
    return '"' + identifier.replace('"', '""') + '"'


def read_rows(conn: sqlite3.Connection, entry: Mapped) -> list[dict[str, Any]]:
    """Read every row, in id order.

    Raw SQL is inherently unscoped, which is the point: a `default_scope` would hide
    rows from any read issued through the model, and those rows are exactly the ones a
    migration must not silently drop.
    """
    primary = "id"
    sql = f"SELECT * FROM {_quote(entry.table)} ORDER BY {_quote(primary)}"
    return [dict(row) for row in _fetch(conn, sql, entry.table)]


def _importable_with_timestamps(
    records: Any, table: str, routed_separately: bool, routable: bool = True
) -> Any:
    """Refuse a row the documented `--preserve-timestamps` import would reject.

    The finding above is column-level and value-agnostic; this is the load-bearing
    check, because an inventory that says NOT NULL and a database that disagrees is
    exactly the drift a migration exists to discover. Without it the bundle extracts,
    hashes and reports success, and the import dies partway through.
    """
    for record in records:
        if not routed_separately:
            missing = [key for key in ("created", "updated") if key not in record]
            if missing:
                raise RailsError(
                    f"{table} row {record.get('id')!r} has no "
                    f"{' or '.join(missing)} timestamp, so importing it with "
                    f"--preserve-timestamps would fail"
                    + (
                        "; decide `separate-import` for this table, or omit it"
                        if routable
                        else " — and the table raised no timestamp finding, so there is "
                        "no decision to record: the source value has to be fixed"
                    )
                )
        yield record


def _record_id(entry: Mapped, row: dict[str, Any]) -> str:
    """Validate the value that becomes the target's primary id.

    `NonStandardPrimaryKey` checks the pk's NAME; nothing checked its VALUES. A TEXT
    `id` column is legal in SQLite, and an empty one imported cleanly WITHOUT
    `--preserve-timestamps` -- the engine silently generated a fresh id, leaving every
    relation that pointed at that row dangling, with a clean exit.
    """
    value = row.get("id")
    if value is None:
        raise RailsError(f"{entry.table} has a row with no id; it cannot be migrated")
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise RailsError(f"{entry.table} has a row whose id is {value!r}")
    text = str(value)
    # `isPlausibleRecordId` (src/records.zig) rejects any byte <= ' ' or >= 127, and the
    # id is a path segment as well as a key.
    if not 1 <= len(text) <= 255 or any(c <= " " or c >= "\x7f" for c in text):
        raise RailsError(
            f"{entry.table} has a row whose id {text!r} the target will not accept; "
            f"ids must be 1-255 printable ASCII characters"
        )
    return text


@contextlib.contextmanager
def _at(table: str, column: str, row_id: str) -> Any:
    """Attach a location to any refusal raised inside.

    `coerce` and `to_rfc3339` see a value and nothing else, so their messages named no
    table, column or row -- and the binary-column one named not even the value, leaving
    an operator with a real source nothing to search for.
    """
    try:
        yield
    except RailsError as exc:
        raise RailsError(f"{table}.{column}, row id {row_id!r}: {exc}") from exc


def build_record(
    entry: Mapped,
    row: dict[str, Any],
    attachments: dict[tuple[str, str, str], list[str]] | None = None,
) -> dict[str, Any]:
    record: dict[str, Any] = {"id": _record_id(entry, row)}
    attachments = attachments or {}
    source_column = {field: column for column, field in entry.field_names.items()}
    source_attachment = {
        field: attachment for attachment, field in entry.attachment_names.items()
    }

    for f in entry.fields:
        name = f["name"]
        column = source_column.get(name, name)
        if f["type"] == "file":
            # The bytes are installed separately, but the record still has to name the
            # file or the target has no idea the attachment belongs to it.
            # Keyed by the SOURCE attachment name -- that is what Active Storage
            # recorded -- while the record emits it under the field name.
            source = source_attachment.get(name, name)
            names = attachments.get((entry.collection, str(row["id"]), source)) or []
            single = entry.attachments.get(source) == "has_one_attached"
            # `has_one_attached` with nothing attached is absent, not an empty list --
            # emitting [] would declare a multi-file field the source never had.
            record[name] = (names[0] if names else None) if single else names
            continue
        if f["type"] == "relation":
            value = row.get(column)
            if value is not None and (
                isinstance(value, bool) or not isinstance(value, (int, str))
            ):
                # A REAL or BLOB foreign key cannot be compared exactly against a target
                # id: SQLite renders a float one way and Python another, so the orphan
                # check and the emitted value would disagree about the same row.
                raise RailsError(
                    f"{entry.table}.{column}, row id {record['id']!r}: {value!r} "
                    f"cannot be a relation id"
                )
            record[name] = None if value is None else str(value)
            continue
        # A value refusal that names no location is unactionable on a real source:
        # there is nothing to search the database for. Every sibling refusal in this
        # file already names its table, column and row, so these must too.
        with _at(entry.table, column, record["id"]):
            record[name] = coerce(
                row.get(column),
                f["type"],
                entry.enums.get(column),
                number_mode=(f.get("options") or {}).get("mode"),
            )

    with _at(entry.table, "created_at", record["id"]):
        created = to_rfc3339(row.get("created_at"))
    with _at(entry.table, "updated_at", record["id"]):
        updated = to_rfc3339(row.get("updated_at"))
    if created:
        record["created"] = created
    # `--preserve-timestamps` requires both. A Rails table with only `created_at` is
    # ordinary, and mirroring is the honest reading -- the row was never updated. It is
    # reported as a finding (`NoUpdatedAtColumn`) and in the bundle report rather than
    # done quietly.
    #
    # Gated on the COLUMN being absent, which is the case that reasoning covers. Where
    # the column exists and this row's value is empty, the row WAS updated and the
    # source has drifted; mirroring there fabricates "never updated" for it, silently,
    # and neither the finding nor `timestampMirrored` mentions the table -- both are
    # column-level. Left unmirrored, `_importable_with_timestamps` refuses and names the
    # table and row, exactly as it already does for an empty `created_at`.
    if (
        updated is None
        and created is not None
        and "updated_at" not in {c["name"] for c in entry.columns}
    ):
        updated = created
    if updated:
        record["updated"] = updated
    return record


def build_auth_record(
    entry: Mapped,
    row: dict[str, Any],
    attachments: dict[tuple[str, str, str], list[str]] | None = None,
    *,
    emit_credentials: bool = True,
) -> dict[str, Any]:
    record = build_record(entry, row, attachments)
    if not emit_credentials:
        # The operator chose `reset-passwords`, which is the ONLY safe answer to a
        # configured Devise pepper. Emitting the digest anyway would ship credentials
        # guaranteed to reject every login while reporting a clean migration -- the
        # reviewed decision and the bundle would say opposite things.
        return record
    digest = row.get(entry.digest_column)
    if digest in (None, ""):
        # A provider-only account genuinely has no password. Extraction cannot invent
        # one, and shipping the row without a credential would be a silent partial
        # migration, so name the cause instead of failing as "unsupported hash".
        raise RailsError(
            f"{entry.table}.{row['id']} has no password digest, which is what a "
            f"provider-only (OmniAuth) account looks like. Decide "
            f"`passwordless-rollout` for these accounts and import them separately, or "
            f"exclude them; extraction cannot invent a credential."
        )
    if not isinstance(digest, str) or not BCRYPT.fullmatch(digest):
        raise RailsError(
            f"{entry.table}.{row['id']} has no supported bcrypt credential; "
            f"non-bcrypt hashes require a reviewed reset"
        )
    record["passwordHash"] = digest
    return record


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------


def _servable_name(filename: str) -> str:
    """Reduce a source filename to one the target can actually serve.

    This mirrors ZigBase's own `sanitizeBase` (src/files/naming.zig) deliberately: the
    file route byte-compares the raw path segment and never percent-decodes it, and the
    SDKs build the URL with `encodeURIComponent`. So a name outside `[A-Za-z0-9._-]`
    installs happily and then 404s for every client -- and `My Photo.png` is about the
    most ordinary upload filename there is. Active Storage keeps the client-supplied
    name verbatim, so the source is full of them.

    Deterministic rather than refusing: the manifest keeps the original `filename`
    beside the rewritten `targetName`, exactly as it already does for a collision.
    """
    base = filename
    for separator in ("/", "\\"):
        base = base.rsplit(separator, 1)[-1]
    base = base.lstrip(".")
    if not base:
        return "file"
    out: list[str] = []
    # A run of unsafe characters collapses to one `_`, emitted lazily so it can be
    # dropped where it would sit next to a `.` -- `sanitizeBase` does exactly this.
    pending = False
    for character in base:
        if character in SERVABLE_CHARACTERS:
            if pending and character != ".":
                out.append("_")
            pending = False
            out.append(character)
        else:
            pending = True
    # No trailing separator is appended for a `pending` run at the END of the name: the
    # `strip("_")` below removes it in every case, so emitting one only looked like
    # sanitization. Verified exhaustively over every name up to three characters.
    cleaned = "".join(out).strip("_").lstrip(".").strip("_")
    return cleaned or "file"


# Bytes. Most filesystems cap a single component at 255; the margin leaves room for the
# `field-`/`key-` disambiguation prefixes below.
TARGET_NAME_LIMIT = 200


def _bounded_name(name: str) -> str:
    """Keep a stored name inside the filesystem's per-component limit.

    Deliberately NOT part of `_servable_name`, which mirrors the engine's `sanitizeBase`
    byte for byte and must keep doing so. The engine's own upload path would fail this
    write too, so refusing here would be honest -- but it would also be a dead end, and
    the manifest records the original name either way.
    """
    if len(name.encode("utf-8")) <= TARGET_NAME_LIMIT:
        return name
    stem, dot, extension = name.rpartition(".")
    if dot and 0 < len(extension) <= 16:
        keep = TARGET_NAME_LIMIT - len(extension.encode("utf-8")) - 1
        trimmed = stem.encode("utf-8")[:keep].decode("utf-8", "ignore")
        return f"{trimmed}.{extension}"
    return name.encode("utf-8")[:TARGET_NAME_LIMIT].decode("utf-8", "ignore")


def _unique_target_name(
    taken: set[tuple[str, str, str]],
    collection: str,
    record_id: str,
    field: str,
    key: str,
    filename: str,
) -> str:
    """A filename unique within one record, stable across runs.

    Prefers the source filename so the target stays readable, and falls back to prefixing
    the attachment field, then the blob key, both of which are already unique per record.
    """
    # Active Storage keeps the client-supplied filename verbatim, so it can contain a
    # path separator -- and ZigBase resolves a file at `{collection}/{record}/{name}`,
    # where a slash is a different path entirely. Refusing at install time was far too
    # late: under the documented order the rows naming that file are already imported.
    filename = _servable_name(filename)
    for candidate in (
        _bounded_name(filename),
        # The FIELD has to be reduced too. A Ruby attachment name may hold anything --
        # `has_one_attached :"my photo"` is legal -- and it arrives here as recorded.
        # Only this fallback puts it in the stored name, so the collision case (the one
        # this function exists for) was the one that produced an unservable path.
        _bounded_name(f"{_servable_name(field)}-{filename}"),
        _bounded_name(f"{key}-{filename}"),
    ):
        if (collection, record_id, candidate) not in taken:
            taken.add((collection, record_id, candidate))
            return candidate
    raise RailsError(
        f"cannot find a unique target name for {collection}/{record_id}/{filename}"
    )


def require_disk_storage(src: Source) -> None:
    """Refuse a bundle whose bytes are not where the installer will look.

    The file plan synthesizes `storage/<shards>/<key>`, which is the local Disk service's
    layout and nothing else's. On S3, GCS, Azure or a custom service the bytes are simply
    not in the snapshot, so a plan built this way names paths that do not exist.
    """
    # The extractor answers this directly now: a MirrorService's class name mentions
    # neither the bucket nor the disk behind it, so sniffing the name was guesswork.
    local = src.storage.get("local_disk")
    if local is True:
        return
    service = str(
        src.storage.get("service_type") or src.storage.get("service_class") or ""
    )
    configured = str(src.storage.get("configured_service") or "")
    if local is False or (
        "disk" not in service.lower() and "disk" not in configured.lower()
    ):
        raise RailsError(
            f"Active Storage uses {configured or service or 'an unknown service'}; file "
            f"extraction can only read the local Disk service, whose bytes live in the "
            f"frozen snapshot. Export the objects separately and install them by hand."
        )


def _fetch(conn: sqlite3.Connection, sql: str, table: str) -> list[Any]:
    """Drain a cursor, naming the table if a value refuses to decode.

    `_decode_text` is installed as a text factory, so it sees bytes and no column. Every
    place that reads text has to add back at least the table, or the operator gets a
    refusal with nowhere to look.
    """
    try:
        return list(conn.execute(sql))
    except RailsError as exc:
        raise RailsError(f"{table}: {exc}") from exc


def _quoted(identifier: str) -> str:
    escaped = identifier.replace('"', '""')
    return f'"{escaped}"'


def _is_empty_to_the_engine(value: Any) -> bool:
    """`isEmpty` in src/records.zig: null, an empty string, or an empty array."""
    return value is None or value == "" or value == []


def _relax_required_for_empty_values(
    conn: sqlite3.Connection, mapped: list[Mapped]
) -> list[str]:
    """`NOT NULL` is a NULL-level contract; ZigBase's `required` is an EMPTINESS one.

    `t.string :nickname, null: false, default: ""` is idiomatic Rails, and an empty
    string in such a column is valid source data -- not drift. Mapping NOT NULL straight
    onto `required` therefore produced a schema the source's own rows violate: the
    import died partway through on data that was never wrong. Refusing the row would
    punish correct data, so the MAPPING gives way instead, and the report says where.

    The emptiness has to be judged on the value the bundle actually EMITS, not on the
    raw column: a serialized column holding the text `null` is non-empty in SQLite and
    emits JSON null, while a text column whose content is literally `[]` is the reverse.
    Comparing raw bytes got both directions wrong.
    """
    relaxed: list[str] = []
    for entry in mapped:
        source_column = {field: column for column, field in entry.field_names.items()}
        candidates = [
            field
            for field in entry.fields
            if field.get("required")
            and field["type"] not in ("relation", "file")
            # An auth collection's engine-injected fields are not declared by the
            # document, so "relaxing" one would describe a change to nothing.
            and not (entry.is_auth and field["name"].lower() in AUTH_MAPPED_FIELD_NAMES)
        ]
        if not candidates:
            continue
        columns = [source_column.get(f["name"], f["name"]) for f in candidates]
        found: set[str] = set()
        rows = _fetch(
            conn,
            f"SELECT id, {', '.join(_quoted(c) for c in columns)} "
            f"FROM {_quoted(entry.table)}",
            entry.table,
        )
        for row in rows:
            row_id, values = row[0], row[1:]
            for field, column, value in zip(candidates, columns, values):
                if field["name"] in found:
                    continue
                with _at(entry.table, column, str(row_id)):
                    emitted = coerce(
                        value,
                        field["type"],
                        entry.enums.get(column),
                        number_mode=(field.get("options") or {}).get("mode"),
                    )
                if _is_empty_to_the_engine(emitted):
                    found.add(field["name"])
            if len(found) == len(candidates):
                break
        for field in candidates:
            if field["name"] in found:
                field["required"] = False
                relaxed.append(f"{entry.collection}.{field['name']}")
    return sorted(relaxed)


def _refuse_dangling_relation_values(
    conn: sqlite3.Connection, mapped: list[Mapped]
) -> None:
    """The row-level sibling of the foreign-key gate.

    The converter checked that a foreign key was DECLARED; nothing checked that each
    row's value resolves. Legacy SQLite Rails apps carry orphans routinely -- foreign
    keys were not enforced by default for most of that history -- and the target
    validates every relation, so the import died partway through with earlier
    collections already committed.
    """
    by_collection = {entry.collection: entry for entry in mapped}
    for entry in mapped:
        for column, target in sorted(entry.relations.items()):
            destination = by_collection.get(target)
            if destination is None:
                continue  # already refused, by name, in map_tables
            orphans = conn.execute(
                f"SELECT COUNT(*) FROM {_quoted(entry.table)} AS src "
                f"LEFT JOIN {_quoted(destination.table)} AS dst "
                # The bundle emits `str(value)` and the engine matches ids byte-for-
                # byte, so a TEXT key holding '01' or ' 1' is affinity-equal here and
                # a miss there. Compare as text, the way the target will.
                f"  ON CAST(dst.id AS TEXT) = CAST(src.{_quoted(column)} AS TEXT) "
                f"WHERE src.{_quoted(column)} IS NOT NULL AND dst.id IS NULL"
            ).fetchone()[0]
            if orphans:
                raise RailsError(
                    f"{entry.table}.{column} has {orphans} row(s) pointing at a "
                    f"{destination.table} that does not exist; the target validates "
                    f"every relation, so this bundle would import partway and stop"
                )


def _timestampless_collections(decisions: dict[str, Decision]) -> set[str]:
    """Collections routed to the second manifest, by their POST-rename names."""
    renames = _renamed_tables(decisions)
    return {
        renames.get(split_id(fid)[1], split_id(fid)[1])
        for fid, d in decisions.items()
        if fid.endswith((".no_timestamps", ".nullable_timestamps"))
        and d.choice == "separate-import"
    }


def _manifest_order(mapped: list[Mapped], timestampless: set[str]) -> list[str]:
    """Sequence the two manifests, or refuse when no sequence works.

    Strip-then-patch is scoped to a single manifest RUN, which is exactly the argument
    that makes a relation out of an auth collection unimportable -- and it applies just
    as much to the second manifest. A relation crossing the boundary needs its target's
    manifest imported first; relations crossing BOTH ways cannot be ordered at all.

    An auth collection rides in NEITHER manifest -- it is imported from its own file
    BEFORE both -- so a relation pointing INTO one is already satisfied and is not a
    crossing. Counting them produced spurious "both directions" refusals that no
    decision could resolve (`separate-import` is only offered on tables that have the
    finding) and a `manifestOrder` naming a file the bundle does not contain. Auth as a
    relation SOURCE is a different problem, and `AuthCollectionRelation` refuses it.
    """
    members = {entry.collection for entry in mapped if not entry.is_auth}
    separate = {
        entry.collection
        for entry in mapped
        if not entry.is_auth and entry.collection in timestampless
    }
    if not separate:
        return ["manifest.json"]
    crossings: dict[str, list[str]] = {"main-first": [], "separate-first": []}
    for entry in mapped:
        if entry.is_auth:
            continue
        for column, target in sorted(entry.relations.items()):
            if target not in members:
                continue  # an auth target is imported before either manifest
            here, there = entry.collection in separate, target in separate
            if here == there:
                continue
            # The REFERENCED manifest has to be imported first, so the rows a relation
            # points at already exist when the referencing side is validated.
            key = "main-first" if here else "separate-first"
            crossings[key].append(f"{entry.collection}.{column} -> {target}")
    if crossings["main-first"] and crossings["separate-first"]:
        raise RailsError(
            "relations cross the timestamp manifest boundary in both directions, so "
            "neither manifest can be imported first: "
            + "; ".join(sorted(crossings["main-first"] + crossings["separate-first"]))
            + " — decide `separate-import` for the tables on one side of the boundary "
            "too, or omit the relations that cross it"
        )
    if crossings["separate-first"]:
        return ["manifest-no-timestamps.json", "manifest.json"]
    return ["manifest.json", "manifest-no-timestamps.json"]


def _refuse_duplicate_auth_identities(
    conn: sqlite3.Connection, mapped: list[Mapped]
) -> None:
    """The engine puts a partial UNIQUE index on an auth collection's email.

    A legacy Rails app that relied on `validates_uniqueness_of` alone -- no database
    index, the classic race-prone setup -- can hold exact duplicates. The auth import
    then died on a bare `Constraint` error, leaving the collection at zero rows, which
    makes every later import fail too.
    """
    for entry in mapped:
        if not entry.is_auth:
            continue
        source_column = {field: column for column, field in entry.field_names.items()}
        for identity in ("email", "username"):
            column = source_column.get(identity)
            if column is None:
                continue
            duplicates = _fetch(
                conn,
                f"SELECT {_quoted(column)}, COUNT(*) FROM {_quoted(entry.table)} "
                f"WHERE {_quoted(column)} IS NOT NULL AND {_quoted(column)} != '' "
                f"GROUP BY {_quoted(column)} HAVING COUNT(*) > 1",
                entry.table,
            )
            if duplicates:
                shown = ", ".join(
                    f"{value!r} x{count}" for value, count in duplicates[:3]
                )
                raise RailsError(
                    f"{entry.table}.{column} has duplicate values ({shown}); ZigBase "
                    f"puts a unique index on an auth collection's {identity}, so the "
                    f"import would fail and leave the collection empty"
                )


def _is_servable_email(value: str) -> bool:
    """Mirror the engine's rule (src/records.zig): no control characters or spaces,
    exactly one `@`, and neither side of it empty."""
    if any(c < " " or c == "\x7f" or c == " " for c in value):
        return False
    local, at, domain = value.partition("@")
    return bool(at) and bool(local) and bool(domain) and "@" not in domain


def _refuse_invalid_auth_identities(
    conn: sqlite3.Connection, mapped: list[Mapped]
) -> None:
    """A legacy user table full of junk emails is ordinary.

    The engine's injected `email` field is email-typed and validates every non-empty
    value, so `admin` or a trailing space aborts the auth import at row one -- leaving
    the collection empty, which then fails every later import that relates to it. An
    EMPTY email is fine: the field is not required and its unique index is partial.
    """
    for entry in mapped:
        if not entry.is_auth:
            continue
        source_column = {field: column for column, field in entry.field_names.items()}
        column = source_column.get("email")
        if column is None:
            continue
        bad = [
            (row[0], row[1])
            for row in _fetch(
                conn,
                f"SELECT id, {_quoted(column)} FROM {_quoted(entry.table)} "
                f"WHERE {_quoted(column)} IS NOT NULL AND {_quoted(column)} != ''",
                entry.table,
            )
            if not _is_servable_email(str(row[1]))
        ]
        if bad:
            shown = ", ".join(f"row {rid}: {value!r}" for rid, value in bad[:3])
            raise RailsError(
                f"{entry.table}.{column} holds {len(bad)} value(s) the target will not "
                f"accept as an email ({shown}); the auth import would stop at the first "
                f"one and leave the collection empty"
            )


def _refuse_incoherent_row_counts(
    src: Source, mapped: list[Mapped], written: dict[str, int]
) -> None:
    """The rows extracted must match the rows the inventory observed.

    Every blob is sha256-pinned against exactly this drift, and the row-count
    comparator was collected and then never consulted. The concrete route is ordinary:
    SQLite has run in WAL mode by default since Rails 7, and copying `*.sqlite3` without
    its `-wal` sidecar opens a pre-checkpoint image. Extraction then reads a
    consistent-looking database that is simply older than the inventory, and attests it.
    """
    observed = {
        entry.get("table"): entry.get("unscoped_count")
        for entry in (src.counts.get("tables") or [])
        if entry.get("source") == "observed"
    }
    for entry in mapped:
        expected = observed.get(entry.table)
        if expected is None:
            continue  # an inferred inventory has nothing to compare against
        actual = written.get(entry.collection)
        if actual != expected:
            raise RailsError(
                f"{entry.table} holds {actual} row(s) but the inventory observed "
                f"{expected}; the snapshot and the inventory describe different states "
                f"of the source (a database copied without its `-wal` sidecar reads "
                f"exactly like this), so the bundle would attest rows it never saw"
            )


def build_file_plan(
    src: Source,
    conn: sqlite3.Connection,
    mapped: list[Mapped] | None = None,
) -> tuple[list[dict[str, Any]], list[str]]:
    """Active Storage blobs, resolved to their on-disk path and owning record.

    Returns the plan and the attachments deliberately left behind.
    """
    tables = {t["name"] for t in src.schema["tables"]}
    if not {"active_storage_blobs", "active_storage_attachments"} <= tables:
        return [], []

    sql = """
        SELECT a.name AS field, a.record_type AS record_type, a.record_id AS record_id,
               b.key AS key, b.filename AS filename, b.content_type AS content_type,
               b.byte_size AS byte_size
        FROM active_storage_attachments a
        JOIN active_storage_blobs b ON b.id = a.blob_id
        -- `a.id`, not `b.key`: within one `has_many_attached` field this ordering IS
        -- the order the target serves the files in, and a blob key is a random base36
        -- token, so ordering by it scrambles a gallery relative to how it was uploaded.
        -- The attachment id is equally deterministic and is the order Rails itself
        -- hands attachments back in.
        ORDER BY a.record_type, a.record_id, a.name, a.id
    """
    require_disk_storage(src)
    models = {m["name"]: m for m in src.models["models"]}
    # Blobs must be filed under the COLLECTION, which a rename decision changes, and a
    # table that was omitted has no collection to file them under at all. Naming them by
    # the raw source table silently detached every attachment on a renamed table and
    # installed omitted ones into a collection that does not exist.
    collection_for = {entry.table: entry.collection for entry in (mapped or [])}
    # Active Storage rows outlive the records they belong to in plenty of old apps.
    # Their bytes were installed under a record directory that will never exist, and
    # counted in `files` as though they had been migrated.
    live_ids = {
        (entry.table, str(row[0]))
        for entry in (mapped or [])
        # `create_table id: :string` -- the ordinary UUID-on-SQLite shape -- declares a
        # non-alias TEXT primary key that holds arbitrary bytes, and this drain is the
        # first thing to read it. Naming the table is the difference between a refusal
        # an operator can act on and one they cannot.
        for row in _fetch(conn, f"SELECT id FROM {_quoted(entry.table)}", entry.table)
    }
    # A decision that dropped an attachment field must drop its bytes too: the blobs
    # were still installed into target storage, orphaned under a field the schema no
    # longer declares.
    kept_attachments = {
        (entry.table, name) for entry in (mapped or []) for name in entry.attachments
    }
    plan = []
    dropped: list[str] = []
    taken: set[tuple[str, str, str]] = set()
    for row in _fetch(conn, sql, "active_storage_attachments"):
        model = models.get(row["record_type"])
        if model is None:
            raise RailsError(
                f"attachment references unknown model {row['record_type']!r}"
            )
        table = model["table_name"]
        if mapped is not None and table not in collection_for:
            # The table was omitted; its blobs go nowhere. Checked BEFORE the blob is
            # read, so omitting a table is also a usable route around the damaged part
            # of a snapshot rather than a refusal the operator cannot act on.
            continue
        if mapped is not None and (table, str(row["record_id"])) not in live_ids:
            dropped.append(f"{collection_for.get(table, table)}.{row['field']}")
            continue
        if mapped is not None and (table, row["field"]) not in kept_attachments:
            # Either a decision dropped the field, or the row names an attachment the
            # model no longer declares. Checked BEFORE the blob is read, so omitting an
            # attachment is as usable a route around a damaged snapshot as omitting the
            # table is; `report.json` names them either way.
            dropped.append(f"{collection_for.get(table, table)}.{row['field']}")
            continue
        key = row["key"]
        source_path = f"storage/{key[0:2]}/{key[2:4]}/{key}"
        blob = src.root / source_path
        if not blob.is_file():
            # Recording `null` here meant the install-time digest check silently turned
            # itself off for exactly the damaged snapshots pinning exists to catch.
            raise RailsError(
                f"the snapshot is missing blob {key} referenced by "
                f"{table}/{row['record_id']}; extraction cannot pin bytes "
                f"it does not have"
            )
        collection = collection_for.get(table, table)
        record_id = str(row["record_id"])
        # ZigBase resolves a stored file at `{collection}/{record}/{name}`, so two
        # attachments on one record that legitimately share a filename would collide
        # there. Disambiguate the NAME rather than inventing directory levels the file
        # API does not read -- a deeper path installs cleanly and then 404s.
        target_name = _unique_target_name(
            taken, collection, record_id, row["field"], key, row["filename"]
        )
        plan.append(
            {
                "collection": collection,
                "recordId": record_id,
                "field": row["field"],
                "filename": row["filename"],
                "targetName": target_name,
                "contentType": row["content_type"],
                "bytes": row["byte_size"],
                # Active Storage's disk service shards on the first two pairs of the key.
                "sourcePath": source_path,
                "key": key,
                # Pin the bytes to THIS extraction. Without a digest the installer hashes
                # whatever happens to be there later, so a changed or truncated blob
                # installs silently.
                "sha256": sha256_file(blob),
            }
        )
    return plan, sorted(set(dropped))


# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------


# ZigBase's importer reads one record per line into a fixed buffer; a longer line is
# refused at import time, long after extraction and hashing have reported success.
IMPORT_LINE_LIMIT = 1024 * 1024


def _require_clean_output(out: Path, src: Source) -> None:
    """A bundle must be built into an empty directory disjoint from the source.

    Otherwise stale NDJSON from an earlier run, or source files themselves, get swept
    into `hashes.json` and the bundle attests to content it did not produce.
    """
    ensure_output_outside_source(out, src.root)
    resolved_out, resolved_src = out.resolve(), src.root.resolve()
    if resolved_out in resolved_src.parents:
        raise RailsError(
            f"output {out} is an ancestor of the source tree; the bundle would contain "
            f"the snapshot it claims to have converted"
        )
    if out.exists() and any(out.iterdir()):
        raise RailsError(
            f"output {out} is not empty; extraction must build into a clean directory so "
            f"stale files cannot be attested in hashes.json"
        )


def extract(
    src: Source,
    decisions: dict[str, Decision],
    out: Path,
    *,
    artifact_root: Path | None = None,
) -> dict[str, Any]:
    # Check the destination first: reconciliation is the expensive, noisy failure, and a
    # caller pointing at a dirty directory should hear about that immediately.
    _require_clean_output(out, src)
    _private_parent(out)
    findings = build_findings(src)
    reconcile(findings, decisions, artifact_root=artifact_root)

    database = require_sqlite(src)
    reset = decisions.get("auth.devise.pepper")
    emit_credentials = not (reset and reset.choice == "reset-passwords")
    mapped = map_tables(src, decisions)
    # Row-level checks, before the document is written: the import contract is valued
    # per ROW, and every column-level gate above can be satisfied by a schema whose own
    # data violates it.
    timestampless = _timestampless_collections(decisions)
    manifest_order = _manifest_order(mapped, timestampless)
    # Which tables actually HAVE a timestamp finding, and so can be routed by decision.
    # SQLite lets `''` satisfy NOT NULL on a datetime column, so a row can lack a
    # timestamp on a table that raised no finding at all -- and naming `separate-import`
    # there sent the operator to a decision `reconcile` then rejects as unknown.
    routable_tables = {
        split_id(f.id)[1]
        for f in findings
        if f.id.endswith((".no_timestamps", ".nullable_timestamps"))
    }
    with _connect(database) as scan:
        relaxed_required = _relax_required_for_empty_values(scan, mapped)
        _refuse_dangling_relation_values(scan, mapped)
        _refuse_duplicate_auth_identities(scan, mapped)
        _refuse_invalid_auth_identities(scan, mapped)
    document = build_schema_document(mapped, decisions)
    write_canonical_json(out / "schema.json", document, private=True)
    # Read back off the document rather than recomputing: a second, parallel call to
    # `_indexes_for` could drift from the one that actually produced the schema.
    emitted_indexes = {
        collection["name"]: {index["name"] for index in collection["indexes"]}
        for collection in document["collections"]
    }
    dropped_indexes = sorted(
        f"{entry.collection}.{index['name']}"
        for entry in mapped
        for index in entry.indexes
        if index["name"] not in emitted_indexes.get(entry.collection, set())
    )

    counts: dict[str, int] = {}
    ordinary: list[dict[str, str]] = []
    separate: list[dict[str, str]] = []
    _renames = _renamed_tables(decisions)
    timestampless = _timestampless_collections(decisions)
    auth_files: list[str] = []
    auth_files_no_timestamps: list[str] = []

    with _connect(database) as conn:
        files, dropped_attachments = build_file_plan(src, conn, mapped)
        index: dict[tuple[str, str, str], list[str]] = {}
        for item in files:
            index.setdefault(
                (item["collection"], item["recordId"], item["field"]), []
            ).append(item.get("targetName") or item["filename"])

        for entry in mapped:
            rows = read_rows(conn, entry)
            if entry.is_auth:
                relative = f"auth/{entry.collection}.ndjson"
                counts[entry.collection] = write_ndjson(
                    out / relative,
                    _importable_with_timestamps(
                        (
                            build_auth_record(
                                entry, r, index, emit_credentials=emit_credentials
                            )
                            for r in rows
                        ),
                        entry.collection,
                        entry.collection in timestampless,
                        entry.table in routable_tables,
                    ),
                )
                auth_files.append(relative)
                if entry.collection in timestampless:
                    # An auth file is imported on its own, not through a manifest, so
                    # there is no second manifest to route it to -- the operator has to
                    # drop `--preserve-timestamps` for this one file, and the report is
                    # the only place that can tell them.
                    auth_files_no_timestamps.append(relative)
            else:
                relative = f"data/{entry.collection}.ndjson"
                counts[entry.collection] = write_ndjson(
                    out / relative,
                    _importable_with_timestamps(
                        (build_record(entry, r, index) for r in rows),
                        entry.collection,
                        entry.collection in timestampless,
                        entry.table in routable_tables,
                    ),
                )
                # Manifest file paths resolve against the manifest's own directory,
                # which is the bundle root -- so this is `data/x.ndjson`, not `../`.
                if entry.collection in timestampless:
                    # These rows carry no created/updated, and the documented workflow
                    # runs the main manifest with --preserve-timestamps, which requires
                    # both on every row. Keeping them here produced a bundle that
                    # extracted cleanly and then failed the documented import.
                    separate.append({"collection": entry.collection, "file": relative})
                else:
                    ordinary.append({"collection": entry.collection, "file": relative})

    # Auth rows never ride in the ordinary manifest: --legacy-hashes applies to every
    # entry in a manifest, so a legacy-hash import has to be its own single-collection run.
    write_canonical_json(
        out / "manifest.json",
        {"zigbaseImportManifest": 1, "collections": ordinary},
        private=True,
    )
    if separate:
        # Imported WITHOUT --preserve-timestamps; the report names it so the operator
        # cannot miss that a second command is required.
        write_canonical_json(
            out / "manifest-no-timestamps.json",
            {"zigbaseImportManifest": 1, "collections": separate},
            private=True,
        )
    write_canonical_json(
        out / "files/manifest.json",
        {"zigbaseRailsFiles": BUNDLE_VERSION, "files": files},
        private=True,
    )

    _refuse_incoherent_row_counts(src, mapped, counts)

    oversized = _oversized_lines(out)
    if oversized:
        raise RailsError(
            f"{oversized[0][0]} contains a {oversized[0][1]}-byte record; ZigBase's "
            f"importer refuses any line over {IMPORT_LINE_LIMIT} bytes, so this bundle "
            f"would extract and hash cleanly and then fail to import"
        )

    report = {
        "zigbaseRailsBundle": BUNDLE_VERSION,
        "sourceMode": src.mode,
        # Bind the bundle to the exact snapshot it was built from, so a compatible but
        # different database cannot silently reuse an earlier set of decisions.
        "inventorySha256": _inventory_digest(src),
        "railsVersion": src.versions.get("rails_version"),
        "rubyVersion": src.versions.get("ruby_version"),
        "databaseSha256": sha256_file(database),
        "collections": [
            {
                "collection": entry.collection,
                "type": "auth" if entry.is_auth else "base",
                "rows": counts[entry.collection],
                "fields": len(entry.fields),
            }
            for entry in mapped
        ],
        # Only tables that were actually extracted: reporting an omitted table as
        # "timestamp mirrored" describes work the bundle never did.
        "timestampMirrored": sorted(
            entry.table
            for entry in mapped
            if {c["name"] for c in entry.columns} >= {"created_at"}
            and "updated_at" not in {c["name"] for c in entry.columns}
        ),
        "authFiles": sorted(auth_files),
        # Import these WITHOUT --preserve-timestamps; their rows carry no created.
        "authFilesNoTimestamps": sorted(auth_files_no_timestamps),
        "separateManifest": ("manifest-no-timestamps.json" if separate else None),
        # Strip-then-patch is scoped to one manifest run, so when relations cross the
        # boundary the manifests have to be imported in this order.
        "manifestOrder": manifest_order,
        "files": len(files),
        "findings": len(findings),
        "decisions": len(decisions),
        # Both ways a table leaves the migration. `_refuse_inert_decisions` already
        # unions these two; the report listed only the first, so a table dropped by an
        # STI `omit` disappeared from the bundle with nothing recording that it had —
        # the same understatement `publicRules` carried.
        "omittedTables": sorted(
            _omitted_tables(decisions) | _sti_omitted_tables(src, decisions)
        ),
        # An index can be dropped for several honest reasons -- it covered a column that
        # was omitted, it was partial and its predicate was not reviewed, it named a
        # field the engine owns. Every one of those was silent until now.
        "droppedIndexes": dropped_indexes,
        # Columns the source declares NOT NULL that nonetheless hold empty values, so
        # the field cannot be `required` in ZigBase's sense.
        "relaxedRequired": relaxed_required,
        # Blobs left behind: a decision dropped the field, or the row names an
        # attachment the model no longer declares.
        "droppedAttachments": dropped_attachments,
        # Read from the EMITTED SCHEMA, not from which decisions chose `public`. The
        # per-action rule form the guide teaches writes `create = @public` inside an
        # `expression` decision, and counting choices saw none of those -- so a bundle
        # granting anonymous create reported no public rules at all, which is the one
        # number an operator checks before deciding the surface is closed.
        #
        # Named by SOURCE table, not by emitted collection: the question this answers is
        # which Rails table's rules ended up open, and a renamed collection would hide
        # that behind its new name.
        "publicRules": sorted(
            {
                entry.table
                for entry in mapped
                for collection in document["collections"]
                if collection["name"] == entry.collection
                and any(
                    key.endswith("Rule") and value == PUBLIC_RULE
                    for key, value in collection.items()
                )
            }
        ),
    }
    write_canonical_json(out / "report.json", report, private=True)

    # Hashes last: they cover every other output, so the file that records them cannot
    # be part of what it records.
    entries = [
        {
            "path": path.relative_to(out).as_posix(),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        for path in sorted(p for p in out.rglob("*") if p.is_file())
        if path.name != "hashes.json"
    ]
    write_canonical_json(
        out / "hashes.json",
        {"zigbaseRailsHashes": BUNDLE_VERSION, "outputs": entries},
        private=True,
    )
    return report


def _contained(root: Path, *parts: str) -> Path:
    """Join `parts` under `root` and refuse anything that escapes it.

    Every component here comes from a bundle manifest -- a file on disk that a converter
    run produced but that nothing re-validates at install time. An absolute component or
    a `..` would otherwise read from, or write to, somewhere neither the frozen snapshot
    nor the data directory owns.
    """
    for part in parts:
        if not part or part in (".", ".."):
            raise RailsError(f"unsafe path component in the file manifest: {part!r}")
        candidate = Path(part)
        if candidate.is_absolute() or ".." in candidate.parts:
            raise RailsError(f"unsafe path component in the file manifest: {part!r}")
        # One component, always. Active Storage keeps the client-supplied filename
        # verbatim, so `a/b.png` is reachable data -- and it would install two levels
        # deep, where the file API (which serves {collection}/{record}/{name}) can never
        # match it. Installed cleanly, then 404.
        if len(candidate.parts) != 1 or "/" in part or "\\" in part:
            raise RailsError(
                f"a stored file name must be a single path component: {part!r}"
            )

    resolved_root = root.resolve()
    target = resolved_root.joinpath(*parts)

    # Which path to resolve matters, and getting it wrong is a real escape: resolving
    # only the parent lets a leaf SYMLINK through, so `source/storage/ab/cd/blob ->
    # /etc/passwd` would satisfy containment and then be read. Resolve the whole path
    # whenever it exists -- which the read side always does -- and fall back to the
    # parent only for a destination that has yet to be created.
    probe = target if target.exists() or target.is_symlink() else target.parent
    resolved = probe.resolve()
    if resolved != resolved_root and resolved_root not in resolved.parents:
        raise RailsError(f"file manifest escapes {root}: {target}")
    return target


def _oversized_lines(out: Path) -> list[tuple[str, int]]:
    found: list[tuple[str, int]] = []
    for path in sorted(out.rglob("*.ndjson")):
        # `split("\n")`, never `splitlines()`: the engine reads physical newline-
        # delimited lines (`takeDelimiter('\n')`), while `splitlines()` also breaks on
        # U+2028, U+2029 and U+0085 -- which `canonical_line` emits RAW, because it
        # serializes with `ensure_ascii=False` and json only escapes below U+0020. A
        # record over the limit whose separator-delimited fragments each fit would have
        # measured as several short lines, passed, been certified in `hashes.json`, and
        # then died at import with LineTooLong: exactly what this check exists to stop.
        for line in path.read_text(encoding="utf-8").split("\n"):
            if len(line.encode("utf-8")) >= IMPORT_LINE_LIMIT:
                found.append((path.name, len(line.encode("utf-8"))))
                break
    return found


def _inventory_digest(src: Source) -> str:
    """One digest over every inventory file, in a fixed order."""
    digest = hashlib.sha256()
    for name in INVENTORY_FILES:
        digest.update(name.encode())
        digest.update(
            read_bytes(
                src.root / "inventory" / f"{name}.json",
                label=f"inventory/{name}.json",
            )
        )
    return digest.hexdigest()


def install_files(bundle: Path, source_root: Path, data_dir: Path) -> dict[str, int]:
    manifest = read_json(bundle / "files/manifest.json", label="file manifest")
    plan = manifest.get("files") or []
    installed = reused = 0
    for item in plan:
        origin = _contained(source_root, *Path(item["sourcePath"]).parts)
        if not origin.is_file():
            raise RailsError(f"bundle references a missing blob: {origin}")
        # Field and key are part of the identity: `has_one_attached :cover` and
        # `:thumbnail` on one record can both be `image.png`. Keyed only by filename,
        # differing bytes abort the install and identical bytes collapse ambiguously.
        destination = _contained(
            data_dir,
            "storage",
            item["collection"],
            item["recordId"],
            item.get("targetName") or item["filename"],
        )
        digest = sha256_file(origin)
        recorded = item.get("sha256")
        if recorded and recorded != digest:
            raise RailsError(
                f"blob {item['key']} changed since extraction: the bundle recorded "
                f"{recorded[:12]}… and the snapshot now holds {digest[:12]}…"
            )
        if item.get("bytes") is not None and origin.stat().st_size != item["bytes"]:
            raise RailsError(
                f"blob {item['key']} is {origin.stat().st_size} bytes; the bundle "
                f"recorded {item['bytes']}"
            )
        if install_file_atomic(origin, destination, digest):
            installed += 1
        else:
            reused += 1
    return {"files": len(plan), "installed": installed, "reused": reused}


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def cmd_inventory(args: argparse.Namespace) -> int:
    ensure_output_outside_source(args.out, args.source)
    src = load_source(args.source)
    inventory = build_inventory(src)
    write_canonical_json(args.out, inventory)
    summary = inventory["summary"]
    print(
        compact_summary(
            {
                "zigbase_rails_inventory": INVENTORY_VERSION,
                "out": str(args.out),
                "sourceMode": src.mode,
                **summary,
            }
        )
    )
    # Exit 2 is "judgment required", not failure: findings are the expected output of
    # an inventory, and a source with none is the unusual case.
    return 2 if (summary["blockers"] or summary["decisions"]) else 0


def cmd_extract(args: argparse.Namespace) -> int:
    ensure_output_outside_source(args.out, args.source)
    src = load_source(args.source)
    decisions = load_decisions(args.decisions)
    # Artifact paths are relative to the decisions file that names them, which is the
    # only location an operator can reasonably be said to have meant.
    report = extract(
        src, decisions, args.out, artifact_root=args.decisions.resolve().parent
    )
    print(
        compact_summary(
            {
                "zigbase_rails_extract": BUNDLE_VERSION,
                "out": str(args.out),
                "collections": len(report["collections"]),
                "rows": sum(c["rows"] for c in report["collections"]),
                "files": report["files"],
                "publicRules": len(report["publicRules"]),
            }
        )
    )
    return 0


def cmd_install_files(args: argparse.Namespace) -> int:
    result = install_files(args.bundle, args.source, args.data_dir)
    print(compact_summary({"zigbase_rails_file_install": BUNDLE_VERSION, **result}))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="rails2zb", description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    inv = sub.add_parser("inventory", help="enumerate findings from a frozen source")
    inv.add_argument("--source", type=Path, required=True)
    inv.add_argument("--out", type=Path, required=True)
    inv.set_defaults(func=cmd_inventory)

    ext = sub.add_parser("extract", help="emit a deterministic migration bundle")
    ext.add_argument("--source", type=Path, required=True)
    ext.add_argument("--decisions", type=Path, required=True)
    ext.add_argument("--out", type=Path, required=True)
    ext.set_defaults(func=cmd_extract)

    ins = sub.add_parser("install-files", help="place Active Storage blobs")
    ins.add_argument("--bundle", type=Path, required=True)
    ins.add_argument("--source", type=Path, required=True)
    ins.add_argument("--data-dir", type=Path, required=True)
    ins.set_defaults(func=cmd_install_files)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except RailsError as exc:
        print(f"rails2zb: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
