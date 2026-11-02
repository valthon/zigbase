#!/usr/bin/env python3
"""Compile canonical Zig examples and exercise their authorization/auth boundaries."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


REPO = Path(__file__).resolve().parents[1]


def snippet(path: str, marker: str) -> str:
    blocks = re.findall(r"```zig\n(.*?)\n```", (REPO / path).read_text(), re.S)
    matches = [block for block in blocks if marker in block]
    if len(matches) != 1:
        raise ValueError(f"{path}: expected one Zig block containing {marker!r}")
    return matches[0] + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default=shutil.which("zig"))
    args = parser.parse_args()
    if not args.zig:
        parser.error("put pinned Zig 0.16.0 on PATH or pass --zig")
    zig = str(Path(args.zig).absolute())
    version = subprocess.check_output([zig, "version"], text=True, timeout=30).strip()
    if version != "0.16.0":
        parser.error("documentation examples require pinned Zig 0.16.0")

    booking = snippet("docs/tutorial.md", "fn confirmBooking(ctx:")
    for path in ("site/sources/docs/tutorial.md", "docs/recipes.md"):
        if snippet(path, "fn confirmBooking(ctx:") != booking:
            raise ValueError(f"{path}: booking example differs from docs/tutorial.md")
    cases = {
        "booking": booking,
        "auth": snippet("docs/recipes.md", "const SignedLinkMethod = struct"),
        "magic": snippet("docs/recipes.md", "fn magicRequest(ctx:"),
        "abilities": 'const std = @import("std");\nconst zigbase = @import("zigbase");\n'
        + snippet("docs/abilities.md", "const App = zigbase.App("),
    }
    with tempfile.TemporaryDirectory(prefix="zigbase-doc-examples-") as directory:
        scratch = Path(directory)
        for name, source in cases.items():
            support = (REPO / "tests" / "doc_examples" / f"{name}.zig").read_text()
            (scratch / f"{name}.zig").write_text(source + "\n" + support)
        # Fixed package identity; only the local dependency path varies by checkout.
        (scratch / "build.zig.zon").write_text(
            '.{ .name = .doc_proof, .version = "0.0.0", '
            '.fingerprint = 0x94102d8b4f0a182d, .minimum_zig_version = "0.16.0", '
            ".dependencies = .{ .zigbase = .{ .path = "
            + json.dumps(os.path.relpath(REPO, scratch))
            + ' } }, .paths = .{ "" } }\n'
        )
        (scratch / "build.zig").write_text(
            """const std = @import("std");
const zigbase = @import("zigbase");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zigbase", .{ .target = target, .optimize = optimize });
    const step = b.step("test", "Exercise extracted documentation examples");
    inline for (.{ "booking", "auth", "magic", "abilities" }) |name| {
        const module = b.createModule(.{
            .root_source_file = b.path(name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        zigbase.addTo(dep, module);
        const tests = zigbase.addTest(b, dep, .{ .root_module = module });
        step.dependOn(&b.addRunArtifact(tests).step);
    }
}
"""
        )
        env = dict(os.environ)
        env.pop("ZIG_LOCAL_CACHE_DIR", None)
        subprocess.run(
            [zig, "build", "test", "--summary", "all", "-j2"],
            cwd=scratch,
            env=env,
            check=True,
            timeout=300,
        )


if __name__ == "__main__":
    main()
