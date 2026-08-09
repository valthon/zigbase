"""`zigbase init` end-to-end (audit SP-2).

The Zig unit tests cover exclusive-create semantics. These cover the part unit
tests structurally cannot: that the emitted CONTENT is valid against the real
`zigbase` binary (`schema apply` really accepts it) and a real toolchain (the
framework scaffold really compiles). A typo in schema/collections.json is
otherwise invisible until a user hits it.
"""
import json
import os
import pathlib
import re
import subprocess

REPO = pathlib.Path(__file__).resolve().parents[2]
ZIG = ["mise", "exec", "zig@0.16.0", "--", "zig"]

BOX_FILES = {
    "docker-compose.yml",
    "schema/collections.json",
    "AGENTS.md",
    "CLAUDE.md",
    ".gitignore",
    "README.md",
}
FRAMEWORK_FILES = {
    "build.zig",
    "build.zig.zon",
    "src/main.zig",
    "AGENTS.md",
    "CLAUDE.md",
    ".gitignore",
    "README.md",
}


def _init(binary, tmp_path, *args):
    out = subprocess.run([binary, "init", "--dir", str(tmp_path), *args],
                         capture_output=True, text=True, check=True)
    return out.stdout


def _present(tmp_path, names):
    return {n for n in names if (tmp_path / n).exists()}


def test_box_mode_emits_every_file(binary, tmp_path):
    out = _init(binary, tmp_path, "--box")
    assert _present(tmp_path, BOX_FILES) == BOX_FILES
    assert "created" in out


def test_framework_mode_emits_every_file_and_names_the_package(binary, tmp_path):
    _init(binary, tmp_path, "--framework", "--name", "demo_app")
    assert _present(tmp_path, FRAMEWORK_FILES) == FRAMEWORK_FILES
    zon = (tmp_path / "build.zig.zon").read_text()
    assert ".name = .demo_app," in zon
    # The dependency must come from `zig fetch --save`, never from a copy-pasted
    # relative path — that is the trap this whole mode exists to kill.
    assert ".path =" not in zon
    assert "zig fetch --save git+https://github.com/valthon/zigbase" in zon


def test_rerunning_never_overwrites(binary, tmp_path):
    _init(binary, tmp_path, "--box")
    (tmp_path / "AGENTS.md").write_text("MINE\n")
    out = _init(binary, tmp_path, "--box")
    assert (tmp_path / "AGENTS.md").read_text() == "MINE\n"
    assert "skipped" in out
    assert "created" not in out


def test_agents_md_infers_mode_from_the_directory(binary, tmp_path):
    (tmp_path / "build.zig.zon").write_text(".{}\n")
    subprocess.run([binary, "agents-md", "--dir", str(tmp_path)], check=True)
    body = (tmp_path / "AGENTS.md").read_text()
    assert "link_libc" in body           # framework-only trap
    assert (tmp_path / "CLAUDE.md").read_text() == "@AGENTS.md\n"


def test_agents_md_stdout_does_not_write(binary, tmp_path):
    out = subprocess.run([binary, "agents-md", "--box", "--stdout", "--dir", str(tmp_path)],
                         capture_output=True, text=True, check=True).stdout
    assert "# AGENTS.md" in out
    assert not (tmp_path / "AGENTS.md").exists()


def test_box_schema_apply_is_idempotent(binary, tmp_path):
    """The starting-point schema must be accepted by `zigbase schema apply` against a
    throwaway data dir -- no server needed, `schemaApplyImpl` never opens a listener --
    and re-applying the same document must be a no-op. This is also the empirical proof
    that every rule the template emits actually parses: if `apply` refused the document,
    this test would fail with its stderr, and the fix belongs in the template, not here.
    """
    _init(binary, tmp_path, "--box")
    schema_file = tmp_path / "schema/collections.json"
    data_dir = tmp_path / "zb_data"

    def apply():
        return subprocess.run(
            [binary, "schema", "apply", str(schema_file), "--data-dir", str(data_dir)],
            capture_output=True, text=True)

    first = apply()
    assert first.returncode == 0, first.stdout + first.stderr
    doc = json.loads(first.stdout)
    assert doc["zigbase_schema_apply"] == 1
    assert doc["destructive"] is False
    assert set(doc["applied"]) == {"users", "posts"}

    # Re-applying the identical document is the documented round-trip/idempotency
    # guarantee -- nothing left to do, so nothing is written the second time.
    second = apply()
    assert second.returncode == 0, second.stdout + second.stderr
    doc2 = json.loads(second.stdout)
    assert doc2["applied"] == []


