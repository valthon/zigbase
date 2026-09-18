### Features

- Add bounded method/route-template timing aggregates to the opt-in query workbench,
  including SQL-free handlers, errors, and authorization denials. Reports expose
  completed scope counts, total/max elapsed time, slow scopes, and dropped scope
  counts independently of query-shape capacity. Timing covers synchronous matched
  dispatch, not transport or detached background work.
