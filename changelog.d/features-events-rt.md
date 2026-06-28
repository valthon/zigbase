### Features

- Feature exposure events: register `.onFeatureExposure` to receive an `ExposureEvent` (`{ kind: .flag | .experiment, name, subject, value, variant }`) each time a declared flag or experiment is resolved. The hook is notify-only and zero-cost when unregistered (the resolver never builds the event without a handler).
- Realtime feature signal: any flag/experiment override change (`ctx.setFlag`/`App.setFlag` or an admin `PUT`/`DELETE` of a `flag:<name>` / `exp:<name>:weights` setting) broadcasts a signal-only `{"type":"features.changed"}` frame on the public `__features` channel. Clients may subscribe anonymously and re-`GET /api/state` on receipt; no per-subject state or experiment assignment is ever pushed over the socket.
