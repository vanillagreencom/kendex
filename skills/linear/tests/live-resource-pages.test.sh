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

pages_case bounded pages
assert_eq 'bounded: completes' "$PAGE_RC" 0
assert_jq 'bounded: preserves open metadata' "$PAGE_OUT" '(.issues.nodes | length == 1) and .issues.pageInfo.hasNextPage == true'
assert_file_lacks 'bounded: no continuation' "$PAGE_ROOT/requests" 'c1'

