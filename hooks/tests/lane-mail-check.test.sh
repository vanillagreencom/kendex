#!/usr/bin/env bash
# lane-mail-check: a Stop hook that blocks a lane's turn end while its overseer
# mailbox holds unread lines, and through the lane-mail-deliver and
# lane-mail-halt hooks beside it hands them over after a tool call and refuses
# one while a halt stands. Every case builds a lane repository under
# TMP_ROOT, writes to its mailbox with the real `lane-mail`, and asserts the
# hook's exit status and the keyed first line of stderr. HOOK_UNDER_TEST
# overrides the script the must-fail controls at the end run against.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/lane-mail-check.sh}"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
# Canonical from the start: the hook resolves its own directory with pwd -P,
# and on a host whose temp root is a symlink — every macOS one, /var pointing
# at /private/var — a path this suite composed would name the link where the
# hook names the target.
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'chmod -R u+rwx -- "${TMP_ROOT:?}" 2>/dev/null || :; rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
# Whether this world can hold two names differing only in case. On a
# case-insensitive filesystem, every macOS default one, the second name is the
# first directory, so the ambiguity the hook refuses cannot be built at all.
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

# The whole assertion: exit status and keyed first line, `-` being silence.
expect() { # RC FIRST LABEL
  assert_eq "RC=$RC first=$(first_line)" "RC=$1 first=$2" "$3"
}

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# A lane: a git repository on a branch named for its item, carrying the layout
# a kendex project install renders, so the hook resolves its reader the way an
# installed one does. CASE_HOOK is the copy a case runs.
LANE=""
CASE_HOOK=""

install_hook() { # SOURCE DEST
  mkdir -p "${2%/*}"
  cp "$1" "$2"
  chmod +x "$2"
  CASE_HOOK="$2"
}

new_lane() { # NAME BRANCH
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE/.agents/skills/orch" "$LANE/.claude/hooks" "$LANE/.claude/skills"
  git -C "$LANE" init -q
  git -C "$LANE" checkout -q -b "$2"
  git -C "$LANE" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  ln -s -f -n "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
  ln -s -f -n ../../.agents/skills/orch "$LANE/.claude/skills/orch"
  install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
  mark_lane "$2"
}

# The marker a launcher writes: the lane's root, named for the item in lower
# case under the common git directory.
mark_lane() { # ITEM
  local common
  common="$(git -C "$LANE" rev-parse --path-format=absolute --git-common-dir)"
  mkdir -p "$common/lane-mail"
  git -C "$LANE" rev-parse --show-toplevel > "$common/lane-mail/$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
}

RC=0
# The judge's argument, empty for the turn-end run the harness makes.
ARM_ARGS=()
run_payload() { # RAW-JSON [ENV=VAL...]
  local payload="$1"
  shift
  RC=0
  : > "$ERR_FILE"
  printf '%s' "$payload" |
    (cd "$LANE" && env "$@" bash "$CASE_HOOK" ${ARM_ARGS[@]+"${ARM_ARGS[@]}"}) >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
}

stop() { # [ENV=VAL...]
  run_payload '{"session_id":"s1","stop_hook_active":false}' "$@"
}

# The repository's own reader: it touches MARKER, so a run of it is visible.
plant_reader() { # MARKER
  rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
  mkdir -p "$LANE/.agents/skills/orch/scripts"
  printf '#!/bin/sh\ntouch %s\n' "$1" > "$LANE/.agents/skills/orch/scripts/lane-mail"
  chmod +x "$LANE/.agents/skills/orch/scripts/lane-mail"
}

send() { # ITEM TEXT [--re MSGID]
  ITEM="$1"
  printf '%s\n' "$2" > "$TMP_ROOT/msg.txt"
  shift 2
  "$LANE_MAIL" send --item "$ITEM" --root "$LANE" "${@:---directive}" --file "$TMP_ROOT/msg.txt"
}

echo "=== lane-mail-check ==="

