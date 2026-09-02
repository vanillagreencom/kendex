# 1. The warning itself: reworded, saying neither the cap nor that the pull is
#    incomplete, and emitted twice.
control_expect "a capped pull emits one warning"
control_expect "a capped pull warns with the page cap"
control_expect "a capped pull warning says the pull is incomplete"
control_replace \
  "scripts/commands/sync.sh" \
  1 \
  '            echo "Sync warning: issues stopped at the $max_pages-page safety cap after fetching $issue_count issues; more pages remain, so this pull is incomplete." >&2' \
  '            echo "Sync warning: issue pull stopped early after fetching $issue_count issues." >&2; echo "Sync warning: duplicate." >&2'

# 2. The cap predicate, inverted: every pull now stops where it should run on
#    and runs on where it should stop.
control_expect "an under-cap pull reaches its terminal page"
control_expect "an under-cap pull returns every fetched issue"
control_expect "an under-cap pull does not warn"
control_expect "a pull completed on page 200 reaches its terminal page"
control_expect "a pull completed on page 200 returns every fetched issue"
control_expect "a pull completed on page 200 does not warn"
control_expect "the page cap stops the pull at 200 requests"
control_expect "a capped pull returns every fetched issue"
control_expect "a capped pull warning names the number of issues fetched"
control_replace \
  "scripts/commands/sync.sh" \
  1 \
  '        if (( page_count >= max_pages )); then' \
  '        if (( page_count < max_pages )); then'
