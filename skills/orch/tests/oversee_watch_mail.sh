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
  "$LANE_MAIL" send --item "$1" --root "$CASE_REPO_ROOT" --re "$2" --file "$TMP_ROOT/ans.txt"
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
sed 's@^    \[\[ "\$hosted_item" -eq 1 \]\] || die hosted-unknown-item .*$@    :@' \
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

LATE="$MUTANT_DIR/orch/scripts/oversee-watch-late"
python3 -c 'import sys
p, out = sys.argv[1], sys.argv[2]
s = open(p).read()
old = "    lane_row_commit \"$state\"\n  done\n}"
assert old in s, "late-commit mutant"
open(out, "w").write(s.replace(old, "  done\n  lane_row_commit \"$state\"\n}", 1))' \
  "$REPO_ROOT/skills/orch/scripts/oversee-watch" "$LATE"
chmod +x "$LATE"
assert_eq "$(cmp -s "$LATE" "$REPO_ROOT/skills/orch/scripts/oversee-watch" && echo same || echo differs)" \
  "differs" "control: the late-commit mutant really moves the commit below the loop"
new_case mail_commit_mutant
blocked_pair KEN-32 KEN-33 "$LATE"
assert_contains "$BLOCKED_AGAIN" "EVENT lane-notice KEN-32 " \
  "control: with the commit below the loop the earlier notice is reported again" "$TMP_ROOT/blocked-b"

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

