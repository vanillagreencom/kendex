#!/usr/bin/env bash
# This repository's committed kendex.settings.toml must resolve the reviewer
# timeout policy to "proceed" and the decision mode to "auto-recommended".
# Both are recognized values of their keys, so nothing else in the repo
# notices a change from one to the other: "block" stops every session at a
# reviewer that never shows, and "ask" stops it at every decision.
#
# A misspelled PR_REVIEW_ON_TIMEOUT is reported by approval-wait's
# timeout-fallback warning, which falls back to "block"; no script reports a
# misspelled ORCH_DECISION_MODE. What is checked here is the resolved value;
# for ORCH_DECISION_MODE this assertion is the only check.
#
# Lives under tools/tests/, not skills/orch/tests/: that suite ships with the
# orch skill to other projects, and this policy is kendex's alone. tools/tests
# is also what keeps the check merge-blocking — the guards-tools shard globs
# tools/tests/*.test.sh and rolls up into the required "Skill suites (shell +
# node)" context under the per-repository ruleset, which the gate-selftest
# job is not, and into `CI` under the organization ruleset that replaces it.
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

# Read the committed file from the repository root, with the process env
# silent on every key that could override it. A lane exporting one of these
# would otherwise mask a committed value.
silent_env=(env -u PR_REVIEW_ON_TIMEOUT -u ORCH_DECISION_MODE)

policy=$(cd "$REPO_ROOT" && "${silent_env[@]}" "$SCRIPTS/orch-env" PR_REVIEW_ON_TIMEOUT block 2>"$TMP/policy.err")
if [[ "$policy" == "proceed" ]]; then
  ok "committed PR_REVIEW_ON_TIMEOUT resolves to proceed"
else
  bad "committed PR_REVIEW_ON_TIMEOUT resolves to proceed (got '$policy')" "$TMP/policy.err"
fi

decision_mode=$(cd "$REPO_ROOT" && "${silent_env[@]}" "$SCRIPTS/orch-env" ORCH_DECISION_MODE ask 2>"$TMP/decision-mode.err")
if [[ "$decision_mode" == "auto-recommended" ]]; then
  ok "committed ORCH_DECISION_MODE resolves to auto-recommended"
else
  bad "committed ORCH_DECISION_MODE resolves to auto-recommended (got '$decision_mode')" "$TMP/decision-mode.err"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
