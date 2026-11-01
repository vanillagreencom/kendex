# Request journal

Read when starting, stopping or reading a bounded local journal of Linear request attempts. Collection is off by default.

Set `LINEAR_JOURNAL_DIR` to an absolute new directory in every process that participates. The installed interface is:

```bash
linear.sh journal start --max-bytes BYTES --actor-id UUID
linear.sh journal stop
linear.sh journal read
```

Start accepts a positive byte limit of at most nine digits and a supplied actor UUID. It creates the directory exclusively and binds that identity to the selected credential. It sends no API request and mints no token. Read and stop need no credential lookup. A changed credential leaves actor identity unread. The supplied identity is an operator assertion, not an independent API check. A client pair keeps its binding through token renewal.

The journal is `attempts.jsonl` in that directory. It records completed HTTP attempts for GraphQL, token mint and renewal, attachment downloads and storage PUTs. Each attempt carries the raw HTTP status, safe operation name, attempt within its authorization phase, actor provenance and caller repository/script/item. `LINEAR_JOURNAL_CALLER` supplies a script identifier without arguments. `LINEAR_JOURNAL_ITEM` supplies a carrying issue identifier or `owner/repo#number`. Missing labels stay unread or use the actual Linear command script. No request or response body, variables, authorization, credential value or signed URL is retained.

Collection stops after one hour, before an append would exceed the byte limit, on explicit stop, or on a journal failure. Each new session needs a new directory. The byte limit covers the journal file; small fixed session, stop and writer-lock metadata are additional. A journal failure reports unavailable or incomplete evidence without changing the HTTP result. A lock is never reclaimed by signalling a saved process number.

Read reports the session state, per-caller attempt counts, the top five callers by attempts, separate transport counts and identity/label/complexity coverage. It sums only returned valid `X-Complexity` values. Missing values stay unread. Shared remaining-quota changes are never request costs. A rate-limit refusal does not establish which caller spent the shared quota.

Only participating installed transport processes on this host are covered. The window uses the host clock and records completed attempts. An attempt completed after expiry, or killed before its record, can be absent. A collection stopped before expiry, capped or failed is not a complete hour. Storage attempts need not consume GraphQL quota.
