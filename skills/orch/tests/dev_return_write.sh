#!/usr/bin/env bash
# Regression tests for dev-return-write: the deterministic writer for a dev
# agent's round-scoped completion artifact
# ([WORKTREE]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json). Running the writer instead
# of hand-authoring the JSON makes the receipt well-formed and complete by
# construction (vstack#776) — every artifact it emits must round-trip through
# dev-artifact-check (round mode) as valid, and every bad invocation must exit 2.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
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

# Assert an invocation fails validation with exit code 2.
assert_exit2() {
  local name="$1"; shift
  set +e
  "$WRITE" "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  assert_eq "$rc" "2" "$name"
}

echo "=== dev-return-write ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree"
RID="1750000000-99"

# --- valid implement (single): no --item → items: [] ---
out="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-776 --round-id "$RID" \
  --branch issue-776 --commit abc123f --validate pass --qa-label needs-review)"
assert_eq "$out" "$worktree/tmp/dev-return-issue-776-$RID.json" "implement single prints the round-scoped artifact path"
assert_eq "$([[ -f "$out" ]] && echo yes)" "yes" "implement single wrote the file"
assert_eq "$(jq -r '.schema_version' "$out")" "1" "implement single .schema_version is 1"
assert_eq "$(jq -r '.schema_version | type' "$out")" "number" "implement single .schema_version is a JSON number"
assert_eq "$(jq -r '.round_id' "$out")" "$RID" "implement single .round_id matches --round-id"
assert_eq "$(jq -r '.kind' "$out")" "implement" "implement single .kind"
assert_eq "$(jq -r '.issue' "$out")" "issue-776" "implement single .issue"
assert_eq "$(jq -r '.commit' "$out")" "abc123f" "implement single .commit"
assert_eq "$(jq -r '.validate' "$out")" "pass" "implement single .validate"
assert_eq "$(jq -c '.qa_labels' "$out")" '["needs-review"]' "implement single .qa_labels"
assert_eq "$(jq -r '.summary_posted' "$out")" "true" "implement single .summary_posted true"
assert_eq "$(jq -r '.summary' "$out")" "null" "implement single .summary null without --summary-file"
assert_eq "$(jq -r '.bundled' "$out")" "false" "implement single .bundled false"
assert_eq "$(jq -c '.items' "$out")" "[]" "implement single .items is []"
# round-trips through dev-artifact-check round mode as valid
assert_eq "$("$CHECK" --worktree "$worktree" --issue issue-776 --round-id "$RID" | jq -r '.reason')" "valid" \
  "implement single round-trips through dev-artifact-check round mode as valid"

# --- valid implement: no qa labels → [] ; --no-summary → false ; FAILING validate ---
out="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-100 --round-id 5-5 \
  --branch b --commit c --validate "FAILING: lint,build" --no-summary)"
assert_eq "$(jq -c '.qa_labels' "$out")" "[]" "implement no labels → qa_labels []"
assert_eq "$(jq -r '.summary_posted' "$out")" "false" "--no-summary sets summary_posted false"
assert_eq "$(jq -r '.validate' "$out")" "FAILING: lint,build" "FAILING validate accepted verbatim"
assert_eq "$("$CHECK" --file "$out" | jq -r '.reason')" "valid" "implement no-summary round-trips as valid"

# --- --summary-file embeds content for GitHub/ad-hoc recovery ---
printf '## Completion Summary\n- did the thing\n' > "$worktree/summary.md"
out="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-gh --round-id 6-6 \
  --branch b --commit c --validate pass --no-summary --summary-file "$worktree/summary.md")"
assert_eq "$(jq -r '.summary' "$out" | head -1)" "## Completion Summary" "--summary-file embeds the summary content"
assert_eq "$(jq -r '.summary_posted' "$out")" "false" "--summary-file keeps summary_posted false (nothing posted to a tracker)"

# --- valid fix: items present ---
out="$("$WRITE" --worktree "$worktree" --kind fix --issue issue-776 --round-id 7-7 \
  --branch issue-776 --commit def456a --validate pass \
  --item 1 Applied "fixed nil deref" --item 2 Skipped "contradicts D010")"
