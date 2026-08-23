"""Deterministic grader interface and dispatch."""

from __future__ import annotations

import importlib
from dataclasses import dataclass
from pathlib import Path

from ..result import EvalFailure


#: Every grader a scenario may declare. Names use the manifest's hyphen convention;
#: `grade` maps each to its module.
GRADERS = frozenset({"genesis", "pocketbase", "rails-api"})


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
        if name not in GRADERS:
            raise ValueError(f"unknown grader: {name}")
        # A manifest grader name is `[a-z0-9][a-z0-9-]*` (scenario.py), which admits a
        # hyphen; a Python module name cannot carry one and still be imported normally
        # by the tests. Translate rather than force one side to give: `rails-api` reads
        # as the scenario does, and lives in `rails_api.py`.
        module = importlib.import_module(f"{__name__}.{name.replace('-', '_')}")
        reports.append(module.grade(workspace=workspace, artifacts=artifacts))

    return GradeReport(
        completion=all(report.completion for report in reports),
        rules_locked=all(report.rules_locked for report in reports),
        tests_green=all(report.tests_green for report in reports),
        deployed=all(report.deployed for report in reports),
        failures=tuple(failure for report in reports for failure in report.failures),
    )
