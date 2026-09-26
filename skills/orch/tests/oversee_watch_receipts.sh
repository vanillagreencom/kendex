#!/usr/bin/env bash
# oversee-watch's directive receipts: what a lane's to-lane.cursor makes the
# watch say about the directives the overseer sent it. The cursor is the
# receipt, whichever of the lane's read paths moved it. The real `lane-mail`
# writes and reads each mailbox; the rest of the sandbox is
# lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/growth-state.sh"

LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
HEARTBEAT='EVENT heartbeat loops=1 interval=0s since=none'

echo "=== oversee-watch directive receipts ==="

mail_reset() { # ITEM
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p -- "$CASE_REPO_ROOT/tmp/lane-mail/$1"
}
# The overseer's directive to ITEM; prints its id.
direct() { # ITEM TEXT
  printf '%s\n' "$2" > "$TMP_ROOT/directive.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item "$1" --root "$CASE_REPO_ROOT" --directive \
    --file "$TMP_ROOT/directive.txt") | sed -n 's/^lane-mail: sent item=[^ ]* id=\([^ ]*\) .*/\1/p'
}
# The lane's own read at a wait point, which moves its cursor.
lane_reads() { # ITEM
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" inbox --item "$1" >/dev/null)
}
# One run's receipt lines for ITEM, their event words joined, or the first
# line when there are none. RECEIPT_ARGS are further watch arguments.
RECEIPT_ARGS=()
receipts() { # ITEM [WATCH_BIN] [ENV...]
  local item="$1" bin="${2:-}" out
  shift
  [[ $# -eq 0 ]] || shift
  out="$(WATCH_BIN="$bin" run_watch "$@" -- --max-loops 1 --item "$item" ${RECEIPT_ARGS[@]+"${RECEIPT_ARGS[@]}"} \
    2>"$STUB_DIR/receipts.err")"
  RECEIPTS="$(grep -E "^EVENT directive-(read|unread) $item " <<<"$out" | sed -E 's/ age=[0-9]+$/ age=N/' | paste -sd '|' -)" \
    || RECEIPTS="$(head -1 <<<"$out")"
}

read_sequence() { # [WATCH_BIN]
  local bin="${1:-}"
  mail_reset KEN-80
  receipts KEN-80 "$bin"
  READ_FIRST="$RECEIPTS"
  READ_ID="$(direct KEN-80 'Rebase onto main.')"
  receipts KEN-80 "$bin" ORCH_DIRECTIVE_UNREAD_SECS=3600
  READ_YOUNG="$RECEIPTS"
  lane_reads KEN-80
  receipts KEN-80 "$bin"
  READ_AFTER="$RECEIPTS"
  receipts KEN-80 "$bin"
  READ_AGAIN="$RECEIPTS"
}
new_case receipts_read
read_sequence
assert_eq "$READ_FIRST|$READ_YOUNG" "$HEARTBEAT|$HEARTBEAT" \
  "a lane with nothing sent and one with a directive younger than the age say nothing" "$STUB_DIR/receipts.err"
assert_eq "$READ_AFTER" "EVENT directive-read KEN-80 $READ_ID" \
  "the lane's cursor passing the directive is its receipt, reported as directive-read" "$STUB_DIR/receipts.err"
assert_eq "$READ_AGAIN" "$HEARTBEAT" "and reported once" "$STUB_DIR/receipts.err"

unread_sequence() {
  mail_reset KEN-81
  receipts KEN-81
  UNREAD_ID="$(direct KEN-81 'Stop and rebase.')"
  receipts KEN-81 "" ORCH_DIRECTIVE_UNREAD_SECS=0
  UNREAD_FIRST="$RECEIPTS"
  receipts KEN-81 "" ORCH_DIRECTIVE_UNREAD_SECS=0
  UNREAD_AGAIN="$RECEIPTS"
  lane_reads KEN-81
  receipts KEN-81 "" ORCH_DIRECTIVE_UNREAD_SECS=0
  UNREAD_READ="$RECEIPTS"
}
new_case receipts_unread
unread_sequence
assert_eq "$UNREAD_FIRST|$UNREAD_AGAIN|$UNREAD_READ" \
  "EVENT directive-unread KEN-81 $UNREAD_ID age=N|$HEARTBEAT|EVENT directive-read KEN-81 $UNREAD_ID" \
  "a directive past the age the cursor has not passed is directive-unread once, then directive-read when read" \
  "$STUB_DIR/receipts.err"

# A lane first watched after it read its mail: the watch starts from its
# cursor, so no directive it read before is replayed as news.
new_case receipts_first_watch
mail_reset KEN-82
direct KEN-82 'Old news.' >/dev/null
lane_reads KEN-82
receipts KEN-82
assert_eq "$RECEIPTS" "$HEARTBEAT" "a lane first watched is taken as having read up to its cursor" "$STUB_DIR/receipts.err"

# A lane never sent a directive is watched on its empty mailbox, and that read
# seeds its row at 0: a first directive the lane reads before the next mail
# pass is still reported read, not taken for one read before it was watched.
first_directive() {
  mail_reset KEN-90
  receipts KEN-90
  FIRST_ID="$(direct KEN-90 'First word.')"
  lane_reads KEN-90
  receipts KEN-90
  FIRST_READ="$RECEIPTS"
}
new_case receipts_first_directive
first_directive
assert_eq "$FIRST_READ" "EVENT directive-read KEN-90 $FIRST_ID" \
  "a first directive read within one mail pass of an empty mailbox is directive-read" "$STUB_DIR/receipts.err"

# The suite's one must-fail control: the lane's cursor never read, so a
# directive the lane read is never reported. The copy keeps orch's place in a
# skills tree: its libraries resolve the github skill beside it.
MUTANT_DIR="$TMP_ROOT/mutant"
MUTANT_WATCH="$(mutant_scripts mutant/orch oversee-watch)/oversee-watch" || exit 1
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
mutate_file "$MUTANT_WATCH" '    lane_read="${BASH_REMATCH[1]}"' '    lane_read=0'
new_case receipts_read_mutant
read_sequence "$MUTANT_WATCH"
assert_eq "$READ_AFTER" "$HEARTBEAT" "control: with the cursor unread, a directive the lane read is never reported" \
  "$STUB_DIR/receipts.err"

# A hosted lane whose cursor read comes back short once, in either shape: the
# provider's read of to-lane.cursor exits as a file not there while its probe
# answers, or the file reads lower than the count reported. That pass is a
# read that missed, not a cursor moved back, so the directive the lane read
# long ago is neither unread then nor read again after.
short_cursor() { # absent|low
  local box="$STUB_DIR/remote/srv/lane/KEN-83/tmp/lane-mail/KEN-83"
  local -a host_env=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log"
    LANE_HOST_STUB_DIR="$STUB_DIR/remote" OVERSEE_WATCH_LANE_MAIL="$LANE_MAIL") short_env=()
  mkdir -p "$box"
  : > "$box/to-lane.cursor.lock"
  printf 'gitdir: /srv/clone/.git/worktrees/ken-83\n' > "$STUB_DIR/remote/srv/lane/KEN-83/.git"
  printf '{"id":"old-1","kind":"directive","at":"2026-01-01T00:00:00Z","from":"overseer:repo","text":"Rebase."}\n' \
    > "$box/to-lane.jsonl"
  printf '1\n' > "$box/to-lane.cursor"
  RECEIPT_ARGS=(--hosted KEN-83=/srv/lane/KEN-83)
  receipts KEN-83 "" "${host_env[@]}"
  SHORT="$RECEIPTS|"
  case "$1" in
    absent) short_env=(LANE_HOST_STUB_CAT_STATUS=2 LANE_HOST_STUB_CAT_PATH=/srv/lane/KEN-83/tmp/lane-mail/KEN-83/to-lane.cursor) ;;
    low) printf '0\n' > "$box/to-lane.cursor" ;;
  esac
  receipts KEN-83 "" "${host_env[@]}" ${short_env[@]+"${short_env[@]}"}
  SHORT+="$RECEIPTS|"
  printf '1\n' > "$box/to-lane.cursor"
  receipts KEN-83 "" "${host_env[@]}"
  SHORT+="$RECEIPTS"
  RECEIPT_ARGS=()
}
for shape in absent low; do
  new_case "receipts_short_cursor_$shape"
  short_cursor "$shape"
  assert_eq "$SHORT" "$HEARTBEAT|$HEARTBEAT|$HEARTBEAT" \
    "a cursor read that comes back $shape reports nothing, and the read after it nothing again" "$STUB_DIR/receipts.err"
