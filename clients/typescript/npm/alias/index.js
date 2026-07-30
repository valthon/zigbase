"use strict";
// The bare, unscoped `zigbase` package is a thin alias of `@zigbase/server`. It
// exists so the unscoped npm name resolves to the official distribution and so
// `npx zigbase` works; `@zigbase/server` stays the canonical package.
//
// Re-export it verbatim. No platform mapping or binary resolution lives here —
// duplicating `binaryPath()` would be a second source of truth for the
// targets.json table it reads.
module.exports = require("@zigbase/server");
