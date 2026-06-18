#!/usr/bin/env node
"use strict";
const { execFileSync } = require("node:child_process");
const { binaryPath } = require("@zigbase/server");

try {
  execFileSync(binaryPath(), ["typegen", ...process.argv.slice(2)], { stdio: "inherit" });
} catch (err) {
  if (typeof err.status === "number") process.exit(err.status);
  console.error(err.message || String(err));
  process.exit(1);
}
