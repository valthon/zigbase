#!/usr/bin/env node
// Assemble + publish the @zigbase/server*, bare `zigbase`, and @zigbase/typegen
// packages. Manual bootstrap (with `npm login`) for the first publish; CI reuses
// it with --skip-build --provenance. Publishes in dependency order and skips
// versions already on the registry so a partial run can resume.
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { genServerPackages, versionFromBuildZon } from "./gen-server-packages.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(HERE, "../../..");
const args = new Set(process.argv.slice(2));
const DRY = args.has("--dry-run");
const SKIP_BUILD = args.has("--skip-build");
const PROVENANCE = args.has("--provenance");
const whatIdx = process.argv.indexOf("--what");
const WHAT = whatIdx >= 0 ? process.argv[whatIdx + 1] : "all";
if (whatIdx >= 0 && !["server", "alias", "typegen", "all"].includes(WHAT)) {
  throw new Error("--what must be one of: server, alias, typegen, all");
}
// `alias` is its own scope rather than part of `server`: it needs no cross-build,
// it must go out after the meta package it depends on, and its first publish is a
// manual name-claim (see RELEASING.md).
const DO_SERVER = WHAT === "server" || WHAT === "all";
const DO_ALIAS = WHAT === "alias" || WHAT === "all";
const DO_TYPEGEN = WHAT === "typegen" || WHAT === "all";

const TARGETS = JSON.parse(readFileSync(join(HERE, "server", "targets.json"), "utf8"));

const pkgCache = new Map();
function readPkg(dir) {
  if (!pkgCache.has(dir)) {
    pkgCache.set(dir, JSON.parse(readFileSync(join(HERE, dir, "package.json"), "utf8")));
  }
  return pkgCache.get(dir);
}
function pkgVersion(dir) {
  return readPkg(dir).version;
}
function pkgName(dir) {
  return readPkg(dir).name;
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

// 1) Regenerate every generated manifest (server platform + meta + alias) from
//    targets.json + build.zig.zon, so a publish can never ship a stale version.
if (DO_SERVER || DO_ALIAS) {
  genServerPackages({ version: versionFromBuildZon(REPO_ROOT), targets: TARGETS, npmDir: HERE });
}

// 2) Build + inject platform binaries (unless --skip-build), then publish
//    platform packages followed by the meta.
if (DO_SERVER) {
  for (const t of TARGETS) {
    const dest = join(HERE, `server-${t.key}`, "zigbase");
    if (!SKIP_BUILD) {
      console.log(`building zigbase for ${t.zig}`);
      const b = spawnSync("mise", ["exec", "zig@0.16.0", "--", "zig", "build",
        `-Dtarget=${t.zig}`, "-Doptimize=ReleaseSafe", "-Dcpu=baseline"], { cwd: REPO_ROOT, stdio: "inherit" });
      if (b.error) throw b.error;
      if (b.status !== 0) throw new Error(`build failed for ${t.zig}`);
      copyFileSync(join(REPO_ROOT, "zig-out/bin/zigbase"), dest);
    }
    if (!existsSync(dest)) throw new Error(`missing binary for ${t.key}: ${dest} (build it or drop it in)`);
  }
  // Version consistency: all @zigbase/server* share one version.
  const v = pkgVersion("server");
  for (const t of TARGETS) {
    if (pkgVersion(`server-${t.key}`) !== v) throw new Error(`version mismatch: server-${t.key} != ${v}`);
  }
  // Publish platform packages, then the meta.
  for (const t of TARGETS) publishDir(`server-${t.key}`);
  publishDir("server");
}

// 3) Publish the bare `zigbase` alias, after the meta it depends on. The pin is
//    re-checked here rather than trusted: publishing an alias whose exact
//    @zigbase/server version is missing yields an uninstallable package.
if (DO_ALIAS) {
  const v = pkgVersion("server");
  const alias = readPkg("alias");
  if (alias.version !== v) throw new Error(`version mismatch: zigbase@${alias.version} != @zigbase/server@${v}`);
  if (alias.dependencies?.["@zigbase/server"] !== v) {
    throw new Error(`zigbase must pin @zigbase/server@${v}, found '${alias.dependencies?.["@zigbase/server"]}'`);
  }
  publishDir("alias");
}

// 4) Publish typegen wrapper.
if (DO_TYPEGEN) {
  publishDir("typegen");
}
console.log("done");
