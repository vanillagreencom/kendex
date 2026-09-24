#!/usr/bin/env bash
# lane-mail: the lane-to-overseer mailbox CLI. Each case builds a lane
# worktree under TMP_ROOT, drives the real script, and asserts stdout, the
# mailbox files and the keyed first line of any refusal; the hosted cases cross
# tests/fixtures/lane-host in its directory-backed mode. The peer cases build a
# second checkout, the overseer of another repository. The must-fail controls
# close the file, one per surface: the partial last line, the inbox cursor,
# the receipts cursor, the already-answered drain filter, the ownership rule, the
# overseer inbox's answer exception, the one-spelling rule, the self-target
# rule, the hosted append, and the lock and terminator that `scripts/lib` owns,
# whose controls run a library copy with one of those rules removed.
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

# The count field of the header drain and inbox --peek open with; the header's
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

# The receipt a send prints, and the repeat it refuses. A sender reads silence
# as a send that did not land, and a wrapper run twice delivers nothing twice.
new_lane receipt
lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
SENT_ID="${OUT#*id=}"
SENT_ID="${SENT_ID%% *}"
assert_eq "$RC=$OUT" "0=lane-mail: sent item=KEN-1 id=$SENT_ID bytes=12" \
  "send prints one receipt naming the item, the envelope it appended and the text's bytes"
assert_eq "$(jq -r '.id' < "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl")" "$SENT_ID" \
  "the receipt's id is the appended envelope's"
lm send --item KEN-2 --root "$LANE" --directive --file "$(text d 'né')"
assert_eq "$RC=${OUT##* }" "0=bytes=3" "the receipt counts the text in bytes, not in characters"

lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
assert_eq "$RC=$ERR=$OUT" "2=lane-mail: duplicate id=$SENT_ID=" \
  "the same text to the same item inside a minute is refused, naming the envelope already there"
assert_eq "$(jq -rs 'length' < "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl")" "1" \
  "and the refusal comes before the append, so the mailbox holds the one copy"
lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold it now.')"
assert_eq "$RC=${OUT%% id=*}" "0=lane-mail: sent item=KEN-1" "other text to that item appends as any send does"
lm send --item KEN-3 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
assert_eq "$RC=${OUT%% id=*}" "0=lane-mail: sent item=KEN-3" "the same text to another item is another message"

# A message longer than one execve argument, which Linux caps at 131072 bytes.
# A diff excerpt, a log tail or a review body reaches this size, so the guard
# takes the envelope through the work directory and no ceiling on an argument
# decides whether a send lands.
new_lane receipt_large
awk 'BEGIN { for (i = 0; i < 4000; i++) printf "the quick brown fox jumps over it\n" }' \
  > "$TMP_ROOT/large.txt"
LARGE_BYTES="$(wc -c < "$TMP_ROOT/large.txt" | tr -d ' ')"
assert_eq "$([ "$LARGE_BYTES" -gt 131072 ] && echo over || echo under)" "over" \
  "the large message really passes the ceiling one argument has"
lm send --item KEN-1 --root "$LANE" --directive --file "$TMP_ROOT/large.txt"
LARGE_ID="${OUT#*id=}"
LARGE_ID="${LARGE_ID%% *}"
assert_eq "$RC=${OUT##* }" "0=bytes=$(( LARGE_BYTES - 1 ))" \
  "a message past that ceiling lands, and its receipt counts every byte"
assert_eq "$(jq -r '.id' < "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl")" "$LARGE_ID" \
  "and the mailbox holds the envelope the receipt names"
lm send --item KEN-1 --root "$LANE" --directive --file "$TMP_ROOT/large.txt"
assert_eq "$RC=$ERR" "2=lane-mail: duplicate id=$LARGE_ID" \
  "and the guard judged it, so its retry is refused like any other"

# The judgement is the whole envelope, not its words. A field a reader acts on
# differing makes a message of its own, so a guard reading the text alone would
# swallow an answer to another ask or a halt after a directive of those words.
new_lane receipt_identity
lm ask --item KEN-1 --file "$(text q 'first')"
ASK_A="${OUT#id=}"
lm ask --item KEN-1 --file "$(text q 'second')"
ASK_B="${OUT#id=}"
lm send --item KEN-1 --root "$LANE" --re "$ASK_A" --file "$(text a 'ok')"
lm send --item KEN-1 --root "$LANE" --re "$ASK_B" --file "$(text a 'ok')"
ANSWER_B="${OUT#*id=}"
ANSWER_B="${ANSWER_B%% *}"
assert_eq "$RC=$(jq -rs 'map(.re) | join(",")' < "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl")" \
  "0=$ASK_A,$ASK_B" "the same words answering two asks are two messages, and both land"
lm send --item KEN-1 --root "$LANE" --re "$ASK_B" --file "$(text a 'ok')"
assert_eq "$RC=$ERR" "2=lane-mail: duplicate id=$ANSWER_B" \
  "the same words answering the same ask again is the retry that is refused"
lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Stop.')"
lm send --item KEN-1 --root "$LANE" --halt --file "$(text d 'Stop.')"
assert_eq "$RC=$(jq -rs 'map(select(.text == "Stop.")) | map(.halt // false | tostring) | join(",")' \
  < "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl")" "0=false,true" \
  "a halt after an identical plain directive lands, carrying the flag the halt hook reads"

# An envelope planted in a lane's mailbox carrying the identity that lane's own
# overseer send writes, so only the field a case is about differs. `from` is
# the repository name, which for a checkout with no kendex.toml and no origin
# is the directory name `new_lane` built it under.
plant_directive() { # ID AT TEXT
  mkdir -p "$LANE/tmp/lane-mail/KEN-1"
  jq -cn --arg id "$1" --arg at "$2" --arg from "overseer:${LANE##*/}" --arg text "$3" \
    '{id: $id, kind: "directive", at: $at, from: $from, text: $text}' \
    >> "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl"
}
stamp() { # SECONDS-FROM-NOW
  jq -rn --argjson t "$(( $(date -u +%s) + $1 ))" '$t | todate'
}

