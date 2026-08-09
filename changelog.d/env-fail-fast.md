### Changed

- **A malformed environment variable now aborts startup with a message naming the variable, the offending value, and the accepted form**, instead of dying with a bare parse error or silently falling back to a default.
- **Boolean environment variables accept exactly `true`, `false`, `1`, or `0`.** Any other spelling is now a startup error. Previously anything that was not `true` or `1` silently meant `false`, so `ZIGBASE_TRUST_PROXY=yes` quietly left the knob off.
- An unrecognized `ZIGBASE_*` variable now logs a startup warning naming it (never its value), so a typo'd knob is visible instead of ignored.
