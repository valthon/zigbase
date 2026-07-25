### Fixes

- Multipart form-data parsing no longer leaks its per-request delimiter scratch: `files/multipart.parse` allocated two derived boundary-matching strings on every call and never freed them, leaking that memory for any caller that does not pass an arena allocator (the production HTTP upload path is arena-backed, so served requests were unaffected).
