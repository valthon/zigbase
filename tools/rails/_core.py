"""Source-agnostic primitives shared by the Rails converter's subcommands.

Everything here is deliberately free of Rails knowledge: determinism helpers, bounded
readers, digests, and the bundle envelope. The Rails-specific mapping lives in
``rails2zb.py`` so the parts that must be byte-stable stay small and reviewable.
"""

from __future__ import annotations

import hashlib
import json
import os
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


def read_json(path: Path, *, limit: int = JSON_LIMIT, label: str = "file") -> Any:
    try:
        size = path.stat().st_size
    except OSError as exc:
        raise RailsError(f"cannot stat {label} {path}: {exc}") from exc
    if size > limit:
        raise RailsError(f"{label} exceeds the {limit}-byte limit: {path}")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise RailsError(f"cannot read {label} {path}: {exc}") from exc


def sha256_file(path: Path) -> str:
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


# ---------------------------------------------------------------------------
# Deterministic writers
# ---------------------------------------------------------------------------
#
# Byte-identical reruns are the whole basis for trusting a migration bundle, so every
# writer here sorts keys, pins separators, and ends the file with a newline. Nothing in
# this module may consult the clock, the environment, or a random source.


def write_canonical_json(path: Path, value: Any) -> None:
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(
            json.dumps(
                value, indent=2, ensure_ascii=False, sort_keys=True, allow_nan=False
            )
            + "\n",
            encoding="utf-8",
        )
    except OSError as exc:
        raise RailsError(f"cannot write {path}: {exc}") from exc
    except ValueError as exc:  # non-finite float
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
    """Write one canonical JSON object per line. Returns the row count."""
    count = 0
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("w", encoding="utf-8", newline="\n") as sink:
            for record in records:
                sink.write(canonical_line(record))
                sink.write("\n")
                count += 1
    except OSError as exc:
        raise RailsError(f"cannot write {path}: {exc}") from exc
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
    if resolved_out == resolved_source or resolved_out.is_relative_to(resolved_source):
        raise RailsError("output must be written outside the frozen source tree")


def install_file_atomic(source: Path, destination: Path, digest: str) -> bool:
    """Install one file atomically. Returns True when this call created it.

    An identical file already in place is a benign retry; a file with the same path and
    different content is a hard stop, because silently overwriting it would destroy
    evidence of a collision the operator needs to see.
    """
    if destination.exists():
        if sha256_file(destination) == digest:
            return False
        raise RailsError(
            f"refusing to overwrite {destination}: existing file differs from the bundle"
        )
    try:
        destination.parent.mkdir(parents=True, exist_ok=True)
        handle, temporary = tempfile.mkstemp(
            dir=destination.parent, prefix=".zigbase-install-"
        )
        os.close(handle)
        staged = Path(temporary)
        staged.write_bytes(source.read_bytes())
        if sha256_file(staged) != digest:
            staged.unlink(missing_ok=True)
            raise RailsError(f"bundle file {source} does not match its recorded digest")
        os.replace(staged, destination)
    except OSError as exc:
        raise RailsError(f"cannot install {destination}: {exc}") from exc
    return True
