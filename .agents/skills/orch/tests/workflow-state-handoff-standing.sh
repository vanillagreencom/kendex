#!/usr/bin/env bash
# workflow-state handoff-standing: the one judge of whether a lane's handoff
# record stands. Three callers ask it: the oversee-watch pass that reports
# `handoff`, the lane-mail-check turn-end hook that refuses until a record
# stands, and the resume step of ../workflows/start.md. So the answer is a
# status and not prose: 0 with the record on stdout, 3 for none standing, 2
# for a state nothing could read.
#
# 1 is the status this verb never gives, and the rows below are what holds it
# free: an install older than the verb answers 1 from its unknown-command arm,
# and a caller that read 1 as "none stands" would tell a lane that has already
# written its record to write it again at every turn end.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$(cd "$TEST_DIR/../scripts" && pwd)"
WS="$SCRIPTS/workflow-state"
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

PASS=0
FAIL=0
assert_eq() { # GOT WANT LABEL
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$3" "$2" "$1"
  fi
}

# One call: its status, and the record it printed.
standing() { # ITEM
  local out rc=0
  out="$("$WS" --state-dir "$STATE" handoff-standing "$1" 2>"$TMP_ROOT/err")" || rc=$?
  printf 'rc=%s out=%s' "$rc" "$out"
}

echo "=== workflow-state handoff-standing ==="

assert_eq "$(standing KEN-1)" "rc=3 out=" \
  "an item with no state file has no record standing"

"$WS" --state-dir "$STATE" init KEN-1 > /dev/null
assert_eq "$(standing KEN-1)" "rc=3 out=" \
  "an item whose state carries no handoff has none standing"

RECORD='{"written_at":"2026-09-18T08:05:00Z","merged":[],"remaining":["submit-pr"],"branch":"b","worktree":"w","open_pr":null,"traps":[]}'
"$WS" --state-dir "$STATE" set KEN-1 handoff "$RECORD" > /dev/null
assert_eq "$(standing KEN-1)" "rc=0 out=$RECORD" \
  "a record no relaunch has resumed stands, and is printed as it was written"

"$WS" --state-dir "$STATE" set-now KEN-1 handoff.resumed_at > /dev/null
assert_eq "$(standing KEN-1)" "rc=3 out=" \
  "a record a relaunch stamped resumed_at on belongs to an earlier life"

# A handoff that is not an object is not a record: the shape is part of the
# test, so a field set to a string or a number never reads as one.
"$WS" --state-dir "$STATE" init KEN-2 > /dev/null
"$WS" --state-dir "$STATE" set KEN-2 handoff pending > /dev/null
assert_eq "$(standing KEN-2)" "rc=3 out=" \
  "a handoff field that is not an object is no record"

printf 'not json\n' > "$STATE/workflow-state-KEN-3.json"
assert_eq "$(standing KEN-3)" "rc=2 out=" \
  "a state file nothing can parse is a read that failed, never no record"
assert_eq "$("$WS" --state-dir "$STATE" no-such-verb KEN-1 >/dev/null 2>&1; echo "rc=$?")" "rc=1" \
  "the dispatcher answers 1 for a verb it does not know, which is why none-stands is 3"
assert_eq "$([ -s "$TMP_ROOT/err" ] && echo said || echo silent)" "said" \
  "that failure carries the reader's own words on stderr"

# The callers: each reaches the verb rather than restating its jq filter.
FILTER='select(type == "object" and .resumed_at == null)'
for caller in scripts/oversee-watch hooks/lane-mail-check.sh; do
  path="$TEST_DIR/../../../$caller"
  [[ "$caller" != scripts/* ]] || path="$TEST_DIR/../$caller"
  assert_eq "$(grep -cF -- "$FILTER" "$path" || true)" "0" \
    "$caller states no second copy of the record test"
  assert_eq "$(grep -cF -- 'handoff-standing "' "$path" || true)" "1" \
    "$caller asks the verb instead, once"
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
