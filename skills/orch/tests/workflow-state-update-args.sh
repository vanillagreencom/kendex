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
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

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

# --- the documented § 4 form, end to end from an artifact file --------------
# review-pr § 4 types only a path, an array name, and an index: the finding's
# text never enters a shell word, which is the only way a location holding an
# apostrophe survives (the harness rejects $(...) and multi-command blocks, so
# a shell variable cannot carry it either). The value here also holds a double
# quote and a newline.
ART_LOC="crates/core/src/fs.rs::write_all's \"atomic\" guard"
ART_DESC="line one of the finding
line two, with an apostrophe's worth of trouble and a \"quoted\" span"
ART="$TMP_ROOT/review-security.json"
jq -n --arg l "$ART_LOC" --arg d "$ART_DESC" \
  '{verdict: "action_required", blockers: [{location: $l, description: $d}], suggestions: []}' > "$ART"

sda="$TMP_ROOT/state-artifact"
"$WS" --state-dir "$sda" init KEN-2 --worktree "$REPO_ROOT" --branch ken-2 >/dev/null
"$WS" --state-dir "$sda" append KEN-2 fixed_items \
  "$(jq -n --arg l "$ART_LOC" --arg d "$ART_DESC" '{description: $d, location: $l, commit: "abc123f", source: "pr-review"}')" >/dev/null

"$WS" --state-dir "$sda" update KEN-2 --slurpfile art "$ART" --arg src pr-review \
  '$art[0].blockers[0] as $item | .fixed_items = ((.fixed_items // []) | map(select(.location != $item.location or .description != $item.description))) | .escalated_items = ((.escalated_items // []) + [{description: $item.description, location: $item.location, reason: "outstanding at the review cycle cap", outcome: "blocked", source: $src}])' >/dev/null \
  && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && ok "the documented artifact-bound write succeeds" \
  || bad "the documented artifact-bound write succeeds" "rc=$rc"

art_loc="$("$WS" --state-dir "$sda" get KEN-2 '.escalated_items[0].location')"
art_desc="$("$WS" --state-dir "$sda" get KEN-2 '.escalated_items[0].description')"
[[ "$art_loc" == "$ART_LOC" ]] && ok "the artifact location round-trips through the file binding" \
  || bad "the artifact location round-trips through the file binding" "got=$art_loc"
[[ "$art_desc" == "$ART_DESC" ]] && ok "a multi-line description round-trips through the file binding" \
  || bad "a multi-line description round-trips through the file binding" "got=$art_desc"

art_fixed="$("$WS" --state-dir "$sda" get KEN-2 '.fixed_items | length')"
[[ "$art_fixed" == "0" ]] && ok "the superseded entry is dropped by the artifact-bound write" \
  || bad "the superseded entry is dropped by the artifact-bound write" "len=$art_fixed"

err="$("$WS" --state-dir "$sda" update KEN-2 --slurpfile art "$TMP_ROOT/absent.json" '.cycles = 1' 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"no such file"* ]] \
  && ok "--slurpfile refuses a missing file" \
  || bad "--slurpfile refuses a missing file" "rc=$rc err=$err"

printf 'not json' > "$TMP_ROOT/bad.json"
err="$("$WS" --state-dir "$sda" update KEN-2 --slurpfile art "$TMP_ROOT/bad.json" '.cycles = 1' 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"exactly one JSON value"* ]] \
  && ok "--slurpfile refuses a file that is not one JSON value" \
  || bad "--slurpfile refuses a file that is not one JSON value" "rc=$rc err=$err"

