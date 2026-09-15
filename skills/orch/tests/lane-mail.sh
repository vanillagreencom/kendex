#!/usr/bin/env bash
# lane-mail: the lane-to-overseer mailbox CLI. Each case builds a lane
# worktree under TMP_ROOT, drives the real script, and asserts stdout, the
# mailbox files and the keyed first line of any refusal; the hosted cases cross
# tests/fixtures/lane-host in its directory-backed mode. The peer cases build a
# second checkout, the overseer of another repository. The must-fail controls
# close the file, one per surface: the partial last line, the inbox cursor,
# inbox --after, the already-answered drain filter, the ownership rule, the
# overseer inbox's answer exception and the one-spelling rule.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

# Whether this world can hold two names differing only in case. On a
# case-insensitive filesystem, every macOS default one, the second name is the
# first directory, so neither the split mailbox nor its refusal can be built.
mkdir -p "$TMP_ROOT/case-probe/A"
CASE_SENSITIVE=1
[ ! -d "$TMP_ROOT/case-probe/a" ] || CASE_SENSITIVE=0

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

# A fresh lane worktree: the orch scripts where a lane's own `.agents` tree
# holds them, so `--host` resolves the same `lane-host` a lane would run.
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

# The count field of the header drain and inbox --after open with; the header's
# first= field has its own row.
count_line() {
  local header
  header="$(head -n 1 <<<"$OUT")"
  printf '%s' "${header%% first=*}"
}

text() { # NAME CONTENT
  printf '%s\n' "$2" > "$TMP_ROOT/$1.txt"
  printf '%s' "$TMP_ROOT/$1.txt"
}

echo "=== lane-mail ==="

new_lane envelope
lm ask --item KEN-1 --file "$(text q 'Cut the scanner?')" --options cut,keep
assert_eq "$RC" "0" "ask exits 0"
ID="${OUT#id=}"
assert_eq "${OUT%%=*}" "id" "ask prints the id it appended"
BOX="$LANE/tmp/lane-mail/KEN-1"
SHAPE="$(jq -cS 'to_entries | map(.key) | sort | join(",")' < "$BOX/to-overseer.jsonl")"
assert_eq "$SHAPE" '"at,from,id,kind,options,text"' "an ask carries id, kind, at, from, text and its options"
assert_eq "$(jq -r '.from' < "$BOX/to-overseer.jsonl")" "KEN-1" "a lane verb sends as its own item"
assert_eq "$(jq -r '.kind + " " + .text + " " + (.options | join("/"))' < "$BOX/to-overseer.jsonl")" \
  "ask Cut the scanner? cut/keep" "the ask holds its kind, its text without the trailing newline, and its choices"
assert_eq "$(jq -r '.id' < "$BOX/to-overseer.jsonl")" "$ID" "the printed id is the appended envelope's"
assert_eq "$(jq -r '.at | test("^[0-9-]{10}T[0-9:]{8}Z$")' < "$BOX/to-overseer.jsonl")" "true" "the envelope stamps a UTC time"

lm notice --item KEN-1 --file "$(text n 'Rebased onto main.')"
assert_eq "$RC=$OUT" "0=" "notice exits 0 and prints nothing"
assert_eq "$(jq -rs '.[1] | .kind + " " + (has("options") | tostring)' < "$BOX/to-overseer.jsonl")" \
  "notice false" "a notice carries no options"
lm notice --item KEN-1 --file "$(text n 'x')" --options a,b
assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=--options" "a notice refuses choices rather than dropping them"

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

# --timeout is a deadline, not a count of intervals: one shorter than the
# interval must not wait the whole interval out.
new_lane wait_deadline
lm ask --item KEN-1 --file "$(text q 'Deadline?')"
DEADLINE_ID="${OUT#id=}"
BEFORE="$(date -u +%s)"
lm wait --item KEN-1 --id "$DEADLINE_ID" --timeout 1 --interval 5
ELAPSED="$(( $(date -u +%s) - BEFORE ))"
assert_eq "$RC=$([ "$ELAPSED" -le 2 ] && echo prompt || printf 'late:%s' "$ELAPSED")" "124=prompt" \
  "a timeout shorter than the interval returns at its deadline"

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

