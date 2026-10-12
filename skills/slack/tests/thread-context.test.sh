#!/usr/bin/env bash
# A thread reply's parent carries every thread message its reader generation
# has not been delivered, through the real relay, lane-mail and overseer record.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start --page 2
echo "=== slack thread context ==="
ROOT="$(sk_new_root context)"
sk_bind "$ROOT"
CH="$(sk_channel "$ROOT")"
sk_poll "$ROOT"
RECORD="$ROOT/tmp/workflow-state-oversee.json"
generation() { jq -c ".overseer.generation = $1" "$RECORD" > "$SK_TMP/record" && mv -- "$SK_TMP/record" "$RECORD"; } # N
post() { sk_run -- post --root "$ROOT" --text "$1" ${2:+--thread "$2"}; sk_state ".messages.${CH}[-1].ts"; } # TEXT [THREAD]
reply() { REPLY="$(sk_inject "$CH" U001 "$1" "$2")"; sk_event "$ROOT" "$CH" "$REPLY"; } # TEXT THREAD
# The [author, ts] pairs of the delivered reply's parent.thread.
carried() { jq -c --arg d "$CH:$1" 'select(.delivery_id == $d) | [.parent.thread[] | [.author, .ts]]' "$(sk_box "$ROOT")/to-lane.jsonl"; } # TS
pairs() { printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | split(" "))'; } # "AUTHOR TS"...

ROOT_TS="$(post 'Plan A or plan B?')"
A1="$(post 'Plan A is cheaper.' "$ROOT_TS")"
ASIDE="$(sk_inject "$CH" U999 'A non-owner aside.' "$ROOT_TS")"
reply 'Which is faster?' "$ROOT_TS"; R1="$REPLY"
assert_eq "$(carried "$R1")" "$(pairs "app $ROOT_TS" "app $A1" "owner $R1")" "the first reply carries the whole thread, both sides, and no non-owner"
assert_eq "$(jq -r --arg d "$CH:$R1" 'select(.delivery_id == $d) | .parent.thread[0].text' "$(sk_box "$ROOT")/to-lane.jsonl")" \
  "Plan A or plan B?" "each carried message keeps its text"
A2="$(post 'Plan B is faster.' "$ROOT_TS")"
reply 'Take plan B.' "$ROOT_TS"; R2="$REPLY"
assert_eq "$(carried "$R2")" "$(pairs "app $A2" "owner $R2")" "the second reply carries only what its generation has not been delivered"

generation 1
reply 'Status?' "$ROOT_TS"; R3="$REPLY"
assert_eq "$(carried "$R3")" "$(pairs "app $ROOT_TS" "app $A1" "owner $R1" "app $A2" "owner $R2" "owner $R3")" \
  "a successor generation's first reply carries the whole thread again"
reply 'Go on.' "$ROOT_TS"; R4="$REPLY"
assert_eq "$(carried "$R4")" "$(pairs "owner $R4")" "the successor's second reply carries only its own message"
for pair in "$R1 $R2" "$R3 $R4"; do
  set -- $pair
  assert_eq "$(jq -s --arg a "$CH:$1" --arg b "$CH:$2" '[.[] | select(.delivery_id == $a or .delivery_id == $b) | .parent.thread[].ts] | length == (unique | length)' "$(sk_box "$ROOT")/to-lane.jsonl")" \
    "true" "no message reaches generation of $1 twice"
done

# An unreadable generation refuses the delivery rather than guess a reader.
generation '"x"'
reply 'Unreadable reader.' "$ROOT_TS" 2>"$SK_TMP/refused.err"
assert_eq "$RC=$(carried "$REPLY")" "1=" "a record whose generation cannot be read refuses the delivery"

# Controls plant defects in copies of the runtime, never in the checkout.
sk_mutant reader relay.py 'raise Refusal\("lane-mail-failed", f"\{command\} \{\(proc[^\n]*' 'return 0'
reply 'Read as zero.' "$ROOT_TS"
assert_eq "$RC" "0" "control: reading an unreadable generation as 0 breaks the refusal assertion"
sk_bin_reset
generation 2
sk_mutant mark relay.py 'mark = thread\.reads\.get\(generation\) if thread is not None else None' 'mark = None'
reply 'Unmarked one.' "$ROOT_TS"
reply 'Unmarked two.' "$ROOT_TS"
assert_has "$(carried "$REPLY")" "$ROOT_TS" "control: ignoring the delivery mark repeats the thread to its generation"
sk_bin_reset
generation 3
sk_mutant one-reader relay.py 'return int\(generation\)\n' 'return 0\n'
reply 'Same reader.' "$ROOT_TS"
assert_lacks "$(carried "$REPLY")" "$ROOT_TS" "control: one generation for every reader withholds the thread from a successor"
sk_bin_reset
generation 4
sk_mutant anyone relay.py 'return "owner" if message.get\("user"\) in owner_ids else None' 'return "owner"'
reply 'Everyone counts.' "$ROOT_TS"
assert_has "$(carried "$REPLY")" "$ASIDE" "control: carrying a non-owner's message breaks the owner-only assertion"
sk_bin_reset

