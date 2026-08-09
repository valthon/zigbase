import json, os, pathlib, subprocess

import pytest

from conftest import run

# A migrate-only data dir is NOT a clean --production report: `migrate` never
# persists a JWT secret (only `serve` does) and no mailer is configured, and
# both escalate warn -> error under --production (see src/doctor.zig
# checkJwtSecret / checkMailerConfigured). Tests that need a warnings-only
# --production state pin both away with env so the loopback-bind warning
# (host-binding) is the ONLY remaining finding, deterministically producing
# exit 2 instead of exit 1.
_PROD_CLEAN_ENV = {
    "ZIGBASE_JWT_SECRET": "x" * 64,        # >= min_jwt_secret_len (32) -> ok
    "ZIGBASE_SMTP_HOST": "smtp.example.com",  # non-empty -> mailer-configured ok
}


def _findings(binary, *args, env=None, timeout=60):
    p = run(binary, "doctor", "--json", *args, env=env, timeout=timeout)
    objs = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
    assert objs, p.stdout + p.stderr
    summary = objs[-1]
    assert summary.get("summary") is True, "the last NDJSON line must be the summary object"
    return objs[:-1], summary, p.returncode


def test_json_is_ndjson_findings_then_one_summary(binary, data_dir):
    assert run(binary, "migrate", "--data-dir", data_dir).returncode == 0
    findings, summary, code = _findings(binary, "--data-dir", data_dir)
    ids = [f["check"] for f in findings]
    # Every frozen id appears, in ledger order.
    ledger_path = pathlib.Path(__file__).resolve().parents[2] / "src" / "doctor_ids.txt"
    ledger = [l for l in ledger_path.read_text().splitlines() if l.strip()]
    assert [i for i in ids if i in ledger] == [i for i in ids]
    for check_id in ledger:
        assert check_id in ids, f"{check_id} is in the ledger but doctor never emitted it"
    for f in findings:
        assert set(f) == {"check", "severity", "subject", "message"}
        assert f["severity"] in {"ok", "info", "warn", "error", "skipped"}
    assert set(summary) == {"summary", "production", "checks", "errors", "warnings", "skipped"}
    assert summary["checks"] == len(findings)
    # 0 fully clean / 1 any error / 2 warnings only. Skipped never scores.
    expected_code = 1 if summary["errors"] else (2 if summary["warnings"] else 0)
    assert code == expected_code


def test_warnings_only_exits_2_not_0(binary, data_dir):
    """The exit-2 state is the whole reason a tolerant deploy gate can exist:
    'ran fine, but look at this' must be distinguishable from 'nothing to see'.
    A loopback bind under --production is a guaranteed warning with no errors,
    so it pins exit 2 without depending on the rest of the report.

    The JWT-secret and mailer findings are pinned to 'ok' via env (see
    _PROD_CLEAN_ENV) — a bare migrate-only dir legitimately ERRORS on both
    under --production, which would make this a 1-exit test instead."""
    assert run(binary, "migrate", "--data-dir", data_dir).returncode == 0
    findings, summary, code = _findings(binary, "--production", "--data-dir", data_dir, env=_PROD_CLEAN_ENV)
    assert summary["errors"] == 0, [f for f in findings if f["severity"] == "error"]
    assert summary["warnings"] >= 1
    assert code == 2

    # And the two documented shell gates behave as documented against it.
    strict = subprocess.run(f"{binary} doctor --production --data-dir {data_dir}",
                            shell=True, capture_output=True,
                            env={**subprocess.os.environ, **_PROD_CLEAN_ENV})
    assert strict.returncode == 2  # `&& deploy` would NOT run
    tolerant = subprocess.run(
        f"{binary} doctor --production --data-dir {data_dir}; case $? in 0|2) exit 0 ;; *) exit 1 ;; esac",
        shell=True, capture_output=True, env={**subprocess.os.environ, **_PROD_CLEAN_ENV})
    assert tolerant.returncode == 0  # the tolerant gate proceeds