# --after is the caller's own cursor: a file cursor unlike both it and the count
# is neither read nor moved.
after_lane() { # NAME
  new_lane "$1"
  LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'First.')"
  LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Second.')"
  printf '0\n' > "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor"
  cp "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor" "$TMP_ROOT/cursor.before"
  lm inbox --item KEN-1 --after 1
  AFTER_READ="$RC=$(count_line)=$(tail -n +2 <<<"$OUT" | jq -r '.text')"
  CURSOR_KEPT="$(cmp -s "$TMP_ROOT/cursor.before" "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor" && echo kept || echo rewritten)"
}
after_lane inbox_after
assert_eq "$AFTER_READ" "0=count=2=Second." "inbox --after prints the count and only the envelopes after line N"
assert_eq "$CURSOR_KEPT" "kept" "inbox --after leaves the file cursor byte-identical"

# A Stop hook peeks, then a workflow wait point hands a later line over, then
# the hook acknowledges its older count. ACK_CURSOR is what that leaves.
stale_ack() { # NAME
  new_lane "$1"
  LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'First.')"
  LANE_MAIL_BIN="$LANE_MAIL" lm inbox --item KEN-1 --peek
  PEEKED="$(count_line)"
  LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Second.')"
  LANE_MAIL_BIN="$LANE_MAIL" lm inbox --item KEN-1
  lm inbox --item KEN-1 --ack "${PEEKED#count=}"
  ACK_CURSOR="$RC=$(cat "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor")"
}
stale_ack inbox_ack
assert_eq "$PEEKED=$ACK_CURSOR" "count=1=0=2" "an --ack older than the cursor never moves it back"

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
assert_eq "$(count_line)" "count=8" "drain counts every line the parallel writers left"

new_lane partial
lm notice --item KEN-1 --file "$(text n 'whole')"
BOX="$LANE/tmp/lane-mail/KEN-1"
printf '{"id":"half","kind":"notice","at":"t","text":"trunc' >> "$BOX/to-overseer.jsonl"
lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(count_line)" "count=1" "a partial last line is not counted"
assert_eq "$(tail -n +2 <<<"$OUT" | jq -r '.text')" "whole" "a partial last line is left unread"
printf '"}\n' >> "$BOX/to-overseer.jsonl"
lm drain --item KEN-1 --root "$LANE" --after 1
assert_eq "$(tail -n +2 <<<"$OUT" | jq -r '.id')" "half" "the line reads once its writer finishes it"

# A writer killed inside its printf leaves a fragment; the envelope that
# follows must land whole rather than be glued to it.
new_lane interrupted
lm notice --item KEN-1 --file "$(text n 'whole')"
printf '{"id":"half","kind":"notice"' >> "$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl"
lm ask --item KEN-1 --file "$(text q 'after the fragment')"
lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(tail -n +2 <<<"$OUT" | jq -rs 'map(.text) | join(",")')" "whole,after the fragment" \
  "an envelope appended after an interrupted one is read whole"

new_lane restart
lm ask --item KEN-1 --file "$(text q 'first')"
FIRST="${OUT#id=}"
lm ask --item KEN-1 --file "$(text q 'second')"
lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(head -n 1 <<<"$OUT")" "count=2 first=$FIRST" "the drain header names the id the mailbox opens with"
SAVED="$(count_line)"
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

# The peer channel: two repositories, each an overseer of its own. `new_lane`
# builds a checkout under TMP_ROOT, so a peer named by its bare name is the
# sibling layout the resolution assumes.
new_lane peer_b
PEER_B="$LANE"
new_lane peer_a
lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Own lane.')"
assert_eq "$(jq -r '.from' < "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl")" "overseer:peer_a" \
  "an overseer's send to its own lane carries the repository it came from"
lm send --item overseer --directive --file "$(text d 'Owner note.')"
assert_eq "$(jq -r '.from' < "$LANE/tmp/lane-mail/overseer/to-lane.jsonl")" "owner" \
  "a send into the overseer's own mailbox is the owner's"

lm peer ask --repo peer_b --file "$(text q 'Do you own KEN-9?')" --options yes,no
PEER_ASK="${OUT#id=}"
assert_eq "$RC=${OUT%%=*}" "0=id" "peer ask prints the id it appended"
assert_eq "$(jq -r '.id + " " + .from + " " + .kind + " " + .text' < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl")" \
  "$PEER_ASK overseer:peer_a ask Do you own KEN-9?" \
  "peer ask lands in the peer's overseer mailbox under one id, naming the repository that sent it"
lm pending --item overseer
assert_eq "$(jq -r '.id' <<<"$OUT")" "$PEER_ASK" "the asker's own pending owes the peer's answer"

