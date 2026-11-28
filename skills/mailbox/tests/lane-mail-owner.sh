#!/usr/bin/env bash
# lane-mail's owner channel: the typed fields an overseer ask and notice carry,
# `resolve` closing an owner ask exactly once, `--delivery-id` landing an ask or send
# once under the lock, `events` reading both files, `pending --to` and
# `--due`, and owner-answers over an owner listing past the kernel's limit for
# one argument. Each case builds an overseer checkout under TMP_ROOT and drives the
# real script; the lane-side verbs are tests/lane-mail.sh. The must-fail
# controls close the file, one per rule, each a copy of lane-mail or the
# library it sources with that rule removed: the one resolution, the delivery
# id, the attachment's confinement, the audience and deadline filters, the
# cursor rule, the reply's owner-ask read, the owner-note class a reply names,
# the ask's deadline field, the box `events` stamps, the owner ask's required
# recommendation, the box `events --after` requires, the reply's delivery id, the
# referenced mailbox's read lock, a draft's medium, fields and text hash, and
# a reserved ask's field, its two conflicts, its --due exclusion and its
# --default refusal, and a standing ask's reservation: its fold, reserve's
# reads of the close before and after its append, its kind read, and the
# default's judge under the close's lock.
# The owner notice's day-long text rule keeps its controls beside its rows.
# The data notice keeps its class and source controls beside its rows.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/git-env.sh
source "$REPO_ROOT/skills/orch/tests/lib/git-env.sh"

LANE_MAIL="$REPO_ROOT/skills/mailbox/scripts/lane-mail"
# Canonical at creation: lane-mail records an attachment at its physical path,
# so every expectation built from LANE or BOX must name the same one.
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-owner: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-owner: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-owner: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# mutant_scripts and mutate_file, the two halves of the controls at the end.
# shellcheck source=../../orch/tests/lib/growth-state.sh
source "$REPO_ROOT/skills/orch/tests/lib/growth-state.sh"

# shellcheck source=../../orch/tests/lib/assertions.sh
source "$REPO_ROOT/skills/orch/tests/lib/assertions.sh"

