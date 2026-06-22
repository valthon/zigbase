### Changed

- **Documented the CSRF double-submit contract for cookie sessions** — the API reference now spells out that cookie-session clients must echo the readable `zb_csrf` cookie in the `X-CSRF-Token` header on unsafe methods (`POST`/`PUT`/`PATCH`/`DELETE`); `GET`/`HEAD`/`OPTIONS` are exempt. A failed CSRF check makes the request anonymous, so the response status follows the collection's access rules — `403` on a create denial, `404` on an update/delete denial against a protected record (existence-hiding) — not a flat `403`. Documentation only; no behavior change.
