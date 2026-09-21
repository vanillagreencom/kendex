#!/usr/bin/env bash
# workflow-state handoff-standing: the one judge of whether a lane's handoff
# record stands. Three callers ask it: the oversee-watch pass that reports
# `handoff`, the lane-mail-check turn-end hook that refuses until a record
# stands, and the resume step of ../workflows/start.md. The answer is the
# verdict word on the first stdout line, and the verb exits 0 for every one of
# them, so the rows below pin the whole protocol a caller parses.
#
# A status is never a verdict, and that is what the rows hold: every orch
# script sources `.env.local` as shell before its dispatch is reached, and bash
# 3.2 kills the script on a file it cannot parse with a status this verb would
# otherwise have published for a state file it could not read. An install older
# than the verb answers 1 from its unknown-command arm, and a caller reading
# either as "none stands" would tell a lane that has already written its record
# to write it again at every turn end.
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

# One call: its status and every line it printed, newlines shown as `|`.
standing() { # ITEM
  local out rc=0
  out="$("$WS" --state-dir "$STATE" handoff-standing "$1" 2>"$TMP_ROOT/err")" || rc=$?
  printf 'rc=%s out=%s' "$rc" "${out//$'\n'/|}"
}

# The verdict line's key, spelled once for every row below.
VERDICT='workflow-state: handoff-standing'

echo "=== workflow-state handoff-standing ==="

assert_eq "$(standing KEN-1)" "rc=0 out=$VERDICT=none" \
  "an item with no state file has no record standing"

"$WS" --state-dir "$STATE" init KEN-1 > /dev/null
assert_eq "$(standing KEN-1)" "rc=0 out=$VERDICT=none" \
  "an item whose state carries no handoff has none standing"

RECORD='{"written_at":"2026-09-18T08:05:00Z","merged":[],"remaining":["submit-pr"],"branch":"b","worktree":"w","open_pr":null,"traps":[]}'
"$WS" --state-dir "$STATE" set KEN-1 handoff "$RECORD" > /dev/null
assert_eq "$(standing KEN-1)" "rc=0 out=$VERDICT=stands|$RECORD" \
  "a record no relaunch has resumed stands, and is printed under the verdict as it was written"

"$WS" --state-dir "$STATE" set-now KEN-1 handoff.resumed_at > /dev/null
assert_eq "$(standing KEN-1)" "rc=0 out=$VERDICT=none" \
  "a record a relaunch stamped resumed_at on belongs to an earlier life"

# A handoff that is not an object is not a record: the shape is part of the
# test, so a field set to a string or a number never reads as one. `set`
# refuses to write one, so the state is built through `update` here, which is
# the shape a hand edit or an install older than that refusal leaves behind.
"$WS" --state-dir "$STATE" init KEN-2 > /dev/null
"$WS" --state-dir "$STATE" update KEN-2 '.handoff = "pending"' > /dev/null
assert_eq "$(standing KEN-2)" "rc=0 out=$VERDICT=none" \
  "a handoff field that is not an object is no record"

printf 'not json\n' > "$STATE/workflow-state-KEN-3.json"
assert_eq "$(standing KEN-3)" "rc=0 out=$VERDICT=unreadable" \
  "a state file nothing can parse is a read that failed, never no record"
assert_eq "$("$WS" --state-dir "$STATE" no-such-verb KEN-1 >/dev/null 2>&1; echo "rc=$?")" "rc=1" \
  "the dispatcher answers 1 for a verb it does not know, and writes no verdict line"
assert_eq "$([ -s "$TMP_ROOT/err" ] && echo said || echo silent)" "said" \
  "that failure carries the reader's own words on stderr"

# The class the verdict line closes. Every orch script sources the project's
# `.env.local` as shell before its dispatch is reached, so a file the loader
# cannot parse kills the script with a status this verb would otherwise have
# published for a state file it could not read — and on bash 3.2 it kills the
# shell outright. A run that never reached the verb writes no verdict, which is
# what lets a caller tell the two apart at all.
PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT"
git -C "$PROJECT" init -q
printf 'this is ( not shell\n' > "$PROJECT/.env.local"
DEAD_RC=0
DEAD_OUT="$( (cd "$PROJECT" && "$WS" --state-dir "$STATE" handoff-standing KEN-1) \
  2>"$TMP_ROOT/dead.err" )" || DEAD_RC=$?
assert_eq "rc=$([ "$DEAD_RC" -ne 0 ] && echo nonzero || echo 0) verdict=$(grep -cF -- "$VERDICT" <<<"$DEAD_OUT" || true) said=$([ -s "$TMP_ROOT/dead.err" ] && echo said || echo silent)" \
  "rc=nonzero verdict=0 said=said" \
  "a settings file the loader cannot parse stops the script before the verb, and writes no verdict for a caller to read"

# Every verdict the verb can publish, read out of its own call sites rather
# than from a second list here, and each one spelled in the help its callers
# read. A count of zero below means this extractor is broken, not the script.
VERDICTS="$(grep -o 'handoff_verdict [a-z][a-z]*' "$WS" | awk '{ print $2 }' | sort -u)"
assert_eq "$([ -n "$VERDICTS" ] && echo found || echo none)" "found" \
  "the extractor reads the verdict call sites out of the script"
HELP="$("$WS" --help)"
MISSING=""
for word in $VERDICTS; do
  grep -qF -- "$VERDICT=$word" <<<"$HELP" || MISSING="$MISSING,$word"
done
assert_eq "missing=${MISSING#,}" "missing=" \
  "every verdict the verb publishes is spelled in the help its callers read"

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
