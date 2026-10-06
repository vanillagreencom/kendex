# 1. Drop the refusal: every completed-blocker relation is deleted again.
control_expect "a Done blocker named by --blocked-by is refused: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    [ -n "$blocker" ] || return 0' \
    '    return 0'

# 2. Judge Canceled open, so only a Done blocker is kept.
control_expect "a Canceled blocker named by --blocks is refused: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    blocker=$(jq -r "$ISSUE_RELATION_JQ"'"'"'.issueRelation | select(.type == "blocks" and (.issue | issue_is_open | not)) | "\(.issue.parent.identifier // "")/\(.relatedIssue.parent.identifier // "") blocker=\(.issue.identifier) state=\(.issue.state.name)"'"'"' <<<"$relation") || return 1' \
    '    blocker=$(jq -r "$ISSUE_RELATION_JQ"'"'"'.issueRelation | select(.type == "blocks" and .issue.state.type == "completed") | "\(.issue.parent.identifier // "")/\(.relatedIssue.parent.identifier // "") blocker=\(.issue.identifier) state=\(.issue.state.name)"'"'"' <<<"$relation") || return 1'

# 3. Take the structural-repair flag on its word, without the peer rule.
control_expect "the structural repair is refused for a peer pair: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$2" = "true" ] && ! blocking_level_ok "${parents%/*}" "${parents#*/}"; then return 0; fi' \
    '    if [ "$2" = "true" ]; then return 0; fi'

# 4. Close the structural-repair route.
control_expect "the structural repair removes a Done blocker that crosses bundles: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$2" = "true" ] && ! blocking_level_ok "${parents%/*}" "${parents#*/}"; then return 0; fi' \
    '    if false; then return 0; fi'

# 5. Remove a cross-bundle completed blocker without the flag.
control_expect "a Done blocker that crosses bundles is refused without the structural-repair flag: exit status"
control_replace scripts/commands/issues.sh 1 \
    '    if [ "$2" = "true" ] && ! blocking_level_ok "${parents%/*}" "${parents#*/}"; then return 0; fi' \
    '    if ! blocking_level_ok "${parents%/*}" "${parents#*/}"; then return 0; fi'

# 6. Let a failed relation read through to the delete.
control_expect "a failed relation read deletes nothing: deleted relation"
control_replace scripts/commands/issues.sh 1 \
    '        "$(jq -cn --arg id "$1" '"'"'{id: $id}'"'"')") || return 1' \
    '        "$(jq -cn --arg id "$1" '"'"'{id: $id}'"'"')") || true'

# 7. Read the flag as given on the relation UUID route.
control_expect "a Done blocker that crosses bundles is refused by relation UUID without the structural-repair flag: exit status"
control_replace scripts/commands/issues.sh 1 \
    '        refuse_completed_blocker "$relation_id" "$([ "${1:-}" != --peer-rule-violation ] || echo true)" || return 1' \
    '        refuse_completed_blocker "$relation_id" true || return 1'

# 8. Read the flag as given on the issue route.
control_expect "a Done blocker that crosses bundles is refused without the structural-repair flag: deleted relation"
control_replace scripts/commands/issues.sh 1 \
    '    local peer_rule_violation=""' \
    '    local peer_rule_violation="true"'