assert_eq "$(jq -r '.kind' "$out")" "fix" "fix .kind"
assert_eq "$(jq -r '.items | length' "$out")" "2" "fix has 2 items"
assert_eq "$(jq -r '.items[0].n | type' "$out")" "number" "fix item[0].n is a JSON number"
assert_eq "$(jq -r '.items[1].decision' "$out")" "Skipped" "fix item[1].decision"
assert_eq "$("$CHECK" --worktree "$worktree" --issue issue-776 --round-id 7-7 --expect-items 1,2 | jq -r '.reason')" "valid" \
  "fix round-trips through round mode with matching --expect-items"

# --- valid bundled implement: --bundled + items ---
out="$("$WRITE" --worktree "$worktree" --kind implement --issue PROJ-100 --round-id 8-8 \
  --branch feat/proj-100 --commit aaa111 --validate pass --bundled \
  --item 1 Applied "sub A done" --item 2 Applied "sub B done" \
  --qa-label needs-safety-audit --qa-label needs-review)"
assert_eq "$(jq -r '.bundled' "$out")" "true" "bundled implement .bundled true"
assert_eq "$(jq -r '.items | length' "$out")" "2" "bundled implement has 2 items"
assert_eq "$(jq -c '.qa_labels' "$out")" '["needs-safety-audit","needs-review"]' "bundled implement aggregated qa_labels"
assert_eq "$("$CHECK" --worktree "$worktree" --issue PROJ-100 --round-id 8-8 | jq -r '.reason')" "valid" \
  "bundled implement round-trips as valid"

# --- Blocked decision accepted ---
out="$("$WRITE" --worktree "$worktree" --kind fix --issue issue-b --round-id 9-9 \
  --branch b --commit c --validate pass --item 3 Blocked "needs API design")"
assert_eq "$(jq -r '.items[0].decision' "$out")" "Blocked" "fix item Blocked decision accepted"

# --- vstack#952: analysis kind — a read-only round has a truthful spelling ---
# The artifact must be UNABLE to assert a validation outcome that did not occur:
# the commit/validate/validate_note keys are omitted entirely, and the
# recommendation (the round's deliverable) is required via --summary-file.
printf '## Recommendation\nClose with reasoning: premise invalidated by merge X.\n' > "$worktree/analysis.md"
out="$("$WRITE" --worktree "$worktree" --kind analysis --issue issue-952 --round-id 10-10 \
  --branch issue-952 --summary-file "$worktree/analysis.md" --no-summary)"
assert_eq "$out" "$worktree/tmp/dev-return-issue-952-10-10.json" "analysis prints the round-scoped artifact path"
assert_eq "$(jq -r '.kind' "$out")" "analysis" "analysis .kind"
assert_eq "$(jq -r '.round_id' "$out")" "10-10" "analysis .round_id matches --round-id"
assert_eq "$(jq -r 'has("commit")' "$out")" "false" "analysis artifact carries NO commit key"
assert_eq "$(jq -r 'has("validate")' "$out")" "false" "analysis artifact carries NO validate key"
assert_eq "$(jq -r 'has("validate_note")' "$out")" "false" "analysis artifact carries NO validate_note key"
assert_eq "$(jq -r '.summary' "$out" | head -1)" "## Recommendation" "analysis embeds the recommendation content"
assert_eq "$(jq -c '.items' "$out")" "[]" "analysis .items is []"
assert_eq "$(jq -r '.bundled' "$out")" "false" "analysis .bundled false"
assert_eq "$("$CHECK" --worktree "$worktree" --issue issue-952 --round-id 10-10 | jq -r '.reason')" "valid" \
  "analysis round-trips through dev-artifact-check round mode as valid"

# --- vstack#1236: inline --summary — an analysis round must not depend on a
# file write the harness can refuse. Exactly one of --summary/--summary-file.
out="$("$WRITE" --worktree "$worktree" --kind analysis --issue issue-1236 --round-id 11-11 \
  --branch issue-1236 --summary "Recommend: close with reasoning — premise invalidated by merge X." --no-summary)"
assert_eq "$(jq -r '.summary' "$out")" "Recommend: close with reasoning — premise invalidated by merge X." \
  "analysis inline --summary embeds the recommendation text"
assert_eq "$(jq -r 'has("commit")' "$out")" "false" "inline-summary analysis still carries NO commit key"
assert_eq "$("$CHECK" --worktree "$worktree" --issue issue-1236 --round-id 11-11 | jq -r '.reason')" "valid" \
  "inline-summary analysis round-trips through dev-artifact-check round mode as valid"

# Inline --summary is a general alternative summary source, not analysis-only.
out="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-1236i --round-id 12-12 \
  --branch b --commit c --validate pass --no-summary --summary "inline completion summary")"
