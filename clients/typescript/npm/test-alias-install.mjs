// Install test for the bare `zigbase` alias package.
//
// The generator test (gen-server-packages.test.mjs) only checks the JSON it
// emits. That cannot catch what actually matters about this package: whether npm
// links its `zigbase` bin, whether the delegating shim resolves through
// `@zigbase/server`, and what happens when both packages are installed side by
// side (they both declare a `zigbase` bin). So this test packs real tarballs and
// `npm install`s them into scratch consumer projects.
//
// Hermetic: the platform binary is a stub script, so no zig build is needed and
// CI can run this; and npm cannot reach a registry, so a passing run proves every
// dependency resolved from the local tarballs rather than from npmjs.org.
//
// Run: `node --test clients/typescript/npm/test-alias-install.mjs`
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { genServerPackages } from "./gen-server-packages.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const VERSION = "9.9.9";
const KEY = `${process.platform}-${process.arch}`;
const TARGET = JSON.parse(readFileSync(join(HERE, "server", "targets.json"), "utf8")).find((t) => t.key === KEY);
if (!TARGET) throw new Error(`test-alias-install: no target entry for host '${KEY}'`);

// A dead registry — nothing listens on port 1 — so an install that reaches for
// npmjs.org fails instead of quietly succeeding against the real packages. Retries
// are off so that failure is immediate rather than minutes of npm backoff. (The
// npx test needs `--offline` instead; see there.)
const NPM_ENV = {
  ...process.env,
  npm_config_registry: "http://127.0.0.1:1/",
  npm_config_audit: "false",
  npm_config_fund: "false",
  npm_config_update_notifier: "false",
  npm_config_fetch_retries: "0",
  npm_config_fetch_timeout: "5000",
  npm_config_fetch_retry_mintimeout: "100",
  npm_config_fetch_retry_maxtimeout: "1000",
};

/** Stand-in for the platform binary: echoes its argv, exits with a chosen code. */
const STUB = `#!/usr/bin/env node
console.log("STUB-ARGV:" + JSON.stringify(process.argv.slice(2)));
const flag = process.argv.find((a) => a.startsWith("--exit="));
process.exit(flag ? Number(flag.slice("--exit=".length)) : 0);
`;

// stdin is closed, not piped: `npm exec` reads it, and an open pipe nothing ever
// writes to hangs the run forever instead of failing.
function run(cmd, args, cwd, extraEnv) {
  return spawnSync(cmd, args, { cwd, encoding: "utf8", env: { ...NPM_ENV, ...extraEnv }, stdio: ["ignore", "pipe", "pipe"] });
}

/**
 * Pack the three packages (host platform stub, @zigbase/server, zigbase) as they
 * would be published, and return the tarball paths.
 */
function packTarballs(root) {
  const pkgs = join(root, "pkgs");
  genServerPackages({ version: VERSION, targets: [TARGET], npmDir: pkgs });

  // Committed sources that the generator does not write.
  for (const rel of [["server", "index.js"], ["server", "targets.json"], ["server", "bin", "zigbase.js"],
    ["alias", "index.js"], ["alias", "README.md"], ["alias", "bin", "zigbase.js"]]) {
    mkdirSync(join(pkgs, ...rel.slice(0, -1)), { recursive: true });
    copyFileSync(join(HERE, ...rel), join(pkgs, ...rel));
  }
  const stub = join(pkgs, `server-${KEY}`, "zigbase");
  writeFileSync(stub, STUB);
  chmodSync(stub, 0o755);

  const out = join(root, "tarballs");
  mkdirSync(out, { recursive: true });
  const tarballs = {};
  for (const [name, dir] of [["platform", `server-${KEY}`], ["server", "server"], ["alias", "alias"]]) {
    const r = run("npm", ["pack", "--pack-destination", out], join(pkgs, dir));
    assert.equal(r.status, 0, `npm pack ${dir} failed: ${r.stderr}`);
    tarballs[name] = join(out, r.stdout.trim().split("\n").pop());
  }
  return tarballs;
}

