#!/usr/bin/env bash
# This repository's committed kendex.settings.toml must RESOLVE the review
# gate to "review" and its timeout policy to "proceed". The reviewers here
# comment but never approve, so `approval` re-arms a gate no reviewer can
# open and every session stalls, while `off` stops approval-wait waiting at
# all and a session proceeds as though a review had landed. Both are
# recognized values: approval-wait warns only on an unrecognized one, so
# nothing else in the repo notices either.
#
# This is the AGENT-side wait only. Whether a PR can merge without a review
# is decided by REVIEW_GATE_MODE through the review-gate predicate and the
# required "Review gate" context, which nothing here asserts.
#
# Spelling is approval-wait's to report and is not re-checked here. What is
# checked is the resolved value, which a warning cannot cover.
#
# Lives under tools/tests/, not skills/orch/tests/: that suite ships with the
# orch skill to other projects, and this policy is kendex's alone. tools/tests
# is also what keeps the check merge-blocking — the shell shard globs
# tools/tests/*.test.sh and rolls up into the required "Skill suites (shell +
# node)" context, which the gate-selftest job is not.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd)"
SCRIPTS="$REPO_ROOT/skills/orch/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  if [[ -s "$2" ]]; then sed 's/^/        stderr: /' "$2"; fi
}

# Read the committed file the way the gate does: from the repository root,
# with the process env silent on every key that could override it. A lane
# exporting one of these would otherwise mask a committed value.
silent_env=(env -u PR_REVIEW_GATE -u PR_APPROVAL_GATE -u REVIEW_GATE_MODE -u PR_REVIEW_ON_TIMEOUT)

gate=$(cd "$REPO_ROOT" && "${silent_env[@]}" "$SCRIPTS/approval-wait" --resolve-mode 2>"$TMP/gate.err")
if [[ "$gate" == "review" ]]; then
  ok "committed PR_REVIEW_GATE resolves to review"
else
  bad "committed PR_REVIEW_GATE resolves to review (got '$gate')" "$TMP/gate.err"
fi

policy=$(cd "$REPO_ROOT" && "${silent_env[@]}" "$SCRIPTS/orch-env" PR_REVIEW_ON_TIMEOUT block 2>"$TMP/policy.err")
if [[ "$policy" == "proceed" ]]; then
  ok "committed PR_REVIEW_ON_TIMEOUT resolves to proceed"
else
  bad "committed PR_REVIEW_ON_TIMEOUT resolves to proceed (got '$policy')" "$TMP/policy.err"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
