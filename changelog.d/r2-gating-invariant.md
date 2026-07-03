### Internal

- CI now enforces the gating invariant: a minimal consumer build (`fixtures/minimal/`) is nm-scanned to prove deselected subsystems (WebAuthn, magic-link, OAuth2, analytics API, senders, mail webhook, webhook/mail job kinds, admin SPA) leave zero symbols (`scripts/check-gating.sh`), self-checked against a positive-control build (`fixtures/full/`) so a renamed/vacuous pattern also fails the check.
