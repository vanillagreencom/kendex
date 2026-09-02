control_replace \
  "scripts/commands/sync.sh" \
  1 \
  '            echo "Sync warning: issues stopped at the $max_pages-page safety cap after fetching $issue_count issues; more pages remain, so this pull is incomplete." >&2' \
  '            :'
control_replace \
  "scripts/commands/sync.sh" \
  1 \
  '        if (( page_count >= max_pages )); then' \
  '        if (( page_count >= 2 )); then'
control_expect "an under-cap pull reaches its terminal page"
control_expect "a capped pull emits one warning"
control_expect "a capped pull warns with the page cap"