# More than a minute apart is a second message, not a retry. The envelope is
# planted with a stamp two minutes back, so the case costs no wall clock.
OLD_AT="$(stamp -120)"
new_lane receipt_window
plant_directive older "$OLD_AT" 'Hold the PR.'
lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
assert_eq "$RC=${OUT%% id=*}" "0=lane-mail: sent item=KEN-1" \
  "an envelope the mailbox has held for more than a minute is sent again"

# A provider whose clock runs ahead of the sender's stamps a line in the
# future. No send is a retry of a line written after it, so it still lands.
new_lane receipt_future
plant_directive ahead "$(stamp 120)" 'Hold the PR.'
lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
assert_eq "$RC=${OUT%% id=*}" "0=lane-mail: sent item=KEN-1" \
  "an envelope stamped ahead of the sender's clock is no line this send repeats"

# Two copies inside the window: the refusal names the one a retry would sit
# beside, which is the later of them.
new_lane receipt_latest
plant_directive earlier "$(stamp -30)" 'Hold the PR.'
plant_directive later "$(stamp -10)" 'Hold the PR.'
lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
assert_eq "$RC=$ERR" "2=lane-mail: duplicate id=later" \
  "the refusal names the most recent copy, never an older one behind it"

# The cursor moves only past what an inbox hands over. A read that finds
# nothing new leaves the file as it was, and a --receipts read lists the
# cursor no further than the lines it listed. QUIET is whether the second
# inbox left the cursor file's inode alone; CLAMPED the receipts line under a
# cursor planted past the file's end.
cursor_lane() { # NAME
  new_lane "$1"
  LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'First.')"
  LANE_MAIL_BIN="${LANE_MAIL_BIN:-$LANE_MAIL}" lm inbox --item KEN-1
  ls -i "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor" > "$TMP_ROOT/inode.before"
  lm inbox --item KEN-1
  QUIET="$(ls -i "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor" | cmp -s - "$TMP_ROOT/inode.before" && echo kept || echo rewritten)"
  printf '5\n' > "$LANE/tmp/lane-mail/KEN-1/to-lane.cursor"
  lm drain --item KEN-1 --root "$LANE" --after 0 --receipts
  CLAMPED="$(grep '^receipts ' <<<"$OUT" | sed 's/ first=.*//')"
}
cursor_lane inbox_quiet
assert_eq "$QUIET" "kept" "an inbox that hands nothing over leaves the cursor file alone"
assert_eq "$CLAMPED" "receipts cursor=1 count=1" "drain --receipts lists the cursor no further than the lines it read"
lm inbox --item KEN-1 --after 1
assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=--after" "inbox takes no --after: the cursor is its one position"
lm inbox --item KEN-1 --receipts
assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=--receipts" "--receipts is drain's alone"

# An answer the lane read, then a directive: the answer's line is on the
# cursor's scale, so pending lists the directive as unread.
answered_lane() { # NAME
  new_lane "$1"
  LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --re some-ask --file "$(text a 'Merge it.')"
  LANE_MAIL_BIN="$LANE_MAIL" lm inbox --item KEN-1
  LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Unread.')"
  lm pending --item KEN-1 --root "$LANE"
  PENDING_DIRECTIVE="$(jq -r 'select(.kind == "directive") | .text' <<<"$OUT")"
}
answered_lane pending_after_answer
assert_eq "$PENDING_DIRECTIVE" "Unread." "pending lists a directive past an answer the lane read"

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
assert_eq "$(jq -r 'select(.kind == "ask") | .id' <<<"$OUT")" "$PEER_ASK" "the asker's own pending owes the peer's answer"
# The other half of pending: what was sent to this mailbox and not yet read,
# judged by its cursor, so a read takes it off the list.
assert_eq "$(jq -r 'select(.kind == "directive") | .text' <<<"$OUT")" "Owner note." \
  "pending lists a directive the mailbox's cursor has not passed"

# The peer answers from its own checkout, naming the asker by path.
PEER_A="$LANE"
LANE="$PEER_B"
lm peer send --repo "$PEER_A" --re "$PEER_ASK" --file "$(text a 'It is ours.')"
assert_eq "$RC=$(jq -rs 'map(select(.kind == "answer")) | .[0] | .from + " " + .re + " " + .text' \
  < "$PEER_A/tmp/lane-mail/overseer/to-lane.jsonl")" \
  "0=overseer:peer_b $PEER_ASK It is ours." "peer send --re answers the asker's ask from the peer's own checkout"
assert_eq "${OUT%% id=*}" "lane-mail: sent item=overseer" "peer send prints the receipt send prints"
LANE="$PEER_A"
lm pending --item overseer
assert_eq "$RC=$(jq -c 'select(.kind == "ask")' <<<"$OUT")" "0=" "the answered peer ask is no longer pending"
lm wait --item overseer --id "$PEER_ASK" --timeout 5 --interval 1
assert_eq "$RC=$OUT" "0=It is ours." "the asker's wait on the overseer mailbox returns the peer's answer"

# An answer in the overseer mailbox has no `wait` to go to: the overseer runs
# its watch, which reads this mailbox with `inbox`.
lm inbox --item overseer
assert_eq "$(jq -rs 'map(.kind) | join(",")' <<<"$OUT")" "directive,answer" \
  "inbox hands the overseer its own note and the peer's answer"
lm pending --item overseer
assert_eq "$RC=$OUT" "0=" "a directive the inbox has read is no longer pending"
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
# A peer is another repository. Aimed at the caller's own, `peer ask` would
# put both sides of an exchange in one mailbox. The refusal names the resolved
# root, which mktemp may reach through a link, so the row resolves it too.
new_lane self_target
SELF_ROOT="$(cd "$LANE" && pwd -P)"
lm peer send --repo "$LANE" --file "$(text d 'To myself.')"
assert_eq "$RC=$ERR" "2=lane-mail: repo-self=$SELF_ROOT" \
  "a peer target resolving to the caller's own checkout is refused"
