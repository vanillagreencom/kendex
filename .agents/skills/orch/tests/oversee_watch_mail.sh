#!/usr/bin/env bash
# oversee-watch's lane-mail pass: what a lane's mailbox makes the watch say.
# The pass reads mailboxes, never panes, so every case runs with no lane window
# but the hosted lane's close, and one with no tmux at all. The real `lane-mail` writes and reads each
# mailbox. The rest of the sandbox is lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# shellcheck source=lib/oversee-watch-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/oversee-watch-harness.sh"

LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
FIXTURE_HOST="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
HEARTBEAT='EVENT heartbeat loops=1 interval=0s since=none'

echo "=== oversee-watch lane mail ==="

# Under the sandbox repository the watch runs in, where lane-mail resolves a
# lane root with no --root of its own.
mail_reset() { # ITEM
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  mkdir -p -- "$CASE_REPO_ROOT/tmp/lane-mail/$1"
}

say() { # ITEM VERB TEXT [OPTIONS] -> the id, for an ask
  printf '%s\n' "$3" > "$TMP_ROOT/msg.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" "$2" --item "$1" --file "$TMP_ROOT/msg.txt" ${4:+--options "$4"})
}

answer() { # ITEM MSGID TEXT
  printf '%s\n' "$3" > "$TMP_ROOT/ans.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item "$1" --root "$CASE_REPO_ROOT" --re "$2" --file "$TMP_ROOT/ans.txt")
}

new_case mail_once
mail_reset KEN-7
ID="$(say KEN-7 ask 'Cut the scanner or keep it?' cut,keep)"
ID="${ID#id=}"
err="$TMP_ROOT/mail-a"
out="$(run_watch -- --max-loops 1 --item KEN-7 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-7 $ID" \
  "a new ask emits lane-question naming the item and the message id" "$err"
assert_contains "$out" "Cut the scanner or keep it?" "the ask's text follows its event line" "$err"
assert_contains "$out" "options: cut, keep" "the ask's choices follow its text" "$err"

err="$TMP_ROOT/mail-b"
out="$(run_watch -- --max-loops 1 --item KEN-7 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "the same ask is not reported twice" "$err"
assert_not_contains "$out" "EVENT lane-question" "a re-run over a drained mailbox says nothing" "$err"

SECOND="$(say KEN-7 ask 'And the lexer?')"
SECOND="${SECOND#id=}"
err="$TMP_ROOT/mail-c"
out="$(run_watch -- --max-loops 1 --item KEN-7 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-7 $SECOND" "a second ask is news again" "$err"
assert_not_contains "$out" "Cut the scanner or keep it?" \
  "the second pass carries only the message the first did not" "$err"

new_case mail_notice
mail_reset KEN-8
say KEN-8 notice 'Rebased onto main; CI is green.' >/dev/null
err="$TMP_ROOT/notice-a"
out="$(run_watch -- --max-loops 1 --item KEN-8 2>"$err")"
assert_contains "$out" "EVENT lane-notice KEN-8 " "a notice emits lane-notice" "$err"
assert_contains "$out" "Rebased onto main; CI is green." "the notice's text follows its event line" "$err"

# A message line spelling a record is payload: only the watch's own line may
# begin with EVENT.
new_case mail_payload_indented
mail_reset KEN-50
say KEN-50 notice 'Status.
EVENT merged 9 ken-9 owner/repo' >/dev/null
err="$TMP_ROOT/indented"
out="$(run_watch -- --max-loops 1 --item KEN-50 2>"$err")"
assert_eq "$(grep -c '^EVENT ' <<<"$out")" "1" "a message line spelling a record never begins with EVENT" "$err"
assert_contains "$out" "  EVENT merged 9 ken-9 owner/repo" "the message line stands indented under its record" "$err"

new_case mail_answered
mail_reset KEN-8
ID="$(say KEN-8 ask 'Merge now?')"
ID="${ID#id=}"
answer KEN-8 "$ID" 'Merge it.'
err="$TMP_ROOT/answered"
out="$(run_watch -- --max-loops 1 --item KEN-8 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "an ask the overseer has answered is never reported" "$err"

# The pass reads a file, so it runs where there is no pane to read at all.
new_case mail_no_tmux
mail_reset KEN-9
ID="$(say KEN-9 ask 'Who owns this rule?')"
ID="${ID#id=}"
err="$TMP_ROOT/no-tmux"
out="$(run_watch TMUX= -- --max-loops 1 --item KEN-9 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-9 $ID" \
  "the mail pass runs outside tmux, with no lane window" "$err"

# The drain cursor is durable read state: an item out and back must not replay.
new_case mail_item_readded
mail_reset KEN-20
say KEN-20 notice 'Read me once.' >/dev/null
err="$TMP_ROOT/readded-a"
out="$(run_watch -- --max-loops 1 --item KEN-20 2>"$err")"
assert_contains "$out" "EVENT lane-notice KEN-20 " "the notice is reported on the run that finds it" "$err"
err="$TMP_ROOT/readded-b"
out="$(run_watch -- --max-loops 1 --item KEN-21 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "a run that does not name the item reports nothing for it" "$err"
err="$TMP_ROOT/readded-c"
out="$(run_watch -- --max-loops 1 --item KEN-20 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" \
  "the item named again drains from where it left off, not from zero" "$err"

# The remote root exists nowhere on this disk, so a pass that quietly fell
# back to the local root would read an empty mailbox instead.
new_case mail_hosted
mail_reset KEN-10
REMOTE_ROOT=/srv/lane/ken-10
REMOTE_DISK="$STUB_DIR/remote"
mkdir -p "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-10"
printf 'gitdir: /srv/clone/.git/worktrees/ken-10\n' > "$REMOTE_DISK$REMOTE_ROOT/.git"
printf '{"id":"remote-1","kind":"ask","at":"t","text":"Hosted question"}\n' \
  > "$REMOTE_DISK$REMOTE_ROOT/tmp/lane-mail/KEN-10/to-overseer.jsonl"
err="$TMP_ROOT/hosted"
out="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
  LANE_HOST_STUB_DIR="$REMOTE_DISK" -- --max-loops 1 --item KEN-10 --hosted "KEN-10=$REMOTE_ROOT" 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-10 remote-1" \
  "--hosted reads the lane's mailbox on its own host" "$err"
assert_contains "$out" "Hosted question" "the hosted ask's text follows its event line" "$err"
assert_contains "$(cat "$STUB_DIR/host.log")" "$REMOTE_ROOT/tmp/lane-mail/KEN-10/to-overseer.jsonl" \
  "the transport call log names the remote path the pass read" "$err"

new_case mail_hosted_invalid
err="$TMP_ROOT/hosted-bad"
out="$(run_watch -- --max-loops 1 --item KEN-10 --hosted 'KEN 10=/srv' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a --hosted value that names no item exits 2"
assert_eq "$(grep -c '^oversee-watch: hosted-invalid value=KEN 10=/srv$' "$err")" "1" \
  "the refusal names its reason and the value it rejected"
# An entry for an item the run does not watch reads no mailbox, and the item it
# was meant for quietly reads its local root.
err="$TMP_ROOT/hosted-unknown"
out="$(run_watch -- --max-loops 1 --item KEN-10 --hosted 'KEN-11=/srv' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "a --hosted item this run does not watch exits 2"
assert_eq "$(grep -c '^oversee-watch: hosted-unknown-item item=KEN-11$' "$err")" "1" \
  "the refusal names the item nothing watches"

new_case mail_unreadable
mail_reset KEN-11
say KEN-11 notice 'x' >/dev/null
chmod 000 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-11/to-overseer.jsonl"
err="$TMP_ROOT/unreadable"
out="$(run_watch -- --max-loops 1 --item KEN-11 2>"$err")" && rc=0 || rc=$?
chmod 644 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-11/to-overseer.jsonl"
assert_eq "$rc" "2" "a mailbox that cannot be read exits 2 rather than reading the lane as silent"
assert_eq "$(grep -c '^oversee-watch: mail-read-failed item=KEN-11 exit=2$' "$err")" "1" \
  "the refusal names the item and the reader's exit status"
assert_contains "$(cat "$err")" "lane-mail: file-unreadable=" "the reader's own keyed line is kept under the watch's"

