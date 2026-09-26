#!/usr/bin/env bash
# `workflow-state set <id> handoff <record>`: the record's time is the
# script's, not the lane's. A lane types its handoff at a safe point, and a
# typed time can name a moment that has not arrived, which makes a relaunch
# look faster than it was. The command stamps an absent `written_at`, keeps a
# past one, refuses a future one, refuses one outside the ISO 8601 UTC shape
# the schema names or naming no instant a calendar has, refuses a record that
# is not a JSON object, and refuses the set outright when its own clock
# cannot be read. The `fleet_log` half of the same rule is
# workflow-state-append-file.sh; both call one `stamp_judge`.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
source "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh"

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo
echo "--- workflow-state set handoff ---"

SD="$TMP_ROOT/state"
"$WS" --state-dir "$SD" init KEN-H >/dev/null

# The record the templates now hand the lane: every durable field a relaunch
# reads, and no time.
RECORD='{"merged":["#2714"],"remaining":["merge-pr § 5"],"branch":"b","worktree":"/w","open_pr":null,"traps":["t"]}'

before="$(date -u +%s)"
"$WS" --state-dir "$SD" set KEN-H handoff "$RECORD" >/dev/null
after="$(date -u +%s)"
stamped="$("$WS" --state-dir "$SD" get KEN-H '.handoff.written_at')"
stamped_epoch="$(to_epoch "$stamped")" || stamped_epoch=""
[[ -n "$stamped_epoch" && "$stamped_epoch" -ge "$before" && "$stamped_epoch" -le "$after" ]] \
  && pass "a handoff record with no written_at is stamped from the clock" \
  || fail "a handoff record with no written_at is stamped from the clock" "written_at=$stamped window=$before..$after"
