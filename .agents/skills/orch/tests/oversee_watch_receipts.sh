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

unread_sequence() { # [WATCH_BIN]
  local bin="${1:-}"
  mail_reset KEN-81
  receipts KEN-81 "$bin"
  UNREAD_ID="$(direct KEN-81 'Stop and rebase.')"
  receipts KEN-81 "$bin" ORCH_DIRECTIVE_UNREAD_SECS=0
  UNREAD_FIRST="$RECEIPTS"
  receipts KEN-81 "$bin" ORCH_DIRECTIVE_UNREAD_SECS=0
  UNREAD_AGAIN="$RECEIPTS"
  lane_reads KEN-81
  receipts KEN-81 "$bin" ORCH_DIRECTIVE_UNREAD_SECS=0
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
first_directive() { # [WATCH_BIN]
  local bin="${1:-}"
  mail_reset KEN-90
  receipts KEN-90 "$bin"
  FIRST_ID="$(direct KEN-90 'First word.')"
  lane_reads KEN-90
  receipts KEN-90 "$bin"
  FIRST_READ="$RECEIPTS"
}
new_case receipts_first_directive
first_directive
assert_eq "$FIRST_READ" "EVENT directive-read KEN-90 $FIRST_ID" \
  "a first directive read within one mail pass of an empty mailbox is directive-read" "$STUB_DIR/receipts.err"

# Must-fail inverses: the cursor not read, so no directive is ever read; and
# the unread line not remembered, so it comes back on every run.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
receipts_mutant() { # NAME OLD NEW
  python3 - "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$MUTANT_DIR/orch/scripts/oversee-watch-$1" "$2" "$3" <<'PY'
import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, "receipts mutant pattern: " + old
open(out, "w").write(s.replace(old, new))
PY
  chmod +x "$MUTANT_DIR/orch/scripts/oversee-watch-$1"
}
receipts_mutant cursorless '    lane_read="${BASH_REMATCH[1]}"' '    lane_read=0'
receipts_mutant forgetful '        unread_at="$line"' '        :'
receipts_mutant replacement-kept '      elif [[ -n "$to_first" && -n "$seen" && "$to_first" != "$seen" ]]; then
        read_at=0; unread_at=0' '      elif [[ -n "$to_first" && -n "$seen" && "$to_first" != "$seen" ]]; then
        :'
# lane-mail numbering the directive lines alone, off the cursor's scale.
DIRONLY="$MUTANT_DIR/orch/scripts/lane-mail-dironly"
python3 - "$REPO_ROOT/skills/orch/scripts/lane-mail" "$DIRONLY" <<'PY'
import sys
src, out = sys.argv[1:]
s = open(src).read()
old = "foreach inputs as $raw (0; . + 1;"
assert s.count(old) == 1, "dironly mutant pattern"
open(out, "w").write(s.replace(old, 'foreach (inputs | select(test("directive"))) as $raw (0; . + 1;'))
PY
chmod +x "$DIRONLY"
# lane-mail mutants of the one rule that tells a lane that never read from a
# cursor read that missed: every absent cursor read as 0, or as missed.
lane_mail_mutant() { # NAME OLD NEW
  python3 - "$REPO_ROOT/skills/orch/scripts/lane-mail" "$MUTANT_DIR/orch/scripts/lane-mail-$1" "$2" "$3" <<'PY'
import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, "lane-mail mutant pattern: " + old
open(out, "w").write(s.replace(old, new))
PY
  chmod +x "$MUTANT_DIR/orch/scripts/lane-mail-$1"
}
lane_mail_mutant missed-zero '        [ "$LM_FETCH_ABSENT" -eq 1 ] || SEEN=missed' '        :'
lane_mail_mutant missed-always '        [ "$LM_FETCH_ABSENT" -eq 1 ] || SEEN=missed' '        SEEN=missed'
# The watch judging an empty listing a missed read itself, so a row is never
# seeded from one; and lane-mail clamping a cursor over one to 0.
receipts_mutant seed-skips-empty '      elif ! [[ "$read_at" =~ ^[0-9]+$ && "$unread_at" =~ ^[0-9]+$ ]]; then
        read_at="$lane_read"; unread_at=0' '      elif ! [[ "$read_at" =~ ^[0-9]+$ && "$unread_at" =~ ^[0-9]+$ ]]; then
        if [[ "$header" == *" count=0 "* ]]; then hold=directives; else read_at="$lane_read"; unread_at=0; fi'
lane_mail_mutant empty-clamped '      if [ "$SEEN" -gt 0 ] && [ "$COUNT" -eq 0 ]; then' '      if false; then'
receipts_mutant reset-on-short '      elif [[ "$lane_read" -lt "$read_at" ]]; then
        hold=directives' '      elif [[ "$lane_read" -lt "$read_at" ]]; then
        read_at=0; unread_at=0'
receipts_mutant short-holds-item '      elif [[ "$lane_read" -lt "$read_at" ]]; then
        hold=directives' '      elif [[ "$lane_read" -lt "$read_at" ]]; then
        hold=item'
# A hosted lane whose cursor read comes back short once, in either shape: the
# provider's read of to-lane.cursor exits as a file not there while its probe
# answers, or the file reads lower than the count reported. That pass is a
# read that missed, not a cursor moved back, so the directive the lane read
# long ago is neither unread then nor read again after.
short_cursor() { # absent|low [WATCH_BIN] [LANE_MAIL]
  local bin="${2:-}" box="$STUB_DIR/remote/srv/lane/KEN-83/tmp/lane-mail/KEN-83"
  local -a host_env=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log"
    LANE_HOST_STUB_DIR="$STUB_DIR/remote" OVERSEE_WATCH_LANE_MAIL="${3:-$LANE_MAIL}") short_env=()
  mkdir -p "$box"
  : > "$box/to-lane.cursor.lock"
  printf 'gitdir: /srv/clone/.git/worktrees/ken-83\n' > "$STUB_DIR/remote/srv/lane/KEN-83/.git"
  printf '{"id":"old-1","kind":"directive","at":"2026-01-01T00:00:00Z","from":"overseer:repo","text":"Rebase."}\n' \
    > "$box/to-lane.jsonl"
  printf '1\n' > "$box/to-lane.cursor"
  RECEIPT_ARGS=(--hosted KEN-83=/srv/lane/KEN-83)
  receipts KEN-83 "$bin" "${host_env[@]}"
  SHORT="$RECEIPTS|"
  case "$1" in
    absent) short_env=(LANE_HOST_STUB_CAT_STATUS=2 LANE_HOST_STUB_CAT_PATH=/srv/lane/KEN-83/tmp/lane-mail/KEN-83/to-lane.cursor) ;;
    low) printf '0\n' > "$box/to-lane.cursor" ;;
  esac
  receipts KEN-83 "$bin" "${host_env[@]}" ${short_env[@]+"${short_env[@]}"}
  SHORT+="$RECEIPTS|"
  printf '1\n' > "$box/to-lane.cursor"
  receipts KEN-83 "$bin" "${host_env[@]}"
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
first_watch_missed() { # to-lane.jsonl|to-lane.cursor [WATCH_BIN] [LANE_MAIL]
  local bin="${2:-}" box="$STUB_DIR/remote/srv/lane/KEN-87/tmp/lane-mail/KEN-87"
  local -a host_env=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log"
    LANE_HOST_STUB_DIR="$STUB_DIR/remote" ORCH_DIRECTIVE_UNREAD_SECS=0 OVERSEE_WATCH_LANE_MAIL="${3:-$LANE_MAIL}")
  mkdir -p "$box"
  : > "$box/to-lane.cursor.lock"
  printf 'gitdir: /srv/clone/.git/worktrees/ken-87\n' > "$STUB_DIR/remote/srv/lane/KEN-87/.git"
  printf '{"id":"old-%s","kind":"directive","at":"2026-01-01T00:00:00Z","from":"overseer:repo","text":"Rebase."}\n' 1 2 \
    > "$box/to-lane.jsonl"
  printf '2\n' > "$box/to-lane.cursor"
  RECEIPT_ARGS=(--hosted KEN-87=/srv/lane/KEN-87)
  receipts KEN-87 "$bin" "${host_env[@]}" LANE_HOST_STUB_CAT_STATUS=2 \
    LANE_HOST_STUB_CAT_PATH="/srv/lane/KEN-87/tmp/lane-mail/KEN-87/$1"
  MISSED_FIRST="$RECEIPTS|"
  receipts KEN-87 "$bin" "${host_env[@]}"
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
never_read() { # [LANE_MAIL]
  mail_reset KEN-88
  NEVER_ID="$(direct KEN-88 'Read me.')"
  receipts KEN-88 "" ORCH_DIRECTIVE_UNREAD_SECS=0 OVERSEE_WATCH_LANE_MAIL="${1:-$LANE_MAIL}"
  NEVER="$RECEIPTS"
}
new_case receipts_never_read
never_read
assert_eq "$NEVER" "EVENT directive-unread KEN-88 $NEVER_ID age=N" \
  "a lane with neither cursor nor lock has read nothing, and its old directive is unread" "$STUB_DIR/receipts.err"

