#!/usr/bin/env bash
# `workflow-state append-file <id> <path> <file>`: reviewer text never crosses
# argv. A cause reaches the state byte for byte through a file, the array is
# created where the field is absent, anything that is not exactly one JSON
# value is refused with the record untouched, and no workflow spells the
# append by hand. On fleet_log the command also owns the record's time: it
# stamps an absent `at`, keeps a past one, and refuses a future one, one
# outside the ISO 8601 UTC shape, and one shaped right that names no instant
# a calendar has. A clock it cannot read refuses the append rather than
# stamping an empty time.
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

# Every spelling the rule refuses, each its own class. Without it the first
# is judged by the date ladder alone, which refuses it as future on a host
# whose `date` takes -d and stores it on one whose does not: the same record,
# two answers, neither caller able to act on the pair. The last row is the
# round trip's rather than the regex's, and the BSD-arm control for it is
# below.
while IFS='|' read -r fl_value fl_label; do
  printf '{"at":"%s","kind":"ruling","item":"KEN-4","text":"shape"}\n' "$fl_value" > "$TMP_ROOT/fl-shape.json"
  rc=0
  "$WS" --state-dir "$fl_sd" append-file oversee fleet_log "$TMP_ROOT/fl-shape.json" \
    >/dev/null 2>"$TMP_ROOT/fl-shape.err" || rc=$?
  key="$(head -n 1 "$TMP_ROOT/fl-shape.err")"
  [[ "$rc" -eq 1 && "$key" == "workflow-state: fleet-log-at-invalid at=$fl_value" ]] \
    && ok "a fleet_log at $fl_label is refused as fleet-log-at-invalid" \
    || bad "a fleet_log at $fl_label is refused as fleet-log-at-invalid" "rc=$rc key=$key"
done <<'ROWS'
2099-01-01 00:00:00|later than the clock in a spelling only the GNU arm reads
2020-01-01 00:00:00|earlier than the clock in that same spelling
 2020-01-01T00:00:00Z|carrying the ISO form with text around it