done

# A lane first watched on a read that missed: its to-lane.jsonl, or its
# to-lane.cursor, comes back not there on the first pass. Nothing is seeded
# from that read, so the two directives it read long ago are neither unread
# on that pass nor read on the next.
first_watch_missed() { # to-lane.jsonl|to-lane.cursor
  local box="$STUB_DIR/remote/srv/lane/KEN-87/tmp/lane-mail/KEN-87"
  local -a host_env=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log"
    LANE_HOST_STUB_DIR="$STUB_DIR/remote" ORCH_DIRECTIVE_UNREAD_SECS=0 OVERSEE_WATCH_LANE_MAIL="$LANE_MAIL")
  mkdir -p "$box"
  : > "$box/to-lane.cursor.lock"
  printf 'gitdir: /srv/clone/.git/worktrees/ken-87\n' > "$STUB_DIR/remote/srv/lane/KEN-87/.git"
  printf '{"id":"old-%s","kind":"directive","at":"2026-01-01T00:00:00Z","from":"overseer:repo","text":"Rebase."}\n' 1 2 \
    > "$box/to-lane.jsonl"
  printf '2\n' > "$box/to-lane.cursor"
  RECEIPT_ARGS=(--hosted KEN-87=/srv/lane/KEN-87)
  receipts KEN-87 "" "${host_env[@]}" LANE_HOST_STUB_CAT_STATUS=2 \
    LANE_HOST_STUB_CAT_PATH="/srv/lane/KEN-87/tmp/lane-mail/KEN-87/$1"
  MISSED_FIRST="$RECEIPTS|"
  receipts KEN-87 "" "${host_env[@]}"
  MISSED_FIRST+="$RECEIPTS"
  RECEIPT_ARGS=()
}
for missed_file in to-lane.jsonl to-lane.cursor; do
  new_case "receipts_first_watch_missed_${missed_file#to-lane.}"
  first_watch_missed "$missed_file"
  assert_eq "$MISSED_FIRST" "$HEARTBEAT|$HEARTBEAT" \
    "a lane first watched on a missed $missed_file read seeds nothing from it" "$STUB_DIR/receipts.err"
