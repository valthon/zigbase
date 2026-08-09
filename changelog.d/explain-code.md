### Features

- `zigbase explain-code [CODE] [--json]` — print the summary and long-form explanation for any frozen API error code, or list every code with `explain-code` alone. `--json` emits exactly one JSON object on stdout (prose goes to stderr); the exit code is 0 for a registered code and 1 for an unknown one.
