### Performance
- Skipped a redundant buffer duplication on the non-encrypted JSON field read path, reducing per-request allocations for records with JSON fields.