# The peer answers from its own checkout, naming the asker by path.
PEER_A="$LANE"
LANE="$PEER_B"
lm peer send --repo "$PEER_A" --re "$PEER_ASK" --file "$(text a 'It is ours.')"
assert_eq "$RC=$(jq -rs 'map(select(.kind == "answer")) | .[0] | .from + " " + .re + " " + .text' \
  < "$PEER_A/tmp/lane-mail/overseer/to-lane.jsonl")" \
  "0=overseer:peer_b $PEER_ASK It is ours." "peer send --re answers the asker's ask from the peer's own checkout"
LANE="$PEER_A"
lm pending --item overseer
assert_eq "$RC=$OUT" "0=" "the answered peer ask is no longer pending"
lm wait --item overseer --id "$PEER_ASK" --timeout 5 --interval 1
assert_eq "$RC=$OUT" "0=It is ours." "the asker's wait on the overseer mailbox returns the peer's answer"

# An answer in the overseer mailbox has no `wait` to go to: the overseer runs
# its watch, which reads this mailbox with `inbox`.
lm inbox --item overseer
assert_eq "$(jq -rs 'map(.kind) | join(",")' <<<"$OUT")" "directive,answer" \
  "inbox hands the overseer its own note and the peer's answer"
lm send --item KEN-1 --root "$PEER_A" --re some-ask --file "$(text a 'Lane answer.')"
lm inbox --item KEN-1
assert_eq "$RC=$(jq -rs 'map(.kind) | unique | join(",")' <<<"$OUT")" "0=directive" \
  "a lane item's answer still belongs to the wait that asked for it"

lm send --item KEN-1 --root "$PEER_B" --directive --file "$(text d 'Not yours.')"
assert_eq "$RC=$ERR" "2=lane-mail: lane-foreign=$PEER_B" \
  "a send into a lane another repository owns is refused"
assert_eq "$([ -e "$PEER_B/tmp/lane-mail/KEN-1/to-lane.jsonl" ] && echo written || echo untouched)" "untouched" \
  "the refused send leaves the foreign lane's mailbox unwritten"
# The overseer mailbox is judged with the lanes: a --root into another
# repository's overseer mailbox is the cross-repository write `peer` owns.
lm send --item overseer --root "$PEER_B" --directive --file "$(text d 'Not yours either.')"
assert_eq "$RC=$ERR" "2=lane-mail: lane-foreign=$PEER_B" \
  "a send into another repository's overseer mailbox is refused"
assert_eq "$(jq -rs 'map(.text) | join(",")' < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl")" \
  "Do you own KEN-9?" "the refused overseer send left the peer's mailbox holding only the peer ask"

# A peer root is its repository's main checkout. A directory that is no
# checkout would open a mailbox no watch reads, and a path inside a peer would
# open a second one beside it.
lm peer send --repo "$TMP_ROOT" --file "$(text d 'Nowhere.')"
assert_eq "$RC=$ERR" "2=lane-mail: repo-unresolved=$TMP_ROOT" \
  "a peer root that is no checkout is refused"
assert_eq "$([ -e "$TMP_ROOT/tmp/lane-mail" ] && echo written || echo untouched)" "untouched" \
  "the refused peer send opened no mailbox under it"
lm peer send --repo "$PEER_B/.agents/skills/orch" --file "$(text d 'Inside the peer.')"
assert_eq "$RC=$(jq -rs 'map(.text) | last' < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl")" \
  "0=Inside the peer." "a path inside a peer resolves to that peer's main checkout"

# A delivered ask the caller cannot wait on is the failure the id closes: the
# peer holds it, so the id it was given is the only way back to the answer.
chmod 000 "$PEER_A/tmp/lane-mail/overseer/to-overseer.jsonl"
lm peer ask --repo peer_b --file "$(text q 'Recorded nowhere?')"
UNRECORDED="$RC=${OUT%%=*}"
chmod 644 "$PEER_A/tmp/lane-mail/overseer/to-overseer.jsonl"
assert_eq "$UNRECORDED" "2=id" "a peer ask whose own record fails still prints the id the peer now holds"
assert_eq "$(jq -rs 'map(.text) | last' < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl")" \
  "Recorded nowhere?" "and the peer holds the ask that record was for"

# The repository name is the identity every peer message carries, and TOML
# spells a string two ways. A value in neither spelling falls through to the
# origin URL rather than reaching that identity mangled.
peer_name() { # TOML-VALUE TEXT -> the from the peer received
  printf '[marketplace]\nname = %s\n' "$1" > "$PEER_A/kendex.toml"
  lm peer send --repo peer_b --file "$(text d "$2")"
  rm -f -- "${PEER_A:?}/kendex.toml"
  jq -rs 'map(.from) | last' < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl"
}
assert_eq "$(peer_name "'quoted-peer'" 'Literal string.')" "overseer:quoted-peer" \
  "a literal-string name is read as written"