# Two items, the second unreadable: one pass over both, then the repair and a
# second pass. BLOCKED_FIRST is what the second pass said about the first item,
# which is where an uncommitted cursor shows up as a message reported twice.
blocked_pair() { # FIRST SECOND [WATCH_BIN]
  local sealed="$CASE_REPO_ROOT/tmp/lane-mail/$2/to-overseer.jsonl"
  mail_reset "$1"
  mkdir -p -- "${sealed%/*}"
  say "$1" notice 'Read me once.' >/dev/null
  say "$2" notice 'And me.' >/dev/null
  chmod 000 "$sealed"
  BLOCKED_RC=0
  BLOCKED_FIRST="$(WATCH_BIN="${3:-}" run_watch -- --max-loops 1 --item "$1" --item "$2" \
    2>"$TMP_ROOT/blocked-a")" || BLOCKED_RC=$?
  chmod 644 "$sealed"
  BLOCKED_AGAIN="$(WATCH_BIN="${3:-}" run_watch -- --max-loops 1 --item "$1" --item "$2" \
    2>"$TMP_ROOT/blocked-b")"
}

new_case mail_commit_per_item
blocked_pair KEN-30 KEN-31
assert_eq "$BLOCKED_RC" "2" "the pass exits 2 on the mailbox it could not read"
assert_contains "$BLOCKED_FIRST" "EVENT lane-notice KEN-30 " \
  "the item read before it still reported its notice" "$TMP_ROOT/blocked-a"
assert_not_contains "$BLOCKED_AGAIN" "EVENT lane-notice KEN-30 " \
  "the re-run after the repair does not report that notice again" "$TMP_ROOT/blocked-b"

# A relaunched lane brings a fresh mailbox, shorter than the cursor that read
# the old one. The saved cursor would suppress everything the replacement
# holds and then lower itself, losing those messages for good.
new_case mail_replaced
mail_reset KEN-40
# A first line that is no envelope records no first id, so the count decides.
printf 'not an envelope\n' > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl"
say KEN-40 notice 'one' >/dev/null
say KEN-40 notice 'two' >/dev/null
say KEN-40 notice 'three' >/dev/null
err="$TMP_ROOT/replaced-a"
out="$(run_watch -- --max-loops 1 --item KEN-40 2>"$err")"
assert_contains "$out" "EVENT lane-notice KEN-40 " "the first mailbox is drained to its own count" "$err"
REPLACED="$(say KEN-40 ask 'Who owns the replacement?')"
REPLACED="${REPLACED#id=}"
# The replacement: one line where the cursor says four.
printf '%s\n' "$(tail -n 1 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl")" \
  > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl.new"
mv "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl.new" \
  "$CASE_REPO_ROOT/tmp/lane-mail/KEN-40/to-overseer.jsonl"
err="$TMP_ROOT/replaced-b"
out="$(run_watch -- --max-loops 1 --item KEN-40 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-40 $REPLACED" \
  "a mailbox shorter than its cursor is read whole" "$err"
err="$TMP_ROOT/replaced-c"
out="$(run_watch -- --max-loops 1 --item KEN-40 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "and once read, not again" "$err"

# A replacement already holding as many lines as the cursor opens with another
# envelope, which is what tells it from the mailbox drained. REGEN_NOTICES is
# how many of its two notices the second pass reported.
regenerated() { # ITEM [WATCH_BIN]
  local box="$CASE_REPO_ROOT/tmp/lane-mail/$1/to-overseer.jsonl"
  mail_reset "$1"
  say "$1" notice 'old' >/dev/null
  WATCH_BIN="${2:-}" run_watch -- --max-loops 1 --item "$1" >/dev/null 2>"$TMP_ROOT/regen-a"
  printf '%s\n' '{"id":"regen-1","kind":"notice","at":"t","text":"new one"}' \
    '{"id":"regen-2","kind":"notice","at":"t","text":"new two"}' > "$box"
  REGEN_NOTICES="$(WATCH_BIN="${2:-}" run_watch -- --max-loops 1 --item "$1" 2>"$TMP_ROOT/regen-b" |
    grep -c "^EVENT lane-notice $1 ")" || true
}
new_case mail_regenerated
regenerated KEN-42
assert_eq "$REGEN_NOTICES" "2" "a replacement with more lines than the cursor is drained whole" "$TMP_ROOT/regen-b"

# The baseline row never consulted: with it gone the same ask is reported on
# every pass. The copy keeps orch's place in a skills tree so its libraries
# resolve the github skill beside it.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/orch"
cp -R "$REPO_ROOT/skills/orch/scripts" "$MUTANT_DIR/orch/scripts"
ln -s "$REPO_ROOT/skills/github" "$MUTANT_DIR/github"
sed 's@lane_row_get lane-mail "\$state" "\$cursor"@printf ""@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MUTANT_DIR/orch/scripts/oversee-watch"
assert_eq "$(cmp -s "$MUTANT_DIR/orch/scripts/oversee-watch" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the mutant really stops the pass consulting its baseline row"

UNCHECKED="$MUTANT_DIR/orch/scripts/oversee-watch-unchecked"
sed 's@^    \[\[ "\$known" -eq 1 \]\] || die "\$kind-unknown-item" .*$@    :@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$UNCHECKED"
chmod +x "$UNCHECKED"
assert_eq "$(cmp -s "$UNCHECKED" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the unchecked mutant really drops the hosted-item check"
new_case mail_hosted_unchecked
mail_reset KEN-10
err="$TMP_ROOT/hosted-unchecked"
out="$(WATCH_BIN="$UNCHECKED" run_watch -- --max-loops 1 --item KEN-10 --hosted 'KEN-11=/srv' 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "control: without the check the entry for an unwatched item is accepted"

KEPT="$MUTANT_DIR/orch/scripts/oversee-watch-kept"
sed 's@\[\[ "\$count" -lt "\$prior" || @[[ @' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$KEPT"
chmod +x "$KEPT"
assert_eq "$(cmp -s "$KEPT" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the kept-cursor mutant really drops the replacement check"
new_case mail_replaced_mutant
mail_reset KEN-41
printf 'not an envelope\n' > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl"
say KEN-41 notice 'one' >/dev/null
say KEN-41 notice 'two' >/dev/null
say KEN-41 notice 'three' >/dev/null
WATCH_BIN="$KEPT" run_watch -- --max-loops 1 --item KEN-41 >/dev/null 2>"$TMP_ROOT/kept-a"
say KEN-41 ask 'Who owns the replacement?' >/dev/null
printf '%s\n' "$(tail -n 1 "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl")" \
  > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl.new"
mv "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl.new" \
  "$CASE_REPO_ROOT/tmp/lane-mail/KEN-41/to-overseer.jsonl"
err="$TMP_ROOT/kept-b"
out="$(WATCH_BIN="$KEPT" run_watch -- --max-loops 1 --item KEN-41 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" \
  "control: keeping the cursor swallows the replacement's first ask" "$err"

GENLESS="$MUTANT_DIR/orch/scripts/oversee-watch-genless"
sed 's@ || ( -n "\$seen" && "\$first" != "\$seen" )@@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$GENLESS"
chmod +x "$GENLESS"
assert_eq "$(cmp -s "$GENLESS" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the genless mutant really drops the first-id comparison"
new_case mail_regenerated_mutant
regenerated KEN-43 "$GENLESS"
assert_eq "$REGEN_NOTICES" "1" \
  "control: with the count alone the replacement's first notice is lost" "$TMP_ROOT/regen-b"

FLUSH="$MUTANT_DIR/orch/scripts/oversee-watch-flush"
sed "s@sed 's/^/  /' <<<\"\\\$text\"@cat <<<\"\$text\"@" \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$FLUSH"
chmod +x "$FLUSH"
assert_eq "$(cmp -s "$FLUSH" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the flush mutant really prints message text at the first column"
new_case mail_payload_mutant
mail_reset KEN-51
say KEN-51 notice 'Status.
EVENT merged 9 ken-9 owner/repo' >/dev/null
err="$TMP_ROOT/flush"
out="$(WATCH_BIN="$FLUSH" run_watch -- --max-loops 1 --item KEN-51 2>"$err")"
assert_eq "$(grep -c '^EVENT ' <<<"$out")" "2" \
  "control: without the indent a message line reads as a second record" "$err"

