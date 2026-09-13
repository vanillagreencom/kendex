#!/usr/bin/env bash
# lane-mail: the lane-to-overseer mailbox CLI.
#
# Each case builds a lane worktree under TMP_ROOT, drives the real script
# against it, and asserts stdout, the mailbox files and the keyed first line of
# any refusal. The hosted cases drive tests/fixtures/lane-host in its
# directory-backed mode, so `send` and `drain` cross the same `cat` and `put`
# the fleet's transport gives them.
#
# The must-fail controls sit at the end, one per surface this suite asserts:
# a reader that consumes a partial last line, an inbox that does not advance
# its cursor, and a drain that ignores the answers to-lane.jsonl already holds.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

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

# A fresh lane worktree: a git repository with the orch scripts linked in
# where a lane's own `.agents` tree holds them, so `--host` resolves the same
# `lane-host` a lane would run.
LANE=""
new_lane() { # NAME
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE/.agents/skills/orch"
  git -C "$LANE" init -q -b ken-1 2>/dev/null || {
    mkdir -p "$LANE"; git -C "$LANE" init -q; git -C "$LANE" checkout -q -b ken-1
  }
  ln -sfn "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
}

RC=0
OUT=""
ERR=""
lm() { # ARGS...
  RC=0
  OUT="$(cd "$LANE" && "${LANE_MAIL_BIN:-$LANE_MAIL}" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(head -n 1 "$TMP_ROOT/err")"
}

text() { # NAME CONTENT
  printf '%s\n' "$2" > "$TMP_ROOT/$1.txt"
  printf '%s' "$TMP_ROOT/$1.txt"
}

echo "=== lane-mail ==="

# --- envelope shape -----------------------------------------------------
new_lane envelope
lm ask --item KEN-1 --file "$(text q 'Cut the scanner?')" --options cut,keep
assert_eq "$RC" "0" "ask exits 0"
ID="${OUT#id=}"
assert_eq "${OUT%%=*}" "id" "ask prints the id it appended"
BOX="$LANE/tmp/lane-mail/KEN-1"
SHAPE="$(jq -cS 'to_entries | map(.key) | sort | join(",")' < "$BOX/to-overseer.jsonl")"
assert_eq "$SHAPE" '"at,id,kind,options,text"' "an ask carries id, kind, at, text and its options"
assert_eq "$(jq -r '.kind + " " + .text + " " + (.options | join("/"))' < "$BOX/to-overseer.jsonl")" \
  "ask Cut the scanner? cut/keep" "the ask holds its kind, its text without the trailing newline, and its choices"
assert_eq "$(jq -r '.id' < "$BOX/to-overseer.jsonl")" "$ID" "the printed id is the appended envelope's"
assert_eq "$(jq -r '.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' < "$BOX/to-overseer.jsonl")" \
  "true" "the envelope stamps a UTC time"

lm notice --item KEN-1 --file "$(text n 'Rebased onto main.')"
assert_eq "$RC=$OUT" "0=" "notice exits 0 and prints nothing"
assert_eq "$(jq -rs '.[1] | .kind + " " + (has("options") | tostring)' < "$BOX/to-overseer.jsonl")" \
  "notice false" "a notice carries no options"
lm notice --item KEN-1 --file "$(text n 'x')" --options a,b
assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=--options" "a notice refuses choices rather than dropping them"

# --- wait ---------------------------------------------------------------
new_lane wait
lm ask --item KEN-1 --file "$(text q 'Merge now?')"
MINE="${OUT#id=}"
lm send --item KEN-1 --root "$LANE" --re other-ask --file "$(text a 'Not yours.')"
assert_eq "$RC" "0" "send answers an ask by id"
lm wait --item KEN-1 --id "$MINE" --timeout 1 --interval 1
assert_eq "$RC=$ERR" "124=lane-mail: timeout=$MINE" "wait ignores an answer to another ask and exits 124 at its timeout"
lm send --item KEN-1 --root "$LANE" --re "$MINE" --file "$(text a 'Merge it.')"
lm wait --item KEN-1 --id "$MINE" --timeout 5 --interval 1
assert_eq "$RC=$OUT" "0=Merge it." "wait returns the answer that names its own ask"