# Catch-up must include app messages it already scanned but did not deliver.
# Slack's replies page is reused while handling each offline owner reply.
while read -r mode; do
  ROOT="$(sk_new_root "catch-up-$mode")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  ROOT_TS="$(post 'Offline topic.')"
  reply 'Read this first.' "$ROOT_TS"
  sk_poll "$ROOT"
  BETWEEN="$(post 'Progress before the offline reply.' "$ROOT_TS")"
  sk_poll "$ROOT"
  assert_eq "$RC=$(jq -r 'select(.t == "thread") | .seen' "$(sk_journal "$ROOT")" | tail -n 1)" \
    "0=$BETWEEN" "$mode: catch-up scans an app message after the reader delivery mark"
  AFTER="$(post 'More progress.' "$ROOT_TS")"
  OFFLINE="$(sk_inject "$CH" U001 'First offline reply.' "$ROOT_TS")"
  LATER="$(sk_inject "$CH" U001 'Second offline reply.' "$ROOT_TS")"
  if [ "$mode" = truncated-page-control ]; then
    sk_mutant truncated-page relay.py 'messages = page\[1\]' 'messages = page[1][:1]'
  fi
  sk_poll "$ROOT"
  assert_eq "$RC" 0 "$mode: offline replies reach the mailbox through catch-up"
  GOT="$(jq -sc --arg first "$CH:$OFFLINE" --arg later "$CH:$LATER" \
    '{first: [.[] | select(.delivery_id == $first) | .parent.thread[]], later: [.[] | select(.delivery_id == $later) | .parent.thread[]]}' \
    "$(sk_box "$ROOT")/to-lane.jsonl")"
  WANT="$(jq -nc --arg between "$BETWEEN" --arg after "$AFTER" --arg first "$OFFLINE" --arg later "$LATER" \
    '{first: [{ts:$between, author:"app", text:"Progress before the offline reply."}, {ts:$after, author:"app", text:"More progress."}, {ts:$first, author:"owner", text:"First offline reply."}], later: [{ts:$later, author:"owner", text:"Second offline reply."}]}')"
  if [ "$mode" = production ]; then
    assert_eq "$GOT" "$WANT" "catch-up carries complete unseen author, timestamp and text entries in order without repeats"
  else
    sk_assert_red "$GOT" "$WANT" "control: truncating the reused page fails the complete catch-up context assertion"
  fi
  sk_bin_reset
done <<'ROWS'
production
truncated-page-control
ROWS

