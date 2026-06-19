#!/usr/bin/env node
// Generate the @zigbase/server* npm package.json + README files from the single
// source of truth (server/targets.json) and the version in build.zig.zon. The
// generated files are gitignored; only this script + targets.json are committed.
// Adding a platform = one entry in server/targets.json.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

const REPO = {
  type: "git",
  url: "git+https://github.com/valthon/zigbase.git",
};
const LICENSE = "Apache-2.0";

const OS_LABEL = { linux: "Linux", darwin: "macOS" };
function platformLabel(t) {
  return `${OS_LABEL[t.os] ?? t.os} ${t.cpu}`;
}

function writeJson(path, obj) {
  writeFileSync(path, JSON.stringify(obj, null, 2) + "\n");
}

/** Read the server version from build.zig.zon (single source of truth). */
export function versionFromBuildZon(repoRoot) {
  const zon = readFileSync(join(repoRoot, "build.zig.zon"), "utf8");
  const m = zon.match(/\.version\s*=\s*"([^"]+)"/);
  if (!m) throw new Error("gen-server-packages: could not read .version from build.zig.zon");
  return m[1];
}

/**
 * Generate the platform + meta package.json/README into `npmDir`.
 * @returns {string[]} the paths written.
 */
export function genServerPackages({ version, targets, npmDir }) {
  const written = [];

  // Platform packages.
  for (const t of targets) {
    const dir = join(npmDir, `server-${t.key}`);
    mkdirSync(dir, { recursive: true });
    const pkgPath = join(dir, "package.json");
    writeJson(pkgPath, {
      name: `@zigbase/server-${t.key}`,
      version,
      description: `ZigBase server prebuilt binary for ${t.key}.`,
      os: [t.os],
      cpu: [t.cpu],
      files: ["zigbase", "README.md"],
      publishConfig: { access: "public" },
      repository: REPO,
      license: LICENSE,
    });
    const readmePath = join(dir, "README.md");
    writeFileSync(
      readmePath,
      `ZigBase server prebuilt binary for ${t.key}. Installed automatically by @zigbase/server; do not depend on this directly.\n`,
    );
    written.push(pkgPath, readmePath);
  }

  // Meta package.
  const serverDir = join(npmDir, "server");
  mkdirSync(serverDir, { recursive: true });
  const optionalDependencies = {};
  for (const t of targets) optionalDependencies[`@zigbase/server-${t.key}`] = version;
  const metaPath = join(serverDir, "package.json");
  writeJson(metaPath, {
    name: "@zigbase/server",
    version,
    description: "ZigBase server — official prebuilt binary distribution (typegen-enabled).",
    bin: { zigbase: "bin/zigbase.js" },
    main: "index.js",
    files: ["bin", "index.js", "targets.json", "README.md"],
    engines: { node: ">=18" },
    publishConfig: { access: "public" },
    optionalDependencies,
    repository: REPO,
    license: LICENSE,
  });

  const rows = targets
    .map((t) => `| ${platformLabel(t)} | \`@zigbase/server-${t.key}\` |`)
    .join("\n");
  const metaReadmePath = join(serverDir, "README.md");
  writeFileSync(
    metaReadmePath,
    `# @zigbase/server

The official prebuilt ZigBase server binary, typegen-enabled. Ships as a meta-launcher that
resolves the correct platform-specific binary from the corresponding \`@zigbase/server-<platform>\`
optional dependency — the same distribution strategy as \`esbuild\`.

## Usage

\`\`\`sh
npx @zigbase/server serve --http-port 8090 --data-dir ./zb_data
\`\`\`

The \`zigbase\` binary is also available on PATH after \`npm install\`:

\`\`\`sh
zigbase serve --http-port 8090 --data-dir ./zb_data
zigbase --help
\`\`\`

From Node.js, resolve the binary path programmatically:

\`\`\`js
const { binaryPath } = require("@zigbase/server");
const bin = binaryPath(); // absolute path to the platform binary
\`\`\`

## Supported platforms

| Platform | Package |
| --- | --- |
${rows}

Windows support is not yet available.

The per-platform packages are installed automatically as optional dependencies — you do not need
to depend on them directly. If no platform package matches the current host, \`binaryPath()\` throws
a clear error.

## Typegen

\`@zigbase/server\` ships a typegen-enabled binary. \`@zigbase/typegen\` builds on it to provide
\`npx @zigbase/typegen\` — no Zig toolchain required.

## Requirements

- Node.js >=18
- One of the supported platforms listed above
`,
  );
  written.push(metaPath, metaReadmePath);
  return written;
}

// CLI: generate into the real npm dir using the committed targets.json + build.zig.zon.
if (import.meta.url === `file://${process.argv[1]}`) {
  const npmDir = HERE;
  const repoRoot = join(HERE, "..", "..", "..");
  const targets = JSON.parse(readFileSync(join(npmDir, "server", "targets.json"), "utf8"));
  const version = versionFromBuildZon(repoRoot);
  const written = genServerPackages({ version, targets, npmDir });
  console.log(`generated ${written.length} files for @zigbase/server* at version ${version}`);
}