# A fresh overseer checkout: a repository whose `.agents` tree holds the orch
# scripts, so `--item overseer` resolves its own mailbox and `--attach` finds
# orch-env beside lane-mail.
LANE=""
BOX=""
new_repo() { # NAME
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE/.agents/skills/orch"
  git -C "$LANE" init -q
  git -C "$LANE" config gc.auto 0
  git -C "$LANE" config maintenance.auto false
  ln -sfn "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
  mkdir -p "$LANE/.agents/skills/mailbox"
  ln -sfn "$REPO_ROOT/skills/mailbox/scripts" "$LANE/.agents/skills/mailbox/scripts"
  BOX="$LANE/tmp/lane-mail/overseer"
  mkdir -p "$LANE/tmp"
  printf '{"controller":{"server":"7000","pane":"%%0"}}\n' > "$LANE/tmp/workflow-state-oversee.json"
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
  [[ -z "${3:-}" ]] || args+=(--recommend "$3" --effect none)
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
PROGRESS_ASSERTION='a progress notice carries true and its request reference'
while IFS='|' read -r audience ref words want progress; do
  progress_args=(); progress_receipt=""; progress_field=""
  if [[ "$progress" == yes ]]; then
    progress_args=(--progress); progress_receipt=' progress=1'; progress_field=',"progress":true'
  fi
  lm notice --item overseer --to "$audience" --ref "${REFS[$ref]}" --file "$(text n "$words")" ${progress_args[@]+"${progress_args[@]}"}
  if [[ "$want" == progress ]]; then
    PROGRESS_WANT="true|${REFS[$ref]}"
    assert_eq "$(field "$BOX/to-overseer.jsonl" '[.progress, .ref] | map(tostring) | join("|")')" \
      "$PROGRESS_WANT" "$PROGRESS_ASSERTION"
  fi
  if [[ "$want" == duplicate ]]; then
    assert_eq "$RC=$ERR=$OUT=$(field "$BOX/to-overseer.jsonl" 'select(.text == "Reply.") | .id')" \
      "2=lane-mail: duplicate id=$FIRST_ID==$FIRST_ID" "notice repeat refuses before appending"
  elif [[ "$want" == repeated ]]; then
    assert_eq "$RC=$ERR=$OUT=$(field "$BOX/to-overseer.jsonl" 'select(.text == "Reply.") | .id')" \
      "2=lane-mail: owner-notice-repeated=overseer id=$FIRST_ID==$FIRST_ID" \
      "an owner notice text the owner holds refuses whatever its reference"
  else
    ID="$(jq -rs 'last.id' < "$BOX/to-overseer.jsonl")" || exit 1
    assert_eq "$RC=$OUT" "0=lane-mail: sent item=overseer id=$ID bytes=6 to=$audience ref=${REFS[$ref]}$progress_receipt" \
      "notice $want prints its appended receipt"
    assert_eq "$(field "$BOX/to-overseer.jsonl" 'del(.id, .at) | tojson' | tail -n 1)" \
      "{\"kind\":\"notice\",\"from\":\"overseer\",\"to\":\"$audience\",\"ref\":\"${REFS[$ref]}\"$progress_field,\"re_delivery_id\":\"first\",\"text\":\"$words\"}" \
      "notice $want keeps exactly its envelope fields"
    [[ "$want" != first ]] || FIRST_ID="$ID"
  fi
done <<'ROWS'
owner|0|Step..|progress|yes
owner|0|Reply.|first|no
owner|0|Reply.|duplicate|no
owner|1|Reply.|repeated|no
owner|0|Other.|changed-text|no
ROWS
# The same first-row assertion must reject a notice whose marker is dropped.
new_repo control_progress
lm send --item overseer --directive --file "$(text d 'Voice request.')"
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
PROGRESS_DIR="$(mutant_scripts mutants/progress lane-mail)" || exit 1
mutate_file "$PROGRESS_DIR/lane-mail" '{progress: true}' '({progress: true} | del(.progress))'
LANE_MAIL_BIN="$PROGRESS_DIR/lane-mail" lm notice --item overseer --to owner --ref "$OWNER_NOTE" --progress --file "$(text n 'Step..')"
CONTROL_RC=0
(FAIL=0; assert_eq "$(field "$BOX/to-overseer.jsonl" '[.progress, .ref] | map(tostring) | join("|")')" \
  "true|$OWNER_NOTE" "$PROGRESS_ASSERTION"; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/progress-assertion" || CONTROL_RC=$?
assert_eq "$RC=$CONTROL_RC" "0=1" "control: dropping progress fails the first notice row" "$TMP_ROOT/progress-assertion"
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
# A restarted overseer retries the same ask after the minute window. The
# unkeyed row is the control: the same retry appends a second ask. The relay
# consumes these ask envelopes, so no second envelope means no second thread.
while IFS='|' read -r name retry_key words want; do
  new_repo "ask_delivery_$name"
  lm ask --item overseer --to owner --options yes,no --recommend yes --effect none \
    --delivery-id ask:restart --file "$(text q 'Retry?')"
  FIRST_ASK="${OUT#id=}"
  FIRST_LINE="$(cat -- "$BOX/to-overseer.jsonl")"
  assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.delivery_id')" "0=ask:restart" \
    "$name: the first ask carries its delivery key"
  sleep 61
  key_args=()
  [[ -z "$retry_key" ]] || key_args=(--delivery-id "$retry_key")
  lm ask --item overseer --to owner --options yes,no --recommend yes --effect none \
    ${key_args[@]+"${key_args[@]}"} --file "$(text q "$words")"
  control_rc=0
  # The first line of the keyed refusal is lane-mail's machine-read contract.
  (FAIL=0
    assert_eq "$RC=$ERR=$(field "$BOX/to-overseer.jsonl" 'select(.kind == "ask") | .id')" \
      "2=lane-mail: delivery-repeated=ask:restart id=$FIRST_ASK=$FIRST_ASK" \
      'a keyed retry names the first ask and leaves one ask envelope'
    assert_eq "$(cat -- "$BOX/to-overseer.jsonl")" "$FIRST_LINE" \
      'a keyed retry preserves the original timestamp and deadline'
    [[ "$FAIL" -eq 0 ]]
  ) >"$TMP_ROOT/ask-delivery-assertion" || control_rc=$?
  assert_eq "$control_rc" "$want" "$name: the same retry assertion judges the key" "$TMP_ROOT/ask-delivery-assertion"
  if [[ "$want" == 1 ]]; then
    assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" 'select(.kind == "ask") | .id' | wc -l | tr -d ' ')" \
      "0=2" 'control: the retry without a key appends a second ask after the minute'
  fi
done <<'ROWS'
keyed|ask:restart|Retry?|0
changed-text|ask:restart|Other?|0
unkeyed||Retry?|1
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
eligibility~[ "$VERB" != resolve ] && [ "$VERB" != present ] && [ -z "$DELIVERY_ID" ]~false && [ "$VERB" != resolve ] && [ "$VERB" != present ] && [ -z "$DELIVERY_ID" ]~1
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
owner-ask|210|overseer|Report.|ask --item overseer --to owner --options yes,no --recommend yes --effect none --file @F|0==2
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
  reports="$LANE/tmp/progress-reports"
  mkdir -p "$reports"
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
    ask) args=(ask --item overseer --to owner --options keep,stop --recommend keep --effect none); box="$sender/tmp/lane-mail/overseer/to-overseer.jsonl" ;;
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
      env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$TMP_ROOT/clock-bin:$PATH" HOME="$TMP_ROOT/repeat-home" LC_ALL=C \
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
# which resolve can close explicitly; the
# peer's ask the other way lands in to-lane.jsonl beside the owner's notes.
REFUSALS="$LANE"
new_repo peer
lm peer ask --repo refusals --file "$(text q 'Mine?')" --options yes,no
INBOUND_PEER="${OUT#id=}"
LANE="$REFUSALS"; BOX="$LANE/tmp/lane-mail/overseer"
lm peer ask --repo peer --file "$(text q 'Yours?')" --options yes,no
PEER_ASK="${OUT#id=}"
# ARGS|WANT (rc=first stderr line); F is the message file. A notice may
# reference a prior owner notice. An ask may reference an owner request.
# Peer messages and resolutions remain invalid references.
F="$TMP_ROOT/q.txt"
while IFS='|' read -r args want; do
  before="$(cat "$BOX/to-overseer.jsonl")"
  # shellcheck disable=SC2086  # a row's arguments are its own words.
  lm $args
  assert_eq "$RC=$ERR" "$want" "refused: $args"
  if [[ "$args" == *--progress* ]]; then
    assert_eq "$(cat "$BOX/to-overseer.jsonl")" "$before" "a refused progress notice writes no owner envelope"
    lane_write=empty
    [[ ! -s "$LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl" ]] || lane_write=written
    assert_eq "$lane_write" "empty" \
      "a refused progress option writes no lane envelope"
  fi
done <<ROWS
ask --item overseer --file $F|2=lane-mail: option-required=--to
ask --item KEN-1 --to owner --file $F|2=lane-mail: option-unknown=--to
ask --item overseer --to peer --file $F|2=lane-mail: to-invalid=peer
ask --item overseer --to nobody --file $F|2=lane-mail: to-invalid=nobody
ask --item overseer --to owner --options a,b --recommend c --effect none --file $F|2=lane-mail: recommend-invalid=c
ask --item overseer --to owner --options a,b --recommend a,b --effect none --file $F|2=lane-mail: recommend-invalid=a,b
ask --item overseer --to owner --file $F|2=lane-mail: recommend-required=owner
ask --item overseer --to owner --options a,b --wait 5 --file $F|2=lane-mail: recommend-required=owner
ask --item overseer --to owner --recommend a --effect none --file $F|2=lane-mail: option-required=--options
ask --item overseer --to owner --options a,b --recommend a --effect none --wait 5m --file $F|2=lane-mail: minutes-invalid=--wait
ask --item overseer --to owner --options a,b --recommend a --reserved --file $F|2=lane-mail: option-conflict=--reserved,--recommend
ask --item overseer --to owner --options a,b --recommend a --file $F|2=lane-mail: effect-required=--effect
ask --item overseer --to owner --options a,b --recommend a --effect cheap --file $F|2=lane-mail: effect-required=cheap
ask --item overseer --to owner --options a,b --recommend a --effect spend --file $F|2=lane-mail: ask-reserved-effect=spend
ask --item overseer --to owner --options a,b --recommend a --effect as-owner --file $F|2=lane-mail: ask-reserved-effect=as-owner
ask --item KEN-1 --options a,b --effect none --file $F|2=lane-mail: option-unknown=--effect
ask --item overseer --to owner --reserved --file $F|2=lane-mail: option-required=--options
ask --item KEN-1 --options a,b --reserved --file $F|2=lane-mail: option-unknown=--reserved
notice --item KEN-1 --ref $OWNER_NOTE --file $F|2=lane-mail: option-unknown=--ref
notice --item overseer --to owner --progress --file $F|2=lane-mail: progress-needs-ref=--progress
notice --item KEN-1 --progress --file $F|2=lane-mail: option-unknown=--progress
notice --item overseer --progress --ref $OWNER_NOTE --file $F|2=lane-mail: option-unknown=--progress
ask --item overseer --to owner --ref $OWNER_NOTE --progress --options a,b --recommend a --effect none --file $F|2=lane-mail: option-unknown=--progress
send --item overseer --directive --progress --file $F|2=lane-mail: option-unknown=--progress
notice --item overseer --to owner --ref no/such --file $F|2=lane-mail: ref-invalid=no/such
notice --item overseer --to owner --ref 1790000000-1-1 --file $F|2=lane-mail: ref-unknown=1790000000-1-1
notice --item overseer --to owner --ref $PEER_ASK --file $F|2=lane-mail: ref-unknown=$PEER_ASK
notice --item overseer --to owner --ref $INBOUND_PEER --file $F|2=lane-mail: ref-unknown=$INBOUND_PEER
notice --item overseer --to owner --ref $RESOLUTION --file $F|2=lane-mail: ref-unknown=$RESOLUTION
ask --item overseer --to owner --options a,b --recommend a --effect none --ref $NOTE_TO_OWNER --file $F|2=lane-mail: ref-unknown=$NOTE_TO_OWNER
ask --item overseer --to owner --options a,b --recommend a --effect none --ref 1790000000-1-1 --file $F|2=lane-mail: ref-unknown=1790000000-1-1
ask --item overseer --to owner --options a,b --recommend a --effect none --attach x --file $F|2=lane-mail: option-unknown=--attach
notice --item KEN-1 --attach x --file $F|2=lane-mail: option-unknown=--attach
send --item overseer --re $OWNER_NOTE --file $F|2=lane-mail: ask-unknown=$OWNER_NOTE
send --item overseer --directive --host --root $LANE --delivery-id k --file $F|2=lane-mail: option-conflict=--host,--delivery-id
send --item overseer --directive --default --file $F|2=lane-mail: option-unknown=--default
send --item overseer --directive --sender owner --file $F|2=lane-mail: option-unknown=--sender
send --item KEN-1 --re x --sender owner --file $F|2=lane-mail: option-unknown=--sender
send --item overseer --re x --sender Jarvis --file $F|2=lane-mail: sender-invalid=Jarvis
resolve --item overseer --id x --default --sender owner|2=lane-mail: option-unknown=--sender
resolve --item KEN-1 --id x --default|2=lane-mail: overseer-only=KEN-1
resolve --item overseer --default|2=lane-mail: option-required=--id
resolve --item overseer --id x|2=lane-mail: ask-unknown=x
resolve --item overseer --id x --default --text $F|2=lane-mail: option-conflict=--text,--default
resolve --item overseer --id 1790000000-1-1 --default|2=lane-mail: ask-unknown=1790000000-1-1
resolve --item overseer --id $PEER_ASK --text $F|2=lane-mail: option-conflict=$PEER_ASK
resolve --item overseer --id $NOTE_TO_OWNER --text $F|2=lane-mail: ask-unknown=$NOTE_TO_OWNER
drain --item overseer --after 0 --to owner|2=lane-mail: option-unknown=--to
inbox --item overseer --due|2=lane-mail: option-unknown=--due
events --item overseer --after 0|2=lane-mail: option-required=--box
events --item overseer --box sideways|2=lane-mail: box-invalid=sideways
events --item overseer --box to-lane --after sideways|2=lane-mail: after-invalid=sideways
drain --item overseer --after 0 --box to-lane|2=lane-mail: option-unknown=--box
pending --item overseer --after 3|2=lane-mail: option-unknown=--after
ROWS
# Distinct replies keep the reference cases independent of text deduplication.
# Only the notice parent gets the binding the Slack relay uses for a follow-up.
while IFS='|' read -r parent ref has_notice_binding; do
  lm notice --item overseer --to owner --ref "$ref" --file "$(text n "Reply to $parent.")"
  binding="$(jq -rs 'last | [.ref, has("re_owner_notice"), .re_owner_notice == true] | map(tostring) | join("|")' "$BOX/to-overseer.jsonl")"
  assert_eq "$RC=$binding" "0=$ref|$has_notice_binding|$has_notice_binding" \
    "a reply to $parent records its reference and the appropriate notice binding"
done <<ROWS
owner notice|$NOTE_TO_OWNER|true
owner ask|$ASK_TO_OWNER|false
owner note|$OWNER_NOTE|false
ROWS

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
lm ask --item overseer --to owner --options approve,deny --recommend deny --effect none --ref "$OWNER_NOTE" --file "$(text q 'Approve?')"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" "$ASK_BINDING")" "0=$OWNER_NOTE|voice:request-1" \
  "an owner ask names the voice request and copies its delivery id"

# --- the attachment's confinement --------------------------------------------
new_repo attach
# The directory ORCH_PROGRESS_REPORT_DIR names by default, under the checkout.
REPORTS="$LANE/tmp/progress-reports"
mkdir -p "$REPORTS"
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
# attach-check answers each path as the notice above judged it, with the
# physical path the notice recorded, and appends nothing.
PHYSICAL="$(cd "$REPORTS" && pwd -P)/09-26-01-00.md"
LINES_BEFORE="$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')"
# PATH|WANT (status=stdout=first stderr line)
while IFS='|' read -r path want; do
  lm attach-check --attach "$path"
  assert_eq "$RC=$OUT=$ERR" "$want" "attach-check $path"
done <<ROWS
$REPORTS/09-26-01-00.md|0=lane-mail: attach=$PHYSICAL=
tmp/progress-reports/09-26-01-00.md|0=lane-mail: attach=$PHYSICAL=
$REPORTS/deeper/09-26-01-01.md|2==lane-mail: attach-outside=$REPORTS/deeper/09-26-01-01.md
$LANE/elsewhere/09-26-01-02.md|2==lane-mail: attach-outside=$LANE/elsewhere/09-26-01-02.md
$REPORTS/09-26-01-03.md|2==lane-mail: attach-outside=$REPORTS/09-26-01-03.md
$LANE/reports-link/09-26-01-00.md|0=lane-mail: attach=$PHYSICAL=
$REPORTS|2==lane-mail: attach-outside=$REPORTS
ROWS
assert_eq "$(wc -l < "$BOX/to-overseer.jsonl" | tr -d ' ')" "$LINES_BEFORE" "attach-check appends nothing"
lm attach-check --attach "$PHYSICAL" --item overseer
assert_eq "$RC=$ERR" "2=lane-mail: option-unknown=--item" "attach-check takes the file alone"
lm attach-check
assert_eq "$RC=$ERR" "2=lane-mail: option-required=--attach" "attach-check requires the file"
# From a linked worktree the default report directory is the main
# checkout's, as a notice from there judges it.
git -C "$LANE" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
git -C "$LANE" worktree add -q "$TMP_ROOT/attach-wt" 2>/dev/null
attach_from_worktree() {
  RC=0
  OUT="$(cd "$TMP_ROOT/attach-wt" && env -u ORCH_PROGRESS_REPORT_DIR \
    "${LANE_MAIL_BIN:-$LANE_MAIL}" attach-check --attach "$PHYSICAL" 2>"$TMP_ROOT/err")" || RC=$?
}
attach_from_worktree
assert_eq "$RC=$OUT" "0=lane-mail: attach=$PHYSICAL" \
  "attach-check from a linked worktree judges the main checkout's report directory"

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

# Rewrite the caller's draft after jq emits the bytes used for the hash.
# The recorded text must still be the text that was checked and hashed.
draft_rewrite() {
  local jq_bin
  jq_bin="$(command -v jq)" || exit 1
  mkdir -p "$TMP_ROOT/draft-bin"
  cat > "$TMP_ROOT/draft-bin/jq" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
"$REAL_JQ" "$@"
if [[ "${1:-}" == -j ]]; then
  printf '%s' '{"recipient":"r","medium":"email","text":"Changed."}' > "$REWRITE_DRAFT"
fi
SHIM
  chmod +x "$TMP_ROOT/draft-bin/jq"
  local draft
  draft="$(draft_file rewrite "$DRAFT_JSON")" || exit 1
  PATH="$TMP_ROOT/draft-bin:$PATH" REAL_JQ="$jq_bin" REWRITE_DRAFT="$draft" draft_ask "$draft"
  assert_eq "$RC=${OUT%%=*}" "0=id" "a draft rewritten during hashing still lands"
  assert_eq "$(field "$draft" '.text')" "Changed." "the jq shim rewrote the caller's draft"
  assert_draft_text "$DRAFT_BYTES"
}
new_repo draft_rewrite
draft_rewrite

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
# A release refused beside --recommend takes this route, its effect named.
reserved_ask --wait 0 --effect release
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

# --- a standing ask reserved ---------------------------------------------------
# reserve makes an ask sent with a recommendation reserved under its own id:
# the watch's two reads, --due and --default, then treat it as a reserved ask,
# and the owner's answer still closes it.
over_lines() { wc -l < "$BOX/to-overseer.jsonl" | tr -d ' '; }
new_repo reserve
owner_ask 'Ship the release?' ship,hold ship 0
lm reserve --item overseer --id "$ASK"
assert_eq "$RC=$OUT" "0=lane-mail: reserved id=$ASK" "reserve keeps the standing ask under its own id"
lm pending --item overseer --to owner --due
assert_eq "$RC=$OUT" "0=" "--due leaves out a reserved standing ask past its deadline"
lm pending --item overseer --to owner
assert_eq "$RC=$(jq -r '[.id, .reserved] | map(tostring) | join(" ")' <<<"$OUT")" "0=$ASK true" \
  "the reserved standing ask stays pending under its id, read as reserved"
lm events --item overseer --box to-overseer
assert_eq "$RC=$(sed 1d <<<"$OUT" | jq -r '[.id, .reserved] | map(tostring) | join(" ")')" "0=$ASK true" \
  "events folds the reservation into the ask and emits no record of its own"
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR=$(default_answers)" "2=lane-mail: ask-reserved=$ASK=0" \
  "resolve --default refuses the reserved standing ask and writes no default answer"
LINES="$(over_lines)"
lm reserve --item overseer --id "$ASK"
assert_eq "$RC=$OUT=$(over_lines)" "0=lane-mail: reserved id=$ASK=$LINES" "a second reserve appends nothing"
lm resolve --item overseer --id "$ASK" --text "$(text a 'hold it')"
CLOSE="$(field "$BOX/to-lane.jsonl" 'select(.kind == "resolution") | .id')"
assert_eq "$RC=$OUT" "0=lane-mail: resolved id=$ASK by=text answer=$CLOSE" "the owner's answer closes the reserved standing ask"
lm reserve --item overseer --id "$ASK"
assert_eq "$RC=$ERR=$(over_lines)" "2=lane-mail: resolved-already=$ASK id=$CLOSE=$LINES" \
  "reserve refuses a closed ask by its close and appends nothing"

# An ask reserved at ask time is reserved already: reserve appends nothing.
new_repo reserve_reserved
reserved_ask --wait 0
lm reserve --item overseer --id "$ASK"
assert_eq "$RC=$OUT=$(over_lines)" "0=lane-mail: reserved id=$ASK=1" "reserve of an ask sent --reserved appends nothing"

# ID|WANT (rc=first stderr line); each refusal appends nothing.
new_repo reserve_refusals
owner_ask 'Ship?' ship,hold ship 0
lm notice --item overseer --to owner --file "$(text n 'Shipped.')"
NOTICE="$(field "$BOX/to-overseer.jsonl" 'select(.kind == "notice") | .id')"
lm send --item overseer --directive --file "$(text d 'Carry on.')"
DIRECTIVE="$(field "$BOX/to-lane.jsonl" '.id')"
jq -cn '{id:"peer-ask",kind:"ask",to:"peer",at:"2000-01-01T00:00:00Z",text:"x"}' >> "$BOX/to-overseer.jsonl"
LINES="$(over_lines)"
while IFS='|' read -r id want; do
  lm reserve --item overseer --id "$id"
  assert_eq "$RC=$ERR=$(over_lines)" "$want=$LINES" "reserve --id $id refuses as $want"
done <<ROWS
1700000000-1-1|2=lane-mail: ask-unknown=1700000000-1-1
$NOTICE|2=lane-mail: not-owner-ask=$NOTICE kind=notice
$DIRECTIVE|2=lane-mail: not-owner-ask=$DIRECTIVE kind=directive
peer-ask|2=lane-mail: not-owner-ask=peer-ask kind=ask
ROWS
lm reserve --item KEN-1 --id "$ASK"
assert_eq "$RC=$ERR" "2=lane-mail: overseer-only=KEN-1" "reserve acts on the overseer mailbox alone"

# resolve pauses inside the close's lock while reserve runs to its end or to
# its own wait on that lock: the two interleave where a deadline meets a
# reservation. RESOLVE_BIN pauses; RESERVE_BIN reserves. Sets RACE_RESOLVE and
# RACE_RESERVE to `<rc>=<first stdout or stderr line>`.
PAUSE_DIR="$(mutant_scripts fixtures/close-pause lib/mailbox-append.sh)" || exit 1
mutate_file "$PAUSE_DIR/lib/mailbox-append.sh" '  if ! orch_take_lock 9 "$1" "$2"; then
    exec 9>&-
    return 3
  fi' '  if ! orch_take_lock 9 "$1" "$2"; then
    exec 9>&-
    return 3
  fi
  : > "$RACE_MARKER"
  pause_tries=0
  while [ ! -e "$RACE_RELEASE" ] && [ "$pause_tries" -lt 400 ]; do
    pause_tries=$((pause_tries + 1))
    sleep 0.05
  done'
race_result() { # NAME
  local rc
  rc="$(cat "$TMP_ROOT/$1.rc")" || exit 1
  printf '%s=%s' "$rc" "$(cat "$TMP_ROOT/$1.out" "$TMP_ROOT/$1.err" | sed -n 1p)"
}
reserve_race() { # NAME RESOLVE_BIN RESERVE_BIN [RESOLVE_ARGS...]
  local name="$1" resolver="$2" reserver="$3" tries=0 resolving reserving
  shift 3
  new_repo "$name"
  LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Ship it?' ship,hold ship 0
  (cd "$LANE" && rc=0
    RACE_MARKER="$TMP_ROOT/$name.paused" RACE_RELEASE="$TMP_ROOT/$name.release" \
      "$resolver" resolve --item overseer --id "$ASK" "$@" >"$TMP_ROOT/$name-resolve.out" 2>"$TMP_ROOT/$name-resolve.err" || rc=$?
    printf '%s\n' "$rc" >"$TMP_ROOT/$name-resolve.rc") & resolving=$!
  await_marker "$TMP_ROOT/$name.paused" || exit 1
  (cd "$LANE" && rc=0
    "$reserver" reserve --item overseer --id "$ASK" >"$TMP_ROOT/$name-reserve.out" 2>"$TMP_ROOT/$name-reserve.err" || rc=$?
    printf '%s\n' "$rc" >"$TMP_ROOT/$name-reserve.rc") & reserving=$!
  until [ -e "$TMP_ROOT/$name-reserve.rc" ] || jq -e 'select(.kind == "reservation")' "$BOX/to-overseer.jsonl" >/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 100 ] || break
    sleep 0.05
  done
  : > "$TMP_ROOT/$name.release"
  wait "$resolving" "$reserving"
  RACE_RESOLVE="$(race_result "$name-resolve")"
  RACE_RESERVE="$(race_result "$name-reserve")"
}
# A deadline's default that read the ask before the reservation landed
# refuses it under the close's lock, and the reservation stands.
reserve_race race_default "$PAUSE_DIR/lane-mail" "$LANE_MAIL" --default
assert_eq "$RACE_RESOLVE|$RACE_RESERVE|$(default_answers)" "2=lane-mail: ask-reserved=$ASK|0=lane-mail: reserved id=$ASK|0" \
  "a default racing a reservation refuses and the reservation stands"