# --- inbox --------------------------------------------------------------
new_lane inbox
lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
lm inbox --item KEN-1
assert_eq "$(jq -r '.kind + " " + .text' <<<"$OUT")" "directive Hold the PR." "inbox hands over an unread directive"
assert_eq "$(cat "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor")" "1" "inbox advances the cursor past what it handed over"
lm inbox --item KEN-1
assert_eq "$RC=$OUT" "0=" "a second inbox re-reads nothing"
lm send --item KEN-1 --root "$LANE" --re some-ask --file "$(text a 'Answered.')"
lm inbox --item KEN-1
assert_eq "$RC=$OUT" "0=" "an answer belongs to the wait that asked for it, never to the inbox"
assert_eq "$(cat "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor")" "2" "the cursor still passes the answer it did not hand over"

# --- concurrent senders -------------------------------------------------
new_lane concurrent
printf 'parallel\n' > "$TMP_ROOT/p.txt"
for i in 1 2 3 4 5 6 7 8; do
  (cd "$LANE" && "$LANE_MAIL" notice --item KEN-1 --file "$TMP_ROOT/p.txt") &
done
wait
BOX="$LANE/tmp/lane-mail/KEN-1"
assert_eq "$(awk 'END { print NR }' < "$BOX/to-overseer.jsonl")" "8" "eight parallel writers leave eight lines"
assert_eq "$(jq -c -R '(fromjson? // empty) | select(type == "object")' < "$BOX/to-overseer.jsonl" | awk 'END { print NR }')" \
  "8" "every line a parallel writer left parses"
lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(head -n 1 <<<"$OUT")" "count=8" "drain counts every line the parallel writers left"

# --- a partial last line ------------------------------------------------
new_lane partial
lm notice --item KEN-1 --file "$(text n 'whole')"
BOX="$LANE/tmp/lane-mail/KEN-1"
printf '{"id":"half","kind":"notice","at":"t","text":"trunc' >> "$BOX/to-overseer.jsonl"
lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(head -n 1 <<<"$OUT")" "count=1" "a partial last line is not counted"
assert_eq "$(tail -n +2 <<<"$OUT" | jq -r '.text')" "whole" "a partial last line is left unread"
printf '"}\n' >> "$BOX/to-overseer.jsonl"
lm drain --item KEN-1 --root "$LANE" --after 1
assert_eq "$(tail -n +2 <<<"$OUT" | jq -r '.id')" "half" "the line reads once its writer finishes it"

# --- a restarted overseer -----------------------------------------------
new_lane restart
lm ask --item KEN-1 --file "$(text q 'first')"
FIRST="${OUT#id=}"
lm ask --item KEN-1 --file "$(text q 'second')"
lm drain --item KEN-1 --root "$LANE" --after 0
SAVED="$(head -n 1 <<<"$OUT")"
SAVED="${SAVED#count=}"
assert_eq "$SAVED" "2" "the first drain reports the count a receiver saves"
lm ask --item KEN-1 --file "$(text q 'third')"
lm drain --item KEN-1 --root "$LANE" --after "$SAVED"
assert_eq "$(tail -n +2 <<<"$OUT" | jq -rs 'map(.text) | join(",")')" "third" \
  "a drain from the saved cursor loses nothing and duplicates nothing"
lm send --item KEN-1 --root "$LANE" --re "$FIRST" --file "$(text a 'done')"
lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(tail -n +2 <<<"$OUT" | jq -rs 'map(.text) | join(",")')" "second,third" \
  "a drain skips an ask to-lane.jsonl already answers"
lm pending --item KEN-1 --root "$LANE"
assert_eq "$(jq -rs 'map(.text) | join(",")' <<<"$OUT")" "second,third" \
  "pending lists every unanswered ask and no notice"
lm notice --item KEN-1 --file "$(text n 'fyi')"
lm pending --item KEN-1 --root "$LANE"
assert_eq "$(jq -rs 'map(.kind) | unique | join(",")' <<<"$OUT")" "ask" "pending lists asks alone"

