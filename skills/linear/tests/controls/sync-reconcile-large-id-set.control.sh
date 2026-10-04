# 1. Send every cached id in one request: the API answers one page of them
#    and the reconcile fails instead of checking the rest.
control_expect "every reconcile request fits one page"
control_replace scripts/commands/sync.sh 1 \
    '    local batch_size=250' \
    '    local batch_size=100000'

# 2. Stop after ten batches of 250, the old page cap: the ids past 2500 are
#    never checked.
control_expect "every cached id is checked against the API"
control_replace scripts/commands/sync.sh 1 \
    '    while (( offset < ${#ids[@]} )); do' \
    '    while (( offset < ${#ids[@]} && offset < 2500 )); do'

# 3. Read a paged batch as answered whole: the ids the API never answered for
#    are pruned as deleted.
control_expect "a paged reconcile batch prunes nothing"
control_replace scripts/commands/sync.sh 1 \
    '        if [[ "$has_next" != "false" ]]; then' \
    '        if [[ "$has_next" == "never" ]]; then'