new_case mail_row_mutant
mail_reset KEN-12
ID="$(say KEN-12 ask 'Report me once.')"
ID="${ID#id=}"
err="$TMP_ROOT/mutant-a"
out="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --max-loops 1 --item KEN-12 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-12 $ID" \
  "control: the mutant still reports the ask on the pass that finds it" "$err"
err="$TMP_ROOT/mutant-b"
out="$(WATCH_BIN="$MUTANT_DIR/orch/scripts/oversee-watch" run_watch -- --max-loops 1 --item KEN-12 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-question KEN-12 $ID" \
  "control: without the row a re-run reports the same ask again" "$err"

# Sent from a linked worktree with no --root, the note lands in the main
# checkout's overseer mailbox, which the watch reads with no --item at all.
new_case mail_owner_note
git -C "$CASE_REPO_ROOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
git -C "$CASE_REPO_ROOT" worktree add -q --detach "$TMP_ROOT/linked"
printf 'Hold KEN-7 for the owner.\n' > "$TMP_ROOT/note.txt"
(cd "$TMP_ROOT/linked" && "$LANE_MAIL" send --item overseer --directive --file "$TMP_ROOT/note.txt")
NOTE="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || NOTE=unsent
err="$TMP_ROOT/owner-a"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT owner-note $NOTE" \
  "a note to the overseer emits owner-note naming its id" "$err"
assert_contains "$out" "Hold KEN-7 for the owner." "the note's text follows its event line" "$err"
err="$TMP_ROOT/owner-b"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" "the same note is not reported twice" "$err"
err="$TMP_ROOT/owner-c"
out="$(run_watch LINEAR_TEAM -- --max-loops 1 --since 2026-01-01T00:00:00Z 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=2026-01-01T00:00:00Z" \
  "a watch for another fleet's --since does not report the note again" "$err"

# The unkeyed position file every watch on a host shared before the position
# was keyed. The watch whose mailbox it counts adopts it, so the upgrade pass
# replays nothing, and writes the keyed file instead of it.
# How many mailbox-keyed position files the case's state directory holds. The
# glob stands unmatched where there are none, which the existence test drops.
keyed_positions() {
  local f n=0
  for f in "$STATE_DIR"/overseer-mail__*; do
    [[ -e "$f" ]] || continue
    n=$((n + 1))
  done
  printf '%s\n' "$n"
}
new_case mail_legacy_position
mail_reset overseer
printf 'The position predates the key.\n' > "$TMP_ROOT/legacy-note.txt"
(cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive \
  --file "$TMP_ROOT/legacy-note.txt" >/dev/null)
LEGACY_NOTE="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || LEGACY_NOTE=unsent
err="$TMP_ROOT/legacy-a"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT owner-note $LEGACY_NOTE" \
  "the note is reported on the pass that finds it" "$err"
assert_eq "$(keyed_positions)" "1" \
  "the read position is written to a file named for the mailbox it counts"
assert_eq "$([[ -e "$STATE_DIR/overseer-mail" ]] && echo present || echo absent)" "absent" \
  "and never to the unkeyed name"
# What a host that ran the shared file leaves behind. A second note arrives
# before the upgrade pass, so the position that pass writes, two lines read, is
# not the bytes it adopted: a watch that kept writing the unkeyed file would
# leave other bytes there.
mv "$STATE_DIR"/overseer-mail__* "$STATE_DIR/overseer-mail"
printf 'A note the adopted position has not counted.\n' > "$TMP_ROOT/legacy-note-b.txt"
(cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive \
  --file "$TMP_ROOT/legacy-note-b.txt" >/dev/null)
LEGACY_IDS="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || LEGACY_IDS=""
LEGACY_NOTE_B="$(tail -1 <<<"$LEGACY_IDS")"
err="$TMP_ROOT/legacy-b"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT owner-note $LEGACY_NOTE_B" \
  "an unkeyed position whose first id is this mailbox's is the starting position" "$err"
assert_not_contains "$out" "owner-note $LEGACY_NOTE" \
  "so the note that position already counted is not replayed" "$err"
assert_eq "$(cat "$STATE_DIR/overseer-mail")" "1 $LEGACY_NOTE" \
  "the unkeyed file is never written again" "$err"
assert_eq "$(keyed_positions)" "1" \
  "the position it seeded is kept under the keyed name" "$err"
err="$TMP_ROOT/legacy-c"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" \
  "the pass after the upgrade reads the keyed position, not the unkeyed one" "$err"
assert_eq "$(cat "$STATE_DIR/overseer-mail")" "1 $LEGACY_NOTE" \
  "which still holds the bytes the upgrade found there" "$err"

# The upgrade with nothing in the mailbox yet. The shared file holds a real
# position, a count of lines read and the id they opened with, which the
# fixture below puts there. An empty mailbox reports neither, and that report
# is the same "no lines read, no first id" the foot of the pass compares
# against wherever no keyed file exists yet. So the pass finds nothing to
# write, no keyed file appears, and the unkeyed one is still there to be read
# the next pass and the pass after. Only seeding ahead of the pass, in
# watch_state_init, retires it.
new_case mail_legacy_position_empty
mail_reset overseer
mkdir -p "$STATE_DIR"
printf '2 %s' "$LEGACY_NOTE" > "$STATE_DIR/overseer-mail"
err="$TMP_ROOT/legacy-empty"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "$HEARTBEAT" \
  "an empty mailbox under an unkeyed position emits nothing" "$err"
assert_eq "$(keyed_positions)" "1" \
  "and the keyed file exists after that first pass, so the unkeyed one is read no more" "$err"

# The upgrade state a two-overseer host is actually in: the unkeyed file holds
# the OTHER repository's watch's position, a count and a first id no message in
# this mailbox carries. It names a mailbox this one is not, so check_mail's
# replacement branch reads this one whole, once, because that pass writes this
# mailbox's own position under its own name. PEER_FIRST is the line the foreign
# count alone would have skipped, PEER_SEEN counts how often it is reported
# across three passes, and PEER_WHOLE how many lines those passes report.
PEER_POSITION='1 lane-0000000000-peer'
legacy_peer_fleet() { # [WATCH_BIN]
  local bin="${1:-}" n pass out ids
  mail_reset overseer
  for n in 1 2; do
    printf 'Note %s, under a position from another mailbox.\n' "$n" > "$TMP_ROOT/peer-seed-note.txt"
    (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive \
      --file "$TMP_ROOT/peer-seed-note.txt" >/dev/null)
  done
  ids="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || ids=""
  PEER_FIRST="$(head -1 <<<"$ids")"
  mkdir -p "$STATE_DIR"
  printf '%s' "$PEER_POSITION" > "$STATE_DIR/overseer-mail"
  PEER_SEEN=0
  PEER_WHOLE=0
  for pass in 1 2 3; do
    out="$(WATCH_BIN="$bin" run_watch -- --max-loops 1 2>"$TMP_ROOT/peer-$pass")"
    PEER_SEEN=$((PEER_SEEN + $(grep -c "^EVENT owner-note $PEER_FIRST$" <<<"$out" || true)))
    PEER_WHOLE=$((PEER_WHOLE + $(grep -c '^EVENT owner-note ' <<<"$out" || true)))
  done
}
new_case mail_legacy_position_peer
legacy_peer_fleet
assert_eq "$PEER_SEEN" "1" \
  "under another mailbox's position this mailbox is read whole once across three passes" \
  "$TMP_ROOT/peer-3"
assert_eq "$PEER_WHOLE" "2" \
  "and those passes report the two lines it holds, no more" "$TMP_ROOT/peer-3"
assert_eq "$(cat "$STATE_DIR/overseer-mail")" "$PEER_POSITION" \
  "the foreign position is read, never written" "$TMP_ROOT/peer-3"
assert_eq "$(keyed_positions)" "1" \
  "and this mailbox's own position is written under its own name" "$TMP_ROOT/peer-3"