new_lane plain ken-1
stop
expect 0 - "a repository with no mailbox directory passes silently"
mkdir -p "$LANE/tmp/lane-mail/KEN-2"
stop
expect 0 - "a mailbox naming another item is not this branch's lane and passes silently"
git -C "$LANE" checkout -q --detach
stop
expect 0 - "a detached HEAD names no lane and passes silently"
# GIT_CEILING_DIRECTORIES stops discovery at TMP_ROOT, so this directory reads
# as no repository however the suite's own temp root was placed — a runner
# whose TMPDIR sits inside a checkout would otherwise resolve that checkout.
LANE="$TMP_ROOT/norepo"
CEILING=(GIT_CEILING_DIRECTORIES="$TMP_ROOT")
mkdir -p "$LANE"
stop "${CEILING[@]}"
expect 0 - "a directory git reports no repository for holds no mailbox and passes silently"
mkdir -p "$LANE/tmp/lane-mail/KEN-1"
stop "${CEILING[@]}"
expect 2 "lane-mail-check: git=rev-parse --show-toplevel" \
  "a mailbox git can report no repository for is refused, never passed"

new_lane empty ken-3
mkdir -p "$LANE/tmp/lane-mail/KEN-3"
stop
expect 0 - "a mailbox with no to-lane.jsonl passes silently"
: > "$LANE/tmp/lane-mail/KEN-3/to-lane.jsonl"
stop
expect 0 - "an empty mailbox passes silently"

new_lane unread ken-4
send KEN-4 'Hold the PR until the owner answers.'
stop
expect 2 "lane-mail-check: unread=1" "unread mail refuses with the count on the first line"
assert_eq "$(cause_below)" "present" "the messages stand under the keyed line"
assert_eq "$(grep -c 'Hold the PR until the owner answers.' "$ERR_FILE")" "1" \
  "the refusal carries the message the overseer sent"
assert_eq "$(cat "$TMP_ROOT/stdout")" "" "the hook writes nothing to stdout"
stop
expect 0 - "a second stop passes: the reader advanced the cursor past what it handed over"

send KEN-4 'And rebase first.'
send KEN-4 'Then re-arm auto-merge.'
stop
expect 2 "lane-mail-check: unread=2" "two new messages refuse once, naming both"

# Killed right after its Nth reader call, as a harness kills a hook at its
# budget, the hook has shown the directive or left it unread, never consumed it
# unseen. KILLED is shown, kept (the next stop reports it) or lost.
killed_stop() { # NAME ITEM N [HOOK]
  local calls="$TMP_ROOT/$1.calls"
  new_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  [ -z "${4:-}" ] || install_hook "$4" "$LANE/.claude/hooks/lane-mail-check.sh"
  send "$2" 'Survive the budget.'
  rm -f "$LANE/.claude/skills/orch"
  mkdir -p "$LANE/.claude/skills/orch/scripts"
  printf '#!/usr/bin/env bash\nrc=0\n"%s" "$@" || rc=$?\nn=$(( $(cat "%s" 2>/dev/null || echo 0) + 1 ))\necho "$n" > "%s"\n[ "$n" -ne %s ] || kill -9 "$PPID"\nexit "$rc"\n' \
    "$LANE_MAIL" "$calls" "$calls" "$3" > "$LANE/.claude/skills/orch/scripts/lane-mail"
  chmod +x "$LANE/.claude/skills/orch/scripts/lane-mail"
  KILLED=lost
  stop
  if grep -q '^lane-mail-check: unread=1$' "$ERR_FILE"; then
    KILLED=shown
  else
    stop
    [ "$(first_line)" != 'lane-mail-check: unread=1' ] || KILLED=kept
  fi
}
for row in 1:kept 2:shown; do
  killed_stop "killed${row%%:*}" "KEN-1$((6 + ${row%%:*}))" "${row%%:*}"
  assert_eq "$KILLED" "${row#*:}" "a hook killed after reader call ${row%%:*} loses no directive"
done

# A launch makes a lane: a mailbox a repository carries with no launch marker,
# or with one bound to another root, is no lane.
unlaunched() { # NAME ITEM MARKER-CONTENT [HOOK] — empty content removes the marker
  new_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  [ -z "${4:-}" ] || install_hook "$4" "$LANE/.claude/hooks/lane-mail-check.sh"
  send "$2" 'Pose as a lane.'
  local marker
  marker="$LANE/.git/lane-mail/$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  rm -f "$marker"
  [ -z "$3" ] || printf '%s\n' "$3" > "$marker"
  stop
}
unlaunched unmarked KEN-20 ""
expect 0 - "a mailbox with no launch marker is no lane and passes silently"
unlaunched rebound KEN-21 "$TMP_ROOT/another-root"
expect 0 - "a launch marker bound to another root is no lane and passes silently"