/** `npm install` into a fresh project; returns the project dir plus npm's output. */
function installProject(root, label, { deps, overrides, npmArgs = [] }) {
  const dir = join(root, label);
  mkdirSync(dir, { recursive: true });
  writeFileSync(
    join(dir, "package.json"),
    JSON.stringify({ name: `consumer-${label}`, version: "1.0.0", private: true, dependencies: deps, ...(overrides ? { overrides } : {}) }, null, 2),
  );
  const r = run("npm", ["install", ...npmArgs], dir);
  assert.equal(r.status, 0, `npm install (${label}) failed:\n${r.stdout}\n${r.stderr}`);
  return { dir, out: (r.stdout || "") + (r.stderr || "") };
}

/** Invoke an executable in the installed tree and collect its output. */
function runBin(exe, args, dir) {
  const r = run(exe, args, dir);
  return { ...r, all: (r.stdout || "") + (r.stderr || "") };
}
const linkedBin = (dir) => join(dir, "node_modules", ".bin", "zigbase");
const aliasShim = (dir) => join(dir, "node_modules", "zigbase", "bin", "zigbase.js");
/** The argv the stub binary reported, or null if it never ran. */
function stubArgv(all) {
  const m = all.match(/STUB-ARGV:(.*)/);
  return m ? JSON.parse(m[1]) : null;
}

