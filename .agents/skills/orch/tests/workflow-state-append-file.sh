#!/usr/bin/env bash
# `workflow-state append-file <id> <path> <file>`: reviewer text never crosses
# argv. A cause reaches the state byte for byte through a file, the array is
# created where the field is absent, anything that is not exactly one JSON
# value is refused with the record untouched, and no workflow spells the
# append by hand. On fleet_log the command also owns the record's time: it
# stamps an absent `at`, keeps a past one, and refuses a future one.
# Split from workflow-state-cycle-cap.sh.

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

echo
echo "--- workflow-state append-file ---"

cd_sd="$TMP_ROOT/append-state"
"$WS" --state-dir "$cd_sd" init KEN-CAP --worktree "$REPO_ROOT" --branch ken-cap >/dev/null

cause="$TMP_ROOT/cause.json"
# A cause carrying every character that ends a shell word early. It reaches
# the state byte for byte, or the command was not the file-bound one.
python3 - "$cause" <<'PYW'
import json, sys
json.dump({"cause": "fs.rs::write_all's guard \"quoted\" $(whoami) `id` | ;", "commit": "abc1234"},
          open(sys.argv[1], "w"))
PYW
"$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$cause" >/dev/null
"$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$cause" >/dev/null
# The type is read beside the length: jq counts an object's keys under the
# same operator, and the fixture object has two, so a bare assignment would
# read as two appended entries.
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes | "\(type):\(length)"')"
[[ "$got" == "array:2" ]] && ok "append-file appends rather than replacing" \
  || bad "append-file appends rather than replacing" "got=$got"
want="$(jq -r .cause "$cause")"
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes[0].cause')"
[[ "$got" == "$want" ]] && ok "the cause reaches the state verbatim, shell metacharacters and all" \
  || bad "the cause reaches the state verbatim, shell metacharacters and all" "got=$got"

# The array is created where the field is absent — the // [] the workflows
# would spell at every call site.
"$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.frozen_causes "$cause" >/dev/null
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.frozen_causes | length')"
[[ "$got" == "1" ]] && ok "append-file creates the array when the field is absent" \
  || bad "append-file creates the array when the field is absent" "got=$got"

# Fails closed on anything that is not exactly one JSON value: a truncated or
# doubled write must not reach the record the recurrence rule reads. The
# whole array is snapshotted first, so a refusal that rewrote an entry while
# keeping the count would not pass as untouched.
before="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes')"
printf 'not json\n' > "$TMP_ROOT/bad.json"
rc=0; "$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$TMP_ROOT/bad.json" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "append-file refuses a file that is not JSON" || bad "append-file refuses a file that is not JSON"
printf '{"a":1}\n{"b":2}\n' > "$TMP_ROOT/two.json"
rc=0; "$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$TMP_ROOT/two.json" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "append-file refuses a file holding two values" || bad "append-file refuses a file holding two values"
rc=0; "$WS" --state-dir "$cd_sd" append-file KEN-CAP pr_comment_review.patched_causes "$TMP_ROOT/nope.json" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "append-file refuses a missing file" || bad "append-file refuses a missing file"
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes')"
[[ "$got" == "$before" ]] && ok "a refused append leaves the record untouched" \
  || bad "a refused append leaves the record untouched" "before=$before got=$got"

# The workflows that record a cause come through it — no second spelling of
# the append jq survives.
append_strays() { grep -rnF 'patched_causes // []) + [' "$1" 2>/dev/null || true; }
stray="$(append_strays "$REPO_ROOT/skills/orch/workflows")"
[[ -z "$stray" ]] && ok "no workflow spells the patched_causes append by hand" \
  || bad "no workflow spells the patched_causes append by hand" "$stray"
# Planted: the hand-spelled jq the workflows would carry.
CTRL_DIR="$TMP_ROOT/append-stray-workflows"
mkdir -p "$CTRL_DIR"
cat > "$CTRL_DIR/dev-fix.md" <<'CTRL'
workflow-state update [ISSUE_ID] --slurpfile e f '$e[0] as $x | .pr_comment_review.patched_causes = ((.pr_comment_review.patched_causes // []) + [$x])'
CTRL
[[ -n "$(append_strays "$CTRL_DIR")" ]] && ok "the stray check flags a workflow spelling the append by hand" \
  || bad "the stray check flags a workflow spelling the append by hand"

