### Fixes

- Command mail delivery consistently returns `MailCommandFailed` when the child
  closes its input before the parent can finish writing the message, including early zero
  exits. The child is still reaped; delivery failure no longer depends on pipe
  scheduling. A successful write only confirms kernel buffering, not that the
  command consumed every byte; zero-exit commands must enforce their own delivery contract.