assert_eq "$(peer_name '"basic-peer"' 'Basic string.')" "overseer:basic-peer" \
  "a basic-string name is read as written"
assert_eq "$(peer_name 'bare-peer' 'Neither spelling.')" "overseer:peer_a" \
  "a value in neither spelling falls through rather than arriving mangled"

# Shaped input: every lane option a peer verb does not take, refused under the
# spelling the caller typed rather than dropped.
for row in "--after 5" "--peek" "--ack 1" "--timeout 3" "--interval 2" "--id abc" "--item KEN-1" "--root $PEER_B" "--directive"; do
  # shellcheck disable=SC2086
  lm peer send --repo peer_b $row --file "$(text d 'x')"
  assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=${row%% *}" \
    "peer send refuses ${row%% *}, the spelling the caller typed"
done
lm peer ask --repo peer_b --re some-id --file "$(text q 'x')"
assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=--re" "peer ask refuses --re, which only peer send takes"
lm peer send --repo peer_b --options a,b --file "$(text d 'x')"
assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=--options" "peer send refuses choices, which only peer ask takes"

# With no own root there is nowhere correct for the caller's record or for a
# bare --repo name, so a peer verb refuses before it writes either. The row
# asserts its own premise: a cwd git claims would make it vacuous.
NOGIT="$TMP_ROOT/nogit"
mkdir -p "$NOGIT"
NOGIT_STATE="$(git -C "$NOGIT" rev-parse --show-toplevel 2>/dev/null && echo in-a-repo || echo outside-any-repo)"
LANE="$NOGIT"
lm peer ask --repo "$PEER_B" --file "$(text q 'From nowhere.')"
assert_eq "$NOGIT_STATE=$RC=$ERR" "outside-any-repo=2=lane-mail: root-unresolved=." \
  "a peer verb from outside any checkout is refused"
assert_eq "$([ -e "$NOGIT/tmp" ] && echo written || echo untouched)" "untouched" \
  "and writes no record beside the directory it ran in"
LANE="$PEER_A"

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

# Every local mailbox component, planted as a symlink or as the wrong kind of
# file, is refused before any verb reads or writes through it. UNSAFE is the
# exit status and keyed line, UNSAFE_PATH the component planted.
unsafe_inbox() { # KIND COMPONENT — relative to tmp/lane-mail, empty for tmp/lane-mail itself
  local mail
  new_lane unsafe
  mail="$LANE/tmp/lane-mail"
  rm -rf -- "${mail:?}" "$TMP_ROOT/away"
  mkdir -p -- "$mail/KEN-1" "$TMP_ROOT/away"
  : > "$TMP_ROOT/away/file"
  UNSAFE_PATH="$mail${2:+/$2}"
  rm -rf -- "${UNSAFE_PATH:?}"
  case "$1:$2" in
    link: | link:KEN-1) ln -s "$TMP_ROOT/away" "$UNSAFE_PATH" ;;
    link:*) ln -s "$TMP_ROOT/away/file" "$UNSAFE_PATH" ;;
    kind:KEN-1) : > "$UNSAFE_PATH" ;;
    kind:*) mkdir -- "$UNSAFE_PATH" ;;
  esac
  lm inbox --item KEN-1 --root "$LANE"
  UNSAFE="$RC=$ERR"
}
for row in link: link:KEN-1 link:KEN-1/to-overseer.jsonl link:KEN-1/to-lane.jsonl link:KEN-1/to-lane.cursor \
  link:KEN-1/to-lane.cursor.lock kind:KEN-1 kind:KEN-1/to-lane.jsonl; do
  component="${row#*:}"
  unsafe_inbox "${row%%:*}" "$component"
  assert_eq "$UNSAFE" "2=lane-mail: mailbox-unsafe=$UNSAFE_PATH" \
    "a ${row%%:*} planted at tmp/lane-mail${component:+/$component} is refused before any read or write"
done
# The inverse: tmp itself linked elsewhere, as a worktree setup may make it.
new_lane tmp_linked
mkdir -p -- "$TMP_ROOT/shared-tmp"
ln -s "$TMP_ROOT/shared-tmp" "$LANE/tmp"
lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Through a linked tmp.')"
lm inbox --item KEN-1 --root "$LANE"
assert_eq "$RC=$(jq -r '.text' <<<"$OUT")" "0=Through a linked tmp." "a tmp directory linked elsewhere still carries the mailbox"

