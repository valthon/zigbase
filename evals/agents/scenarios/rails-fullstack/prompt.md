# Finish the frozen Rails full-stack migration

Use the installed `zigbase-migrate-rails-fullstack` skill. The two source-specific migrations have
already run against one frozen representative Rails application. Their immutable artifacts are
under `source/`:

- observed Rails backend routes;
- ZigBase OpenAPI plus all-passing backend replay findings and the immutable request capture;
- Zigapagos v0.5.0 presentation manifest and complete handoff, including signup, sign-in, allowed
  and denied submission, validation-error, navigation, and asset parity.

Leave `source/` byte-for-byte unchanged. Do not use the network and do not invent a replacement
endpoint or parity result.

Finish the coordinating work under `migration/`:

1. Write `fullstack-decisions.json` with `zigbaseRailsFullstackDecisions: 1` and exactly one decision
   for every route in the union of the two inventories. Use exact method/path/controller/action and
   one-based occurrence. Every route needs a `surface`, `disposition`, `parity`, and non-empty
   `rationale`. The coordinator derives operations and authorization from handoff/OpenAPI artifacts.
   Keep `GET /live` explicitly blocked by
   `RAILS_COMPONENT_VUE_UNSUPPORTED`; never call it converted. Protected POST/PATCH behavior needs
   both allowed and denied evidence. Parity references contain only `kind` and `id`; the coordinator
   derives producer-owned controls. Blocked routes must name the exact handoff finding id; do not
   invent or shorten blocker ids.
2. Run the supplied `tools/rails/fullstack.py` coordinator with its seven source input artifacts and write
   `migration/fullstack-manifest.json`. Run it twice and require byte-identical output. Do not edit
   the generated manifest.
3. Write `security/public-rules.json` using the exact public-rule inventory envelope: top-level
   `"zigbasePublicRules": 1` and a `"rules"` array. Record exactly `posts.list`, `posts.view`, and
   `users.create`; every entry must contain only `collection`, `operation`, `rule: "@public"`, and a
   non-empty review rationale grounded in the supplied contract.
The grader independently applies the supplied schema, runs production doctor, serves the generated
site from the pinned ZigBase binary, executes HTTP parity and the generated Playwright journey,
restarts the same target, restores its stopped data directory into a second target and switches to
it, then stops that copy and performs rollback by switching back to the original target with
credential verification.
The route map is reconciled when every route is migrated, retained, retired, or explicitly blocked
and both tool contracts agree. It is not application-complete or cutover-ready: the blocked Vue
root keeps `needs_review` true. Do not claim that root was migrated. Do not deploy or publish anything.