# A close landing while the reservation does is reserve's refusal, never its
# receipt.
reserve_race race_close "$PAUSE_DIR/lane-mail" "$LANE_MAIL"
CLOSE="$(field "$BOX/to-lane.jsonl" 'select(.kind == "resolution") | .id')"
assert_eq "$RACE_RESOLVE|$RACE_RESERVE" "0=lane-mail: resolved id=$ASK by=explicit answer=$CLOSE|2=lane-mail: resolved-already=$ASK id=$CLOSE" \
  "a close racing a reservation is reserve's refusal"

# --- resolve, exactly once ----------------------------------------------------
new_repo resolve_nonowner
owner_ask 'Still open?' yes,no yes
OPEN_OWNER="$ASK"
for audience in peer legacy; do
  jq -cn --arg id "$audience" --arg to "$audience" '{id:$id,kind:"ask",at:"2000-01-01T00:00:00Z"}
    + (if $to == "peer" then {to:$to} else {} end)' >> "$BOX/to-overseer.jsonl"
  for option in text default; do
    args=(--default)
    [ "$option" != text ] || args=(--text "$(text a 'closed')")
    lm resolve --item overseer --id "$audience" "${args[@]}"
    assert_eq "$RC=$ERR" "2=lane-mail: option-conflict=$audience" "$audience: owner answer options refuse"
  done
  lm send --item overseer --re "$audience" --file "$(text a 'answer')"
  assert_eq "$RC=$ERR" "2=lane-mail: ask-unknown=$audience" "$audience: owner send still refuses"
  lm resolve --item overseer --id "$audience"
  assert_eq "$RC" 0 "$audience: explicit resolve succeeds"
  assert_eq "$(field "$BOX/to-lane.jsonl" 'select(.re == "'"$audience"'") | [.kind,.by] | join(" ")')" \
    'resolution explicit' "$audience: one explicit close and no owner answer"
  lm resolve --item overseer --id "$audience"
  assert_eq "$RC=${ERR%% id=*}" "2=lane-mail: resolved-already=$audience" "$audience: second close refuses"
