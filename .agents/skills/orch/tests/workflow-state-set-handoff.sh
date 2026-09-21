#!/usr/bin/env bash
# `workflow-state set <id> handoff <record>`: the record's time is the
# script's, not the lane's. A lane types its handoff at a safe point, and a
# typed time can name a moment that has not arrived, which makes a relaunch
# look faster than it was. The command stamps an absent `written_at`, keeps a
# past one, refuses a future one, refuses one outside the ISO 8601 UTC shape
# the schema names, and refuses a record that is not a JSON object. The
# `fleet_log` half of the same rule is workflow-state-append-file.sh; both
# call one `stamp_judge`.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
source "$REPO_ROOT/skills/orch/scripts/lib/date-ladder.sh"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

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
  && ok "a handoff record with no written_at is stamped from the clock" \
  || bad "a handoff record with no written_at is stamped from the clock" "written_at=$stamped window=$before..$after"
# The window alone passes on every spelling GNU `date -d` accepts. The schema
# names one shape and the readers order records on it, so it is asserted here
# the way the fleet log's stamp is.
[[ "$stamped" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] \
  && ok "the stamp carries the ISO 8601 UTC form the schema names" \
  || bad "the stamp carries the ISO 8601 UTC form the schema names" "written_at=$stamped"
got="$("$WS" --state-dir "$SD" get KEN-H '.handoff | keys | join(",")')"
[[ "$got" == "branch,merged,open_pr,remaining,traps,worktree,written_at" ]] \
  && ok "the stamp joins the record the lane wrote rather than replacing it" \
  || bad "the stamp joins the record the lane wrote rather than replacing it" "keys=$got"

# A `written_at` the clock has already passed is a late write, and a late
# write is real: it is kept as the record carries it.
"$WS" --state-dir "$SD" set KEN-H handoff '{"written_at":"2020-01-01T00:00:00Z","branch":"b"}' >/dev/null
got="$("$WS" --state-dir "$SD" get KEN-H '.handoff.written_at')"
[[ "$got" == "2020-01-01T00:00:00Z" ]] && ok "a handoff written_at earlier than the clock is kept" \
  || bad "a handoff written_at earlier than the clock is kept" "got=$got"

# refuses VALUE KEY_PREFIX NAME — the set is refused with that first line and
# the record it would have replaced still stands.
refuses() { # VALUE KEY_PREFIX NAME
  local value="$1" want="$2" name="$3" rc=0 key before_record after_record
  before_record="$("$WS" --state-dir "$SD" get KEN-H '.handoff | tojson')"
  "$WS" --state-dir "$SD" set KEN-H handoff "$value" >/dev/null 2>"$TMP_ROOT/refuse.err" || rc=$?
  key="$(head -n 1 "$TMP_ROOT/refuse.err")"
  after_record="$("$WS" --state-dir "$SD" get KEN-H '.handoff | tojson')"
  [[ "$rc" -eq 1 && "$key" == "$want"* ]] && ok "$name" \
    || bad "$name" "rc=$rc key=$key"
  [[ "$after_record" == "$before_record" ]] && ok "$name: the refused record never reaches the state" \
    || bad "$name: the refused record never reaches the state" "after=$after_record"
}

refuses '{"written_at":"2099-01-01T00:00:00Z","branch":"b"}' \
  'workflow-state: handoff-written-at-future written_at=2099-01-01T00:00:00Z now=' \
  "a handoff written_at later than the clock is refused as handoff-written-at-future"
# Every spelling the shape rule refuses, each its own class, in the order the
# fleet log suite lists them. Without it the date ladder alone judges them,
# and its GNU arm reads spellings its BSD arm cannot.
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
[[ "$got" == "false" ]] && ok "set stamps no field but handoff" \
  || bad "set stamps no field but handoff" "got=$got"

MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR"
cp -R "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
# mutant_run MUTANT_NAME STATE_DIR RECORD — the mutant against its own fresh
# state, so what it stored is read back with no earlier record underneath.
mutant_run() { # MUTANT_NAME STATE_DIR RECORD
  local rc=0
  "$WS" --state-dir "$2" init KEN-H >/dev/null
  bash "$MUTANT_DIR/$1" --state-dir "$2" set KEN-H handoff "$3" >/dev/null 2>"$TMP_ROOT/$1.err" || rc=$?
  return "$rc"
}

# Planted: the stamping arm dropped. The record then reaches the state with no
# time at all, which is the field every relaunch reader is missing.
[[ "$(grep -Fc '| .written_at = \$now)"' "$WS")" == "1" ]] \
  && ok "the stamp control finds the stamping arm" \
  || bad "the stamp control finds the stamping arm"
awk 'index($0, "| .written_at = \\$now)\"") \
  { print "            stamp)  atomic_update \"$state_file\" \".${field} = ${value}\" \\"; next } { print }' \
  "$WS" > "$MUTANT_DIR/no-stamp"
mutant_run no-stamp "$TMP_ROOT/mutant-none" "$RECORD" || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-none" get KEN-H '.handoff | has("written_at")')"
[[ "$got" == "false" ]] && ok "control: without the stamping arm the record keeps no time" \
  || bad "control: without the stamping arm the record keeps no time" "got=$got"

# Planted: the clock comparison neutralized in the one helper both stamped
# fields call. The future record then lands in the state unjudged.
[[ "$(grep -Fc '[[ "$raw_epoch" -gt "$now_epoch" ]]' "$WS")" == "1" ]] \
  && ok "the future control finds the clock comparison" \
  || bad "the future control finds the clock comparison"
sed 's|\[\[ "$raw_epoch" -gt "$now_epoch" ]]|false|' "$WS" > "$MUTANT_DIR/no-clock"
mutant_run no-clock "$TMP_ROOT/mutant-future" '{"written_at":"2099-01-01T00:00:00Z","branch":"b"}' || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-future" get KEN-H '.handoff.written_at')"
[[ "$got" == "2099-01-01T00:00:00Z" ]] && ok "control: without the clock comparison the future record is stored" \
  || bad "control: without the clock comparison the future record is stored" "got=$got"

# Planted: the shape check removed. The non-ISO spelling then reaches the
# state, where `to_epoch`'s BSD arm cannot read it back.
[[ "$(grep -Fc 'state_message handoff-written-at-invalid "$@" >&2; return 1' "$WS")" == "1" ]] \
  && ok "the shape control finds the shape refusal" \
  || bad "the shape control finds the shape refusal"
sed 's|state_message handoff-written-at-invalid "$@" >&2; return 1|:|' "$WS" > "$MUTANT_DIR/no-shape"
mutant_run no-shape "$TMP_ROOT/mutant-shape" '{"written_at":"2020-01-01 00:00:00","branch":"b"}' || true
got="$("$WS" --state-dir "$TMP_ROOT/mutant-shape" get KEN-H '.handoff.written_at')"
[[ "$got" == "2020-01-01 00:00:00" ]] && ok "control: without the shape refusal the non-ISO value is stored" \
  || bad "control: without the shape refusal the non-ISO value is stored" "got=$got"

# Planted: the object read made total, which is the shape that lets a scalar
# record through to jq — the failure then names the filter, not the record.
[[ "$(grep -Fc "jq -er 'select(type == \"object\") | .written_at // \"\"' <<<\"\$value\"" "$WS")" == "1" ]] \
  && ok "the record control finds the written_at read" \
  || bad "the record control finds the written_at read"
awk -v q="'" 'index($0, "jq -er " q "select(type == \"object\") | .written_at // \"\"" q) \
  { print "        if ! written_at=$(jq -r " q ".written_at? // \"\"" q " <<<\"$value\" 2>/dev/null); then"; next } { print }' \
  "$WS" > "$MUTANT_DIR/total-read"
mutant_run total-read "$TMP_ROOT/mutant-scalar" '"not an object"' || true
key="$(head -n 1 "$TMP_ROOT/total-read.err")"
[[ "$key" == "workflow-state: jq-failed state=$TMP_ROOT/mutant-scalar/workflow-state-KEN-H.json" ]] \
  && ok "control: without the record refusal the scalar fails as jq-failed, naming the filter" \
  || bad "control: without the record refusal the scalar fails as jq-failed, naming the filter" "key=$key"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
