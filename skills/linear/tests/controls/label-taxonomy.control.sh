# Let the create path apply an undeclared label: it reaches Linear and is sent.
control_expect "create-undeclared: refused"
control_expect "create-undeclared: no write is sent"
control_expect "create-undeclared: refused before any request"
control_replace scripts/commands/issues.sh 1 \
    '        linear_require_declared_labels "$labels" || return 1' \
    '        linear_require_declared_labels "$labels" || :'

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

# Read a JSON block with no closing fence as the taxonomy.
control_expect "unclosed-json: the refusal names the unreadable taxonomy"
control_replace scripts/lib/common.sh 1 \
    '        END { if (state == 0) exit 5; if (state != 3) exit 3 }' \
    '        END { if (state == 0) exit 5 }'

# Read a taxonomy heading over an empty JSON block as no taxonomy.
control_expect "empty-json: refused"
control_expect "empty-json: the refusal names the unreadable taxonomy"
control_replace scripts/lib/common.sh 1 \
    '    [[ "$rc" != 5 ]] || return 0' \
    '    [[ "$rc" != 5 && -n "$block" ]] || return 0'

# Read a render with no taxonomy heading as an unreadable taxonomy.
control_expect "no-heading: create keeps today's behaviour"
control_expect "no-heading: create sends the undeclared label"
control_replace scripts/lib/common.sh 1 \
    '    [[ "$rc" != 5 ]] || return 0' \
    '    [[ "$rc" != 6 ]] || return 0'

# Read the taxonomy beside the linear install, not in the project: a global
# install reads the global render and enforces nothing.
control_expect "label-outside-install: refused"
control_expect "label-outside-install: no label is written"
control_replace scripts/lib/common.sh 1 \
    'LINEAR_TAXONOMY_FILE="$PROJECT_ROOT/.agents/skills/project-management/SKILL.md"' \
    'LINEAR_TAXONOMY_FILE="${_LIB_DIR%/*/*/*}/project-management/SKILL.md"'

# Declare a match.parent category's labels[] without its group name.
control_expect "label-group: accepted"
control_replace scripts/lib/common.sh 1 \
    '        | [.categories[] | (.labels // [])[], (.match.parent // empty)]' \
    '        | [.categories[] | (.labels // [])[]]'

# Read the taxonomy for a create with no labels.
control_expect "label-less: an unreadable taxonomy does not stop a create with no labels"
control_expect "label-less: the create is sent"
control_replace scripts/commands/issues.sh 1 \
    '    if [[ -n "$labels" ]]; then' \
    '    if true; then'

# Skip a declared label Linear does not have, creating the issue without it.
control_expect "create-missing: refused"
control_expect "create-missing: no write is sent"
control_expect "create-missing: the refusal names the label and the taxonomy"
control_replace scripts/commands/issues.sh 1 \
    '                if [ -n "$declared" ]; then' \
    '                if false; then'

# Upload attachments before a declared label Linear does not have refuses.
control_expect "create-missing-attach: no write is sent"
control_expect "create-missing-attach: the refusal names the label and the taxonomy"
control_replace scripts/commands/issues.sh 1 \
    '                elif [ -n "$declared" ]; then' \
    '                elif false; then'

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
control_expect "label-undeclared: no label is written"
control_replace scripts/commands/labels.sh 1 \
    '    linear_require_declared_labels "$name" || return 1' \
    '    linear_require_declared_labels "$name" || :'

# Let a team label take a name a workspace label uses.
control_expect "label-workspace-duplicate: refused"
control_expect "label-workspace-duplicate: the refusal is keyed"
control_expect "label-workspace-duplicate: no label is written"
control_replace scripts/commands/labels.sh 1 \
    '    if [ "$workspace_count" != 0 ]; then' \
    '    if [ "$workspace_count" = -1 ]; then'

# Look the workspace label up without its workspace filter: a team label of
# the name reads as a workspace one.
control_expect "label-team: accepted"
control_replace scripts/commands/labels.sh 1 \
    "    local workspace_query='query WorkspaceLabel(\$name: String!) { issueLabels(filter: {name: {eq: \$name}, team: {null: true}}) { nodes { id } } }'" \
    "    local workspace_query='query WorkspaceLabel(\$name: String!) { issueLabels(filter: {name: {eq: \$name}}) { nodes { id } } }'"