done
lm pending --item overseer
assert_eq "$RC=$(jq -r .id <<<"$OUT")" "0=$OPEN_OWNER" 'pending omits both explicit closes and keeps the owner ask'

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

# An answer records the sender its sending command names, and none where it
# names none. `from` stays owner on each: a routing value, not an author.
new_repo answer_sender
owner_ask 'Cut the scanner?' cut,keep cut 120
lm send --item overseer --re "$ASK" --sender owner --file "$(text a 'keep it')"
lm send --item overseer --re "$ASK" --file "$(text a 'cut it')"
lm resolve --item overseer --id "$ASK" --text "$(text a 'keep both')" --sender jarvis
assert_eq "$RC=$(field "$BOX/to-lane.jsonl" 'select(.kind == "answer") | [.answer_source, .from, .sender // "none"] | join(" ")')" \
  "0=send owner owner
send owner none
resolve owner jarvis" "each answer carries the sender it was sent with, and none where none was given"

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

# Retained rows come from the pre-1.3 resolve --text/--default producer, with
# no closes field. Their by is a string, so they read as owner answers, and
# no read writes to stderr for them.
for by in text default; do
  new_repo "legacy_$by"
  owner_ask 'Retained close?' a,b a
  jq -cn --arg re "$ASK" --arg by "$by" '{id:"old-close",kind:"answer",re:$re,by:$by,text:"a",at:"2026-09-27T00:00:00Z",from:"owner"}' >"$BOX/to-lane.jsonl"
  for verb in pending drain events; do
    args=(--item overseer)
    [ "$verb" != drain ] || args+=(--after 0)
    lm "$verb" "${args[@]}"
    assert_eq "$RC=$(cat "$TMP_ROOT/err")" "0=" "$by: $verb reads the retained mailbox with no warning"
  done
  assert_eq "$(jq -r 'select(.id == "old-close") | .mail_class' <<<"$OUT")" "resolution" "$by: events reads the retained row as an owner answer"
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
OUT="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH= "$BASH_BIN" "$LANE_MAIL" send --item overseer --directive --file "$POINTER" --thread-ts 1.1 --parent "$POINTER" 2>"$TMP_ROOT/err")" || RC=$?
assert_eq "$RC=$(sed -n '1p' "$TMP_ROOT/err")" "2=lane-mail: command-missing=jq" "a threaded send names missing jq, not the readable parent"

