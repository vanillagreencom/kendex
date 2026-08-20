#!/usr/bin/env bash
# The repository's own kendex.settings.toml must resolve the review gate to
# "review" and its timeout policy to "proceed". The reviewers here comment
# but never approve, so any other recognized value — and any misspelling,
# which the gate tolerates by warning and falling back to approval/block —
# re-arms a gate no reviewer can open and stalls every session.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TEST_DIR/../scripts"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"
  [[ -s "$2" ]] && sed 's/^/        stderr: /' "$2"
}

# Read the committed file the way the gate does: from the repository root,
# with the process env silent on every key that could override it.
silent_env=(env -u PR_REVIEW_GATE -u PR_APPROVAL_GATE -u REVIEW_GATE_MODE -u PR_REVIEW_ON_TIMEOUT)

gate=$(cd "$REPO_ROOT" && "${silent_env[@]}" "$SCRIPTS/approval-wait" --resolve-mode 2>"$TMP/gate.err")
if [[ "$gate" == "review" ]]; then ok "committed PR_REVIEW_GATE resolves to review"
else bad "committed PR_REVIEW_GATE resolves to review (got '$gate')" "$TMP/gate.err"; fi
if ! grep -q unrecognized "$TMP/gate.err"; then ok "PR_REVIEW_GATE resolved without a fallback warning"
else bad "PR_REVIEW_GATE resolved without a fallback warning" "$TMP/gate.err"; fi

policy=$(cd "$REPO_ROOT" && "${silent_env[@]}" "$SCRIPTS/orch-env" PR_REVIEW_ON_TIMEOUT block 2>"$TMP/policy.err")
if [[ "$policy" == "proceed" ]]; then ok "committed PR_REVIEW_ON_TIMEOUT resolves to proceed"
else bad "committed PR_REVIEW_ON_TIMEOUT resolves to proceed (got '$policy')" "$TMP/policy.err"; fi
if ! grep -q unrecognized "$TMP/policy.err"; then ok "PR_REVIEW_ON_TIMEOUT resolved without a warning"
else bad "PR_REVIEW_ON_TIMEOUT resolved without a warning" "$TMP/policy.err"; fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