# An old read thread keeps only the delivery rows needed by its generations.
# Live replies still arrive after its history and parent cache are pruned.
while read -r mode; do
  ROOT="$(sk_new_root "compact-$mode")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  RECORD="$ROOT/tmp/workflow-state-oversee.json"
  read -r OLD O1 O2 O3 <<< "$(python3 -c 'import time; t = time.time() - 9 * 86400; print(" ".join("%.6f" % (t + n) for n in range(4)))')"
  ROOT_TS="$(sk_inject "$CH" UBOT 'Old app topic.' '' "\"ts\":\"$OLD\",\"bot_id\":\"B01\"")"
  R1="$(sk_inject "$CH" U001 'First old reply.' "$ROOT_TS" "\"ts\":\"$O1\"")"
  sk_event "$ROOT" "$CH" "$R1"
  assert_eq "$RC" 0 "$mode: the first old reply reaches the mailbox"
  R2="$(sk_inject "$CH" U001 'Second old reply.' "$ROOT_TS" "\"ts\":\"$O2\"")"
  sk_event "$ROOT" "$CH" "$R2"
  generation 1
  R3="$(sk_inject "$CH" U001 'Successor old reply.' "$ROOT_TS" "\"ts\":\"$O3\"")"
  sk_event "$ROOT" "$CH" "$R3"
  sk_lm "$ROOT" inbox --item overseer > "$SK_TMP/old-inbox" || exit 1
  sk_poll "$ROOT"
  assert_eq "$RC=$(sk_reactions "$CH" "$R2")" '0=white_check_mark' "$mode: the old delivered reply is read before compaction"
  case "$mode" in
    retention-control) sk_mutant retention store.py 'retained = kind in \("in", "mark"\) and str\(line\["ts"\]\) in received' 'retained = False' ;;
    receipt-control) sk_mutant retained-receipt store.py 'drop = not \(pending or retained\)' 'drop = not pending' ;;
  esac
  sk_run -- compact --root "$ROOT"
  assert_eq "$RC" 0 "$mode: old history compacts"
  assert_eq "$(jq -sr --arg ts "$R1" '[.[] | select((.t == "in" or .t == "mark") and .ts == $ts)] | length' "$(sk_journal "$ROOT")")" \
    0 "$mode: compaction removes the superseded old delivery and its receipt marks"
  assert_eq "$(jq -sr '[.[] | select(.t == "parent" or .t == "thread")] | length' "$(sk_journal "$ROOT")")" \
    0 "$mode: compaction removes expired parent caches and thread scan positions"
  sk_ctl /_test/calls-reset >/dev/null
  sk_poll "$ROOT"
  GOT="$(sk_state '[.calls[] | select(. == "reactions.add" or . == "reactions.remove")] | length')"
  if [ "$mode" = receipt-control ]; then
    sk_assert_red "$GOT" 0 'control: dropping the retained read receipt repeats reaction writes after compaction'
  else
    assert_eq "$RC=$GOT" '0=0' "$mode: compacted read deliveries cause no new reaction writes"
  fi
  generation 0
  reply 'Continue the old topic.' "$ROOT_TS"; R4="$REPLY"
  GOT="$(carried "$R4")"
  WANT="$(pairs "owner $R3" "owner $R4")"
  if [ "$mode" = retention-control ]; then
    sk_assert_red "$GOT" "$WANT" 'control: dropping generation marks repeats old context in a later live reply'
  else
    assert_eq "$RC=$GOT" "0=$WANT" "$mode: the original generation receives only its unseen old reply and new reply after compaction"
    generation 1
    reply 'The successor continues.' "$ROOT_TS"
    assert_eq "$RC=$(carried "$REPLY")" "0=$(pairs "owner $R4" "owner $REPLY")" \
      "$mode: the successor delivery mark also survives old-thread compaction"
  fi
  sk_bin_reset
done <<'ROWS'
production
retention-control
receipt-control
ROWS

# Answers deliver only themselves. A successor must still receive earlier
# app messages and an answer delivered to the previous generation.
while read -r mode; do
  ROOT="$(sk_new_root "answer-$mode")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  RECORD="$ROOT/tmp/workflow-state-oversee.json"
  sk_lm "$ROOT" ask --item overseer --to owner --file "$(sk_text "question-$mode" 'Proceed with this task?')" --options yes,no --recommend no > "$SK_TMP/ask-receipt" || exit 1
  ASK="$(jq -r 'select(.kind == "ask") | .id' "$(sk_box "$ROOT")/to-overseer.jsonl")"
  sk_poll "$ROOT"
  ROOT_TS="$(sk_state ".messages.${CH}[] | select(.text | contains(\"Proceed with this task?\")) | .ts")"
  BEFORE="$(post 'Earlier unseen progress.' "$ROOT_TS")"
  reply yes "$ROOT_TS"; FIRST="$REPLY"
  sk_lm "$ROOT" inbox --item overseer > "$SK_TMP/first-answer" || exit 1
  assert_eq "$(jq -sc '[.[] | {kind,text}]' "$SK_TMP/first-answer")" '[{"kind":"answer","text":"yes"}]' \
    "$mode: the first generation reads the real mailbox answer"
  generation 1
  BETWEEN="$(post 'More unseen progress.' "$ROOT_TS")"
  case "$mode" in
    answer-watermark-control) sk_mutant answer-watermark store.py 'if line\["kind"\] == "directive":' 'if line["kind"] in ("directive", "answer"):' ;;
  esac
  reply no "$ROOT_TS"; SECOND="$REPLY"
  reply yes "$ROOT_TS"; THIRD="$REPLY"
  sk_lm "$ROOT" inbox --item overseer > "$SK_TMP/next-answers" || exit 1
  assert_eq "$(jq -sc '[.[] | {kind,text}]' "$SK_TMP/next-answers")" '[{"kind":"answer","text":"no"},{"kind":"answer","text":"yes"}]' \
    "$mode: the successor reads both accepted answers through the real inbox"
  sk_lm "$ROOT" resolve --item overseer --id "$ASK" >/dev/null || exit 1
  sk_poll "$ROOT"
  assert_eq "$RC=$(sk_reactions "$CH" "$THIRD")" '0=white_check_mark' "$mode: resolution and answer receipts settle before compaction"
  case "$mode" in
    answer-pruning-control) sk_mutant answer-pruning store.py 'retained = kind in \("in", "mark"\) and str\(line\["ts"\]\) in received' 'retained = False' ;;
    repeat-answer-control) sk_mutant repeat-answer relay.py ' and str\(message\["ts"\]\) not in answers:' ':' ;;
  esac
  # The production compactor accepts a cutoff. Advance that cutoff past
  # these settled deliveries without waiting for their retention horizon.
  python3 - "${SK_BIN%/*}/lib" "$ROOT" "$THIRD" <<'PY' || exit 1
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
from store import compact
compact(Path(sys.argv[2]), float(sys.argv[3]) + 1)
PY
  reply 'Continue after resolution.' "$ROOT_TS"
  GOT="$(carried "$REPLY")"
  WANT="$(pairs "app $ROOT_TS" "app $BEFORE" "owner $FIRST" "app $BETWEEN" "owner $REPLY")"
  if [ "$mode" = production ]; then
    assert_eq "$RC=$GOT" "0=$WANT" 'after answer resolution and compaction, the successor receives all unseen earlier messages but no accepted answer twice'
    reply 'Continue again.' "$ROOT_TS"
    assert_eq "$(carried "$REPLY")" "$(pairs "owner $REPLY")" 'a later directive repeats neither earlier context nor accepted answers'
    generation 2
    reply 'A new reader takes over.' "$ROOT_TS"
    assert_has "$(carried "$REPLY")" "$SECOND" 'an answer delivered to the previous generation reaches a new generation'
  else
    sk_assert_red "$GOT" "$WANT" "$mode: losing exact answer delivery knowledge or advancing the context mark breaks complete unseen context"
  fi
  sk_bin_reset
