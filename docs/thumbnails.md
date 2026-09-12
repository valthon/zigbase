# Image thumbnails

Enable `-Dimage-thumbnails=true` and declare named profiles. Disabled builds
exclude thumbnail routes, admission state and subprocess support. ZigBase does
not vendor or link an image codec; enabled deployments supply ImageMagick.

```zig
.files = .{ .thumbnails = .{
    .imagemagick = .{
        .executable = "/usr/bin/convert",
        .command_style = .convert, // ImageMagick 6; use .magick for version 7
        .threads = 1,
        .memory_bytes = 128 << 20,
    },
    .profiles = .{
        .avatar = .{ .width = 128, .height = 128 },
        .card = .{ .width = 320, .height = 240, .format = .webp,
            .fit = .cover, .quality = 85 },
    },
    .max_concurrent = 1,
    .max_waiting = 32,
    .wait_timeout_ms = 5000,
} },
```

## Deployment

Install a trusted, patched ImageMagick 6 `convert` or ImageMagick 7 `magick`
binary with PNG, JPEG and WebP support. Specify an absolute executable path;
there is no `PATH` search and no shell command string. The optional deployment
variable `ZIGBASE_IMAGEMAGICK_EXECUTABLE` overrides the compiled path, not the
compiled command style. Choose a matching major version. Configured thumbnail
applications validate/probe the executable at HTTP startup, before listening;
offline commands do not launch ImageMagick. A version probe does not
guarantee every coder is available under the installed system policy.

The subprocess receives a restricted environment, private working/configuration
directory, bounded pipes and a policy denying delegates, filters, indirect reads
and image coders other than PNG/JPEG/WebP (the write-only INFO coder supplies
bounded metadata inspection). Installed system policies may impose further
restrictions. This is defense in depth, **not an OS sandbox**: the executable,
its libraries and system configuration remain trusted deployment dependencies.
Keep them patched and use container/cgroup/OS limits when stronger isolation is
required. The disabled feature needs no ImageMagick installation.

## Routes and authorization

`GET` or `HEAD /api/files/:col/:rec/:name/thumbnail/:profile` uses the original
file's record reference, authentication, tenant scope, view rule and
`beforeServe` hook. Bearer/cookie authentication and scoped file tokens work as
for original downloads. Denied access remains 404. Unknown profiles return 404
before database reads and hooks. For known profiles, hooks run before admission;
a busy response does not guarantee hooks had no effects.

Only the exact built-in local storage backend is supported, checked after the
hook. There is no S3/custom-backend fetch or presigned redirect. Configured-root
symlinks are allowed; descendant symlinks and nonregular files are rejected.
Source reads use a regular-file descriptor opened relative to directory handles
and reject observed truncation/growth. They are not snapshots against same-size
writes or trusted hard links. Both original and derivative serving release the
database reader before `beforeServe` and storage work.

## Formats and response semantics

Sources and output profiles support PNG, JPEG and WebP. Input is identified from
its signature, not a URL-controlled coder or filename extension. Animated and
multi-frame inputs are rejected. ImageMagick applies automatic orientation and strips
metadata. `.contain` (default) fits inside the requested box without upscaling;
`.cover` fills the box and center-crops, including upscaling when necessary.
Output defaults to `.png`; `.jpeg` flattens transparency onto white. Quality is
1–100, default 85; codec-specific quality behavior is ImageMagick's, not a
cross-format fidelity guarantee. No arbitrary operation strings are accepted.

Responses use the output format's MIME type, `Accept-Ranges: none`, an inline
thumbnail filename, nosniff, no-referrer and sandbox CSP headers. Range requests
do not select original-file bytes or produce a partial derivative. HEAD performs
the same work as GET to determine encoded length unless a conditional request
can be satisfied first.

Conditional requests use a weak derivative ETag and
`Cache-Control: private, max-age=0, must-revalidate`, varying on Authorization,
Cookie and X-Account-Id. Authorization and hooks still run before an exact
derivative ETag match can return 304, skipping admission and transformation.
`If-None-Match: *` returns 304 only after successful rendering; it does not
bypass image validation or resource limits. There is no
persistent derivative store or cross-request in-memory image cache. Validators
include source metadata, full profile/backend configuration and a boot nonce;
restart the server after changing the executable, its libraries or system policy.
They are not source-content hashes. A first
request or a nonmatching validator still transforms the source.