assert_eq "$(jq -r '.summary' "$out")" "inline completion summary" "implement inline --summary embeds the summary text"
assert_eq "$("$CHECK" --file "$out" | jq -r '.reason')" "valid" "implement inline-summary round-trips as valid"

# --- atomic write: no leftover temp files in tmp/ after a successful write ---
tmp_leftovers="$(find "$worktree/tmp" -maxdepth 1 -name '.dev-return-*' | wc -l | tr -d ' ')"
assert_eq "$tmp_leftovers" "0" "atomic write leaves no temp files behind"

# --- validation / exit-2 paths ---
assert_exit2 "bad --kind exits 2" \
  --worktree "$worktree" --kind review --issue i --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "missing --round-id exits 2" \
  --worktree "$worktree" --kind implement --issue i --branch b --commit c --validate pass
assert_exit2 "missing --issue (required arg) exits 2" \
  --worktree "$worktree" --kind implement --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "value flag with no value at end exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate
assert_exit2 "missing --worktree exits 2" \
  --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "nonexistent --worktree dir exits 2" \
  --worktree "$TMP_ROOT/nope" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "bad --validate exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate weird
assert_exit2 "path-unsafe --issue (slash) exits 2" \
  --worktree "$worktree" --kind implement --issue "a/b" --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "path-traversal --issue (..) exits 2" \
  --worktree "$worktree" --kind implement --issue ".." --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "path-unsafe --round-id (slash) exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "a/../b" --branch b --commit c --validate pass
assert_exit2 "path-traversal --round-id (..) exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id ".." --branch b --commit c --validate pass
assert_exit2 "missing --summary-file exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass --summary-file "$TMP_ROOT/nope.md"
assert_exit2 "bad --item DECISION exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass --item 1 Fixed "x"
assert_exit2 "empty --item REASONING exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass --item 1 Applied ""
assert_exit2 "non-numeric --item N exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass --item x Applied "x"
assert_exit2 "--item with too few args exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass --item 1 Applied
assert_exit2 "fix with no --item exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "bundled implement with no --item exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass --bundled
assert_exit2 "unknown argument exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass --frobnicate

# vstack#952: an analysis round has no commit and runs no validation — supplying
# either (or an item/bundle claim) must be a loud error, never silently ignored.
assert_exit2 "analysis with --commit exits 2" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary-file "$worktree/analysis.md" --commit abc
assert_exit2 "analysis with --validate exits 2" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary-file "$worktree/analysis.md" --validate pass
assert_exit2 "analysis with --validate-note exits 2" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary-file "$worktree/analysis.md" --validate-note "caveat"
assert_exit2 "analysis with --item exits 2" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary-file "$worktree/analysis.md" --item 1 Applied "x"
assert_exit2 "analysis with --bundled exits 2" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary-file "$worktree/analysis.md" --bundled
assert_exit2 "analysis without --summary or --summary-file exits 2 (the recommendation is the deliverable)" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b

# vstack#1236: one summary source only — both flags at once must be a loud
# error (a silent precedence rule would quietly misrecord the deliverable).
assert_exit2 "analysis with both --summary and --summary-file exits 2" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b \
  --summary "inline" --summary-file "$worktree/analysis.md"
assert_exit2 "implement with both --summary and --summary-file exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass \
  --summary "inline" --summary-file "$worktree/summary.md"
# Exclusion and validation key on flag PRESENCE, not value: an explicitly
# empty --summary-file (an unset path variable) is a supplied second source /
# a config error, never a silent no-op.
assert_exit2 "--summary plus empty --summary-file value still exits 2 (presence, not content)" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b \
  --summary "inline" --summary-file ""
assert_exit2 "explicitly empty --summary-file alone exits 2 for analysis" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary-file ""
assert_exit2 "explicitly empty --summary-file alone exits 2 for implement" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass \
  --summary-file ""
assert_exit2 "whitespace-only --summary exits 2 (an empty deliverable is not a record)" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary "   "
printf '  \n\t\n' > "$worktree/blank.md"
assert_exit2 "whitespace-only --summary-file content exits 2 for analysis" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary-file "$worktree/blank.md"
assert_exit2 "--summary with no value exits 2" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary

# Option-token swallow: with an argc-only check, a value flag whose value was
# omitted mid-line consumes the NEXT FLAG as its value — "--summary
# --no-summary" would record the literal string "--no-summary" as the round's
# deliverable in a well-formed, accepted artifact. Every value-taking flag
# shares the guard.
assert_exit2 "--summary followed by another flag exits 2 (option token is not a value)" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary --no-summary
assert_exit2 "--summary-file followed by another flag exits 2" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary-file --no-summary
assert_exit2 "--branch followed by another flag exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch --commit c --validate pass
assert_exit2 "--validate-note followed by another flag exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass \
  --validate-note --qa-label needs-review
assert_exit2 "--item REASONING as option token exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass \
  --item 1 Applied --bundled
# Control: ordinary leading-dash prose (a Markdown bullet) is still a value.
out="$("$WRITE" --worktree "$worktree" --kind analysis --issue issue-dash --round-id 13-13 \
  --branch b --summary "- close as duplicate of the merged fix" --no-summary)"
assert_eq "$(jq -r '.summary' "$out")" "- close as duplicate of the merged fix" \
  "a leading single-dash summary value is accepted (only '--' tokens are rejected)"
assert_exit2 "analysis with empty --commit value still exits 2 (presence, not content)" \
  --worktree "$worktree" --kind analysis --issue i --round-id "$RID" --branch b --summary-file "$worktree/analysis.md" --commit ""

# A rejected analysis invocation leaves no artifact behind.
set +e
"$WRITE" --worktree "$worktree" --kind analysis --issue issue-anoclaim --round-id "$RID" \
  --branch b --summary-file "$worktree/analysis.md" --validate pass >/dev/null 2>&1
set -e
assert_eq "$([[ -f "$worktree/tmp/dev-return-issue-anoclaim-$RID.json" ]] && echo yes || echo no)" "no" \
  "rejected analysis (--validate supplied) writes no artifact file"

# A rejected invocation must not leave a partial artifact at the target path.
set +e
"$WRITE" --worktree "$worktree" --kind fix --issue issue-noitems --round-id "$RID" \
  --branch b --commit c --validate pass >/dev/null 2>&1
set -e
assert_eq "$([[ -f "$worktree/tmp/dev-return-issue-noitems-$RID.json" ]] && echo yes || echo no)" "no" \
  "rejected fix (no items) writes no artifact file"

# --- vstack#884: a qualified validation result is recordable ---
# `validate` stays a closed enumeration (orch gates on it); the note is the
# additive channel for a caveat the enumeration cannot express. Without it a
# pass-only-on-re-run is recorded as a bare "pass" and the caveat is lost from
# the artifact orch treats as authoritative.
NOTE="80/80 on re-run; first run flaked on Rust Tests (release), same git_diff_hash"
noted="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-note --round-id "$RID" \
  --branch b --commit c --validate pass --validate-note "$NOTE")"
assert_eq "$(jq -r '.validate' "$noted")" "pass" "--validate-note leaves validate strictly enumerated"
assert_eq "$(jq -r '.validate_note' "$noted")" "$NOTE" "--validate-note is recorded verbatim"

# A FAILING run can carry a caveat too — the note is not pass-only.
failnote="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-failnote --round-id "$RID" \
  --branch b --commit c --validate "FAILING: lint" --validate-note "lint fails only under --release")"
assert_eq "$(jq -r '.validate' "$failnote")" "FAILING: lint" "a note does not relax a FAILING verdict"
assert_eq "$(jq -r '.validate_note' "$failnote")" "lint fails only under --release" "FAILING artifacts can carry a note"

# Omitted: the field is present and null, so consumers never have to distinguish
# "absent key" from "no note".
plain="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-nonote --round-id "$RID" \
  --branch b --commit c --validate pass)"
assert_eq "$(jq -r 'has("validate_note")' "$plain")" "true" "validate_note is always present"
assert_eq "$(jq -r '.validate_note' "$plain")" "null" "an omitted note is null, not empty string"

# An empty or whitespace-only note looks like a recorded caveat while carrying
# nothing, so it is refused rather than stored.
assert_exit2 "whitespace-only --validate-note exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c \
  --validate pass --validate-note "   "
assert_exit2 "--validate-note with no value exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c \
  --validate pass --validate-note

# The note must never become a way to smuggle a third verdict past the gate.
assert_exit2 "--validate still rejects an out-of-domain verdict even with a note" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c \
  --validate pass_with_notes --validate-note "explained"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