done <<'ROWS'
production
repeat-answer-control
answer-watermark-control
answer-pruning-control
ROWS

# Both live events and catch-up pages pass complete text to plain().
# The shipped post command preserves indentation and the final newline.
while read -r path mode; do
  ROOT="$(sk_new_root "whitespace-$path-$mode")"
  sk_bind "$ROOT"
  CH="$(sk_channel "$ROOT")"
  sk_poll "$ROOT"
  APP_BOUNDARY=$'    if ready:\n        proceed()\n'
  OWNER_BOUNDARY=$'\n\tKeep the indentation.  \n'
  sk_run -- post --root "$ROOT" --text "$APP_BOUNDARY"
  ROOT_TS="$(sk_state ".messages.${CH}[-1].ts")"
  assert_eq "$RC=$(sk_state ".messages.${CH}[-1] | .text | @json")" "0=$(jq -nc --arg text "$APP_BOUNDARY" '$text')" \
    "$path/$mode: the shipped post preserves the app text's boundary whitespace"
  if [ "$mode" = trim-control ]; then
    sk_mutant trim-context relay.py 'plain\(str\(message.get\("text"\) or ""\), self.user_name\)' 'plain(str(message.get("text") or "").strip(), self.user_name)'
  fi
  REPLY="$(sk_inject "$CH" U001 "$OWNER_BOUNDARY" "$ROOT_TS")"
  case "$path" in
    live) sk_event "$ROOT" "$CH" "$REPLY" ;;
    catch-up) sk_poll "$ROOT" ;;
  esac
  assert_eq "$RC" 0 "$path/$mode: the whitespace reply reaches the real mailbox"
  GOT="$(jq -c --arg d "$CH:$REPLY" 'select(.delivery_id == $d) | .parent.thread' "$(sk_box "$ROOT")/to-lane.jsonl")"
  WANT="$(jq -nc --arg root "$ROOT_TS" --arg app "$APP_BOUNDARY" --arg reply "$REPLY" --arg owner "$OWNER_BOUNDARY" \
    '[{ts:$root,author:"app",text:$app},{ts:$reply,author:"owner",text:$owner}]')"
  if [ "$mode" = production ]; then
    assert_eq "$GOT" "$WANT" "$path: complete app and owner text retains indentation, tabs, boundary spaces and final newlines with author and timestamp"
  else
    sk_assert_red "$GOT" "$WANT" "$path: trimming before plain fails the same complete message assertion"
  fi
  sk_bin_reset
done <<'ROWS'
live production
live trim-control
catch-up production
catch-up trim-control
ROWS

sk_summary
