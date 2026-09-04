# Drop the wrapped issue so every --format branch falls back to the mutation
# summary. --format=safe then reports success instead of the updated issue,
# which is what  looked like from the caller's side.
control_expect "update --format=safe emits the safe issue with parent_id and agent"
control_replace scripts/commands/issues.sh 1 \
    '        wrapped_issue=$(jq -n --argjson i "$updated_issue" '"'"'{issue: $i}'"'"')' \
    '        wrapped_issue=""'