assert_eq "$([ -e "$LANE/tmp/lane-mail" ] && echo written || echo untouched)" "untouched" \
  "and the refused self-target opened no mailbox"
LANE="$PEER_A"

lm peer send --repo "$PEER_B/.agents/skills/orch" --file "$(text d 'Inside the peer.')"
assert_eq "$RC=$(jq -rs 'map(.text) | last' < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl")" \
  "0=Inside the peer." "a path inside a peer resolves to that peer's main checkout"

# The repeat rule on the peer side, and the sender field that keeps two
# overseers writing one mailbox from silencing each other.
new_lane peer_c
PEER_C="$LANE"
LANE="$PEER_A"
lm peer send --repo peer_b --file "$(text d 'Both of us.')"
LANE="$PEER_C"
lm peer send --repo peer_b --file "$(text d 'Both of us.')"
PEER_C_SENT="${OUT#*id=}"
PEER_C_SENT="${PEER_C_SENT%% *}"
assert_eq "$RC=$(jq -rs 'map(select(.text == "Both of us.")) | map(.from) | join(",")' \
  < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl")" "0=overseer:peer_a,overseer:peer_c" \
  "two overseers writing one mailbox with the same words both land"
lm peer send --repo peer_b --file "$(text d 'Both of us.')"
assert_eq "$RC=$ERR" "2=lane-mail: duplicate id=$PEER_C_SENT" \
  "a peer send repeating its own envelope inside a minute is refused"
assert_eq "$(jq -rs 'map(select(.text == "Both of us.")) | length' \
  < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl")" "2" \
  "and the peer's mailbox still holds only the two that landed"

# A peer ask lands in the same mailbox a later peer send is judged against, so
# the kind and the choices an ask carries are what keep the two apart.
lm peer ask --repo peer_b --file "$(text q 'Same words.')" --options a,b
lm peer send --repo peer_b --file "$(text d 'Same words.')"
assert_eq "$RC=$(jq -rs 'map(select(.text == "Same words.")) | map(.kind) | join(",")' \
  < "$PEER_B/tmp/lane-mail/overseer/to-lane.jsonl")" "0=ask,directive" \
  "an ask and a directive of the same words are two messages, and both land"
LANE="$PEER_A"

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
# A basic string processes escapes and this parse decodes none, so one holding
# a backslash is a value it cannot read. A literal string processes no escapes,
# so the same character there is read as written.
assert_eq "$(peer_name '"peer\u002Da"' 'Escaped basic string.')" "overseer:peer_a" \
  "a basic-string name holding an escape falls through rather than arriving mangled"
assert_eq "$(peer_name "'lit\eral'" 'Literal backslash.')" "overseer:lit-eral" \
  "a literal-string name holding a backslash is read as written"

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

# A write leaves no work directory behind on a host with no flock, which is
# every stock macOS. There file-lock.sh takes a mkdir mutex, and the mutex arm
# arms its own EXIT trap over lane-mail's; the trap the writer re-arms after
# the lock is what still removes the work directory. The PATH below is the
# commands lane-mail names, minus flock, so the mutex arm is the one that runs.
FLOCKLESS_BIN="$TMP_ROOT/no-flock-bin"
mkdir -p "$FLOCKLESS_BIN"
for command_name in bash sh cat tail printf mkdir mv rm rmdir date jq awk sed git \
  tr head sleep cp ln wc sort grep dirname basename touch chmod id uname getent; do
  command_path="$(command -v "$command_name" 2>/dev/null)" || continue
  ln -sfn "$command_path" "$FLOCKLESS_BIN/$command_name"
done
# `mktemp -d` with no template reads TMPDIR on GNU and a shared /tmp on BSD, so
# on macOS the work directory this case counts lands where nothing can count
# it. This one gives that form the template BSD asks for, under the TMPDIR the
# case sets, and passes every other call through. Where the directory goes is
# all it decides; whether it is removed is what the case is about, and the row
# below pins the premise so a platform that moves it says so itself.
FLOCKLESS_MKTEMP="$(command -v mktemp)"
cat > "$FLOCKLESS_BIN/mktemp" <<STUB
#!/bin/sh
if [ "\$#" -eq 1 ] && [ "\$1" = -d ]; then
  exec "$FLOCKLESS_MKTEMP" -d "\${TMPDIR:-/tmp}/tmp.XXXXXXXXXX"
fi
exec "$FLOCKLESS_MKTEMP" "\$@"
STUB
chmod +x "$FLOCKLESS_BIN/mktemp"
FLOCKLESS_PROBE_DIR="$TMP_ROOT/no-flock-probe"
mkdir -p "$FLOCKLESS_PROBE_DIR"
FLOCKLESS_PROBE="$(env TMPDIR="$FLOCKLESS_PROBE_DIR" PATH="$FLOCKLESS_BIN" mktemp -d)"
assert_eq "${FLOCKLESS_PROBE#$FLOCKLESS_PROBE_DIR/}" "${FLOCKLESS_PROBE##*/}" \
  "a work directory lands under the TMPDIR this case counts"
# What one local write on that PATH exits with, and how many work directories
# it leaves under a TMPDIR of its own.
flockless_leftovers() { # NAME BIN
  local rc=0 dir="$TMP_ROOT/no-flock-tmp-$1"
  mkdir -p "$dir"
  (cd "$LANE" && env TMPDIR="$dir" PATH="$FLOCKLESS_BIN" \
    "$2" notice --item KEN-1 --file "$(text n 'no flock on this host')") || rc=$?
  FLOCKLESS="$rc=$(ls "$dir" | wc -l | tr -d ' ')"
}
new_lane flockless_cleanup
flockless_leftovers real "$LANE_MAIL"
assert_eq "$(env PATH="$FLOCKLESS_BIN" sh -c 'command -v flock >/dev/null 2>&1 && echo present || echo absent')=$FLOCKLESS" \
  "absent=0=0" "a local write where flock is absent leaves no work directory behind"

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
    LANE_HOST_STUB_DIR="$REMOTE_DISK" LANE_HOST_STUB_LIB="$REPO_ROOT/skills/orch/scripts/lib" \
    ${HOST_ENV[@]+"${HOST_ENV[@]}"} \
    "${HOST_BIN:-$LANE_MAIL}" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(head -n 1 "$TMP_ROOT/err")"
  HOST_ENV=(); HOST_BIN=""
}

