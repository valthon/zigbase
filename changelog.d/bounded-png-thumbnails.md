### Features

- Add opt-in ImageMagick thumbnail profiles for built-in local storage, with PNG/JPEG/WebP output, contain/cover resizing, shared file authorization and configurable process/admission limits. Disabled builds exclude thumbnail routes and subprocess support; no image codec is vendored or linked into ZigBase.
- Expose `invalid_image` and `thumbnail_busy` error codes for rejected images and exhausted thumbnail admission.

### Changed

- Release the file-serving database reader before `beforeServe` hooks and storage work, including original downloads, so hooks can acquire a reader even with a one-reader pool.