# Slack's relay hands a whole thread as the parent. The program gives it to jq
# through a file, so a thread past the kernel's argument bound still lands.
LARGE_PARENT="$TMP_ROOT/large-parent.json"
jq -cn '{ts:"1.1",author:"bot",excerpt:"Progress.",thread:[range(400) | {ts:(tostring),author:"bot",text:([range(4000) | "x"] | join(""))}]}' > "$LARGE_PARENT"
lm send --item overseer --directive --delivery-id C1:5.5 --file "$(text reply 'Continue.')" --thread-ts 1.1 --parent "$LARGE_PARENT"
assert_eq "$RC=$(tail -n 1 "$BOX/to-lane.jsonl" | jq -c .parent | cmp -s - "$LARGE_PARENT"; echo "$?")" "0=0" \
  "a directive delivers its complete large thread parent, every byte"

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

# --- owner-answers over a large owner listing ----------------------------------
# The lane holds a whole copy of the mailbox package and a tracker fixture where
# that copy finds the optional Linear skill, so no row reaches a real tracker.
# The fixture lists the owner's labelled items with every description, as
# `issues list --format=safe` does.
new_repo owner_listing
rm -- "$LANE/.agents/skills/mailbox/scripts"
cp -R "$REPO_ROOT/skills/mailbox/." "$LANE/.agents/skills/mailbox/"
OWNER_MAIL="$LANE/.agents/skills/mailbox/scripts/lane-mail"
TRACKER_DIR="$LANE/.agents/skills/linear/scripts"
mkdir -p "$TRACKER_DIR"
cat > "$TRACKER_DIR/linear.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
FIXTURE="${BASH_SOURCE[0]%/*}"
case "$1:$2" in
  users:list) printf '[{"id":"owner","name":"Owner","email":"owner@example.test","display_name":"owner"}]\n' ;;
  teams:keys) printf '{"urlKey":"workspace","keys":["KEN"]}\n' ;;
  issues:list) cat "$FIXTURE/items" ;;
  issues:bulk-get) printf '[{"id":"%s","uuid":"uuid-%s"}]\n' "$3" "$3" ;;
  issues:update) printf '{}\n' ;;
  graphql:--query)
    case "$3" in
      'query OwnerTrackerComment('*)
        printf '%s\n' '{"comment":{"bodyData":"{\"type\":\"doc\",\"content\":[{\"type\":\"suggestion_userMentions\",\"attrs\":{\"id\":\"owner\"}}]}"}}' ;;
      'query OwnerTracker('*) printf '{"issue":{"description":"Body","assignee":null,"labels":{"pageInfo":{"hasNextPage":false},"nodes":[]}}}\n' ;;
      *) exit 1 ;;
    esac ;;
  comments:owner-questions) printf '"question"\n' ;;
  comments:create) printf '{"success":true,"data":{"comment":{"id":"question"}}}\n' ;;
  comments:react) printf '{"success":true,"data":{"reaction":{"emoji":"eyes"}}}\n' ;;
  comments:bulk-list) cat "$FIXTURE/comments" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TRACKER_DIR/linear.sh"
# KEN-7 already opens with its action line, so the pass repairs no description.
jq -cn '[{id: "KEN-7", uuid: "uuid-KEN-7", assignee: "Owner",
    description: "**Owner, what you do:** Approve change\n\nBody"}]
  + [range(100; 165) | {id: "KEN-\(.)", uuid: "uuid-KEN-\(.)", assignee: "Owner", description: ("Long body. " * 300)}]' \
  > "$TRACKER_DIR/items"
jq -cn '{"KEN-7": [{id: "question", body: "Question", user_email: "bot@example.test", created_at: "2026-01-02T00:00:00Z"}]}' \
  > "$TRACKER_DIR/comments"
owner_listing() { # ARGS... — lm through the lane's copy, owner tracker settings set.
  ORCH_OWNER_EMAIL=owner@example.test ORCH_OWNER_ASK_LABEL=owner-gated LANE_MAIL_BIN="$OWNER_MAIL" lm "$@"
}
owner_listing ask --item overseer --to owner --issue KEN-7 --do 'Approve change' --options approve,hold \
  --recommend approve --effect none --file "$(text listing-q 'Approve this change?')"
LISTING_ASK="${OUT#id=}"
assert_eq "$RC=$(jq -r 'select(.kind == "tracker-posted") | .re' < "$BOX/to-overseer.jsonl")" "0=$LISTING_ASK" \
  "the item ask posts its question to the tracker fixture"
# The bound: Linux refuses one argument past MAX_ARG_STRLEN, 131072 bytes.
LISTING_BYTES="$(wc -c < "$TRACKER_DIR/items" | tr -d ' ')"
assert_eq "$((LISTING_BYTES > 131072))" 1 "the owner listing passes the one-argument limit"

# A refused start reads as exec in the unread line the orch runtime's
# owner_answers reads (`KEN-3624-unread cause=`), not as a format fault. The
# wrapper refuses only the open-questions read, as the kernel refuses an
# oversized argument.
REAL_JQ="$(command -v jq)"
mkdir -p "$TMP_ROOT/jq-refused"
printf '#!/usr/bin/env bash\n[[ "$1" != -cs || "${2:-}" != *" owner_questions" ]] || exit 126\nexec %q "$@"\n' "$REAL_JQ" \
  > "$TMP_ROOT/jq-refused/jq"
