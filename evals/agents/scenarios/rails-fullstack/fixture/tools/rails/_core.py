"""Source-agnostic primitives shared by the Rails converter's subcommands.

Everything here is deliberately free of Rails knowledge: determinism helpers, bounded
readers, digests, and the bundle envelope. The Rails-specific mapping lives in
``rails2zb.py`` so the parts that must be byte-stable stay small and reviewable.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


class RailsError(Exception):
    """A bounded, user-actionable input or tool failure."""


# ---------------------------------------------------------------------------
# Bounded reads
# ---------------------------------------------------------------------------

# A frozen inventory file is small. A source that hands us a hundred-megabyte
# "routes.json" is a mistake or an attack, not a migration, so every read is bounded
# and the limit is part of the contract rather than a defensive afterthought.
JSON_LIMIT = 32 * 1024 * 1024
OBSERVED = "observed"
INFERRED = "inferred"
SOURCE_MODES = frozenset({OBSERVED, INFERRED})


def read_json(path: Path, *, limit: int = JSON_LIMIT, label: str = "file") -> Any:
    payload = read_bytes(path, limit=limit, label=label)
    return parse_json(payload, path=path, label=label)


def read_bytes(path: Path, *, limit: int = JSON_LIMIT, label: str = "file") -> bytes:
    try:
        with path.open("rb") as source:
            payload = source.read(limit + 1)
    except OSError as exc:
        raise RailsError(f"cannot read {label} {path}: {exc}") from exc
    if len(payload) > limit:
        raise RailsError(f"{label} exceeds the {limit}-byte limit: {path}")
    return payload


def reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number {value}")


def parse_finite_float(value: str) -> float:
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"non-finite JSON number {value}")
    return number


def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def parse_json(payload: bytes, *, path: Path, label: str = "file") -> Any:
    try:
        return json.loads(
            payload.decode("utf-8"),
            parse_constant=reject_json_constant,
            parse_float=parse_finite_float,
            object_pairs_hook=reject_duplicate_keys,
        )
    except (UnicodeError, json.JSONDecodeError, ValueError) as exc:
        raise RailsError(f"cannot read {label} {path}: {exc}") from exc


def read_json_with_sha256(
    path: Path, *, limit: int = JSON_LIMIT, label: str = "file"
) -> tuple[Any, str]:
    """Parse and hash the same bounded bytes so provenance cannot race the parser."""
    payload = read_bytes(path, limit=limit, label=label)
    return parse_json(payload, path=path, label=label), hashlib.sha256(
        payload
    ).hexdigest()


def sha256_file(path: Path) -> str:
    """Hash a complete file with constant memory."""
    digest = hashlib.sha256()
    try:
        with path.open("rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as exc:
        raise RailsError(f"cannot hash {path}: {exc}") from exc
    return digest.hexdigest()


def required_string(value: dict[str, Any], key: str, where: str) -> str:
    result = value.get(key)
    if not isinstance(result, str) or not result:
        raise RailsError(f"{where}.{key} must be a non-empty string")
    return result


def nested_source_modes(value: Any) -> set[str]:
    """Return every observed/inferred provenance marker nested in a JSON value."""
    found: set[str] = set()
    if isinstance(value, dict):
        # ``source`` is also an ordinary Rails attribute/parameter name and the
        # pattern-text field in Regexp descriptors. Only the two reserved string
        # values are provenance markers; arbitrary nested data must remain data.
        marker = value.get("source")
        if isinstance(marker, str) and marker in SOURCE_MODES:
            found.add(marker)
        for nested in value.values():
            found |= nested_source_modes(nested)
    elif isinstance(value, list):
        for nested in value:
            found |= nested_source_modes(nested)
    return found


def validate_inventory_source(
    payload: Any,
    *,
    name: str,
    expected_mode: str | None = None,
) -> str:
    """Validate one rails2zb inventory document's provenance contract."""
    if not isinstance(payload, dict):
        raise RailsError(f"inventory/{name}.json must be a JSON object")
    declared = payload.get("source")
    if declared not in SOURCE_MODES:
        raise RailsError(
            f"inventory/{name}.json does not declare source 'observed' or 'inferred'"
        )
    mode = expected_mode or declared
    if mode not in SOURCE_MODES:
        raise RailsError(f"inventory source mode {mode!r} is unsupported")
    if declared != mode:
        raise RailsError(
            f"inventory/{name}.json declares source {declared!r} but the inventory "
            f"is {mode!r}; observed and inferred records must not be mixed"
        )
    mixed = nested_source_modes(payload) - {mode}
    if mixed:
        raise RailsError(
            f"inventory/{name}.json declares {mode!r} but contains nested records "
            f"marked {sorted(mixed)}; observed and inferred records must not be mixed"
        )
    return mode


# ---------------------------------------------------------------------------
# Deterministic writers
# ---------------------------------------------------------------------------
#
# Byte-identical reruns are the whole basis for trusting a migration bundle, so every
# writer here sorts keys, pins separators, and ends the file with a newline. Nothing in
# this module may consult the clock, the environment, or a random source.


def canonical_text(value: Any) -> str:
    try:
        return (
            json.dumps(
                value, indent=2, ensure_ascii=False, sort_keys=True, allow_nan=False
            )
            + "\n"
        )
    except (TypeError, ValueError) as exc:  # non-JSON value or non-finite float
        raise RailsError(f"cannot encode canonical JSON: {exc}") from exc


def _private_parent(path: Path) -> None:
    existed = path.exists()
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not existed:
        path.chmod(0o700)


