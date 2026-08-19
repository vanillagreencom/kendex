#!/usr/bin/env bash
# Does the WORKFLOW PROSE wire the check's contract? Split from
# review_artifact_check.sh, which asks what the script does; these assertions
# ask whether the three call sites and the reviewer-facing schema say what the
# script actually enforces. A contract nobody relays is a contract nobody obeys.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/review-artifact-check"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

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

assert_file_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
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

assert_file_not_contains() {
  local file="$1" pattern="$2" name="$3"
  if grep -Fq -- "$pattern" "$file"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected pattern: %s\n        file: %s\n' "$name" "$pattern" "$file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

# expect_valid <artifact-path> <desc> — accepting-direction assertion that
# survives a mutant. A bare `out="$("$CHECK" ...)"` aborts the whole run under
# set -e the moment a guard starts over-rejecting, which truncates the suite
# instead of naming what broke; the accepting direction is exactly where that
# matters, because it is what pins WHICH number a guard reads.
expect_valid() {
  local path="$1" desc="$2" out rc=0
  set +e
  out="$("$CHECK" --file "$path")"
  rc=$?
  set -e
  assert_eq "$rc" "0" "$desc (exits 0)"
  assert_eq "$(jq -r '.reason' <<<"$out")" "valid" "$desc"
}

# expect_glob_valid <worktree> <agent> <boundary> <expected-path> <desc>
expect_glob_valid() {
  local wt="$1" ag="$2" bound="$3" want="$4" desc="$5" out rc=0
  set +e
  out="$("$CHECK" "$wt" "$ag" "$bound")"
  rc=$?
  set -e
  assert_eq "$rc" "0" "$desc (exits 0)"
  assert_eq "$(jq -r '.path' <<<"$out")" "$want" "$desc"
}

echo "=== review-artifact-check: workflow wiring ==="

# --- valid_undermeasured is named at every site that consumes the check ---
# Making the undermeasured state machine-readable only helps where a caller
# reads it. All three call sites take a result that may carry the reason; a
# site that names only ok/true records a review whose own instrument produced
# nothing as an ordinary one.
review_pr_sites="$REPO_ROOT/skills/orch/workflows/review-pr.md"
submit_pr="$REPO_ROOT/skills/orch/workflows/submit-pr.md"
# valid_undermeasured is an ok=TRUE reason, so naming it under a failure branch
# documents a state the reader never reaches. Assert the CONTEXT, not the token:
# every line that mentions the reason must also carry the acceptance condition.
# The weaker "the file contains the word" passed while submit-pr.md § 1 had the
# clause hanging off its `ok == false` sentence.
# wc, not grep -c: grep exits 1 on a zero count, which would make the "no bad
# lines" case indistinguishable from a broken command.
undermeasured_mentions() { grep 'valid_undermeasured' "$1" | wc -l | tr -d ' '; }
undermeasured_offbranch() { grep 'valid_undermeasured' "$1" | grep -v 'ok == true' | wc -l | tr -d ' '; }
assert_eq "$(undermeasured_offbranch "$review_pr_sites")" "0" "review-pr.md: every valid_undermeasured mention sits in an ok == true branch"
assert_eq "$(undermeasured_offbranch "$submit_pr")" "0" "submit-pr.md: every valid_undermeasured mention sits in an ok == true branch"
assert_eq "$(undermeasured_mentions "$review_pr_sites")" "2" "review-pr.md names it at BOTH its call sites (§ 2.5 external, § 3.1 completion)"
assert_eq "$(undermeasured_mentions "$submit_pr")" "1" "submit-pr.md § 1 names the undermeasured reason once"
assert_file_contains "$review_pr_sites" "measurement_failed" "review-pr.md relays the declaration string"
assert_file_contains "$submit_pr" "measurement_failed" "submit-pr.md relays the declaration string"

# measurement_suppressed exists so a suppression is not invisible, which makes a
# suppression invisible to its readers the one failure it cannot have. Pinned
# the same way as its sibling: a count per file, and the off-branch check — an
# ok=TRUE field named under a failure branch is documented where the reader
# never arrives, which is exactly what submit-pr.md § 1 did before.
suppressed_mentions() { grep 'measurement_suppressed' "$1" | wc -l | tr -d ' '; }
suppressed_offbranch() { grep 'measurement_suppressed' "$1" | grep -v 'ok == true' | wc -l | tr -d ' '; }
assert_eq "$(suppressed_offbranch "$review_pr_sites")" "0" "review-pr.md: every measurement_suppressed mention sits in an ok == true branch"
assert_eq "$(suppressed_offbranch "$submit_pr")" "0" "submit-pr.md: every measurement_suppressed mention sits in an ok == true branch"
assert_eq "$(suppressed_mentions "$review_pr_sites")" "2" "review-pr.md relays the suppression record at BOTH its call sites"
assert_eq "$(suppressed_mentions "$submit_pr")" "1" "submit-pr.md § 1 relays the suppression record"

# --- review-pr.md wires the deterministic acceptance ---
review_pr="$REPO_ROOT/skills/orch/workflows/review-pr.md"
assert_file_contains "$review_pr" ".agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT]" "review-pr acceptance runs review-artifact-check"
assert_file_not_contains "$review_pr" 'A return message arrives with `Verdict:` and `File:` lines, *or*' "review-pr no longer accepts return-message-only completion"
assert_file_contains "$review_pr" "never sufficient" "review-pr states a return message alone cannot complete a reviewer"
assert_file_contains "$review_pr" "exactly one" "review-pr limits incomplete returns to one re-delegation"
assert_file_contains "$review_pr" "using your harness file-write tool" "review-pr re-delegation instructs harness file-write tool"
assert_file_contains "$review_pr" 'review-artifact-check --file "$EXTERNAL_OUTPUT"' "review-pr validates external output via --file mode"
assert_file_not_contains "$review_pr" "if jq -e '.verdict'" "review-pr no longer prescribes inline if/redirection for external verdict check"
assert_file_contains "$review_pr" 'review-artifact-check --file "$EXTERNAL_OUTPUT" [REVIEW_DELEGATED_AT_FROM_PREVIOUS_COMMAND]' "review-pr passes review_delegated_at as the --file freshness boundary"
# The reason vocabulary belongs to the script (behaviourally covered above);
# the workflow's obligation is to surface whatever reason it reports, with the
# detail field that pinpoints the offending item, instead of silently passing.
assert_file_contains "$review_pr" 'report the `reason` (and `detail` when present)' "review-pr surfaces the rejection reason and detail"

# --- submit-pr.md wires the --file freshness boundary for the local review ---
submit_pr="$REPO_ROOT/skills/orch/workflows/submit-pr.md"
assert_file_contains "$submit_pr" 'review-artifact-check --file "$LOCAL_OUTPUT" [LOCAL_STARTED_AT]' "submit-pr passes a delegated-at boundary to the --file freshness check"
assert_file_contains "$submit_pr" "git-context timestamp epoch" "submit-pr captures an epoch boundary before running the local review"
assert_file_contains "$submit_pr" 'report the `reason`' "submit-pr surfaces the rejection reason"
assert_file_contains "$submit_pr" "none of those outcomes is a pass" "submit-pr states a rejected local review is not a pass"

# --- vstack#885: the rejection has to teach the schema, not just flag it ---
# Four artifacts were rejected in one session by agents that followed the
# workflow text without opening the schema file. Two reached for `priority: 5`;
# two used plausible-but-wrong field names (`detail`, `remediation`, `file`+
# `line`). The rejection is relayed verbatim to the agent that must redo the
# work, so it names the whole expected item shape.
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
rm -rf "$impact_wt"

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

# --- The authoring path must carry the requirements, not just the recovery path ---
# vstack#885's defect was an authoring path with strictly less information than
# the rejection it would then receive. The current answer is mechanical, not
# duplicated prose: the schema file is the single field authority, and every
# review workflow + the reviewer SKILL require a pre-return self-check with this
# same validator, so a rejection can never first surface at the orchestrator.
reviewer_skill="$REPO_ROOT/skills/reviewer/SKILL.md"
schema_doc="$REPO_ROOT/skills/reviewer/schemas/review-finding.md"
assert_file_contains "$reviewer_skill" "Output Contract" "reviewer SKILL has an output-contract section"
assert_file_contains "$reviewer_skill" "review-artifact-check" "reviewer SKILL mandates the pre-return self-check"
assert_file_contains "$schema_doc" "1-4" "schema states the priority range"
assert_file_contains "$schema_doc" "no P5" "schema says there is no P5"
assert_file_contains "$schema_doc" "no line numbers" "schema states the location shape"
assert_file_contains "$schema_doc" "recommendation" "schema names the recommendation field"
for wf in review codebase-review qa-review; do
  wf_file="$REPO_ROOT/skills/reviewer/workflows/$wf.md"
  assert_file_contains "$wf_file" "schemas/review-finding.md" "$wf workflow points at the schema authority"
  assert_file_contains "$wf_file" "review-artifact-check" "$wf workflow carries the pre-return self-check"
done

review_pr_recovery="$REPO_ROOT/skills/orch/workflows/review-pr.md"
# The required-field list lives in the schema, so the re-delegation points the
# reviewer there rather than restating a field list that would drift from it.
assert_file_contains "$review_pr_recovery" "every required field of \`review-finding.md\`" \
  "review-pr's re-delegation routes the reviewer to the schema's required fields"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