# --- refusals -----------------------------------------------------------
new_lane refusals
lm ask --item ../escape --file "$(text q 'x')"
assert_eq "$RC=$ERR" "2=lane-mail: item-invalid=../escape" "an item outside its alphabet never reaches a path"
lm ask --item KEN-1 --file "$TMP_ROOT/absent.txt"
assert_eq "$RC=$ERR" "2=lane-mail: file-unreadable=$TMP_ROOT/absent.txt" "an unreadable message file is refused"
lm ask --item KEN-1
assert_eq "$RC=$ERR" "2=lane-mail: option-required=--file" "ask requires its message file"
lm wait --item KEN-1
assert_eq "$RC=$ERR" "2=lane-mail: option-required=--id" "wait requires the ask it waits on"
lm drain --item KEN-1 --root "$LANE"
assert_eq "$RC=$ERR" "2=lane-mail: after-invalid=<unset>" "drain requires the cursor it reads from"
lm send --item KEN-1 --root "$LANE" --re x --directive --file "$(text a 'x')"
assert_eq "$RC=$ERR" "2=lane-mail: option-conflict=--re,--directive" "a send is an answer or a directive, never both"
lm drain --item KEN-1 --host --after 0
assert_eq "$RC=$ERR" "2=lane-mail: option-required=--root" "a hosted read needs the lane's own root"
lm summon --item KEN-1
assert_eq "$RC=$ERR" "2=lane-mail: verb-invalid=summon" "an unknown command is refused"
new_lane unreadable
lm notice --item KEN-1 --file "$(text n 'x')"
chmod 000 "$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl"
lm drain --item KEN-1 --root "$LANE" --after 0
chmod 644 "$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl"
assert_eq "$RC=$ERR" "2=lane-mail: file-unreadable=$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl" \
  "a mailbox that cannot be read is refused, never reported as empty"

# --- hosted send and drain ----------------------------------------------
# The fixture's directory-backed mode is the remote filesystem; the remote root
# is a path that exists nowhere on this disk, so a case that silently fell back
# to the local root would read an empty mailbox instead.
new_lane hosted
REMOTE_ROOT=/srv/lane/ken-1
REMOTE_DISK="$TMP_ROOT/remote"
mkdir -p "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-1"
printf '{"id":"remote-ask","kind":"ask","at":"t","text":"Hosted question"}\n' \
  > "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-1/to-overseer.jsonl"
STUB_LOG="$TMP_ROOT/host.log"
: > "$STUB_LOG"
host_lm() { # ARGS...
  RC=0
  OUT="$(cd "$LANE" && env ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$STUB_LOG" LANE_HOST_STUB_DIR="$REMOTE_DISK" \
    "$LANE_MAIL" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(head -n 1 "$TMP_ROOT/err")"
}
host_lm drain --item KEN-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$(head -n 1 <<<"$OUT")" "0=count=1" "a hosted drain counts the remote mailbox"
assert_eq "$(tail -n +2 <<<"$OUT" | jq -r '.text')" "Hosted question" "a hosted drain reads the lane's own host"
assert_eq "$(grep -c -- "$REMOTE_ROOT/tmp/lane-mail/KEN-1/to-overseer.jsonl" "$STUB_LOG")" "1" \
  "the hosted read names the remote path in the transport's call log"
host_lm send --item KEN-1 --root "$REMOTE_ROOT" --host --re remote-ask --file "$(text a 'Hosted answer.')"
assert_eq "$RC" "0" "a hosted send exits 0"
assert_eq "$(jq -r '.text' < "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-1/to-lane.jsonl")" \
  "Hosted answer." "a hosted send writes through the transport to the remote mailbox"