# A lane relaunched onto a fresh mailbox: its to-lane.jsonl opens on another
# id, so the counts start over and the new mailbox's first directive is read.
replaced_mailbox() { # [WATCH_BIN]
  local bin="${1:-}" box="$CASE_REPO_ROOT/tmp/lane-mail/KEN-84"
  mail_reset KEN-84
  receipts KEN-84 "$bin"
  direct KEN-84 'Old mailbox.' >/dev/null
  lane_reads KEN-84
  receipts KEN-84 "$bin"
  rm -f -- "$box/to-lane.jsonl" "$box/to-lane.cursor"
  REPLACED_ID="$(direct KEN-84 'New mailbox.')"
  lane_reads KEN-84
  receipts KEN-84 "$bin"
  REPLACED="$RECEIPTS"
}
new_case receipts_replaced
replaced_mailbox
assert_eq "$REPLACED" "EVENT directive-read KEN-84 $REPLACED_ID" \
  "a mailbox opening on another id starts the counts over, so its first directive is read" "$STUB_DIR/receipts.err"

# A lane relaunched onto a fresh mailbox after reading a directive: its empty
# to-lane.jsonl reads a cursor of 0, below the one reported, until a directive
# lands. That holds its directive lines alone, so its first ask is reported.
relaunch_ask() { # [WATCH_BIN]
  local out
  mail_reset KEN-86
  receipts KEN-86 "${1:-}"
  direct KEN-86 'Old mailbox.' >/dev/null
  lane_reads KEN-86
  receipts KEN-86 "${1:-}"
  mail_reset KEN-86
  printf 'Squash or merge?\n' > "$TMP_ROOT/ask.txt"
  RELAUNCH_ASK="$(cd "$CASE_REPO_ROOT" && "$LANE_MAIL" ask --item KEN-86 --file "$TMP_ROOT/ask.txt")"
  out="$(WATCH_BIN="${1:-}" run_watch -- --max-loops 1 --item KEN-86 2>"$STUB_DIR/receipts.err")"
  RELAUNCHED="$(head -1 <<<"$out")"
}
new_case receipts_relaunch_ask
relaunch_ask
assert_eq "$RELAUNCHED" "EVENT lane-question KEN-86 ${RELAUNCH_ASK#id=}" \
  "a cursor below the one reported still reports the relaunched lane's ask" "$STUB_DIR/receipts.err"