def test_pending_migrations_are_an_error(binary, data_dir):
    """`migrations-applied` is a DB-backed check (doctor_run.gatherDb queries
    the schema), so it needs the schema provisioned first — a truly untouched
    data dir (no `migrate`, no `serve` ever run against it) has no tables to
    query at all and the check reports 'skipped' with a PrepareFailed db_error,
    exactly like test_unwritable_data_dir_errors_and_skips_the_db_checks below
    (this is doctor's own 'never claim ok when we could not look' contract,
    not a special case). So: migrate first, THEN assert on a real report."""
    assert run(binary, "migrate", "--data-dir", data_dir).returncode == 0
    findings, summary, code = _findings(binary, "--data-dir", data_dir)
    mig = next(f for f in findings if f["check"] == "migrations-applied")
    # Either it is clean (this binary declares no consumer migrations) or it is
    # an error — never a silent ok while work is outstanding.
    assert mig["severity"] in {"ok", "error"}
    if mig["severity"] == "error":
        assert code == 1


def test_unwritable_data_dir_errors_and_skips_the_db_checks(binary):
    """/proc/zigbase-nope used to make `doctor` spin forever at ~100% CPU: a
    read-only diagnostic has no business creating anything under a data dir it
    already found unusable, and unconditionally trying to anyway walked into a
    Zig 0.16 std lib infinite loop specific to procfs-like paths (mkdir on an
    unregistered leaf returns ENOENT, which createDirPath's climb-to-parent
    logic misreads as 'parent missing' forever). Fixed by short-circuiting
    doctor_run.gatherDb on `!data_dir_writable` (src/doctor_run.zig) — it now
    never calls openPool/ensureDataDir at all when the writability probe
    already failed. Kept the bounded timeout as a regression guard: if this
    ever starts hanging again, the test fails fast with a clear timeout
    instead of stalling CI."""
    findings, summary, code = _findings(binary, "--data-dir", "/proc/zigbase-nope", timeout=10)
    assert code == 1
    dd = next(f for f in findings if f["check"] == "data-dir-writable")
    assert dd["severity"] == "error"
    for dependent in ("public-rules-enumerated", "migrations-applied"):
        f = next(x for x in findings if x["check"] == dependent)
        # Skipped, NOT ok: claiming "no public rules" when we could not look is
        # the worst possible answer for a ship gate.
        assert f["severity"] == "skipped"
    assert summary["skipped"] >= 2


@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0,
                     reason="root ignores directory mode bits; EACCES never fires")
def test_chmod_unwritable_data_dir_errors_and_skips_the_db_checks(binary, data_dir):
    """The procfs test above proves the fix against the specific quirk that
    exposed the createDirPath hang, but procfs's ENOENT-for-unregistered-leaf
    behavior is unusual. This is the ordinary case doctor must also get right:
    a real directory that exists but is not writable (EACCES), independent of
    any procfs-specific behavior."""
    os.chmod(data_dir, 0o500)  # r-x------: readable/listable, not writable
    try:
        findings, summary, code = _findings(binary, "--data-dir", data_dir, timeout=10)
    finally:
        # Restore before the data_dir fixture's rmtree, or cleanup itself fails.
        os.chmod(data_dir, 0o700)
    assert code == 1
    dd = next(f for f in findings if f["check"] == "data-dir-writable")
    assert dd["severity"] == "error"
    for dependent in ("public-rules-enumerated", "migrations-applied"):
        f = next(x for x in findings if x["check"] == dependent)
        assert f["severity"] == "skipped"
    assert summary["skipped"] >= 2


def test_production_escalates_insecure_cookies(binary, data_dir):
    assert run(binary, "migrate", "--data-dir", data_dir).returncode == 0
    dev, _, dev_code = _findings(binary, "--data-dir", data_dir)
    prod, _, prod_code = _findings(binary, "--production", "--data-dir", data_dir)

    def sev(fs, cid):
        return next(f["severity"] for f in fs if f["check"] == cid)

    # The default loopback bind is right for dev and questionable for prod —
    # the clearest asymmetry to pin, and it needs no env fiddling.
    assert sev(dev, "host-binding") == "ok"
    assert sev(prod, "host-binding") == "warn"


def test_prose_mode_is_human_readable_and_agrees_with_json(binary, data_dir):
    assert run(binary, "migrate", "--data-dir", data_dir).returncode == 0
    prose = run(binary, "doctor", "--data-dir", data_dir)
    _, summary, json_code = _findings(binary, "--data-dir", data_dir)
    assert prose.returncode == json_code
    assert "checks" in prose.stdout
    assert not prose.stdout.lstrip().startswith("{"), "prose mode must not emit JSON"