function withRoot(fn) {
  const root = mkdtempSync(join(tmpdir(), "alias-install-"));
  try {
    fn(root, packTarballs(root));
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
}

/** Install the alias as the only direct dependency; the rest come from tarballs. */
function aliasOnly(root, tars, label, npmArgs) {
  return installProject(root, label, {
    deps: { zigbase: `file:${tars.alias}` },
    overrides: { "@zigbase/server": `file:${tars.server}`, [`@zigbase/server-${KEY}`]: `file:${tars.platform}` },
    npmArgs,
  });
}

test("depending on `zigbase` puts a working zigbase on PATH", () => {
  withRoot((root, tars) => {
    const { dir } = aliasOnly(root, tars, "alias-only");
    const r = runBin(linkedBin(dir), ["serve", "--http-port", "8090", "--flag with space"], dir);
    assert.equal(r.status, 0, r.all);
    // Argv passthrough, including a value containing a space, arrives verbatim.
    assert.deepEqual(stubArgv(r.all), ["serve", "--http-port", "8090", "--flag with space"]);
  });
});

test("the alias's own shim forwards argv and propagates the exit code", () => {
  withRoot((root, tars) => {
    // Invoked directly, because `node_modules/.bin/zigbase` is usually a link to
    // @zigbase/server's shim (npm hoists it and prefers it for the shared bin
    // name), which would leave this file untested. It is the shim that runs for
    // `npm i -g zigbase` and under a nested install, so it needs its own coverage.
    const { dir } = aliasOnly(root, tars, "own-shim");
    const shim = aliasShim(dir);
    const r = runBin(process.execPath, [shim, "serve", "--data-dir", "./zb"], dir);
    assert.deepEqual(stubArgv(r.all), ["serve", "--data-dir", "./zb"]);
    assert.equal(r.status, 0, r.all);
    assert.equal(runBin(process.execPath, [shim, "--exit=7"], dir).status, 7);
    assert.equal(runBin(process.execPath, [shim, "--exit=0"], dir).status, 0);
  });
});

test("a nested install links the alias's shim, and it works", () => {
  withRoot((root, tars) => {
    // --install-strategy=nested is the tree shape where npm links the alias's own
    // copy rather than the hoisted @zigbase/server one, so `zigbase` on PATH goes
    // through this package's shim end to end.
    const { dir } = aliasOnly(root, tars, "nested", ["--install-strategy=nested"]);
    assert.match(readlinkSync(linkedBin(dir)), /zigbase\/bin\/zigbase\.js$/);
    const r = runBin(linkedBin(dir), ["serve", "--exit=5"], dir);
    assert.deepEqual(stubArgv(r.all), ["serve", "--exit=5"]);
    assert.equal(r.status, 5);
  });
});

test("`node_modules/.bin/zigbase` propagates the exit code", () => {
  withRoot((root, tars) => {
    const { dir } = aliasOnly(root, tars, "exit-code");
    assert.equal(runBin(linkedBin(dir), ["--exit=7"], dir).status, 7);
    assert.equal(runBin(linkedBin(dir), ["--exit=0"], dir).status, 0);
  });
});

test("require('zigbase') re-exports @zigbase/server's binaryPath", () => {
  withRoot((root, tars) => {
    const { dir } = aliasOnly(root, tars, "require");
    const r = run(process.execPath, ["-e", "process.stdout.write(require('zigbase').binaryPath())"], dir);
    assert.equal(r.status, 0, r.stderr);
    assert.match(r.stdout, new RegExp(`server-${KEY}/zigbase$`));
  });
});

test("installing `zigbase` and `@zigbase/server` together still yields a working zigbase", () => {
  withRoot((root, tars) => {
    // Both declare `bin.zigbase`, so npm has two claims on one bin name. The
    // install must not fail or warn, and the winner must behave identically —
    // both copies exec the same platform binary. npm 11 links @zigbase/server's,
    // which is asserted here so a change in that preference is noticed rather
    // than silently altering which shim every consumer runs.
    const { dir, out } = installProject(root, "both", {
      deps: { zigbase: `file:${tars.alias}`, "@zigbase/server": `file:${tars.server}` },
      overrides: { [`@zigbase/server-${KEY}`]: `file:${tars.platform}` },
    });
    assert.doesNotMatch(out, /npm (error|warn)/, `install was not clean:\n${out}`);
    assert.match(readlinkSync(linkedBin(dir)), /@zigbase\/server\/bin\/zigbase\.js$/);

    const r = runBin(linkedBin(dir), ["serve", "--exit=3"], dir);
    assert.deepEqual(stubArgv(r.all), ["serve", "--exit=3"]);
    assert.equal(r.status, 3);
  });
});

test("`npx zigbase` resolves the command from the alias's own bin, not its dependency's", () => {
  // Why this package declares `bin.zigbase` even though `@zigbase/server` already
  // does: npm derives the executable from the *requested* package's manifest, so
  // a bin-less package is not runnable via npx however many of its dependencies
  // provide the command. Both halves below run the `npx <pkg>` shape — a bare
  // relative spec, no `--package` and no `--`, which is what makes npm do the
  // manifest lookup.
  withRoot((root, tars) => {
    const cache = join(root, "cache");
    const npxExec = (spec, cwd) => {
      // `--offline` with an empty cache, rather than this file's dead registry:
      // npm exec against an unreachable host hangs instead of failing, and an
      // empty cache in only-if-cached mode fails immediately and locally.
      const r = run("npm", ["exec", "--yes", `--cache=${cache}`, spec], cwd, { npm_config_offline: "true", npm_config_registry: "https://registry.npmjs.org/" });
      return (r.stdout || "") + (r.stderr || "");
    };

    // A bin-less package: npm cannot pick a command at all.
    const nobin = join(root, "nobin");
    mkdirSync(nobin, { recursive: true });
    writeFileSync(join(nobin, "package.json"), JSON.stringify({ name: "zigbase-nobin-fixture", version: "1.0.0" }));
    const packed = run("npm", ["pack", "--pack-destination", nobin], nobin);
    assert.equal(packed.status, 0, packed.stderr);
    const nobinTar = packed.stdout.trim().split("\n").pop();
    assert.match(npxExec(`./${nobinTar}`, nobin), /could not determine executable to run/);

    // The alias: the command resolves from its own `bin`, and the run gets as far
    // as fetching @zigbase/server — the step after the manifest lookup, which the
    // empty offline cache then refuses.
    const aliasDir = dirname(tars.alias);
    const out = npxExec(`./${tars.alias.slice(aliasDir.length + 1)}`, aliasDir);
    assert.doesNotMatch(out, /could not determine executable to run/, out);
    assert.match(out, /ENOTCACHED[\s\S]*@zigbase(%2f|\/)server/i, out);
  });
});

test("packed alias tarball ships only the delegating shim (no resolver copy)", () => {
  withRoot((root, tars) => {
    const listing = run("tar", ["-tzf", tars.alias]).stdout.trim().split("\n").sort();
    assert.deepEqual(listing, ["package/README.md", "package/bin/zigbase.js", "package/index.js", "package/package.json"]);
    // No targets.json, and nothing that maps a platform to a binary: the alias
    // must not carry a second copy of the resolver.
    const src = readdirSync(join(root, "pkgs", "alias")).join(",");
    assert.doesNotMatch(src, /targets\.json/);
  });
});