# --- dev-fix § 2 step 6, the entry bound from its own file ------------------
# Both outcome writes clear the item from BOTH buckets before appending their
# own entry, so an item fixed then re-raised then blocked, or escalated then
# fixed, lands in one bucket once. The entry reaches jq through a file: the
# text below carries an apostrophe and a double quote, which an --argjson
# argument would not survive.
STEP6_DROP='$item[0] as $e | .fixed_items = ((.fixed_items // []) | map(select(.location != $e.location or .description != $e.description))) | .escalated_items = ((.escalated_items // []) | map(select(.location != $e.location or .description != $e.description)))'
STEP6_FIXED="$STEP6_DROP | .fixed_items += [\$e]"
STEP6_ESCALATED="$STEP6_DROP | .escalated_items += [\$e]"

sd6="$TMP_ROOT/state-step6"
ENTRY="$TMP_ROOT/state-item-KEN-5.json"
"$WS" --state-dir "$sd6" init KEN-5 --worktree "$REPO_ROOT" --branch ken-5 >/dev/null

# Round one fixes it.
jq -n --arg l "$LOC" --arg d "$DESC" '{description: $d, location: $l, commit: "abc123f", source: "pr-review"}' > "$ENTRY"
"$WS" --state-dir "$sd6" update KEN-5 --slurpfile item "$ENTRY" "$STEP6_FIXED" >/dev/null && rc=0 || rc=$?
[[ "$rc" -eq 0 ]] && ok "the fixed write succeeds with the entry bound from a file" \
  || bad "the fixed write succeeds with the entry bound from a file" "rc=$rc"

step6_desc="$("$WS" --state-dir "$sd6" get KEN-5 '.fixed_items[0].description')"
[[ "$step6_desc" == "$DESC" ]] && ok "a description holding a quote and an apostrophe round-trips" \
  || bad "a description holding a quote and an apostrophe round-trips" "got=$step6_desc"

# Round two re-raises the same defect and blocks it: the fixed entry goes.
jq -n --arg l "$LOC" --arg d "$DESC" '{description: $d, location: $l, reason: "could not fix", outcome: "blocked", source: "pr-review"}' > "$ENTRY"
"$WS" --state-dir "$sd6" update KEN-5 --slurpfile item "$ENTRY" "$STEP6_ESCALATED" >/dev/null
f_len="$("$WS" --state-dir "$sd6" get KEN-5 '.fixed_items | length')"
e_len="$("$WS" --state-dir "$sd6" get KEN-5 '.escalated_items | length')"
[[ "$f_len" == "0" ]] && [[ "$e_len" == "1" ]] \
  && ok "escalating a fixed item leaves it in one bucket" \
  || bad "escalating a fixed item leaves it in one bucket" "fixed=$f_len escalated=$e_len"

# Round three fixes the escalated item: the escalated entry goes. This is the
# direction review.md § 4 and a standalone fix round reach, neither of which
# excludes escalated items from the round.
jq -n --arg l "$LOC" --arg d "$DESC" '{description: $d, location: $l, commit: "def456a", source: "review"}' > "$ENTRY"
"$WS" --state-dir "$sd6" update KEN-5 --slurpfile item "$ENTRY" "$STEP6_FIXED" >/dev/null
f_len="$("$WS" --state-dir "$sd6" get KEN-5 '.fixed_items | length')"
e_len="$("$WS" --state-dir "$sd6" get KEN-5 '.escalated_items | length')"
f_sha="$("$WS" --state-dir "$sd6" get KEN-5 '.fixed_items[0].commit')"
[[ "$f_len" == "1" ]] && [[ "$e_len" == "0" ]] && [[ "$f_sha" == "def456a" ]] \
  && ok "fixing an escalated item leaves it in one bucket, against the live sha" \
  || bad "fixing an escalated item leaves it in one bucket, against the live sha" "fixed=$f_len escalated=$e_len sha=$f_sha"

