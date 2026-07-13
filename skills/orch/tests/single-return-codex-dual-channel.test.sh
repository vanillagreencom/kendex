#!/usr/bin/env bash
# Regression tests for orch's Single Return Message invariant under Codex
# collaboration agents (vstack#532).
#
# A compliant Codex sub-agent delivers its single completion over two channels:
# a `send_input` MESSAGE followed by a FINAL_ANSWER that echoes the same
# commit/scope/findings. The invariant must recognize that pair as ONE
# completion (deduplicated, not a violation) while STILL flagging a genuine
# second return that introduces a new commit or extra changes. dev/SKILL.md
# must state that the send_input MESSAGE is the return and the FINAL_ANSWER
# echo is expected, not a separate return.
#
# Hermetic: greps SKILL.md prose on disk only, no network.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"

PASS=0
FAIL=0

# Assert a phrase appears anywhere in a file (tolerant substring match).
assert_contains() {
  local file="$1" needle="$2" name="$3"
  if grep -Fq -- "$needle" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing: %s\n        file:    %s\n' "$name" "$needle" "$file"
  fi
}

# Assert a phrase appears within a specific `#### <heading>` section, so the
# guidance is anchored to the Single Return Message invariant, not just present
# somewhere else in the file. Section ends at the next `#### ` heading or a
# horizontal rule (`---`).
assert_section_contains() {
  local file="$1" heading="$2" needle="$3" name="$4"
  local body
  body=$(awk -v h="$heading" '
    index($0, "#### " h) == 1 { grab = 1; next }
    grab && /^#### / { grab = 0 }
    grab && /^---$/  { grab = 0 }
    grab { print }
  ' "$file")
  if grep -Fq -- "$needle" <<<"$body"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing in section "%s": %s\n        file: %s\n' \
      "$name" "$heading" "$needle" "$file"
  fi
}

echo "=== Single Return Message: Codex dual-channel completion (vstack#532) ==="

orch_skill="$REPO_ROOT/skills/orch/SKILL.md"
dev_skill="$REPO_ROOT/skills/dev/SKILL.md"

# --- orch: Single Return Message section recognizes the Codex MESSAGE +
#     echoed FINAL_ANSWER pair as ONE completion (deduplicated, not a violation).
sec="Single Return Message"
assert_section_contains "$orch_skill" "$sec" "FINAL_ANSWER" \
  "orch section names the Codex FINAL_ANSWER echo"
assert_section_contains "$orch_skill" "$sec" "MESSAGE" \
  "orch section names the send_input MESSAGE channel"
assert_section_contains "$orch_skill" "$sec" "one completion" \
  "orch section treats the pair as one completion"
assert_section_contains "$orch_skill" "$sec" "deduplicate" \
  "orch section deduplicates rather than flagging a violation"

# The harness cause is framed explicitly so the reader does not misattribute it
# to [FORMATTED_ITEMS] leakage.
assert_section_contains "$orch_skill" "$sec" "Codex runtime" \
  "orch section attributes the duplication to the Codex runtime"

# --- orch: the existing genuine-second-return protection is retained: a NEW
#     commit / extra changes / different scope is still a real second return.
assert_section_contains "$orch_skill" "$sec" "new commit" \
  "orch section still flags a genuine second return with a new commit"
assert_section_contains "$orch_skill" "$sec" "genuine second return" \
  "orch section still classifies a new/extra payload as a real second return"
assert_section_contains "$orch_skill" "$sec" "unrequested commits" \
  "orch section retains the original unrequested-commit violation rule"

# --- dev: the send_input MESSAGE is the durable return and the FINAL_ANSWER
#     echo is expected, not a separate return the agent should author.
assert_contains "$dev_skill" "send_input" \
  "dev SKILL names the Codex send_input return channel"
assert_contains "$dev_skill" "FINAL_ANSWER" \
  "dev SKILL names the FINAL_ANSWER echo"
assert_contains "$dev_skill" "durable return" \
  "dev SKILL states the send_input MESSAGE is the durable return"
assert_contains "$dev_skill" "not a separate return" \
  "dev SKILL states the FINAL_ANSWER echo is not a separate return"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
