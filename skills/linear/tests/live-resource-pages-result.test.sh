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
root-rows|query|(.issues.nodes | length == 2) and (.issues.nodes[1].description | length == 180000)
create|query|.issueCreate.success == true and (.issueCreate.issue.description | length == 180000) and (.issueCreate.issue.labels.nodes | length == 2)
update|query|.issueUpdate.success == true and (.issueUpdate.issue.description | length == 180000) and (.issueUpdate.issue.labels.nodes | length == 2)
absent|query|.issue == {id:"owner",description:"short"} and .project == null
ROWS

