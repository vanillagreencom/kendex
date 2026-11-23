#!/usr/bin/env bash
# This repository's committed kendex.settings.toml must resolve the decision
# mode to "auto-recommended". "ask" is also a recognized value, so nothing
# else in the repo notices a change from one to the other, and "ask" stops
# every session at every decision. No script reports a misspelled
# ORCH_DECISION_MODE either, so this assertion is its only check.
#
# Lives under tools/tests/, not skills/orch/tests/: that suite ships with the
# orch skill to other projects, and this policy is kendex's alone. tools/tests
# is also what keeps the check merge-blocking — the guards-tools shard globs
# tools/tests/*.test.sh and rolls up into the required "Skill suites (shell +
# node)" and `CI` contexts under the repository required-checks ruleset.
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
# silent on the key. A lane exporting it would otherwise mask the committed
# value.
silent_env=(env -u ORCH_DECISION_MODE)

decision_mode=$(cd "$REPO_ROOT" && "${silent_env[@]}" "$SCRIPTS/orch-env" ORCH_DECISION_MODE ask 2>"$TMP/decision-mode.err")
if [[ "$decision_mode" == "auto-recommended" ]]; then
  ok "committed ORCH_DECISION_MODE resolves to auto-recommended"
else
  bad "committed ORCH_DECISION_MODE resolves to auto-recommended (got '$decision_mode')" "$TMP/decision-mode.err"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
