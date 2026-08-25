#!/usr/bin/env bash
# `workflow-state update <id> [--arg NAME VALUE]... [--argjson NAME JSON]... <expr>`
# hands values to jq out of band, so text the caller did not author reaches the
# filter as a literal string.
#
# review-pr § 4's capped-item write carries a finding's location and
# description into state. Splicing those into the jq expression breaks on an
# apostrophe or a quote — jq fails, nothing is written, and § 8 re-derives the
# live blocker as a decline, which is the defect KEN-518 fixed. The control at
# the end runs the interpolated form on the same text and shows it failing.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

echo "=== workflow-state update --arg/--argjson ==="

# A location and a description in the shape review findings actually take: an
# apostrophe, a double quote, and a backslash.
LOC="crates/core/src/fs.rs::write_all's guard"
DESC='the writer'"'"'s "atomic" rename can lose data \ on EXDEV'
OTHER_LOC='crates/core/src/registry.rs'

sd="$TMP_ROOT/state"
"$WS" --state-dir "$sd" init KEN-1 --worktree "$REPO_ROOT" --branch ken-1 >/dev/null
"$WS" --state-dir "$sd" append KEN-1 fixed_items \
  "$(jq -n --arg l "$LOC" --arg d "$DESC" '{description: $d, location: $l, commit: "abc123f", source: "pr-review"}')" >/dev/null
"$WS" --state-dir "$sd" append KEN-1 fixed_items \
  "$(jq -n --arg l "$OTHER_LOC" '{description: "unrelated", location: $l, commit: "def456a", source: "pr-review"}')" >/dev/null

# --- the § 4 capped-item write, verbatim in shape --------------------------
CAP_FILTER='.fixed_items = ((.fixed_items // []) | map(select(.location != $loc or .description != $desc))) | .escalated_items = ((.escalated_items // []) + [{description: $desc, location: $loc, reason: "outstanding at the review cycle cap", outcome: "blocked", source: $src}])'

"$WS" --state-dir "$sd" update KEN-1 --arg loc "$LOC" --arg desc "$DESC" --arg src pr-review "$CAP_FILTER" >/dev/null \
  && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && ok "the capped-item write succeeds on text with an apostrophe, a quote, and a backslash" \
  || bad "the capped-item write succeeds on text with an apostrophe, a quote, and a backslash" "rc=$rc"

got_desc="$("$WS" --state-dir "$sd" get KEN-1 '.escalated_items[0].description')"
[[ "$got_desc" == "$DESC" ]] && ok "the description round-trips byte for byte" \
  || bad "the description round-trips byte for byte" "got=$got_desc want=$DESC"

got_loc="$("$WS" --state-dir "$sd" get KEN-1 '.escalated_items[0].location')"
[[ "$got_loc" == "$LOC" ]] && ok "the location round-trips byte for byte" \
  || bad "the location round-trips byte for byte" "got=$got_loc want=$LOC"

got_outcome="$("$WS" --state-dir "$sd" get KEN-1 '.escalated_items[0].outcome')"
[[ "$got_outcome" == "blocked" ]] && ok "the entry carries outcome blocked" \
  || bad "the entry carries outcome blocked" "got=$got_outcome"

# The superseded entry goes, and only it.
remaining="$("$WS" --state-dir "$sd" get KEN-1 '.fixed_items | length')"
survivor="$("$WS" --state-dir "$sd" get KEN-1 '.fixed_items[0].location')"
[[ "$remaining" == "1" ]] && [[ "$survivor" == "$OTHER_LOC" ]] \
  && ok "the matching fixed_items entry is dropped and the unrelated one survives" \
  || bad "the matching fixed_items entry is dropped and the unrelated one survives" "len=$remaining first=$survivor"

# --- --argjson binds parsed JSON, and refuses what is not JSON -------------
"$WS" --state-dir "$sd" update KEN-1 --argjson labels '["needs-review","skills"]' '.qa_labels = $labels' >/dev/null
labels="$("$WS" --state-dir "$sd" get KEN-1 '.qa_labels | join(",")')"
[[ "$labels" == "needs-review,skills" ]] && ok "--argjson binds parsed JSON" \
  || bad "--argjson binds parsed JSON" "labels=$labels"

before="$("$WS" --state-dir "$sd" get KEN-1 '.qa_labels | length')"
err="$("$WS" --state-dir "$sd" update KEN-1 --argjson labels 'not json' '.qa_labels = $labels' 2>&1 >/dev/null)" && rc=0 || rc=$?
after="$("$WS" --state-dir "$sd" get KEN-1 '.qa_labels | length')"
[[ "$rc" -ne 0 ]] && [[ "$err" == *"not valid JSON"* ]] && [[ "$before" == "$after" ]] \
  && ok "--argjson refuses a non-JSON value and writes nothing" \
  || bad "--argjson refuses a non-JSON value and writes nothing" "rc=$rc err=$err before=$before after=$after"

# --- argument-shape refusals -----------------------------------------------
err="$("$WS" --state-dir "$sd" update KEN-1 --arg loc 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"needs a NAME and a VALUE"* ]] \
  && ok "--arg without a VALUE is refused" \
  || bad "--arg without a VALUE is refused" "rc=$rc err=$err"

err="$("$WS" --state-dir "$sd" update KEN-1 '.cycles = 1' '.cycles = 2' 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"exactly one jq expression"* ]] \
  && ok "two jq expressions are refused" \
  || bad "two jq expressions are refused" "rc=$rc err=$err"

err="$("$WS" --state-dir "$sd" update KEN-1 --arg loc "$LOC" 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"needs a jq expression"* ]] \
  && ok "bindings with no expression are refused" \
  || bad "bindings with no expression are refused" "rc=$rc err=$err"

# A bare expression with no bindings still works — the old call shape.
"$WS" --state-dir "$sd" update KEN-1 '.cycles = 4' >/dev/null
cycles="$("$WS" --state-dir "$sd" get KEN-1 .cycles)"
[[ "$cycles" == "4" ]] && ok "an update with no bindings behaves as before" \
  || bad "an update with no bindings behaves as before" "cycles=$cycles"

# --- must-fail control: the interpolated form on the same input -------------
echo
echo "--- planted control ---"

sd2="$TMP_ROOT/state-interpolated"
"$WS" --state-dir "$sd2" init KEN-2 --worktree "$REPO_ROOT" --branch ken-2 >/dev/null
err="$("$WS" --state-dir "$sd2" update KEN-2 \
  ".escalated_items = ((.escalated_items // []) + [{description: \"$DESC\", location: \"$LOC\", outcome: \"blocked\"}])" 2>&1 >/dev/null)" && rc=0 || rc=$?
recorded="$("$WS" --state-dir "$sd2" get KEN-2 '.escalated_items | length')"
[[ "$rc" -ne 0 ]] && [[ "$err" == *"jq expression failed"* ]] && [[ "$recorded" == "0" ]] \
  && ok "the interpolated form fails on this text and records nothing" \
  || bad "the interpolated form fails on this text and records nothing" "rc=$rc recorded=$recorded err=$err"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
