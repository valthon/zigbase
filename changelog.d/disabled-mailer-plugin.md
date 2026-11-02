### Features
- `zigbase.DisabledMailerPlugin` lets an app declare that it sends no mail: messages are dropped without logging recipients, bodies or tokens, and `doctor --production` reports the choice instead of a missing-mailer error.
