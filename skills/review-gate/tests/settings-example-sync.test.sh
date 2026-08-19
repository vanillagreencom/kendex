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
GATE_KEYS="REVIEW_GATE_CONTEXT REVIEW_GATE_TRUSTED_STATUS_CONTEXTS REVIEW_GATE_CHECKRUN_SKIP_PATTERNS REVIEW_GATE_COMMENT_REVIEWERS REVIEW_GATE_SHA_PREFIX_FLOOR REVIEW_GATE_OVERRIDE_CONTEXT REVIEW_GATE_STATUS_PUBLISHER_REJECT REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS REVIEW_GATE_REVIEW_OBJECT_MIN_STATE REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS REVIEW_GATE_THREADS REVIEW_GATE_API_ATTEMPTS REVIEW_GATE_API_RETRY_DELAY_SECONDS REVIEW_GATE_CARRY_FORWARD REVIEW_GATE_CARRY_FORWARD_EXCLUDE REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC REVIEW_GATE_MODE"

passed=0
failed=0
skipped=0

# check DESC CMD... — CMD is run as a command, never eval'd. An assertion
# that could `exit` would end the RUN rather than itself, and the summary
# below would then report a green verdict for every comparison it never
# reached; there is no expression string here for one to hide in.
check() {
  local desc="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
  else
    echo "FAIL: $desc"
    failed=$((failed + 1))
  fi
}

# skip REASON — a comparison this run cannot make. Counted, printed, and
# reported in the summary, so an unmeasured run never reads as a clean one.
skip() {
  echo "  skip  $1"
  skipped=$((skipped + 1))
}

summary() {
  echo "settings-example-sync: $passed passed, $failed failed, $skipped skipped"
}

# has_key FILE KEY — KEY carries a QUOTED default in FILE. The quotes are
# part of the contract: value_of reads that form and nothing else, so a key
# written any other way would compare as an empty default against a real one
# and two drifted unquoted values would agree.
has_key() {
  grep -q "^$2 = \"" "$1"
}

# has_caveat FILE KEY — a SECURITY caveat sits within the 12 lines above KEY.
has_caveat() {
  grep -B12 "^$2 = \"" "$1" | grep -qi 'SECURITY'
}

# value_of FILE KEY — first uncommented assignment of KEY in FILE, value
# only. One sed, no pipeline: a SIGPIPE from a `| head -1` would fail the
# command substitution and, under `set -e`, end the run mid-comparison.
value_of() {
  sed -n "/^$2 = \"/{s/^$2 = \"\(.*\)\"\$/\1/p;q;}" "$1"
}

# The skill template ships beside this test; its absence is a broken
# checkout, not a downstream condition, and every comparison below reads it.
if [ ! -f "$SKILL_TEMPLATE" ]; then
  echo "FAIL: review-gate skill template missing: $SKILL_TEMPLATE"
  failed=1
  summary
  exit 1
fi

# The root template exists only in the vstack source tree. A downstream
# install that vendors the skill alone skips the cross-file comparisons —
# one counted skip per key — and still runs every skill-side assertion.
root_present=1
if [ ! -f "$ROOT_TEMPLATE" ]; then
  root_present=""
fi

check "skill template declares [env]" grep -q '^\[env\]' "$SKILL_TEMPLATE"

for key in $GATE_KEYS; do
  check "$key present in skill template" has_key "$SKILL_TEMPLATE" "$key"
  if [ -z "$root_present" ]; then
    skip "$key cross-template comparison: root template absent ($ROOT_TEMPLATE)"
    continue
  fi
  check "$key present in root template" has_key "$ROOT_TEMPLATE" "$key"
  skill_val="$(value_of "$SKILL_TEMPLATE" "$key")"
  root_val="$(value_of "$ROOT_TEMPLATE" "$key")"
  check "$key default drift: skill='$skill_val' root='$root_val'" \
    test "$skill_val" = "$root_val"
done

# The security caveats must travel with the keys that need them: name-matched
# evidence trust and the publisher reject-list.
for caveat_key in REVIEW_GATE_TRUSTED_STATUS_CONTEXTS REVIEW_GATE_COMMENT_REVIEWERS REVIEW_GATE_OVERRIDE_CONTEXT REVIEW_GATE_STATUS_PUBLISHER_REJECT; do
  check "$caveat_key carries the SECURITY caveat in the skill template" \
    has_caveat "$SKILL_TEMPLATE" "$caveat_key"
done

summary
if [ "$failed" -ne 0 ]; then
  echo "settings-example-sync: FAIL"
  exit 1
fi
echo "pass: settings-example-sync"
