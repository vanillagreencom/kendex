# Each mutation changes a disposable skill copy and names its assertion.
# The default bound moves.
control_expect 'issues list: 75 rows by default in one request, and the notice'
control_replace scripts/lib/pages.sh 1 \
    'LINEAR_LIST_DEFAULT=75' \
    'LINEAR_LIST_DEFAULT=50'
# Rows that select a connection are asked for in Linear's largest page.
control_expect 'teams list --max: rows with a connection, pages of 50'
control_replace scripts/lib/pages.sh 1 \
    "        printf '50'" \
    "        printf '250'"
# Flat rows are asked for in the small page.
control_expect 'labels list --max: flat rows, pages of 250'
control_replace scripts/lib/pages.sh 1 \
    "        printf '250'" \
    "        printf '50'"
# --first reads as a bound of one row, so its answer prints the notice.
control_expect 'projects list --first: one row, no notice'
control_replace scripts/lib/pages.sh 1 \
    '    first) first=1 limit=1 ;;' \
    '    first) first=1 limit=1 LINEAR_LIST_BOUND=1 ;;'
# --limit 0 is taken, and reads as no bound at all.
control_expect 'issues list --limit 0: refused before any request'
control_replace scripts/lib/pages.sh 1 \
    '        linear_require_pattern --limit "${2:-}" '\''^[1-9][0-9]{0,8}$'\'' "a positive whole number" || return 1' \
    '        linear_require_pattern --limit "${2:-}" '\''^[0-9]+$'\'' "a whole number" || return 1'
# --max keeps the default bound.
control_expect 'issues list --max: every row in pages of 75, no notice'
control_replace scripts/lib/pages.sh 1 \
    '    --max) LINEAR_LIST_BOUND=all ;;' \
    '    --max) ;;'
# The notice prints on every bounded read.
control_expect 'issues list --limit 10 over 10 rows: no notice'
control_replace scripts/lib/pages.sh 1 \
    '        if [[ "$open" == true ]]; then' \
    '        if true; then'
# The notice never prints.
control_expect 'projects list: 75 rows by default in pages of 50'
control_replace scripts/lib/pages.sh 1 \
    '        if [[ "$open" == true ]]; then' \
    '        if false; then'
# A last page trimmed to the bound reads as the end of the collection.
control_expect 'labels list --limit 300: a trimmed last page still notices'
control_replace scripts/lib/pages.sh 1 \
    '            setpath($key + ["pageInfo", "hasNextPage"]; true) |' \
    '            . |'
# An unknown --type reads every cycle.
control_expect 'cycles list --type past: refused before any request'
control_replace scripts/commands/cycles.sh 1 \
    '        all | "")' \
    '        all | "" | *)'
# A verb's measured page is ignored for the page its query derives.
control_expect 'issues list --limit 300: pages of 75'
control_replace scripts/lib/pages.sh 1 \
    '    if [[ -z "$page" ]]; then' \
    '    if true; then'
