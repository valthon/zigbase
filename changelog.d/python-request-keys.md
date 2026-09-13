### Features
- Python SDK: opt-in `request_key` cancellation for async generic requests and individual collection reads, including generated typed clients. Newer requests cancel older work and retry waits without adding dependencies or tasks to unkeyed requests.
