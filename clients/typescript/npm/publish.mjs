#!/usr/bin/env node
// Assemble + publish the @zigbase/server* and @zigbase/typegen packages.
// Manual bootstrap (with `npm login`) for the first publish; CI reuses it with
// --skip-build --provenance. Publishes in dependency order and skips versions
// already on the registry so a partial run can resume.
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../../..");
const args = new Set(process.argv.slice(2));
const DRY = args.has("--dry-run");
const SKIP_BUILD = args.has("--skip-build");
const PROVENANCE = args.has("--provenance");
const whatIdx = process.argv.indexOf("--what");
const WHAT = whatIdx >= 0 ? process.argv[whatIdx + 1] : "all";
if (whatIdx >= 0 && !["server", "typegen", "all"].includes(WHAT)) {
  throw new Error("--what must be one of: server, typegen, all");
}

const TARGETS = [
  { key: "linux-x64", zig: "x86_64-linux-musl" },
  { key: "linux-arm64", zig: "aarch64-linux-musl" },
  { key: "darwin-x64", zig: "x86_64-macos" },
  { key: "darwin-arm64", zig: "aarch64-macos" },
];

function pkgVersion(dir) {
  return JSON.parse(readFileSync(join(HERE, dir, "package.json"), "utf8")).version;
}
function pkgName(dir) {
  return JSON.parse(readFileSync(join(HERE, dir, "package.json"), "utf8")).name;
}
function alreadyPublished(name, version) {
  const r = spawnSync("npm", ["view", `${name}@${version}`, "version"], { encoding: "utf8", timeout: 10_000 });
  return r.status === 0 && r.stdout.trim() === version;
}
function publishDir(dir) {
  const name = pkgName(dir);
  const version = pkgVersion(dir);
  if (alreadyPublished(name, version)) {
    console.log(`skip ${name}@${version} (already on registry)`);
    return;
  }
  const flags = ["publish", "--access", "public"];
  if (PROVENANCE) flags.push("--provenance");
  if (DRY) flags.push("--dry-run");
  console.log(`publish ${name}@${version} ${DRY ? "(dry-run)" : ""}`);
  execFileSync("npm", flags, { cwd: join(HERE, dir), stdio: "inherit" });
}

// 1) Build + inject platform binaries (unless --skip-build).
if (WHAT !== "typegen") {
  for (const t of TARGETS) {
    const dest = join(HERE, `server-${t.key}`, "zigbase");
    if (!SKIP_BUILD) {
      console.log(`building dist-server for ${t.zig}`);
      const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build", "dist-server",
        `-Dtarget=${t.zig}`, "-Doptimize=ReleaseFast", "-Dcpu=baseline"], { cwd: REPO_ROOT, stdio: "inherit" });
      if (b.status !== 0) throw new Error(`build failed for ${t.zig}`);
      copyFileSync(join(REPO_ROOT, "zig-out/bin/zigbase-dist"), dest);
    }
    if (!existsSync(dest)) throw new Error(`missing binary for ${t.key}: ${dest} (build it or drop it in)`);
  }
  // 2) Version consistency: all @zigbase/server* share one version.
  const v = pkgVersion("server");
  for (const t of TARGETS) {
    if (pkgVersion(`server-${t.key}`) !== v) throw new Error(`version mismatch: server-${t.key} != ${v}`);
  }
  // 3) Publish platform packages, then the meta.
  for (const t of TARGETS) publishDir(`server-${t.key}`);
  publishDir("server");
}

// 4) Publish typegen wrapper.
if (WHAT !== "server") {
  publishDir("typegen");
}
console.log("done");