# Anything present at to-lane.jsonl in a launched lane reaches the reader,
# whose component rule refuses it: never passed as a mailbox with no file.
for row in dir:ken-23 link:ken-24; do
  new_lane "unsafe_${row%%:*}" "${row#*:}"
  box="$LANE/tmp/lane-mail/$(printf '%s' "${row#*:}" | tr 'a-z' 'A-Z')"
  mkdir -p "$box"
  case "${row%%:*}" in
    dir) mkdir "$box/to-lane.jsonl" ;;
    link) ln -s "$TMP_ROOT/nowhere" "$box/to-lane.jsonl" ;;
  esac
  stop
  assert_eq "RC=$RC first=$(first_line) cause=$(grep -c "^lane-mail: mailbox-unsafe=$box/to-lane.jsonl\$" "$ERR_FILE")" \
    "RC=2 first=lane-mail-check: inbox=2 cause=1" "a ${row%%:*} at to-lane.jsonl in a launched lane is refused, never passed"
done

# A marker present but not a plain file is refused, never read as no lane.
new_lane marker_dir ken-25
send KEN-25 'Behind a marker that is a directory.'
rm -f "$LANE/.git/lane-mail/ken-25"
mkdir "$LANE/.git/lane-mail/ken-25"
stop
expect 2 "lane-mail-check: marker=$LANE/.git/lane-mail/ken-25" "a marker path that is a directory is refused, never read as no lane"

new_lane answered ken-5
send KEN-5 'Merge it.' --re some-ask
stop
expect 0 - "an answer belongs to the wait that asked for it and never stops a turn"

new_lane named ken-6
mark_lane OTHER-1
send OTHER-1 'Brief-named mailbox.'
stop
expect 0 - "a mailbox the branch does not name is not read without LANE_MAIL_ITEM"
stop LANE_MAIL_ITEM=OTHER-1
expect 2 "lane-mail-check: unread=1" "LANE_MAIL_ITEM selects the lane's mailbox whatever the branch is"
stop LANE_MAIL_ITEM=../escape
expect 2 "lane-mail-check: item=invalid" "an item outside its alphabet is refused rather than resolved to a path"

if [ "${CASE_SENSITIVE:?}" -eq 1 ]; then
  new_lane ambiguous ken-7
  mkdir -p "$LANE/tmp/lane-mail/KEN-7" "$LANE/tmp/lane-mail/ken-7"
  stop
  expect 2 "lane-mail-check: item=ambiguous" "two mailboxes lowercasing to one branch decide nothing and are refused"
else
  printf '  skip  two mailboxes lowercasing to one branch: this filesystem is case-insensitive, so the second name is the first mailbox\n'
fi

new_lane noreader ken-8
send KEN-8 'unreachable'
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
stop
expect 2 "lane-mail-check: reader=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "a mailbox with no reader beside it is refused, never passed"

# The repository supplies a reader and the hook is installed nowhere near it.
# The hook's own install is the only place a reader may come from; otherwise a
# repository hands this hook a command to run at every turn end.
new_lane planted ken-12
send KEN-12 'run me'
MARKER="$TMP_ROOT/planted-ran"
plant_reader "$MARKER"
install_hook "$HOOK" "$TMP_ROOT/elsewhere/hooks/lane-mail-check.sh"
stop
expect 2 "lane-mail-check: reader-outside=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "a reader the open repository supplies is refused where the hook is installed outside it"
assert_eq "$([ -e "$MARKER" ] && echo ran || echo not-run)" "not-run" "the repository's own script never runs"

new_lane unreadable ken-9
send KEN-9 'sealed'
chmod 000 "$LANE/tmp/lane-mail/KEN-9/to-lane.jsonl"
stop
chmod 644 "$LANE/tmp/lane-mail/KEN-9/to-lane.jsonl"
expect 2 "lane-mail-check: inbox=2" "a mailbox that cannot be read is refused with the reader's status"
assert_eq "$(grep -c '^lane-mail: file-unreadable=' "$ERR_FILE")" "1" \
  "the reader's own keyed line is replayed under the hook's"

