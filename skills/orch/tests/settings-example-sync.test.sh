#!/usr/bin/env bash
# vstack#683-class guard: the orch skill ships vstack.settings.toml.example so
# project installs merge the orch keys' defaults. This test keeps that template
# in lockstep with the repo-root vstack.settings.toml.example — every orch key
# must exist in BOTH files with IDENTICAL default values, so the two places
# users learn the options can never drift.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_TEMPLATE="$SCRIPT_DIR/../vstack.settings.toml.example"
ROOT_TEMPLATE="$SCRIPT_DIR/../../../vstack.settings.toml.example"

ORCH_KEYS="PR_REVIEW_GATE PR_REVIEW_NUDGE_SECS PR_REVIEW_NUDGE PR_REVIEW_CHECK PR_REVIEW_ON_TIMEOUT PR_REVIEW_OUTAGE_CONTEXT CI_WAIT_NO_CHECKS_GRACE CI_FIX_MAX_CYCLES REVIEWER_SLOT_BUDGET"

fail=0

check() {
  if ! eval "$2"; then
    echo "FAIL: $1"
    fail=1
  fi
}

value_of() {
  # First uncommented assignment of key $2 in file $1, value only.
  sed -n "s/^$2 = \"\(.*\)\"$/\1/p" "$1" | head -1
}

check "orch skill template exists" "[ -f \"\$SKILL_TEMPLATE\" ]"
check "root template exists (skip-safe in downstream installs)" "[ -f \"\$ROOT_TEMPLATE\" ] || exit 0"

check "skill template declares [env]" "grep -q '^\[env\]' \"\$SKILL_TEMPLATE\""

for key in $ORCH_KEYS; do
  skill_val="$(value_of "$SKILL_TEMPLATE" "$key")"
  root_val="$(value_of "$ROOT_TEMPLATE" "$key")"
  check "$key present in skill template" "grep -q \"^$key = \" \"\$SKILL_TEMPLATE\""
  check "$key present in root template" "grep -q \"^$key = \" \"\$ROOT_TEMPLATE\""
  if [ "$skill_val" != "$root_val" ]; then
    echo "FAIL: $key default drift: skill='$skill_val' root='$root_val'"
    fail=1
  fi
done

# The security caveat for name-matched evidence must travel with the key.
check "PR_REVIEW_CHECK carries the trust-model caveat" \
  "grep -B2 '^PR_REVIEW_CHECK = ' \"\$SKILL_TEMPLATE\" | grep -qi 'SECURITY' || grep -B6 '^PR_REVIEW_CHECK = ' \"\$SKILL_TEMPLATE\" | grep -qi 'SECURITY'"

if [ "$fail" -ne 0 ]; then
  echo "settings-example-sync: FAIL"
  exit 1
fi
echo "pass: settings-example-sync"
