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

# REVIEW_GATE_MODE's owning skill is review-gate (its settings-example-sync
# test pins the same key); orch lists it too because orch consumes the
# one-switch gate disable even where the review-gate engine is not installed.
ORCH_KEYS="PR_REVIEW_GATE REVIEW_GATE_MODE PR_REVIEW_WAIT_SECS PR_REVIEW_NUDGE_SECS PR_REVIEW_NUDGE PR_REVIEW_CHECK PR_REVIEW_ON_TIMEOUT CI_WAIT_NO_CHECKS_GRACE CI_FIX_MAX_CYCLES REVIEWER_SLOT_BUDGET ORCH_DECISION_MODE ORCH_TMUX_VERIFY_SECS"

# Opt-in keys with no shipped default: the skill template carries a COMMENTED
# example (nothing to merge, so no uncommented assignment) so the option is
# still discoverable where its skill is installed.
ORCH_OPTIN_KEYS=""
SKILL_ONLY_OPTIN_KEYS="ORCH_LANE_ALIASES"

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

for key in $ORCH_OPTIN_KEYS; do
  check "$key commented example present in skill template" "grep -Eq \"^#[[:space:]]*${key}[[:space:]]*=\" \"\$SKILL_TEMPLATE\""
  check "$key commented example present in root template" "grep -Eq \"^#[[:space:]]*${key}[[:space:]]*=\" \"\$ROOT_TEMPLATE\""
done

for key in $SKILL_ONLY_OPTIN_KEYS; do
  check "$key commented example present in skill template" "grep -Eq \"^#[[:space:]]*${key}[[:space:]]*=\" \"\$SKILL_TEMPLATE\""
done

# The security caveat for name-matched evidence must travel with the key.
check "PR_REVIEW_CHECK carries the trust-model caveat" \
  "grep -B2 '^PR_REVIEW_CHECK = ' \"\$SKILL_TEMPLATE\" | grep -qi 'SECURITY' || grep -B6 '^PR_REVIEW_CHECK = ' \"\$SKILL_TEMPLATE\" | grep -qi 'SECURITY'"

if [ "$fail" -ne 0 ]; then
  echo "settings-example-sync: FAIL"
  exit 1
fi
echo "pass: settings-example-sync"
