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

# The fixture closes after the page cap. The control moves that cap by one page.
while IFS='|' read -r name mode cause; do
    pages_case "$name" "$mode"
    assert_ne "$name: refuses" "$PAGE_RC" 0
    assert_eq "$name: empty stdout" "$PAGE_OUT" ''
    assert_file_contains "$name: cause" "$PAGE_ROOT/error" "$cause"
done <<'ROWS'
cap|pages|linear-pages: page-cap=issues
ROWS