Malformed/unsupported images and ImageMagick decoder/policy rejections return
`422 invalid_image`. Application-detected input/output byte limits and parsed
dimension/pixel limits return `413 payload_too_large`. ImageMagick can reject
an image under its own policy before metadata reaches those checks, yielding
422 instead of 413; error text is not parsed to infer a resource failure.
A full waiting queue or expired admission
deadline returns `503 thumbnail_busy` with `Retry-After: 1`. Unsupported storage
returns `501 not_implemented`. An unavailable/timed-out subprocess or exceeded
child-diagnostic output limit returns
`503 internal`; unexpected I/O/allocation failures return 500.
A build without the feature has no thumbnail routes. The flag alone configures
no profiles.

## SDK URLs

The TypeScript, Python, Dart and Kotlin SDKs still expose a legacy `thumb`
option that only appends `?thumb=...` to an original-file URL. That option is
deprecated for ZigBase use and does not select a named profile. The public SDK
signatures remain compatible; dedicated named-profile helpers are not provided.
Use the explicit route above, encoding every path segment. For example:

```ts
const original = new URL(zb.files.getUrl(record, filename, { token }), window.location.origin);
original.pathname += `/thumbnail/${encodeURIComponent("card")}`;
const derivativeUrl = original.toString(); // token stays after the complete path
```

Do not concatenate `/thumbnail/card` after an existing query string. The profile
must be declared by the server; dimensions are not accepted as a query parameter.

## Resource tuning

Profiles and admission policy are compile-time configuration. Declare 1–32
profiles; unknown keys and invalid limits fail compilation. Profile names are
1–64 lowercase ASCII letters, digits or hyphens, starting with a letter. Width
and height must be positive and fit the configured dimension/pixel limits;
there is no inherited 512-pixel thumbnail ceiling.

| Admission setting | Default |
| --- | --- |
| `max_concurrent` | 1 transform per App instance |
| `max_waiting` | 32 waiting requests |
| `wait_timeout_ms` | 5000 ms |

Set `max_waiting = 0` for fail-fast admission. Otherwise the wait deadline must
be positive; wakeups race for a permit, without FIFO fairness. Waiting is bounded
and precedes source allocation. Waiting requests park HTTP workers: this is not
a detached or asynchronous image service. Size waiting capacity, concurrency
and deadlines together with the server's HTTP worker budget; a large gallery
queue can occupy workers needed by unrelated requests. A queue absorbs short gallery
bursts but does not make overload disappear. Clients should handle 503; Golfsim
falls back to original photos. These limits are process-local, not distributed.

| `.imagemagick` setting | Default |
| --- | --- |
| `max_input_bytes` | 32 MiB source bytes |
| `max_output_bytes` | 16 MiB encoded output |
| `max_stderr_bytes` | 16 KiB child diagnostics |
| `timeout_ms` | 10,000 ms |
| `threads` | 1 child thread requested |
| `memory_bytes` | 128 MiB ImageMagick pixel-cache memory |
| `map_bytes` | 0 (mapped pixel cache disabled) |
| `disk_bytes` | 0 (disk pixel cache disabled) |
| `max_dimension` | 16,384 per source/output dimension |
| `max_pixels` | 40,000,000 source/output pixels |

Defaults are tuning choices, not fixed ceilings applications can only lower.
Input, output and diagnostic pipes are bounded. A transform uses three bounded
subprocesses for metadata inspection, conversion and output validation. A child
deadline triggers termination and reaping; cleanup can extend elapsed time, so
this is not a hard end-to-end request deadline. ImageMagick memory/map/disk limits govern its pixel
cache, not all child allocations or total RSS. The caller also holds source and
output buffers, response copies, pipe buffers and ordinary request state. Do not
multiply `memory_bytes` by concurrency and label the result a process-memory cap.

For a lean deployment, keep the feature off if unused. When enabled, begin with
one transform/thread, a short bounded queue, and source/output limits matching
your upload policy. For a capable host, measure representative images and tune
concurrency, child threads and cache limits together; multiplying both concurrency
and thread count can oversubscribe CPUs. Allowing map/disk cache trades memory
pressure for I/O and requires an appropriately bounded temporary filesystem.
