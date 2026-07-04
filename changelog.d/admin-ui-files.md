### Features
- Admin UI: a **Files** view — browse per-collection file fields with image previews, upload/replace files, and remove them, plus a read-only storage-backend strip (local disk vs S3). Backed by the existing records + file-serve APIs plus a new superuser `GET /api/files/config` (non-secret backend info only — never the S3 credentials).
