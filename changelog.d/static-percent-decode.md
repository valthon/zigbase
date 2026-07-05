### Features
- Static file serving now percent-decodes the request path, so files whose names need encoding (e.g. `my%20file.pdf`) are servable. Decoding is single-pass and happens before the traversal checks, so encoded traversal (`%2e%2e`, `%2f`, `%00`, `%5c`) is decoded and then rejected fail-closed, and double-encoding is never recursively decoded; the symlink guard is unchanged.
