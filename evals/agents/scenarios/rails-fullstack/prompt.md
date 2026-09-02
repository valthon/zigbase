# Finish the frozen Rails full-stack migration

Use the installed `zigbase-migrate-rails-fullstack` skill. The two source-specific migrations have
already run against one frozen representative Rails application. Their immutable artifacts are
under `source/`:

- observed Rails backend routes;
- ZigBase OpenAPI, all-passing backend replay summary/findings plus the immutable request capture,
  and direct data/file/job evidence;
- Zigapagos v0.5.0 presentation manifest and complete handoff, including signup, sign-in, allowed
  and denied submission, validation-error, navigation, and asset parity.

Leave `source/` byte-for-byte unchanged. Do not use the network and do not invent a replacement
endpoint or parity result.

Finish the coordinating work under `migration/`:

1. Write `fullstack-decisions.json` with `zigbaseRailsFullstackDecisions: 1` and exactly one decision
   for every route in the union of the two inventories. Use exact method/path/controller/action and
   one-based occurrence. Every route needs a `surface`, `disposition`, `backend_operation_id`,
   `auth`, `parity`, and non-empty `rationale`. Keep `GET /live` explicitly blocked by
   `RAILS_COMPONENT_VUE_UNSUPPORTED`; never call it converted. Protected POST/PATCH behavior needs
   both allowed and denied evidence. Evidence controls are producer-owned: use backend controls
   validated against captured expected status and browser controls from the handoff parity kind. Blocked
   routes must name the exact handoff finding id; do not invent or shorten blocker ids.
2. Run the supplied `tools/rails/fullstack.py` coordinator with its eight source input artifacts and write
   `migration/fullstack-manifest.json`. Run it twice and require byte-identical output. Do not edit
   the generated manifest.
3. Write `security/public-rules.json` using the exact public-rule inventory envelope: top-level
   `"zigbasePublicRules": 1` and a `"rules"` array. Record exactly `posts.list`, `posts.view`, and
   `users.create`; every entry must contain only `collection`, `operation`, `rule: "@public"`, and a
   non-empty review rationale grounded in the supplied contract.
4. Write `migration/report.json` with exactly these fields:

   - `zigbaseRailsFullstackReport`: `1`;
   - `source`: `"source"`;
   - `manifest`: `"migration/fullstack-manifest.json"`;
   - `unresolved`: an empty array;
   - `checks`: an array containing `contracts`, `route-map`, `backend-parity`, `browser-parity`,
     `authorization`, `doctor`, `restart`, `restore`, `rollback`, and `cutover`;
   - `sameOrigin`: `true`;
   - `reviewedPublicRules`: exactly `posts.list`, `posts.view`, and `users.create`, in that order;
   - `doctorErrors`: `0`;
   - `doctorWarnings`: exactly `posts.listRule`, `posts.viewRule`, and `users.createRule`, in that order;
   - `restart`, `restore`, `rollback`, and `cutover`: non-empty evidence strings grounded in
     `source/backend-evidence.json`; and
   - `unsupported`: the sorted blocker-code inventory from the presentation manifest: exactly
     `RAILS_COMPONENT_VUE_UNSUPPORTED`, `RAILS_HELPER_UNKNOWN`, `RAILS_ROUTE_DYNAMIC_SEGMENT`,
     `RAILS_ROUTE_HELPER_UNKNOWN`, `RAILS_TEMPLATE_ENGINE_UNSUPPORTED`, and
     `RAILS_TEMPLATE_PARSE_ERROR`.

The grader independently applies the supplied schema, runs production doctor, serves the generated
site from the pinned ZigBase binary, executes HTTP parity and the generated Playwright journey,
restarts the same target, restores its stopped data directory into a second target and switches to
it, then stops that copy and switches back to the original target with credential verification.
Report strings are plans and cannot substitute for these executable cutover/rollback checks.

The migration is complete only in the coordinating sense: every route is migrated, retained,
retired, or explicitly blocked, and both tool contracts agree. Do not claim that the blocked Vue
root was migrated. Do not deploy or publish anything.
