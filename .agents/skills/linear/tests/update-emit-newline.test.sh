#!/usr/bin/env bash
# Regression test for kendex hotfix: linear_update_activity_type must terminate
# its output with a newline so `read -r ...` returns 0 under `set -e`.
# Before the hotfix, the lack of a trailing newline made `read` return 1 at
# EOF, which aborted the update path via set -e BEFORE emit_linear_issue_activity
# could fire. As a result, linear.issue_updated / _finished / _cancelled events
# never landed in the activity sidecar.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISSUES_SH="$SCRIPT_DIR/../scripts/commands/issues.sh"

# Source only the function under test so we don't trigger the script's main
# dispatch.
# shellcheck disable=SC1090
source <(awk '/^linear_update_activity_type\(\)/,/^}$/' "$ISSUES_SH")

assert_pair() {
    local label="$1" normalized="$2" expect_type="$3" expect_sev="$4"
    local out_t out_s
    set +e
    read -r out_t out_s < <(linear_update_activity_type "$normalized")
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "FAIL $label: read returned non-zero ($rc) — function missed terminating newline"
        exit 1
    fi
    if [ "$out_t" != "$expect_type" ] || [ "$out_s" != "$expect_sev" ]; then
        echo "FAIL $label: got '$out_t $out_s', expected '$expect_type $expect_sev'"
        exit 1
    fi
    echo "PASS $label"
}

assert_pair "completed state -> issue_finished success" \
    '{"data":{"issue":{"state":{"name":"Done","type":"completed"}}}}' \
    "linear.issue_finished" "success"

assert_pair "canceled state -> issue_cancelled warning" \
    '{"data":{"issue":{"state":{"name":"Canceled","type":"canceled"}}}}' \
    "linear.issue_cancelled" "warning"

assert_pair "in_progress state -> issue_updated info" \
    '{"data":{"issue":{"state":{"name":"In Progress","type":"started"}}}}' \
    "linear.issue_updated" "info"

echo "all pass"
