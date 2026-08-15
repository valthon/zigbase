"""Strict scenario manifest contract for provider-neutral agent evaluations."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any, ClassVar


class ScenarioError(ValueError):
    """A scenario manifest violates the runner contract."""


def _relative_path(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\\" in value:
        raise ScenarioError(f"{field} must be a non-empty POSIX relative path")
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        raise ScenarioError(f"{field} must stay below the scenario directory")
    return value


@dataclass(frozen=True)
class AgentScenario:
    zigbaseAgentScenario: int
    name: str
    prompt: str
    fixture: str | None
    graders: tuple[str, ...]
    timeout_seconds: int
    term_grace_seconds: int
    max_command_bytes: int
    max_output_bytes: int

    VERSION: ClassVar[int] = 1
    FIELDS: ClassVar[tuple[str, ...]] = (
        "zigbaseAgentScenario",
        "name",
        "prompt",
        "fixture",
        "graders",
        "timeout_seconds",
        "term_grace_seconds",
        "max_command_bytes",
        "max_output_bytes",
    )
    MAX_TIMEOUT_SECONDS: ClassVar[int] = 7_200
    MAX_COMMAND_BYTES: ClassVar[int] = 65_536
    MAX_OUTPUT_BYTES: ClassVar[int] = 16 * 1024 * 1024

    def __post_init__(self) -> None:
        if self.zigbaseAgentScenario != self.VERSION:
            raise ScenarioError(
                f"unsupported zigbaseAgentScenario version: {self.zigbaseAgentScenario!r}"
            )
        if not isinstance(self.name, str) or not re.fullmatch(
            r"[a-z0-9][a-z0-9-]*", self.name
        ):
            raise ScenarioError(
                "name must contain lowercase letters, digits, and hyphens"
            )
        _relative_path(self.prompt, "prompt")
        if self.fixture is not None:
            _relative_path(self.fixture, "fixture")
        if not isinstance(self.graders, tuple) or not self.graders:
            raise ScenarioError("graders must be a non-empty array")
        if len(set(self.graders)) != len(self.graders) or not all(
            isinstance(name, str) and re.fullmatch(r"[a-z0-9][a-z0-9-]*", name)
            for name in self.graders
        ):
            raise ScenarioError("graders must contain unique lowercase names")
        limits = {
            "timeout_seconds": (self.timeout_seconds, self.MAX_TIMEOUT_SECONDS),
            "term_grace_seconds": (self.term_grace_seconds, 60),
            "max_command_bytes": (self.max_command_bytes, self.MAX_COMMAND_BYTES),
            "max_output_bytes": (self.max_output_bytes, self.MAX_OUTPUT_BYTES),
        }
        for name, (value, maximum) in limits.items():
            if (
                isinstance(value, bool)
                or not isinstance(value, int)
                or not 1 <= value <= maximum
            ):
                raise ScenarioError(f"{name} must be an integer from 1 to {maximum}")

    @classmethod
    def from_dict(cls, value: Any) -> "AgentScenario":
        if not isinstance(value, dict) or set(value) != set(cls.FIELDS):
            raise ScenarioError(f"scenario fields must be exactly {list(cls.FIELDS)}")
        prepared = dict(value)
        if not isinstance(prepared["graders"], list):
            raise ScenarioError("graders must be an array")
        prepared["graders"] = tuple(prepared["graders"])
        return cls(**prepared)

    @classmethod
    def load(cls, manifest_path: Path) -> "AgentScenario":
        if manifest_path.is_symlink() or manifest_path.parent.is_symlink():
            raise ScenarioError("scenario root and manifest must not be symlinks")
        try:
            value = json.loads(manifest_path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise ScenarioError(f"cannot load scenario manifest: {exc}") from exc
        scenario = cls.from_dict(value)
        root = manifest_path.parent.resolve()
        for field in ("prompt", "fixture"):
            relative = getattr(scenario, field)
            if relative is None:
                continue
            target = root / relative
            if target.is_symlink() or root not in target.resolve().parents:
                raise ScenarioError(
                    f"{field} must resolve below the scenario directory without symlinks"
                )
            if field == "prompt" and not target.is_file():
                raise ScenarioError("prompt file does not exist")
            if field == "fixture" and not target.is_dir():
                raise ScenarioError("fixture directory does not exist")
        return scenario
