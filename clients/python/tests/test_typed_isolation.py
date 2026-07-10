"""Locks in `zigbase.typed`'s no-Pydantic contract (its module docstring:
"has no dependency on Pydantic ... a concern of *generated* code ... not of
this module") the same way `test_realtime_wiring.py`'s
`TestOptionalDependencyContract` locks in the `websockets` one.

The dev venv installs `pydantic` (it's needed to exercise the golden
generated client under `tests/codegen/`), so a plain in-process import check
would pass even if `zigbase.typed` grew a hidden top-level `import pydantic`
-- Pydantic being present would silently paper over it. A fresh subprocess
that poisons `sys.modules['pydantic'] = None` *before* importing anything
closes that gap: Python's import machinery raises `ImportError` immediately
on any subsequent `import pydantic` while that sentinel is in place, so
`import zigbase; import zigbase.typed` only succeeds if neither module
actually needs it.
"""

from __future__ import annotations

import subprocess
import sys


class TestPydanticOptionalDependencyContract:
    def test_import_zigbase_typed_succeeds_with_pydantic_blocked(self) -> None:
        script = (
            "import sys\n"
            "sys.modules['pydantic'] = None\n"
            "import zigbase\n"
            "import zigbase.typed\n"
            "assert sys.modules.get('pydantic') is None, "
            "'pydantic was actually imported despite being blocked'\n"
        )
        result = subprocess.run(
            [sys.executable, "-c", script],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, (
            f"'import zigbase; import zigbase.typed' failed (or imported "
            f"pydantic) with pydantic blocked\n"
            f"stdout={result.stdout!r} stderr={result.stderr!r}"
        )