# An append that dies adds nothing: the provider stages the bytes beside the
# target and reaches the file only once they have all arrived.
append_survives() { # sets SURVIVED to the text the remote mailbox still holds
  local box="$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-5/to-lane.jsonl"
  mkdir -p "${box%/*}"
  printf '{"id":"kept","kind":"directive","at":"t","text":"kept"}\n' > "$box"
  HOST_ENV=(LANE_HOST_STUB_APPEND_FAIL=1)
  host_lm send --item KEN-5 --root "$REMOTE_ROOT" --host --directive --file "$(text d 'new')"
  SURVIVED="$(jq -rs 'map(.text) | join(",")' < "$box" 2>/dev/null)" || SURVIVED=gone
}

# Two writers on one hosted mailbox, each in its OWN checkout, which is what
# two overseers of two repositories are. Nothing on either sender's disk can
# serialize them: a lock one takes at home is a lock the other never opens, so
# the lock the provider takes where the file is, is the only thing keeping both
# lines. The stub delay makes the overlap a fact rather than a hope: it is
# longer than any startup skew between two children of one loop.
race_peer_sends() { # BIN
  local n
  mkdir -p "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/overseer"
  : > "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/overseer/to-lane.jsonl"
  printf 'first\n' > "$TMP_ROOT/first.txt"
  printf 'second\n' > "$TMP_ROOT/second.txt"
  for n in first second; do
    (cd "$TMP_ROOT/racer_$n" && env ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_LOG" \
      LANE_HOST_STUB_DIR="$REMOTE_DISK" LANE_HOST_STUB_APPEND_DELAY=1 LANE_HOST_STUB_PUT_DELAY=1 \
      LANE_HOST_STUB_LIB="$REPO_ROOT/skills/orch/scripts/lib" \
      OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/racer_$n/state" \
      "$1" peer send --repo "$REMOTE_ROOT" --host --file "$TMP_ROOT/$n.txt" >/dev/null) &
  done
  wait
  RACED="$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/overseer/to-lane.jsonl"
}

# What the raced file holds: both texts, or `lost`. A write that replaces the
# file instead of appending drops a line, and two writers sharing no lock tear
# each other's bytes so that nothing parses. The lock rules out each, so the
# assertion is the guarantee rather than one of the ways it breaks.
raced_texts() {
  jq -rs 'map(.text) | sort | join(",")' < "$RACED" 2>/dev/null || printf 'lost'
}

# A background writer holding one file's lock, through the same orch_take_lock
# every mailbox append calls. It signals NAME.taken once it holds the lock and
# lets go when NAME.release appears, or after a minute, so a case that aborts
# before releasing it leaves no process spinning behind the suite.
hold_lock() { # FILE NAME
  local waited=0
  . "$REPO_ROOT/skills/orch/scripts/lib/file-lock.sh"
  exec 9>>"$1"
  orch_take_lock 9 "$1" 30 || return 1
  : > "$TMP_ROOT/$2.taken"
  while [ ! -e "$TMP_ROOT/$2.release" ]; do
    waited=$((waited + 1))
    [ "$waited" -lt 1200 ] || return 1
    sleep 0.05
  done
}

# Wait for a holder's marker, bounded at five seconds. A holder that failed
# before writing it would otherwise spin the suite to the CI job's own timeout,
# with nothing on screen saying which assertion was in flight.
await_marker() { # PATH
  local tries=0
  while [ ! -e "$1" ]; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || return 1
    sleep 0.05
  done
}

# The lock the provider takes, observed without a race, because a race only
# ever samples one interleaving. The holder takes the mailbox's own lock
# through the same orch_take_lock the library calls, so a hosted send cannot
# write while it is held and lands once the holder lets go. LIB is the library
# the fixture appends through, the real one unless a control hands a mutant.
held_hosted_send() { # BIN LIB — sets HELD to the line counts during and after
  local box="$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" during send_pid
  mkdir -p -- "${box%/*}"
  : > "$box"
  rm -f -- "${TMP_ROOT:?}/held.taken" "${TMP_ROOT:?}/held.release"
  printf 'while the lock is held\n' > "$TMP_ROOT/held.txt"
  hold_lock "$box" held &
  await_marker "$TMP_ROOT/held.taken" || { HELD="holder-never-took-the-lock"; return 0; }
  (cd "$TMP_ROOT/racer_first" && env ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_LOG" \
    LANE_HOST_STUB_DIR="$REMOTE_DISK" LANE_HOST_STUB_LIB="$2" \
    OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/racer_first/state" \
    "$1" peer send --repo "$REMOTE_ROOT" --host --file "$TMP_ROOT/held.txt" >/dev/null 2>&1) &
  send_pid=$!
  sleep 2
  during="$(awk 'END { print NR + 0 }' < "$box")"
  : > "$TMP_ROOT/held.release"
  wait "$send_pid" || true
  wait
  HELD="$during/$(awk 'END { print NR + 0 }' < "$box")"
}

host_lm drain --item KEN-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$RC=$(count_line)" "0=count=1" "a hosted drain counts the remote mailbox"
assert_eq "$(tail -n +2 <<<"$OUT" | jq -r '.text')" "Hosted question" "a hosted drain reads the lane's own host"
assert_eq "$(grep -c -- "$REMOTE_ROOT/tmp/lane-mail/KEN-1/to-overseer.jsonl" "$STUB_LOG")" "1" \
  "the hosted read names the remote path in the transport's call log"
