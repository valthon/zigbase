### Security

- The OTP and magic-link **initiate** endpoints no longer leak account existence. Previously
  they sent the code/link synchronously and only for an existing (or auto-created) account, so
  the response timing — and a propagated SMTP send failure (`500` vs `204`) — revealed whether
  an email was registered. Delivery now goes through the same non-blocking token-mail queue
  that verification and password-reset already use, so initiate returns `204` with identical
  timing and status regardless of whether the email matched a record.
