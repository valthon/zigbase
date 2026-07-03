### Internal
- Generalized the AWS SigV4 signer (`src/mail/sigv4.zig` → `src/aws/sigv4.zig`): parameterized method / canonical URI (S3 `UriEncode`) / signed-header list / service, SES signatures pinned byte-identical. Groundwork for the S3 storage backend; zero behavior change.