LEGACYREAD="$MUTANT_DIR/orch/scripts/oversee-watch-legacyread"
sed 's@\[\[ ! -e "\$mailf" \]\] || stored=.*@stored="$(cat "$PW_MAIL_LEGACY" 2>/dev/null || true)"@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$LEGACYREAD"
chmod +x "$LEGACYREAD"
assert_eq "$(cmp -s "$LEGACYREAD" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the legacy-read mutant really consults the unkeyed file on every pass"
new_case mail_legacy_position_peer_mutant
legacy_peer_fleet "$LEGACYREAD"
assert_eq "$PEER_SEEN" "3" \
  "control: a watch that consults the unkeyed file every pass replays the mailbox every pass" \
  "$TMP_ROOT/peer-3"
assert_eq "$PEER_WHOLE" "6" \
  "control: reporting both lines three times over" "$TMP_ROOT/peer-3"

# One mailbox, two checkouts. lane-mail resolves the overseer mailbox to the
# main checkout from a linked worktree as well, and every fleet lane runs in
# one, so a watch started there must name the position file the main checkout's
# watch names. WT_SEEN counts how often the one note is reported across a pass
# from each.
git -C "$CASE_REPO_ROOT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m worktree-seed
git -C "$CASE_REPO_ROOT" worktree add -q --detach "$TMP_ROOT/watch-worktree"
mkdir -p "$TMP_ROOT/watch-worktree/.agents/skills"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/watch-worktree/.agents/skills/orch"
worktree_fleet() { # [WATCH_BIN]
  local bin="${1:-}" cwd out
  mail_reset overseer
  printf 'Hold KEN-7, from whichever checkout reads this.\n' > "$TMP_ROOT/wt-note.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive \
    --file "$TMP_ROOT/wt-note.txt" >/dev/null)
  WT_NOTE="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || WT_NOTE=unsent
  WT_SEEN=0
  for cwd in "$CASE_REPO_ROOT" "$TMP_ROOT/watch-worktree"; do
    out="$(WATCH_BIN="$bin" WATCH_CWD="$cwd" run_watch -- --max-loops 1 2>"$TMP_ROOT/wt-${cwd##*/}")"
    WT_SEEN=$((WT_SEEN + $(grep -c "^EVENT owner-note $WT_NOTE$" <<<"$out" || true)))
  done
}
new_case mail_worktree_position
worktree_fleet
assert_eq "$WT_SEEN" "1" \
  "a note is reported once across a pass in the main checkout and a pass in a linked worktree of it" \
  "$TMP_ROOT/wt-watch-worktree"
assert_eq "$(keyed_positions)" "1" \
  "because one mailbox keeps one position file, whichever checkout the watch runs in" \
  "$TMP_ROOT/wt-watch-worktree"

MAINROOT="$MUTANT_DIR/orch/scripts/oversee-watch-mainroot"
sed 's@^MAIL_ROOT="\$(.*@MAIL_ROOT=""@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$MAINROOT"
chmod +x "$MAINROOT"
assert_eq "$(cmp -s "$MAINROOT" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the own-checkout mutant really stops the watch asking which checkout holds the mailbox"
new_case mail_worktree_position_mutant
worktree_fleet "$MAINROOT"
assert_eq "$WT_SEEN" "2" \
  "control: keyed on the watch's own checkout, the worktree pass replays the note the main checkout read" \
  "$TMP_ROOT/wt-watch-worktree"
assert_eq "$(keyed_positions)" "2" \
  "control: and one mailbox ends the case with two position files" \
  "$TMP_ROOT/wt-watch-worktree"

# Two overseers of two repositories on one host point OVERSEE_WATCH_STATE_DIR
# at one directory, which is how their lane claims line up. Each keeps its own
# mailbox read position there, so neither reads the other's and replays its own
# mail. SHARED_ALPHA_SEEN and SHARED_BETA_SEEN count how often each
# repository's one note was emitted across three passes that alternate between
# the two watches.
SHARED_ALPHA="$TMP_ROOT/shared-alpha"
SHARED_BETA="$TMP_ROOT/shared-beta"
for root in "$SHARED_ALPHA" "$SHARED_BETA"; do
  mkdir -p "$root/.agents/skills"
  ln -s "$REPO_ROOT/skills/orch" "$root/.agents/skills/orch"
  git -C "$root" init -q
done
shared_fleet() { # [WATCH_BIN]
  local bin="${1:-}" root pass out
  for root in "$SHARED_ALPHA" "$SHARED_BETA"; do
    rm -rf -- "${root:?}/tmp"
    printf 'Hold the lane.\n' > "$TMP_ROOT/shared-note.txt"
    (cd "$root" && "$LANE_MAIL" send --item overseer --directive \
      --file "$TMP_ROOT/shared-note.txt" >/dev/null)
  done
  SHARED_ALPHA_ID="$(jq -r .id "$SHARED_ALPHA/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || SHARED_ALPHA_ID=unsent
  SHARED_BETA_ID="$(jq -r .id "$SHARED_BETA/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || SHARED_BETA_ID=unsent
  SHARED_ALPHA_SEEN=0
  SHARED_BETA_SEEN=0
  for pass in 1 2 3; do
    out="$(WATCH_BIN="$bin" WATCH_CWD="$SHARED_ALPHA" run_watch -- \
      --max-loops 1 --repo owner/alpha 2>"$TMP_ROOT/shared-alpha-$pass")"
    SHARED_ALPHA_SEEN=$((SHARED_ALPHA_SEEN + $(grep -c "^EVENT owner-note $SHARED_ALPHA_ID$" <<<"$out" || true)))
    out="$(WATCH_BIN="$bin" WATCH_CWD="$SHARED_BETA" run_watch -- \
      --max-loops 1 --repo owner/beta 2>"$TMP_ROOT/shared-beta-$pass")"
    SHARED_BETA_SEEN=$((SHARED_BETA_SEEN + $(grep -c "^EVENT owner-note $SHARED_BETA_ID$" <<<"$out" || true)))
  done
}
new_case mail_shared_state_dir
shared_fleet
assert_eq "$SHARED_ALPHA_SEEN" "1" \
  "one watch's note is emitted once across three passes over a shared state directory" \
  "$TMP_ROOT/shared-alpha-3"
assert_eq "$SHARED_BETA_SEEN" "1" \
  "the other watch's note is emitted once across the same three passes" \
  "$TMP_ROOT/shared-beta-3"

SHAREDKEY="$MUTANT_DIR/orch/scripts/oversee-watch-sharedkey"
sed 's@/overseer-mail__\$(pw_slug "\$MAIL_ROOT")@/overseer-mail@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$SHAREDKEY"
chmod +x "$SHAREDKEY"
assert_eq "$(cmp -s "$SHAREDKEY" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the shared-key mutant really drops the mailbox from the file name"
new_case mail_shared_state_dir_mutant
shared_fleet "$SHAREDKEY"
assert_eq "$SHARED_ALPHA_SEEN" "3" \
  "control: with one position file for both mailboxes one watch replays its note on every pass" \
  "$TMP_ROOT/shared-alpha-3"
assert_eq "$SHARED_BETA_SEEN" "3" \
  "control: and so does the other" \
  "$TMP_ROOT/shared-beta-3"

# A peer overseer writes this one's mailbox from its own checkout, so the watch
# reports the repository the note came from rather than the owner.
new_case mail_peer_note
mail_reset overseer
PEER_REPO="$TMP_ROOT/peer-repo"
rm -rf -- "${PEER_REPO:?}"
mkdir -p -- "$PEER_REPO"
git -C "$PEER_REPO" init -q
printf 'VSY-47 is ours; hold KEN-7.\n' > "$TMP_ROOT/peer-note.txt"
(cd "$PEER_REPO" && "$LANE_MAIL" peer send --repo "$CASE_REPO_ROOT" --file "$TMP_ROOT/peer-note.txt")
PEER_NOTE="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || PEER_NOTE=unsent
err="$TMP_ROOT/peer-a"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $PEER_NOTE kind=directive" \
  "a peer overseer's note emits peer-note naming its repository, the message id and its kind" "$err"
assert_contains "$out" "  VSY-47 is ours; hold KEN-7." "the peer note's text follows its event line" "$err"
# The third kind the peer-note entry names. An overseer runs this watch rather
# than blocking in `wait`, so a peer's answer reaches it here or nowhere.
printf 'Ours after all.\n' > "$TMP_ROOT/peer-answer.txt"
(cd "$PEER_REPO" && "$LANE_MAIL" peer send --repo "$CASE_REPO_ROOT" --re some-ask --file "$TMP_ROOT/peer-answer.txt")
PEER_ANSWER="$(jq -rs 'map(select(.kind == "answer")) | .[0] | .id' "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || PEER_ANSWER=unsent
err="$TMP_ROOT/peer-b"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $PEER_ANSWER kind=answer re=some-ask" \
  "a peer's answer emits peer-note naming the ask of this overseer's it replies to" "$err"

# Only an ask is owed a reply, and a directive answered would name an id in no
# outbox, so the two must not arrive in one shape.
new_case mail_peer_ask
mail_reset overseer
printf 'Do you own VSY-47?\n' > "$TMP_ROOT/peer-ask.txt"
(cd "$PEER_REPO" && "$LANE_MAIL" peer ask --repo "$CASE_REPO_ROOT" --file "$TMP_ROOT/peer-ask.txt" >/dev/null)
PEER_INBOUND="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || PEER_INBOUND=unsent
err="$TMP_ROOT/peer-ask"
out="$(run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $PEER_INBOUND kind=ask" \
  "a peer's ask is told from a note by the kind on its line" "$err"

# Each lane-local read surface can fail on the first item without starving the
# next item. The second pass keeps the same failure in place: the later lane's
# successful mail and handoff rows must stop both of its events replaying.
continuation_pair() { # mail|state-fetch|handoff-output [WATCH_BIN]
  local kind="$1" bin="${2:-}" first=KEN-62 later=KEN-63 remote wrapper sealed item
  local -a CONTINUE_ENV CONTINUE_ARGS
  rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
  rm -f -- "$CASE_REPO_ROOT/tmp/workflow-state-$first.json" \
    "$CASE_REPO_ROOT/tmp/workflow-state-$later.json"
  mkdir -p "$CASE_REPO_ROOT/tmp/lane-mail/$first" "$CASE_REPO_ROOT/tmp/lane-mail/$later"
  printf '{"id":"first-%s","kind":"notice","at":"t","text":"First lane."}\n' "$kind" \
    > "$CASE_REPO_ROOT/tmp/lane-mail/$first/to-overseer.jsonl"
  printf '{"id":"later-%s","kind":"notice","at":"t","text":"Later lane."}\n' "$kind" \
    > "$CASE_REPO_ROOT/tmp/lane-mail/$later/to-overseer.jsonl"
  CONTINUE_ENV=()
  CONTINUE_ARGS=(--max-loops 1 --item "$first" --item "$later")
  CONTINUE_CAUSE=""
  CONTINUE_HANDOFF=""
  sealed=""
  case "$kind" in
    mail)
      sealed="$CASE_REPO_ROOT/tmp/lane-mail/$first/to-overseer.jsonl"
      chmod 000 "$sealed"
      CONTINUE_CAUSE="oversee-watch: mail-read-failed item=$first exit=2"
      ;;
    state-fetch)
      remote="$STUB_DIR/continuation-remote"
      rm -rf -- "${remote:?}"
      for item in "$first" "$later"; do
        mkdir -p "$remote/srv/lane/$item/tmp/lane-mail/$item" "$remote/srv/clone/tmp/lane-mail/$item"
        printf 'gitdir: /srv/clone/.git/worktrees/%s\n' "$item" > "$remote/srv/lane/$item/.git"
        cp "$CASE_REPO_ROOT/tmp/lane-mail/$item/to-overseer.jsonl" \
          "$remote/srv/lane/$item/tmp/lane-mail/$item/to-overseer.jsonl"
        printf '{"handoff":{"written_at":"t"}}\n' \
          > "$remote/srv/clone/tmp/workflow-state-$item.json"
      done
      rm -rf -- "${CASE_REPO_ROOT:?}/tmp/lane-mail"
      CONTINUE_ENV=(ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log"
        LANE_HOST_STUB_DIR="$remote" LANE_HOST_STUB_CAT_STATUS=1
        LANE_HOST_STUB_CAT_ITEM="$first"
        LANE_HOST_STUB_CAT_PATH="/srv/clone/tmp/workflow-state-$first.json")
      CONTINUE_ARGS+=(--hosted "$first=/srv/lane/$first" --hosted "$later=/srv/lane/$later")
      CONTINUE_CAUSE="oversee-watch: handoff-read-failed item=$first path=/srv/clone/tmp"
      CONTINUE_HANDOFF="EVENT handoff $later"
      ;;
    handoff-output)
      printf '{"handoff":{"written_at":"t"}}\n' \
        > "$CASE_REPO_ROOT/tmp/workflow-state-$first.json"
      printf '{"handoff":{"written_at":"t"}}\n' \
        > "$CASE_REPO_ROOT/tmp/workflow-state-$later.json"
      wrapper="$STUB_DIR/workflow-state-invalid.sh"
      cat > "$wrapper" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if [[ " $* " == *" handoff-standing KEN-62 "* ]]; then
  printf 'workflow-state: handoff-standing=invalid\n'
  exit 0
