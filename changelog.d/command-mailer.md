### Features

- **`CommandMailer` (local-command / sendmail mailer)** — a built-in mailer that pipes the serialized RFC822 message to a local MTA's stdin (e.g. `sendmail -t -i` or `msmtp -t`) and treats exit 0 as success. The standard "delegate delivery to a local relay, hold no SMTP credentials in the app" setup. Selected via the new `ZIGBASE_SENDMAIL_COMMAND` env var (whitespace-split into argv; `From:` from `ZIGBASE_SMTP_FROM`), which takes precedence over SMTP in `DefaultMailerPlugin`. Re-exported as `zigbase.CommandMailer`.