host_lm send --item KEN-1 --root "$REMOTE_ROOT" --host --re remote-ask --file "$(text a 'Hosted answer.')"
assert_eq "$RC" "0" "a hosted send exits 0"
HOSTED_ID="${OUT#*id=}"
HOSTED_ID="${HOSTED_ID%% *}"
assert_eq "${OUT%% id=*}" "lane-mail: sent item=KEN-1" "and prints the receipt from the remote mailbox"
assert_eq "$HOSTED_ID" "$(jq -r '.id' < "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-1/to-lane.jsonl")" \
  "whose id is the envelope the transport appended"
assert_eq "$(jq -r '.text' < "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-1/to-lane.jsonl")" \
  "Hosted answer." "a hosted send writes through the transport to the remote mailbox"
host_lm drain --item KEN-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$(tail -n +2 <<<"$OUT")" "" "a hosted drain skips the ask its hosted answer already answers"
assert_eq "$(grep -c -- "append --item KEN-1" "$STUB_LOG")" "1" "the hosted send crosses lane-host append once"
assert_eq "$(grep -c -- "put --item KEN-1" "$STUB_LOG")" "0" "and never put, which would replace the whole mailbox"

# The repeat is judged on the remote file, read through the transport the
# append writes, so a hosted send judges the mailbox its own line would join.
host_lm send --item KEN-1 --root "$REMOTE_ROOT" --host --re remote-ask --file "$(text a 'Hosted answer.')"
assert_eq "$RC=$ERR" "2=lane-mail: duplicate id=$HOSTED_ID" \
  "a hosted repeat is refused against the mailbox its own transport reads"
assert_eq "$(grep -c -- "append --item KEN-1" "$STUB_LOG")" "1" "and crosses no second append"

# A send the provider refused prints no receipt, so silence and a landed send
# are never the same screen.
HOST_ENV=(LANE_HOST_STUB_NO_APPEND=1)
host_lm send --item KEN-7 --root "$REMOTE_ROOT" --host --directive --file "$(text d 'never landed')"
assert_eq "$RC=$OUT" "2=" "a hosted send the provider refused prints no receipt"

# A hosted mailbox that cannot be read is one no send can be judged against,
# so the send stops at the read rather than appending an unjudged line.
HOST_ENV=(LANE_HOST_STUB_CAT_STATUS=1)
host_lm send --item KEN-1 --root "$REMOTE_ROOT" --host --re remote-ask --file "$(text a 'Unjudged.')"
assert_eq "$RC=$ERR=$OUT" "2=lane-mail: mail-read-failed=KEN-1=" \
  "a hosted send whose mailbox read failed is refused, with no receipt"
assert_eq "$(jq -rs 'map(select(.text == "Unjudged.")) | length' \
  < "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-1/to-lane.jsonl")" "0" \
  "and nothing of it reached the remote mailbox"
assert_eq "$(grep -c -- "append --item KEN-1" "$STUB_LOG")" "1" "and it crossed no second append"

# A provider predating the verb fails it. The send refuses and names the verb;
# reading the mailbox and putting it back is what loses a line, so no write
# falls back to it.
HOST_ENV=(LANE_HOST_STUB_NO_APPEND=1)
host_lm send --item KEN-3 --root "$REMOTE_ROOT" --host --directive --file "$(text d 'no verb here')"
assert_eq "$RC=$ERR" "2=lane-mail: host-append=KEN-3" \
  "a provider without the append verb refuses the hosted send"
assert_eq "$(grep -c -- "put --item KEN-3" "$STUB_LOG")" "0" "and nothing falls back to a put"

# A host out of reach is not a provider declining a write it never saw. The
# send probes it exactly as a read does, so the operator gets the key that says
# to start or relaunch the host, and the state it is in.
HOST_ENV=(LANE_HOST_STUB_STATUS=4)
host_lm send --item KEN-3 --root "$REMOTE_ROOT" --host --directive --file "$(text d 'no host')"
assert_eq "$RC=$ERR" "2=lane-mail: host-unreachable=KEN-3 state=unknown" \
  "a hosted send whose host cannot be reached is refused as unreachable, with its state"
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

# A transfer that dies partway adds nothing, and the send says so.
new_lane hosted_append
append_survives
assert_eq "$SURVIVED" "kept" "an append that dies partway adds nothing"
assert_eq "$RC=$ERR" "2=lane-mail: host-append=KEN-5" "and the send says the append failed"

# A peer ask records itself only once the peer has it. Both files are
# append-only and pending filters on answered ids alone, so a record written
# before a delivery that refused would owe an answer to a question the peer
# never received, and every retry would add another.
new_lane peer_undelivered
HOST_ENV=(LANE_HOST_STUB_APPEND_FAIL=1)
host_lm peer ask --repo "$REMOTE_ROOT" --host --file "$(text q 'Never delivered?')"
assert_eq "$RC=$ERR" "2=lane-mail: host-append=overseer" "a peer ask whose delivery fails refuses"
lm pending --item overseer
assert_eq "$RC=$OUT" "0=" \
  "and leaves the asker's pending empty rather than owed an answer the peer never saw"

new_lane racer_first
new_lane racer_second
race_peer_sends "$LANE_MAIL"
assert_eq "$(raced_texts)" "first,second" \
  "two peers on separate checkouts racing on one hosted overseer mailbox both land"

# The lock itself, which a race can only sample: while the mailbox's own lock
# is held, the hosted send writes nothing, and it lands when the hold ends.
held_hosted_send "$LANE_MAIL" "$REPO_ROOT/skills/orch/scripts/lib"
assert_eq "$HELD" "0/1" "a hosted send waits on the mailbox lock and lands when it is free"

# The library's own two outcomes, driven for real: a lock another writer holds,
# and a directory that cannot be written. Three callers read these codes, so
# each is pinned where it is produced. The wait is one second because what is
# under test is which outcome comes back, not how long a caller waits.
new_lane library_codes
LIB_BOX="$LANE/box.jsonl"
: > "$LIB_BOX"
rm -f -- "${TMP_ROOT:?}/libcode.taken" "${TMP_ROOT:?}/libcode.release"
hold_lock "$LIB_BOX" libcode &
LIB_RC=0
if await_marker "$TMP_ROOT/libcode.taken"; then
  ( . "$REPO_ROOT/skills/orch/scripts/lib/file-lock.sh"
    . "$REPO_ROOT/skills/orch/scripts/lib/mailbox-append.sh"
    mailbox_append_locked "$LIB_BOX" 1 <<<'{"id":"blocked"}' ) 2>/dev/null || LIB_RC=$?