# An answer the lane read sits on a line the cursor counts: the directive sent
# after it is on the line past the cursor, unread, never taken for read.
answered_first() { # [LANE_MAIL]
  local lane_mail="${1:-$LANE_MAIL}"
  mail_reset KEN-85
  receipts KEN-85 "" OVERSEE_WATCH_LANE_MAIL="$lane_mail"
  printf 'Merge it.\n' > "$TMP_ROOT/answer.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item KEN-85 --root "$CASE_REPO_ROOT" --re some-ask \
    --file "$TMP_ROOT/answer.txt" >/dev/null)
  lane_reads KEN-85
  ANSWERED_ID="$(direct KEN-85 'Halt after the answer.')"
  receipts KEN-85 "" OVERSEE_WATCH_LANE_MAIL="$lane_mail" ORCH_DIRECTIVE_UNREAD_SECS=0
  ANSWERED="$RECEIPTS"
}
new_case receipts_after_answer
answered_first
assert_eq "$ANSWERED" "EVENT directive-unread KEN-85 $ANSWERED_ID age=N" \
  "a directive after an answer the lane read is unread, the answer's line counted by the cursor" "$STUB_DIR/receipts.err"

new_case receipts_read_mutant
read_sequence "$MUTANT_DIR/orch/scripts/oversee-watch-cursorless"
assert_eq "$READ_AFTER" "$HEARTBEAT" "control: with the cursor unread, a directive the lane read is never reported" \
  "$STUB_DIR/receipts.err"
new_case receipts_unread_mutant
unread_sequence "$MUTANT_DIR/orch/scripts/oversee-watch-forgetful"
assert_contains "$UNREAD_AGAIN" "EVENT directive-unread KEN-81 $UNREAD_ID age=N" \
  "control: with the reported line forgotten, the unread directive is reported on every run" "$STUB_DIR/receipts.err"

new_case receipts_replaced_mutant
replaced_mailbox "$MUTANT_DIR/orch/scripts/oversee-watch-replacement-kept"
assert_eq "$REPLACED" "$HEARTBEAT" \
  "control: counts kept across a replacement leave its first directive unreported" "$STUB_DIR/receipts.err"
new_case receipts_after_answer_mutant
answered_first "$DIRONLY"
assert_eq "$ANSWERED" "EVENT directive-read KEN-85 $ANSWERED_ID" \
  "control: directive lines numbered alone report an unread directive as read" "$STUB_DIR/receipts.err"