# One spelling per lane, in the two states that decide it. The lane opens its own
# mailbox lower case and the overseer sends to the upper-case name: a send that
# would open the second folder is refused, and a send to a folder already there
# is not, which is how a pair an earlier launcher left is drained and cleared.
# Fields: whether the upper-case folder is planted, the exit and first stderr
# line, the directives that folder then holds, and the row's name. A row plants
# that folder rather than opening it, because opening one is what the tool
# refuses. The count is what the verb decided: a refusal writes none, and a send
# that goes through writes one, into the folder it names rather than the lane's.
if [ "${CASE_SENSITIVE:?}" -eq 1 ]; then
  for row in 'no|2=lane-mail: item-case-variant=KEN-1|0|opening the second spelling is refused' \
    'yes|0=|1|a send to a spelling already there is not refused'; do
    IFS='|' read -r plant want held name <<<"$row"
    new_lane "case_variant_$plant"
    lm notice --item ken-1 --file "$(text lane 'lane side')"
    [ "$plant" = no ] || mkdir -p -- "$LANE/tmp/lane-mail/KEN-1"
    lm send --item KEN-1 --root "$LANE" --directive --file "$(text overseer 'overseer side')"
    COUNT=0
    [ ! -f "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl" ] ||
      COUNT="$(awk 'END { print NR }' < "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl")"
    assert_eq "$RC=$ERR=$COUNT" "$want=$held" "$name"
  done
else
  printf '  skip  the one-spelling rule: this filesystem is case-insensitive, so the second name is the first mailbox\n'
fi

# The remote root exists nowhere on this disk, so a case that silently fell
# back to the local root would read an empty mailbox instead.
new_lane hosted
REMOTE_ROOT=/srv/lane/ken-1
REMOTE_DISK="$TMP_ROOT/remote"
mkdir -p "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-1"
printf '{"id":"remote-ask","kind":"ask","at":"t","text":"Hosted question"}\n' \
  > "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-1/to-overseer.jsonl"
STUB_LOG="$TMP_ROOT/host.log"
: > "$STUB_LOG"
HOST_ENV=()
HOST_BIN=""
host_lm() { # ARGS... — HOST_ENV adds stub knobs, HOST_BIN swaps in a mutant
  RC=0
  OUT="$(cd "$LANE" && env ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_LOG" \
    LANE_HOST_STUB_DIR="$REMOTE_DISK" ${HOST_ENV[@]+"${HOST_ENV[@]}"} \
    "${HOST_BIN:-$LANE_MAIL}" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(head -n 1 "$TMP_ROOT/err")"
  HOST_ENV=(); HOST_BIN=""
}

# A put that dies leaves the previous file standing: the provider stages the
# bytes beside the target and renames only once they have all arrived.
put_survives() { # sets SURVIVED to the text the remote mailbox still holds
  local box="$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-5/to-lane.jsonl"
  mkdir -p "${box%/*}"
  printf '{"id":"kept","kind":"directive","at":"t","text":"kept"}\n' > "$box"
  HOST_ENV=(LANE_HOST_STUB_PUT_FAIL=1)
  host_lm send --item KEN-5 --root "$REMOTE_ROOT" --host --directive --file "$(text d 'new')"
  SURVIVED="$(jq -rs 'map(.text) | join(",")' < "$box" 2>/dev/null)" || SURVIVED=gone
}

# Two writers on one item, the second starting while the first is inside its
# put. BIN is the script both run. The put delay is what makes the overlap a
# fact rather than a hope: it is longer than any startup skew between two
# children of one loop, so without a lock both read the file before either
# writes it.
race_sends() { # ITEM BIN
  local n
  mkdir -p "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/$1"
  : > "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/$1/to-lane.jsonl"
  printf 'first\n' > "$TMP_ROOT/first.txt"
  printf 'second\n' > "$TMP_ROOT/second.txt"
  for n in first second; do
    (cd "$LANE" && env ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_LOG" \
      LANE_HOST_STUB_DIR="$REMOTE_DISK" LANE_HOST_STUB_PUT_DELAY=1 \
      OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/watch-state" \
      "$2" send --item "$1" --root "$REMOTE_ROOT" --host --directive \
      --file "$TMP_ROOT/$n.txt") &
  done
  wait
  RACED="$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/$1/to-lane.jsonl"
}