else
  LIB_RC=holder-never-took-the-lock
fi
: > "$TMP_ROOT/libcode.release"
wait
assert_eq "$LIB_RC=$(awk 'END { print NR + 0 }' < "$LIB_BOX")" "3=0" \
  "the library reports 3 for a lock another writer holds, and adds nothing"

mkdir -p -- "$LANE/sealed"
chmod 500 "$LANE/sealed"
LIB_RC=0
( . "$REPO_ROOT/skills/orch/scripts/lib/file-lock.sh"
  . "$REPO_ROOT/skills/orch/scripts/lib/mailbox-append.sh"
  mailbox_append_locked "$LANE/sealed/box.jsonl" 1 <<<'{"id":"nowhere"}' ) 2>/dev/null || LIB_RC=$?
chmod 700 "$LANE/sealed"
assert_eq "$LIB_RC" "2" "the library reports 2 for a mailbox it could not open"

# One per surface: the partial-line rule, the inbox cursor, inbox --after, the
# already-answered filter, the ownership rule, the self-target rule and the
# overseer inbox's answer exception. Each mutant keeps the matched text,
# removes the behaviour, and is proved to differ from the script it was cut
# from.
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
# A control on a rule `scripts/lib` owns, which a mutant of lane-mail itself
# cannot reach: a directory holding a library copy with that one rule removed,
# an unmodified lane-mail beside it, and the siblings both resolve. MUTANT_LIB
# is the library for a provider fixture, MUTANT_LIB_BIN the script for a lane.
mutant_lib() { # NAME SED-EXPRESSION
  local dir="$MUTANT_DIR/$1" source="$REPO_ROOT/skills/orch/scripts/lib/mailbox-append.sh"
  mkdir -p "$dir/lib"
  cp "$REPO_ROOT"/skills/orch/scripts/lib/*.sh "$dir/lib/"
  sed "$2" "$source" > "$dir/lib/mailbox-append.sh"
  assert_eq "$(cmp -s "$dir/lib/mailbox-append.sh" "$source" && echo same || echo differs)" "differs" \
    "control: the $1 library mutant really differs from mailbox-append.sh"
  cp "$LANE_MAIL" "$dir/lane-mail"
  chmod +x "$dir/lane-mail"
  ln -sfn "$REPO_ROOT/skills/orch/scripts/lane-host" "$dir/lane-host"
  ln -sfn "$REPO_ROOT/skills/orch/scripts/git-context" "$dir/git-context"
  MUTANT_LIB="$dir/lib"
  MUTANT_LIB_BIN="$dir/lane-mail"
}

mutant() { # NAME SED-EXPRESSION
  sed "$2" "$LANE_MAIL" > "$MUTANT_DIR/$1"
  chmod +x "$MUTANT_DIR/$1"
  assert_eq "$(cmp -s "$MUTANT_DIR/$1" "$LANE_MAIL" && echo same || echo differs)" "differs" \
    "control: the $1 mutant really differs from lane-mail"
  LANE_MAIL_BIN="$MUTANT_DIR/$1"
}

mutant partial-consumed 's@if \[ "\$complete" -eq 0 \]; then@if [ x = x ]; then@'
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

mutant inbox-cursor-churn 's@^    \[ "\$PEEK" -eq 1 \] || \[ "\$COUNT" = "\$SEEN" \] || lm_cursor_write "\$COUNT"$@    [ "$PEEK" -eq 1 ] || lm_cursor_write "$COUNT"@'
cursor_lane control_quiet
assert_eq "$QUIET" "rewritten" "control: a cursor written on every inbox is replaced by a read that found nothing"

mutant directives-alone 's@foreach inputs as \$raw (0; \. + 1;@foreach (inputs | select(test("directive"))) as $raw (0; . + 1;@'
answered_lane control_pending_answer
assert_eq "$PENDING_DIRECTIVE" "" "control: directive lines numbered alone drop an unread directive from pending"

mutant receipts-unclamped 's@^      \[ "\$SEEN" -le "\$COUNT" \] || SEEN="\$COUNT"$@      :@'
cursor_lane control_clamp
assert_eq "$CLAMPED" "receipts cursor=5 count=1" "control: an unclamped cursor claims lines the read never listed"

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

mutant escapes-decoded 's@> 0) exit$@> 0) ;@'
LANE="$PEER_A"
LANE_MAIL_BIN="$MUTANT_DIR/escapes-decoded"
assert_eq "$(peer_name '"peer\u002Da"' 'Escapes decoded.')" "overseer:peer-u002Da" \
  "control: without the escape rule the undecoded escape reaches the identity"
LANE_MAIL_BIN=""

mutant basic-only 's@ \&\& mark != q) exit@) exit@'
LANE="$PEER_A"
LANE_MAIL_BIN="$MUTANT_DIR/basic-only"
assert_eq "$(peer_name "'quoted-peer'" 'Basic only.')" "overseer:peer_a" \
  "control: without the literal-string spelling that name is not read at all"
LANE_MAIL_BIN=""

mutant self-allowed 's@^    \[ "\$ROOT" != "\$OWN_ROOT" \] || refuse repo-self "\$ROOT"$@    :@'
new_lane control_self_target
LANE_MAIL_BIN="$MUTANT_DIR/self-allowed" lm peer send --repo "$LANE" --file "$(text d 'To myself.')"
assert_eq "$RC=$(jq -r '.text' < "$LANE/tmp/lane-mail/overseer/to-lane.jsonl")" "0=To myself." \
  "control: without the self-target rule a caller writes its own overseer mailbox as a peer"
LANE="$PEER_A"

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

# One mutant for both call sites, applied at each in its own row: the send
# branch calls the guard bare and the peer branch inside its `send` arm, so a
# control covering one says nothing about the other.
mutant duplicate-allowed 's@^    lm_no_duplicate "\$LINE"$@    :@; s@^      lm_no_duplicate "\$LINE"$@      :@'
new_lane control_duplicate
LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Twice over.')"
LANE_MAIL_BIN="$MUTANT_DIR/duplicate-allowed" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Twice over.')"
assert_eq "$RC=$(jq -rs 'map(.text) | join(",")' < "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl")" \
  "0=Twice over.,Twice over." "control: without the repeat check the retry is delivered a second time"

new_lane control_peer_target
CONTROL_PEER="$LANE"
new_lane control_peer_duplicate
LANE_MAIL_BIN="$LANE_MAIL" lm peer send --repo control_peer_target --file "$(text d 'Peer twice.')"
LANE_MAIL_BIN="$MUTANT_DIR/duplicate-allowed" lm peer send --repo control_peer_target --file "$(text d 'Peer twice.')"
assert_eq "$RC=$(jq -rs 'map(.text) | join(",")' < "$CONTROL_PEER/tmp/lane-mail/overseer/to-lane.jsonl")" \
  "0=Peer twice.,Peer twice." "control: without it at the peer call site the peer retry is delivered too"

mutant duplicate-window-open 's@<= 60)@<= 86400)@'
new_lane control_window
plant_directive older "$OLD_AT" 'Hold the PR.'
LANE_MAIL_BIN="$MUTANT_DIR/duplicate-window-open" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
assert_eq "$RC=$ERR" "2=lane-mail: duplicate id=older" \
  "control: with the window wider than a minute an envelope two minutes old refuses the send"

mutant duplicate-future-counted 's@(\$now - \$at) >= 0 and @@'
new_lane control_future
plant_directive ahead "$(stamp 120)" 'Hold the PR.'
LANE_MAIL_BIN="$MUTANT_DIR/duplicate-future-counted" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
assert_eq "$RC=$ERR" "2=lane-mail: duplicate id=ahead" \
  "control: without the floor a line stamped after this send is read as one it repeats"

mutant duplicate-first-match "s@awk '{ last = \$0 } END { if (NR > 0) print last }'@awk 'NR == 1 { print; exit }'@"
new_lane control_latest
plant_directive earlier "$(stamp -30)" 'Hold the PR.'
plant_directive later "$(stamp -10)" 'Hold the PR.'
LANE_MAIL_BIN="$MUTANT_DIR/duplicate-first-match" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'Hold the PR.')"
assert_eq "$RC=$ERR" "2=lane-mail: duplicate id=earlier" \
  "control: naming the first match sends the reader to a copy behind the one a retry sits beside"

# The identity the guard compares. A copy reading the text alone swallows the
# answer to a second ask, which the lane then waits out to its timeout.
mutant duplicate-text-only 's@select(del(.id, .at) == \$want)@select(.text == ($sent[0] | .text))@'
new_lane control_identity
LANE_MAIL_BIN="$LANE_MAIL" lm send --item KEN-1 --root "$LANE" --re ask-A --file "$(text a 'ok')"
LANE_MAIL_BIN="$MUTANT_DIR/duplicate-text-only" lm send --item KEN-1 --root "$LANE" --re ask-B --file "$(text a 'ok')"
assert_eq "$RC=$(jq -rs 'map(.re) | join(",")' < "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl")" \
  "2=ask-A" "control: judging the words alone refuses the answer to a second ask and never appends it"

# The receipt is printed once the envelope is appended, on both routes. A copy
# that prints it first tells a caller a send landed that the write then refused.
mutant receipt-ahead-of-append 's@^      lm_append_host "\$TO_LANE" "\$LINE"$@      lm_sent; lm_append_host "$TO_LANE" "$LINE"@; s@^      lm_append_local "\$TO_LANE" "\$LINE"$@      lm_sent; lm_append_local "$TO_LANE" "$LINE"@'
HOST_ENV=(LANE_HOST_STUB_NO_APPEND=1); HOST_BIN="$MUTANT_DIR/receipt-ahead-of-append"
host_lm send --item KEN-7 --root "$REMOTE_ROOT" --host --directive --file "$(text d 'never landed')"
assert_eq "$RC=${OUT%% id=*}" "2=lane-mail: sent item=KEN-7" \
  "control: a receipt printed ahead of the hosted append reports a send the provider refused"

# A mailbox file the lane can read and cannot write: the guard reads it, and
# the append is what fails, so the two copies differ on the receipt alone.
unwritable_send() { # BIN — sets LOCAL_SEND to the status and the receipt
  new_lane control_local_receipt
  mkdir -p "$LANE/tmp/lane-mail/KEN-1"
  : > "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl"
  chmod 444 "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl"
  LANE_MAIL_BIN="$1" lm send --item KEN-1 --root "$LANE" --directive --file "$(text d 'never landed')"
  chmod 644 "$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl"
  LOCAL_SEND="$RC=$ERR=${OUT%% id=*}"
  # Whether the first line an operator reads is lane-mail's own key or the
  # shell's message about a library file.
  case "$ERR" in
    'lane-mail: '*) LOCAL_FIRST=keyed ;;
    *) LOCAL_FIRST=noise ;;
  esac
}
unwritable_send "$LANE_MAIL"
assert_eq "$LOCAL_SEND" "2=lane-mail: write-failed=$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl=" \
  "a local send whose append could not write refuses under its own key first, and prints no receipt"
unwritable_send "$MUTANT_DIR/receipt-ahead-of-append"
assert_eq "$LOCAL_SEND" "2=lane-mail: write-failed=$LANE/tmp/lane-mail/KEN-1/to-lane.jsonl=lane-mail: sent item=KEN-1" \
  "control: a receipt printed ahead of the local append reports a send the disk refused"

# The library opens the mailbox itself, so the shell's own words on that
# failure would stand ahead of the key unless the call site captures them.
mutant append-words-uncaptured 's@ 2>"\$WORK_DIR/local.err" || rc=\$?@ || rc=$?@'
unwritable_send "$MUTANT_DIR/append-words-uncaptured"
assert_eq "${LOCAL_SEND%%=*}=$LOCAL_FIRST" "2=noise" \
  "control: without the capture the library's own message stands where the keyed line belongs"


STREAMING_HOST="$MUTANT_DIR/streaming-host"
sed 's@^      head -c 10 > "\$landing"$@      head -c 10 >> "$dest"@' \
  "$FIXTURE_HOST" > "$STREAMING_HOST"
chmod +x "$STREAMING_HOST"
assert_eq "$(cmp -s "$STREAMING_HOST" "$FIXTURE_HOST" && echo same || echo differs)" "differs" \
  "control: the streaming-host mutant really writes the partial stream into the target"
new_lane control_hosted_append
FIXTURE_HOST_REAL="$FIXTURE_HOST"
FIXTURE_HOST="$STREAMING_HOST"
append_survives
FIXTURE_HOST="$FIXTURE_HOST_REAL"
assert_eq "$SURVIVED" "gone" \
  "control: an append that streams into the target leaves a fragment behind"

mutant_lib unterminated 's@^  printf .\\n. >>"\$1" || return 1$@  return 0@'
new_lane control_interrupted
LANE_MAIL_BIN="$LANE_MAIL" lm notice --item KEN-1 --file "$(text n 'whole')"
printf '{"id":"half","kind":"notice"' >> "$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl"
LANE_MAIL_BIN="$MUTANT_LIB_BIN" lm ask --item KEN-1 --file "$(text q 'after the fragment')"
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

mutant state-unnamed 's@^  REFUSE_EXTRA="state=\$(lm_host_state)"$@  :@'
HOST_ENV=(LANE_HOST_STUB_TOUCH_STATUS=1); HOST_BIN="$MUTANT_DIR/state-unnamed"
host_lm drain --item TEST-1 --root "$REMOTE_ROOT" --host --after 0
assert_eq "$ERR" "lane-mail: host-unreachable=TEST-1" \
  "control: without the lookup the refusal names no state"

# The defect this replaced: a hosted write that reads the mailbox, adds its
# line and puts the file back. The mutant keeps the transport call and swaps
# the verb, so the line still crosses and the provider still writes, and the
# loss is the put replacing a file the other sender had already added to.
mutant hosted-put 's@"\$SCRIPT_DIR/lane-host" append --item@"$SCRIPT_DIR/lane-host" put --item@'
race_peer_sends "$MUTANT_DIR/hosted-put"
assert_eq "$([ "$(raced_texts)" = first,second ] && echo both || echo lost)" "lost" \
  "control: a hosted write that puts the file back instead of appending does not keep both lines"

# The other half of the guarantee: the lock the provider takes where the file
# is. A library copy with that one call removed reaches the fixture through the
# same LANE_HOST_STUB_LIB the suites hand it, and the two writers then tear
# each other's bytes.
# The re-armed trap, without which the mutex arm's own EXIT trap replaces
# lane-mail's and the work directory stays. Addressed inside lm_append_local,
# because the inbox cursor site re-arms for the same reason.
mutant trap-not-rearmed '/^lm_append_local/,/^}/ s@^  trap lm_cleanup EXIT$@  :@'
new_lane control_flockless
flockless_leftovers control "$MUTANT_DIR/trap-not-rearmed"
assert_eq "$FLOCKLESS" "0=1" \
  "control: without the re-armed trap a write where flock is absent keeps its work directory"

# The two codes the library returns and the two refusals lane-mail turns them
# into. A library copy returns each code at its first line, so the mapping is
# pinned without waiting out lane-mail's own thirty seconds on a held lock; the
# codes themselves are produced for real earlier in this file.
for row in '3|lock-failed' '2|write-failed'; do
  CODE="${row%%|*}"
  KEY="${row#*|}"
  mutant_lib "returns-$CODE" 's@^  exec 9>>"\$1" || return 2$@  return '"$CODE"'@'
  new_lane "decode_$CODE"
  # --root, as the neighbouring rows pass it: a verb that resolves its own root
  # answers the physical path, and on a disk whose temporary root is a symlink,
  # every macOS, that is not the name this file built the lane under.
  LANE_MAIL_BIN="$MUTANT_LIB_BIN" lm notice --item KEN-1 --root "$LANE" --file "$(text n 'decoded')"
  assert_eq "$RC=$ERR" "2=lane-mail: $KEY=$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl" \
    "the library's $CODE is refused as $KEY"
done

# The same two codes as the provider reports them. lane-mail's host-append
# refusal sends the operator to the provider's own line for the cause, so what
# that line says is the whole diagnosis: a writer holding the mailbox, or a
# disk it could not write.
for row in '3|lock-timeout' '2|write-failed'; do
  CODE="${row%%|*}"
  WORD="${row#*|}"
  mutant_lib "hosted-returns-$CODE" 's@^  exec 9>>"\$1" || return 2$@  return '"$CODE"'@'
  new_lane "hosted_decode_$CODE"
  HOST_ENV=(LANE_HOST_STUB_LIB="$MUTANT_LIB")
  host_lm send --item KEN-4 --root "$REMOTE_ROOT" --host --directive --file "$(text d 'decoded')"
  assert_eq "$RC=$ERR=$(grep -c "append-failed path=.* reason=$WORD\$" "$TMP_ROOT/err")" \
    "2=lane-mail: host-append=KEN-4=1" \
    "a hosted append ending in $CODE reaches the operator as reason=$WORD"
done

mutant_lib unlocked 's@^  if ! orch_take_lock 9 "\$1" "\$2"; then$@  if false; then@'
held_hosted_send "$LANE_MAIL" "$MUTANT_LIB"
assert_eq "$HELD" "1/1" \
  "control: without the lock the hosted send writes while another writer holds it"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