fi
exec "$WORKFLOW_STATE_STUB" "$@"
EOF
      chmod +x "$wrapper"
      CONTINUE_ENV=(OVERSEE_WATCH_WORKFLOW_STATE="$wrapper"
        WORKFLOW_STATE_STUB="$TMP_ROOT/bin/workflow-state-stub.sh")
      CONTINUE_CAUSE="oversee-watch: handoff-read-failed item=$first path=$CASE_REPO_ROOT/tmp"
      CONTINUE_HANDOFF="EVENT handoff $later"
      ;;
    *) echo "continuation_pair: unknown kind: $kind" >&2; exit 2 ;;
  esac
  CONTINUE_RC=0
  CONTINUE_OUT="$(WATCH_BIN="$bin" run_watch ${CONTINUE_ENV[@]+"${CONTINUE_ENV[@]}"} -- \
    "${CONTINUE_ARGS[@]}" 2>"$STUB_DIR/continue-a.err")" || CONTINUE_RC=$?
  CONTINUE_AGAIN_RC=0
  CONTINUE_AGAIN="$(WATCH_BIN="$bin" run_watch ${CONTINUE_ENV[@]+"${CONTINUE_ENV[@]}"} -- \
    "${CONTINUE_ARGS[@]}" 2>"$STUB_DIR/continue-b.err")" || CONTINUE_AGAIN_RC=$?
  [[ -z "$sealed" ]] || chmod 644 "$sealed"
}

for kind in mail state-fetch handoff-output; do
  new_case "mail_continue_$kind"
  continuation_pair "$kind"
  assert_eq "$CONTINUE_RC" "2" "$kind failure exits 2 after the completed pass"
  assert_eq "$(grep -cxF -- "$CONTINUE_CAUSE" "$STUB_DIR/continue-a.err" || :)" "1" \
    "$kind failure prints its keyed cause once" "$STUB_DIR/continue-a.err"
  assert_eq "$(grep -cx "EVENT lane-notice KEN-63 later-$kind" <<<"$CONTINUE_OUT" || :)" "1" \
    "$kind failure does not hide the later lane's mail" "$STUB_DIR/continue-a.err"
  [[ -z "$CONTINUE_HANDOFF" ]] || assert_eq \
    "$(grep -cxF -- "$CONTINUE_HANDOFF" <<<"$CONTINUE_OUT" || :)" "1" \
    "$kind failure does not hide the later lane's handoff" "$STUB_DIR/continue-a.err"
  assert_eq "$CONTINUE_AGAIN_RC" "2" "$kind failure keeps the next completed pass failed"
  assert_eq "$(grep -cxF -- "EVENT lane-notice KEN-63 later-$kind" <<<"$CONTINUE_AGAIN" || :)" "0" \
    "$kind failure preserves the later lane's successful cursors" "$STUB_DIR/continue-b.err"
  [[ -z "$CONTINUE_HANDOFF" ]] || assert_eq \
    "$(grep -cxF -- "$CONTINUE_HANDOFF" <<<"$CONTINUE_AGAIN" || :)" "0" \
    "$kind failure preserves the later lane's successful handoff row" "$STUB_DIR/continue-b.err"