# What the raced file holds: both texts in order, or `lost`. Two unlocked puts
# into one path either drop a line or tear the bytes of both, and the lock is
# what rules out each, so the assertion is the guarantee rather than one of
# the ways it breaks.
raced_texts() {
  jq -rs 'map(.text) | sort | join(",")' < "$RACED" 2>/dev/null || printf 'lost'
}
host_lm drain --item KEN-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$(count_line)" "0=count=1" "a hosted drain counts the remote mailbox"
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
assert_eq "$RC=$(count_line)" "0=count=0" "a hosted lane that has not opened its mailbox reads empty"
HOST_ENV=(LANE_HOST_STUB_STATUS=4)
host_lm drain --item KEN-2 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$ERR" "2=lane-mail: host-unreachable=KEN-2 state=unknown" \
  "a host that cannot be reached is refused, and the refusal names the state it could not act on"


# A hosted mailbox directory that is a symlink is refused by the provider behind
# cat, which lane-mail reads as a failed read, never as an empty mailbox.
mkdir -p -- "$TMP_ROOT/away-remote"
ln -s "$TMP_ROOT/away-remote" "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-6"
host_lm drain --item KEN-6 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$ERR=$(grep -c "mailbox-component path=$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-6\$" "$TMP_ROOT/err")" \
  "2=lane-mail: mail-read-failed=KEN-6=1" "a hosted mailbox directory that is a symlink is refused, never read as empty"

# A read that fails is one of three things, and only the exit code and the
# probe tell them apart.
host_lm drain --item KEN-9 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$(count_line)" "0=count=0" "a remote file that is not there drains as an empty mailbox"
HOST_ENV=(LANE_HOST_STUB_CAT_STATUS=1)
host_lm drain --item KEN-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=KEN-1" \
  "a read that failed for any other reason is refused, never reported as empty"

# The fixture lists TEST-1 as `hosted`, and a failed touch is what asks.
HOST_ENV=(LANE_HOST_STUB_TOUCH_STATUS=1)
host_lm drain --item TEST-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$ERR" "2=lane-mail: host-unreachable=TEST-1 state=hosted" \
  "an unreachable host's refusal carries the state its provider reports"

# Two overseer writers, not one process: the second send starts while the
# first is inside its put, and both lines land.
new_lane hosted_put
put_survives
assert_eq "$SURVIVED" "kept" "a put that dies partway replaces nothing"
assert_eq "$RC=$ERR" "2=lane-mail: host-write=KEN-5" "and the send says the write failed"

# A peer ask records itself only once the peer has it. Both files are
# append-only and pending filters on answered ids alone, so a record written
# before a delivery that refused would owe an answer to a question the peer
# never received, and every retry would add another.
new_lane peer_undelivered
HOST_ENV=(LANE_HOST_STUB_PUT_FAIL=1)
host_lm peer ask --repo "$REMOTE_ROOT" --host --file "$(text q 'Never delivered?')"
assert_eq "$RC=$ERR" "2=lane-mail: host-write=overseer" "a peer ask whose delivery fails refuses"
lm pending --item overseer
assert_eq "$RC=$OUT" "0=" \
  "and leaves the asker's pending empty rather than owed an answer the peer never saw"

new_lane hosted_lock
race_sends KEN-1 "$LANE_MAIL"
assert_eq "$(raced_texts)" "first,second" "two hosted sends racing on one item both land"

# One per surface: the partial-line rule, the inbox cursor, inbox --after, the
# already-answered filter, the ownership rule and the overseer inbox's answer
# exception. Each mutant keeps the matched text, removes the behaviour, and is
# proved to differ from the script it was cut from.
MUTANT_DIR="$TMP_ROOT/mutants"
mkdir -p "$MUTANT_DIR"
# lane-mail resolves its lock library, the transport and the checkout judge
# beside itself, so a mutant copy keeps them around it; without them every
# control would read as a silent pass. git-context is load-bearing here: with
# it absent every peer verb refuses root-unresolved, which is an exit 2 a
# control asserting a refusal would accept as its own.
ln -sfn "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
ln -sfn "$REPO_ROOT/skills/orch/scripts/lane-host" "$MUTANT_DIR/lane-host"
ln -sfn "$REPO_ROOT/skills/orch/scripts/git-context" "$MUTANT_DIR/git-context"
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
printf '{"id":"half","kind":"notice","at":"t","text":"trunc' >> "$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl"
LANE_MAIL_BIN="$MUTANT_DIR/partial-consumed" lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(count_line)" "count=3" \
  "control: without the terminated-prefix rule the half-written line is counted as read"

