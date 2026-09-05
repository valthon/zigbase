# Generalized two-factor authentication

Implementation contract for #392. See [API usage](api.md#two-factor-authentication)
and [framework configuration](framework.md#two-factor-authentication).

## Compile-time and runtime configuration

The entire subsystem is opt-in at compile time. The configuration is
`App(.{ .auth = .{ .two_factor = .{ .factors = .{ .totp, .webauthn } } } })`.
Omitting `two_factor` or selecting `.disabled` excludes it. Select only `.totp`
or only `.webauthn` to exclude the other factor's routes and implementation.
Recovery codes are included by default when enabled and can be excluded with
`.recovery_codes = false`. The application requirement hook is also selected at
compile time; `TwoFactorPolicyContext` provides current principal data and query helpers.

Runtime data consists of enrollment, collection defaults, account requirements,
and application-owned group policy. Runtime changes cannot enable an omitted
factor. Unsupported configurations must fail explicitly rather than silently
waive a two-factor requirement. Test binary exclusion as well as config parsing;
a runtime boolean alone does not satisfy compile-time configurability.

## Policy and authentication

Collection `auth.two_factor` policy has three modes: disabled (the backward
compatible default), optional (required for enrolled users), and required
(unenrolled users must enroll before receiving a session). Allowed factors are
configured independently of primary authentication methods. Initial factors are
TOTP and WebAuthn, with single-use recovery codes as a recovery mechanism.

An application policy hook can additionally require two factors for the current
principal. It receives a read-only data context so the application can evaluate
roles, administrator status, account security preferences, and group membership
against current data. ZigBase does not impose a group schema or decide who may
change a group's policy; ordinary application authorization controls that write.
Hook errors fail closed. Hook output can add a requirement but cannot waive a
collection requirement or an enrolled user's voluntary protection.

The effective requirement is the union of collection policy, application
policy, and voluntary enrollment. If any applicable group requires two factors,
membership in another group without that requirement does not cancel it. A
user's opt-out cannot override an administrator or group requirement. Conversely,
removing a group requirement does not disable a user's voluntary enrollment.
Evaluate current policy again during completion, refresh, and authenticated
access, so promoting a user to administrator or changing a group requirement
also affects existing sessions. Applications should make policy reads cheap;
silently caching an obsolete requirement would weaken enforcement.

Every primary authentication path must converge on one decision: issue a full
session, or return a pending authentication result. This includes the method
dispatcher, legacy password login, magic-link consumption, and the custom
framework authentication helper. The low-level session issuer must reject
issuance when policy requires a factor and there is no verified completion.

Pending authentication is an opaque capability, never an ordinary auth JWT or
session cookie. Store only its digest, bind it to collection, principal, primary
method, token-key generation, session epoch, purpose, and expiry. Return it only
after successful primary authentication. Do not put it in redirect URLs. Limit
verification attempts both per pending attempt and per account; issuance of a
fresh attempt must not reset the account's verification rate limit.

A successful factor verification consumes the pending attempt atomically with
session issuance. Hook veto or database failure must not produce a session or
an after-auth notification. An invalid proof spends an attempt even though no
session transaction commits. Expiry, token-key rotation, account deletion, or
revocation invalidates outstanding attempts.

Full sessions record second-factor assurance in a signed claim. Refresh retains
that assurance after authenticating the predecessor session. Enabling required
policy must reject existing sessions without that assurance; optional policy
must likewise reject them once the user has enrolled. The same check belongs in
shared auth-token verification so HTTP and realtime agree. Previously issued,
short-lived file download capabilities retain their existing expiry semantics.
Existing WebSocket and SSE connections reverify
their retained session before subscriptions and event delivery, including custom
topics. A revoked or newly insufficient session must reauthenticate; it cannot
keep receiving private events until its original expiry.

## Factors and enrollment

Factor implementations provide enrollment and assertion verification separately
from primary login methods. The framework owns principal selection, challenge
binding, expiry, failure accounting, and session issuance. A factor returns a
verified result; it cannot select another principal or mint its own session.

TOTP uses a unique random 160-bit secret, SHA-1, six decimal digits, and 30-second
steps. Accept at most one adjacent step on either side. Persist the greatest
accepted step atomically, rejecting reuse across concurrent login attempts.
Encrypt stored secrets with the framework's authenticated encryption envelope
and a dedicated key-derivation domain. Enrollment activates only after a valid
code, and that code's step is already spent.

WebAuthn assertions bind the challenge to the pending attempt, principal,
collection, and ceremony purpose. Verify credential ownership, RP ID, origin,
ceremony type, signature, flags, and signature counter. Registration and login
challenges cannot substitute for second-factor challenges. A WebAuthn primary
login cannot use the same credential as its second factor; persist the primary
credential identity or exclude WebAuthn as a second factor for that attempt.

An unenrolled user under required policy may enroll through a restricted initial
enrollment attempt. That permission disappears when any factor is activated;
concurrent enrollment attempts cannot install additional factors afterward.
Activation and management transactions lock the principal and recheck the
attempt's generation and initial-enrollment eligibility before credential writes.
PostgreSQL uses a row lock so separate server instances obey the same boundary.
Existing users must prove an enrolled factor before adding, replacing, or
removing one. An ordinary session alone does not authorize those changes.

## Recovery and management

Generate high-entropy recovery codes only after verified enrollment or a fresh
factor-management proof. Display plaintext once and store digests. Consumption
is atomic and single-use. Replacing recovery codes invalidates the old set.
Recovery does not silently remove enrolled factors or disable policy. A recovery
proof can authorize explicit replacement through a short-lived management
capability bound to that account and operation.

Changing factors revokes existing sessions and outstanding management/login
attempts. Removing the last factor is forbidden under required policy unless a
replacement is activated in the same transaction. Administrative account
recovery is an explicit trusted application operation, never an anonymous
endpoint that substitutes email or OAuth for an enrolled second factor.

## Client contract and verification

Primary auth returns a discriminated result: authenticated, factor-required, or
enrollment-required. Pending responses have no auth token or session cookies.
SDKs must not save pending capabilities in their normal auth stores. Typed APIs
cover available factors, initiation, completion, enrollment, factor management,
and recovery-code replacement. The admin UI must support the same contract
before enabling two-factor policy on superuser accounts.

Acceptance coverage includes every primary route, custom auth helpers, both
session-store modes, refresh, hook veto, direct issuer bypass, unauthenticated
route access with a pending capability, enrollment races, wrong principal and
collection, expired/replayed proofs, account revocation, counter races, recovery
code races, factor changes, disabled-policy compatibility, client auth-store
behavior, and real browser WebAuthn ceremonies using a virtual authenticator.

Protocol references: [RFC 6238](https://www.rfc-editor.org/rfc/rfc6238) and
[Web Authentication](https://www.w3.org/TR/webauthn-3/).

## Publication and example acceptance

Completion includes canonical API and framework documentation, client examples,
the README authentication summary, relevant marketing-site sources, and the
generated documentation mirrors through the site's checked-in sync scripts.

Use the golfsim example for a complete TOTP enrollment, login, and recovery
journey, keeping blog the minimal example. Demonstrate optional enrollment for
ordinary members and a server-side requirement for privileged users. Its browser
coverage must show that a primary login cannot open a protected page until the
second factor is verified. Document how a group-policy lookup uses the same
application hook without requiring a built-in group model.
