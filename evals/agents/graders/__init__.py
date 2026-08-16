"""Deterministic grader interface and dispatch."""

from __future__ import annotations

import importlib
from dataclasses import dataclass
from pathlib import Path

from ..result import EvalFailure


@dataclass(frozen=True)
class GradeReport:
    completion: bool
    rules_locked: bool
    tests_green: bool
    deployed: bool
    failures: tuple[EvalFailure, ...] = ()


def grade(names: tuple[str, ...], workspace: Path, artifacts: Path) -> GradeReport:
    """Dispatch the scenario's declared graders and combine independent grades."""
    reports = []
    for name in names:
        if name not in {"genesis"}:
            raise ValueError(f"unknown grader: {name}")
        module = importlib.import_module(f"{__name__}.{name}")
        reports.append(module.grade(workspace=workspace, artifacts=artifacts))

    return GradeReport(
        completion=all(report.completion for report in reports),
        rules_locked=all(report.rules_locked for report in reports),
        tests_green=all(report.tests_green for report in reports),
        deployed=all(report.deployed for report in reports),
        failures=tuple(failure for report in reports for failure in report.failures),
    )
