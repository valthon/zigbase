### Changed

- `doctor --production` now reports exact `@public` creation on non-system auth collections as a warning instead of an inescapable error, so ZigBase's documented open-signup flow can pass a tolerant production gate. Public writes on ordinary collections and system auth collections remain errors.
