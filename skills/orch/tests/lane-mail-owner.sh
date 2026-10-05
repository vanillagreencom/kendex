#!/usr/bin/env bash
# lane-mail's owner channel: the typed fields an overseer ask and notice carry,
# `resolve` closing an owner ask exactly once, `--delivery-id` landing a send
# once under the lock, `events` reading both files, and `pending --to` and
# `--due`. Each case builds an overseer checkout under TMP_ROOT and drives the
# real script; the lane-side verbs are tests/lane-mail.sh. The must-fail
# controls close the file, one per rule, each a copy of lane-mail or the
# library it sources with that rule removed: the one resolution, the delivery
# id, the attachment's confinement, the audience and deadline filters, the
# cursor rule, the reply's owner-ask read, the owner-note class a reply names,
# the ask's deadline field, the box `events` stamps, the owner ask's required
# recommendation, the cursor `events` refuses, the reply's delivery id, the
# referenced mailbox's read lock, a draft's medium, fields and text hash, and
# a reserved ask's field, its two conflicts, its --due exclusion and its
# --default refusal.
# The owner notice's day-long text rule keeps its controls beside its rows.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
# Canonical at creation: lane-mail records an attachment at its physical path,
# so every expectation built from LANE or BOX must name the same one.
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-owner: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-owner: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-owner: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# mutant_scripts and mutate_file, the two halves of the controls at the end.
# shellcheck source=lib/growth-state.sh
source "$REPO_ROOT/skills/orch/tests/lib/growth-state.sh"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# A fresh overseer checkout: a repository whose `.agents` tree holds the orch
# scripts, so `--item overseer` resolves its own mailbox and `--attach` finds
# workflow-state beside lane-mail.
LANE=""
BOX=""
new_repo() { # NAME
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE/.agents/skills/orch"
  git -C "$LANE" init -q
  git -C "$LANE" config gc.auto 0
  git -C "$LANE" config maintenance.auto false
  ln -sfn "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
  BOX="$LANE/tmp/lane-mail/overseer"
  mkdir -p "$LANE/tmp"
  printf '{"overseer":{"server":"7000","pane":"%%0"}}\n' > "$LANE/tmp/workflow-state-oversee.json"
}

RC=0
OUT=""
ERR=""
lm() { # ARGS...
  RC=0
  OUT="$(cd "$LANE" && env -u ORCH_ASK_WAIT_MINUTES -u ORCH_PROGRESS_REPORT_DIR \
    "${LANE_MAIL_BIN:-$LANE_MAIL}" "$@" 2>"$TMP_ROOT/err")" || RC=$?
  ERR="$(head -n 1 "$TMP_ROOT/err")"
}

text() { # NAME CONTENT
  printf '%s\n' "$2" > "$TMP_ROOT/$1.txt"
  printf '%s' "$TMP_ROOT/$1.txt"
}

# owner_ask CONTENT [OPTIONS] [RECOMMEND] [WAIT] — sets ASK to the id.
ASK=""
owner_ask() {
  local args=(ask --item overseer --to owner --file "$(text q "$1")")
  [[ -z "${2:-}" ]] || args+=(--options "$2")
  [[ -z "${3:-}" ]] || args+=(--recommend "$3")
  [[ -z "${4:-}" ]] || args+=(--wait "$4")
  lm "${args[@]}"
  ASK="${OUT#id=}"
}

# field FILE JQ — one jq read of the mailbox file.
field() { jq -r "$2" < "$1"; }

echo "=== lane-mail owner channel ==="

# --- the owner ask's fields ---------------------------------------------------
new_repo fields
owner_ask 'Cut the scanner?' cut,keep cut 30
assert_eq "$RC=${OUT%%=*}" "0=id" "an owner ask prints its id"
assert_eq "$(field "$BOX/to-overseer.jsonl" '[.to, .recommend, (.wait | tostring), .from] | join(" ")')" \
  "owner cut 30 overseer" "the ask carries its audience, recommendation and wait as fields"
assert_eq "$(field "$BOX/to-overseer.jsonl" '(.deadline | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) - (.at | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)')" \
  "1800" "the deadline is the stamp plus the wait, in seconds"

# The wait no ask names is the setting, read from the checkout's own file.
new_repo wait_setting
printf '[env]\nORCH_ASK_WAIT_MINUTES = "7"\n' > "$LANE/kendex.settings.toml"
owner_ask 'Settle it?' yes,no yes
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.wait')" "0=7" "an ask with no --wait takes ORCH_ASK_WAIT_MINUTES"
printf '[env]\nORCH_ASK_WAIT_MINUTES = "soon"\n' > "$LANE/kendex.settings.toml"
owner_ask 'Settle it?' yes,no yes
assert_eq "$RC=$ERR" "2=lane-mail: minutes-invalid=ORCH_ASK_WAIT_MINUTES=soon" \
  "a setting that is no number of minutes refuses the ask"
new_repo wait_default
owner_ask 'Settle it?' yes,no yes
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.wait')" "0=120" "with no setting the wait is 120 minutes"

# The overseer retries a silent notice or ask. Keep the clock fixed so the
# minute guard does not depend on how long the runner spends on these rows.
source "$REPO_ROOT/skills/orch/tests/lib/virtual-clock.sh"
mkdir -p "$TMP_ROOT/clock-bin"
virtual_clock_install "$TMP_ROOT/clock-bin" "$TMP_ROOT/clock"
SAVED_PATH="$PATH"; PATH="$TMP_ROOT/clock-bin:$PATH"
new_repo notice_receipt
for delivery in first second; do
  lm send --item overseer --directive --delivery-id "$delivery" --file "$(text d 'Reply owed.')"
done
REF_ROWS="$(jq -rs 'map(.id) | join(" ")' < "$BOX/to-lane.jsonl")" || exit 1
read -r -a REFS <<<"$REF_ROWS"
FIRST_ID=""
while IFS='|' read -r audience ref words want; do
  lm notice --item overseer --to "$audience" --ref "${REFS[$ref]}" --file "$(text n "$words")"
  if [[ "$want" == duplicate ]]; then
    assert_eq "$RC=$ERR=$OUT=$(field "$BOX/to-overseer.jsonl" '.id')" \
      "2=lane-mail: duplicate id=$FIRST_ID==$FIRST_ID" "notice repeat refuses before appending"
  elif [[ "$want" == repeated ]]; then
    assert_eq "$RC=$ERR=$OUT=$(field "$BOX/to-overseer.jsonl" '.id')" \
      "2=lane-mail: owner-notice-repeated=overseer id=$FIRST_ID==$FIRST_ID" \
      "an owner notice text the owner holds refuses whatever its reference"
  else
    ID="$(jq -rs 'last.id' < "$BOX/to-overseer.jsonl")" || exit 1
    assert_eq "$RC=$OUT" "0=lane-mail: sent item=overseer id=$ID bytes=6 to=$audience ref=${REFS[$ref]}" \
      "notice $want prints its appended receipt"
    [[ -n "$FIRST_ID" ]] || FIRST_ID="$ID"
  fi
done <<'ROWS'
owner|0|Reply.|first
owner|0|Reply.|duplicate
owner|1|Reply.|repeated
owner|0|Other.|changed-text
ROWS
owner_ask 'Retry?' yes,no yes
FIRST_ASK="$ASK"
sleep 5
owner_ask 'Retry?' yes,no yes
ASK_REPEAT_WANT="2=lane-mail: duplicate id=$FIRST_ASK=$FIRST_ASK"
ASK_REPEAT_ASSERTION="an owner ask retry after the clock advances refuses without appending"
assert_eq "$RC=$ERR=$(field "$BOX/to-overseer.jsonl" 'select(.kind == "ask") | .id')" \
  "$ASK_REPEAT_WANT" "$ASK_REPEAT_ASSERTION"
# Caller changes remain distinct even while the generated deadline moves.
while IFS='|' read -r name words options recommend wait advance; do
  new_repo "ask_$name"
  owner_ask 'Retry?' yes,no yes
  sleep "$advance"
  owner_ask "$words" "$options" "$recommend" "$wait"
  assert_eq "$RC=$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')" "0=2" "ask $name lands a new row"
done <<'ROWS'
wait|Retry?|yes,no|yes|121|5
recommend|Retry?|yes,no|no||5
options|Retry?|yes,no,later|yes||5
text|Other?|yes,no|yes||5
expired|Retry?|yes,no|yes||61
ROWS
new_repo control_ask_retry
owner_ask 'Retry?' yes,no yes
FIRST_ASK="$ASK"
ASK_REPEAT_WANT="2=lane-mail: duplicate id=$FIRST_ASK=$FIRST_ASK"
mutant_dir="$(mutant_scripts mutants/ask-retry lib/mailbox-append.sh)" || exit 1
mutate_file "$mutant_dir/lib/mailbox-append.sh" '.deadline = ($deadline - $stamp)' '. # .deadline = ($deadline - $stamp)'
sleep 5
LANE_MAIL_BIN="$mutant_dir/lane-mail" owner_ask 'Retry?' yes,no yes
CONTROL_RC=0
CONTROL_OUT="$(
  FAIL=0
  assert_eq "$RC=$ERR=$(field "$BOX/to-overseer.jsonl" 'select(.kind == "ask") | .id')" \
    "$ASK_REPEAT_WANT" "$ASK_REPEAT_ASSERTION"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$RC=$CONTROL_RC=$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')" "0=1=2" \
  "control: the advancing-clock retry assertion fails without deadline normalization"