# Two-word `zigbase <verb1> <verb2>` forms the AGENTS.md text is allowed to name,
# keyed by first word -> the second words that continue it into one command. A
# bare second lowercase word that is NOT in this set (e.g. an example argument
# like `explain-code not_found`) is left attached to the FIRST word only, since
# it is a value, not a subcommand.
_TWO_WORD_VERBS = {
    "serve": {"stop", "status", "logs"},
    "superuser": {"create"},
    "schema": {"dump", "apply"},
    "migrate": {"status", "rollback", "dump"},
}


# The framework-mode "Checking work" table tells an agent to run everything
# through the build system, so its rows read `zig build run -- <verb>`, not
# `zigbase <verb>`. Both are real invocations of the same commands, and both are
# exactly what an agent copy-pastes — so both must be scanned, or a typo in a
# `zig build run --` row (which is most of the framework table) ships unnoticed.
_COMMAND_PREFIXES = (r"zigbase ", r"zig build run -- ")


def _verbs_named(agents_md_text):
    """Every `zigbase <verb>` (or `zig build run -- <verb>`) this generated
    AGENTS.md text names.

    Mirrors src/scaffold/agents_md.zig's own findUnknownCommand scan (skip a
    following token that does not start with a lowercase ASCII letter — that is
    prose, a URL, or a placeholder like `<cmd>`, not a command), but this is an
    independent implementation against the REAL emitted text of a REAL binary,
    not a re-check of the same Zig logic.
    """
    verbs = set()
    pattern = re.compile(r"(?:" + "|".join(_COMMAND_PREFIXES) + r")([a-z][\w-]*)")
    for m in pattern.finditer(agents_md_text):
        first = m.group(1)
        rest = agents_md_text[m.end():]
        m2 = re.match(r" ([a-z][\w-]*)", rest)
        second = m2.group(1) if m2 else None
        if second and second in _TWO_WORD_VERBS.get(first, ()):
            verbs.add(f"{first} {second}")
        else:
            verbs.add(first)
    return verbs


def test_generated_agents_md_names_only_commands_the_binary_really_has(binary):
    """The "named implies exists" invariant, end-to-end against the real binary.

    src/scaffold/agents_md.zig's own unit tests assert the generated text names
    nothing outside its `commands_named` allowlist, but that only proves internal
    consistency between two lists in the SAME source file. This proves the
    allowlist itself is not a fiction: every verb the generated AGENTS.md names,
    for both --box and --framework, must be a command `zigbase <verb> --help`
    actually runs (exit 0) against the binary under test.
    """
    verbs = set()
    for mode in ("--box", "--framework"):
        out = subprocess.run([binary, "agents-md", mode, "--stdout"],
                             capture_output=True, text=True, check=True).stdout
        verbs |= _verbs_named(out)

    assert verbs, "the scan should find at least one `zigbase <verb>` in the generated text"
    for verb in sorted(verbs):
        r = subprocess.run([binary, *verb.split(" "), "--help"],
                           capture_output=True, text=True)
        assert r.returncode == 0, (
            f"AGENTS.md names `zigbase {verb}`, but `zigbase {verb} --help` "
            f"exited {r.returncode}:\n{r.stdout}{r.stderr}"
        )


def test_framework_scaffold_builds_and_its_tests_pass(binary, tmp_path):
    """The generated project compiles and `zig build test` is green.

    Points the manifest at this worktree instead of `zig fetch`ing GitHub, which
    would test main rather than the tree under review. Zig 0.16 rejects an
    *absolute* `.path` in build.zig.zon, so the dependency path is computed
    relative to the scaffolded project's own directory (`tmp_path`), not REPO's
    absolute location.
    """
    _init(binary, tmp_path, "--framework", "--name", "ci_check")
    zon = tmp_path / "build.zig.zon"
    rel_repo = os.path.relpath(REPO, tmp_path)
    zon.write_text(zon.read_text().replace(
        ".dependencies = .{},",
        '.dependencies = .{ .zigbase = .{ .path = "%s" } },' % rel_repo))

    r = subprocess.run([*ZIG, "build", "test", "--summary", "all"],
                       cwd=tmp_path, capture_output=True, text=True, timeout=600)
    assert r.returncode == 0, r.stdout + r.stderr
    assert "0 failed; 0 leaked." in (r.stdout + r.stderr)
    # The simple runner exists precisely so this never appears.
    assert "--listen=-" not in (r.stdout + r.stderr)
