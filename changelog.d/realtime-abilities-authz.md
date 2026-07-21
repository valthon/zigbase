### Security

- Realtime (WebSocket/SSE) delivery now enforces relationship **abilities**, not just the
  access rule and tenant scope. A collection that was `@public` for its view rule but
  visibility-narrowed by a `view` ability previously delivered every record to every
  subscriber, bypassing the ability on the realtime channel (REST reads were unaffected).
  Effective realtime visibility is now `(rule) AND (ability) AND (tenant)`, matching the
  documented guarantee and the REST list/read paths.