# Judge a team label create by the workspace rule with no taxonomy declared.
control_expect "label-team-none: no taxonomy keeps today's team label create"
control_expect "label-team-none: no workspace lookup is sent"
control_replace scripts/commands/labels.sh 1 \
    '    [ -n "$declared" ] || return 0' \
    '    :'

# Rename a label to a name the taxonomy does not declare.
control_expect "label-rename-undeclared: refused"
control_expect "label-rename-undeclared: no label is written"
control_replace scripts/commands/labels.sh 1 \
    '        linear_require_declared_labels "$name" || return 1' \
    '        linear_require_declared_labels "$name" || :'

# Rename a label to a name a workspace label uses.
control_expect "label-rename-workspace-duplicate: refused"
control_expect "label-rename-workspace-duplicate: no label is written"
control_replace scripts/commands/labels.sh 1 \
    '        refuse_workspace_name "$name" "$label_id" || return 1' \
    '        refuse_workspace_name "$name" "$label_id" || :'

# Count the renamed workspace label as the duplicate of its own name.
control_expect "label-rename-self: accepted"
control_replace scripts/commands/labels.sh 1 \
    "    workspace_count=\$(jq -r --arg self \"\$label_id\" '[.issueLabels.nodes[] | select(.id != \$self)] | length' <<<\"\$workspace_result\") || return 1" \
    "    workspace_count=\$(jq -r '.issueLabels.nodes | length' <<<\"\$workspace_result\") || return 1"

# Report declared labels as the drift.
control_expect "audit: lists each undeclared label with the open issues carrying it"
control_replace scripts/commands/labels.sh 1 \
    '                | select(IN($declared[]) | not) | {label: ., issue: $issue}]' \
    '                | select(IN($declared[])) | {label: ., issue: $issue}]'

# Read every state's issues, closed ones included.
control_expect "audit: skips closed issues"
control_replace scripts/commands/labels.sh 1 \
    '    issues=$(audit_pages '"'"'query AuditIssues($teamId: ID!, $first: Int, $after: String) { issues(filter: {team: {id: {eq: $teamId}}, state: {type: {nin: ["completed", "canceled"]}}}, first: $first, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier labels(first: 100) { pageInfo { hasNextPage } nodes { name } } } } }'"'"' \' \
    '    issues=$(audit_pages '"'"'query AuditIssues($teamId: ID!, $first: Int, $after: String) { issues(filter: {team: {id: {eq: $teamId}}}, first: $first, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier labels(first: 100) { pageInfo { hasNextPage } nodes { name } } } } }'"'"' \'

# Read every team's open issues.
control_expect "audit: reads only the team's issues"
control_replace scripts/commands/labels.sh 1 \
    '    issues=$(audit_pages '"'"'query AuditIssues($teamId: ID!, $first: Int, $after: String) { issues(filter: {team: {id: {eq: $teamId}}, state: {type: {nin: ["completed", "canceled"]}}}, first: $first, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier labels(first: 100) { pageInfo { hasNextPage } nodes { name } } } } }'"'"' \' \
    '    issues=$(audit_pages '"'"'query AuditIssues($teamId: ID!, $first: Int, $after: String) { issues(filter: {state: {type: {nin: ["completed", "canceled"]}}}, first: $first, after: $after) { pageInfo { hasNextPage endCursor } nodes { identifier labels(first: 100) { pageInfo { hasNextPage } nodes { name } } } } }'"'"' \'

# Read every team's labels.
control_expect "audit: ignores another team's same-name label"
control_replace scripts/commands/labels.sh 1 \
    '    labels=$(audit_pages '"'"'query AuditLabels($teamId: ID!, $first: Int, $after: String) { issueLabels(filter: {or: [{team: {id: {eq: $teamId}}}, {team: {null: true}}]}, first: $first, after: $after) { pageInfo { hasNextPage endCursor } nodes { id name team { id } } } }'"'"' \' \
    '    labels=$(audit_pages '"'"'query AuditLabels($teamId: ID!, $first: Int, $after: String) { issueLabels(first: $first, after: $after) { pageInfo { hasNextPage endCursor } nodes { id name team { id } } } }'"'"' \'

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
