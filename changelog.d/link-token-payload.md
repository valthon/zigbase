### Features

- **`mintLinkToken` opaque bound payload** — `zigbase.auth.mintLinkToken` takes a trailing `opts: MintOptions` arg whose `payload` (default `""`) binds a small opaque string into the single-use token's signed `pl` claim, returned by `verifyLinkToken` as `claims.pl`. Lets a magic-link flow carry tamper-proof bound state (e.g. a post-login redirect target) in the one token instead of an unsigned `&next=` URL param. Signed, not encrypted — readable-but-tamper-proof; keep it small. Existing call sites add `.{}`.