host_lm drain --item KEN-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$(tail -n +2 <<<"$OUT")" "" "a hosted drain skips the ask its hosted answer already answers"
assert_eq "$(grep -c -- "put --item KEN-1" "$STUB_LOG")" "1" "the hosted send crosses lane-host put once"
# A host that answers and a mailbox that is not there yet is an empty read; a
# host that does not answer is refused, since the transport reports one status
# for both and a silent lane is not the safe reading.
host_lm drain --item KEN-2 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$(head -n 1 <<<"$OUT")" "0=count=0" "a hosted lane that has not opened its mailbox reads empty"
RC=0
OUT="$(cd "$LANE" && env ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_LOG" \
  LANE_HOST_STUB_DIR="$REMOTE_DISK" LANE_HOST_STUB_STATUS=4 \
  "$LANE_MAIL" drain --item KEN-2 --root "$REMOTE_ROOT" --host --after 0 2>"$TMP_ROOT/err")" || RC=$?
assert_eq "$RC=$(head -n 1 "$TMP_ROOT/err")" "2=lane-mail: host-unreachable=KEN-2" \
  "a host that cannot be reached is refused rather than read as an empty mailbox"

# --- must-fail controls -------------------------------------------------
# One per surface: the partial-line rule, the inbox cursor, and the
# already-answered filter. Each mutant keeps the matched text and removes the
# behaviour, and each is proved to differ from the script it was cut from.
MUTANT_DIR="$TMP_ROOT/mutants"
mkdir -p "$MUTANT_DIR"
# lane-mail resolves its lock library and the transport beside itself, so a
# mutant copy keeps orch's scripts directory around it; without them the copy
# would die on its own layout and every control would read as a silent pass.
ln -sfn "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
ln -sfn "$REPO_ROOT/skills/orch/scripts/lane-host" "$MUTANT_DIR/lane-host"
mutant() { # NAME SED-EXPRESSION
  sed "$2" "$LANE_MAIL" > "$MUTANT_DIR/$1"
  chmod +x "$MUTANT_DIR/$1"
  assert_eq "$(cmp -s "$MUTANT_DIR/$1" "$LANE_MAIL" && echo same || echo differs)" "differs" \
    "control: the $1 mutant really differs from lane-mail"
  LANE_MAIL_BIN="$MUTANT_DIR/$1"
}

mutant partial-consumed 's@if \[ "\$last" = "\$NL"x \]; then@if [ x = x ]; then@'
new_lane control_partial
LANE_MAIL_BIN="$LANE_MAIL" lm notice --item KEN-1 --file "$(text n 'whole')"
LANE_MAIL_BIN="$LANE_MAIL" lm ask --item KEN-1 --file "$(text q 'q')" >/dev/null
printf '{"id":"half","kind":"notice","at":"t","text":"trunc' \
  >> "$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl"
LANE_MAIL_BIN="$MUTANT_DIR/partial-consumed" lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(head -n 1 <<<"$OUT")" "count=3" \
  "control: without the terminated-prefix rule the half-written line is counted as read"

mutant inbox-cursor-frozen 's@^    mv -- "\$WORK_DIR/cursor" "\$CURSOR".*@    rm -f -- "$WORK_DIR/cursor"@'
new_lane control_cursor
LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'twice')"
LANE_MAIL_BIN="$MUTANT_DIR/inbox-cursor-frozen" lm inbox --item KEN-1
assert_eq "$(jq -r '.text' <<<"$OUT")" "twice" "control: the frozen-cursor mutant still hands the line over once"
LANE_MAIL_BIN="$MUTANT_DIR/inbox-cursor-frozen" lm inbox --item KEN-1
assert_eq "$(jq -r '.text' <<<"$OUT")" "twice" \
  "control: without the cursor advance a second inbox hands the same line over again"

mutant answered-ignored 's@index(\$envelope\.id)@index("no-such-id")@'
new_lane control_answered
LANE_MAIL_BIN="$LANE_MAIL" lm ask --item KEN-1 --file "$(text q 'settled')"
SETTLED="${OUT#id=}"
LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --re "$SETTLED" --file "$(text a 'yes')"
LANE_MAIL_BIN="$LANE_MAIL" lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(tail -n +2 <<<"$OUT")" "" "control: the real drain drops the settled ask"
LANE_MAIL_BIN="$MUTANT_DIR/answered-ignored" lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(tail -n +2 <<<"$OUT" | jq -r '.text')" "settled" \
  "control: without the answered filter a settled ask is reported again"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
