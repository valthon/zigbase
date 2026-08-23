"""Eval fixture workspaces are DATA, not this repository's tests.

Each one contains a `tests/test_migration.py` that the agent was asked to write and
that the grader runs inside the workspace. Collecting them here runs them against the
repository root, where their relative paths mean something else — and two scenarios
carrying the same filename collide outright, which is how this was noticed.
"""

collect_ignore_glob = ["*"]