# Chat answers use send --re without a delivery key while the ask stays open.
# Both controls keep the semantic guard and remove one append-owner rule.
while IFS='~' read -r name old replacement want; do
  new_repo "answer_repeat_$name"
  owner_ask 'Which?' a,b a
  lm send --item overseer --re "$ASK" --file "$(text a b)"
  FIRST="$(field "$BOX/to-lane.jsonl" '.id')"
  bin="$LANE_MAIL"
  if [[ -n "$old" ]]; then
    dir="$(mutant_scripts "mutants/answer-repeat-$name" lane-mail)" || exit 1
    mutate_file "$dir/lane-mail" "$old" "$replacement"; bin="$dir/lane-mail"
  fi
  LANE_MAIL_BIN="$bin" lm send --item overseer --re "$ASK" --file "$(text a b)"
  control_rc=0
  (FAIL=0; assert_eq "$RC=$ERR=$(field "$BOX/to-lane.jsonl" '.id')" \
    "2=lane-mail: duplicate id=$FIRST=$FIRST" "unkeyed owner answer retry refuses without appending"; [[ "$FAIL" -eq 0 ]]) \
    >"$TMP_ROOT/answer-repeat-assertion" || control_rc=$?
  assert_eq "$control_rc" "$want" "$name: the owner answer retry assertion detects either missing rule" "$TMP_ROOT/answer-repeat-assertion"
  if [[ "$name" == live ]]; then
    lm resolve --item overseer --id "$ASK"
    CLOSE="$(field "$BOX/to-lane.jsonl" 'select(.kind == "resolution") | .id')"
    lm send --item overseer --re "$ASK" --file "$(text a c)"
    assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$CLOSE" "unkeyed new answer after close retains its semantic refusal"
  fi
done <<'ROWS'
live~~~0
eligibility~[ "$VERB" != resolve ] && [ -z "$DELIVERY_ID" ] && [ "${3:-}" != : ]~false && [ "$VERB" != resolve ] && [ -z "$DELIVERY_ID" ] && [ "${3:-}" != : ]~1
refusal~[ "${report#duplicate id=}" != "$report" ] || return 4~[ "${report#duplicate id=}" != "$report" ] && return 4~1
ROWS
PATH="$SAVED_PATH"

# --- an owner notice's text, judged for a day ---------------------------------
# One owner notice, `Report.` with no attachment, planted AGE seconds back in
# BOX's to-overseer.jsonl: a report summary sent by hand before `write` sends
# it again with its file. Planted, so no row waits on a clock. @A is a report
# file and @F the message file holding WORDS. A row's result is the send's
# status, its refusal line, and the lines BOX's file then holds; a send that
# lands carries no refusal, and the notes other rules print beside it, a peer
# ask's `no-reader` among them, are theirs.
# NAME|AGE|BOX|WORDS|ARGS|WANT
OWNER_REPEAT_ROWS='attach|210|overseer|Report.|notice --item overseer --to owner --attach @A --file @F|2=lane-mail: owner-notice-repeated=overseer id=planted=1
day-old|90000|overseer|Report.|notice --item overseer --to owner --attach @A --file @F|0==2
changed-text|210|overseer|Report two.|notice --item overseer --to owner --attach @A --file @F|0==2
lane-notice|210|KEN-1|Report.|notice --item KEN-1 --file @F|0==2
owner-ask|210|overseer|Report.|ask --item overseer --to owner --options yes,no --recommend yes --file @F|0==2
peer-ask|210|overseer|Report.|peer ask --repo repeat_peer --options yes,no --file @F|0==2'
new_repo repeat_peer
REPEAT=""
REPEAT_WANT=""
owner_repeat() { # NAME
  local row name age box words args want file at reports
  row="$(grep -e "^$1|" <<<"$OWNER_REPEAT_ROWS")" || { echo "lane-mail-owner: row=$1" >&2; exit 1; }
  IFS='|' read -r name age box words args want <<<"$row"
  new_repo "repeat_$name"
  file="$LANE/tmp/lane-mail/$box/to-overseer.jsonl"
  mkdir -p "${file%/*}"
  reports="$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" progress-report-path)" || exit 1
  reports="${reports%/*}"
  echo "a report" > "$reports/10-02-03-10.md"
  at="$(jq -rn --argjson age "$age" '(now | floor) - $age | todate')" || exit 1
  jq -cn --arg at "$at" '{id: "planted", kind: "notice", at: $at, from: "overseer", to: "owner", text: "Report."}' >> "$file"
  args="${args//@A/$reports/10-02-03-10.md}"
  args="${args//@F/$(text n "$words")}"
  # shellcheck disable=SC2086  # a row's arguments are its own words.
  lm $args
  [[ "$RC" -ne 0 ]] || ERR=""
  REPEAT="$RC=$ERR=$(wc -l < "$file" | tr -d ' ')"
  REPEAT_WANT="$want"
}
while IFS='|' read -r name _; do
  owner_repeat "$name"
  assert_eq "$REPEAT" "$REPEAT_WANT" "owner notice repeat: $name"
done <<<"$OWNER_REPEAT_ROWS"
# Each control is a copy of lane-mail with one part of the rule removed, run
# against the row that rule decides: the guard itself, the attachment left out
# of the comparison, and the 24-hour age test.
while IFS='~' read -r control row old new; do
  dir="$(mutant_scripts "mutants/owner-repeat-$control" lane-mail)" || exit 1
  mutate_file "$dir/lane-mail" "$old" "$new"
  LANE_MAIL_BIN="$dir/lane-mail" owner_repeat "$row"
  control_rc=0
  (FAIL=0; assert_eq "$REPEAT" "$REPEAT_WANT" "owner notice repeat: $row"; [[ "$FAIL" -eq 0 ]]) \
    >"$TMP_ROOT/owner-repeat-assertion" || control_rc=$?
  assert_eq "$control_rc" 1 "control $control: the $row row turns red" "$TMP_ROOT/owner-repeat-assertion"
done <<'ROWS'
guard-removed~attach~if [ "$VERB:$TO" = notice:owner ]; then~if false; then
attach-compared~attach~.text == $candidate.text)~.text == $candidate.text and .attach == $candidate.attach)
age-dropped~day-old~($now - $at) <= 86400)~($now - $at) <= 86400 or true)
ROWS

FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
REMOTE_DISK="$TMP_ROOT/repeat-remote"
STUB_LOG="$TMP_ROOT/repeat-host.log"
# Both senders reach the append while a third process holds its lock. The
# markers instrument a disposable library, not the sender or the repeat rule.
# A fixed clock gives both envelopes the same second, as Copilot reports do.
race_repeats() { # NAME MODE ACTION LIB
  local name="$1" mode="$2" action="$3" lib="$4" sender receiver box n holder first codes
  local pids=() args=()
  new_repo "repeat-$name-sender"; sender="$LANE"
  new_repo "repeat-$name-receiver"; receiver="$LANE"
  case "$action" in
    ask) args=(ask --item overseer --to owner --options keep,stop --recommend keep); box="$sender/tmp/lane-mail/overseer/to-overseer.jsonl" ;;
    notice) args=(notice --item overseer --to owner); box="$sender/tmp/lane-mail/overseer/to-overseer.jsonl" ;;
    send) args=(send --item overseer --directive --root "$sender"); box="$sender/tmp/lane-mail/overseer/to-lane.jsonl" ;;
    send-peer | ask-peer) args=(peer "${action%-peer}" --repo "$receiver"); box="$receiver/tmp/lane-mail/overseer/to-lane.jsonl" ;;
    *) echo "lane-mail suite: action=$action" >&2; exit 1 ;;
  esac
  if [ "$mode" = hosted ]; then args+=(--host); box="$REMOTE_DISK$box"; fi
  mkdir -p -- "${box%/*}" "$TMP_ROOT/repeat-home"
  : > "$box"
  printf 'one progress report\n' > "$TMP_ROOT/repeat.txt"
  hold_lock "$box" "$name" & holder=$!
  await_marker "$TMP_ROOT/$name.taken" || exit 1
  for n in 1 2; do
    (cd -- "$sender" && rc=0
      env -i PATH="$TMP_ROOT/clock-bin:$PATH" HOME="$TMP_ROOT/repeat-home" LC_ALL=C \
        STUB_CLOCK="$STUB_CLOCK" STUB_REAL_DATE="$STUB_REAL_DATE" STUB_REAL_SLEEP="$STUB_REAL_SLEEP" \
        RACE_MARKER="$TMP_ROOT/$name-$n.waiting" ORCH_LANE_HOST="$FIXTURE_HOST" \
        LANE_HOST_STUB_LOG="$STUB_LOG" LANE_HOST_STUB_DIR="$REMOTE_DISK" LANE_HOST_STUB_LIB="$lib" \
        "$lib/../lane-mail" "${args[@]}" --file "$TMP_ROOT/repeat.txt" \
        >"$TMP_ROOT/$name-$n.out" 2>"$TMP_ROOT/$name-$n.err" || rc=$?
      printf '%s\n' "$rc" >"$TMP_ROOT/$name-$n.rc") &
    pids+=("$!")
  done
  for n in 1 2; do await_marker "$TMP_ROOT/$name-$n.waiting" || exit 1; done
  : > "$TMP_ROOT/$name.release"
  wait "$holder" "${pids[@]}"
  first="$(jq -r '.id' "$box" | sed -n '1p')" || exit 1
  codes="$(sort -n "$TMP_ROOT/$name-1.rc" "$TMP_ROOT/$name-2.rc" | tr '\n' ',')" || exit 1
  RACE_RESULT="$codes|$(wc -l < "$box" | tr -d ' ')|$(sed -n '/^lane-mail: duplicate /p' "$TMP_ROOT/$name-1.err" "$TMP_ROOT/$name-2.err")"
  RACE_WANT="0,2,|1|lane-mail: duplicate id=$first"
}
RACE_DIR="$(mutant_scripts fixtures/repeat-lock lib/mailbox-append.sh)" || exit 1
mutate_file "$RACE_DIR/lib/mailbox-append.sh" '  if ! orch_take_lock 9 "$1" "$2"; then' \
  '  : > "$RACE_MARKER"
  if ! orch_take_lock 9 "$1" "$2"; then'
