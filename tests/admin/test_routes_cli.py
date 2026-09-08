"""Offline compiled-route discovery: configuration, redaction and compile-out."""
import json
import os
from pathlib import Path
import subprocess

import pytest

REPO = Path(__file__).resolve().parents[2]


def run(binary, *args, env=None):
    return subprocess.run([str(binary), *args], env=env, capture_output=True, text=True, timeout=30)


@pytest.fixture(scope="session")
def discovery_binaries(tmp_path_factory):
    prefix = tmp_path_factory.mktemp("route-binaries")
    for options in ([], ["-Ddev-tools=false", "--prefix", str(prefix)],
                    ["-Drealtime-backfill=true", "--prefix", str(prefix / "backfill")]):
        subprocess.run(["mise", "exec", "zig@0.16.0", "--", "zig", "build", "route-discovery-fixture", *options],
                       cwd=REPO, check=True, timeout=180)
    return (REPO / "zig-out/bin/route-discovery-fixture", prefix / "bin/route-discovery-fixture",
            prefix / "backfill/bin/route-discovery-fixture")


def inventory(binary, tmp_path):
    data = tmp_path / "must-not-exist"
    env = {**os.environ, "ZIGBASE_DATA_DIR": str(data), "ZIGBASE_HTTP_PORT": "invalid",
           "ZIGBASE_DB_URL": "postgres://invalid.invalid/unreachable", "ZIGBASE_JWT_SECRET": "DO-NOT-PRINT"}
    first = run(binary, "routes", "--json", env=env)
    assert first.returncode == 0, first.stderr
    again = run(binary, "routes", env=env)
    assert again.returncode == 0 and again.stdout == first.stdout
    assert not data.exists()
    assert "DO-NOT-PRINT" not in first.stdout + first.stderr
    assert "FIXTURE-PRIVATE-CREDENTIAL" not in first.stdout + first.stderr
    result = json.loads(first.stdout)
    assert result["protocol_version"] == 1 and result["scope"] == "compiled-route-registrations"
    return result


def test_stock_routes_are_offline_with_explicit_coverage(binary, tmp_path):
    result = inventory(binary, tmp_path)
    routes = {(r["method"], r["path"]): r for r in result["items"]}
    assert len(routes) == len(result["items"])
    assert routes["GET", "/api/health"]["declared_access"] is None
    assert routes["POST", "/api/collections/:col/auth-with-password"]["declared_access"] == "public"
    assert routes["GET", "/api/realtime"]["source"] == "realtime"
    assert routes["GET", "/api/state"]["source"] == "feature_state"
    assert result["reserved_prefixes"] == [{"path": "/_", "source": "admin"}]
    assert result["coverage"] == {"static_files": False, "admin_endpoints": False, "runtime_authorization": False}
    caps = json.loads(run(binary, "capabilities").stdout)
    op = next(op for op in caps["operations"] if op["id"] == "routes")
    assert op["argv"] == ["routes", "--json"] and not op["requires_database"]


def test_custom_config_gates_auth_redaction_and_registration_order(discovery_binaries, tmp_path):
    result = inventory(discovery_binaries[0], tmp_path)
    routes = {(r["method"], r["path"]): r for r in result["items"]}
    assert len(routes) == len(result["items"])
    assert result["reserved_prefixes"] == []
    assert not any("webauthn" in r["path"] or "magic-link" in r["path"] or "oauth2" in r["path"] for r in result["items"])
    assert routes["GET", "/public/flags"]["source"] == "feature_state"
    assert routes["HEAD", "/public/flags"]["source"] == "feature_state"
    assert routes["GET", "/api/state"]["source"] == "custom"
    secret = routes["POST", "/hooks/:token"]
    assert secret["path_secret"] == {"param": "token", "in": "path", "on_mismatch": "not_found"}
    assert routes["GET", "/member"]["authed_collection"] == {"collection": "members", "allow_superuser": True}
    assert routes["GET", "/privileged"]["declared_access"] == "superuser"
    ordered = [r["name"] for r in result["items"] if r["path"].startswith("/ordered/")]
    assert ordered == ["firstMatch", "shadowedLiteral"]


def test_routes_help_flags_and_disabled_symbols(binary, discovery_binaries):
    for flag in ("--help", "-h"):
        result = run(binary, "routes", flag)
        assert result.returncode == 0 and "zigbase routes [--json]" in result.stdout
        assert "Does not load deployment configuration" in result.stdout
    assert run(binary, "routes", "--execute").returncode != 0
    for args in (("routes",), ("routes", "--help")):
        disabled = run(discovery_binaries[1], *args)
        assert disabled.returncode != 0 and "-Ddev-tools=true" in disabled.stderr
    for binary_path, expected in zip(discovery_binaries, (True, False)):
        symbols = subprocess.run(["nm", "--defined-only", str(binary_path)], capture_output=True, text=True, check=True, timeout=30)
        assert ("route_discovery." in symbols.stdout) == expected


def test_build_flag_routes_follow_the_executable(discovery_binaries, tmp_path):
    for binary_path, expected in ((discovery_binaries[0], False), (discovery_binaries[2], True)):
        result = inventory(binary_path, tmp_path)
        assert any(r["path"] == "/api/realtime/backfill" for r in result["items"]) == expected
