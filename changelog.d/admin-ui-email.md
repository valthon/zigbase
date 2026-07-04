### Features
- Admin UI: an **Email** view — manage verified sender identities (list / invite / delete), the suppression list (add / remove / filter by reason, incl. one-click-unsubscribe entries), and read-only bulk-send batch progress, with a read-only mail-policy strip. Backed by the existing mail APIs plus a new superuser `GET /api/mail/config` (booleans only, no secrets).