EARLY_DIR="$(mutant_scripts mutants/repeat-before-lock lib/mailbox-append.sh)" || exit 1
mutate_file "$EARLY_DIR/lib/mailbox-append.sh" '  local duplicate=""' \
  '  local duplicate=""
  [ -z "${4:-}" ] || duplicate="$(mailbox_duplicate_id "$1" "$4")" || return 2'
mutate_file "$EARLY_DIR/lib/mailbox-append.sh" '    if ! duplicate="$(mailbox_duplicate_id "$1" "$4")"; then' \
  '    if false; then # if ! duplicate="$(mailbox_duplicate_id "$1" "$4")"; then'
mutate_file "$EARLY_DIR/lib/mailbox-append.sh" '  if ! orch_take_lock 9 "$1" "$2"; then' \
  '  : > "$RACE_MARKER"
  if ! orch_take_lock 9 "$1" "$2"; then'
for implementation in live early; do
  lib="$RACE_DIR/lib"; [ "$implementation" != early ] || lib="$EARLY_DIR/lib"
  while IFS='|' read -r name mode action; do
    race_repeats "$implementation-$name" "$mode" "$action" "$lib"
    control_rc=0
    (FAIL=0; assert_eq "$RACE_RESULT" "$RACE_WANT" "identical $mode $action writers refuse under the append lock"; [[ "$FAIL" -eq 0 ]]) \
      >"$TMP_ROOT/repeat-assertion" || control_rc=$?
    want=0; [ "$implementation" != early ] || want=1
    assert_eq "$control_rc" "$want" "$implementation $name: the locked repeat assertion turns red with an early read" "$TMP_ROOT/repeat-assertion"
  done <<'ROWS'
ask|local|ask
notice|local|notice
send|local|send
peer-send|local|send-peer
peer-ask|local|ask-peer
host-send|hosted|send
host-peer-send|hosted|send-peer
host-peer-ask|hosted|ask-peer
ROWS
done

# --- refusals, one row per rule -----------------------------------------------
new_repo refusals
lm notice --item overseer --to owner --file "$(text n 'A note.')"
NOTE_TO_OWNER="$(field "$BOX/to-overseer.jsonl" '.id')"
lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
owner_ask 'Which?' a,b a
ASK_TO_OWNER="$ASK"
lm resolve --item overseer --id "$ASK_TO_OWNER" --text "$(text a 'a')"
RESOLUTION="$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer") | .id')"
# A peer ask leaves the asker's own record in this mailbox with `to: peer`,
# which resolve closes no more than it closes this overseer's own notice; the
# peer's ask the other way lands in to-lane.jsonl beside the owner's notes.
REFUSALS="$LANE"
new_repo peer
lm peer ask --repo refusals --file "$(text q 'Mine?')" --options yes,no
INBOUND_PEER="${OUT#id=}"
LANE="$REFUSALS"; BOX="$LANE/tmp/lane-mail/overseer"
lm peer ask --repo peer --file "$(text q 'Yours?')" --options yes,no
PEER_ASK="${OUT#id=}"
# ARGS|WANT (rc=first stderr line); F is the message file. A --ref answers an
# owner note or an owner ask; a notice of this overseer's own, a peer's line
# and a resolution are none of them.
F="$TMP_ROOT/q.txt"
while IFS='|' read -r args want; do
  # shellcheck disable=SC2086  # a row's arguments are its own words.
  lm $args
  assert_eq "$RC=$ERR" "$want" "refused: $args"
done <<ROWS
ask --item overseer --file $F|2=lane-mail: option-required=--to
ask --item KEN-1 --to owner --file $F|2=lane-mail: option-unknown=--to
ask --item overseer --to peer --file $F|2=lane-mail: to-invalid=peer
ask --item overseer --to nobody --file $F|2=lane-mail: to-invalid=nobody
ask --item overseer --to owner --options a,b --recommend c --file $F|2=lane-mail: recommend-invalid=c
ask --item overseer --to owner --options a,b --recommend a,b --file $F|2=lane-mail: recommend-invalid=a,b
ask --item overseer --to owner --file $F|2=lane-mail: recommend-required=owner
ask --item overseer --to owner --options a,b --wait 5 --file $F|2=lane-mail: recommend-required=owner
ask --item overseer --to owner --recommend a --file $F|2=lane-mail: option-required=--options
ask --item overseer --to owner --options a,b --recommend a --wait 5m --file $F|2=lane-mail: minutes-invalid=--wait
ask --item overseer --to owner --options a,b --recommend a --reserved --file $F|2=lane-mail: option-conflict=--reserved,--recommend
ask --item overseer --to owner --reserved --file $F|2=lane-mail: option-required=--options
ask --item KEN-1 --options a,b --reserved --file $F|2=lane-mail: option-unknown=--reserved
notice --item KEN-1 --ref $OWNER_NOTE --file $F|2=lane-mail: option-unknown=--ref
notice --item overseer --to owner --ref no/such --file $F|2=lane-mail: ref-invalid=no/such
notice --item overseer --to owner --ref 1790000000-1-1 --file $F|2=lane-mail: ref-unknown=1790000000-1-1
notice --item overseer --to owner --ref $NOTE_TO_OWNER --file $F|2=lane-mail: ref-unknown=$NOTE_TO_OWNER
notice --item overseer --to owner --ref $ASK_TO_OWNER --file $F|0=
notice --item overseer --to owner --ref $PEER_ASK --file $F|2=lane-mail: ref-unknown=$PEER_ASK
notice --item overseer --to owner --ref $INBOUND_PEER --file $F|2=lane-mail: ref-unknown=$INBOUND_PEER
notice --item overseer --to owner --ref $RESOLUTION --file $F|2=lane-mail: ref-unknown=$RESOLUTION
ask --item overseer --to owner --options a,b --recommend a --ref 1790000000-1-1 --file $F|2=lane-mail: ref-unknown=1790000000-1-1
ask --item overseer --to owner --options a,b --recommend a --attach x --file $F|2=lane-mail: option-unknown=--attach
notice --item KEN-1 --attach x --file $F|2=lane-mail: option-unknown=--attach
send --item overseer --re $OWNER_NOTE --file $F|2=lane-mail: ask-unknown=$OWNER_NOTE
send --item overseer --directive --host --root $LANE --delivery-id k --file $F|2=lane-mail: option-conflict=--host,--delivery-id
send --item overseer --directive --default --file $F|2=lane-mail: option-unknown=--default
resolve --item KEN-1 --id x --default|2=lane-mail: overseer-only=KEN-1
resolve --item overseer --default|2=lane-mail: option-required=--id
resolve --item overseer --id x|2=lane-mail: ask-unknown=x
resolve --item overseer --id x --default --text $F|2=lane-mail: option-conflict=--text,--default
resolve --item overseer --id 1790000000-1-1 --default|2=lane-mail: ask-unknown=1790000000-1-1
resolve --item overseer --id $PEER_ASK --text $F|2=lane-mail: ask-unknown=$PEER_ASK
resolve --item overseer --id $NOTE_TO_OWNER --text $F|2=lane-mail: ask-unknown=$NOTE_TO_OWNER
drain --item overseer --after 0 --to owner|2=lane-mail: option-unknown=--to
inbox --item overseer --due|2=lane-mail: option-unknown=--due
events --item overseer --after 0|2=lane-mail: events-no-cursor=--after
pending --item overseer --after 3|2=lane-mail: option-unknown=--after
ROWS
lm notice --item overseer --to owner --file "$(text n 'Reply.')" --ref "$OWNER_NOTE"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" 'select(.text == "Reply.") | .ref')" "0=$OWNER_NOTE" \
  "a reply names the owner note it answers"