# An unrelated entry in either bucket is untouched by any of it.
jq -n --arg l "$OTHER_LOC" '{description: "unrelated", location: $l, reason: "skipped", outcome: "skipped", source: "pr-review"}' > "$TMP_ROOT/other.json"
"$WS" --state-dir "$sd6" update KEN-5 --slurpfile item "$TMP_ROOT/other.json" "$STEP6_ESCALATED" >/dev/null
jq -n --arg l "$LOC" --arg d "$DESC" '{description: $d, location: $l, commit: "0badc0d", source: "review"}' > "$ENTRY"
"$WS" --state-dir "$sd6" update KEN-5 --slurpfile item "$ENTRY" "$STEP6_FIXED" >/dev/null
other_len="$("$WS" --state-dir "$sd6" get KEN-5 '.escalated_items | length')"
other_loc="$("$WS" --state-dir "$sd6" get KEN-5 '.escalated_items[0].location')"
[[ "$other_len" == "1" ]] && [[ "$other_loc" == "$OTHER_LOC" ]] \
  && ok "an unrelated entry survives a write for a different item" \
  || bad "an unrelated entry survives a write for a different item" "len=$other_len loc=$other_loc"

# The key is the recorded pair. A description the reviewer re-authored instead
# of copying leaves the stale entry standing, which is what the re-review
# prompts head off by telling it to copy location and description verbatim.
jq -n --arg l "$LOC" --arg d "$DESC (fix recorded in abc123f did not hold)" '{description: $d, location: $l, reason: "could not fix", outcome: "blocked", source: "pr-review"}' > "$ENTRY"
"$WS" --state-dir "$sd6" update KEN-5 --slurpfile item "$ENTRY" "$STEP6_ESCALATED" >/dev/null
stale="$("$WS" --state-dir "$sd6" get KEN-5 '.fixed_items | length')"
[[ "$stale" == "1" ]] \
  && ok "a re-authored description misses the key and strands the stale entry" \
  || bad "a re-authored description misses the key and strands the stale entry" "fixed=$stale"

# --argjson on the same entry: the shape the file replaces.
argjson_entry='{"description":"'"$DESC"'","location":"'"$LOC"'","commit":"abc123f","source":"pr-review"}'
"$WS" --state-dir "$sd6" update KEN-5 --argjson item "$argjson_entry" "$STEP6_FIXED" >/dev/null 2>&1 && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && ok "the same entry pasted as --argjson is refused as invalid JSON" \
  || bad "the same entry pasted as --argjson is refused as invalid JSON" "rc=$rc"

# --- --argjson binds parsed JSON, and refuses what is not JSON -------------
"$WS" --state-dir "$sd" update KEN-1 --argjson labels '["needs-review","skills"]' '.qa_labels = $labels' >/dev/null
labels="$("$WS" --state-dir "$sd" get KEN-1 '.qa_labels | join(",")')"
[[ "$labels" == "needs-review,skills" ]] && ok "--argjson binds parsed JSON" \
  || bad "--argjson binds parsed JSON" "labels=$labels"

before="$("$WS" --state-dir "$sd" get KEN-1 '.qa_labels | length')"
err="$("$WS" --state-dir "$sd" update KEN-1 --argjson labels 'not json' '.qa_labels = $labels' 2>&1 >/dev/null)" && rc=0 || rc=$?
after="$("$WS" --state-dir "$sd" get KEN-1 '.qa_labels | length')"
[[ "$rc" -ne 0 ]] && [[ "$err" == *"exactly one JSON value"* ]] && [[ "$before" == "$after" ]] \
  && ok "--argjson refuses a non-JSON value and writes nothing" \
  || bad "--argjson refuses a non-JSON value and writes nothing" "rc=$rc err=$err before=$before after=$after"

err="$("$WS" --state-dir "$sd" update KEN-1 --argjson pair '1 2' '.cycles = 0' 2>&1 >/dev/null)" && rc=0 || rc=$?
[[ "$rc" -ne 0 ]] && [[ "$err" == *"exactly one JSON value"* ]] \
  && ok "--argjson refuses a stream of several values" \
  || bad "--argjson refuses a stream of several values" "rc=$rc err=$err"

