# Let the create path apply an undeclared label: it reaches Linear and is sent.
control_expect "create-undeclared: refused"
control_expect "create-undeclared: no write is sent"
control_expect "create-undeclared: refused before any request"
control_replace scripts/commands/issues.sh 1 \
    '    linear_require_declared_labels "$labels" || return 1' \
    '    linear_require_declared_labels "$labels" || :'

# Let the update path apply an undeclared label, which activation and block
# reach through it.
control_expect "update-undeclared: refused"
control_expect "update-undeclared: no write is sent"
control_expect "activate-undeclared: refused"
control_expect "activate-undeclared: no write is sent"
control_expect "block-undeclared: no write is sent"
control_replace scripts/commands/issues.sh 1 \
    '        linear_require_declared_labels "$labels" "$kept_labels" || return 1' \
    '        linear_require_declared_labels "$labels" "$kept_labels" || :'

# Judge a label the issue already carries as applied: every write to an issue
# labelled before the taxonomy refuses.
control_expect "update-kept: accepted"
control_expect "update-kept: the write is sent"
control_expect "activate-kept: accepted"
control_expect "activate-kept: the write is sent"
control_replace scripts/lib/common.sh 1 \
    '        [$requested | split(",")[] | select(length > 0)] - $declared - $kept | unique | join(",")'"'"') || return 1' \
    '        [$requested | split(",")[] | select(length > 0)] - $declared | unique | join(",")'"'"') || return 1'

# Read a taxonomy heading with no JSON block as no taxonomy.
control_expect "no-json: refused"
control_expect "no-json: the refusal names the unreadable taxonomy"
control_replace scripts/lib/common.sh 1 \
    '        END { if (state == 1 || state == 2) exit 3 }' \
    '        END { }'

# Read a JSON block under a later heading as the taxonomy.
control_expect "json-in-next-section: the refusal names the unreadable taxonomy"
control_replace scripts/lib/common.sh 1 \
    '        state == 1 && /^##?#? / { exit 3 }' \
    '        state == 1 && /^##?#? / { }'

# Accept a JSON block of the wrong shape.
control_expect "invalid-json: the refusal names the unreadable taxonomy"
control_replace scripts/lib/common.sh 1 \
    '                and ((.labels // []) | type == "array" and all(type == "string"))' \
    '                and true'

# Read a repository with no taxonomy as declaring none: every label refuses.
control_expect "none: create keeps today's behaviour"
control_expect "none: create sends the undeclared label"
control_replace scripts/lib/common.sh 1 \
    '    [[ -e "$file" || -L "$file" ]] || return 0' \
    '    [[ -e "$file" || -L "$file" ]] || { printf '"'"'[]\n'"'"'; return 0; }'

# Name the refused labels without the taxonomy file that declares them.
control_expect "create-undeclared: the refusal names the label and the taxonomy"
control_expect "update-undeclared: the refusal names the label and the taxonomy"
control_expect "activate-undeclared: the refusal names the label and the taxonomy"
control_expect "block-undeclared: the refusal names the label and the taxonomy"
control_expect "label-undeclared: the refusal is keyed"
control_replace scripts/lib/common.sh 1 \
    "        printf 'linear-labels: undeclared labels=%s taxonomy=%s\\n' \"\$value\" \"\$LINEAR_TAXONOMY_FILE\"" \
    "        printf 'linear-labels: undeclared labels=%s\\n' \"\$value\""

# Let labels create make an undeclared label.
control_expect "label-undeclared: refused"
control_expect "label-undeclared: no label is created"
control_replace scripts/commands/labels.sh 1 \
    '    linear_require_declared_labels "$name" || return 1' \
    '    linear_require_declared_labels "$name" || :'

# Let a team label take a name a workspace label uses.
control_expect "label-workspace-duplicate: refused"
control_expect "label-workspace-duplicate: the refusal is keyed"
control_expect "label-workspace-duplicate: no label is created"
control_replace scripts/commands/labels.sh 1 \
    '        if [ "$workspace_count" != 0 ]; then' \
    '        if [ "$workspace_count" = -1 ]; then'

# Judge a team label create by the workspace rule with no taxonomy declared.
control_expect "label-team-none: no taxonomy keeps today's team label create"
control_expect "label-team-none: no workspace lookup is sent"
control_replace scripts/commands/labels.sh 1 \
    '    if [ -n "$team" ] && [ -n "$declared" ]; then' \
    '    if [ -n "$team" ]; then'

# Report declared labels as the drift.
control_expect "audit: lists each undeclared label with the open issues carrying it"
control_replace scripts/commands/labels.sh 1 \
    '                | select(IN($declared[]) | not) | {label: ., issue: $issue}]' \
    '                | select(IN($declared[])) | {label: ., issue: $issue}]'

# Stop at the first page of open issues.
control_expect "audit: reads the open issues past the first page"
control_replace scripts/commands/labels.sh 1 \
    '        [ "$has_next" = true ] || break' \
    '        break'

# Report every label sharing a name, not only team/workspace pairs.
control_expect "audit: lists the same-name team and workspace pair"
control_replace scripts/commands/labels.sh 1 \
    '            | map(select(any(.[]; .team == null) and any(.[]; .team != null))' \
    '            | map(select(any(.[]; .team == null) or any(.[]; .team != null))'

# Read a page with no pageInfo as the last page.
control_expect "audit-pages: refused"
control_expect "audit-pages: a page with no pageInfo fails the audit"
control_replace scripts/commands/labels.sh 1 \
    '            ! has_next=$(jq -r --arg field "$field" '"'"'.[$field].pageInfo.hasNextPage | if type == "boolean" then . else error("hasNextPage") end'"'"' <<<"$result" 2>/dev/null); then' \
    '            ! has_next=$(jq -r --arg field "$field" '"'"'.[$field].pageInfo.hasNextPage // false'"'"' <<<"$result" 2>/dev/null); then'

# Audit with no taxonomy, reporting every label as drift.
control_expect "audit-absent: no taxonomy has nothing to audit against"
control_expect "audit-absent: no issue is read"
control_replace scripts/commands/labels.sh 1 \
    '    if [ -z "$declared" ]; then' \
    '    if [ -z "$declared" ] && false; then'
