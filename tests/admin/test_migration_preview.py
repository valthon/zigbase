"""Declaration-only migration preview never boots application or database state."""
import json
import os
import subprocess

import pytest

from _bin import resolve_plugins_binary
from test_routes_cli import discovery_binaries, run  # noqa: F401


def preview(binary, tmp_path):
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(tmp_path / "absent"),
           "ZIGBASE_HTTP_PORT": "invalid", "ZIGBASE_DB_URL": "postgres://invalid.invalid/unreachable",
           "ZIGBASE_JWT_SECRET": "PRIVATE-SENTINEL"}
    result = subprocess.run([str(binary), "migrate", "preview", "--json"], cwd=tmp_path,
                            env=env, capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    assert list(tmp_path.iterdir()) == []
    assert "PRIVATE-SENTINEL" not in result.stdout + result.stderr
    document = json.loads(result.stdout)
    assert document["scope"] == "compiled-consumer-migrations"
    assert document["protocol_version"] == 1
    assert document["unknown"] == ["pending_state", "sql", "effects", "runtime_reversibility"]
    assert document["includes_system_migrations"] is False
    return document


def test_empty_stock_preview_and_discovery(binary, tmp_path):
    assert preview(binary, tmp_path)["items"] == []
    caps = json.loads(run(binary, "capabilities").stdout)
    operation = next(op for op in caps["operations"] if op["id"] == "migration-preview")
    assert operation["effect"] == "read_only" and not operation["requires_database"]
    assert operation["argv"] == ["migrate", "preview", "--json"]
    assert "no deployment configuration" in operation["notes"]
    assert "CLI logging preferences still apply" in operation["notes"]


@pytest.mark.parametrize("args", [("--help",), ("preview", "--help"), ("preview", "-h")])
def test_migration_help_describes_preview_flags(binary, args):
    result = run(binary, "migrate", *args)
    assert result.returncode == 0, result.stderr
    assert "--json           (status or preview)" in result.stdout
    assert "Preview always emits JSON, including when --json is omitted." in result.stdout
    assert "--data-dir PATH  (not preview)" in result.stdout


def test_plugins_example_declarations(tmp_path):
    binary = resolve_plugins_binary()
    if binary is None:
        pytest.skip("npm required to build the plugins example")
    items = preview(binary, tmp_path)["items"]
    assert [item["id"] for item in items] == ["0001_create_audit_log", "0002_index_audit_note"]
    assert all(item["rollback_declaration"] == "missing_reverse" for item in items)


def test_callback_declarations_and_disabled_symbols(discovery_binaries, tmp_path):  # noqa: F811 - imported pytest fixture
    enabled, disabled, _ = discovery_binaries
    items = preview(enabled, tmp_path)["items"]
    assert [item["id"] for item in items] == ["z_first", "a_second", "explicit", "rejected"]
    assert [item["rollback_declaration"] for item in items] == [
        "missing_reverse", "change_requires_runtime_verification", "explicit_down",
        "nontransactional_change_rejected"]
    assert run(enabled, "migrate", "preview").stdout == run(enabled, "migrate", "preview", "--json").stdout
    for args in (("--json",), ("--help",)):
        result = run(disabled, "migrate", "preview", *args)
        assert result.returncode != 0 and "-Ddev-tools=true" in result.stderr
        assert "zigbase migrate preview:" in result.stderr
    for binary_path, expected in ((enabled, True), (disabled, False)):
        for args in (("help",), ("migrate", "--help")):
            result = run(binary_path, *args)
            assert result.returncode == 0, result.stderr
            assert ("migrate preview" in result.stdout) == expected
        if not expected:
            help_text = run(binary_path, "migrate", "--help").stdout
            assert "--json           (status only)" in help_text
            assert "preview" not in help_text.lower()
    for binary_path, expected in ((enabled, True), (disabled, False)):
        symbols = subprocess.run(["nm", "--defined-only", str(binary_path)], capture_output=True,
                                 text=True, check=True, timeout=30)
        assert ("migration_preview." in symbols.stdout) == expected


@pytest.mark.parametrize("args", [("--data-dir", "absent"), ("--out", "report.json"), ("1",)])
def test_preview_rejects_database_and_mutation_arguments(binary, tmp_path, args):
    result = subprocess.run([str(binary), "migrate", "preview", *args], cwd=tmp_path,
                            capture_output=True, text=True, timeout=30)
    assert result.returncode != 0
    assert list(tmp_path.iterdir()) == []
