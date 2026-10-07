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
ROWS

# A --max read spools its pages: the merge is the one an independent jq makes
# of the fixture, and no variable the pager's shell sees outgrows one page.
PAGES_LARGEST="$PAGE_ROOT/largest" pages_case cumulative pages
assert_eq 'spooled: completes' "$PAGE_RC" 0
assert_eq 'spooled: merged result' "$PAGE_OUT" "$(jq -c '. as $f | .replies[-1].response |
    .issues.nodes = [($f.initial, $f.replies[].response) | .issues.nodes[]]' "$PAGE_ROOT/fixture.json")"
page_size=$(jq '[.initial, .replies[].response | tojson | length] | max' "$PAGE_ROOT/fixture.json")
largest=$(sort -n "$PAGE_ROOT/largest" | tail -n 1)
assert 'spooled: no variable past one page' test "${largest%% *}" -le "$page_size"

# A row whose own collection is open completes alone: the merged backlog still
# never enters a variable, and each row gains its continuation.
PAGES_LARGEST="$PAGE_ROOT/largest" pages_case cumulative-open pages
assert_eq 'spooled-open: completes' "$PAGE_RC" 0
assert_eq 'spooled-open: merged result' "$PAGE_OUT" "$(jq -c '. as $f | .replies[] | select(.id == null and .response.issues.pageInfo.hasNextPage == false) | .response |
    .issues.nodes = [($f.initial, ($f.replies[] | select(.id == null) | .response)) | .issues.nodes[] |
        .labels = {nodes: [{name: "a"}, {name: "b"}], pageInfo: {hasNextPage: false, endCursor: null}}]' "$PAGE_ROOT/fixture.json")"
# One completed row holds a root page's row and its own continuation page.
page_size=$(jq '([.initial, (.replies[] | select(.id == null) | .response) | tojson | length] | max)
    + ([.replies[] | select(.id != null) | .response | tojson | length] | max)' "$PAGE_ROOT/fixture.json")
largest=$(sort -n "$PAGE_ROOT/largest" | tail -n 1)
assert 'spooled-open: no variable past one page' test "${largest%% *}" -le "$page_size"

pages_case bounded pages
assert_eq 'bounded: completes' "$PAGE_RC" 0
assert_jq 'bounded: preserves open metadata' "$PAGE_OUT" '(.issues.nodes | length == 1) and .issues.pageInfo.hasNextPage == true'
assert_file_lacks 'bounded: no continuation' "$PAGE_ROOT/requests" 'c1'