# The window alone passes on every spelling GNU `date -d` accepts. The schema
# names one shape and the readers order records on it, so it is asserted here
# the way the fleet log's stamp is.
[[ "$stamped" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && pass "the stamp carries the ISO 8601 UTC form the schema names" \
  || fail "the stamp carries the ISO 8601 UTC form the schema names" "written_at=$stamped"
got="$("$WS" --state-dir "$SD" get KEN-H '.handoff | keys | join(",")')"
[[ "$got" == "branch,merged,open_pr,remaining,traps,worktree,written_at" ]] \
  && pass "the stamp joins the record the lane wrote rather than replacing it" \
  || fail "the stamp joins the record the lane wrote rather than replacing it" "keys=$got"

# A `written_at` the clock has already passed is a late write, and a late
# write is real: it is kept as the record carries it.
"$WS" --state-dir "$SD" set KEN-H handoff '{"written_at":"2020-01-01T00:00:00Z","branch":"b"}' >/dev/null
got="$("$WS" --state-dir "$SD" get KEN-H '.handoff.written_at')"
[[ "$got" == "2020-01-01T00:00:00Z" ]] && pass "a handoff written_at earlier than the clock is kept" \
  || fail "a handoff written_at earlier than the clock is kept" "got=$got"

# refuses VALUE KEY_PREFIX NAME — the set is refused with that first line and
# the record it would have replaced still stands.
refuses() { # VALUE KEY_PREFIX NAME
  local value="$1" want="$2" name="$3" rc=0 key before_record after_record
  before_record="$("$WS" --state-dir "$SD" get KEN-H '.handoff | tojson')"
  "$WS" --state-dir "$SD" set KEN-H handoff "$value" >/dev/null 2>"$TMP_ROOT/refuse.err" || rc=$?
  key="$(head -n 1 "$TMP_ROOT/refuse.err")"
  after_record="$("$WS" --state-dir "$SD" get KEN-H '.handoff | tojson')"
  [[ "$rc" -eq 1 && "$key" == "$want"* ]] && pass "$name" \
    || fail "$name" "rc=$rc key=$key"
  [[ "$after_record" == "$before_record" ]] && pass "$name: the refused record never reaches the state" \
    || fail "$name: the refused record never reaches the state" "after=$after_record"
}

refuses '{"written_at":"2099-01-01T00:00:00Z","branch":"b"}' \
  'workflow-state: handoff-written-at-future written_at=2099-01-01T00:00:00Z now=' \
  "a handoff written_at later than the clock is refused as handoff-written-at-future"
# Every spelling the rule refuses, each its own class, in the order the fleet
# log suite lists them. Without it the date ladder alone judges them, and its
# GNU arm reads spellings its BSD arm cannot. The last row is the round
# trip's rather than the regex's; both fields call one `stamp_judge`, so its
# row under the BSD date stub runs in workflow-state-append-file.sh rather
# than a second time here.
while IFS='|' read -r value label; do
  refuses "{\"written_at\":\"$value\",\"branch\":\"b\"}" \
    "workflow-state: handoff-written-at-invalid written_at=$value" \
    "a handoff written_at $label is refused as handoff-written-at-invalid"
done <<'ROWS'
2099-01-01 00:00:00|later than the clock in a spelling only the GNU arm reads
2020-01-01 00:00:00|earlier than the clock in that same spelling
 2020-01-01T00:00:00Z|carrying the ISO form with text around it
2020-02-30T00:00:00Z|shaped right but naming no instant a calendar has
ROWS
refuses '"not an object"' 'workflow-state: handoff-record issue=KEN-H' \
  "a handoff record that is not an object is refused as handoff-record"

# The inverse: no other field is stamped. The record is the same object under
# another name, so a written_at appearing on it would be this rule reaching
# past handoff.
"$WS" --state-dir "$SD" set KEN-H post_pr_stop "$RECORD" >/dev/null
got="$("$WS" --state-dir "$SD" get KEN-H '.post_pr_stop | has("written_at")')"
[[ "$got" == "false" ]] && pass "set stamps no field but handoff" \
  || fail "set stamps no field but handoff" "got=$got"

# The suite's one must-fail control: the clock comparison neutralized in the
# one helper both stamped fields call. The future record then lands in the
# state unjudged.
NO_CLOCK="$(mutant_scripts no-clock workflow-state)/workflow-state" || exit 1
mutate_file "$NO_CLOCK" '[[ "$raw_epoch" -gt "$now_epoch" ]]' 'false'
"$WS" --state-dir "$TMP_ROOT/mutant-future" init KEN-H >/dev/null
"$NO_CLOCK" --state-dir "$TMP_ROOT/mutant-future" set KEN-H handoff \
  '{"written_at":"2099-01-01T00:00:00Z","branch":"b"}' >/dev/null 2>&1 || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-future" get KEN-H '.handoff.written_at')"
[[ "$got" == "2099-01-01T00:00:00Z" ]] && pass "control: without the clock comparison the future record is stored" \
  || fail "control: without the clock comparison the future record is stored" "got=$got"

# The clock the stamp comes from is this rule's own dependency, and a `date`
# that exits nonzero leaves both reads empty. `stamp_judge` runs inside a
# command substitution, which carries no failure out to its caller, so the
# empty string would otherwise be stamped into the record under a success
# exit. It is refused by name with nothing written instead. One key covers
# both stamped fields, because the clock is the script's rather than either
# field's; the `fleet_log` side of the same key is the sibling suite's.
DEAD_BIN="$TMP_ROOT/dead-bin"
mkdir -p "$DEAD_BIN"
printf '#!/bin/sh\nexit 1\n' > "$DEAD_BIN/date"
chmod +x "$DEAD_BIN/date"
dead_before="$("$WS" --state-dir "$SD" get KEN-H 'tojson')"
rc=0
PATH="$DEAD_BIN:$PATH" "$WS" --state-dir "$SD" set KEN-H handoff '{"branch":"b"}' \
  >/dev/null 2>"$TMP_ROOT/clock.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/clock.err")"
[[ "$rc" -eq 1 && "$key" == "workflow-state: clock-unreadable field=handoff" ]] \
  && pass "a handoff set whose clock cannot be read is refused as clock-unreadable" \
  || fail "a handoff set whose clock cannot be read is refused as clock-unreadable" "rc=$rc key=$key"
got="$("$WS" --state-dir "$SD" get KEN-H 'tojson')"
[[ "$got" == "$dead_before" ]] && pass "the clock refusal leaves the state untouched" \
  || fail "the clock refusal leaves the state untouched" "got=$got"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
