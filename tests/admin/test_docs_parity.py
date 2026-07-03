"""Doc-drift guards (R2, audit api-ergonomics E2/E12/N12).

Pure text tests: no server, no browser. They parse source + docs and fail when
either drifts. If one fails, fix the DOCS (or, for a deliberately-undocumented
var, add it to the allowlist below with a comment).
"""
import pathlib, re

REPO = pathlib.Path(__file__).resolve().parents[2]

# Config keys legitimately absent from the docs/framework.md §3 table (none today —
# every key in framework.zig's `allowed` tuple is a real, documented consumer-facing
# knob). Kept as an explicit allowlist, not silent omission, so a future internal-only
# key doesn't have to fight this test to land — it earns its way in with a comment.
CONFIG_KEY_ALLOWLIST: set[str] = set()

def _allowed_keys():
    fw = (REPO / "src" / "framework.zig").read_text()
    m = re.search(r'const allowed = \.\{([^}]*)\}', fw)
    assert m, "allowed tuple not found in src/framework.zig — did App()'s cfg-key guard move?"
    return set(re.findall(r'"(\w+)"', m.group(1))) - CONFIG_KEY_ALLOWLIST

def _table_keys(md_path):
    text = md_path.read_text()
    start = text.index("accepts exactly these optional keys")
    keys = set()
    for line in text[start:].splitlines():
        m = re.match(r'\|\s*`(\w+)`\s*\|', line)
        if m:
            keys.add(m.group(1))
        elif keys and line.startswith("##"):
            break  # end of the section
    return keys

def test_config_key_table_matches_allowed_tuple():
    allowed = _allowed_keys()
    for doc in (REPO / "docs" / "framework.md", REPO / "site" / "src" / "content" / "docs" / "framework.md"):
        table = _table_keys(doc)
        assert table == allowed, (
            f"{doc}: config-key table drift. missing={sorted(allowed - table)} stale={sorted(table - allowed)}"
        )