new_lane payload ken-10
send KEN-10 'x'
run_payload 'not json'
expect 2 "lane-mail-check: payload=invalid-json" "a payload that is not JSON is refused rather than skipped"
run_payload '{"stop_hook_active":true}'
expect 0 - "the turn the harness already continued is not blocked again"


# A global install: the hook under a fake home, the orch skill in that home's
# shared tree, the open repository elsewhere. Claude is two deep, Pi four.
global_home() { # NAME — a fake home with the shared reader in it
  GLOBAL_HOME="$TMP_ROOT/$1"
  mkdir -p "$GLOBAL_HOME/.agents/skills/orch"
  ln -s -f -n "$REPO_ROOT/skills/orch/scripts" "$GLOBAL_HOME/.agents/skills/orch/scripts"
}

for hookdir in .claude/hooks .pi/agent/kendex/hooks; do
  new_lane "global-${hookdir%%/*}" ken-14
  send KEN-14 'Reached the global install.'
  rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
  global_home "home-${hookdir%%/*}"
  install_hook "$HOOK" "$GLOBAL_HOME/$hookdir/lane-mail-check.sh"
  stop "HOME=$GLOBAL_HOME"
  expect 2 "lane-mail-check: unread=1" "a global install under $hookdir reads its own shared skill tree"
done

# A harness root outside the home directory, which CODEX_HOME and
# PI_CODING_AGENT_DIR make: the walk climbs ancestors kendex installed nothing
# under, and the home's own shared tree is what still holds the reader.
new_lane relocated ken-16
send KEN-16 'Reached the relocated root.'
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
global_home home-relocated
install_hook "$HOOK" "$TMP_ROOT/opt/codex/hooks/lane-mail-check.sh"
stop "HOME=$GLOBAL_HOME"
expect 2 "lane-mail-check: unread=1" \
  "a harness root outside the home reads the home's own shared tree"

# The refusal removed and nothing else: the hook still reads the mailbox and
# advances the cursor, so a control that deleted the read instead would prove
# the assertion runs rather than that the block does.
# Sets MUTANT_PATH rather than printing it: the assertion below writes to the
# same stdout a substitution would capture.
MUTANT_PATH=""
mutant() { # NAME SED-ARGUMENT... — MUTANT_SOURCE names a file other than the hook
  MUTANT_PATH="$TMP_ROOT/$1.sh"
  local name="$1" source="${MUTANT_SOURCE:-$HOOK}"
  shift
  sed "$@" "$source" > "$MUTANT_PATH"
  assert_eq "$(cmp -s "$MUTANT_PATH" "$source" && echo same || echo differs)" "differs" \
    "control: the $name mutant really differs from the hook"
}

mutant no-block -e 's@^message unread "\$COUNT"$@exit 0@'
BLOCK_MUTANT="$MUTANT_PATH"
new_lane control ken-11
send KEN-11 'Block me.'
install_hook "$BLOCK_MUTANT" "$LANE/.claude/hooks/lane-mail-check.sh"
stop
expect 0 - "control: without its refusal the hook lets the turn end with the message unread"

mutant unbound -e 's@^\[ "\$BOUND" = "\$ROOT" \] || exit 0$@:@'
unlaunched control_unmarked KEN-22 "" "$MUTANT_PATH"
expect 2 "lane-mail-check: unread=1" "control: without the marker rule a committed mailbox poses as a lane"

# The acknowledgement moved ahead of the refusal, both still made: killed
# between them, the hook has consumed a directive it never showed.
mutant ack-first -e '/^message unread "\$COUNT"$/d' -e 's@^exit 2$@message unread "$COUNT"; exit 2@'
killed_stop control_killed KEN-19 2 "$MUTANT_PATH"
assert_eq "$KILLED" "lost" "control: acknowledged before its refusal, a killed hook consumes the directive unseen"