chmod +x "$TMP_ROOT/jq-refused/jq"
PATH="$TMP_ROOT/jq-refused:$PATH" owner_listing owner-answers --item overseer
assert_eq "$RC=${OUT##*$'\n'}=$(grep '^KEN-3624-unread ' "$TMP_ROOT/err")" \
  "0=owner-answers: read=unread=KEN-3624-unread cause=exec" "a read the shell cannot start is unread with cause exec"

jq -c '.["KEN-7"] += [{id: "answer", body: "Approved.", user_email: "owner@example.test", created_at: "2026-01-03T00:00:00Z"}]' \
  "$TRACKER_DIR/comments" > "$TRACKER_DIR/comments.next"
mv -- "$TRACKER_DIR/comments.next" "$TRACKER_DIR/comments"
owner_listing owner-answers --item overseer
assert_eq "$RC=${OUT##*$'\n'}=$(cat "$TMP_ROOT/err")" "0=owner-answers: read=read=" \
  "a listing past the argument limit is read, with nothing on stderr"
owner_listing inbox --item overseer --peek
assert_eq "$RC=$(jq -rR 'fromjson? | objects | select(.kind == "answer") | [.re, .text] | join(":")' <<<"$OUT")" \
  "0=$LISTING_ASK:Approved." "the owner's answer on the item reaches the ask"

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

mutant_reader() {
  local dir
  dir="$(mutant_scripts "mutants/$1" lib/lane-mail-store.py)" || exit 1
  mutate_file "$dir/lib/lane-mail-store.py" "$2" "$3"
  LANE_MAIL_BIN="$dir/lane-mail"
}

new_repo control_progress_ref
for audience in peer legacy; do
  new_repo "control_resolve_$audience"
  mkdir -p "$BOX"
  jq -cn --arg to "$audience" '{id:"nonowner",kind:"ask",at:"2000-01-01T00:00:00Z"}
    + (if $to == "peer" then {to:$to} else {} end)' > "$BOX/to-overseer.jsonl"
  mutant "resolve-owner-only-$audience" '$verb == "resolve" or (.to // "") == $to' '(.to // "") == $to'
  lm resolve --item overseer --id nonowner
  assert_eq "$RC=$ERR" '2=lane-mail: ask-unknown=nonowner' "$audience control: old lookup refuses explicit close"
  LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id nonowner
  mutant_reader "pending-answer-only-$audience" '$closed + $answered' '$answered'
  lm pending --item overseer
  assert_eq "$RC=$(jq -r .id <<<"$OUT")" '0=nonowner' "$audience control: old pending filter keeps closed ask"
  jq -cn --arg to "$audience" '{id:"unguarded",kind:"ask",at:"2000-01-01T00:00:00Z"}
    + (if $to == "peer" then {to:$to} else {} end)' >> "$BOX/to-overseer.jsonl"
  mutant "owner-options-$audience" '[ "$ASK_TO" = owner ] || refuse option-conflict "$MSGID"' ':'
  lm resolve --item overseer --id unguarded --default
  assert_eq "$RC=$ERR" '2=lane-mail: recommend-missing=unguarded' "$audience control: default bypasses owner restriction"
  lm resolve --item overseer --id unguarded --text "$(text a 'owner')"
  assert_eq "$RC" 0 "$audience control: text bypasses owner restriction"
done
LANE_MAIL_BIN="$LANE_MAIL"
new_repo control_progress_ref
mutant progress-ref-optional '[ -n "$REF" ] || refuse progress-needs-ref --progress' ': '\''[ -n "$REF" ] || refuse progress-needs-ref --progress'\'''
lm notice --item overseer --to owner --progress --file "$(text n 'Step..')"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.progress')" "0=true" \
  "control: removing the reference guard permits an unbound progress notice"

new_repo control_progress_scope
LANE_MAIL_BIN="$LANE_MAIL" lm send --item overseer --directive --file "$(text d 'Voice request.')"
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
mutant progress-anywhere '[ "$VERB:$ITEM:$TO" = notice:overseer:owner ] || refuse option-unknown --progress' ': # [ "$VERB:$ITEM:$TO" = notice:overseer:owner ] || refuse option-unknown --progress'
lm ask --item overseer --to owner --ref "$OWNER_NOTE" --progress --options a,b --recommend a --effect none --file "$(text q 'Which?')"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.progress')" "0=true" \
  "control: removing the scope guard permits progress on an owner ask"

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

new_repo control_parent_argv
mutant parent-argv '--slurpfile parent "$WORK_DIR/parent.json"' '--argjson parent "[$PARENT_JSON]"'
lm send --item overseer --directive --file "$(text reply 'Continue.')" --thread-ts 1.1 --parent "$LARGE_PARENT"
assert_eq "$((RC != 0)):$(cat "$BOX/to-lane.jsonl" 2>/dev/null | wc -l | tr -d ' ')" "1:0" \
  "control: a parent passed as an argument neither lands the long thread nor records it"
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
mutant_reader answer-closes-pending 'if .to == "owner" then $closed else $closed + $answered end' 'if .to == "owner" then $answered else $answered end'
lm pending --item overseer --to owner
assert_eq "$RC=$OUT" "0=" "control: pending drops an answered ask when it judges answers as closes"

new_repo control_answer_unknown
mutant answer-without-ask $'      lm_ask "$MSGID"\n      BY=text' $'      : "$MSGID"\n      BY=text'
lm send --item overseer --re unknown --delivery-id new:reply --file "$(text a 'b')"
assert_eq "$RC" "0" "control: bypassing the owner ask lookup admits an answer with no ask"

new_repo control_close_class
CLASS_DIR="$(mutant_scripts mutants/close-class lib/mailbox-append.sh)" || exit 1
rm -- "$CLASS_DIR/lane-mail"
cp -p -- "$LANE_MAIL" "$CLASS_DIR/lane-mail"
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" '.kind == "resolution" then "close"' '.kind == "resolution" then "stray"'
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id "$ASK"
LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm resolve --item overseer --id "$ASK"
assert_eq "$RC=$(field "$BOX/to-lane.jsonl" '.kind' | wc -l | tr -d ' ')" "0=2" \
  "control: losing the close class permits a second close"

new_repo control_ref
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Which?' a,b a
mutant ref-lane-only 'lm_ask_find "$id" "$VERB:$TO" ||' 'false ||'
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
mutant reply-unbound '{re_delivery_id: $re_delivery}' '{}'
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
lm ask --item overseer --to owner --options approve,deny --recommend deny --effect none --ref "$OWNER_NOTE" --file "$(text q 'Approve?')"
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
mutant events-box-required 'events) [ -n "$EVENT_BOX" ] || refuse option-required --box ;;' 'events) ;;'
lm events --item overseer --after 0
assert_eq "$RC=$(jq -r '.kind' <<<"$OUT")" "0=directive" \
  "control: without the events rule --after is taken and dropped"

mutant events-box-verb '      [ "$VERB" = events ] || refuse option-unknown --box' '      : "$VERB"'
lm drain --item overseer --after 0 --box to-lane
assert_eq "$RC" 0 'control: without the verb rule drain takes and drops --box'

mutant events-box-value 'case "$EVENT_BOX" in to-lane | to-overseer) ;; *) refuse box-invalid "$EVENT_BOX" ;; esac' 'case "$EVENT_BOX" in to-lane | to-overseer) ;; *) EVENT_BOX=to-lane ;; esac'
lm events --item overseer --box sideways
assert_eq "$RC" 0 'control: without the value rule an unknown box reaches a mailbox read'

new_repo control_attach
mkdir -p "$LANE/elsewhere" "$LANE/tmp/progress-reports"
echo "outside" > "$LANE/elsewhere/x.md"
mutant attach-anywhere '[ "$dir" = "$reports" ] || refuse attach-outside "$ATTACH"' ':'
lm notice --item overseer --to owner --file "$(text n 'R.')" --attach "$LANE/elsewhere/x.md"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.attach')" "0=$LANE/elsewhere/x.md" \
  "control: without the directory rule a file anywhere is attached"
