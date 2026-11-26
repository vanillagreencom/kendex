# Admit another profile so an unrelated comment becomes an owner request.
control_expect "distinct same-issue asks and exact profile mention"
control_replace scripts/commands/comments.sh 1 \
    '       requests: [$items[] | . as $issue | .comments[] | select(.body | mentions($owner.url))' \
    '       requests: [$items[] | . as $issue | .comments[] | select((.body | mentions($owner.url)) or true)'

# Drop continued metadata while keeping the original request selection intact.
control_expect "both issue and comment continuations preserve requests"
control_replace scripts/lib/pages.sh 1 \
    "    issue:comments) printf '%s' 'id body createdAt updatedAt user { name email } user { id } parent { id } url' ;;" \
    "    issue:comments) printf '%s' 'id body createdAt updatedAt user { name email }' ;; # user { id } parent { id } url"

control_expect "raw preference retains safe evidence"
control_replace scripts/commands/comments.sh 1 \
    "    jq -cs \"\$COMMENT_SAFE_JQ\$OWNER_RULING_JQ\$STATE_TYPE_CLOSED_JQ\"'" \
    "    jq -cs --arg format \"\$DEFAULT_FORMAT\" \"\$COMMENT_SAFE_JQ\"'def safe: comment_safe; def comment_safe: if \$format == \"raw\" then . else safe end;'\"\$OWNER_RULING_JQ\$STATE_TYPE_CLOSED_JQ\"'"

control_expect "large comment document succeeds"
control_replace scripts/commands/comments.sh 1 \
    "    jq -cs \"\$COMMENT_SAFE_JQ\$OWNER_RULING_JQ\$STATE_TYPE_CLOSED_JQ\"'" \
    "    jq -cs --argjson carried \"\$items\" \"\$COMMENT_SAFE_JQ\$OWNER_RULING_JQ\$STATE_TYPE_CLOSED_JQ\"'"
