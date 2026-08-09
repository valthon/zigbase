### Fixes

- The full-text provisioner no longer skips a collection in silence. A collection whose name is not a valid identifier is still not indexed — the read path deliberately answers `?search=` on it with `NotSearchable` rather than returning unfiltered rows — but when such a collection actually declares `.searchable` fields, startup now logs what was skipped, why, and how to fix it, instead of leaving `?search=` failing with nothing in the logs.