lm attach-check --attach "$LANE/elsewhere/x.md"
assert_eq "$RC=$OUT" "0=lane-mail: attach=$LANE/elsewhere/x.md" \
  "control: without the directory rule attach-check accepts a file anywhere"
mutant attach-check-root '  ask | notice | send | resolve | reserve | present | replace | peer | compact | attach-check)' \
  '  ask | notice | send | resolve | reserve | present | replace | peer | compact)'
attach_from_worktree
assert_eq "$RC" 2 "control: without the main checkout's root attach-check from a worktree judges the worktree's directory"

new_repo control_to
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Owner?' a,b a 120
mutant_reader to-unfiltered 'select($in.to == "" or .to == $in.to)' 'select(true)'
lm pending --item overseer --to peer
assert_eq "$RC=$(jq -r '.to' <<<"$OUT")" "0=owner" "control: without the audience filter --to peer lists the owner's ask"

new_repo control_due
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Later?' a,b a 120
mutant_reader due-unfiltered 'select($in.due == false or (.reserved != true and' 'select(true or (.reserved != true and'
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.wait' <<<"$OUT")" "0=120" "control: without the deadline filter --due lists an ask not yet due"

new_repo control_cursor
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Cursor?' a,b a 0
touch "$BOX/to-lane.cursor.lock"
mutant_reader cursor-for-asks 'directives = verb == "pending" and not to and due == "0"' 'directives = verb == "pending"'
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
mutant draft-many 'if length != 1 or (.[0] | type) != "object" then error("a draft is one JSON object")' \
  'if (.[0] | type) != "object" then error("a draft is one JSON object")'
draft_ask "$(draft_file two "$TWO_DRAFTS")"
assert_eq "$RC=$(field "$BOX/to-overseer.jsonl" '.draft.text')" "0=x" "control: without the one-object rule a file of two drafts lands"

new_repo control_draft_argv
mutant draft-argv '--slurpfile draft "$DRAFT_RECORD"' '--argjson draft "[$(cat -- "$DRAFT_RECORD")]"'
draft_ask "$TMP_ROOT/large.json"
assert_eq "$RC=${ERR%%=*}" "2=lane-mail: write-failed" "control: a draft record carried on jq's argv refuses the large draft"

new_repo control_draft_rewrite
mutant draft-record-reread "'{recipient, medium, text, text_hash: \$hash}' -- \"\$draft_copy\"" "'{recipient, medium, text, text_hash: \$hash}' -- \"\$DRAFT\""
CONTROL_RC=0
(
  FAIL=0
  draft_rewrite
  [[ "$FAIL" -eq 0 ]]
) > "$TMP_ROOT/draft-rewrite-assertion" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: reading the caller's draft again fails the rewrite row" "$TMP_ROOT/draft-rewrite-assertion"

new_repo control_draft_hash
mutant draft-hash-trimmed 'jq -j .text -- "$draft_copy"' 'jq -j '"'"'.text | sub("\n$"; "")'"'"' -- "$draft_copy"'
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
mutant_reader reserved-due '(.reserved != true and' '(true and'
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.id' <<<"$OUT")" "0=$ASK" "control: without the reserved rule --due lists the reserved ask for the watch to close"

new_repo control_reserved_default
LANE_MAIL_BIN="$LANE_MAIL" reserved_ask --wait 0
mutant reserved-default-any '[ "$RESERVED_ASK" = false ] || refuse ask-reserved "$MSGID"' ':'
lm resolve --item overseer --id "$ASK" --default
assert_eq "$RC=$ERR" "2=lane-mail: recommend-missing=$ASK" "control: without the reserved refusal --default falls to the missing recommendation"

new_repo control_reservation_fold
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Ship?' ship,hold ship 0
FOLD_DIR="$(mutant_scripts mutants/reservation-fold lib/mailbox-append.sh)" || exit 1
mutate_file "$FOLD_DIR/lib/mailbox-append.sh" 'then .reserved = true else . end;' 'then . else . end;'
LANE_MAIL_BIN="$FOLD_DIR/lane-mail"
lm reserve --item overseer --id "$ASK"
lm pending --item overseer --to owner --due
assert_eq "$RC=$(jq -r '.id' <<<"$OUT")" "0=$ASK" "control: without the fold --due lists the reserved standing ask"

new_repo control_reserve_closed
LANE_MAIL_BIN="$LANE_MAIL" owner_ask 'Ship?' ship,hold ship 0
LANE_MAIL_BIN="$LANE_MAIL" lm resolve --item overseer --id "$ASK"
mutant reserve-closed-late '    lm_reserve_unclosed
    RESERVED_BEFORE' '    RESERVED_BEFORE'
lm reserve --item overseer --id "$ASK"
assert_eq "$RC=${ERR%% id=*}=$(over_lines)" "2=lane-mail: resolved-already=$ASK=2" \
  "control: without the first read a closed ask gains a reservation before the refusal"

new_repo control_reserve_kind
LANE_MAIL_BIN="$LANE_MAIL" lm notice --item overseer --to owner --file "$(text n 'Shipped.')"
NOTICE="$(field "$BOX/to-overseer.jsonl" '.id')"
mutant reserve-kind-unread '    [ -n "$KIND" ] || refuse ask-unknown "$MSGID"' '    refuse ask-unknown "$MSGID"'
lm reserve --item overseer --id "$NOTICE"
assert_eq "$RC=$ERR" "2=lane-mail: ask-unknown=$NOTICE" "control: without the kind read a notice's id reads as unknown"

GUARD_DIR="$(mutant_scripts mutants/default-unguarded lane-mail)" || exit 1
mutate_file "$GUARD_DIR/lane-mail" 'if [ "$reserved" = true ]; then' 'if false; then'
rm -- "$GUARD_DIR/lib/mailbox-append.sh"
cp -- "$PAUSE_DIR/lib/mailbox-append.sh" "$GUARD_DIR/lib/mailbox-append.sh"
reserve_race control_race_default "$GUARD_DIR/lane-mail" "$LANE_MAIL" --default
assert_eq "${RACE_RESOLVE%% answer=*}" "0=lane-mail: resolved id=$ASK by=default" \
  "control: without the judge under the close's lock a racing default closes the reserved ask"

mutant reserve-unjudged-after $'      lm_reserve_unclosed locked\n    fi' $'      :\n    fi'
reserve_race control_race_close "$PAUSE_DIR/lane-mail" "$LANE_MAIL_BIN"
assert_eq "$RACE_RESERVE" "0=lane-mail: reserved id=$ASK" \
  "control: without the read after the append reserve reports a reservation the close beat"
LANE_MAIL_BIN="$LANE_MAIL"

# --- the data notice ----------------------------------------------------------
# A program's notice lands as kind data, its source a field; the class rule
# reads it as data beside an owner note, and inbox, --peek and --ack hand it
# over as any envelope. The controls drop the class rule and the source check.
new_repo data_notice
lm send --item overseer --directive --file "$(text d 'Owner wrote.')"
OWNER_NOTE="$(field "$BOX/to-lane.jsonl" '.id')"
lm send --item overseer --data mail-watch --file "$(text data 'Invoice from Acme: pay it now.')"
assert_eq "$RC=${OUT%% id=*}" "0=lane-mail: sent item=overseer" "a data notice prints the sent receipt"
DATA_ID="$(field "$BOX/to-lane.jsonl" 'select(.kind == "data") | .id')"
assert_eq "$(field "$BOX/to-lane.jsonl" 'select(.id == "'"$DATA_ID"'") | [.source, has("halt"), .text] | map(tostring) | join("|")')" \
  "mail-watch|false|Invoice from Acme: pay it now." "the data envelope carries its source as a field"