done

# A lane that has never read has neither a to-lane.cursor nor the lock its
# reads leave, so it has read nothing, and its directive past the age is
# reported unread on the first pass.
never_read() {
  mail_reset KEN-88
  NEVER_ID="$(direct KEN-88 'Read me.')"
  receipts KEN-88 "" ORCH_DIRECTIVE_UNREAD_SECS=0 OVERSEE_WATCH_LANE_MAIL="$LANE_MAIL"
  NEVER="$RECEIPTS"
}
new_case receipts_never_read
never_read
assert_eq "$NEVER" "EVENT directive-unread KEN-88 $NEVER_ID age=N" \
  "a lane with neither cursor nor lock has read nothing, and its old directive is unread" "$STUB_DIR/receipts.err"

# A lane relaunched onto a fresh mailbox: its to-lane.jsonl opens on another
# id, so the counts start over and the new mailbox's first directive is read.
replaced_mailbox() {
  local box="$CASE_REPO_ROOT/tmp/lane-mail/KEN-84"
  mail_reset KEN-84
  receipts KEN-84
  direct KEN-84 'Old mailbox.' >/dev/null
  lane_reads KEN-84
  receipts KEN-84
  rm -f -- "$box/to-lane.jsonl" "$box/to-lane.cursor"
  REPLACED_ID="$(direct KEN-84 'New mailbox.')"
  lane_reads KEN-84
  receipts KEN-84
  REPLACED="$RECEIPTS"
}
new_case receipts_replaced
replaced_mailbox
assert_eq "$REPLACED" "EVENT directive-read KEN-84 $REPLACED_ID" \
  "a mailbox opening on another id starts the counts over, so its first directive is read" "$STUB_DIR/receipts.err"

