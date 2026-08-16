---
name: zigbase-migrate-pocketbase
description: Migrate PocketBase 0.39.11 applications to ZigBase through a stopped, read-only snapshot; durable inventory decisions; deterministic schema, row, auth, and local-file extraction; parity testing; doctor review; and rehearsed cutover or rollback. Use for PocketBase migration planning, execution, review, troubleshooting, or launch readiness.
---

# ZigBase PocketBase Migration

Preserve data without silently claiming behavioral parity.

## Load the authoritative references

Read `references/migrate-pocketbase.md` and `references/agents.md` before inventorying, planning,
or executing a migration. They define the supported source version, durable-decision contract,
tool sequence, and stable ZigBase behavior.

Read only the additional references needed:

- `references/migration-tools.md` for schema, import, legacy-hash, and replay details.
- `references/serve.md` before starting or diagnosing ZigBase or interpreting doctor.
- `references/deployment.md` and `references/docker.md` before rehearsal, cutover, rollback, or
  production advice.

The copied references are authoritative for this skill. If canonical repository docs differ, stop
and report drift instead of mixing versions.

## 1. Freeze the source boundary

Require PocketBase `0.39.11`. Do not imply support for another version. Work from an immutable,
recoverable snapshot after writes and PocketBase have stopped: public collection export,
`pb_data/data.db`, and local storage. Refuse WAL/SHM sidecars and never edit the source.

Inventory hooks, migrations, custom Go, views, indexes, auth methods, mail, cron, storage backend,
and client-visible endpoint behavior. S3 download, sessions, live dual-write, geo queries, and
automatic view/hook translation are outside the converter boundary.

## 2. Use the converter as the only extraction path

Run `tools/pocketbase/pb2zb.py inventory`. Treat exit `2` as judgment required, not failure. Build
a versioned `decisions.json` keyed by every exact finding id. Require a non-empty rationale and a
typed artifact for every replacement. Never replace these durable decisions with comments,
unstructured notes, or warning suppression.

An empty PocketBase rule is public. Confirm it only with the finding's `public` choice; extraction
then emits exact ZigBase `@public`. This includes intentional public auth signup. Reconcile those
rules with doctor warnings later; do not treat reviewed public access as a doctor error.

Run `extract` only after all findings reconcile. Review source/decision hashes, counts, omissions,
replacement artifacts, public rules, unreferenced objects, and credential redaction. Run it twice
and require byte-identical bundles.

## 3. Rehearse the exact cutover

Use a fresh disposable target with the server stopped:

1. syntax-lint and dry-run the schema;
2. apply schema and run full-depth rule lint;
3. import each auth file separately with `--legacy-hashes bcrypt --preserve-timestamps`;
4. dry-run then run the ordinary manifest with `--preserve-timestamps`;
5. run `install-files` only after row validation; and
6. verify counts, ids, cyclic relations, exact timestamps, and file digests directly.

Do not manually copy rows or storage around converter validation. Do not combine auth imports with
the ordinary manifest. An identical file-install retry is acceptable; a differing collision is a
hard stop.

## 4. Port behavior before declaring parity

Implement required views, hooks, Go behavior, auth methods, jobs, mail, and custom endpoints in
trusted ZigBase seams. Add at least one allow and one deny test per authorization replacement.
Capture representative PocketBase requests before shutdown and replay them against ZigBase.

Test anonymous/public reads, owner denial and allowance, expansion, public and protected files,
validation failures, and client response boundaries. Prove a wrong password does not mutate a
legacy credential, the correct old password logs in and upgrades bcrypt to argon2id, and the login
still succeeds after restart. Never claim PocketBase sessions survive.

## 5. Gate cutover and preserve rollback

Run production doctor and reconcile exact public-rule warnings with decisions. Resolve genuine
errors. Track remaining legacy hashes explicitly; a warning is acceptable only under a reviewed
rehash-on-login rollout with a proven known account.

Verify health, metadata, data, authorization, and files before and after a production-shaped
restart. Rehearse backup restoration. Keep the snapshot, decisions, bundle, target database,
storage, and JWT secret as one rollback unit.

At final cutover, stop writes, take a new stopped snapshot, regenerate from the already-reviewed
decisions, repeat every rehearsal check, and switch traffic only when the evidence matches. Do not
deploy or mutate external infrastructure without user authorization.

## Handoff

Report source and bundle hashes, decisions and replacements, counts, exact commands and exits,
rule/doctor findings, parity and allow/deny results, legacy-hash transition, restart/restore proof,
cutover boundary, and rollback trigger. Name every unsupported or unresolved behavior plainly.