done

# One stopped hosted lane is a failed read, not the end of the pass. The later
# lane and both kinds of overseer note each advance their own cursor. The
# stopped row advances only when the provider reports another state.
stopped_fleet() { # [WATCH_BIN]
  local bin="${1:-}" remote_disk="$STUB_DIR/stopped-remote" n
  STOPPED_REMOTE="$remote_disk"
  mail_reset overseer
  rm -rf -- "${remote_disk:?}"
  for n in 60 61; do
    mkdir -p "$remote_disk/srv/lane/KEN-$n/tmp/lane-mail/KEN-$n"
    printf 'gitdir: /srv/clone/.git/worktrees/KEN-%s\n' "$n" \
      > "$remote_disk/srv/lane/KEN-$n/.git"
  done
  printf '{"id":"later-1","kind":"notice","at":"t","text":"Later lane."}\n' \
    > "$remote_disk/srv/lane/KEN-61/tmp/lane-mail/KEN-61/to-overseer.jsonl"
  printf 'Owner note.\n' > "$TMP_ROOT/stopped-owner.txt"
  (cd "$CASE_REPO_ROOT" && "$LANE_MAIL" send --item overseer --directive \
    --file "$TMP_ROOT/stopped-owner.txt" >/dev/null)
  STOPPED_OWNER="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl")"
  printf 'Peer note.\n' > "$TMP_ROOT/stopped-peer.txt"
  (cd "$PEER_REPO" && "$LANE_MAIL" peer send --repo "$CASE_REPO_ROOT" \
    --file "$TMP_ROOT/stopped-peer.txt")
  STOPPED_PEER="$(jq -rs '.[1].id' "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl")"
  STOPPED_RC=0
  STOPPED_OUT="$(WATCH_BIN="$bin" run_watch ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$remote_disk" \
    LANE_HOST_STUB_CAT_STATUS=1 LANE_HOST_STUB_CAT_ITEM=KEN-60 \
    LANE_HOST_STUB_CAT_STATE=stopped -- --max-loops 1 \
    --item KEN-60 --hosted KEN-60=/srv/lane/KEN-60 \
    --item KEN-61 --hosted KEN-61=/srv/lane/KEN-61 2>"$TMP_ROOT/stopped-a")" \
    || STOPPED_RC=$?
  STOPPED_AGAIN_RC=0
  STOPPED_AGAIN="$(WATCH_BIN="$bin" run_watch ORCH_LANE_HOST="$FIXTURE_HOST" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_DIR="$remote_disk" \
    LANE_HOST_STUB_CAT_STATUS=1 LANE_HOST_STUB_CAT_ITEM=KEN-60 \
    LANE_HOST_STUB_CAT_STATE=stopped -- --max-loops 1 \
    --item KEN-60 --hosted KEN-60=/srv/lane/KEN-60 \
    --item KEN-61 --hosted KEN-61=/srv/lane/KEN-61 2>"$TMP_ROOT/stopped-b")" \
    || STOPPED_AGAIN_RC=$?
}

new_case mail_stopped_lane_continues
stopped_fleet
assert_eq "$STOPPED_RC" "2" "a stopped hosted lane makes the completed pass fail"
assert_eq "$(grep -c '^oversee-watch: handoff-read-failed item=KEN-60 ' "$TMP_ROOT/stopped-a" || :)" "1" \
  "the stopped lane's keyed failure is emitted once" "$TMP_ROOT/stopped-a"
assert_eq "$(grep -c '^lane-stopped item=KEN-60 state=stopped verb=cat$' "$TMP_ROOT/stopped-a" || :)" "1" \
  "the provider's stopped state follows the keyed failure once" "$TMP_ROOT/stopped-a"
assert_eq "$(grep -c '^EVENT lane-notice KEN-61 later-1$' <<<"$STOPPED_OUT" || :)" "1" \
  "the pass reports the later lane's notice" "$TMP_ROOT/stopped-a"
assert_eq "$(grep -c "^EVENT owner-note $STOPPED_OWNER$" <<<"$STOPPED_OUT" || :)" "1" \
  "the pass reports the owner's note" "$TMP_ROOT/stopped-a"
assert_eq "$(grep -c "^EVENT peer-note peer-repo $STOPPED_PEER kind=directive$" <<<"$STOPPED_OUT" || :)" "1" \
  "the pass reports the peer note" "$TMP_ROOT/stopped-a"
assert_eq "$STOPPED_AGAIN_RC" "2" "the standing stopped lane keeps the next completed pass failed"
assert_eq "$(grep -c 'lane-stopped item=KEN-60 state=stopped' "$TMP_ROOT/stopped-b" || :)" "0" \
  "the same stopped state is not reported on every pass" "$TMP_ROOT/stopped-b"
assert_eq "$(grep -c '^EVENT ' <<<"$STOPPED_AGAIN" || :)" "0" \
  "the successful lane and overseer cursors suppress their events on the next pass" "$TMP_ROOT/stopped-b"
run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
  LANE_HOST_STUB_DIR="$STOPPED_REMOTE" -- --max-loops 1 \
  --item KEN-60 --hosted KEN-60=/srv/lane/KEN-60 \
  --item KEN-61 --hosted KEN-61=/srv/lane/KEN-61 >/dev/null 2>"$TMP_ROOT/stopped-recovered"
rc=0
out="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
  LANE_HOST_STUB_DIR="$STOPPED_REMOTE" LANE_HOST_STUB_CAT_STATUS=1 \
  LANE_HOST_STUB_CAT_ITEM=KEN-60 LANE_HOST_STUB_CAT_STATE=stopped -- --max-loops 1 \
  --item KEN-60 --hosted KEN-60=/srv/lane/KEN-60 \
  --item KEN-61 --hosted KEN-61=/srv/lane/KEN-61 2>"$TMP_ROOT/stopped-c")" || rc=$?
assert_eq "$rc" "2" "the lane's next stopped state makes the completed pass fail again"
assert_eq "$(grep -c '^lane-stopped item=KEN-60 state=stopped verb=cat$' "$TMP_ROOT/stopped-c" || :)" "1" \
  "a successful read clears the stopped sighting, so the next stop is reported" "$TMP_ROOT/stopped-c"

STOP_EARLY="$MUTANT_DIR/orch/scripts/oversee-watch-stop-early"
python3 -c 'import sys
src, out = sys.argv[1:]
s = open(src).read()
old = "  PASS_FAILED=1\n  PASS_FAILED_ITEMS+="
new = "  exit 2\n  PASS_FAILED_ITEMS+="
assert s.count(old) == 1, "deferred-exit mutant pattern"
open(out, "w").write(s.replace(old, new))' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$STOP_EARLY"
chmod +x "$STOP_EARLY"
assert_eq "$(cmp -s "$STOP_EARLY" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the stop-early mutant really restores a lane failure's immediate exit"
new_case mail_stopped_lane_control
stopped_fleet "$STOP_EARLY"
assert_eq "$(grep -c '^EVENT ' <<<"$STOPPED_OUT" || :)" "0" \
  "control: ending at the failed lane drops the later lane and both overseer notes" "$TMP_ROOT/stopped-a"

NO_SUCCESS_CURSOR="$MUTANT_DIR/orch/scripts/oversee-watch-no-success-cursor"
sed 's@state="$(lane_row_set lane-mail "$state" "$cursor" "$count $first")"@:@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$NO_SUCCESS_CURSOR"
chmod +x "$NO_SUCCESS_CURSOR"
assert_eq "$(cmp -s "$NO_SUCCESS_CURSOR" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the cursor mutant really drops the successful lane's cursor"
new_case mail_stopped_lane_cursor_control
stopped_fleet "$NO_SUCCESS_CURSOR"
assert_eq "$(grep -c '^EVENT lane-notice KEN-61 later-1$' <<<"$STOPPED_AGAIN" || :)" "1" \
  "control: without its cursor the successful later lane is reported again" "$TMP_ROOT/stopped-b"

