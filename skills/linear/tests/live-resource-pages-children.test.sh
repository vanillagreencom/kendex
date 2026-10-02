#!/bin/bash
# The real page owner consumes sanitized Relay replies. Dependencies alone are
# fixtures. The matching control restores each broken rule.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir PAGE_ROOT
PAGE_ROOT="$(cd -- "$PAGE_ROOT" && pwd -P)" || exit 1

while IFS='|' read -r name mode check; do
    pages_case "$name" "$mode"
    assert_eq "$name: completes" "$PAGE_RC" 0
    assert_jq "$name: rows and fields" "$PAGE_OUT" "$check"
    assert_file_lacks "$name: no argument-size failure" "$PAGE_ROOT/error" 'Argument list too long'
done <<'ROWS'
children-recursive|query|(.issue.children.nodes | length == 2) and (.issue.children.nodes[1] | has("description") | not) and (.issue.children.nodes[1].children.nodes | length == 2) and (.issue.children.nodes[1].children.nodes[1] | has("children") | not)
children|query|(.issue.children.nodes | length == 2) and (.issue.children.nodes[0].labels.nodes | length == 2) and (.issue.children.nodes[1].children.nodes | length == 2) and (.issue.children.nodes[1].children.nodes[1] | has("children") | not)
ROWS

# The final success row keeps its request log for the depth assertion.
while IFS='|' read -r owner cursor depth; do
    assert "children: $owner continuation keeps requested depth" jq -se \
        --arg owner "$owner" --arg cursor "$cursor" --argjson depth "$depth" '
        [.[] | select(.variables.id == $owner and .variables.after == $cursor)] |
        length == 1 and (.[0].query |
            ([scan("children\\(")] | length) == $depth and
            ([scan("children\\(first: 1\\)")] | length) == ($depth - 1))' \
        "$PAGE_ROOT/requests"
done <<'ROWS'
parent|ch1|2
child-b|g1|1
ROWS

# Failed child continuations come from GraphQL replies.
while IFS='|' read -r name mode cause; do
    pages_case "$name" "$mode"
    assert_ne "$name: refuses" "$PAGE_RC" 0
    assert_eq "$name: empty stdout" "$PAGE_OUT" ''
    assert_file_contains "$name: cause" "$PAGE_ROOT/error" "$cause"
done <<'ROWS'
children-failure|query|fixture: later page failed
ROWS