# The host worker sends a voice request as an owner note with --delivery-id.
# A reply carries that id only when --ref names the delivered request; a plain
# owner note and an unreferenced notice produce no reply-delivery field.
while IFS='|' read -r name delivery referenced has_delivery; do
  new_repo "reply_$name"
  args=(send --item overseer --directive --file "$(text d 'Owner request.')")
  [[ -z "$delivery" ]] || args+=(--delivery-id "$delivery")
  lm "${args[@]}"
  assert_eq "$RC" "0" "$name: the owner request lands"
  OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
  args=(notice --item overseer --to owner --file "$(text n 'Reply.')")
  WANT_REF=""; WANT_DELIVERY=""
  if [[ "$referenced" == yes ]]; then
    args+=(--ref "$OWNER_NOTE")
    WANT_REF="$OWNER_NOTE"; WANT_DELIVERY="$delivery"
  fi
  lm "${args[@]}"
  assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '[.ref // "", has("re_delivery_id"), .re_delivery_id // ""] | map(tostring) | join("|")')" \
    "0=$WANT_REF|$has_delivery|$WANT_DELIVERY" "$name: the notice carries only the referenced delivery"
  lm events --item overseer
  assert_eq "$RC=$(jq -r 'select(.kind == "notice") | [.box, has("re_delivery_id"), .re_delivery_id // ""] | map(tostring) | join("|")' <<<"$OUT")" \
    "0=to-overseer|$has_delivery|$WANT_DELIVERY" "$name: events exports the reply binding without a lookup"
done <<'ROWS'
delivered|voice:request-1|yes|true
plain||yes|false
unreferenced|voice:request-1|no|false
ROWS

# An owner ask raised while answering the request binds to it the same way.
ASK_BINDING='select(.kind == "ask") | [.ref // "", .re_delivery_id // ""] | join("|")'
new_repo reply_ask
lm send --item overseer --directive --file "$(text d 'Voice request.')" --delivery-id voice:request-1
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
lm ask --item overseer --to owner --options approve,deny --recommend deny --ref "$OWNER_NOTE" --file "$(text q 'Approve?')"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" "$ASK_BINDING")" "0=$OWNER_NOTE|voice:request-1" \
  "an owner ask names the voice request and copies its delivery id"

# --- the attachment's confinement --------------------------------------------
new_repo attach
REPORTS="$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" progress-report-path)"
REPORTS="${REPORTS%/*}"
echo "a report" > "$REPORTS/09-26-01-00.md"
mkdir -p "$REPORTS/deeper" "$LANE/elsewhere"
echo "nested" > "$REPORTS/deeper/09-26-01-01.md"
echo "outside" > "$LANE/elsewhere/09-26-01-02.md"
ln -s "$LANE/elsewhere/09-26-01-02.md" "$REPORTS/09-26-01-03.md"
ln -s "$REPORTS" "$LANE/reports-link"
# PATH|WANT
while IFS='|' read -r path want; do
  lm notice --item overseer --to owner --file "$(text n 'Report.')" --attach "$path"
  [[ "$want" != duplicate ]] || want="2=lane-mail: duplicate id=$ATTACH_ID"
  assert_eq "$RC=$ERR" "$want" "attach $path"
  [[ "$RC" != 0 ]] || ATTACH_ID="$(field "$BOX/to-overseer.jsonl" '.id')"
done <<ROWS
$REPORTS/09-26-01-00.md|0=
tmp/progress-reports/09-26-01-00.md|duplicate
$REPORTS/deeper/09-26-01-01.md|2=lane-mail: attach-outside=$REPORTS/deeper/09-26-01-01.md
$LANE/elsewhere/09-26-01-02.md|2=lane-mail: attach-outside=$LANE/elsewhere/09-26-01-02.md
$REPORTS/09-26-01-03.md|2=lane-mail: attach-outside=$REPORTS/09-26-01-03.md
$LANE/reports-link/09-26-01-00.md|duplicate
$REPORTS|2=lane-mail: attach-outside=$REPORTS
ROWS
assert_eq "$(field "$BOX/to-overseer.jsonl" '.attach' | sort -u)" "$(cd "$REPORTS" && pwd -P)/09-26-01-00.md" \
  "every accepted attachment is recorded at its one physical path"

# --- pending --to and --due ---------------------------------------------------
new_repo pending
owner_ask 'Due now?' a,b a 0
DUE="$ASK"
owner_ask 'Due later?' a,b b 120
LATER="$ASK"
lm send --item overseer --directive --file "$(text d 'Unread directive.')"
lm pending --item overseer
assert_eq "$(jq -r '.kind' <<<"$OUT" | sort | uniq -c | awk '{ print $2 "=" $1 }' | paste -sd, -)" "ask=2,directive=1" \
  "pending without --to lists every ask and the unread directive"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE,$LATER" \
  "pending --to owner lists the owner asks and no directive"
lm pending --item overseer --to peer
assert_eq "$RC=$OUT" "0=" "pending --to peer lists none of them"
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE" \
  "--due keeps the ask whose deadline has passed alone, not the later one"
# A cursor read that missed, the lock standing beside no cursor, refuses the
# listing that would print directives against it and nothing else: the asks
# --to and --due keep read no cursor, so the watch's deadline step and the
# report's Waiting on you row list them whatever the cursor read did.
touch "$BOX/to-lane.cursor.lock"
lm pending --item overseer
assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=overseer cursor=missed" \
  "a bare pending over a cursor read that missed is refused"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE,$LATER" \
  "pending --to owner over the same missed read lists the owner asks, reading no cursor"
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.id' <<<"$OUT" | paste -sd, -)" "0=$DUE" "and --due lists the due one"
rm -f -- "${BOX:?}/to-lane.cursor.lock"

# --- the draft ask -------------------------------------------------------------
draft_file() { # NAME JSON
  printf '%s' "$2" > "$TMP_ROOT/$1.json"
  printf '%s' "$TMP_ROOT/$1.json"
}
draft_ask() { # DRAFT [ARGS...] — sets ASK to the id.
  local draft="$1"
  shift
  lm ask --item overseer --to owner --file "$(text q 'Send it as the owner?')" --draft "$draft" "$@"
  ASK="${OUT#id=}"
}
# The expected hash comes from the bytes the test wrote, never from lane-mail.
sha256_of() { # FILE
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1"; else shasum -a 256 < "$1"; fi | cut -d ' ' -f 1
}
# The one ask in BOX records exactly FILE's bytes as its draft text, and a
# text_hash taken over those bytes.
assert_draft_text() { # FILE
  jq -j '.draft.text' < "$BOX/to-overseer.jsonl" > "$TMP_ROOT/draft.recorded" || exit 1
  assert_eq "$(sha256_of "$TMP_ROOT/draft.recorded") $(field "$BOX/to-overseer.jsonl" '.draft.text_hash')" \
    "$(sha256_of "$1") $(sha256_of "$1")" "the draft text is the file's exact string and text_hash its SHA-256"
}
DRAFT_BYTES="$TMP_ROOT/draft.bytes"
printf 'Grüße an alle\n' > "$DRAFT_BYTES"
DRAFT_JSON='{"recipient":"#launch","medium":"slack-channel","text":"Grüße an alle\n"}'
# Two drafts in one file, each valid alone: one ask approves one message.
TWO_DRAFTS='{"recipient":"r","medium":"email","text":"x"} {"recipient":"r","medium":"email","text":"y"}'

new_repo draft
draft_ask "$(draft_file d "$DRAFT_JSON")" --wait 30
assert_eq "$RC=${OUT%%=*}" "0=id" "a draft ask prints its id"
assert_eq "$(field "$BOX/to-overseer.jsonl" '[(.options | join(",")), .recommend, has("deadline"), (.draft | keys | join(","))] | map(tostring) | join(" ")')" \
  "approve,deny deny true medium,recipient,text,text_hash" "a draft ask fixes approve,deny with deny standing at its deadline"
assert_draft_text "$DRAFT_BYTES"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '.draft.text_hash' <<<"$OUT")" "0=$(sha256_of "$DRAFT_BYTES")" "pending prints the draft ask with its text_hash"
lm send --item overseer --re "$ASK" --file "$(text a approve)"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '.id' <<<"$OUT")" "0=$ASK" "an owner answer leaves the draft ask pending"

new_repo draft_media
for medium in slack-thread email; do
  draft_ask "$(draft_file "$medium" '{"recipient":"r","medium":"'"$medium"'","text":"Ship it."}')"
  assert_eq "$RC=$(jq -rs 'last.draft.medium' < "$BOX/to-overseer.jsonl")" "0=$medium" "a $medium draft lands"
done

# A draft past what one exec can carry (128 KiB per argument on Linux, 1 MiB
# for the whole argv on macOS) lands whole: its record reaches the envelope
# through a file, never jq's argv.
LARGE_BYTES="$TMP_ROOT/draft.large"
head -c 1179648 /dev/zero | tr '\0' 'x' > "$LARGE_BYTES" || exit 1
jq -n --rawfile text "$LARGE_BYTES" '{recipient: "r", medium: "email", text: $text}' > "$TMP_ROOT/large.json" || exit 1
new_repo draft_large
draft_ask "$TMP_ROOT/large.json"
assert_eq "$RC=${OUT%%=*}" "0=id" "a draft past one exec's argument cap lands"
assert_draft_text "$LARGE_BYTES"

