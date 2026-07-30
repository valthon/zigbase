import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { genServerPackages } from "./gen-server-packages.mjs";

const TARGETS = [
  { key: "linux-x64", zig: "x86_64-linux-musl", os: "linux", cpu: "x64" },
  { key: "darwin-arm64", zig: "aarch64-macos", os: "darwin", cpu: "arm64" },
];

function generate() {
  const dir = mkdtempSync(join(tmpdir(), "genpkg-"));
  genServerPackages({ version: "9.9.9", targets: TARGETS, npmDir: dir });
  return dir;
}
const readJson = (dir, ...p) => JSON.parse(readFileSync(join(dir, ...p), "utf8"));

test("platform package.json has name, version, os, cpu, license", () => {
  const dir = generate();
  try {
    const pkg = readJson(dir, "server-linux-x64", "package.json");
    assert.equal(pkg.name, "@zigbase/server-linux-x64");
    assert.equal(pkg.version, "9.9.9");
    assert.deepEqual(pkg.os, ["linux"]);
    assert.deepEqual(pkg.cpu, ["x64"]);
    assert.equal(pkg.license, "Apache-2.0");
    assert.deepEqual(pkg.files, ["zigbase", "README.md"]);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("meta package.json: version, optionalDependencies, license, files include targets.json", () => {
  const dir = generate();
  try {
    const meta = readJson(dir, "server", "package.json");
    assert.equal(meta.name, "@zigbase/server");
    assert.equal(meta.version, "9.9.9");
    assert.equal(meta.license, "Apache-2.0");
    assert.deepEqual(meta.optionalDependencies, {
      "@zigbase/server-linux-x64": "9.9.9",
      "@zigbase/server-darwin-arm64": "9.9.9",
    });
    assert.ok(meta.files.includes("targets.json"));
    assert.ok(meta.files.includes("index.js"));
    assert.ok(meta.files.includes("bin"));
    assert.equal(meta.bin.zigbase, "bin/zigbase.js");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("meta README has a row per target", () => {
  const dir = generate();
  try {
    const readme = readFileSync(join(dir, "server", "README.md"), "utf8");
    assert.match(readme, /Linux x64.*@zigbase\/server-linux-x64/);
    assert.match(readme, /macOS arm64.*@zigbase\/server-darwin-arm64/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("alias package.json: bare name, own bin, thin file list, no platform gate", () => {
  const dir = generate();
  try {
    const pkg = readJson(dir, "alias", "package.json");
    assert.equal(pkg.name, "zigbase");
    assert.equal(pkg.version, "9.9.9");
    assert.equal(pkg.license, "Apache-2.0");
    // Its own bin, or `npx zigbase` and `npm i -g zigbase` have no command to run.
    assert.equal(pkg.bin.zigbase, "bin/zigbase.js");
    assert.equal(pkg.main, "index.js");
    assert.deepEqual(pkg.files, ["bin", "index.js", "README.md"]);
    assert.deepEqual(pkg.publishConfig, { access: "public" });
    // No os/cpu: the alias installs everywhere and lets @zigbase/server's
    // optionalDependencies pick the platform.
    assert.equal(pkg.os, undefined);
    assert.equal(pkg.cpu, undefined);
    // No optionalDependencies either — it owns no binary.
    assert.equal(pkg.optionalDependencies, undefined);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("alias pins @zigbase/server to its own exact version", () => {
  const dir = generate();
  try {
    const pkg = readJson(dir, "alias", "package.json");
    const meta = readJson(dir, "server", "package.json");
    // A skew here ships an alias whose only dependency does not exist.
    assert.deepEqual(pkg.dependencies, { "@zigbase/server": "9.9.9" });
    assert.equal(pkg.dependencies["@zigbase/server"], meta.version);
    assert.equal(pkg.version, meta.version);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test("one entry per target -> one platform dir each, no more", () => {
  const dir = generate();
  try {
    readJson(dir, "server-linux-x64", "package.json");
    readJson(dir, "server-darwin-arm64", "package.json");
    assert.throws(() => readJson(dir, "server-darwin-x64", "package.json"));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
