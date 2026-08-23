# Club.default_scope replacement

Rails hid `archived` clubs from every ordinary read. The rows migrate — hiding
them at extraction would be silent data loss — and the target reproduces the
filter in the list rule and the club index route instead, where it is visible.
