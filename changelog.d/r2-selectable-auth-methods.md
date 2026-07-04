### Features

- `.auth.methods` (the app-level auth-method registry) gains an exact-set form: `.{ .builtins = .{ .password, .otp }, .custom = .{ MyMethod } }`. Deselected built-ins (WebAuthn's CBOR/COSE stack, magic-link, OAuth2, OTP) are excluded from the binary together with their routes. Absent key / bare-tuple form keep today's all-five behavior — non-breaking.