KINDLESS="$MUTANT_DIR/orch/scripts/oversee-watch-kindless"
sed 's@\$id kind=\$kind\${re:+ re=\$re}@$id${re:+ re=$re}@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$KINDLESS"
chmod +x "$KINDLESS"
assert_eq "$(cmp -s "$KINDLESS" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the kindless mutant really drops the kind"
new_case mail_peer_kindless
mail_reset overseer
(cd "$PEER_REPO" && "$LANE_MAIL" peer ask --repo "$CASE_REPO_ROOT" --file "$TMP_ROOT/peer-ask.txt" >/dev/null)
KINDLESS_ASK="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || KINDLESS_ASK=unsent
err="$TMP_ROOT/kindless"
out="$(WATCH_BIN="$KINDLESS" run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $KINDLESS_ASK" \
  "control: without the kind an ask arrives in the same shape as a note" "$err"

# The thread pointer is the answer's alone. A lane's own records reach the
# watch through drain, and a `re=` on one would read as a reply to an ask the
# overseer never sent.
new_case mail_lane_no_thread
mail_reset KEN-52
say KEN-52 notice 'Rebased onto main.' >/dev/null
err="$TMP_ROOT/lane-thread"
out="$(run_watch -- --max-loops 1 --item KEN-52 2>"$err")"
assert_eq "$(grep -c 're=' <<<"$(head -1 <<<"$out")")" "0" \
  "a lane's event line carries no thread pointer" "$err"

THREADLESS="$MUTANT_DIR/orch/scripts/oversee-watch-threadless"
sed 's@ kind=\$kind\${re:+ re=\$re}@ kind=$kind@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$THREADLESS"
chmod +x "$THREADLESS"
assert_eq "$(cmp -s "$THREADLESS" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the threadless mutant really drops the thread pointer"
new_case mail_peer_threadless
mail_reset overseer
(cd "$PEER_REPO" && "$LANE_MAIL" peer send --repo "$CASE_REPO_ROOT" --re some-ask --file "$TMP_ROOT/peer-answer.txt")
THREADLESS_ID="$(jq -r .id "$CASE_REPO_ROOT/tmp/lane-mail/overseer/to-lane.jsonl" 2>/dev/null)" || THREADLESS_ID=unsent
err="$TMP_ROOT/threadless"
out="$(WATCH_BIN="$THREADLESS" run_watch -- --max-loops 1 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT peer-note peer-repo $THREADLESS_ID kind=answer" \
  "control: without the pointer two replies from one peer are told apart by their wording alone" "$err"

THREADED_LANE="$MUTANT_DIR/orch/scripts/oversee-watch-threaded-lane"
sed 's@echo "EVENT lane-notice \$item \$id"@echo "EVENT lane-notice $item $id${re:+ re=$re}"@' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" > "$THREADED_LANE"
chmod +x "$THREADED_LANE"
assert_eq "$(cmp -s "$THREADED_LANE" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the threaded-lane mutant really puts the pointer on a lane line"
new_case mail_lane_threaded
mail_reset KEN-53
printf '{"id":"lane-1","kind":"notice","at":"t","from":"KEN-53","re":"never-asked","text":"Rebased."}\n' \
  > "$CASE_REPO_ROOT/tmp/lane-mail/KEN-53/to-overseer.jsonl"
err="$TMP_ROOT/lane-threaded"
out="$(WATCH_BIN="$THREADED_LANE" run_watch -- --max-loops 1 --item KEN-53 2>"$err")"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-notice KEN-53 lane-1 re=never-asked" \
  "control: a pointer on a lane line reads as a reply to an ask the overseer never sent" "$err"

