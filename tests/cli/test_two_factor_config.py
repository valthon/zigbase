"""Compile-time two-factor mistakes must fail, not silently change protection."""
import pathlib
import shutil
import subprocess

import pytest

REPO = pathlib.Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(("config", "diagnostic"), [
    (".{ .factors = .{} }", "must contain at least one factor"),
    (".{ .factors = .{.totp, .totp} }", "duplicate .totp"),
    (".{ .factors = .{.sms} }", "unknown factor '.sms'"),
    (".{ .factors = .{.totp}, .recovery_codes = 1 }", "recovery_codes must be bool"),
    (".{ .factors = .{.totp}, .typo = true }", "unknown key '.typo'"),
])
def test_invalid_two_factor_config_fails_compilation(tmp_path, config, diagnostic):
    source = tmp_path / "main.zig"
    source.write_text('const cfg = @import("config");\ncomptime { _ = cfg.select(' + config + '); }\n')
    zig = shutil.which("zig")
    assert zig, "Zig 0.16 is required"
    result = subprocess.run([zig, "build-obj", "--dep", "config", f"-Mroot={source}",
                             f"-Mconfig={REPO / 'src/auth/two_factor_config.zig'}", "-fno-emit-bin"],
                            text=True, capture_output=True)
    assert result.returncode != 0
    assert diagnostic in result.stderr
