- The `session-drift-check` hook needs `jq` too: without it, or on a payload it
  cannot parse, the drift report is skipped with that reason instead of being
  repeated on every compact.
