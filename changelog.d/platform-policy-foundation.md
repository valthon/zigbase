### Features

- Filter/rule grammar: new `in` set-membership operator — `field in ("a", "b")` (literal list) or `field in <list-macro>`, compiled to a parameter-bound `IN (?, …)`. An empty set matches nothing (fail-closed).
- Filter/rule grammar: new `@request.account.id`, `@request.account.role`, and the list-valued `@request.account.ids` macros — the foundation for multi-tenancy and row-level/relationship authorization. They resolve to `""`/empty until the tenancy resolver ships, so existing rules are unaffected.

### Internal

- New `policy.zig` authorization composition layer wrapping the `rules.zig` primitive. Every enforcement chokepoint (REST list/view/create/update/delete, realtime delivery, subscribe-authorization) now routes through `policy.*` so later work can compose ability/tenant predicates at one place. PR1 is a byte-identical pass-through, pinned by back-compat tests.
