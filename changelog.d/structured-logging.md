### Features

- Structured logging. Every log line is now timestamped and leveled, and the whole stream can be switched to one JSON object per line. Embedding consumers opt in from their own binary root with `pub const std_options = zigbase.std_options;`.