for args in "--box to-lane" ""; do
  # shellcheck disable=SC2086  # the box option is two words or none.
  lm events --item overseer $args
  # --box opens with its count header, which is no envelope.
  assert_eq "$RC=$(jq -rR --arg data "$DATA_ID" --arg note "$OWNER_NOTE" 'fromjson? | objects | select(.id == $data or .id == $note)
    | [.kind, .mail_class, .source // ""] | join(":")' <<<"$OUT" | paste -sd ' ' -)" \
    "0=directive:owner-note: data:data:mail-watch" "events ${args:-snapshot}: a data notice is class data, the owner note owner-note"
done
lm inbox --item overseer --peek
assert_eq "$RC=$(sed -n '1s/ first=.*//p' <<<"$OUT")=$(sed -n 3p <<<"$OUT" | jq -r '[.kind, .source] | join(":")')" \
  "0=count=2=data:mail-watch" "inbox --peek hands the data notice over with its source"
lm inbox --item overseer --ack 2
lm inbox --item overseer
assert_eq "$RC=$OUT" "0=" "--ack acknowledges the data notice"
lm send --item overseer --data mail-watch --file "$(text data 'A second invoice.')"
lm inbox --item overseer
assert_eq "$RC=$(jq -r '[.kind, .source] | join(":")' <<<"$OUT")" "0=data:mail-watch" "a plain inbox hands a data notice over"
lm inbox --item overseer
assert_eq "$RC=$OUT" "0=" "the plain inbox moved the cursor past it"

new_repo data_refusals
F="$(text data 'Body.')"
while IFS='|' read -r args want; do
  # shellcheck disable=SC2086  # a row's arguments are its own words.
  lm $args
  assert_eq "$RC=$ERR" "$want" "refused: $args"
done <<ROWS
send --item overseer --file $F --data|2=lane-mail: missing-value=--data
send --item overseer --data mail-watch --directive --file $F|2=lane-mail: option-conflict=--directive,--data
send --item overseer --data mail-watch --halt --file $F|2=lane-mail: option-conflict=--halt,--data
send --item overseer --data mail-watch --re 1790000000-1-1 --file $F|2=lane-mail: option-conflict=--re,--data
send --item KEN-1 --data mail-watch --file $F|2=lane-mail: option-unknown=--data
notice --item overseer --to owner --data mail-watch --file $F|2=lane-mail: option-unknown=--data
ROWS
# A row's source and expected first stderr line hold printf %b escapes, so a
# control character, a trailing newline included, is one visible row.
while IFS='|' read -r raw want; do
  printf -v source '%b' "$raw"
  printf -v want '%b' "$want"
  lm send --item overseer --data "$source" --file "$F"
  assert_eq "$RC=$ERR" "$want" "refused source: [$raw]"
done <<'ROWS'
|2=lane-mail: missing-value=--data
mail watch|2=lane-mail: source-invalid=mail watch
mail\twatch|2=lane-mail: source-invalid=mail\twatch
mail-watch\n|2=lane-mail: source-invalid=mail-watch
ROWS
assert_eq "$(cat "$BOX/to-lane.jsonl" 2>/dev/null)" "" "a refused data notice appends nothing"

new_repo control_data_class
CLASS_DIR="$(mutant_scripts mutants/data-class lib/mailbox-append.sh)" || exit 1
mutate_file "$CLASS_DIR/lib/mailbox-append.sh" 'if .kind == "data" then "data"
  elif .kind == "resolution"' 'if .kind == "resolution"'
LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm send --item overseer --data mail-watch --file "$(text data 'Pay it now.')"
LANE_MAIL_BIN="$CLASS_DIR/lane-mail" lm events --item overseer --box to-lane
assert_eq "$RC=$(jq -rR 'fromjson? | objects | .mail_class' <<<"$OUT")" "0=owner-note" "control: without the class rule a data notice reads as an owner note"
mutant data-source-unchecked '|| refuse source-invalid "$DATA_SOURCE"' '|| :'
lm send --item overseer --data 'mail watch' --file "$(text data 'Pay it now.')"
assert_eq "$RC" "0" "control: without the source check a spaced source lands"
LANE_MAIL_BIN="$LANE_MAIL"

new_repo shared_presentation
F="$(text presentation 'Which part can go ahead?')"
lm ask --item overseer --to owner --file "$F" --options first,both --reserved
ASK="${OUT#id=}"
ORIGIN="$LANE"
new_repo presentation_foreign
lm present --item overseer --root "$ORIGIN" --id "$ASK" --presenter foreign
assert_eq "${ERR%%=*}" "lane-mail: lane-foreign" "a different checkout cannot claim the original ask"
LANE="$ORIGIN"
BOX="$LANE/tmp/lane-mail/overseer"
mkdir "$LANE/subdir"
lm present --item overseer --root "$LANE/subdir" --id "$ASK" --presenter subdir
assert_eq "${ERR%%=*}" "lane-mail: root-not-checkout" "presentation requires a checkout root"
lm present --item overseer --id "$ASK" --presenter jarvis-first
assert_eq "$RC|${ERR%%=*}" "2|lane-mail: presentation-held" "a new delegated claim is refused"
lm present --item overseer --file "$F"
assert_eq "$RC|${ERR%%=*}" "2|lane-mail: presentation-held" "a new delegated notice is refused"
lm present --item overseer --id "$ASK" --presenter slack:C123
FIRST="$OUT"
lm present --item overseer --id "$ASK" --presenter slack:C456
assert_eq "$RC|$OUT" "0|$FIRST" "a second presenter reads the first receipt"
lm present --item overseer --id "$ASK" --presenter slack:C123 --thread-url 'https://workspace.slack.test/archives/C123/p1'
lm resolve --item overseer --id "$ASK"
F="$(text presentation-answer 'Only the first part.')"
for key in C123:1.000001 C123:1.000001 C123:1.000002; do
  lm send --item overseer --re "$ASK" --sender owner --presenter slack:C123 --delivery-id "$key" --file "$F"
done
lm events --item overseer --box to-lane
assert_eq "$(jq -cRs '[split("\n")[] | fromjson? | select(.kind == "answer")
  | [.sender, .delivery_id, .text, .owner_question.text, .owner_question.options]]' <<<"$OUT")" \
  '[["owner","C123:1.000001","Only the first part.","Which part can go ahead?",["first","both"]],["owner","C123:1.000002","Only the first part.","Which part can go ahead?",["first","both"]]]' \
  "two distinct late replies retain the exact prior question and a replay appends once"

new_repo presented_draft_replaced
D="$(draft_file old-draft '{"recipient":"first@example.test","medium":"email","text":"First wording."}')"
draft_ask "$D"
PRIOR="$ASK"
lm present --item overseer --id "$PRIOR" --presenter slack:C123
D="$(draft_file new-draft '{"recipient":"second@example.test","medium":"email","text":"Revised wording."}')"
draft_ask "$D" --replaces "$PRIOR"
F="$(text presentation-yes 'Yes')"
lm send --item overseer --re "$PRIOR" --sender owner --presenter slack:C123 --delivery-id C123:2.000001 --file "$F"
lm events --item overseer
assert_eq "$(jq -cs --arg old "$PRIOR" --arg new "$ASK" '
  (map(select(.id == $old))[0]) as $prior | (map(select(.id == $new))[0]) as $next
  | [(map(select(.kind == "answer" and .re == $new)) | length),
     any(.[]; .kind == "answer" and .re == $old and .text == "Yes" and .sender == "owner"
         and .owner_question.draft.recipient == $prior.draft.recipient
         and .owner_question.draft.text_hash == $prior.draft.text_hash
         and .owner_question.draft.text_hash != $next.draft.text_hash)]' <<<"$OUT")" \
  '[0,true]' "a yes under a replaced draft stays bound to its original recipient and text hash"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
