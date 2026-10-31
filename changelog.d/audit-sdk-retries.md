### Fixes

- Preserve Python file-stream upload bodies across overload and authentication retries.
- Correct TypeScript and Dart live-filter control escapes and refetch field-to-field predicates that cannot be evaluated locally.
- Fall back to live-list refetch when a server filter is outside the TypeScript or Dart local parser's grammar, preserving the original query and server errors.
- Preserve SDK single-flight refresh across delayed unauthorized responses and overlapping token generations, including Python async cancellation recovery.
