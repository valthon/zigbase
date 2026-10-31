### Security

- Reject client relation filters and sorts through targets with restricted view policies or TTL, including realtime subscription filters. Trusted access-rule and server-authored Ctx queries retain private traversal; server code forwarding untrusted filters can opt into client-query validation.
- Reject hidden-field predicates in realtime subscription filters, closing a boolean oracle over fields omitted from client records. Invalid subscription filters receive immediate errors without replacing valid subscriptions; delivery checks remain in place.

### Fixes

- Preserve shared descendants in relation expansion and correctly release expanded records with ordinary allocators, including partial allocation failures.
- Reject oversized stateless and signed cursors before returning an unusable continuation token, with an actionable client error.
- Reject empty SQLite prepared statements safely.