mutant inbox-cursor-frozen 's@^  mv -- "\$WORK_DIR/cursor" "\$CURSOR".*@  rm -f -- "$WORK_DIR/cursor"@'
new_lane control_cursor
LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'twice')"
LANE_MAIL_BIN="$MUTANT_DIR/inbox-cursor-frozen" lm inbox --item KEN-1
assert_eq "$(jq -r '.text' <<<"$OUT")" "twice" "control: the frozen-cursor mutant still hands the line over once"
LANE_MAIL_BIN="$MUTANT_DIR/inbox-cursor-frozen" lm inbox --item KEN-1
assert_eq "$(jq -r '.text' <<<"$OUT")" "twice" \
  "control: without the cursor advance a second inbox hands the same line over again"

mutant inbox-after-cursor 's@^    if \[ -n "\$AFTER" \]; then$@    if false; then@'
after_lane control_after
assert_eq "$AFTER_READ" "0=count=2=First.
Second." "control: an --after that reads the file cursor hands over what line 1 already covers"

mutant inbox-after-cursor-write 's@^    if \[ -z "\$AFTER" \]; then$@    if true; then@'
after_lane control_after_write
assert_eq "$CURSOR_KEPT" "rewritten" "control: an --after that writes the file cursor changes it"

mutant ack-backward 's@^      \[ "\$ACK" -le "\$SEEN" \] || lm_cursor_write "\$ACK"$@      lm_cursor_write "$ACK"@'
stale_ack control_ack
assert_eq "$ACK_CURSOR" "0=1" "control: without the forward-only rule a stale --ack moves the cursor back"

mutant unsafe-component 's@^    { \[ ! -L "\$path" \] && { \[ ! -e "\$path" \] || test "\$kind" "\$path"; }; } || refuse mailbox-unsafe "\$path"$@    :@'
unsafe_inbox link KEN-1/to-lane.jsonl
assert_eq "${UNSAFE%%=*}" "0" "control: without the component rule an inbox reads through a planted link"

if [ "${CASE_SENSITIVE:?}" -eq 1 ]; then
  mutant case-variant-allowed 's@^\[ "\$HOST" -eq 1 \] || lm_one_spelling$@:@'
  new_lane control_case_variant
  LANE_MAIL_BIN="$LANE_MAIL" lm notice --item ken-1 --file "$(text lane 'lane side')"
  LANE_MAIL_BIN="$MUTANT_DIR/case-variant-allowed" lm send --item KEN-1 --root "$LANE" --directive --file "$(text overseer 'overseer side')"
  assert_eq "$RC=$([ -d "$LANE/tmp/lane-mail/KEN-1" ] && echo made || echo absent)" "0=made" \
    "control: without the one-spelling check the second spelling opens its own mailbox"
else
  printf '  skip  control for the one-spelling rule: this filesystem cannot hold the second mailbox\n'
fi

mutant unowned-send 's@^if \[ "\$VERB" = send \] && \[ "\$HOST" -eq 0 \]; then$@if false; then@'
LANE="$PEER_A"
LANE_MAIL_BIN="$MUTANT_DIR/unowned-send" lm send --item KEN-1 --root "$PEER_B" --directive --file "$(text d 'Not yours.')"
assert_eq "$RC=$(jq -r '.text' < "$PEER_B/tmp/lane-mail/KEN-1/to-lane.jsonl")" "0=Not yours." \
  "control: without the ownership rule the same send writes the foreign lane"
LANE_MAIL_BIN="$MUTANT_DIR/unowned-send" lm send --item overseer --root "$PEER_B" --directive --file "$(text d 'Not yours either.')"
assert_eq "$RC=$(jq -rs 'map(.text) | last' < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl")" \
  "0=Not yours either." "control: and writes the foreign overseer mailbox the same way"

mutant record-first '/PEER_VERB" = ask/,/^    fi$/{s@^      printf @      : @;}'
LANE="$PEER_A"
chmod 000 "$PEER_A/tmp/lane-mail/overseer/to-overseer.jsonl"
LANE_MAIL_BIN="$MUTANT_DIR/record-first" lm peer ask --repo peer_b --file "$(text q 'No id?')"
RECORD_FIRST="$RC=$OUT"
chmod 644 "$PEER_A/tmp/lane-mail/overseer/to-overseer.jsonl"
assert_eq "$RECORD_FIRST" "2=" \
  "control: with the id behind the record a delivered ask leaves the caller nothing to wait on"

