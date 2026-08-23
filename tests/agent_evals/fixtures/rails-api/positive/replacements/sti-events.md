# Event single-table inheritance

`events` migrates as one collection carrying its `type` column. Subclass
behavior lives in the route layer; the target has no class hierarchy to map on.