# One changed character is a new message: a new ask with its own hash.
new_repo draft_edit
draft_ask "$(draft_file d "$DRAFT_JSON")"
draft_ask "$(draft_file e "${DRAFT_JSON/alle/alle!}")"
assert_eq "$RC=$(jq -rs '[(map(.id) | unique | length), (map(.draft.text_hash) | unique | length)] | map(tostring) | join(",")' < "$BOX/to-overseer.jsonl")" \
  "0=2,2" "an edited draft lands under a new id and a different hash"

# ARGS~DRAFT~WANT: every refusal leaves the one draft ask already there alone.
new_repo draft_refusals
VALID="$(draft_file valid "$DRAFT_JSON")"
draft_ask "$VALID"
D="$TMP_ROOT/refused.json"
while IFS='~' read -r args json want; do
  if [[ "$json" == VALID ]]; then cp -- "$VALID" "$D"; else printf '%s' "$json" > "$D"; fi
  # shellcheck disable=SC2086  # a row's arguments are its own words.
  lm $args --file "$(text q 'Send it?')" --draft "$D"
  assert_eq "$RC=$ERR=$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')" "$want=1" "draft refused: $args $json"
done <<ROWS
ask --item overseer --to owner~{"medium":"email","text":"x"}~2=lane-mail: draft-field=recipient
ask --item overseer --to owner~{"recipient":"r","medium":"","text":"x"}~2=lane-mail: draft-field=medium
ask --item overseer --to owner~{"recipient":"r","medium":"email","text":" \n\t"}~2=lane-mail: draft-field=text
ask --item overseer --to owner~{"recipient":"r","medium":"email","text":"x","text_hash":"00"}~2=lane-mail: draft-field=text_hash
ask --item overseer --to owner~{"recipient":"r","medium":"email","text":3}~2=lane-mail: draft-field=text
ask --item overseer --to owner~{"recipient":"r","medium":"fax","text":"x"}~2=lane-mail: draft-medium=fax
ask --item overseer --to owner~{"recipient":"r",~2=lane-mail: file-unreadable=$D
ask --item overseer --to owner~["r","email","x"]~2=lane-mail: file-unreadable=$D
ask --item overseer --to owner~$TWO_DRAFTS~2=lane-mail: file-unreadable=$D
ask --item overseer --to owner --options approve,deny~VALID~2=lane-mail: option-conflict=--draft,--options
ask --item overseer --to owner --recommend deny~VALID~2=lane-mail: option-conflict=--draft,--recommend
ask --item overseer --to owner --options approve,deny --reserved~VALID~2=lane-mail: option-conflict=--reserved,--draft
ask --item KEN-1~VALID~2=lane-mail: option-unknown=--draft
notice --item overseer --to owner~VALID~2=lane-mail: option-unknown=--draft
ROWS

# --- the reserved ask ----------------------------------------------------------
# An owner-reserved decision names no default, so its deadline closes nothing:
# --due leaves it out, resolve --default refuses it, and the owner's text
# answer closes it.
reserved_ask() { # [ARGS...] — sets ASK to the id.
  lm ask --item overseer --to owner --file "$(text q 'Cut kendex 2.0.0?')" --options cut,hold --reserved "$@"
  ASK="${OUT#id=}"
}
default_answers() {
  if [[ -f "$BOX/to-lane.jsonl" ]]; then jq -rs '[.[] | select(.by == "default")] | length' "$BOX/to-lane.jsonl"; else echo 0; fi
}
new_repo reserved
reserved_ask --wait 0
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '[.reserved, has("recommend"), has("deadline")] | map(tostring) | join(" ")')" \
  "0=true false true" "a reserved ask records reserved and a deadline, and no recommendation"
lm pending --item overseer --to owner --due
assert_eq "$RC=$OUT" "0=" "--due leaves out a reserved ask past its deadline"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '.id' <<<"$OUT")" "0=$ASK" "past its deadline the reserved ask stays pending"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR=$(default_answers)" "2=lane-mail: ask-reserved=$ASK=0" \
  "resolve --default refuses the reserved ask and writes no default answer"
lm resolve --item overseer --id "$ASK" --text "$(text a 'hold until Monday')"
ANSWER="$(field "$BOX/to-lane.jsonl" 'select(.kind == "resolution") | .id')"
assert_eq "$RC=$OUT" "0=lane-mail: resolved id=$ASK by=text answer=$ANSWER" "the owner's text answer closes the reserved ask"
lm pending --item overseer --to owner
assert_eq "$RC=$OUT" "0=" "the answered reserved ask is no longer pending"

# --- resolve, exactly once ----------------------------------------------------
new_repo resolve
owner_ask 'Cut the scanner?' cut,keep cut 0
lm resolve --item overseer --id "$ASK" --default
ANSWER="$(field "$BOX/to-lane.jsonl" 'select(.kind == "resolution") | .id')"
assert_eq "$RC=$OUT" "0=lane-mail: resolved id=$ASK by=default answer=$ANSWER" "resolve --default prints the resolution"
assert_eq "$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer") | [.kind, .re, .by, .text, .from] | join(" ")')" \
  "answer $ASK default cut overseer:resolve" \
  "the default answer carries the recommendation and comes from the overseer"
lm pending --item overseer --to owner
assert_eq "$RC=$OUT" "0=" "a resolved ask is no longer pending"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "2=lane-mail: resolved-already=$ASK id=$ANSWER=2" \
  "a second resolution is refused, naming the answer, and appends nothing"
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep it')"
assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$ANSWER" "later text for a resolved ask is refused too"

new_repo resolve_text
owner_ask 'Cut the scanner?' cut,keep cut 120
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep it')" --delivery-id slack:C1:1.1
ANSWER="$(field "$BOX/to-lane.jsonl" 'select(.kind == "resolution") | .id')"
assert_eq "$RC=$OUT" "0=lane-mail: resolved id=$ASK by=text answer=$ANSWER" "resolve --text prints the resolution"
assert_eq "$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer") | [.by, .text, .from, .delivery_id] | join(" ")')" \
  "text keep it owner slack:C1:1.1" "the owner's answer is the owner's, carrying the delivery it came by"
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep it')" --delivery-id slack:C1:1.1
assert_eq "$RC=$OUT=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=lane-mail: resolved id=$ASK by=text answer=$ANSWER=2" \
  "the same delivery resolving again gets the same line and appends nothing"
lm resolve --item overseer --id "$ASK" --text "$(text a 'cut it')" --delivery-id slack:C1:2.2
assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$ANSWER" "another delivery is refused as resolved already"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=$ANSWER" "the deadline's default cannot override the owner's answer"

# Slack sends distinct answers, and the deadline closes without replacing them.
new_repo answered_deadline
owner_ask 'Cut the scanner?' cut,keep cut 0
for key in slack:1 slack:2; do
  lm send --item overseer --re "$ASK" --delivery-id "$key" --file "$(text a 'keep it')"
  assert_eq "$RC" "0" "an answer lands under $key"
done
lm pending --item overseer --to owner --due
assert_eq "$(jq -r '.id' <<<"$OUT")" "$ASK" "the answered ask stays due and pending"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$(jq -rs '[.[] | select(.kind == "answer")] | length' "$BOX/to-lane.jsonl")=$(jq -rs '[.[] | select(.kind == "answer" and .by == "default")] | length' "$BOX/to-lane.jsonl")" \
  "0=2=0" "the answered deadline closes without a recommendation answer"
lm pending --item overseer --to owner
assert_eq "$RC=$OUT" "0=" "the deadline drops the answered ask"
lm send --item overseer --re "$ASK" --delivery-id slack:1 --file "$(text a 'keep it')"
assert_eq "${ERR%% id=*}" "lane-mail: delivery-repeated=slack:1" "a replay after close still names the answer"
lm send --item overseer --re "$ASK" --delivery-id slack:3 --file "$(text a 'more words')"
assert_eq "${ERR%% id=*}" "lane-mail: resolved-already=$ASK" "new answer delivery after close is refused"

# Retained rows come from the pre-1.3 resolve --text/--default producer.
for by in text default; do
  new_repo "legacy_$by"
  owner_ask 'Retained close?' a,b a
  jq -cn --arg re "$ASK" --arg by "$by" '{id:"old-close",kind:"answer",re:$re,by:$by,text:"a",at:"2026-09-27T00:00:00Z",from:"owner"}' >"$BOX/to-lane.jsonl"
  for verb in pending drain events; do
    args=(--item overseer)
    [ "$verb" != drain ] || args+=(--after 0)
    lm "$verb" "${args[@]}"
    assert_eq "$RC" "0" "$by: $verb reads the retained mailbox"
    assert_eq "${ERR%%=*}" "lane-mail: legacy-close" "$by: $verb warns on the old closing format"
    if [ "$verb" = events ]; then
      assert_eq "$(jq -r 'select(.id == "old-close") | .mail_class' <<<"$OUT")" "close" "$by: events delegates closure to the mailbox rule"
    else
      assert_eq "$(jq -r 'select(.kind == "ask") | .id' <<<"$OUT")" "" "$by: $verb does not reopen a closed ask"
    fi
  done
  lm send --item overseer --re "$ASK" --delivery-id new:reply --file "$(text a b)"
  assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=old-close" "$by: a retained close refuses a new answer"
  lm resolve --item overseer --id "$ASK"
  assert_eq "$RC=$ERR" "2=lane-mail: resolved-already=$ASK id=old-close" "$by: a retained close refuses another close"
