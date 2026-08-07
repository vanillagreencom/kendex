#!/usr/bin/env bash
# The review-gate skill ships vstack.settings.toml.example so project
# installs merge the engine's trust defaults. This test keeps that template
# in lockstep with the repo-root vstack.settings.toml.example — every
# REVIEW_GATE key must exist in BOTH files with IDENTICAL default values, so
# the two places users learn the options can never drift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_TEMPLATE="$SCRIPT_DIR/../vstack.settings.toml.example"
ROOT_TEMPLATE="$SCRIPT_DIR/../../../vstack.settings.toml.example"

# REVIEW_GATE_OVERRIDE_CONTEXT, not the legacy REVIEW_GATE_OUTAGE_CONTEXT:
# the examples model the v2 posture and assign only the v2 key (the
# vars-documented test enforces the legacy key's absence).
GATE_KEYS="REVIEW_GATE_CONTEXT REVIEW_GATE_TRUSTED_STATUS_CONTEXTS REVIEW_GATE_CHECKRUN_SKIP_PATTERNS REVIEW_GATE_COMMENT_REVIEWERS REVIEW_GATE_SHA_PREFIX_FLOOR REVIEW_GATE_OVERRIDE_CONTEXT REVIEW_GATE_STATUS_PUBLISHER_REJECT REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS REVIEW_GATE_REVIEW_OBJECT_MIN_STATE REVIEW_GATE_THREADS REVIEW_GATE_API_ATTEMPTS REVIEW_GATE_API_RETRY_DELAY_SECONDS REVIEW_GATE_CARRY_FORWARD"

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

check "review-gate skill template exists" "[ -f \"\$SKILL_TEMPLATE\" ]"
check "root template exists (skip-safe in downstream installs)" "[ -f \"\$ROOT_TEMPLATE\" ] || exit 0"

check "skill template declares [env]" "grep -q '^\[env\]' \"\$SKILL_TEMPLATE\""

for key in $GATE_KEYS; do
  skill_val="$(value_of "$SKILL_TEMPLATE" "$key")"
  root_val="$(value_of "$ROOT_TEMPLATE" "$key")"
  check "$key present in skill template" "grep -q \"^$key = \" \"\$SKILL_TEMPLATE\""
  check "$key present in root template" "grep -q \"^$key = \" \"\$ROOT_TEMPLATE\""
  if [ "$skill_val" != "$root_val" ]; then
    echo "FAIL: $key default drift: skill='$skill_val' root='$root_val'"
    fail=1
  fi
done

# The security caveats must travel with the keys that need them: name-matched
# evidence trust and the publisher reject-list.
for caveat_key in REVIEW_GATE_TRUSTED_STATUS_CONTEXTS REVIEW_GATE_COMMENT_REVIEWERS REVIEW_GATE_OVERRIDE_CONTEXT REVIEW_GATE_STATUS_PUBLISHER_REJECT; do
  check "$caveat_key carries the SECURITY caveat in the skill template" \
    "grep -B12 \"^$caveat_key = \" \"\$SKILL_TEMPLATE\" | grep -qi 'SECURITY'"
done

if [ "$fail" -ne 0 ]; then
  echo "settings-example-sync: FAIL"
  exit 1
fi
echo "pass: settings-example-sync"