# The containment rule's control: its refusal arm replaced by the assignment
# it guards, so the repository's script runs and leaves its marker.
mutant no-containment -e 's@^    [*]) refuse reader-outside .*$@    *) READER="$ROOT/.agents/skills/orch/scripts/lane-mail" ;;@'
OPEN_MUTANT="$MUTANT_PATH"
new_lane control_open ken-13
send KEN-13 'run me'
OPEN_MARKER="$TMP_ROOT/open-ran"
plant_reader "$OPEN_MARKER"
install_hook "$OPEN_MUTANT" "$TMP_ROOT/open-elsewhere/hooks/lane-mail-check.sh"
stop
assert_eq "$([ -e "$OPEN_MARKER" ] && echo ran || echo not-run)" "ran" \
  "control: without the containment rule the repository's own script runs"

# The shared tree is one rule offered at two sites, the walk and the home, so
# the mutant removes both; either site alone still answers the other's world.
mutant no-shared-tree \
  -e 's@ "\$AT/.agents/skills/orch/scripts/lane-mail"; do$@; do@' \
  -e 's@^  \[ ! -x "\$CANDIDATE" \] || READER="\$CANDIDATE"$@  :@'
SHARED_MUTANT="$MUTANT_PATH"
new_lane control_shared ken-15
send KEN-15 'Reached the global install.'
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
global_home home-control
install_hook "$SHARED_MUTANT" "$GLOBAL_HOME/.claude/hooks/lane-mail-check.sh"
stop "HOME=$GLOBAL_HOME"
expect 2 "lane-mail-check: reader-outside=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "control: without the shared tree the global install finds no reader"
install_hook "$SHARED_MUTANT" "$TMP_ROOT/opt-control/codex/hooks/lane-mail-check.sh"
stop "HOME=$GLOBAL_HOME"
expect 2 "lane-mail-check: reader-outside=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "control: without it a relocated harness root finds none either"

# The lane-mail-deliver and lane-mail-halt hooks run the judge beside them. A
# tool payload names the command the lane is about to run.
install_arms() { # [JUDGE]
  install_hook "$TEST_DIR/../lane-mail-deliver.sh" "$LANE/.claude/hooks/lane-mail-deliver.sh"
  install_hook "$TEST_DIR/../lane-mail-halt.sh" "$LANE/.claude/hooks/lane-mail-halt.sh"
  install_hook "${1:-$HOOK}" "$LANE/.claude/hooks/lane-mail-check.sh"
}

tool() { # ARM [COMMAND] [AGENT_ID] — an agent id marks a subagent's call
  local judge="$CASE_HOOK"
  CASE_HOOK="$LANE/.claude/hooks/lane-mail-$1.sh"
  run_payload "$(jq -nc --arg c "${2:-git status}" --arg a "${3:-}" \
    '{tool_name: "Bash", tool_input: {command: $c}} + (if $a == "" then {} else {agent_id: $a} end)')"
  CASE_HOOK="$judge"
}

# The event a deliver run's JSON names and the first line of the context it
# carries; `-` for no output.
context_line() {
  [ -s "$TMP_ROOT/stdout" ] || { echo -; return; }
  jq -r '"\(.hookSpecificOutput.hookEventName) \(.hookSpecificOutput.additionalContext | split("\n")[0])"' "$TMP_ROOT/stdout"
}

new_lane arms ken-30
install_arms
send KEN-30 'Rebase first.'
tool halt
expect 0 - "an unread directive that is no halt passes the tool call"
tool deliver
assert_eq "RC=$RC context=$(context_line) stderr=$(first_line)" \
  "RC=0 context=PostToolUse lane-mail-check: unread=1 stderr=-" \
  "a directive reaches a working lane in the context its next tool call's hook output carries"
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" "a finished tool call with nothing unread carries nothing"

send KEN-30 'Stop pushing.' --halt
HALT_ID=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-30/to-lane.jsonl")
printf -v READ_HALT '%q inbox --item %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-30
tool halt
expect 2 "lane-mail-check: halt=$HALT_ID" "an unread halt refuses the next tool call"
tool deliver
tool halt
expect 2 "lane-mail-check: halt=$HALT_ID" "a deliver run leaves the halt standing"
stop
tool halt
expect 2 "lane-mail-check: halt=$HALT_ID" "a stop run leaves the halt standing"
tool halt "$READ_HALT"
expect 0 - "the one command that reads the halt passes while it stands"
"$LANE_MAIL" inbox --item KEN-30 --root "$LANE" >/dev/null
tool halt
expect 0 - "a halt read by the inbox passes"