2020-02-30T00:00:00Z|shaped right but naming no instant a calendar has
ROWS
got="$("$WS" --state-dir "$fl_sd" get oversee '.fleet_log | length')"
[[ "$got" == "2" ]] && ok "no refused shape reaches the log either" \
  || bad "no refused shape reaches the log either" "got=$got"

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
[[ "$(grep -Fc "jq -er 'select(type == \"object\") | .at // \"\"' < \"\$file\"" "$WS")" == "1" ]] \
  && ok "the record control finds the at read" \
  || bad "the record control finds the at read"
awk -v q="'" 'index($0, "jq -er " q "select(type == \"object\") | .at // \"\"" q) \
  { print "        if ! at=$(jq -r " q ".at? // \"\"" q " < \"$file\" 2>/dev/null); then"; next } { print }' \
  "$WS" > "$MUTANT_DIR/total-read"
mutant_run total-read "$TMP_ROOT/mutant-scalar" "$TMP_ROOT/fl-scalar.json" "$TMP_ROOT/total-read.err" || true
key="$(head -n 1 "$TMP_ROOT/total-read.err")"
[[ "$key" == "workflow-state: jq-failed state=$TMP_ROOT/mutant-scalar/workflow-state-oversee.json" ]] \
  && ok "control: without the record refusal the scalar fails as jq-failed, naming the filter" \
  || bad "control: without the record refusal the scalar fails as jq-failed, naming the filter" "key=$key"

# Planted: the clock comparison removed. The future record then lands in the
# log unjudged.
[[ "$(grep -Fc '[[ "$raw_epoch" -gt "$now_epoch" ]]' "$WS")" == "1" ]] \
  && ok "the future control finds the clock comparison" \
  || bad "the future control finds the clock comparison"
sed 's|\[\[ "$raw_epoch" -gt "$now_epoch" ]]|false|' "$WS" > "$MUTANT_DIR/no-clock"
mutant_run no-clock "$TMP_ROOT/mutant-future" "$TMP_ROOT/fl-future.json" "$TMP_ROOT/no-clock.err" || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-future" get oversee '.fleet_log[0].at')"
[[ "$got" == "2099-01-01T00:00:00Z" ]] && ok "control: without the clock comparison the future record is stored" \
  || bad "control: without the clock comparison the future record is stored" "got=$got"

# Planted: the shape refusal removed. The value then reaches the log, where a
# reader on the other date arm cannot read it back.
[[ "$(grep -Fc 'state_message fleet-log-at-invalid "$@" >&2; return 1' "$WS")" == "1" ]] \
  && ok "the shape control finds the shape refusal" \
  || bad "the shape control finds the shape refusal"
printf '{"at":"2020-01-01 00:00:00","kind":"ruling","item":"KEN-5","text":"shape"}\n' > "$TMP_ROOT/fl-loose.json"
sed 's|state_message fleet-log-at-invalid "$@" >&2; return 1|:|' "$WS" > "$MUTANT_DIR/no-shape"
mutant_run no-shape "$TMP_ROOT/mutant-shape" "$TMP_ROOT/fl-loose.json" "$TMP_ROOT/no-shape.err" || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-shape" get oversee '.fleet_log[0].at')"
[[ "$got" == "2020-01-01 00:00:00" ]] && ok "control: without the shape refusal the non-ISO value is stored" \
  || bad "control: without the shape refusal the non-ISO value is stored" "got=$got"

# The instant is judged by a round trip through the epoch, not by whether the
# date ladder read the string at all, because the ladder's two arms disagree
# on exactly that. The rows below need the BSD arm's answer, and which side
# of the split this host sits on decides where it comes from. A `date` with
# no -d already IS that arm, so the rows run straight against it. A `date`
# with -d is the GNU arm, and only there is a stub built to the BSD contract
# put in front of it. So the stub runs on a GNU host and nowhere else, which
# is what lets its arms hand the work back to the real `date` in GNU's own
# spellings; a stub reaching for those on a macOS runner would answer every
# row with "illegal option -- d".
BSD_REAL_DATE="$(command -v date)"
[[ -x "$BSD_REAL_DATE" ]] \
  || { echo "append-file suite: date not found before PATH shadowing" >&2; exit 1; }
export BSD_REAL_DATE
BSD_PATH="$PATH"
if "$BSD_REAL_DATE" -d @0 +%s >/dev/null 2>&1; then
BSD_BIN="$TMP_ROOT/bsd-bin"
mkdir -p "$BSD_BIN"
cat > "$BSD_BIN/date" <<'STUB'
#!/usr/bin/env bash
# `date` to the BSD/macOS contract, in the three forms this script's callers
# use, over a GNU `date` the suite resolved before shadowing it. There is no
# -d, so the ladder falls to its second arm. That arm is strptime then
# mktime: strptime range-checks a day as 1 to 31 whatever the month is and a
# second to 60, and mktime then normalizes whatever it let through, so
# 2020-02-30 becomes 2020-03-01 and the parse succeeds. Rendering is the same
# on both implementations, so -r is handed straight back.
set -uo pipefail
case "${1:-}" in
  -u)
    [[ "${2:-}" == "+%s" ]] || { echo "date stub: unsupported: $*" >&2; exit 1; }
    exec "$BSD_REAL_DATE" -u +%s ;;
  -d)
    echo "date: illegal option -- d" >&2; exit 1 ;;
  -r)
    exec "$BSD_REAL_DATE" -d "@${2:?}" "${3:?}" ;;
  -j)
    [[ "${2:-}" == "-f" && "${3:-}" == '%Y-%m-%dT%H:%M:%SZ' && "${5:-}" == "+%s" ]] \
      || { echo "date stub: unsupported -j form: $*" >&2; exit 1; }
    if [[ ! "$4" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]]; then
      echo "date: Failed conversion of $4" >&2; exit 1
    fi
    y="${BASH_REMATCH[1]}"
    mo=$((10#${BASH_REMATCH[2]})); d=$((10#${BASH_REMATCH[3]}))
    h=$((10#${BASH_REMATCH[4]})); mi=$((10#${BASH_REMATCH[5]})); s=$((10#${BASH_REMATCH[6]}))
    if (( mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || s > 60 )); then
      echo "date: Failed conversion of $4" >&2; exit 1
    fi
    # mktime: the first of the parsed month, then every other field added to
    # it, which is the normalization the range checks above leave to do.
    exec "$BSD_REAL_DATE" -u -d \
      "$(printf '%s-%02d-01 00:00:00 UTC' "$y" "$mo") + $((d - 1)) days + $h hours + $mi minutes + $s seconds" \
      +%s ;;
esac
echo "date stub: unsupported: $*" >&2
exit 1
STUB
chmod +x "$BSD_BIN/date"
BSD_PATH="$BSD_BIN:$PATH"
fi

# Whichever of the two the host gave, it is read the way the ladder reads it
# before any row leans on it: the shipped `to_epoch` under this PATH must
# return the epoch of the normalized day, which is what a macOS runner
# returns. The row is unconditional, so on a macOS runner it pins the real
# implementation and on a Linux one it pins the stub against it.
bsd_epoch="$(PATH="$BSD_PATH" bash -c \
  'source "$1"; to_epoch 2020-02-30T00:00:00Z' _ "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh")" || bsd_epoch=""
[[ "$bsd_epoch" == "1583020800" ]] \
  && ok "the BSD date arm this host offers normalizes 2020-02-30 rather than refusing it" \
  || bad "the BSD date arm this host offers normalizes 2020-02-30 rather than refusing it" "got=$bsd_epoch"

# On that arm the shape row above passes the ladder, so only the round trip
# separates a stored record from a refused one. It is refused here as it is
# on the GNU arm: one answer on both implementations.
printf '{"at":"2020-02-30T00:00:00Z","kind":"ruling","item":"KEN-6","text":"nonday"}\n' \
  > "$TMP_ROOT/fl-nonday.json"
bsd_sd="$TMP_ROOT/bsd-state"
"$WS" --state-dir "$bsd_sd" init oversee >/dev/null
rc=0
PATH="$BSD_PATH" "$WS" --state-dir "$bsd_sd" append-file oversee fleet_log "$TMP_ROOT/fl-nonday.json" \
  >/dev/null 2>"$TMP_ROOT/fl-nonday.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/fl-nonday.err")"
[[ "$rc" -eq 1 && "$key" == "workflow-state: fleet-log-at-invalid at=2020-02-30T00:00:00Z" ]] \
  && ok "a day past its month's length is refused on the BSD date arm too" \
  || bad "a day past its month's length is refused on the BSD date arm too" "rc=$rc key=$key"

# Planted: the round trip removed. On the BSD arm the ladder then answers
# that 2020-02-30 names an instant, and the record is stored carrying a date
# no calendar has — stored on macOS, refused on Linux.
[[ "$(grep -Fc "from_epoch \"\$raw_epoch\" '%Y-%m-%dT%H:%M:%SZ'" "$WS")" == "1" ]] \
  && ok "the instant control finds the round trip" \
  || bad "the instant control finds the round trip"
sed 's|\[\[ "$(from_epoch "$raw_epoch" .%Y-%m-%dT%H:%M:%SZ.)" != "$raw" ]]|false|' \
  "$WS" > "$MUTANT_DIR/no-roundtrip"
"$WS" --state-dir "$TMP_ROOT/mutant-nonday" init oversee >/dev/null
PATH="$BSD_PATH" bash "$MUTANT_DIR/no-roundtrip" --state-dir "$TMP_ROOT/mutant-nonday" \
  append-file oversee fleet_log "$TMP_ROOT/fl-nonday.json" >/dev/null 2>"$TMP_ROOT/no-roundtrip.err" || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-nonday" get oversee '.fleet_log[0].at')"
[[ "$got" == "2020-02-30T00:00:00Z" ]] \
  && ok "control: without the round trip the BSD arm stores the nonexistent date" \
  || bad "control: without the round trip the BSD arm stores the nonexistent date" "got=$got"

# The clock the stamp comes from is this rule's own dependency, and a `date`
# that exits nonzero leaves both reads empty. `stamp_judge` runs inside a
# command substitution, which carries no failure out to its caller, so the
# empty string would otherwise be stamped into the record under a success
# exit. It is refused by name with nothing written instead.
DEAD_BIN="$TMP_ROOT/dead-bin"
mkdir -p "$DEAD_BIN"
printf '#!/bin/sh\nexit 1\n' > "$DEAD_BIN/date"
chmod +x "$DEAD_BIN/date"
dead_sd="$TMP_ROOT/dead-state"
"$WS" --state-dir "$dead_sd" init oversee >/dev/null
dead_before="$("$WS" --state-dir "$dead_sd" get oversee 'tojson')"
rc=0
PATH="$DEAD_BIN:$PATH" "$WS" --state-dir "$dead_sd" append-file oversee fleet_log "$TMP_ROOT/fl-none.json" \
  >/dev/null 2>"$TMP_ROOT/fl-clock.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/fl-clock.err")"
[[ "$rc" -eq 1 && "$key" == "workflow-state: clock-unreadable field=fleet_log" ]] \
  && ok "a fleet_log append whose clock cannot be read is refused as clock-unreadable" \
  || bad "a fleet_log append whose clock cannot be read is refused as clock-unreadable" "rc=$rc key=$key"
got="$("$WS" --state-dir "$dead_sd" get oversee 'tojson')"
[[ "$got" == "$dead_before" ]] && ok "the clock refusal leaves the state untouched" \
  || bad "the clock refusal leaves the state untouched" "got=$got"

# Planted: the clock reads left unchecked, which is the shape that stamps the
# empty string. The record then lands carrying "at": "" and the command exits
# 0, so the field the rule owns is written from a clock nobody read.
[[ "$(grep -Fc 'if [[ -z "$now_epoch" || -z "$now" ]]; then' "$WS")" == "1" ]] \
  && ok "the clock control finds the clock check" \
  || bad "the clock control finds the clock check"
awk 'index($0, "if [[ -z \"$now_epoch\" || -z \"$now\" ]]; then") \
  { print "    if false; then"; next } { print }' "$WS" > "$MUTANT_DIR/no-clock-read"
"$WS" --state-dir "$TMP_ROOT/mutant-clock" init oversee >/dev/null
rc=0
PATH="$DEAD_BIN:$PATH" bash "$MUTANT_DIR/no-clock-read" --state-dir "$TMP_ROOT/mutant-clock" \
  append-file oversee fleet_log "$TMP_ROOT/fl-none.json" >/dev/null 2>"$TMP_ROOT/no-clock-read.err" || rc=$?
got="$("$WS" --state-dir "$TMP_ROOT/mutant-clock" get oversee '.fleet_log[0].at | tojson')"
[[ "$rc" -eq 0 && "$got" == '""' ]] \
  && ok "control: without the clock check the record is stored with an empty at" \
  || bad "control: without the clock check the record is stored with an empty at" "rc=$rc got=$got"

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