done

# Inject jq failures only in the selected scan, not envelope construction.
FAULT_DIR="$TMP_ROOT/jq-fault"
mkdir -p "$FAULT_DIR"
REAL_JQ="$(command -v jq)" || exit 1
cat >"$FAULT_DIR/jq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  case "$arg" in
    *'select(overseer_mail_class == "close"'*)
      [ "$JQ_FAULT" != closure ] || { printf 'jq-fault=closure\n' >&2; exit 5; } ;;
    *'select(.kind == "answer" and .re == $re)'*)
      [ "$JQ_FAULT" != answers ] || { printf 'jq-fault=answers\n' >&2; exit 5; } ;;
  esac
done
exec "$REAL_JQ" "$@"
SH
chmod +x "$FAULT_DIR/jq"
export REAL_JQ
while read -r verb fault; do
  new_repo "scan_${verb}_${fault}"
  owner_ask 'Faulted read?' a,b a
  args=(--item overseer)
  if [ "$verb" = send ]; then
    args+=(--re "$ASK" --delivery-id fault:reply --file "$(text a b)")
  else
    args+=(--id "$ASK" --default)
  fi
  PATH="$FAULT_DIR:$PATH" JQ_FAULT="$fault" lm "$verb" "${args[@]}"
  assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=overseer" "$verb/$fault: an operational failure is not a close"
  assert_eq "$(tail -n 1 "$TMP_ROOT/err")" "jq-fault=$fault" "$verb/$fault: the dependency diagnostic survives"
  assert_eq "$(wc -l <"$BOX/to-lane.jsonl" | tr -d ' ')" "0" "$verb/$fault: failed scans append no words"
done <<'ROWS'
send closure
resolve closure
resolve answers
ROWS

# --- the delivery id under the lock -------------------------------------------
new_repo delivery
lm send --item overseer --directive --file "$(text d 'From Slack.')" --delivery-id slack:C1:3.3
FIRST="$(field "$BOX/to-lane.jsonl" '.id')"
assert_eq "$RC=${OUT%% bytes=*}=$(field "$BOX/to-lane.jsonl" '.delivery_id')" \
  "0=lane-mail: sent item=overseer id=$FIRST=slack:C1:3.3" "a send records its delivery id and prints its receipt"
lm send --item overseer --directive --file "$(text d 'From Slack.')" --delivery-id slack:C1:3.3
assert_eq "$RC=$ERR=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "2=lane-mail: delivery-repeated=slack:C1:3.3 id=$FIRST=1" \
  "the same delivery again is refused, naming the envelope that landed, and appends nothing"
lm send --item overseer --directive --file "$(text d 'From Slack.')" --delivery-id slack:C1:4.4
assert_eq "$RC=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=2" \
  "the same words under another delivery id land: the id is the judge, not the minute window"

# --- threaded owner directive storage ------------------------------------------
new_repo pointer
POINTER="$(text parent '{"ts":"1.1","author":"bot","excerpt":"A release.","envelope":"NOTICE-1"}')"
lm send --item overseer --directive --delivery-id C1:2.2 --file "$(text reply 'Continue.')" --thread-ts 1.1 --parent "$POINTER"
lm inbox --item overseer
assert_eq "$RC=$(jq -c '{thread_ts,parent}' <<<"$OUT")" \
  '0={"thread_ts":"1.1","parent":{"ts":"1.1","author":"bot","excerpt":"A release.","envelope":"NOTICE-1"}}' \
  "inbox preserves both thread pointer fields on the stored envelope"
for flag in --thread-ts --parent; do
  case "$flag" in --thread-ts) value=1.1 ;; --parent) value="$POINTER" ;; esac
  lm send --item overseer --directive --file "$(text reply 'Incomplete.')" "$flag" "$value"
  assert_eq "$RC=$ERR" "2=lane-mail: option-conflict=--thread-ts,--parent" "a single $flag refuses an incomplete pointer"
done
lm send --item overseer --directive --file "$(text reply 'Broken.')" --thread-ts 1.1 --parent "$(text broken '{')"
assert_eq "$RC=$ERR" "2=lane-mail: file-unreadable=$TMP_ROOT/broken.txt" "a truncated parent file never lands a directive"
owner_ask 'Which?' a,b a
lm send --item overseer --re "$ASK" --file "$(text reply 'a')" --thread-ts 1.1 --parent "$POINTER"
assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=--thread-ts" "thread pointers are for overseer owner directives only, never an answer"
INVALID_POINTER="$(text invalid-parent '{"ts":"1.1","author":"other","excerpt":"A release."}')"
lm send --item overseer --directive --file "$(text reply 'Wrong author.')" --thread-ts 1.1 --parent "$INVALID_POINTER"
assert_eq "$RC=$ERR" "2=lane-mail: file-unreadable=$INVALID_POINTER" "a parent outside Slack's owner or bot kinds is refused"

# Missing jq must name the dependency before parsing a readable parent.
BASH_BIN="$(command -v bash)"
RC=0
OUT="$(env -i PATH= "$BASH_BIN" "$LANE_MAIL" send --item overseer --directive --file "$POINTER" --thread-ts 1.1 --parent "$POINTER" 2>"$TMP_ROOT/err")" || RC=$?
assert_eq "$RC=$(sed -n '1p' "$TMP_ROOT/err")" "2=lane-mail: command-missing=jq" "a threaded send names missing jq, not the readable parent"

# --- events -------------------------------------------------------------------
new_repo events
owner_ask 'Cut the scanner?' cut,keep cut 0
lm resolve --item overseer --id "$ASK" --default
lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
lm events --item overseer
assert_eq "$RC=$(jq -r '[.box, (.line | tostring), .kind] | join(":")' <<<"$OUT" | paste -sd, -)" \
  "0=to-overseer:1:ask,to-lane:1:answer,to-lane:2:resolution,to-lane:3:directive" \
  "events prints both files, the resolved ask and its answer included, each naming its box"
lm events --item overseer
assert_eq "$(jq -r '.kind' <<<"$OUT" | paste -sd, -)=$([[ -e "$BOX/to-lane.cursor" ]] && echo cursor || echo no-cursor)" \
  "ask,answer,resolution,directive=no-cursor" "events consumes nothing: a second read prints the same and moves no cursor"
printf 'interrupted\n\n' >> "$BOX/to-overseer.jsonl"
lm notice --item overseer --to owner --file "$(text after-gap 'After the interrupted lines.')"
printf 'interrupted\n' >> "$BOX/to-overseer.jsonl"
lm events --item overseer
assert_eq "$RC=$(jq -r 'select(.box == "to-overseer") | "\(.line)/\(.count)"' <<<"$OUT" | paste -sd, -)" "0=1/5,4/5" \
  "events keeps physical offsets and counts across filtered lines left by an interrupted writer"

# --- controls, one per rule ---------------------------------------------------
# mutant NAME OLD NEW — a private lane-mail with OLD, which occurs once,
# replaced by NEW, beside links to the shipped rest; lm runs it until the next
# real-script row resets LANE_MAIL_BIN.
mutant() {
  local dir
  dir="$(mutant_scripts "mutants/$1" lane-mail)" || exit 1
  mutate_file "$dir/lane-mail" "$2" "$3"
  LANE_MAIL_BIN="$dir/lane-mail"
}

new_repo control_pointer
mutant pointer-fields '+ (if $thread == "" then {} else {thread_ts: $thread, parent: $parent} end)' '+ {}'
lm send --item overseer --directive --delivery-id C1:2.2 --file "$(text reply 'Continue.')" --thread-ts 1.1 --parent "$POINTER"
lm inbox --item overseer
assert_eq "$(jq -r 'has("parent") or has("thread_ts")' <<<"$OUT")" "false" "control: omitted pointer fields break the inbox assertion"
LANE_MAIL_BIN="$LANE_MAIL"

new_repo control_pointer_pair
mutant pointer-pair '[ -n "$THREAD_TS" ] && [ -n "$PARENT" ] || refuse option-conflict '\''--thread-ts,--parent'\''' '[ -n "$THREAD_TS" ] && [ -n "$PARENT" ] || :'
lm send --item overseer --directive --file "$(text reply 'Incomplete.')" --thread-ts 1.1
assert_eq "$ERR" "lane-mail: file-unreadable=" "control: omitting the pair guard loses its incomplete-pointer refusal"
LANE_MAIL_BIN="$LANE_MAIL"

