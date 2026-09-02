control_replace \
  "scripts/commands/sync.sh" \
  1 \
  '            echo "Sync warning: issues stopped at the $max_pages-page safety cap after caching $issue_count issues; more pages remain, so the cache is truncated." >&2' \
  '            :'
control_expect "a capped pull warns with the page cap"
control_expect "a capped pull warning names the number of issues cached"
control_expect "a capped pull warning says the cache is truncated"