new_case receipts_short_cursor_low_mutant
short_cursor low "$MUTANT_DIR/orch/scripts/oversee-watch-reset-on-short"
assert_eq "${SHORT##*|}" "EVENT directive-read KEN-83 old-1" \
  "control: a lower cursor taken as a replacement reports the old directive read again" "$STUB_DIR/receipts.err"
new_case receipts_relaunch_ask_mutant
relaunch_ask "$MUTANT_DIR/orch/scripts/oversee-watch-short-holds-item"
assert_eq "$RELAUNCHED" "$HEARTBEAT" \
  "control: a cursor below the one reported holding the item never reports the relaunched lane's ask" \
  "$STUB_DIR/receipts.err"
# No control of its own for the absent shape past a first pass: the lower
# cursor rule above also holds it, since a cursor lane-mail read as 0 sits
# below the one reported; the first-pass rows below are where `missed` alone
# decides.
new_case receipts_first_watch_missed_lane_mutant
first_watch_missed to-lane.jsonl "" "$MUTANT_DIR/orch/scripts/lane-mail-empty-clamped"
assert_eq "$MISSED_FIRST" "$HEARTBEAT|EVENT directive-read KEN-87 old-1|EVENT directive-read KEN-87 old-2" \
  "control: a cursor clamped over an empty read seeds a row that replays both directives as read" "$STUB_DIR/receipts.err"
new_case receipts_first_directive_mutant
first_directive "$MUTANT_DIR/orch/scripts/oversee-watch-seed-skips-empty"
assert_eq "$FIRST_READ" "$HEARTBEAT" \
  "control: an empty mailbox left unseeded takes a first directive read within a pass for one read before" \
  "$STUB_DIR/receipts.err"
new_case receipts_first_watch_missed_cursor_mutant
first_watch_missed to-lane.cursor "" "$MUTANT_DIR/orch/scripts/lane-mail-missed-zero"
assert_eq "$MISSED_FIRST" "EVENT directive-unread KEN-87 old-1 age=N|EVENT directive-unread KEN-87 old-2 age=N|EVENT directive-read KEN-87 old-1|EVENT directive-read KEN-87 old-2" \
  "control: a missed cursor read as 0 on a first pass reports both read directives unread" "$STUB_DIR/receipts.err"
new_case receipts_never_read_mutant
never_read "$MUTANT_DIR/orch/scripts/lane-mail-missed-always"
assert_eq "$NEVER" "$HEARTBEAT" \
  "control: a cursor not there always taken for a missed read never reports the unread directive" "$STUB_DIR/receipts.err"

# The heartbeat's owed mail pass after a long pass that overran: under the stub
# clock the turn's mail pass reads a directive younger than the age, and the
# long pass's pr-watch moves the clock past it. The owed pass reads the clock
# afresh and reports the directive unread.
overrun_unread() { # [WATCH_BIN]
  local sent
  mail_reset KEN-84
  OVERRUN_ID="$(direct KEN-84 'Rebase before the review.')"
  sent="$(date -u +%s)"
  printf '%s\n' "$((sent + 10))" > "$STUB_DIR/now.epoch"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" %s > "$STUB_DIR/now.epoch"\nexec "%s" "$@"\n' \
    "$((sent + 1000))" "$TMP_ROOT/bin/pr-watch-stub.sh" > "$STUB_DIR/pr-watch-overrun.sh"
  chmod +x "$STUB_DIR/pr-watch-overrun.sh"
  receipts KEN-84 "${1:-}" ORCH_DIRECTIVE_UNREAD_SECS=300 OVERSEE_WATCH_PR_WATCH="$STUB_DIR/pr-watch-overrun.sh"
}
new_case receipts_overrun_unread
overrun_unread
assert_eq "$RECEIPTS" "EVENT directive-unread KEN-84 $OVERRUN_ID age=N" \
  "the owed mail pass after an overrunning long pass judges a directive's age on a fresh clock" \
  "$STUB_DIR/receipts.err"
receipts_mutant stale-owed $'    MAIL_OWED=0\n    # A turn of its own: the turn\'s reading predates the long pass it follows.\n    PASS_NOW="$(date -u +%s)" || die time-failed "" "clock=UTC"\n' \
  $'    MAIL_OWED=0\n'
new_case receipts_overrun_unread_mutant
overrun_unread "$MUTANT_DIR/orch/scripts/oversee-watch-stale-owed"
assert_eq "$RECEIPTS" "$HEARTBEAT" \
  "control: the owed pass on the turn's clock takes the directive for one still younger than the age" \
  "$STUB_DIR/receipts.err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
