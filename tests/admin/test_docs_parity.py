"""Doc-drift guards (R2, audit api-ergonomics E2/E12/N12).

Pure text tests: no server, no browser. They parse source + docs and fail when
either drifts. If one fails, fix the DOCS (or, for a deliberately-undocumented
var, add it to the allowlist below with a comment).
"""
import json, pathlib, re, subprocess

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
    # config.isKnown() matches two templated families by shape (std.mem.startsWith),
    # not by literal name, so it holds their bare PREFIX as a string constant — that
    # prefix incidentally matches this file's ZIGBASE_[A-Z0-9_]+ regex even though it
    # is not itself an env var. The real, user-facing spellings (ZIGBASE_FIELD_KEY_V<n>,
    # ZIGBASE_OAUTH_<PROVIDER>_CLIENT_ID/_CLIENT_SECRET) are documented in README/help.
    "ZIGBASE_FIELD_KEY_V", "ZIGBASE_OAUTH_",
    # config.zig's own "isKnown accepts the templated families and rejects a typo" unit
    # test: ZIGBASE_OAUTH_GITHUB_CLIENT_SECRET exercises the shape match (same reasoning
    # as the GOOGLE pair above); ZIGBASE_HTTP_PORTS / ZIGBASE_TRUST_PROXIES /
    # ZIGBASE_OAUTH_GOOGLE_SECRET are deliberate near-miss typos the test asserts are
    # correctly REJECTED by isKnown — none of the three is a real knob.
    "ZIGBASE_OAUTH_GITHUB_CLIENT_SECRET",
    "ZIGBASE_HTTP_PORTS", "ZIGBASE_TRUST_PROXIES", "ZIGBASE_OAUTH_GOOGLE_SECRET",
    # Internal recursion guard set by `serve --background` on the re-exec'd
    # child so it runs the plain foreground path (src/serve_control.zig). The
    # USER-facing knob is ZIGBASE_SERVE_BACKGROUND, which IS in the README and
    # help tables (SP-3 landed the real behavior and docs, superseding SP-1's
    # temporary pre-registration of both names here). Note the substring trap
    # that makes this direction the only correct one: documenting only
    # "..._CHILD" would falsely satisfy the parity check for
    # "ZIGBASE_SERVE_BACKGROUND" too. Documented in docs/serve.md.
    "ZIGBASE_SERVE_BACKGROUND_CHILD",
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

def test_env_vars_are_registered_in_config_known_vars():
    """Every ZIGBASE_* knob in the code must be registered as known — either read
    directly by Config.loadDiag (config.known_vars) or consumed outside Config, e.g.
    ZIGBASE_DB_URL read by framework.openPoolSelect (config.known_external_vars) — or
    the unknown-variable warning fires on a legitimate setting."""
    src = (REPO / "src" / "config.zig").read_text()
    m = re.search(r"pub const known_vars = \[_\]\[\]const u8\{(.*?)\n\};", src, re.S)
    assert m, "known_vars not found in src/config.zig — did it move or get renamed?"
    known = set(re.findall(r'"(ZIGBASE_[A-Z0-9_]+)"', m.group(1)))
    m2 = re.search(r"pub const known_external_vars = \[_\]\[\]const u8\{(.*?)\n\};", src, re.S)
    assert m2, "known_external_vars not found in src/config.zig — did it move or get renamed?"
    known |= set(re.findall(r'"(ZIGBASE_[A-Z0-9_]+)"', m2.group(1)))
    missing = sorted(n for n in _code_env_vars() if n not in known)
    assert not missing, f"env vars missing from config.known_vars/known_external_vars: {missing}"

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
    # Only the canonical docs/framework.md is checked: the Zigapagos site mirror
    # (site/content/docs/framework.smd) is a gitignored build artifact generated
    # from this canonical by site/scripts/gen-content.ts, so it cannot drift.
    table = _table_keys(REPO / "docs" / "framework.md")
    assert table == allowed, (
        f"config-key table drift in docs/framework.md. missing={sorted(allowed - table)} stale={sorted(table - allowed)}"
    )

# --- Docs-registry drift (SP-2) -------------------------------------------------
#
# Adding a docs/*.md needs a registry entry and a navigation entry. The Zigapagos
# generator consumes every registry entry for the page, docs index, llms.txt, and
# sitemap; generated mirrors are covered by one wildcard ignore rule. These tests
# guard the remaining hand-maintained surfaces and the registry's own integrity.

# Canonical docs that are deliberately NOT published: internal assessments, the
# advisory/audit records, and the tutorial (published from a site-authored source).
DOCS_UNPUBLISHED = {
    "dx-assessment.md",
    "ideas.md",
    "security-advisories.md",
    "security-audit.md",
    "tutorial.md",
}

# Pages authored in site/sources/docs/ with no docs/ canonical.
SITE_AUTHORED_SLUGS = {"overview", "quick-start", "tutorial", "configuration"}


