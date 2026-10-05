#!/bin/bash
# Read verbs through linear.sh against Linear's own replies, recorded read-only
# and redacted (tests/lib/fixtures/recorded/README.md): recorded_read_case in
# lib/assert.sh drives each one. A complete cursor chain returns every recorded
# row; a chain whose later page fails exits nonzero and prints nothing; no
# read writes a local store.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1

for name in issues-list issues-get issues-bundle issues-bulk-get issues-children issues-children-recursive issues-children-pending issues-children-pending-raw issues-relations; do
    recorded_read_case "$name"
done