# Hosted lanes over the provider stub, three runs each. Each lane is the pair
# open-terminal launches for a GitHub item: item issue-N in window gh-N. The
# clone is learned from the worktree's .git file and the handoff read from the
# clone's state. Unless the row keeps them, the worktrees are then removed and
# a closing notice lands in each clone's mailbox before the merged item's
# exited window closes its sandbox.
hosted_runs() { # CASE LANES KEEP [ENV...]
  local lanes="$2" keep="$3" n run args=()
  new_case "$1"
  shift 3
  HOSTED_DISK="$STUB_DIR/remote"
  HOSTED_OUT=()
  HOSTED_RC=()
  for n in $lanes; do
    mkdir -p "$HOSTED_DISK/srv/lane/issue-$n" "$HOSTED_DISK/srv/clone/tmp/lane-mail/issue-$n"
    printf 'gitdir: /srv/clone/.git/worktrees/issue-%s\n' "$n" > "$HOSTED_DISK/srv/lane/issue-$n/.git"
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
    [[ "$run" -eq 1 && "$keep" != keep ]] || continue
    for n in $lanes; do
      rm -rf -- "${HOSTED_DISK:?}/srv/lane/issue-$n"
      printf '{"id":"closing-%s","kind":"notice","at":"t","text":"Merged."}\n' "$n" \
        > "$HOSTED_DISK/srv/clone/tmp/lane-mail/issue-$n/to-overseer.jsonl"
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
    out+=" refused=$(grep -A1 -x "EVENT lane-close-refused issue-$n" <<<"$later" | grep -c 'dirty=' || :)"
    out+=" closes=$(grep -c "^close --item issue-$n \$" "$STUB_DIR/host.log" || :)"
    out+=" none=$(grep -A1 -x "EVENT lane-closed issue-$n" <<<"$later" | grep -cx 'kept=none' || :); "
  done
  printf '%s' "${out%; }"
}
# The second run's exit status and its keyed close-failure lines: the run whose
# close of issue-2 a failed-close row makes fail first.
hosted_exit() {
  printf 'rc=%s note=%s' "${HOSTED_RC[2]}" \
    "$(grep -cx 'oversee-watch: lane-close-failed item=issue-2 exit=1' "$STUB_DIR/run2.err" || :)"
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
hosted_mutant retried '    3) echo "EVENT lane-close-refused $1" ;;' '    :) ;;'
hosted_mutant standing '         && grep -qxF -- "$LANE_ITEM" <<<"$HOSTED_GONE_ITEMS"; then' '; then'
hosted_mutant fail-fast '      ow_message lane-close-failed "item=$1" "exit=$rc" >&2' '      exit 2'
hosted_mutant window '  LANE_ITEM="issue-${LANE_ITEM#gh-}"' '  :'
hosted_mutant nothing-kept '  [[ "$rc" -ne 0 ]] || grep -q '"'"'^kept='"'"' <<<"$out" || echo "kept=none"' '  :'
hosted_mutant exit-zero '  [[ "$close_failed" -eq 0 ]] || exit 2' '  :'
hosted_mutant unkeyed '      ow_message lane-close-failed "item=$1" "exit=$rc" >&2' '      :'
ONE='issue-2: handoff=1 notice=1'
FAIL2='LANE_HOST_STUB_CLOSE_STATUS=1 LANE_HOST_STUB_CLOSE_ITEM=issue-2'
RETRIED="issue-1: handoff=1 notice=1 closed=1 refused=0 closes=1 none=0; $ONE closed=0 refused=0 closes=2 none=0"
HOSTED_SEQ=0
for row in \
  "a hosted GitHub lane reads its handoff and closing notice from the clone and closes once||2|gone||$ONE closed=1 refused=0 closes=1 none=0" \
  "a dirty remote worktree is reported with its detail and never closed again||2|gone|LANE_HOST_STUB_CLOSE_STATUS=3|$ONE closed=0 refused=1 closes=1 none=0" \
  "a lane exiting while its worktree stands is not closed||2|keep||issue-2: handoff=1 notice=0 closed=0 refused=0 closes=0 none=0" \
  "a failed close is retried alone, the lane closed beside it not closed again||1 2|gone|$FAIL2|$RETRIED|rc=2 note=1" \
  "a close that archived nothing is reported as kept=none||2|gone|LANE_HOST_STUB_CLOSE_EMPTY=1|$ONE closed=1 refused=0 closes=1 none=1" \
  "control: read from this checkout's state, the hosted handoff is never reported|local-state|2|gone||issue-2: handoff=0 notice=1 closed=1 refused=0 closes=1 none=0" \
  "control: without the close call the sandbox stays|unclosed|2|gone||$ONE closed=0 refused=0 closes=0 none=0" \
  "control: reading the removed worktree's mailbox loses the closing notice|worktree-mail|2|gone||issue-2: handoff=1 notice=0 closed=1 refused=0 closes=1 none=0" \
  "control: a refusal read as a failure is closed again on the next run|retried|2|gone|LANE_HOST_STUB_CLOSE_STATUS=3|$ONE closed=0 refused=0 closes=2 none=0" \
  "control: without the worktree check a lane stopped inside merge-pr is closed|standing|2|keep||issue-2: handoff=1 notice=0 closed=1 refused=0 closes=1 none=0" \
  "control: a failed close that ends the pass closes the lane beside it again|fail-fast|1 2|gone|$FAIL2|issue-1: handoff=1 notice=1 closed=2 refused=0 closes=2 none=0; $ONE closed=0 refused=0 closes=2 none=0" \
  "control: a gh-N window not mapped to issue-N never closes its lane|window|2|gone||$ONE closed=0 refused=0 closes=0 none=0" \
  "control: an empty close with no line of the watch's own leaves nothing to record|nothing-kept|2|gone|LANE_HOST_STUB_CLOSE_EMPTY=1|$ONE closed=0 refused=0 closes=1 none=0" \
  "control: a failed close whose pass exits 0 hides the failure from the caller|exit-zero|1 2|gone|$FAIL2|$RETRIED|rc=0 note=1" \
  "control: a failed close with no keyed line leaves the caller no item to act on|unkeyed|1 2|gone|$FAIL2|$RETRIED|rc=2 note=0"; do
  IFS='|' read -r label bin lanes keep env expect exit <<<"$row"
  read -ra envs <<<"$env"
  WATCH_BIN="${bin:+$MUTANT_DIR/orch/scripts/oversee-watch-$bin}" \
    hosted_runs "hosted_$((HOSTED_SEQ += 1))" "$lanes" "$keep" ${envs[@]+"${envs[@]}"}
  assert_eq "$(hosted_facts "$lanes")" "$expect" "$label" "$STUB_DIR/run2.err"
  [[ -z "$exit" ]] || assert_eq "$(hosted_exit)" "$exit" "$label: exit status and keyed line" "$STUB_DIR/run2.err"
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