# Hosted lanes over the provider stub, three runs each. Each lane is the pair
# open-terminal launches for a GitHub item: item issue-N in window gh-N. The
# clone is learned from the worktree's .git file and the handoff read from the
# clone's state. KEEP gone removes the worktrees after the first run, lands a
# closing notice in each clone's mailbox and a new handoff record in each
# clone's state before the merged item's exited window closes its sandbox;
# keep leaves them standing; absent never has one.
hosted_runs() { # CASE LANES KEEP [ENV...]
  local lanes="$2" keep="$3" n run args=()
  new_case "$1"
  shift 3
  HOSTED_DISK="$STUB_DIR/remote"
  HOSTED_OUT=()
  HOSTED_RC=()
  for n in $lanes; do
    mkdir -p "$HOSTED_DISK/srv/clone/tmp/lane-mail/issue-$n"
    if [[ "$keep" != absent ]]; then
      mkdir -p "$HOSTED_DISK/srv/lane/issue-$n"
      printf 'gitdir: /srv/clone/.git/worktrees/issue-%s\n' "$n" > "$HOSTED_DISK/srv/lane/issue-$n/.git"
    fi
    printf '{"handoff":{"written_at":"t"}}\n' > "$HOSTED_DISK/srv/clone/tmp/workflow-state-issue-$n.json"
    printf 'bash\n' > "$STUB_DIR/cmd-gh-$n.txt"
    args+=(--item "issue-$n" --hosted "issue-$n=/srv/lane/issue-$n" "gh-$n")
  done
  jq -nc '[$ARGS.positional[] | {number: tonumber, headRefName: "issue-\(.)", mergedAt: "2026-09-14T10:00:00Z"}]' \
    --args $lanes > "$STUB_DIR/merged.json"
  for run in 1 2 3; do
    HOSTED_RC[run]=0
    HOSTED_OUT[run]="$(run_watch ORCH_LANE_HOST="$FIXTURE_HOST" LANE_HOST_STUB_LOG="$STUB_DIR/host.log" \
      LANE_HOST_STUB_DIR="$HOSTED_DISK" ${1+"$@"} -- --max-loops 1 "${args[@]}" 2>"$STUB_DIR/run$run.err")" \
      || HOSTED_RC[run]=$?
    # A jammed state directory is the stub's doing; the next run starts writable.
    [[ ! -d "$STATE_DIR" ]] || chmod u+w "$STATE_DIR"
    [[ "$run" -eq 1 && "$keep" == gone ]] || continue
    for n in $lanes; do
      rm -rf -- "${HOSTED_DISK:?}/srv/lane/issue-$n"
      printf '{"id":"closing-%s","kind":"notice","at":"t","text":"Merged."}\n' "$n" \
        > "$HOSTED_DISK/srv/clone/tmp/lane-mail/issue-$n/to-overseer.jsonl"
      printf '{"handoff":{"written_at":"t2"}}\n' > "$HOSTED_DISK/srv/clone/tmp/workflow-state-issue-$n.json"
    done
  done
}
hosted_facts() { # LANES
  local n later out=""
  later="$(printf '%s\n%s\n' "${HOSTED_OUT[2]}" "${HOSTED_OUT[3]}")"
  for n in $1; do
    out+="issue-$n: handoff=$(grep -cx "EVENT handoff issue-$n" <<<"${HOSTED_OUT[1]}" || :)"
    out+=" notice=$(grep -cx "EVENT lane-notice issue-$n closing-$n" <<<"${HOSTED_OUT[2]}" || :)"
    out+=" closed=$(grep -A1 -x "EVENT lane-closed issue-$n" <<<"$later" | grep -c '^kept=' || :)"
    out+=" refused=$(grep -A1 -x "EVENT lane-close-refused issue-$n" <<<"$later" | grep -cx 'path=/srv/clone' || :)"
    out+=" closes=$(grep -c "^close --item issue-$n \$" "$STUB_DIR/host.log" || :)"
    out+=" none=$(grep -A1 -x "EVENT lane-closed issue-$n" <<<"$later" | grep -cx 'kept=none' || :); "
  done
  printf '%s' "${out%; }"
}
# One run's exit status, how many times its stderr carries KEYED_LINE, and
# with EVENT_LINE how many times its stdout carries that.
hosted_exit() { # RUN KEYED_LINE [EVENT_LINE]
  printf 'rc=%s note=%s' "${HOSTED_RC[$1]}" "$(grep -cxF -- "$2" "$STUB_DIR/run$1.err" || :)"
  [[ -z "${3:-}" ]] || printf ' out=%s' "$(grep -cxF -- "$3" <<<"${HOSTED_OUT[$1]}" || :)"
}
hosted_mutant() { # NAME OLD NEW
  python3 -c 'import sys
src, out, old, new = sys.argv[1:]
s = open(src).read()
assert s.count(old) == 1, "hosted mutant pattern: " + old
open(out, "w").write(s.replace(old, new))' "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$MUTANT_DIR/orch/scripts/oversee-watch-$1" "$2" "$3"
  chmod +x "$MUTANT_DIR/orch/scripts/oversee-watch-$1"
}
hosted_mutant local-state '  [[ -n "$HOSTED_ROOT" ]] || return 0' '  return 0'
hosted_mutant unclosed '        if ! close_hosted_lane "$LANE_ITEM"; then' '        if false; then'
hosted_mutant worktree-mail '        root="$HOSTED_CLONE"; cursor="$item@clone"' '        :'
hosted_mutant retried '      echo "EVENT lane-close-refused $1"' '      return 1'
hosted_mutant standing '         && grep -qxF -- "$LANE_ITEM" <<<"$HOSTED_GONE_ITEMS"; then' '; then'
hosted_mutant fail-fast '      ow_message lane-close-failed "item=$1" "exit=$rc" >&2' '      exit 2'
hosted_mutant window '  LANE_ITEM="issue-${LANE_ITEM#gh-}"' '  :'
hosted_mutant nothing-kept '      grep -q '"'"'^kept='"'"' <<<"$out" || echo "kept=none" ;;' '      ;;'
hosted_mutant exit-zero '  [[ "$close_failed" -eq 0 ]] || exit 2' '  :'
hosted_mutant unkeyed '      ow_message lane-close-failed "item=$1" "exit=$rc" >&2' '      :'
hosted_mutant commit-after '        lane_row_commit "$asking_state"' '        :'
hosted_mutant misread-cat '  [[ "$rc" -eq 2 ]] || return 2' '  :'
hosted_mutant misread-touch '  "$SCRIPT_DIR/lane-host" touch --item "$1" >/dev/null 2>>"$WORK_DIR/host.err" || return 2' '  :'
hosted_mutant early-exit $'  check_handoff\n  # check_handoff commits' $'  [[ "$close_failed" -eq 0 ]] || exit 2\n  check_handoff\n  # check_handoff commits'
hosted_mutant path-unparsed '        path="${line#*close-refused path=}"' '        :'
ONE='issue-2: handoff=1 notice=1'
QUIET='issue-2: handoff=0 notice=0 closed=0 refused=0 closes=0 none=0'
FAIL2='LANE_HOST_STUB_CLOSE_STATUS=1 LANE_HOST_STUB_CLOSE_ITEM=issue-2'
CLOSE_NOTE='oversee-watch: lane-close-failed item=issue-2 exit=1'
READ_NOTE='oversee-watch: handoff-read-failed item=issue-2 path=/srv/lane/issue-2/.git'
RETRIED="issue-1: handoff=1 notice=1 closed=1 refused=0 closes=1 none=0; $ONE closed=0 refused=0 closes=2 none=0"
HOSTED_SEQ=0
# label|mutant|lanes|keep|env|facts[|exit|run|keyed line[|event line]]
for row in \
  "a hosted GitHub lane reads its handoff and closing notice from the clone and closes once||2|gone||$ONE closed=1 refused=0 closes=1 none=0" \
  "a refused close names the refused checkout's path and is never closed again||2|gone|LANE_HOST_STUB_CLOSE_STATUS=3|$ONE closed=0 refused=1 closes=1 none=0" \
  "a lane exiting while its worktree stands is not closed||2|keep||issue-2: handoff=1 notice=0 closed=0 refused=0 closes=0 none=0" \
  "a failed close is retried alone, the lane closed beside it not closed again||1 2|gone|$FAIL2|$RETRIED|rc=2 note=1|2|$CLOSE_NOTE" \
  "a close that archived nothing is reported as kept=none||2|gone|LANE_HOST_STUB_CLOSE_EMPTY=1|$ONE closed=1 refused=0 closes=1 none=1" \
  "a close whose run then fails to commit is not closed again||2|gone|LANE_HOST_STUB_CLOSE_JAM=1|$ONE closed=1 refused=0 closes=1 none=0" \
  "a failing close still lets its pass report another lane's handoff before exiting 2||1 2|gone|$FAIL2|$RETRIED|rc=2 note=1 out=1|2|$CLOSE_NOTE|EVENT handoff issue-1" \
  "a hosted read the provider fails is handoff-read-failed, never a missing file||2|gone|LANE_HOST_STUB_CAT_STATUS=1|$QUIET|rc=2 note=1|1|$READ_NOTE" \
  "a missing file on a host that does not answer is handoff-read-failed||2|absent|LANE_HOST_STUB_TOUCH_STATUS=1|$QUIET|rc=2 note=1|1|$READ_NOTE" \
  "control: read from this checkout's state, the hosted handoff is never reported|local-state|2|gone||issue-2: handoff=0 notice=1 closed=1 refused=0 closes=1 none=0" \
  "control: without the close call the sandbox stays|unclosed|2|gone||$ONE closed=0 refused=0 closes=0 none=0" \
  "control: reading the removed worktree's mailbox loses the closing notice|worktree-mail|2|gone||issue-2: handoff=1 notice=0 closed=1 refused=0 closes=1 none=0" \
  "control: a refusal read as a failure is closed again on the next run|retried|2|gone|LANE_HOST_STUB_CLOSE_STATUS=3|$ONE closed=0 refused=0 closes=2 none=0" \
  "control: without the worktree check a lane stopped inside merge-pr is closed|standing|2|keep||issue-2: handoff=1 notice=0 closed=1 refused=0 closes=1 none=0" \
  "control: a failed close that ends the pass before its row is reset is never retried|fail-fast|1 2|gone|$FAIL2|issue-1: handoff=1 notice=1 closed=1 refused=0 closes=1 none=0; $ONE closed=0 refused=0 closes=1 none=0" \
  "control: a gh-N window not mapped to issue-N never closes its lane|window|2|gone||$ONE closed=0 refused=0 closes=0 none=0" \
  "control: an empty close with no line of the watch's own leaves nothing to record|nothing-kept|2|gone|LANE_HOST_STUB_CLOSE_EMPTY=1|$ONE closed=0 refused=0 closes=1 none=0" \
  "control: a failed close whose pass exits 0 hides the failure from the caller|exit-zero|1 2|gone|$FAIL2|$RETRIED|rc=0 note=1|2|$CLOSE_NOTE" \
  "control: a failed close with no keyed line leaves the caller no item to act on|unkeyed|1 2|gone|$FAIL2|$RETRIED|rc=2 note=0|2|$CLOSE_NOTE" \
  "control: a row committed after the close is closed again when that commit fails|commit-after|2|gone|LANE_HOST_STUB_CLOSE_JAM=1|$ONE closed=2 refused=0 closes=2 none=0" \
  "control: a failed close that ends the pass early drops another lane's handoff|early-exit|1 2|gone|$FAIL2|$RETRIED|rc=2 note=1 out=0|2|$CLOSE_NOTE|EVENT handoff issue-1" \
  "control: a failed read taken as a missing file loses the path the refusal names|misread-cat|2|gone|LANE_HOST_STUB_CAT_STATUS=1|$QUIET|rc=2 note=0|1|$READ_NOTE" \
  "control: an unanswered probe taken as a missing file loses the path the refusal names|misread-touch|2|absent|LANE_HOST_STUB_TOUCH_STATUS=1|$QUIET|rc=2 note=0|1|$READ_NOTE" \
  "control: a refusal whose path is not read names no checkout|path-unparsed|2|gone|LANE_HOST_STUB_CLOSE_STATUS=3|$ONE closed=0 refused=0 closes=1 none=0"; do
  IFS='|' read -r label bin lanes keep env expect exit run needle event <<<"$row"
  read -ra envs <<<"$env"
  WATCH_BIN="${bin:+$MUTANT_DIR/orch/scripts/oversee-watch-$bin}" \
    hosted_runs "hosted_$((HOSTED_SEQ += 1))" "$lanes" "$keep" ${envs[@]+"${envs[@]}"}
  assert_eq "$(hosted_facts "$lanes")" "$expect" "$label" "$STUB_DIR/run${run:-2}.err"
  [[ -z "$exit" ]] || assert_eq "$(hosted_exit "$run" "$needle" "$event")" "$exit" "$label: exit status and keyed line" "$STUB_DIR/run$run.err"
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
