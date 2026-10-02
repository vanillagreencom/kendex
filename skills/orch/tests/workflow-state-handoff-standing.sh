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
TMP_ROOT="$(mktemp -d)" || { echo "workflow-state-handoff-standing: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "workflow-state-handoff-standing: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "workflow-state-handoff-standing: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
STATE="$TMP_ROOT/state"
mkdir -p "$STATE"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
# mutant_scripts and mutate_file, for the controls below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

# One call: its status and every line it printed, newlines shown as `|`.
standing() { # ITEM
  local out rc=0
  out="$("$WS" --state-dir "$STATE" handoff-standing "$1" 2>"$TMP_ROOT/err")" || rc=$?
  printf 'rc=%s out=%s' "$rc" "${out//$'\n'/|}"
}

# The verdict line's key, spelled once for every row below.
VERDICT='workflow-state: handoff-standing'

echo "=== workflow-state handoff-standing ==="

assert_eq "$(standing KEN-1)" "rc=0 out=$VERDICT=none file=$STATE/workflow-state-KEN-1.json" \
  "an item with no state file has no record standing"

"$WS" --state-dir "$STATE" init KEN-1 > /dev/null
assert_eq "$(standing KEN-1)" "rc=0 out=$VERDICT=none file=$STATE/workflow-state-KEN-1.json" \
  "an item whose state carries no handoff has none standing"

RECORD='{"written_at":"2026-09-18T08:05:00Z","merged":[],"remaining":["submit-pr"],"branch":"b","worktree":"w","open_pr":null,"traps":[]}'
"$WS" --state-dir "$STATE" set KEN-1 handoff "$RECORD" > /dev/null
assert_eq "$(standing KEN-1)" "rc=0 out=$VERDICT=stands file=$STATE/workflow-state-KEN-1.json|$RECORD" \
  "a record no relaunch has resumed stands, and is printed under the verdict as it was written"

"$WS" --state-dir "$STATE" set-now KEN-1 handoff.resumed_at > /dev/null
assert_eq "$(standing KEN-1)" "rc=0 out=$VERDICT=none file=$STATE/workflow-state-KEN-1.json" \
  "a record a relaunch stamped resumed_at on belongs to an earlier life"

# A handoff that is not an object is not a record: the shape is part of the
# test, so a field set to a string or a number never reads as one. `set`
# refuses to write one, so the state is built through `update` here, which is
# the shape a hand edit or an install older than that refusal leaves behind.
"$WS" --state-dir "$STATE" init KEN-2 > /dev/null
"$WS" --state-dir "$STATE" update KEN-2 '.handoff = "pending"' > /dev/null
assert_eq "$(standing KEN-2)" "rc=0 out=$VERDICT=none file=$STATE/workflow-state-KEN-2.json" \
  "a handoff field that is not an object is no record"

printf 'not json\n' > "$STATE/workflow-state-KEN-3.json"
assert_eq "$(standing KEN-3)" "rc=0 out=$VERDICT=unreadable file=$STATE/workflow-state-KEN-3.json" \
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

# The second place: a lane whose launch forbids writing the main checkout keeps
# its state in its worktree's tmp, which the verb reads after the rule's
# directory, by default from a linked worktree naming no --state-dir and from
# anywhere naming --worktree. Each row: where the verb runs, the rule's file
# content and the worktree file's ("-" for none), the argv after the script,
# and the verdict line, MAIN and WT standing for the two state files.
MAIN_CO="$TMP_ROOT/main" WT_CO="$TMP_ROOT/wt"
git init -q "$MAIN_CO"
git -C "$MAIN_CO" config gc.auto 0
git -C "$MAIN_CO" config maintenance.auto false
git -C "$MAIN_CO" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
git -C "$MAIN_CO" worktree add -q -b wt "$WT_CO"
MAIN_FILE="$MAIN_CO/tmp/workflow-state-KEN-9.json" WT_FILE="$WT_CO/tmp/workflow-state-KEN-9.json"
mkdir -p "$MAIN_CO/tmp" "$WT_CO/tmp"
HELD='{"handoff":{"remaining":["x"]}}' SPENT='{"handoff":{"remaining":["x"],"resumed_at":1}}'
place() { # FILE CONTENT
  if [[ "$2" == - ]]; then rm -f -- "$1"; else printf '%s\n' "$2" > "$1"; fi
}
# The first line WS prints run from DIR with the two files placed, its stderr
# in TWO_ERR.
TWO_ERR="$TMP_ROOT/two.err"
two_places() { # WS DIR MAIN WT ARGS...
  local ws="$1" dir="$2" out rc=0
  place "$MAIN_FILE" "$3"
  place "$WT_FILE" "$4"
  shift 4
  out="$(cd "$dir" && env -u ORCH_STATE_DIR "$ws" "$@" 2>"$TWO_ERR")" || rc=$?
  printf 'rc=%s %s' "$rc" "$(two_paths "${out%%$'\n'*}")"
}
two_paths() { # LINE — MAIN and WT for the two state files
  local line="${1//$MAIN_FILE/MAIN}"
  printf '%s' "${line//$WT_FILE/WT}"
}
# The first keyed line of the last run's stderr; jq's own words go unkeyed.
two_err() { two_paths "$(sed -n '/^workflow-state: /{p;q;}' "$TWO_ERR")"; }
while IFS='|' read -r dir main wt args want label; do
  args="${args//@WT/$WT_CO}"
  # shellcheck disable=SC2086 # the argv column is a word list
  assert_eq "$(two_places "$WS" "${dir/#wt/$WT_CO}" "$main" "$wt" ${args//@MT/$MAIN_CO/tmp})" "$want" "two places: $label"
done <<EOF
$MAIN_CO|-|-|handoff-standing KEN-9|rc=0 $VERDICT=none file=MAIN|the main checkout reads the rule's directory alone
wt|-|$HELD|handoff-standing KEN-9|rc=0 $VERDICT=stands file=WT|a linked worktree reads its own tmp after the rule's
$MAIN_CO|-|$HELD|handoff-standing KEN-9|rc=0 $VERDICT=none file=MAIN|the main checkout names no worktree
$MAIN_CO|-|$HELD|handoff-standing KEN-9 --worktree @WT|rc=0 $VERDICT=stands file=WT|--worktree names the lane root from anywhere
wt|-|$HELD|--state-dir @MT handoff-standing KEN-9|rc=0 $VERDICT=none file=MAIN|a named --state-dir is the one place read
wt|$HELD|$HELD|handoff-standing KEN-9|rc=0 $VERDICT=stands file=MAIN|the rule's directory answers first
wt|{|$HELD|handoff-standing KEN-9|rc=0 $VERDICT=stands file=WT|a record in the worktree stands past a rule's file that failed
wt|{|-|handoff-standing KEN-9|rc=0 $VERDICT=unreadable file=MAIN|with none standing the rule's failure is the answer
wt|$SPENT|{|handoff-standing KEN-9|rc=0 $VERDICT=unreadable file=WT|and the worktree's failure where the rule's file read
wt|-|$SPENT|handoff-standing KEN-9|rc=0 $VERDICT=none file=WT|none names the one place holding the state file
wt|-|-|handoff-standing KEN-9 --worktree|rc=2 |--worktree with no root is refused
EOF

# The resume stamp spends the record in every place it stands.
assert_eq "$(two_places "$WS" "$WT_CO" "$HELD" "$HELD" handoff-resume KEN-9; printf ' main=%s wt=%s' \
  "$(jq -r '.handoff.resumed_at | type' "$MAIN_FILE")" "$(jq -r '.handoff.resumed_at | type' "$WT_FILE")")" \
  "rc=0 workflow-state: handoff-resumed file=MAIN main=number wt=number" \
  "handoff-resume stamps the record in both places it stands"
SPENT_ANSWER="$(cd "$WT_CO" && env -u ORCH_STATE_DIR "$WS" handoff-standing KEN-9 2>/dev/null)"
assert_eq "${SPENT_ANSWER%%$'\n'*}" "$VERDICT=none file=$MAIN_FILE" \
  "after the stamp no place keeps a record standing"
assert_eq "$(two_places "$WS" "$WT_CO" - "$SPENT" handoff-resume KEN-9) err=$(two_err)" \
  "rc=1  err=workflow-state: handoff-none issue=KEN-9" \
  "handoff-resume with none standing exits 1 and stamps nothing"
# A place it cannot read: the record standing elsewhere is stamped, and the
# failed place is named with exit 1. RESUME is the script under test.
resume_unread() { # RESUME
  printf '%s err=%s main=%s' "$(two_places "$1" "$WT_CO" "$HELD" "{" handoff-resume KEN-9)" "$(two_err)" \
    "$(jq -r '.handoff.resumed_at | type' "$MAIN_FILE")"
}
assert_eq "$(resume_unread "$WS")" \
  "rc=1 workflow-state: handoff-resumed file=MAIN err=workflow-state: handoff-unread state-file=WT main=number" \
  "handoff-resume stamps the record that stands and names the place it could not read"

# Controls. The worktree place dropped: a lane's record in its worktree's tmp
# reads as none.
PLACE_MUTANT="$(mutant_scripts place-mutant workflow-state)/workflow-state" || exit 1
mutate_file "$PLACE_MUTANT" '[[ "$worktree_file" == "${HANDOFF_FILES[0]}" ]] || HANDOFF_FILES+=("$worktree_file")' ':'
assert_eq "$(two_places "$PLACE_MUTANT" "$WT_CO" - "$HELD" handoff-standing KEN-9)" "rc=0 $VERDICT=none file=MAIN" \
  "control: without the worktree place a record standing there reads as none"
# The stamp written under the rule's directory: the worktree record stays.
STAMP_MUTANT="$(mutant_scripts stamp-mutant workflow-state)/workflow-state" || exit 1
mutate_file "$STAMP_MUTANT" '( STATE_DIR="${file%/*}"; cmd_set_now' '( cmd_set_now'
two_places "$STAMP_MUTANT" "$WT_CO" "{}" "$HELD" handoff-resume KEN-9 >/dev/null
assert_eq "$(jq -c '.handoff.resumed_at' "$WT_FILE")" "null" \
  "control: a stamp written under the rule's directory leaves the worktree record standing"

# The resume's unreadable place passed over: it exits 0 with that place unread.
UNREAD_MUTANT="$(mutant_scripts unread-mutant workflow-state)/workflow-state" || exit 1
mutate_file "$UNREAD_MUTANT" $'stamped=1 ;;\n            unreadable) [[ -n "$unread" ]] || unread="$file" ;;' $'stamped=1 ;;\n            unreadable) : ;;'
assert_eq "$(resume_unread "$UNREAD_MUTANT")" \
  "rc=0 workflow-state: handoff-resumed file=MAIN err= main=number" \
  "control: a resume passing over an unreadable place exits 0 and names none"

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
