"""Doc-drift guards (R2, audit api-ergonomics E2/E12/N12).

Pure text tests: no server, no browser. They parse source + docs and fail when
either drifts. If one fails, fix the DOCS (or, for a deliberately-undocumented
var, add it to the allowlist below with a comment).
"""
import pathlib, re

REPO = pathlib.Path(__file__).resolve().parents[2]

# Dev/test-only or internal names that deliberately stay out of the README table.
# EXACT matches only — a prefix rule would silently swallow real vars (e.g. a
# "ZIGBASE_OAUTH_" prefix rule would hide ZIGBASE_OAUTH_STATE_SERVER, the E11 var!).
ENV_ALLOWLIST = {
    "ZIGBASE_FAKE_NOW", "ZIGBASE_FAKE_SEED",          # -Ddev-mode builds only
    "ZIGBASE_TEST_BINARY", "ZIGBASE_FEATURES_BINARY", # test harness only
    "ZIGBASE_PG_TEST_URL",                            # postgres test-suite harness only
    "ZIGBASE_PG_TLS_CA", "ZIGBASE_PG_PLAINTEXT",      # postgres live-TLS test harness only (tls_pg_test.zig)
    # S3 live-endpoint e2e test harness only (src/files/s3.zig test blocks + tests/s3/):
    # the real consumer knobs are the un-suffixed ZIGBASE_S3_* (documented in README/help).
    "ZIGBASE_S3_TEST_BUCKET", "ZIGBASE_S3_TEST_ENDPOINT",
    "ZIGBASE_S3_TEST_KEY", "ZIGBASE_S3_TEST_SECRET",
    # provision.zig's own test mocks a resolved OAuth provider env pair with the
    # literal names "GOOGLE" would produce; the code never reads these two names
    # directly — it builds ZIGBASE_OAUTH_<UPPER(NAME)>_CLIENT_ID/_SECRET at runtime
    # via std.fmt (not a string literal our regex can see). The templated,
    # user-facing spelling is documented in docs/framework.md's OAuth2 section.
    "ZIGBASE_OAUTH_GOOGLE_CLIENT_ID", "ZIGBASE_OAUTH_GOOGLE_CLIENT_SECRET",
    # field_policy.zig/rewrap.zig tests exercise concrete generations of the
    # templated ZIGBASE_FIELD_KEY_V<n> pattern (built via std.fmt at runtime, not
    # a string literal); the <n> spelling is documented in README/help below.
    "ZIGBASE_FIELD_KEY_V1", "ZIGBASE_FIELD_KEY_V2",
}

def _code_env_vars():
    names = set()
    for f in (REPO / "src").rglob("*.zig"):
        for m in re.finditer(r'"(ZIGBASE_[A-Z0-9_]+)"', f.read_text()):
            names.add(m.group(1))
    return names - ENV_ALLOWLIST

def test_env_vars_documented_in_readme():
    readme = (REPO / "README.md").read_text()
    missing = sorted(n for n in _code_env_vars() if n not in readme)
    assert not missing, f"env vars referenced in src/ but missing from the README env table: {missing}"

def test_env_vars_listed_in_top_level_help():
    fw = (REPO / "src" / "framework.zig").read_text()
    # Anchor on the help text itself (printUsage's ENVIRONMENT VARIABLES: header),
    # NOT on the first occurrence of an env name — code above the help string also
    # names env vars (e.g. ZIGBASE_DB_URL in openPoolSelect), which would make a
    # start-only slice vacuous. The END is bounded too, at the next "EXAMPLES:"
    # (printUsage's own) — an UNBOUNDED end (start -> EOF) false-PASSES: a
    # ZIGBASE_* name that only appears in a later std.log.err/info message (past
    # printUsage — e.g. the rewrap-path messages around framework.zig:1629/1823/1828)
    # would be counted as "documented in help" when it never appears in the actual
    # help text a user sees.
    anchor = "ENVIRONMENT VARIABLES:"
    assert fw.count(anchor) >= 1, "help-text anchor drifted — update this test's anchor string"
    start = fw.index(anchor)
    end_anchor = "EXAMPLES:"
    assert end_anchor in fw[start:], "help-block end anchor drifted — update this test's anchor string"
    help_block = fw[start : fw.index(end_anchor, start)]
    missing = sorted(n for n in _code_env_vars() if n not in help_block)
    assert not missing, f"env vars referenced in src/ but missing from `zigbase help`: {missing}"

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