# false and null are JSON values like any other. Validating with `jq -e .`
# reads the parsed value's truthiness instead of the parse, so both come back
# as "not valid JSON" and an update the caller is entitled to make is refused.
"$WS" --state-dir "$sd" update KEN-1 '.skip_qa = true' >/dev/null
"$WS" --state-dir "$sd" update KEN-1 --argjson flag 'false' '.skip_qa = $flag' >/dev/null && rc=0 || rc=$?
flag_val="$("$WS" --state-dir "$sd" get KEN-1 '.skip_qa')"
flag_type="$("$WS" --state-dir "$sd" get KEN-1 '.skip_qa | type')"
[[ "$rc" -eq 0 ]] && [[ "$flag_val" == "false" ]] && [[ "$flag_type" == "boolean" ]] \
  && ok "--argjson binds the scalar false as a boolean" \
  || bad "--argjson binds the scalar false as a boolean" "rc=$rc val=$flag_val type=$flag_type"

"$WS" --state-dir "$sd" set KEN-1 pre_delegate_sha deadbeef >/dev/null
"$WS" --state-dir "$sd" update KEN-1 --argjson sha 'null' '.pre_delegate_sha = $sha' >/dev/null && rc=0 || rc=$?
sha_type="$("$WS" --state-dir "$sd" get KEN-1 '.pre_delegate_sha | type')"
[[ "$rc" -eq 0 ]] && [[ "$sha_type" == "null" ]] \
  && ok "--argjson binds the scalar null as JSON null" \
  || bad "--argjson binds the scalar null as JSON null" "rc=$rc type=$sha_type"

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

# The pre-fix validation: `jq -e .` reads the value, so false and null are
# refused. A copy of the script carrying it must reject both.
CTRL_SCRIPTS="$TMP_ROOT/scripts"
cp -R "$REPO_ROOT/skills/orch/scripts" "$CTRL_SCRIPTS"
sed "s/jq -s -e 'length == 1'/jq -e ./" "$WS" > "$CTRL_SCRIPTS/workflow-state"
chmod +x "$CTRL_SCRIPTS/workflow-state"
if cmp -s "$CTRL_SCRIPTS/workflow-state" "$WS"; then
  bad "truthiness control planted nothing — its sed program matched no text"
else
  sdt="$TMP_ROOT/state-truthiness"
  "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdt" init KEN-3 --worktree "$REPO_ROOT" --branch ken-3 >/dev/null
  refused=0
  for scalar in false null; do
    "$CTRL_SCRIPTS/workflow-state" --state-dir "$sdt" update KEN-3 --argjson v "$scalar" '.skip_qa = $v' >/dev/null 2>&1 \
      || refused=$((refused + 1))
  done
  [[ "$refused" -eq 2 ]] && ok "the -e form refuses both false and null, which this fix accepts" \
    || bad "the -e form refuses both false and null, which this fix accepts" "refused=$refused of 2"
fi

# The form review-pr documented before this change pasted the location into a
# single-quoted shell word. The apostrophe closes that word and the stray
# double quote leaves the command unterminated, so the shell never builds the
# call at all and no binding can help. Written to a file and run, exactly as an
# agent would have issued it.
sdp="$TMP_ROOT/state-pasted"
"$WS" --state-dir "$sdp" init KEN-4 --worktree "$REPO_ROOT" --branch ken-4 >/dev/null
printf "%s --state-dir %s update KEN-4 --arg loc '%s' '.cycles = 1'\n" \
  "$WS" "$sdp" "$ART_LOC" > "$TMP_ROOT/pasted.sh"
if bash "$TMP_ROOT/pasted.sh" >/dev/null 2>&1; then
  bad "the pasted-into-quotes form breaks on a location holding an apostrophe" "it parsed and ran"
else
  ok "the pasted-into-quotes form breaks on a location holding an apostrophe"
fi

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