# A lane relaunched onto a fresh mailbox after reading a directive: its empty
# to-lane.jsonl reads a cursor of 0, below the one reported, until a directive
# lands. That holds its directive lines alone, so its first ask is reported.
relaunch_ask() {
  local out
  mail_reset KEN-86
  receipts KEN-86
  direct KEN-86 'Old mailbox.' >/dev/null
  lane_reads KEN-86
  receipts KEN-86
  mail_reset KEN-86
  printf 'Squash or merge?\n' > "$TMP_ROOT/ask.txt"
  RELAUNCH_ASK="$(cd "$CASE_REPO_ROOT" && "$LANE_MAIL" ask --item KEN-86 --file "$TMP_ROOT/ask.txt")"
  out="$(run_watch -- --max-loops 1 --item KEN-86 2>"$STUB_DIR/receipts.err")"
  RELAUNCHED="$(head -1 <<<"$out")"
}
new_case receipts_relaunch_ask
relaunch_ask
assert_eq "$RELAUNCHED" "EVENT lane-question KEN-86 ${RELAUNCH_ASK#id=}" \
  "a cursor below the one reported still reports the relaunched lane's ask" "$STUB_DIR/receipts.err"

# An answer the lane read sits on a line the cursor counts: the directive sent
# after it is on the line past the cursor, unread, never taken for read.
answered_first() {
  mail_reset KEN-85
  receipts KEN-85 "" OVERSEE_WATCH_LANE_MAIL="$LANE_MAIL"
  printf 'Merge it.\n' > "$TMP_ROOT/answer.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item KEN-85 --root "$CASE_REPO_ROOT" --re some-ask \
    --file "$TMP_ROOT/answer.txt" >/dev/null)
  lane_reads KEN-85
  ANSWERED_ID="$(direct KEN-85 'Halt after the answer.')"
  receipts KEN-85 "" OVERSEE_WATCH_LANE_MAIL="$LANE_MAIL" ORCH_DIRECTIVE_UNREAD_SECS=0
  ANSWERED="$RECEIPTS"
}
new_case receipts_after_answer
answered_first
assert_eq "$ANSWERED" "EVENT directive-unread KEN-85 $ANSWERED_ID age=N" \
  "a directive after an answer the lane read is unread, the answer's line counted by the cursor" "$STUB_DIR/receipts.err"

# The heartbeat's owed mail pass after a long pass that overran: under the stub
# clock the turn's mail pass reads a directive younger than the age, and the
# long pass's pr-watch moves the clock past it. The owed pass reads the clock
# afresh and reports the directive unread.
overrun_unread() {
  local sent
  mail_reset KEN-84
  OVERRUN_ID="$(direct KEN-84 'Rebase before the review.')"
  sent="$(date -u +%s)"
  printf '%s\n' "$((sent + 10))" > "$STUB_DIR/now.epoch"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s > "$STUB_DIR/now.epoch"\nexec "%s" "$@"\n' \
    "$((sent + 1000))" "$TMP_ROOT/bin/pr-watch-stub.sh" > "$STUB_DIR/pr-watch-overrun.sh"
  chmod +x "$STUB_DIR/pr-watch-overrun.sh"
  receipts KEN-84 "" ORCH_DIRECTIVE_UNREAD_SECS=300 OVERSEE_WATCH_PR_WATCH="$STUB_DIR/pr-watch-overrun.sh"
}
new_case receipts_overrun_unread
overrun_unread
assert_eq "$RECEIPTS" "EVENT directive-unread KEN-84 $OVERRUN_ID age=N" \
  "the owed mail pass after an overrunning long pass judges a directive's age on a fresh clock" \
  "$STUB_DIR/receipts.err"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
