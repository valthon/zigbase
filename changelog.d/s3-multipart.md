### Features
- Automatically use multipart S3 uploads for large objects, with configurable threshold/part size, bounded retries, completion XML validation, and abort cleanup. Input bodies remain fully buffered; this does not provide client-resumable uploads.
