"use strict";
// Maps the host to its @zigbase/server-<platform> package and returns the
// absolute path to the bundled `zigbase` binary. Throws a clear error on an
// unsupported platform or a missing optionalDependency.
const SUPPORTED = {
  "linux-x64": "@zigbase/server-linux-x64",
  "linux-arm64": "@zigbase/server-linux-arm64",
  "darwin-x64": "@zigbase/server-darwin-x64",
  "darwin-arm64": "@zigbase/server-darwin-arm64",
};

function binaryPath() {
  const key = `${process.platform}-${process.arch}`;
  const pkg = SUPPORTED[key];
  if (!pkg) {
    throw new Error(
      `@zigbase/server: unsupported platform '${key}'. Supported: ${Object.keys(SUPPORTED).join(", ")}.`,
    );
  }
  try {
    return require.resolve(`${pkg}/zigbase`);
  } catch {
    throw new Error(
      `@zigbase/server: the '${pkg}' package is not installed. If you installed with ` +
        `--no-optional or --omit=optional, reinstall without it so the platform binary is fetched.`,
    );
  }
}

module.exports = { binaryPath };