# The fleet log's `at` is the script's to write: the overseer types the
# judgement and the clock is read by the append.
source "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh"
fl_sd="$TMP_ROOT/fleet-state"
"$WS" --state-dir "$fl_sd" init oversee >/dev/null

printf '{"kind":"ruling","item":"KEN-1","text":"no at"}\n' > "$TMP_ROOT/fl-none.json"
fl_before="$(date -u +%s)"
"$WS" --state-dir "$fl_sd" append-file oversee fleet_log "$TMP_ROOT/fl-none.json" >/dev/null
fl_after="$(date -u +%s)"
stamped="$("$WS" --state-dir "$fl_sd" get oversee '.fleet_log[0].at')"
stamped_epoch="$(to_epoch "$stamped")" || stamped_epoch=""
[[ -n "$stamped_epoch" && "$stamped_epoch" -ge "$fl_before" && "$stamped_epoch" -le "$fl_after" ]] \
  && ok "a fleet_log record with no at is stamped from the clock" \
  || bad "a fleet_log record with no at is stamped from the clock" "at=$stamped window=$fl_before..$fl_after"
# The window alone passes on every spelling GNU `date -d` accepts, which is
# most of them. The stamp is read back by `to_epoch`'s BSD arm too, pinned to
# this one form, so the shape the schema names is asserted outright rather
# than left to whichever `date` the row happened to run under.
[[ "$stamped" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok "the stamp carries the ISO8601 UTC form every sibling field uses" \
  || bad "the stamp carries the ISO8601 UTC form every sibling field uses" "at=$stamped"

# An `at` the clock has already passed is a late write, and a late write is
# real: it is kept as the record carries it.
printf '{"at":"2020-01-01T00:00:00Z","kind":"ruling","item":"KEN-2","text":"past"}\n' > "$TMP_ROOT/fl-past.json"
"$WS" --state-dir "$fl_sd" append-file oversee fleet_log "$TMP_ROOT/fl-past.json" >/dev/null
got="$("$WS" --state-dir "$fl_sd" get oversee '.fleet_log[1].at')"
[[ "$got" == "2020-01-01T00:00:00Z" ]] && ok "a fleet_log at earlier than the clock is kept" \
  || bad "a fleet_log at earlier than the clock is kept" "got=$got"

printf '{"at":"2099-01-01T00:00:00Z","kind":"ruling","item":"KEN-3","text":"future"}\n' > "$TMP_ROOT/fl-future.json"
rc=0
"$WS" --state-dir "$fl_sd" append-file oversee fleet_log "$TMP_ROOT/fl-future.json" \
  >/dev/null 2>"$TMP_ROOT/fl-future.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/fl-future.err")"
[[ "$rc" -eq 1 && "$key" == 'workflow-state: fleet-log-at-future at=2099-01-01T00:00:00Z now='* ]] \
  && ok "a fleet_log at later than the clock is refused as fleet-log-at-future" \
  || bad "a fleet_log at later than the clock is refused as fleet-log-at-future" "rc=$rc key=$key"
got="$("$WS" --state-dir "$fl_sd" get oversee '.fleet_log | length')"
[[ "$got" == "2" ]] && ok "the refused fleet_log record never reaches the log" \
  || bad "the refused fleet_log record never reaches the log" "got=$got"

# The inverse: no other array field is stamped. The cause fixture carries no
# `at`, so an entry that grew one would be this rule reaching past fleet_log.
got="$("$WS" --state-dir "$cd_sd" get KEN-CAP '.pr_comment_review.patched_causes[0] | has("at")')"
[[ "$got" == "false" ]] && ok "append-file stamps no field but fleet_log" \
  || bad "append-file stamps no field but fleet_log" "got=$got"

# A record that is not an object has no `at` to judge, and the refusal names
# that rather than letting jq's indexing failure stand in for it.
printf '"not an object"\n' > "$TMP_ROOT/fl-scalar.json"
rc=0
"$WS" --state-dir "$fl_sd" append-file oversee fleet_log "$TMP_ROOT/fl-scalar.json" \
  >/dev/null 2>"$TMP_ROOT/fl-scalar.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/fl-scalar.err")"
[[ "$rc" -eq 1 && "$key" == "workflow-state: fleet-log-record file=$TMP_ROOT/fl-scalar.json" ]] \
  && ok "a fleet_log record that is not an object is refused as fleet-log-record" \
  || bad "a fleet_log record that is not an object is refused as fleet-log-record" "rc=$rc key=$key"

MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR"
cp -R "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
mutant_run() { # MUTANT_NAME STATE_DIR RECORD ERR_FILE
  local rc=0
  "$WS" --state-dir "$2" init oversee >/dev/null
  bash "$MUTANT_DIR/$1" --state-dir "$2" append-file oversee fleet_log "$3" >/dev/null 2>"$4" || rc=$?
  return "$rc"
}

# Planted: the stamp dropped. The record then reaches the log with no time
# at all, which is the drift this rule ends.
[[ "$(grep -Fc "entry_expr='(\$entry[0] | .at = \$now)'" "$WS")" == "1" ]] \
  && ok "the stamp control finds the stamping expression" \
  || bad "the stamp control finds the stamping expression"
awk -v q="'" 'index($0, "entry_expr=" q "($entry[0] | .at = $now)" q) \
  { print "            entry_expr=" q "$entry[0]" q; next } { print }' "$WS" > "$MUTANT_DIR/no-stamp"
mutant_run no-stamp "$TMP_ROOT/mutant-none" "$TMP_ROOT/fl-none.json" "$TMP_ROOT/no-stamp.err" || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-none" get oversee '.fleet_log[0] | has("at")')"
[[ "$got" == "false" ]] && ok "control: without the stamping expression the record keeps no time" \
  || bad "control: without the stamping expression the record keeps no time" "got=$got"

# Planted: the object read made total, which is the shape that lets a scalar
# record through to jq — the failure then names the filter, not the record.
[[ "$(grep -Fc "jq -r '.at // \"\"' < \"\$file\"" "$WS")" == "1" ]] \
  && ok "the record control finds the at read" \
  || bad "the record control finds the at read"
awk -v q="'" 'index($0, "jq -r " q ".at // \"\"" q) \
  { print "        if ! at=$(jq -r " q ".at? // \"\"" q " < \"$file\" 2>/dev/null); then"; next } { print }' \
  "$WS" > "$MUTANT_DIR/total-read"
mutant_run total-read "$TMP_ROOT/mutant-scalar" "$TMP_ROOT/fl-scalar.json" "$TMP_ROOT/total-read.err" || true
key="$(head -n 1 "$TMP_ROOT/total-read.err")"
[[ "$key" == "workflow-state: jq-failed state=$TMP_ROOT/mutant-scalar/workflow-state-oversee.json" ]] \
  && ok "control: without the record refusal the scalar fails as jq-failed, naming the filter" \
  || bad "control: without the record refusal the scalar fails as jq-failed, naming the filter" "key=$key"

# Planted: the clock comparison removed. The future record then lands in the
# log unjudged.
[[ "$(grep -Fc '[[ "$at_epoch" -gt "$now_epoch" ]]' "$WS")" == "1" ]] \
  && ok "the future control finds the clock comparison" \
  || bad "the future control finds the clock comparison"
sed 's|\[\[ "$at_epoch" -gt "$now_epoch" ]]|false|' "$WS" > "$MUTANT_DIR/no-clock"
mutant_run no-clock "$TMP_ROOT/mutant-future" "$TMP_ROOT/fl-future.json" "$TMP_ROOT/no-clock.err" || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-future" get oversee '.fleet_log[0].at')"
[[ "$got" == "2099-01-01T00:00:00Z" ]] && ok "control: without the clock comparison the future record is stored" \
  || bad "control: without the clock comparison the future record is stored" "got=$got"

# Planted: the stamp written in a form `to_epoch`'s BSD arm cannot read. A
# macOS run would then fail to parse a time this script wrote itself.
[[ "$(grep -Fc "from_epoch \"\$now_epoch\" '%Y-%m-%dT%H:%M:%SZ'" "$WS")" == "1" ]] \
  && ok "the format control finds the stamp format" \
  || bad "the format control finds the stamp format"
sed "s|from_epoch \"\$now_epoch\" '%Y-%m-%dT%H:%M:%SZ'|from_epoch \"\$now_epoch\" '%Y-%m-%d %H:%M:%S'|" \
  "$WS" > "$MUTANT_DIR/loose-format"
mutant_run loose-format "$TMP_ROOT/mutant-format" "$TMP_ROOT/fl-none.json" "$TMP_ROOT/loose-format.err" || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-format" get oversee '.fleet_log[0].at')"
[[ ! "$got" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok "control: a stamp in another format fails the shape the row asserts" \
  || bad "control: a stamp in another format fails the shape the row asserts" "got=$got"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
