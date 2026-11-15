### Fixes

- On PostgreSQL, mail suppression and bulk list sends now work. `POST /api/mail/webhooks/:provider` and `POST /api/mail/unsubscribe` no longer fail with a 500, sends with `.mail.check_suppression` enabled no longer error, and `ctx.mail().sendBulk`, `batchStatus`, `cancelBatch` and the `mail_batch_item` queue job now run. Their queries now use PostgreSQL placeholders and time functions.
- A correctly signed SES webhook whose `complaint` or `bounce` field is not a JSON object (for example `{"notificationType":"Complaint","complaint":1}`) no longer crashes the server; it is accepted and suppresses nothing.