# A well-formed answer, so the guard is the only refusal it can reach.
new_repo control_pointer_target
owner_ask 'Which?' a,b a
mutant pointer-target '[ "$VERB:$ITEM:$DIRECTIVE" = send:overseer:1 ] || refuse option-unknown "$given"' '[ "$VERB:$ITEM:$DIRECTIVE" = send:overseer:1 ] || :'
lm send --item overseer --re "$ASK" --file "$(text reply 'a')" --thread-ts 1.1 --parent "$POINTER"
assert_eq "$RC=$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer") | .thread_ts')" "0=1.1" \
  "control: omitting the target guard lands a pointer on an answer"
LANE_MAIL_BIN="$LANE_MAIL"

new_repo control_pointer_shape
mutant pointer-shape '(.author == "owner" or .author == "bot")' 'true'
INVALID_POINTER="$(text invalid-parent '{"ts":"1.1","author":"other","excerpt":"A release."}')"
lm send --item overseer --directive --file "$(text reply 'Wrong author.')" --thread-ts 1.1 --parent "$INVALID_POINTER"
assert_eq "$RC" "0" "control: omitting parent author validation admits an unsupported author"
LANE_MAIL_BIN="$LANE_MAIL"

new_repo control_resolve
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Cut?' cut,keep cut 0
LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id "$ASK" --default
mutant resolve-twice 'select(overseer_mail_class == "close" and .re == $re)' 'select(false and overseer_mail_class == "close" and .re == $re)'
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=3" \
  "control: without the resolve guard a second resolution lands"

new_repo control_answered_deadline
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Cut?' cut,keep cut 0
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --re "$ASK" --delivery-id slack:1 --file "$(text a 'keep')"
mutant default-overrides '[ ! -s "$WORK_DIR/owner.answers" ] || return 0' ': "$WORK_DIR/owner.answers"'
lm resolve --item overseer --id "$ASK" --default
assert_eq "$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer" and .by == "default") | .text')" "cut" \
  "control: bypassing the answered default guard adds a recommendation answer"

# Keep the legacy row, but remove only its classification from the shared owner.
new_repo control_legacy_close
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Retained?' a,b a
jq -cn --arg re "$ASK" '{id:"old-close",kind:"answer",re:$re,by:"text",text:"a"}' >"$BOX/to-lane.jsonl"
CLASS_DIR="$(mutant_scripts mutants/legacy-close lib/mailbox-append.sh)" || exit 1
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" 'or mailbox_legacy_close then' 'or false then'
LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm pending --item overseer --to owner
CONTROL_RC=0
CONTROL_OUT="$(
  FAIL=0
  assert_eq "$OUT" "" "legacy close remains closed"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: losing the legacy closure rule reopens the ask"

new_repo control_guard_error
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Faulted?' a,b a
CLASS_DIR="$(mutant_scripts mutants/guard-error lib/mailbox-append.sh)" || exit 1
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" '*) return 5 ;;' '*) return 4 ;;'
PATH="$FAULT_DIR:$PATH" JQ_FAULT=closure LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm send --item overseer --re "$ASK" --delivery-id fault:reply --file "$(text a b)"
CONTROL_RC=0
CONTROL_OUT="$(
  FAIL=0
  assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=overseer" "failed scan remains an operational error"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: collapsing guard errors loses the operational refusal"

new_repo control_delivery
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Once.')" --delivery-id k1
mutant delivery-twice 'select(.delivery_id == $key)' 'select(false and .delivery_id == $key)'
lm send --item overseer --directive --file "$(text d 'Once.')" --delivery-id k1
assert_eq "$RC=$(wc -l < "$BOX/to-lane.jsonl" | tr -d ' ')" "0=2" \
  "control: without the delivery guard the retry lands a second time"

new_repo control_answer_closed
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id "$ASK"
mutant answer-after-close $'  lm_guard_resolve "$1"\n}' $'  : "$1"\n}'
lm send --item overseer --re "$ASK" --delivery-id new:reply --file "$(text a 'b')"
assert_eq "$RC" "0" "control: bypassing the answer close guard admits a reply after close"

new_repo control_answer_pending
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --re "$ASK" --delivery-id first:reply --file "$(text a 'b')"
mutant answer-closes-pending 'if $envelope.to == "owner" then $closed else $done end' 'if $envelope.to == "owner" then $done else $done end'
lm pending --item overseer --to owner
assert_eq "$RC=$OUT" "0=" "control: pending drops an answered ask when it judges answers as closes"

new_repo control_answer_unknown
mutant answer-without-ask $'      lm_owner_ask "$MSGID"\n      BY=text' $'      : "$MSGID"\n      BY=text'
lm send --item overseer --re unknown --delivery-id new:reply --file "$(text a 'b')"
assert_eq "$RC" "0" "control: bypassing the owner ask lookup admits an answer with no ask"

new_repo control_close_class
CLASS_DIR="$(mutant_scripts mutants/close-class lib/mailbox-append.sh)" || exit 1
rm -- "$CLASS_DIR/lane-mail"
cp -p -- "$LANE_MAIL" "$CLASS_DIR/lane-mail"
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" 'if .kind == "resolution" or mailbox_legacy_close then "close"' 'if .kind == "resolution" or mailbox_legacy_close then "stray"'
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id "$ASK"
LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm resolve --item overseer --id "$ASK"
assert_eq "$RC=$(field "$BOX/to-lane.jsonl" '.kind' | wc -l | tr -d ' ')" "0=2" \
  "control: losing the close class permits a second close"

new_repo control_ref
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
mutant ref-lane-only 'lm_owner_ask_find "$REF" ||' 'false ||'
lm notice --item overseer --to owner --file "$(text n 'Ruled.')" --ref "$ASK"
assert_eq "$RC=$ERR" "2=lane-mail: ref-unknown=$ASK" "control: without the to-overseer read a reply naming an owner ask is refused"

# The host worker's delivered request is a valid --ref. Fail only that
# to-lane.jsonl lock in a private dependency copy, without a real wait; the
# notice's to-overseer.jsonl append must still work under its own lock.
new_repo ref_lock
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Voice request.')" --delivery-id voice:request-1
assert_eq "$RC" "0" "the request for the failed reference lock lands"
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
REF_LOCK_DIR="$(mutant_scripts fixtures/ref-lock lib/file-lock.sh)" || exit 1
mutate_file "$REF_LOCK_DIR/lib/file-lock.sh" \
  'orch_take_lock() { # FD LOCK_FILE WAIT_SECONDS' \
  'orch_take_lock() { [ "$2" != "$TO_LANE" ] || return 1 # FD LOCK_FILE WAIT_SECONDS'
LANE_MAIL_BIN="$REF_LOCK_DIR/lane-mail" lm notice --item overseer --to owner --file "$(text n 'Unreferenced notice.')"
assert_eq "$RC=$ERR" "0=" "the failed reference lock does not block the notice append lock"
LANE_MAIL_BIN="$REF_LOCK_DIR/lane-mail" lm notice --item overseer --to owner --file "$(text n 'Voice reply.')" --ref "$OWNER_NOTE"
REF_LOCK_WANT="2=lane-mail: lock-failed=$BOX/to-lane.jsonl"
REF_LOCK_ASSERTION="a reply refuses the failed reference read lock and names its mailbox"
assert_eq "$RC=$ERR" "$REF_LOCK_WANT" "$REF_LOCK_ASSERTION"
assert_eq "$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')" "1" \
  "the failed reference read appends no reply"

# Keep the failed dependency, but bypass only lm_ref_find's acquisition in a
# private lane-mail. The same refusal assertion must turn red, while the
# reply append succeeds and carries the delivered request's binding.
rm -- "$REF_LOCK_DIR/lane-mail"
cp -p -- "$LANE_MAIL" "$REF_LOCK_DIR/lane-mail"
mutate_file "$REF_LOCK_DIR/lane-mail" 'orch_take_lock 9 "$path" 30' ': 9 "$path" 30'
LANE_MAIL_BIN="$REF_LOCK_DIR/lane-mail" lm notice --item overseer --to owner --file "$(text n 'Voice reply.')" --ref "$OWNER_NOTE"
CONTROL_RC=0
CONTROL_OUT="$(
  FAIL=0
  assert_eq "$RC=$ERR" "$REF_LOCK_WANT" "$REF_LOCK_ASSERTION"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$RC=$ERR=$CONTROL_RC" "0==1" \
  "control: the reference-lock assertion fails when only its acquisition is bypassed"
assert_eq "$(field "$BOX/to-overseer.jsonl" 'select(has("ref")) | .re_delivery_id')" "voice:request-1" \
  "control: the unlocked reference read permits the bound reply to land"

new_repo control_reply_delivery
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Voice request.')" --delivery-id voice:request-1
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
mutant reply-unbound '+ (if $re_delivery == "" then {} else {re_delivery_id: $re_delivery} end)' '+ {}'
lm notice --item overseer --to owner --file "$(text n 'Voice reply.')" --ref "$OWNER_NOTE"
lm events --item overseer
# Run the binding assertion against the old envelope behavior. Its failure is
# the control's expected result, not a failure of this suite.
CONTROL_RC=0
CONTROL_OUT="$(
  assert_eq "$(jq -r 'select(.kind == "notice") | .re_delivery_id // ""' <<<"$OUT")" \
    "voice:request-1" "the exported reply carries its request's delivery id"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$RC=$CONTROL_RC" "0=1" "control: the reply-binding assertion fails without the copied field"