def _atomic_text(path: Path, payload: str, *, mode: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
    )
    temporary: Path | None = Path(temporary_name)
    try:
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def write_canonical_json(path: Path, value: Any, *, private: bool = False) -> None:
    """Atomically replace ``path`` with deterministic JSON."""
    try:
        if private:
            _private_parent(path.parent)
        mode = 0o600 if private else 0o644
        if not private and path.is_file():
            mode = stat.S_IMODE(path.stat().st_mode)
        _atomic_text(path, canonical_text(value), mode=mode)
    except (OSError, TypeError, ValueError) as exc:
        raise RailsError(f"cannot write {path}: {exc}") from exc


def canonical_line(record: Any) -> str:
    """One canonical JSON object.

    `allow_nan` is off deliberately: Python's default emits bare `Infinity`/`NaN`, which
    are not JSON. SQLite stores a REAL infinity happily, so the bundle came out
    malformed -- and `hashes.json` then certified the malformed bytes.
    """
    try:
        return json.dumps(
            record,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
    except ValueError as exc:
        raise RailsError(
            f"row {record.get('id')!r} holds a value JSON cannot represent ({exc}); "
            f"the bundle would be malformed and hashed as if it were not"
        ) from exc


def write_ndjson(path: Path, records: Iterable[Any]) -> int:
    """Atomically write private canonical NDJSON. Returns the row count."""
    count = 0
    descriptor = -1
    temporary: Path | None = None
    try:
        _private_parent(path.parent)
        descriptor, temporary_name = tempfile.mkstemp(
            dir=path.parent, prefix=f".{path.name}.", suffix=".tmp"
        )
        temporary = Path(temporary_name)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as sink:
            descriptor = -1
            for record in records:
                sink.write(canonical_line(record))
                sink.write("\n")
                count += 1
            sink.flush()
            os.fsync(sink.fileno())
        os.replace(temporary, path)
        temporary = None
    except (OSError, TypeError, ValueError) as exc:
        raise RailsError(f"cannot write {path}: {exc}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return count


def compact_summary(value: dict[str, Any]) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=True)


# ---------------------------------------------------------------------------
# Findings and decisions
# ---------------------------------------------------------------------------


def escape_part(part: str) -> str:
    """Escape one identity part so the joined id can be split back apart.

    The escape must be REVERSIBLE. Mapping `.` to `_` is not: consumers split a
    decision id and compare the resulting parts against the raw inventory, so a
    schema-qualified table like `legacy.posts` produced parts that matched nothing
    and every decision about it was silently ignored. Percent-escaping round-trips,
    so a dotted name keeps working instead of having to be refused.
    """
    return part.replace("%", "%25").replace(".", "%2E")


def unescape_part(part: str) -> str:
    """Inverse of `escape_part`; the order undoes the escaping exactly."""
    return part.replace("%2E", ".").replace("%25", "%")


def finding_id(*parts: str) -> str:
    """Join identity parts, escaping the separator so ids stay unambiguous."""
    return ".".join(escape_part(part) for part in parts)


def split_id(fid: str) -> list[str]:
    """Split a finding id back into its RAW identity parts.

    Every consumer that dispatches on a decision id must use this rather than a bare
    `str.split`, or it compares escaped text against raw inventory names.
    """
    return [unescape_part(part) for part in fid.split(".")]


@dataclass(frozen=True)
class Finding:
    """A stable migration finding.

    The message is prose for a human and deliberately NOT part of the identity: rewording
    a message must never invalidate a decision an operator already recorded against it.
    """

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


# ---------------------------------------------------------------------------
# Output-path safety
# ---------------------------------------------------------------------------


def ensure_output_outside_source(out: Path, source: Path) -> None:
    """Refuse an output path that could overwrite any part of the frozen source."""
    try:
        resolved_out = out.resolve()
        resolved_source = source.resolve(strict=True)
    except OSError as exc:
        raise RailsError(f"cannot resolve paths safely: {exc}") from exc
    lexical_out = Path(os.path.abspath(out))
    lexical_source = Path(os.path.abspath(source))
    if (
        resolved_out == resolved_source
        or resolved_out.is_relative_to(resolved_source)
        or lexical_out == lexical_source
        or lexical_out.is_relative_to(lexical_source)
    ):
        raise RailsError("output must be written outside the frozen source tree")


def install_file_atomic(source: Path, destination: Path, digest: str) -> bool:
    """Install one file atomically. Returns True when this call created it.

    An identical file already in place is a benign retry; a file with the same path and
    different content is a hard stop, because silently overwriting it would destroy
    evidence of a collision the operator needs to see.
    """
    if sha256_file(source) != digest:
        raise RailsError(f"bundle file {source} does not match its recorded digest")
    if destination.exists():
        if sha256_file(destination) == digest:
            return False
        raise RailsError(
            f"refusing to overwrite {destination}: existing file differs from the bundle"
        )
    descriptor = -1
    temporary: Path | None = None
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        descriptor, temporary_name = tempfile.mkstemp(
            dir=destination.parent, prefix=".zigbase-install-"
        )
        temporary = Path(temporary_name)
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as output_file:
            descriptor = -1
            with source.open("rb") as input_file:
                while chunk := input_file.read(1024 * 1024):
                    output_file.write(chunk)
                output_file.flush()
                os.fsync(output_file.fileno())
        if sha256_file(temporary) != digest:
            raise RailsError(f"bundle file {source} changed while being copied")
        os.replace(temporary, destination)
        temporary = None
    except OSError as exc:
        raise RailsError(f"cannot install {destination}: {exc}") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return True
