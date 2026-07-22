### Security

- Record validation now rejects an over-`maxSelect` `relation` or `select` value on the
  element **count**, before running the per-element existence checks. Previously an
  over-limit `relation` array still ran one existence `SELECT` per submitted id under the
  writer lock, so an attacker-sized array (bounded only by the request body limit) could
  drive a large number of queries from input already known to be invalid.
