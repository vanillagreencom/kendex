#!/bin/bash
# The real page owner consumes sanitized Relay replies. Dependencies alone are
# fixtures. controls/live-resource-pages.control.sh restores each broken rule.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir PAGE_ROOT
PAGE_ROOT="$(cd -- "$PAGE_ROOT" && pwd -P)" || exit 1

# The private HTTP 200 evidence is 345761 bytes: 75 issues, an open cursor,
# and descriptions up to 8042 characters. The fixture retains the field names
# and connection shape. All text, identifiers, URLs and cursors are synthetic.
# No headers, credentials or tracker text are copied into this suite.
while IFS='|' read -r name mode check; do
    pages_case "$name" "$mode"
    assert_eq "$name: completes" "$PAGE_RC" 0
    assert_jq "$name: rows and fields" "$PAGE_OUT" "$check"
    assert_file_lacks "$name: no argument-size failure" "$PAGE_ROOT/error" 'Argument list too long'
done <<'ROWS'
shape|pages|(.issues.nodes | length == 77) and (.issues.nodes[0] | has("children") | not) and (.issues.pageInfo.hasNextPage == false)
single|pages|(.issues.nodes | length == 1) and (.issues.nodes[0].description | length == 180000)
cumulative|pages|(.issues.nodes | length == 4) and ([.issues.nodes[].description | length] == [60000,60000,60000,60000])
entity|entity|(.description | length == 180000) and (.labels.nodes | length == 2)
nested|query|(.issue.labels.nodes | length == 2) and (.issue.labels.nodes[1].name | length == 180000)
children|query|(.issue.children.nodes | length == 2) and (.issue.children.nodes[0].labels.nodes | length == 2) and (.issue.children.nodes[1].children.nodes | length == 2) and (.issue.children.nodes[1].children.nodes[1] | has("children") | not)
root-rows|query|(.issues.nodes | length == 2) and (.issues.nodes[1].description | length == 180000)
create|query|.issueCreate.success == true and (.issueCreate.issue.description | length == 180000) and (.issueCreate.issue.labels.nodes | length == 2)
update|query|.issueUpdate.success == true and (.issueUpdate.issue.description | length == 180000) and (.issueUpdate.issue.labels.nodes | length == 2)
absent|query|.issue == {id:"owner",description:"short"} and .project == null
ROWS

pages_case bounded pages
assert_eq 'bounded: completes' "$PAGE_RC" 0
assert_jq 'bounded: preserves open metadata' "$PAGE_OUT" '(.issues.nodes | length == 1) and .issues.pageInfo.hasNextPage == true'
assert_file_lacks 'bounded: no continuation' "$PAGE_ROOT/requests" 'c1'

# Each independent chain rule has its own mutation. Malformed metadata comes
# from GraphQL replies, not from a fake implementation of the page owner.
while IFS='|' read -r name mode cause; do
    pages_case "$name" "$mode"
    assert_ne "$name: refuses" "$PAGE_RC" 0
    assert_eq "$name: empty stdout" "$PAGE_OUT" ''
    assert_file_contains "$name: cause" "$PAGE_ROOT/error" "$cause"
done <<'ROWS'
missing-metadata|pages|linear-pages: incomplete=issues
malformed-metadata|pages|linear-pages: incomplete=issues
malformed-nodes|pages|linear-pages: incomplete=issues
nested-metadata|query|linear-pages: incomplete=issue
nested-malformed|query|linear-pages: incomplete=issue
nested-missing-nodes|query|linear-pages: incomplete=issue
later-page|pages|fixture: later page failed
missing-cursor|pages|linear-pages: missing-cursor=issues
repeated-cursor|pages|linear-pages: repeated-cursor=issues
cap|pages|linear-pages: page-cap=issues
nested-failure|query|fixture: later page failed
children-failure|query|fixture: later page failed
ROWS

pages_case children query
assert_file_contains 'children: continuation keeps requested depth' "$PAGE_ROOT/requests" 'children(first: 1)'