mutant basic-only 's@ \&\& mark != q) exit@) exit@'
LANE="$PEER_A"
LANE_MAIL_BIN="$MUTANT_DIR/basic-only"
assert_eq "$(peer_name "'quoted-peer'" 'Basic only.')" "overseer:peer_a" \
  "control: without the literal-string spelling that name is not read at all"
LANE_MAIL_BIN=""

mutant answer-hidden 's@\$item == "overseer" or @@'
LANE="$PEER_A"
LANE_MAIL_BIN="$MUTANT_DIR/answer-hidden" lm inbox --item overseer --after 0
assert_eq "$(tail -n +2 <<<"$OUT" | jq -rs 'map(select(.kind == "answer")) | length')" "0" \
  "control: without the overseer exception the peer's answer reaches nothing"

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


STREAMING_HOST="$MUTANT_DIR/streaming-host"
sed 's@^      head -c 10 > "\$staged"$@      head -c 10 > "$dest"@' \
  "$FIXTURE_HOST" > "$STREAMING_HOST"
chmod +x "$STREAMING_HOST"
assert_eq "$(cmp -s "$STREAMING_HOST" "$FIXTURE_HOST" && echo same || echo differs)" "differs" \
  "control: the streaming-host mutant really writes the partial stream into the target"
new_lane control_hosted_put
FIXTURE_HOST_REAL="$FIXTURE_HOST"
FIXTURE_HOST="$STREAMING_HOST"
put_survives
FIXTURE_HOST="$FIXTURE_HOST_REAL"
assert_eq "$SURVIVED" "gone" \
  "control: a put that streams into the target loses what was there"

mutant unterminated 's@^  lm_terminate "\$1"$@  :@'
new_lane control_interrupted
LANE_MAIL_BIN="$LANE_MAIL" lm notice --item KEN-1 --file "$(text n 'whole')"
printf '{"id":"half","kind":"notice"' >> "$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl"
LANE_MAIL_BIN="$MUTANT_DIR/unterminated" lm ask --item KEN-1 --file "$(text q 'after the fragment')"
LANE_MAIL_BIN="$LANE_MAIL" lm drain --item KEN-1 --root "$LANE" --after 0
assert_eq "$(tail -n +2 <<<"$OUT" | jq -rs 'map(.text) | join(",")')" "whole" \
  "control: without the terminator the envelope after a fragment is lost with it"

mutant interval-overshoots 's@^        \[ "\$LEFT" -ge "\$NAP" \] || NAP="\$LEFT"$@        :@'
new_lane control_deadline
LANE_MAIL_BIN="$LANE_MAIL" lm ask --item KEN-1 --file "$(text q 'Deadline?')"
OVERSHOOT_ID="${OUT#id=}"
BEFORE="$(date -u +%s)"
LANE_MAIL_BIN="$MUTANT_DIR/interval-overshoots" lm wait --item KEN-1 --id "$OVERSHOOT_ID" --timeout 1 --interval 5
ELAPSED="$(( $(date -u +%s) - BEFORE ))"
assert_eq "$([ "$ELAPSED" -ge 4 ] && echo late || printf 'prompt:%s' "$ELAPSED")" "late" \
  "control: without the cap the wait sleeps the whole interval past its deadline"

mutant read-failed-silent 's@^  \[ "\$rc" -eq 2 \] || refuse mail-read-failed .*$@  :@'
new_lane control_read_failed
HOST_ENV=(LANE_HOST_STUB_CAT_STATUS=1); HOST_BIN="$MUTANT_DIR/read-failed-silent"
host_lm drain --item KEN-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$(count_line)" "0=count=0" \
  "control: without the exit-code reading a failed read is an empty mailbox again"

mutant state-unnamed 's@^    REFUSE_EXTRA="state=\$(lm_host_state)"$@    :@'
HOST_ENV=(LANE_HOST_STUB_TOUCH_STATUS=1); HOST_BIN="$MUTANT_DIR/state-unnamed"
host_lm drain --item TEST-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$ERR" "lane-mail: host-unreachable=TEST-1" \
  "control: without the lookup the refusal names no state"

mutant hosted-unlocked 's@^  orch_take_lock 8 "\$lock" 30 .*$@  :@'
new_lane control_hosted_lock
race_sends KEN-2 "$MUTANT_DIR/hosted-unlocked"
assert_eq "$([ "$(raced_texts)" = first,second ] && echo both || echo lost)" "lost" \
  "control: without the lock the raced sends do not both survive"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
