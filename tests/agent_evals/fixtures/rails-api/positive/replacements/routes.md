# Route disposition

Every client-visible route is either a collection API call, a typed route, or
recorded as retired. The Rails `{"data": ...}` envelope is preserved behind
typed routes; an envelope change is never parity.
