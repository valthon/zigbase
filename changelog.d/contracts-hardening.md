### Internal

- The log formatter returns only the bytes it actually wrote when a record overflows its buffer, instead of the whole buffer. Nothing leaked in practice (Zig's fixed writer fills the buffer before reporting `NoSpaceLeft`), but the old spelling depended on that coincidence to avoid emitting uninitialized stack bytes as log text; the same fix is applied to the error-report backstop line, which had the identical shape.
- The four client SDKs' error-parsing fixtures now carry the current `{status, code, message, data}` envelope. They passed either way — none of the SDKs reads the top-level `code` — so they were quietly teaching the pre-unification shape to anyone reading them.
