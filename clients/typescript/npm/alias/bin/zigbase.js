#!/usr/bin/env node
"use strict";
// Delegate to `@zigbase/server`'s own launcher: requiring it *runs* it (it reads
// `process.argv` itself, and `argv.slice(2)` is the same whichever shim is the
// entry point), so argv forwarding and exit-code propagation keep exactly one
// implementation, in the canonical package.
//
// This package declares its own `bin.zigbase` even though `@zigbase/server`
// already declares one, because two entry points need it and neither can see a
// dependency's bin:
//   - `npx zigbase` derives the command from the *requested* package's manifest
//     (npm's getBinFromManifest); a bin-less manifest is "could not determine
//     executable to run".
//   - `npm i -g zigbase` links only the installed package's own bins into the
//     global bin dir, never a dependency's.
// In a plain local install the command would appear anyway — npm hoists
// @zigbase/server to the same node_modules and links its bin — and when both
// packages claim `zigbase` npm picks @zigbase/server's copy, so this shim is the
// one that runs in the global/npx/nested cases. See README.md.
require("@zigbase/server/bin/zigbase.js");
