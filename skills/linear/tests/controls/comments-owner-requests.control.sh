# Admit another profile so an unrelated comment becomes an owner request.
control_expect "distinct same-issue asks and exact profile mention"
control_replace scripts/commands/comments.sh 1 \
    '      | . + {requests: [.issues[] | . as $issue | .comments[] | select(.body | mentions($owner.url))' \
    '      | . + {requests: [.issues[] | . as $issue | .comments[] | select((.body | mentions($owner.url)) or true)'

# Drop continued metadata while keeping the original request selection intact.
control_expect "continued author, thread and URL survive projection"
control_replace scripts/lib/pages.sh 1 \
    "    issue:comments) printf '%s' 'id body createdAt updatedAt user { name email } user { id url } parent { id } url' ;;" \
    "    issue:comments) printf '%s' 'id body createdAt updatedAt user { name email }' ;; # user { id url } parent { id } url"

control_expect "public _LIB_DIR never executes checkout code"
control_replace scripts/lib/common.sh 1 \
    'readonly _LIB_DIR SCRIPT_DIR BASH BASH_ENV' ': # readonly _LIB_DIR SCRIPT_DIR BASH BASH_ENV'

control_expect "raw preference retains safe evidence"
control_replace scripts/commands/comments.sh 1 \
    '    if [[ ${#refs[@]} -gt 0 ]]; then comments=$(bulk_list_comments --format=safe "${refs[@]}") || return 1; fi' \
    '    if [[ ${#refs[@]} -gt 0 ]]; then comments=$(bulk_list_comments "${refs[@]}") || return 1; fi'

control_expect "large-comments complete document succeeds"
control_replace scripts/commands/comments.sh 1 \
    "    jq -cs '" "    jq -cs --argjson carried \"\$comments\" '"
