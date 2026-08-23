"""A test that asserts nothing passes forever, and says it covered something.

Five of these had accumulated in this suite by round 34 — each written as "must not
refuse", each of which would also have passed had the setup silently failed to build
the scenario it was named for. The class is cheap to detect mechanically, so it is
detected mechanically rather than by the next reviewer.
"""

from __future__ import annotations

import ast
import pathlib

# Tests whose whole contract is "this call completes": the call itself raises on
# failure, so there is nothing further to assert. Every entry needs that to be true of
# the callee — `argparse` exits, `reconcile` raises — not merely convenient.
ASSERTION_FREE_BY_CONTRACT = {
    # `reconcile` raises on any unsatisfied decision; completing IS the assertion.
    "test_a_complete_decision_set_reconciles",
    "test_omitting_behavior_needs_no_artifact",
    # `parse_args` raises SystemExit on a bad command line. Its parameter list is
    # separately guarded against being empty by
    # `test_the_guide_documents_the_commands_it_claims_to`.
    "test_documented_converter_commands_parse",
}

SUITE = pathlib.Path(__file__).parent


def _asserts_something(node: ast.AST) -> bool:
    """True when the body contains an `assert`, or a `pytest.raises`-style guard.

    Matched on AST node shape rather than by searching `ast.dump` text, which would also
    match a string literal that happened to contain the word.

    The traversal stops at a nested `def` or `lambda`: their bodies only run if the test
    calls them, so an `assert` inside one the test never invokes proves nothing — and
    `ast.walk` descends into them, which made exactly that shape count as asserting.

    Only `pytest.raises` in ATTRIBUTE form counts, not a bare `raises` imported from
    pytest. That is deliberate rather than an oversight: a test written that way is
    over-flagged, which fails this file loudly and is fixed in one line, whereas
    matching a bare name would exempt any test that happens to bind `raises` — and an
    exemption is silent. Where the two error directions are not equal, take the loud one.

    Two limits remain, both silent. This proves a test CAN fail, not that it fails for
    the right reason — `assert True` satisfies it. And any attribute named `raises` or
    `warns` counts whether or not it is ever entered, so a bare `pytest.raises`
    reference standing alone satisfies it too. Nothing mechanical catches either; that
    is what review is for.
    """
    nested = (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)
    pending = list(ast.iter_child_nodes(node))
    while pending:
        child = pending.pop()
        if isinstance(child, ast.Assert):
            return True
        # `pytest.raises(...)` / `pytest.warns(...)`: the guard IS the assertion.
        if isinstance(child, ast.Attribute) and child.attr in ("raises", "warns"):
            return True
        if isinstance(child, nested):
            continue
        pending.extend(ast.iter_child_nodes(child))
    return False


def _tests_without_assertions() -> dict[str, str]:
    out: dict[str, str] = {}
    for path in sorted(SUITE.glob("test_*.py")):
        tree = ast.parse(path.read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if not isinstance(node, ast.FunctionDef | ast.AsyncFunctionDef):
                continue
            if not node.name.startswith("test_"):
                continue
            if _asserts_something(node):
                continue
            out[node.name] = f"{path.name}:{node.lineno}"
    return out


def test_every_test_asserts_something():
    found = _tests_without_assertions()
    unexpected = {n: w for n, w in found.items() if n not in ASSERTION_FREE_BY_CONTRACT}
    assert not unexpected, (
        f"these tests assert nothing, so they cannot fail: {unexpected}. Either assert "
        f"the outcome, or add the name to ASSERTION_FREE_BY_CONTRACT with the reason "
        f"the call itself raises."
    )


def test_the_allowlist_has_no_stale_entries():
    """An exemption for a test that now asserts something is misleading in both ways."""
    stale = ASSERTION_FREE_BY_CONTRACT - set(_tests_without_assertions())
    assert not stale, f"these no longer need an exemption: {sorted(stale)}"
