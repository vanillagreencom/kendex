# 1. Drop the refusal: every completed-blocker relation is deleted again.
control_expect "a Done blocker named by --blocked-by is refused: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    [ -n "$blocker" ] || return 0' \
    '    return 0'

# 2. Judge Canceled open, so only a Done blocker is kept.
control_expect "a Canceled blocker named by --blocks is refused: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    blocker=$(jq -r "$ISSUE_RELATION_JQ"'"'"'.issueRelation | select(.type == "blocks" and (.issue | issue_is_open | not)) | [.issue.identifier, .issue.state.name, .issue.parent.identifier // "", .relatedIssue.parent.identifier // ""] | join("|")'"'"' <<<"$relation") || return 1' \
    '    blocker=$(jq -r "$ISSUE_RELATION_JQ"'"'"'.issueRelation | select(.type == "blocks" and .issue.state.type == "completed") | [.issue.identifier, .issue.state.name, .issue.parent.identifier // "", .relatedIssue.parent.identifier // ""] | join("|")'"'"' <<<"$relation") || return 1'

# 3. Take the structural-repair flag on its word, without the peer rule.
control_expect "the structural repair is refused for a peer pair: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$2" = "true" ] && ! blocking_level_ok "$blocker_parent" "$blocked_parent"; then' \
    '    if [ "$2" = "true" ]; then'

# 4. Close the structural-repair route.
control_expect "the structural repair removes a Done blocker that crosses bundles: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$2" = "true" ] && ! blocking_level_ok "$blocker_parent" "$blocked_parent"; then' \
    '    if false; then'
