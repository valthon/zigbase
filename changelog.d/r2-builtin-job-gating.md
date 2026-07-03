### Breaking

- The built-in job kinds are now config-gated (embedded consumers): `ctx.webhook` requires `.webhooks = true`; `ctx.mail().enqueue` requires `.mail` (use `.mail = .{}` for defaults) or a `.mailer` plugin. Without the key the kind is not compiled in and enqueue fails loudly with a hint. Direct mailer delivery (verification/password-reset emails) is unaffected. The kind names `mail`/`webhook` remain reserved either way.