lm ask --item overseer --to owner --options approve,deny --recommend deny --ref "$OWNER_NOTE" --file "$(text q 'Approve?')"
CONTROL_RC=0
CONTROL_OUT="$(
  FAIL=0
  assert_eq "$(field "$BOX/to-overseer.jsonl" "$ASK_BINDING")" "$OWNER_NOTE|voice:request-1" \
    "the owner ask carries its request's delivery id"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$RC=$CONTROL_RC" "0=1" "control: the ask-binding assertion fails without the copied field"

# The owner-note class lives in lib/mailbox-append.sh, which a mutant of
# lane-mail cannot reach: the copied library files a peer's line as an owner
# note.
new_repo control_ref_class
CLASS_REPO="$LANE"
new_repo control_ref_peer
LANE_MAIL_BIN="$LANE_MAIL" lm peer ask --repo control_ref_class --file "$(text q 'Mine?')" --options yes,no
INBOUND_PEER="${OUT#id=}"
LANE="$CLASS_REPO"
CLASS_DIR="$(mutant_scripts mutants/ref-class lib/mailbox-append.sh)" || exit 1
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" 'then "peer"' 'then "owner-note"'
LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm notice --item overseer --to owner --file "$(text n 'Re.')" --ref "$INBOUND_PEER"
assert_eq "$RC=$ERR" "0=" "control: with every sender an owner a reply names a peer's ask"

new_repo control_deadline
mutant no-deadline ', deadline: (($now + ($wait | tonumber) * 60) | todate)' ''
owner_ask 'Cut?' cut,keep cut 30
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '[has("wait"), has("deadline")] | map(tostring) | join(",")')" "0=true,false" \
  "control: without the deadline clause an ask carries its wait and no deadline"

new_repo control_box
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
mutant boxless 'box: $box, line: $numbers[$physical - 1]' 'line: $numbers[$physical - 1]'
lm events --item overseer
assert_eq "$RC=$(jq -r '.box // "none"' <<<"$OUT")" "0=none" "control: without the box field a to-lane envelope names no file"

new_repo control_lines
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
mutant lineless '{box: $box, line: $numbers[$physical - 1], count: $count}' '{box: $box, line: 0, count: $count}'
lm events --item overseer
assert_eq "$RC=$(jq -r '.line' <<<"$OUT")" "0=0" "control: without logical numbering an envelope has no usable cursor position"

new_repo control_recommend
mutant recommend-optional 'if [ "$VERB:$ITEM" = ask:overseer ]; then' 'if [ -n "$RECOMMEND" ]; then'
lm ask --item overseer --to owner --options a,b --file "$(text q 'Which?')"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" 'has("deadline")')" "0=false" \
  "control: with the rule judged only where a recommendation is given an owner ask lands with no deadline"

new_repo control_events_cursor
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
mutant events-cursor 'events) refuse events-no-cursor --after ;;' 'events) ;;'
lm events --item overseer --after 0
assert_eq "$RC=$(jq -r '.kind' <<<"$OUT")" "0=directive" \
  "control: without the events rule --after is taken and dropped"

new_repo control_attach
mkdir -p "$LANE/elsewhere"
echo "outside" > "$LANE/elsewhere/x.md"
mutant attach-anywhere '[ "$dir" = "$reports" ] || refuse attach-outside "$ATTACH"' ':'
lm notice --item overseer --to owner --file "$(text n 'R.')" --attach "$LANE/elsewhere/x.md"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.attach')" "0=$LANE/elsewhere/x.md" \
  "control: without the directory rule a file anywhere is attached"

new_repo control_to
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Owner?' a,b a 120
mutant to-unfiltered 'select($to == "" or $envelope.to == $to)' 'select(true)'
lm pending --item overseer --to peer
assert_eq "$RC=$(jq -r '.to' <<<"$OUT")" "0=owner" "control: without the audience filter --to peer lists the owner's ask"

new_repo control_due
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Later?' a,b a 120
mutant due-unfiltered 'select($due == 0 or ' 'select(true or '
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.wait' <<<"$OUT")" "0=120" "control: without the deadline filter --due lists an ask not yet due"

new_repo control_cursor
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Cursor?' a,b a 0
touch "$BOX/to-lane.cursor.lock"
mutant cursor-for-asks 'if [ "$LISTS_DIRECTIVES" -eq 1 ]; then' 'if [ "$VERB" = pending ] || [ "$RECEIPTS" -eq 1 ]; then'
lm pending --item overseer --to owner
assert_eq "$RC=$ERR" "2=lane-mail: mail-read-failed=overseer cursor=missed" \
  "control: with the cursor read for every pending a missed read refuses the asks --to keeps"

new_repo control_draft_medium
mutant draft-medium-any 'elif (.medium | IN(' 'elif true or (.medium | IN('
draft_ask "$(draft_file fax '{"recipient":"r","medium":"fax","text":"x"}')"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.draft.medium')" "0=fax" "control: without the medium rule a fax draft lands"

new_repo control_draft_options
mutant draft-options-any "|| refuse option-conflict '--draft,--options'" "|| : refuse option-conflict '--draft,--options'"
draft_ask "$(draft_file d "$DRAFT_JSON")" --options approve,deny
assert_eq "$RC=$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')" "0=1" "control: without the --options conflict rule a draft ask naming --options lands"

new_repo control_draft_recommend
mutant draft-recommend-any "|| refuse option-conflict '--draft,--recommend'" "|| : refuse option-conflict '--draft,--recommend'"
draft_ask "$(draft_file d "$DRAFT_JSON")" --recommend deny
assert_eq "$RC=$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')" "0=1" "control: without the --recommend conflict rule a draft ask naming --recommend lands"

new_repo control_draft_field
mutant draft-field-any 'if $bad != [] then' 'if false and $bad != [] then'
draft_ask "$(draft_file blank '{"recipient":"","medium":"email","text":"x"}')"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.draft.recipient')" "0=" "control: without the field rule an empty recipient lands"

new_repo control_draft_single
mutant draft-many 'if length != 1 or (.[0] | type)' 'if (.[0] | type)'
draft_ask "$(draft_file two "$TWO_DRAFTS")"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.draft.text')" "0=x" "control: without the one-object rule a file of two drafts lands"

new_repo control_draft_argv
mutant draft-argv '--slurpfile draft "$DRAFT_RECORD"' '--argjson draft "[$(cat -- "$DRAFT_RECORD")]"'
draft_ask "$TMP_ROOT/large.json"
assert_eq "$RC=${ERR%%=*}" "2=lane-mail: file-unreadable" "control: a draft record carried on jq's argv refuses the large draft"

new_repo control_draft_hash
mutant draft-hash-trimmed 'jq -j .text -- "$DRAFT"' 'jq -j '"'"'.text | sub("\n$"; "")'"'"' -- "$DRAFT"'
draft_ask "$(draft_file d "$DRAFT_JSON")"
CONTROL_RC=0
CONTROL_OUT="$(
  assert_draft_text "$DRAFT_BYTES"
  [[ "$FAIL" -eq 0 ]]
)" || CONTROL_RC=$?
assert_eq "$RC=$CONTROL_RC" "0=1" "control: a hash over the text less its trailing newline turns the draft text row red"

new_repo control_reserved_field
mutant reserved-field '{reserved: true}' '{}'
reserved_ask --wait 0
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" 'has("reserved")')" "0=false" "control: without the field a reserved ask records nothing reserved"

new_repo control_reserved_recommend
mutant reserved-recommend-any "|| refuse option-conflict '--reserved,--recommend'" "|| : refuse option-conflict '--reserved,--recommend'"
reserved_ask --recommend cut
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.recommend')" "0=cut" "control: without the --recommend conflict rule a reserved ask carries a default"

new_repo control_reserved_draft
mutant reserved-draft-any "|| refuse option-conflict '--reserved,--draft'" "|| : refuse option-conflict '--reserved,--draft'"
reserved_ask --draft "$(draft_file d "$DRAFT_JSON")"
assert_eq "$RC=$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')" "0=1" "control: without the --draft conflict rule a reserved draft ask lands"

new_repo control_reserved_due
LANE_MAIL_BIN="$LANE_MAIL" reserved_ask --wait 0
mutant reserved-due '($envelope.reserved != true' '(true'
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.id' <<<"$OUT")" "0=$ASK" "control: without the reserved rule --due lists the reserved ask for the watch to close"

new_repo control_reserved_default
LANE_MAIL_BIN="$LANE_MAIL" reserved_ask --wait 0
mutant reserved-default-any '[ "$RESERVED_ASK" = false ] || refuse ask-reserved "$MSGID"' ':'
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR" "2=lane-mail: recommend-missing=$ASK" "control: without the reserved refusal --default falls to the missing recommendation"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
