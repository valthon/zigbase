"""Stable, sanitized result contract for provider-neutral agent evaluations."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, ClassVar


class ResultError(ValueError):
    """An evaluation result violates the public contract."""


@dataclass(frozen=True)
class EvalFailure:
    code: str
    message: str

    _FIELDS: ClassVar[tuple[str, ...]] = ("code", "message")

    @classmethod
    def from_dict(cls, value: Any) -> "EvalFailure":
        if not isinstance(value, dict) or set(value) != set(cls._FIELDS):
            raise ResultError("each failure must contain exactly code and message")
        if not all(isinstance(value[key], str) and value[key] for key in cls._FIELDS):
            raise ResultError("failure code and message must be non-empty strings")
        return cls(**value)


@dataclass(frozen=True)
class EvalResult:
    zigbaseAgentEval: int
    scenario: str
    commit: str
    agent: str
    started_at: str
    duration_ms: int
    agent_exit: int
    timed_out: bool
    interventions: int
    completion: bool
    rules_locked: bool
    tests_green: bool
    deployed: bool
    score: int
    failures: tuple[EvalFailure, ...]

    VERSION: ClassVar[int] = 1
    FIELDS: ClassVar[tuple[str, ...]] = (
        "zigbaseAgentEval",
        "scenario",
        "commit",
        "agent",
        "started_at",
        "duration_ms",
        "agent_exit",
        "timed_out",
        "interventions",
        "completion",
        "rules_locked",
        "tests_green",
        "deployed",
        "score",
        "failures",
    )

    def __post_init__(self) -> None:
        if self.zigbaseAgentEval != self.VERSION:
            raise ResultError(
                f"unsupported zigbaseAgentEval version: {self.zigbaseAgentEval!r}"
            )
        for name in ("scenario", "commit", "agent", "started_at"):
            if not isinstance(getattr(self, name), str) or not getattr(self, name):
                raise ResultError(f"{name} must be a non-empty string")
        try:
            datetime.fromisoformat(self.started_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise ResultError("started_at must be an ISO-8601 timestamp") from exc
        for name in ("duration_ms", "interventions", "score"):
            value = getattr(self, name)
            if isinstance(value, bool) or not isinstance(value, int) or value < 0:
                raise ResultError(f"{name} must be a non-negative integer")
        if isinstance(self.agent_exit, bool) or not isinstance(self.agent_exit, int):
            raise ResultError("agent_exit must be an integer")
        grades = (self.completion, self.rules_locked, self.tests_green, self.deployed)
        if not all(isinstance(value, bool) for value in (*grades, self.timed_out)):
            raise ResultError("grade and timed_out fields must be booleans")
        if self.score != sum(grades):
            raise ResultError("score must equal the number of passing grades")
        if not isinstance(self.failures, tuple) or not all(
            isinstance(failure, EvalFailure) for failure in self.failures
        ):
            raise ResultError("failures must be a tuple of EvalFailure values")

    @classmethod
    def from_dict(cls, value: Any) -> "EvalResult":
        if not isinstance(value, dict) or set(value) != set(cls.FIELDS):
            raise ResultError(f"result fields must be exactly {list(cls.FIELDS)}")
        prepared = dict(value)
        if not isinstance(prepared["failures"], list):
            raise ResultError("failures must be an array")
        prepared["failures"] = tuple(
            EvalFailure.from_dict(item) for item in prepared["failures"]
        )
        return cls(**prepared)

    @classmethod
    def from_json(cls, text: str) -> "EvalResult":
        try:
            value = json.loads(text)
        except json.JSONDecodeError as exc:
            raise ResultError(f"invalid result JSON: {exc.msg}") from exc
        return cls.from_dict(value)

    def to_dict(self) -> dict[str, Any]:
        value = asdict(self)
        value["failures"] = [asdict(failure) for failure in self.failures]
        return {name: value[name] for name in self.FIELDS}

    def to_json(self) -> str:
        return json.dumps(self.to_dict(), separators=(",", ":"))


def resolve_output_path(path: Path, output_root: Path) -> Path:
    """Resolve an output path without permitting writes outside output_root."""
    root = output_root.resolve()
    target = path if path.is_absolute() else root / path
    target = target.resolve()
    if target == root or root not in target.parents:
        raise ResultError(
            "result output must be a file below the selected output directory"
        )
    return target
