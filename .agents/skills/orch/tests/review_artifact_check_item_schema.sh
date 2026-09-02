#!/usr/bin/env bash
# What a rejected review item is TOLD, asserted against the real
# review-artifact-check. Split from review_artifact_check.sh, which asks
# whether an artifact is accepted; these cases ask what the rejection says
# back, because that text is relayed verbatim to the agent that must redo the
# work.
#
# kendex#885: four artifacts were rejected in one session by agents that
# followed the workflow text without opening the schema. Two reached for
# `priority: 5`; two used plausible-but-wrong field names (`detail`,
# `remediation`, `file`+`line`). Every case here drives the shipped script and
# reads the `detail` it returns.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/review-artifact-check"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_substr() {
  local haystack="$1" needle="$2" name="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected substring: %s\n        in:                 %s\n' "$name" "$needle" "$haystack"
  fi
}

echo "=== review-artifact-check: what a rejected item is told ==="

REQ_SPEC="every blockers[]/suggestions[] item requires: id, title, location (path plus symbol, no line numbers), description, recommendation, priority (integer 1-4), estimate (1-5); suggestions also category (fix|issue), and category:issue also impact (who hits this, on what real path)"

# category:issue items require a non-empty impact line; fix items do not.
impact_wt=$(mktemp -d); mkdir -p "$impact_wt/tmp"
impact_art="$impact_wt/tmp/review-reviewer-impact-20260101-000000.json"
printf '%s' '{"agent":"reviewer-impact","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"s","qa_metadata":{"review_performed":true},"blockers":[],"suggestions":[{"id":1,"title":"t","location":"l (sym)","description":"d","recommendation":"r","priority":3,"estimate":2,"category":"issue"}]}' > "$impact_art"
r=$("$CHECK" "$impact_wt" reviewer-impact 0 || true)
assert_eq "$(jq -r '.ok' <<<"$r")" "false" "category:issue without impact is rejected"
assert_substr "$(jq -r '.detail // ""' <<<"$r")" "impact" "the rejection names the missing impact field"
jq '.suggestions[0].impact = "operators running the nightly import hit it on every run"' "$impact_art" > "$impact_art.n" && mv "$impact_art.n" "$impact_art"
assert_eq "$("$CHECK" "$impact_wt" reviewer-impact 0 | jq -r '.ok')" "true" "category:issue with impact passes"
jq '.suggestions[0].category = "fix" | del(.suggestions[0].impact)' "$impact_art" > "$impact_art.n" && mv "$impact_art.n" "$impact_art"
assert_eq "$("$CHECK" "$impact_wt" reviewer-impact 0 | jq -r '.ok')" "true" "category:fix needs no impact"
rm -rf -- "${impact_wt:?}"

# The check exits 1 on a rejected artifact, which is the case under test here —
# swallow it so `set -e`/`pipefail` do not abort the suite on an expected failure.
detail_of() { "$CHECK" --file "$1" 2>/dev/null | jq -r '.detail // ""' || true; }

# priority: 5 — the "lower than the lowest" instinct.
p5="$TMP_ROOT/p5.json"
jq -n '{agent:"reviewer-safety",timestamp:"t",verdict:"pass",summary:"s",blockers:[],
  suggestions:[{id:1,title:"t",location:"a.rs (`f`)",description:"d",recommendation:"r",
  priority:5,estimate:2,category:"fix"}],qa_metadata:{safety:{}}}' > "$p5"
d="$(detail_of "$p5")"
assert_substr "$d" "suggestions[0]: missing/invalid priority(not 1..4)" \
  "priority 5 is still reported as out of range"
assert_substr "$d" "$REQ_SPEC" "the priority rejection states the 1-4 range and the full item shape"

# `detail` instead of `description`, with id/estimate/category omitted.
alias1="$TMP_ROOT/alias1.json"
jq -n '{agent:"reviewer-arch",timestamp:"t",verdict:"pass",summary:"s",blockers:[],
  suggestions:[{title:"t",location:"a.rs",detail:"d",recommendation:"r",priority:3}],
  qa_metadata:{arch_review:{}}}' > "$alias1"
d="$(detail_of "$alias1")"
assert_substr "$d" "suggestions[0]: missing/invalid id, description, estimate, category" \
  "a detail/description swap is reported by field name"
assert_substr "$d" "$REQ_SPEC" "the swap rejection names the correct field set"

# file+line instead of location, remediation instead of recommendation.
alias2="$TMP_ROOT/alias2.json"
jq -n '{agent:"reviewer-safety",timestamp:"t",verdict:"pass",summary:"s",blockers:[],
  suggestions:[{title:"t",file:"a.rs",line:12,description:"d",remediation:"r",priority:3}],
  qa_metadata:{safety:{}}}' > "$alias2"
d="$(detail_of "$alias2")"
assert_substr "$d" "suggestions[0]: missing/invalid id, location, recommendation, estimate, category" \
  "file/line and remediation are reported as the missing canonical fields"
assert_substr "$d" "no line numbers" "the rejection states that location carries no line numbers"

# Aliases are NOT accepted — one canonical spelling, taught rather than guessed.
assert_eq "$("$CHECK" --file "$alias1" 2>/dev/null | jq -r '.reason' || true)" "incomplete" \
  "an aliased field name is still rejected, not silently accepted"

# A well-formed item produces no detail at all.
good="$TMP_ROOT/good.json"
jq -n '{agent:"reviewer-safety",timestamp:"t",verdict:"pass",summary:"s",blockers:[],
  suggestions:[{id:1,title:"t",location:"a.rs (`f`)",description:"d",recommendation:"r",
  priority:4,estimate:2,category:"issue",
  impact:"anyone auditing unsafe blocks hits it on the next sweep"}],qa_metadata:{safety:{}}}' > "$good"
assert_eq "$("$CHECK" --file "$good" | jq -r '.reason')" "valid" "a schema-correct artifact is still valid"
assert_eq "$(detail_of "$good")" "" "a valid artifact carries no detail"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
