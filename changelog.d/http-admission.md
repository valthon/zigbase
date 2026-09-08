### Features

- Add opt-in comptime HTTP admission limits: immediate 503 overload responses,
  Retry-After, and superuser-only process-local saturation diagnostics. Disabled
  builds retain no admission counters or request checks.
  The built-in GET liveness probe remains available during intentional shedding;
  contending counter updates park instead of busy-spinning.