def _registry():
    return json.loads((REPO / "site" / "scripts" / "docs-registry.json").read_text())


def _sidebar_slugs():
    src = (REPO / "site" / "layouts" / "docs.shtml").read_text()
    return set(re.findall(r"\$site\.page\('docs/([a-z0-9-]+)'\)", src))


def test_every_docs_md_is_registered_or_deliberately_unpublished():
    on_disk = {p.name for p in (REPO / "docs").glob("*.md")}
    registered = {
        e["canonical"].split("/", 1)[1]
        for e in _registry()
        if e["canonical"].startswith("docs/")
    }
    missing = on_disk - registered - DOCS_UNPUBLISHED
    assert not missing, (
        f"docs/*.md with no entry in site/scripts/docs-registry.json: {sorted(missing)}. "
        "Add the entry plus a docs.shtml navigation link, or list it "
        "in DOCS_UNPUBLISHED with a reason."
    )
    stale = registered - on_disk
    assert not stale, f"registry entries pointing at files that do not exist: {sorted(stale)}"


def test_registry_entries_have_unique_publishable_metadata():
    entries = _registry()
    slugs = [e["mirror"].removesuffix(".md") for e in entries]
    assert len(slugs) == len(set(slugs)), "duplicate published slug in docs-registry.json"
    assert all(re.fullmatch(r"[a-z0-9-]+", slug) for slug in slugs), (
        f"invalid published slug in docs-registry.json: {slugs}"
    )
    allowed_groups = {"getting-started", "guides", "features", "reference"}
    invalid = [
        e["mirror"] for e in entries
        if set(e.get("frontmatter", {})) != {"title", "description", "order", "group"}
        or e["frontmatter"]["group"] not in allowed_groups
    ]
    assert not invalid, f"registry entries with invalid discovery metadata: {invalid}"


def test_generated_registry_mirrors_are_gitignored():
    ignored = set((REPO / "site" / ".gitignore").read_text().split())
    assert "content/docs/*.smd" in ignored, (
        "site/.gitignore must ignore every generated Zigapagos docs mirror"
    )


def test_sidebar_and_registry_agree():
    registry_slugs = {e["mirror"].removesuffix(".md") for e in _registry()}
    sidebar = _sidebar_slugs()
    missing = registry_slugs - sidebar
    assert not missing, f"published docs with no sidebar entry (unreachable by navigation): {sorted(missing)}"
    dead = sidebar - registry_slugs - SITE_AUTHORED_SLUGS
    assert not dead, f"sidebar entries with no page behind them (dead links): {sorted(dead)}"


# --- Site-authored page registration drift (5th/6th surfaces) -------------------
#
# The tests above guard the docs/*.md -> registry -> generated mirror -> sidebar
# chain. But the SITE-AUTHORED pages (no docs/ canonical; source lives directly
# under site/sources/docs/) are registered in two OTHER hand-maintained lists:
#   - AUTHORED in site/scripts/gen-content.ts: a page missing here silently
#     vanishes from the site, llms.txt, docs-index.json, and sitemap.
#   - SITE_AUTHORED_SLUGS above: whitelists sidebar entries with no registry entry
#     (test_sidebar_and_registry_agree would otherwise call them dead links).
# A page can drift out of either without any existing test noticing.

def _tracked_site_authored_slugs():
    out = subprocess.run(
        ["git", "ls-files", "site/sources/docs/"],
        cwd=REPO, capture_output=True, text=True, check=True,
    ).stdout
    slugs = set()
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        name = pathlib.PurePosixPath(line).name
        slugs.add(re.sub(r"\.(md|mdx)$", "", name))
    return slugs


def _gen_content_site_authored_slugs():
    src = (REPO / "site" / "scripts" / "gen-content.ts").read_text()
    body = src.split("const AUTHORED = [", 1)[1].split("\n] as const;", 1)[0]
    return set(re.findall(r"slug:\s*'([a-z0-9-]+)'", body))


def test_site_authored_pages_agree_across_registrations():
    tracked = _tracked_site_authored_slugs()
    generated = _gen_content_site_authored_slugs()
    test_list = SITE_AUTHORED_SLUGS

    problems = []
    for slug in sorted(tracked | generated | test_list):
        where = []
        if slug not in tracked:
            where.append("git-tracked site/sources/docs/ files")
        if slug not in generated:
            where.append("AUTHORED in site/scripts/gen-content.ts")
        if slug not in test_list:
            where.append("SITE_AUTHORED_SLUGS in tests/admin/test_docs_parity.py")
        if where:
            problems.append(f"{slug!r} missing from: {', '.join(where)}")

    assert not problems, (
        "site-authored page registration drift (a page must appear in all three: "
        "git-tracked files, gen-content.ts's AUTHORED, and this file's "
        "SITE_AUTHORED_SLUGS):\n" + "\n".join(problems)
    )