# Lane mail is the lead's: a subagent's call neither takes it nor clears a halt.
send KEN-30 'Rebase again.'
tool deliver "git status" dev-1
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: unread=1" \
  "a subagent's tool call leaves the directive unread for the lead's next call"
send KEN-30 'Stop again.' --halt
SUB_HALT=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-30/to-lane.jsonl" | tail -n 1)
tool halt "$READ_HALT" dev-1
expect 2 "lane-mail-check: halt=$SUB_HALT" \
  "a subagent's call carrying the acknowledging command is refused while a halt stands"
tool halt
expect 2 "lane-mail-check: halt=$SUB_HALT" "the halt still stands for the lead after that refusal"

ARM_ARGS=(bogus)
stop
ARM_ARGS=()
expect 2 "lane-mail-check: arm=bogus" "an arm the judge does not know is refused"
rm -f "$LANE/.claude/hooks/lane-mail-check.sh"
for name in deliver halt; do
  tool "$name"
  expect 2 "lane-mail-$name: judge=$LANE/.claude/hooks/lane-mail-check.sh" \
    "the $name hook with no judge beside it refuses, never passes"
done

# The halt refusal replaced by a pass, its judgement still made.
mutant no-halt -e 's@^  refuse halt "\$HALT_ID"$@  exit 0@'
new_lane control_halt ken-31
install_arms "$MUTANT_PATH"
send KEN-31 'Stop.' --halt
tool halt
expect 0 - "control: without its halt refusal the hook passes a tool call with a halt pending"

# Each arm's subagent check removed alone: a subagent's call is judged as the lead's.
mutant lead-deliver -e 's@^if \[ "\$ARM" = deliver \] && \[ "\$CALLER" = subagent \]; then$@if false; then@'
new_lane control_sub_deliver ken-34
install_arms "$MUTANT_PATH"
send KEN-34 'For the lead.'
tool deliver "git status" dev-1
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" \
  "control: without the deliver check a subagent's call consumes the lead's directive"
mutant lead-halt -e 's@^  if \[ "\$CALLER" = lead \]; then$@  if true; then@'
new_lane control_sub_halt ken-35
install_arms "$MUTANT_PATH"
send KEN-35 'Halt the lead.' --halt
printf -v SUB_READ '%q inbox --item %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-35
tool halt "$SUB_READ" dev-1
expect 0 - "control: without the halt check a subagent's call carrying the acknowledging command passes"

# The reader's acknowledgement clamp removed: a deliver run consumes the halt it showed.
CLAMPLESS="$TMP_ROOT/clampless"
mkdir -p "$CLAMPLESS"
ln -s "$REPO_ROOT/skills/orch/scripts/lib" "$CLAMPLESS/lib"
MUTANT_SOURCE="$LANE_MAIL" mutant no-clamp \
  -e 's@^      \[ -z "\$HALT_AT" \] || \[ "\$ACK" -le "\$HALT_AT" \] || ACK="\$HALT_AT"$@      :@'
mv "$MUTANT_PATH" "$CLAMPLESS/lane-mail"
chmod +x "$CLAMPLESS/lane-mail"
new_lane control_clamp ken-32
install_arms
ln -s -f -n "$CLAMPLESS" "$LANE/.agents/skills/orch/scripts"
send KEN-32 'Stop.' --halt
tool deliver
tool halt
expect 0 - "control: without the acknowledgement clamp a deliver run consumes the halt"

# The missing-judge refusal's exit removed, its message still written.
MUTANT_SOURCE="$TEST_DIR/../lane-mail-halt.sh" mutant no-judge-exit -e 's@^  exit 2$@  :@'
new_lane control_judge ken-33
install_arms
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-halt.sh"
rm -f "$LANE/.claude/hooks/lane-mail-check.sh"
tool halt
assert_eq "$([ "$RC" -eq 2 ] && echo refused || echo passed)" "passed" \
  "control: without its exit the halt hook with no judge beside it does not refuse"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
