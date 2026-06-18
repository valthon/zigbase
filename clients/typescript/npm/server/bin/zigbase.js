#!/usr/bin/env node
"use strict";
const { execFileSync } = require("node:child_process");
const { binaryPath } = require("../index.js");

try {
  execFileSync(binaryPath(), process.argv.slice(2), { stdio: "inherit" });
} catch (err) {
  // Propagate the child's exit code; surface resolver errors clearly.
  if (typeof err.status === "number") process.exit(err.status);
  console.error(err.message || String(err));
  process.exit(1);
}
