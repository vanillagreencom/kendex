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
# Whether a mode-000 file can deny this reader. Root ignores the mode, so every
# row that seals a file and asserts the read failed reads a readable file there
# and fails on a world it was never written for. The sibling orch suites guard
# their permission fixtures the same way.
CAN_DENY_READS=1
[ "$(id -u)" -ne 0 ] || CAN_DENY_READS=0
# Which bash runs the hook: its shebang takes the first one on PATH, and the
# two versions differ on what a source it cannot parse does to the shell.
HOOK_BASH_MAJOR="$(bash -c 'printf %s "${BASH_VERSINFO[0]}"')"
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
  mkdir -p "$LANE"
  git -C "$LANE" init -q
  git -C "$LANE" checkout -q -b "$2"
  git -C "$LANE" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  lay_out_lane "$2"
}

# A lane in a worktree added from a main clone at MAIN, as `worktree create`
# makes one: the two share the common git directory the claim lives in.
MAIN=""
new_worktree_lane() { # NAME BRANCH
  MAIN="$TMP_ROOT/$1-main"
  LANE="$TMP_ROOT/$1"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q
  git -C "$MAIN" checkout -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  git -C "$MAIN" worktree add -q -b "$2" "$LANE"
  lay_out_lane "$2"
}

# The install and the launch record, on the repository LANE names.
lay_out_lane() { # BRANCH
  mkdir -p "$LANE/.agents/skills/orch" "$LANE/.claude/hooks" "$LANE/.claude/skills"
  ln -s -f -n "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
  ln -s -f -n ../../.agents/skills/orch "$LANE/.claude/skills/orch"
  install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
  mark_lane "$1"
}

# The marker a launcher writes: the lane's root, named for the item in lower
# case under the common git directory.
mark_lane() { # ITEM
  local common
  common="$(git -C "$LANE" rev-parse --path-format=absolute --git-common-dir)"
  mkdir -p "$common/lane-mail"
  git -C "$LANE" rev-parse --show-toplevel > "$common/lane-mail/$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
}

# Every claim gone, as in a repository no launch ever reached.
unclaim() {
  local common
  common="$(git -C "$LANE" rev-parse --path-format=absolute --git-common-dir)"
  rm -rf -- "${common:?}/lane-mail"
}

# The world a case runs in unless it names another: a home with no lane in it,
# so the handoff marks' account read answers `no configured lane of this
# harness` without reaching the network, and a fetch stub that fails if one
# ever is discovered. The developer's own lane variables and handoff settings
# are cleared rather than inherited, so a case's world is only what it sets.
OFFLINE_HOME="$TMP_ROOT/offline-home"
NO_FETCH="$TMP_ROOT/no-fetch"
mkdir -p "$OFFLINE_HOME"
printf '#!/bin/sh\nexit 1\n' > "$NO_FETCH"
chmod +x "$NO_FETCH"
# The account mark is never judged in that world, so the hook reports the gap
# and ends the turn. This is the whole of a passing turn end's stderr on a lane
# the marks are reached on, and `-` on one they are not.
GAP='lane-mail-check: account=unlisted'

RC=0
# The judge's argument, empty for the turn-end run the harness makes.
ARM_ARGS=()
# The directory the call is made from, the lane's own unless a case names
# another: a lane runs its post-merge steps from the main clone. CALL_ENV is
# what the harness running that call sets, such as the directory it started in.
CALL_DIR=""
CALL_ENV=()
run_payload() { # RAW-JSON [ENV=VAL...]
  local payload="$1"
  shift
  RC=0
  : > "$ERR_FILE"
  printf '%s' "$payload" |
    (cd "${CALL_DIR:-$LANE}" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_PROJECT_DIR -u CODEX_HOME -u LANE_MAIL_ITEM \
      -u ORCH_HANDOFF_CONTEXT_TOKENS -u ORCH_HANDOFF_HEADROOM_PCT -u ORCH_STATE_DIR \
      -u ORCH_OVERSEER_HEADROOM_PCT -u ORCH_OVERSEER_SUCCESSION -u TMUX -u TMUX_PANE \
      "LANES_HOME=$OFFLINE_HOME" "ORCH_LANES_FETCH_CMD=$NO_FETCH" \
      ${CALL_ENV[@]+"${CALL_ENV[@]}"} "$@" bash "$CASE_HOOK" ${ARM_ARGS[@]+"${ARM_ARGS[@]}"}) >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
}

stop() { # [ENV=VAL...]
  run_payload '{"session_id":"s1","stop_hook_active":false}' "$@"
}

# The turn the harness continued because a stop hook blocked.
stop_active() { # [ENV=VAL...]
  run_payload '{"session_id":"s1","stop_hook_active":true}' "$@"
}

# A turn end whose payload names a transcript, as the harness writes one.
stop_at() { # TRANSCRIPT ACTIVE [ENV=VAL...]
  local path="$1" active="$2"
  shift 2
  run_payload "$(jq -nc --arg p "$path" --argjson a "$active" \
    '{session_id:"s1",stop_hook_active:$a,transcript_path:$p}')" "$@"
}

# One assistant line carrying the usage the harness recorded for it, in the
# spelling that harness writes usage in; the context is its input tokens plus
# the cache the prompt was read from, and every spelling below sums to TOKENS.
# A real transcript grows one line at a time, so a row that turns on WHICH
# usage line the hook reads writes the first and appends the rest.
#
#   claude  Claude Code's own line: input_tokens beside its two cache counts.
#   pi      Pi's session entry, `appendMessage` in @earendil-works/pi-coding-agent,
#           carrying the `Usage` of @earendil-works/pi-ai: input, output,
#           cacheRead, cacheWrite, totalTokens and cost, none of them spelled
#           the way Claude Code spells them.
#   unread  a usage object carrying neither spelling, which is what the hook
#           must report rather than sum to zero. It stands for no harness this
#           install has measured; TOKENS is what a lane would be past its mark
#           by if the figure could be read at all.
usage_line() { # SPELLING TOKENS
  case "$1" in
    claude)
      jq -nc --argjson t "$2" \
        '{type:"assistant",message:{usage:{input_tokens:1,cache_read_input_tokens:($t - 1),cache_creation_input_tokens:0}}}'
      ;;
    pi)
      jq -nc --argjson t "$2" \
        '{type:"message",id:"e1",parentId:null,timestamp:"2026-09-19T00:00:00Z",
          message:{role:"assistant",model:"m",stopReason:"stop",
                   usage:{input:1,output:7,cacheRead:($t - 1),cacheWrite:0,
                          totalTokens:($t + 7),cost:{total:0}}}}'
      ;;
    unread)
      jq -nc --argjson t "$2" \
        '{type:"assistant",message:{usage:{prompt_tokens:$t,completion_tokens:7}}}'
      ;;
    *) printf 'usage_line: no such spelling: %s\n' "$1" >&2; return 1 ;;
  esac
}

write_transcript() { # PATH TOKENS
  usage_line claude "$2" > "$1"
}

append_transcript() { # PATH TOKENS
  usage_line claude "$2" >> "$1"
}

# Everything a kendex install renders beside the mailbox reader, taken from the
# catalog itself rather than from a second list here: the handoff marks run
# three of these scripts and those scripts run others, so a case that plants
# its own reader plants the whole neighbourhood the way an install has it. The
# reader is the caller's to plant, and SKIP is the one script a case holes.
plant_siblings() { # SCRIPTS_DIR [SKIP]
  local entry name
  for entry in "$REPO_ROOT/skills/orch/scripts"/*; do
    name="${entry##*/}"
    [ "$name" != lane-mail ] || continue
    [ "$name" != "${2:-}" ] || continue
    ln -s -f -n "$entry" "$1/$name"
  done
}

# The real orch skill beside the hook, with SKIP left out: the walk finds this
# copy before the one under .agents, so a case can hole an install without
# touching anything else the lane carries.
plant_install() { # [SKIP]
  # Whatever stands there, a link new_lane made or an install an earlier call
  # planted, so a case can plant twice.
  rm -rf -- "${LANE:?}/.claude/skills/orch"
  mkdir -p "$LANE/.claude/skills/orch/scripts"
  ln -s -f -n "$REPO_ROOT/skills/orch/scripts/lane-mail" "$LANE/.claude/skills/orch/scripts/lane-mail"
  plant_siblings "$LANE/.claude/skills/orch/scripts" "${1:-}"
}

# The repository's own reader: it touches MARKER, so a run of it is visible.
plant_reader() { # MARKER
  rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
  mkdir -p "$LANE/.agents/skills/orch/scripts"
  printf '#!/bin/sh\ntouch %s\n' "$1" > "$LANE/.agents/skills/orch/scripts/lane-mail"
  chmod +x "$LANE/.agents/skills/orch/scripts/lane-mail"
  plant_siblings "$LANE/.agents/skills/orch/scripts"
}

send() { # ITEM TEXT [--re MSGID]
  ITEM="$1"
  printf '%s\n' "$2" > "$TMP_ROOT/msg.txt"
  shift 2
  (cd "$LANE" && "$LANE_MAIL" send --item "$ITEM" --root "$LANE" "${@:---directive}" --file "$TMP_ROOT/msg.txt")
}

echo "=== lane-mail-check ==="

new_lane plain ken-1
stop
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "a root a launch claimed with no mailbox directory is refused, never passed"
unclaim
stop
expect 0 - "a repository with no claim and no mailbox directory passes silently"
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
expect 2 "lane-mail-check: git=rev-parse --show-toplevel --git-common-dir" \
  "a mailbox git can report no repository for is refused, never passed"

new_lane empty ken-3
mkdir -p "$LANE/tmp/lane-mail/KEN-3"
stop
expect 0 "$GAP" "a mailbox with no to-lane.jsonl ends the turn with only the account gap reported"
: > "$LANE/tmp/lane-mail/KEN-3/to-lane.jsonl"
stop
expect 0 "$GAP" "an empty mailbox ends the turn with only the account gap reported"

new_lane unread ken-4
send KEN-4 'Hold the PR until the owner answers.'
stop
expect 2 "lane-mail-check: unread=1" "unread mail refuses with the count on the first line"
assert_eq "$(cause_below)" "present" "the messages stand under the keyed line"
assert_eq "$(grep -c 'Hold the PR until the owner answers.' "$ERR_FILE")" "1" \
  "the refusal carries the message the overseer sent"
assert_eq "$(cat "$TMP_ROOT/stdout")" "" "the hook writes nothing to stdout"
stop
expect 0 "$GAP" "a second stop passes: the reader advanced the cursor past what it handed over"

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
  plant_siblings "$LANE/.claude/skills/orch/scripts"
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
expect 0 "$GAP" "an answer belongs to the wait that asked for it and never stops a turn"

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

if [ "${CAN_DENY_READS:?}" -eq 1 ]; then
  new_lane unreadable ken-9
  send KEN-9 'sealed'
  chmod 000 "$LANE/tmp/lane-mail/KEN-9/to-lane.jsonl"
  stop
  chmod 644 "$LANE/tmp/lane-mail/KEN-9/to-lane.jsonl"
  expect 2 "lane-mail-check: inbox=2" "a mailbox that cannot be read is refused with the reader's status"
  assert_eq "$(grep -c '^lane-mail: file-unreadable=' "$ERR_FILE")" "1" \
    "the reader's own keyed line is replayed under the hook's"
else
  printf '  skip  a mailbox that cannot be read: running as root, which reads a mode-000 file\n'
  printf '  skip  the reader keyed line under the hook s: running as root, which reads a mode-000 file\n'
fi

new_lane payload ken-10
send KEN-10 'x'
run_payload 'not json'
expect 2 "lane-mail-check: payload=invalid-json" "a payload that is not JSON is refused rather than skipped"
run_payload '{"stop_hook_active":true}'
expect 0 "$GAP" "the turn the harness already continued is not blocked again"


# A refusal the lane cannot clear repeats at every turn end for as long as its
# cause stands. The turn the harness already continued skips the mailbox check
# whole and reports what it could not settle instead of refusing it again, so
# the session can end. Three causes, each refused once and then reported.
new_lane continued_reader ken-61
send KEN-61 'unreachable'
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
NO_READER="$LANE/.agents/skills/orch/scripts/lane-mail"
stop
expect 2 "lane-mail-check: reader=$NO_READER" "a fresh turn refuses a mailbox it has no reader for"
stop_active
expect 0 "lane-mail-check: handoff-skipped=$NO_READER" \
  "the continued turn reports the same missing install and ends"

new_lane continued_item ken-62
mkdir -p "$LANE/tmp/lane-mail/KEN-62"
stop LANE_MAIL_ITEM='bad item!'
expect 2 "lane-mail-check: item=invalid" "a fresh turn refuses an item outside its alphabet"
stop_active LANE_MAIL_ITEM='bad item!'
expect 0 "lane-mail-check: item=invalid" "the continued turn reports the invalid item and ends"

if [ "${CASE_SENSITIVE:?}" -eq 1 ]; then
  new_lane continued_ambiguous ken-63
  mkdir -p "$LANE/tmp/lane-mail/KEN-63" "$LANE/tmp/lane-mail/ken-63"
  stop
  expect 2 "lane-mail-check: item=ambiguous" "a fresh turn refuses a branch two mailboxes lowercase to"
  stop_active
  expect 0 "lane-mail-check: item=ambiguous" "the continued turn reports the ambiguity and ends"
else
  printf '  skip  a continued turn after an ambiguous item: this filesystem is case-insensitive\n'
fi

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
# A copy of the hook with one constant rewritten, so a row can reach a bound
# the shipped value would make it wait for. The rewrite is asserted, never
# assumed. This is a fixture, not a control: it plants no defect.
VARIANT_PATH=""
variant() { # NAME SED-ARGUMENT...
  VARIANT_PATH="$TMP_ROOT/$1.sh"
  local name="$1"
  shift
  sed "$@" "$HOOK" > "$VARIANT_PATH"
  assert_eq "$(cmp -s "$VARIANT_PATH" "$HOOK" && echo same || echo differs)" "differs" \
    "the $name copy really differs from the hook"
}

# --- the handoff marks ---------------------------------------------------
#
# A lane hands itself off at the context mark and at its account's wall, so no
# overseer has to read a pane for it. Every row here is a turn end on a lane
# with an empty mailbox, which is the path the marks are judged on.

# A lane whose mailbox holds nothing, so each row below judges the marks alone.
# The mailbox directory is what `write_lane_marker` makes at launch beside the
# marker, so a lane nobody has messaged still carries the name the hook
# resolves the marks by; open-terminal-lane.sh asserts the launcher makes it.
new_handoff_lane() { # NAME ITEM
  new_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  mkdir -p "$LANE/tmp/lane-mail/$2"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init "$2" >/dev/null)
}

# The record's fields, the durable recovery state a relaunch reads. One list:
# the refusal's template is checked against it and the record below is built
# from it, so a field leaving either side reddens. `written_at` is not among
# them: `workflow-state set` stamps the record's time from its own clock, so a
# lane cannot hand it one that names a moment the clock has not reached.
HANDOFF_FIELDS='merged,remaining,branch,worktree,open_pr,traps'

# The keys of the JSON template the refusal told the lane to write, in order.
template_fields() {
  sed -n "s/.*handoff '\\({.*}\\)'.*/\\1/p" "$ERR_FILE" |
    grep -o '"[a-z_]*":' | tr -d '":' | tr '\n' ',' | sed 's/,$//'
}

# The record the lane writes at the safe point, and the field a relaunch sets
# on it once the item is resumed. Nothing reads the values, only the shape.
record_handoff() { # ITEM [RESUMED_AT]
  local value
  value="$(printf '%s' "$HANDOFF_FIELDS" | tr ',' '\n' | jq -Rn --arg r "${2:-}" \
    '([inputs | {key: ., value: "x"}] | from_entries)
     | if $r == "" then . else .resumed_at = $r end')"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set "$1" handoff "$value" >/dev/null)
}

TRANSCRIPT="$TMP_ROOT/transcript.jsonl"

new_handoff_lane handoff_context KEN-50
write_transcript "$TRANSCRIPT" 499999
stop_at "$TRANSCRIPT" false
expect 0 "$GAP" "a lane under the context mark ends its turn"
write_transcript "$TRANSCRIPT" 500000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=500000" "a lane at the context mark is refused with the figure it reached"
assert_eq "$(grep -cF -- "workflow-state set KEN-50 handoff " "$ERR_FILE")" "1" \
  "the refusal names the one command that writes the record"
assert_eq "$(template_fields)" "$HANDOFF_FIELDS" \
  "the record template it names carries every field a relaunch reads"
assert_eq "$(template_fields | tr ',' '\n' | grep -cx written_at || true)" "0" \
  "and asks the lane for no written_at, which the set stamps"
assert_eq "$(grep -cF -- "lane-mail notice --item KEN-50 --file" "$ERR_FILE")" "1" \
  "the refusal names the handoff notice beside it"
stop_at "$TRANSCRIPT" true
expect 2 "lane-mail-check: context=500000" \
  "the refusal repeats on the continued turn, where the mailbox check does not"
record_handoff KEN-50
stop_at "$TRANSCRIPT" false
expect 0 - "a lane whose handoff record stands ends its turn past the mark"
stop_at "$TMP_ROOT/absent.jsonl" false
expect 0 - "the record is judged before every read the marks rest on, so no failed read traps a lane that recorded one"
record_handoff KEN-50 2026-09-18T09:00:00Z
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=500000" \
  "a record a relaunch resumed belongs to an earlier life and does not clear the mark"

# The figure is the LAST usage line, so a compaction that reset the window
# reads as the reset it is, and the window the tail read opens on can end
# mid-line without changing the answer.
new_handoff_lane handoff_last_line KEN-71
write_transcript "$TRANSCRIPT" 600000
append_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
expect 0 "$GAP" "a transcript whose first usage line is past the mark and whose last is under it ends the turn"
write_transcript "$TRANSCRIPT" 1000
append_transcript "$TRANSCRIPT" 600000
printf '{"type":"assistant","message":{"usa' >> "$TRANSCRIPT"
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "the last complete usage line is the figure, and the fragment the harness is still writing is skipped"
# The payload's three fields are joined on TAB, so a path holding a space is
# one field and not two.
SPACED="$TMP_ROOT/a transcript.jsonl"
write_transcript "$SPACED" 600000
stop_at "$SPACED" false
expect 2 "lane-mail-check: context=600000" "a transcript path holding a space is read, never truncated at it"

# Every spelling a harness writes that usage object in, judged on one figure
# and its inverse: under the mark the turn ends, at the mark the refusal names
# the figure it reached. Pi's is the spelling a lane was reading as zero, so a
# Pi lane ran its context to exhaustion with nothing held and nothing said.
new_handoff_lane handoff_spellings KEN-90
for SPELLING in claude pi; do
  usage_line "$SPELLING" 499999 > "$TRANSCRIPT"
  stop_at "$TRANSCRIPT" false
  expect 0 "$GAP" "a $SPELLING-spelled usage line under the context mark ends the turn"
  usage_line "$SPELLING" 500000 > "$TRANSCRIPT"
  stop_at "$TRANSCRIPT" false
  expect 2 "lane-mail-check: context=500000" \
    "a $SPELLING-spelled usage line at the context mark is refused with the figure it reached"
done

# A usage object neither spelling reads. The figure IS there and unread, which
# is not the documented gap a payload naming no transcript leaves, so it gets
# its own key rather than the silence that gap takes. The turn still ends: no
# handoff record the lane writes would teach this install a harness's field
# names, so holding it would be a refusal nothing the lane does could clear.
new_handoff_lane handoff_unread_usage KEN-91
usage_line unread 900000 > "$TRANSCRIPT"
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) judged=$(grep -c 'context=' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: usage-unread=$TRANSCRIPT judged=0" \
  "a usage object neither spelling reads is keyed, never summed to a figure the mark is judged on"
assert_eq "$(grep -c 'neither of the field spellings' "$ERR_FILE")" "1" \
  "and the key carries the English that says why the figure went unread"
assert_eq "$(grep -cx "$GAP" "$ERR_FILE")" "1" \
  "and the account mark beside it is judged as it is on any other turn end"

new_handoff_lane handoff_setting KEN-51
write_transcript "$TRANSCRIPT" 500000
stop_at "$TRANSCRIPT" false ORCH_HANDOFF_CONTEXT_TOKENS=900000
expect 0 "$GAP" "a mark the setting raises is not reached at the same figure"
# orch-env falls back to its default only on a NON-numeric value, so a value
# in a shape no comparison can take reaches the hook and is named here.
stop_at "$TRANSCRIPT" false ORCH_HANDOFF_CONTEXT_TOKENS=0500000
assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- "workflow-state set KEN-51 handoff " "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: setting-range=ORCH_HANDOFF_CONTEXT_TOKENS=0500000 named=1" \
  "a context mark that is not a plain whole number names the value, and the record clears it"

new_handoff_lane handoff_subagent KEN-52
write_transcript "$TRANSCRIPT" 800000
run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
  '{session_id:"s1",stop_hook_active:false,agent_id:"a1",transcript_path:$p}')"
expect 0 - "a subagent runs its own window and is judged on neither mark"

new_handoff_lane handoff_no_transcript KEN-53
stop
expect 0 "$GAP" "a payload naming no transcript leaves the context unread and passes"
stop_at "$TMP_ROOT/absent.jsonl" false
assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- "workflow-state set KEN-53 handoff " "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: transcript=unreadable named=1" \
  "a transcript the payload names and nothing can read is refused, with the record that clears it"

# The settings loader sources .env.local as shell, and every orch script this
# hook runs loads it. A file a person has broken therefore stops the state read
# first, with a status the verb never gives, so the gap is reported with the
# loader's own words and the turn ends rather than the lane being held on a
# fault no handoff record clears. The key says the script is THERE and did not
# answer, never that it is missing: the repair is a settings line, and an
# operator sent to reinstall an installed skill never finds it.
new_handoff_lane handoff_setting_unreadable KEN-78
printf 'this is ( not shell\n' > "$LANE/.env.local"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'syntax error' "$ERR_FILE") said=$(grep -c 'is there but did not answer' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/workflow-state cause=1 said=1" \
  "a settings file that will not load is reported with the loader's words and the turn ends"
assert_eq "$(grep -c 'is not there' "$ERR_FILE")" "0" \
  "and is never reported as an install that is not there"

# The verb's own status 2: a state file it cannot read. Its header and --help
# publish 2 as attributable, so it is told apart from an install that does not
# carry the verb at all — the repair for one is a state file, for the other an
# install — and the reader's own words, which name the file, stand under it.
# Driven against the real verb, on the file shape a killed write leaves: a
# truncated document, which is the shape jq reports WITHOUT naming the file it
# came from. So the key carries the path the `path` verb answers rather than
# resting on the reader's words, and this row is what holds it to that.
new_handoff_lane handoff_unreadable_state KEN-86
STATE_FILE="$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" path KEN-86)"
printf '{"handoff":' > "$STATE_FILE"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'jq: parse error' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-unreadable=$STATE_FILE cause=1" \
  "a state file the verb could not read is reported under its own key, naming the file"
assert_eq "$(grep -F 'jq: parse error' "$ERR_FILE" | grep -cF "$STATE_FILE")" "0" \
  "and the reader's own words name no file for this shape, which is why the key carries it"

# A sibling the marks need that is there and answers non-zero: the record still
# clears it, so it is refused with the setting named and its words under it.
new_handoff_lane handoff_setting_broken KEN-85
plant_install orch-env
printf '#!/bin/sh\nprintf "orch-env: broken\\n" >&2\nexit 1\n' \
  > "$LANE/.claude/skills/orch/scripts/orch-env"
chmod +x "$LANE/.claude/skills/orch/scripts/orch-env"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -cx 'orch-env: broken' "$ERR_FILE") named=$(grep -cF -- "workflow-state set KEN-85 handoff " "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: setting=ORCH_HANDOFF_CONTEXT_TOKENS cause=1 named=1" \
  "a mark whose setting could not be read is refused with the reader's words and the record that clears it"

# The read is bounded to the last TRANSCRIPT_WINDOW bytes, and falls back to
# the whole file where that window carries no usage line — a session whose
# recent megabyte is all tool results. Both halves need a transcript larger
# than the window, so the copy shortens the window instead of the fixture
# growing to a megabyte.
variant short-window -e 's@^TRANSCRIPT_WINDOW=1048576$@TRANSCRIPT_WINDOW=512@'
WINDOW_HOOK="$VARIANT_PATH"
# filler PATH BYTES — lines the usage read skips, so a row can put a usage line
# on either side of the window.
filler() { # PATH BYTES
  jq -nc --arg p "$(head -c "$2" /dev/zero | tr '\0' 'x')" '{type:"user",text:$p}' >> "$1"
}

new_handoff_lane handoff_window KEN-83
install_hook "$WINDOW_HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
filler "$TRANSCRIPT" 2000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "a usage line before the window is found by the read of the whole file behind it"
assert_eq "$(grep -c 'usage-unread' "$ERR_FILE")" "0" \
  "and a window holding no usage line resolves through that read, never under the unread-usage key"
write_transcript "$TRANSCRIPT" 1000
filler "$TRANSCRIPT" 2000
append_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "a usage line inside the window is found without reading the whole file"

# The account mark, measured through the credential the lane runs on. The
# standard home is shared with the orch suites, so both accounts are staged
# HERE rather than there: nclaude AT the default mark this hook judges, and
# eclaude one point above it. claude has 80 and is room.
#
# The pair is what pins the number. The refusal key carries the account's
# measured headroom and not the threshold, so the nclaude row alone is green
# for any mark at or above it; eclaude ends its turn at this default and is
# refused by the one it replaced, so a mark that drifts back reddens here.
source "$REPO_ROOT/skills/orch/tests/lib/lanes-fixture.sh"
standard_home handoff-accounts
claude_usage 5 97 12 Opus > "$FIXTURE_DIR/.nclaude.json"
claude_usage 5 96 12 Opus > "$FIXTURE_DIR/.eclaude.json"
FETCHER="$TMP_ROOT/handoff-fetch"
make_fetcher "$FETCHER"
account_env() { # LANE-DIR-NAME
  printf '%s\n' "LANES_HOME=$H" "ORCH_LANES_FETCH_CMD=$FETCHER" "FIXTURE_DIR=$FIXTURE_DIR" \
    "CLAUDE_CONFIG_DIR=$H/$1"
}

new_handoff_lane handoff_headroom KEN-54
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .claude)
expect 0 - "a lane on an account with room ends its turn"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .nclaude)
expect 2 "lane-mail-check: headroom=3" "a lane at its account's handoff mark is refused with the headroom left"
assert_eq "$(grep -cF -- "workflow-state set KEN-54 handoff " "$ERR_FILE")" "1" \
  "the account refusal carries the same instruction as the context refusal"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .nclaude) ORCH_HANDOFF_HEADROOM_PCT=1
expect 0 - "a mark the setting lowers leaves the same account with room"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .eclaude)
expect 0 - "an account one point above the mark ends its turn, which the mark this default replaced would refuse"
record_handoff KEN-54
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .nclaude)
expect 0 - "a lane whose handoff record stands ends its turn at its account's mark"

# An account nothing could measure is a gap the lane cannot act on: it is
# reported and the turn ends, never refused, so a setup with no usage endpoint
# is not stopped by a mark it can never reach.
new_handoff_lane handoff_unmeasured KEN-55
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .openclaude)
expect 0 "lane-mail-check: account=unmeasured" \
  "an account with an inventory entry and no usable credential is reported, never read as room"

# `lanes pick --lane` keeps a status-only contract where `handoff-standing`
# could not, and one reservation is what makes that safe: every status with an
# arm of its own is one no death before the verb can produce. `lanes` loads the
# same `.env.local` through the same loader, and a file bash cannot parse kills
# it with 1 or 2 — the two rows below — while the arms that refuse a lane, name
# its harness and report an abandoned read take 3, 4 and 124. An arm that
# starts acting on 1 or 2 reds here.
new_handoff_lane handoff_lanes_reserved KEN-92
write_transcript "$TRANSCRIPT" 1000
for status in 1 2; do
  plant_install lanes
  printf '#!/bin/sh\nprintf "lanes: died at %%s\\n" "%s" >&2\nexit %s\n' "$status" "$status" \
    > "$LANE/.claude/skills/orch/scripts/lanes"
  chmod +x "$LANE/.claude/skills/orch/scripts/lanes"
  stop_at "$TRANSCRIPT" false
  assert_eq "RC=$RC first=$(first_line) cause=$(grep -cx "lanes: died at $status" "$ERR_FILE")" \
    "RC=0 first=lane-mail-check: account=unmeasured cause=1" \
    "a lanes exiting $status leaves the account unmeasured with its own words, never refusing on a status its verb never gives"
done

# A harness this hook's install does not name has no account to read at all.
# The context mark is still judged; the account gap is reported and the turn
# ends, so a consumer on such a harness is never held by a mark it cannot reach.
new_handoff_lane handoff_unnamed_harness KEN-79
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
global_home home-handoff
install_hook "$HOOK" "$GLOBAL_HOME/.pi/agent/kendex/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false "HOME=$GLOBAL_HOME"
assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- "$GLOBAL_HOME/.pi/agent/kendex/hooks is no harness" "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: account=unlisted named=1" \
  "a harness this install does not name leaves the account unjudged, named, and the turn ends"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false "HOME=$GLOBAL_HOME"
expect 2 "lane-mail-check: context=600000" "and the context mark is judged there as everywhere"

# A setting out of range dies inside `lanes` as invalid-percent, whose exit the
# hook cannot tell from an unmeasurable account, so the bound is judged here.
new_handoff_lane handoff_setting_range KEN-70
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .claude) ORCH_HANDOFF_HEADROOM_PCT=101
assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- "workflow-state set KEN-70 handoff " "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: setting-range=ORCH_HANDOFF_HEADROOM_PCT=101 named=1" \
  "a headroom setting out of range names the setting and its value, never the account"

# The read waits on a credentials lock and two network calls, and on a cache
# miss on the host-wide usage refresh lock and a 429 retry's sleep and third
# call, which together outlast this hook's budget, and a hook the harness kills
# at its budget writes no line at all. The copy shortens the ceiling so the row
# need not wait for it.
if command -v timeout >/dev/null 2>&1; then
  variant short-ceiling -e 's@^ACCOUNT_CEILING=20$@ACCOUNT_CEILING=1@'
  standard_home handoff-ceiling
  SLOW_FETCH="$TMP_ROOT/slow-fetch"
  printf '#!/bin/sh\nsleep 30\n' > "$SLOW_FETCH"
  chmod +x "$SLOW_FETCH"
  new_handoff_lane handoff_ceiling KEN-69
  install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
  write_transcript "$TRANSCRIPT" 1000
  stop_at "$TRANSCRIPT" false "LANES_HOME=$H" "ORCH_LANES_FETCH_CMD=$SLOW_FETCH" \
    "FIXTURE_DIR=$FIXTURE_DIR" "CLAUDE_CONFIG_DIR=$H/.claude"
  expect 0 "lane-mail-check: account=timeout" \
    "an account read that passes the ceiling is reported as a gap and the turn ends"

  # What the ceiling leaves behind. `lanes` takes the credentials mutex inside
  # a command substitution, which the ceiling reaps along with the shell that
  # called it. Without a release the mutex outlives the hook and every later
  # renewal on that account waits out its whole timeout. The stub is the real
  # lock library taking the real mutex, on a PATH with no flock, which is the
  # platform that has one. The assertion reads the settled state rather than
  # the instant the hook returns, through lib/lanes-fixture.sh's
  # `settled_mutex`, sourced above.
  LOCK_BIN="$TMP_ROOT/lock-bin"
  mkdir -p "$LOCK_BIN"
  for tool in mkdir sleep rmdir cat rm; do
    ln -s -f -n "$(command -v "$tool")" "$LOCK_BIN/$tool"
  done
  LANE_LOCK="$TMP_ROOT/held-lane/.lanes-refresh.lock"
  mkdir -p "$TMP_ROOT/held-lane"
  new_handoff_lane handoff_mutex KEN-84
  install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
  plant_install lanes
  # The nesting is the real one: `lanes` measures a lane in a command
  # substitution, the renewal inside it takes the mutex in another, and it
  # blocks there on its token POST, a third. Which of those the holder waits in
  # decides whether bash reaches its trap, so a stub that blocked in a bare
  # foreground command would measure a shape `lanes` never has.
  printf '#!/usr/bin/env bash\nset -uo pipefail\n. "%s/lib/file-lock.sh"\nrefresh() {\n  PATH="%s"\n  exec 9>"%s"\n  orch_take_lock 9 "%s" 30 || exit 1\n  post=$(sleep 30)\n  printf %%s "$post"\n}\nmeasure() {\n  local out\n  out=$(refresh) || return 1\n  printf %%s "$out"\n}\nrecord=$(measure)\n' \
    "$REPO_ROOT/skills/orch/scripts" "$LOCK_BIN" "$LANE_LOCK" "$LANE_LOCK" \
    > "$LANE/.claude/skills/orch/scripts/lanes"
  chmod +x "$LANE/.claude/skills/orch/scripts/lanes"
  write_transcript "$TRANSCRIPT" 1000
  stop_at "$TRANSCRIPT" false "LANES_HOME=$H" "ORCH_LANES_FETCH_CMD=$FETCHER" \
    "FIXTURE_DIR=$FIXTURE_DIR" "CLAUDE_CONFIG_DIR=$H/.claude"
  assert_eq "RC=$RC first=$(first_line) mutex=$(settled_mutex "$LANE_LOCK.d")" \
    "RC=0 first=lane-mail-check: account=timeout mutex=released" \
    "the ceiling leaves no credentials mutex behind for the next renewal to wait on"

  standard_home handoff-accounts
  claude_usage 5 97 12 Opus > "$FIXTURE_DIR/.nclaude.json"
  claude_usage 5 96 12 Opus > "$FIXTURE_DIR/.eclaude.json"
else
  printf '  skip  an account read past the ceiling: this host has no timeout to bound it with\n'
fi

# The record is judged before the scripts only the marks need, so a lane that
# has already recorded its handoff is not held by a partial install.
new_handoff_lane handoff_partial KEN-65
plant_install lanes
record_handoff KEN-65
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 - "a standing record ends the turn although lanes is missing from the install"

# The same install with no record: the script the marks need is named, and so
# is the record that ends the refusal.
new_handoff_lane handoff_script KEN-67
plant_install lanes
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) named=$(grep -cF -- "workflow-state set KEN-67 handoff " "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: script=$LANE/.claude/skills/orch/scripts/lanes named=1" \
  "a script the marks need and the install has not got is refused, with the record that clears it"

# The one command that records a handoff, missing: a refusal naming it could
# never be cleared, so the gap is reported and the turn ends.
new_handoff_lane handoff_no_state KEN-72
plant_install workflow-state
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 "lane-mail-check: handoff-skipped=$LANE/.claude/skills/orch/scripts/workflow-state" \
  "an install with no workflow-state leaves the marks unjudged rather than trapping the lane"

# Hooks and skills refresh on their own schedules, and the reader walk climbs
# from this hook's install to the home's shared tree, so the orch scripts the
# marks run can be older than the hook. The verb answers 0 for a record and 3
# for none; every other status is an install that does not carry it, reported
# with its own words and passed. Read as "no record" instead, a lane that has
# already written one would be refused at every turn end for ever.
old_dispatcher() { # — the unknown-command arm of a workflow-state without the verb
  plant_install workflow-state
  printf '#!/bin/sh\ncase "$1" in\n  handoff-standing) printf "workflow-state: unknown-command arg1=%%s\\n" "$1" >&2; exit 1 ;;\nesac\nexit 0\n' \
    > "$LANE/.claude/skills/orch/scripts/workflow-state"
  chmod +x "$LANE/.claude/skills/orch/scripts/workflow-state"
}

new_handoff_lane handoff_old_state KEN-80
old_dispatcher
UNANSWERED="lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/workflow-state"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'workflow-state: unknown-command' "$ERR_FILE") said=$(grep -c 'is there but did not answer' "$ERR_FILE")" \
  "RC=0 first=$UNANSWERED cause=1 said=1" \
  "an install that does not carry the verb is reported with its own words and the turn ends"
record_handoff KEN-80
old_dispatcher
stop_at "$TRANSCRIPT" false
expect 0 "$UNANSWERED" "a lane that has written its record is never refused by that install either"

# The same shape one library down: `lane_context_caller_cfg` is this branch's
# addition, and an orch library without it is readable and sources without
# error, so the call would leave the hook on bash's 127 with no keyed line.
# The library is THERE, so it takes the unanswered key rather than the one
# that tells an operator to install what is installed.
new_handoff_lane handoff_old_library KEN-81
plant_install lib
mkdir -p "$LANE/.claude/skills/orch/scripts/lib"
# Every library but the one this case holes, and that one is written as a file
# of its own rather than over a link: a redirect through a symlink truncates
# the link's target, which here would be the catalog's own copy.
for name in "$REPO_ROOT/skills/orch/scripts/lib"/*.sh; do
  [ "${name##*/}" != lane-context.sh ] || continue
  ln -s -f -n "$name" "$LANE/.claude/skills/orch/scripts/lib/${name##*/}"
done
printf '# shellcheck shell=bash\n: "an orch library older than the account rule"\n' \
  > "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) said=$(grep -c 'is there but did not answer' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/lib/lane-context.sh said=1" \
  "an orch library without the account rule is reported and the turn ends, never left on 127"

# This hook's own directory gone while the turn ends, which a refresh that
# replaces the hooks directory does: no install can be looked for at all, so
# the gap takes the value no path can fill. The stub removes the directory on
# the `--git-common-dir` read that resolves the lane's root, the one call of
# its kind a run makes, and well ahead of the reader on a lane whose mailbox
# holds nothing; bash goes on reading this hook from the handle it already has.
new_handoff_lane handoff_unlocatable KEN-91
GIT_SHIM="$TMP_ROOT/git-shim"
mkdir -p "$GIT_SHIM"
printf '#!/usr/bin/env bash\ncase " $* " in *" --git-common-dir "*)\n  rm -f -- "%s/lane-mail-check.sh"\n  rmdir -- "%s" 2>/dev/null || :\n  ;;\nesac\nexec %s "$@"\n' \
  "$LANE/.claude/hooks" "$LANE/.claude/hooks" "$(command -v git)" > "$GIT_SHIM/git"
chmod +x "$GIT_SHIM/git"
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false "PATH=$GIT_SHIM:$PATH"
assert_eq "RC=$RC first=$(first_line) named=$(grep -c 'could not be resolved' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-skipped=unlocatable named=1" \
  "a hook whose own directory went away reports the gap under the value no path can fill"
assert_eq "$(grep -c 'No such file or directory' "$ERR_FILE")" "1" \
  "and cd's own words are replayed UNDER the keyed line, never ahead of it"

# The same library absent rather than stale. It takes the key whose text says
# the file is not there and names installing the orch skill, because the repair
# the unanswered key names, a settings line, would send the operator to
# .env.local for a file nothing put on disk. Its install shape is the one a
# refresh older than the library leaves: a lib directory carrying every sibling
# and not this one.
new_handoff_lane handoff_absent_library KEN-90
plant_install lib
mkdir -p "$LANE/.claude/skills/orch/scripts/lib"
for name in "$REPO_ROOT/skills/orch/scripts/lib"/*.sh; do
  [ "${name##*/}" != lane-context.sh ] || continue
  ln -s -f -n "$name" "$LANE/.claude/skills/orch/scripts/lib/${name##*/}"
done
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) absent=$(grep -c 'is not there' "$ERR_FILE") stale=$(grep -c 'is there but did not answer' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-skipped=$LANE/.claude/skills/orch/scripts/lib/lane-context.sh absent=1 stale=0" \
  "a library the install has not got is reported as absent, never as one that would not answer"

# A library bash cannot parse. Its syntax errors are written as bash reads the
# file, so an unredirected source would put them AHEAD of the keyed line, which
# is the one thing this hook's output contract forbids.
new_handoff_lane handoff_broken_library KEN-87
plant_install lib
mkdir -p "$LANE/.claude/skills/orch/scripts/lib"
for name in "$REPO_ROOT/skills/orch/scripts/lib"/*.sh; do
  [ "${name##*/}" != lane-context.sh ] || continue
  ln -s -f -n "$name" "$LANE/.claude/skills/orch/scripts/lib/${name##*/}"
done
printf '# shellcheck shell=bash\nthis is ( not shell\n' \
  > "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
write_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'syntax error' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/lib/lane-context.sh cause=1" \
  "a library bash cannot parse is reported with its words UNDER the keyed line, never above it"

# The same library present and unreadable. The source is the one probe that
# answers, so it is run rather than guarded by a readability test: failing it
# writes bash's own permission error to the file the arm replays, where a test
# ahead of it would leave that cause empty under a line that promises one.
if [ "${CAN_DENY_READS:?}" -eq 1 ]; then
  chmod 000 "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
  stop_at "$TRANSCRIPT" false
  chmod 644 "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
  assert_eq "RC=$RC first=$(first_line) cause=$(grep -ci 'permission denied' "$ERR_FILE")" \
    "RC=0 first=lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/lib/lane-context.sh cause=1" \
    "a library that cannot be read is reported with bash's own words, never with an empty cause"
else
  printf '  skip  a library that cannot be read: running as root, which reads a mode-000 file\n'
fi

# The account mark can fire on a lane's first turn end, before any workflow has
# run init, and `set` refuses a state file that is not there. The refusal has
# to carry the init that makes one, so the lane can act on it and nothing else.
new_lane handoff_uninit ken-66
mkdir -p "$LANE/tmp/lane-mail/KEN-66"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" "a lane with no state file is refused at the mark"
INIT_CMD="$(grep -F -- "workflow-state init KEN-66" "$ERR_FILE")"
assert_eq "$([ -n "$INIT_CMD" ] && echo named || echo absent)" "named" \
  "the refusal names the init that set needs"
(cd "$LANE" && eval "$INIT_CMD" > /dev/null)
stop_at "$TRANSCRIPT" false
assert_eq "RC=$RC first=$(first_line) init=$(grep -cF -- "workflow-state init KEN-66" "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: context=600000 init=0" \
  "the init it named makes the state, and the next refusal drops that line"
record_handoff KEN-66
stop_at "$TRANSCRIPT" false
expect 0 - "the set it named then clears the mark"

# The same refusal on a lane with no branch to name: LANE_MAIL_ITEM selects the
# item and HEAD is detached, so the init line carries no --branch and must
# still be a command the lane can run.
new_lane handoff_detached ken-82
mkdir -p "$LANE/tmp/lane-mail/KEN-82"
mark_lane KEN-82
git -C "$LANE" checkout -q --detach
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false LANE_MAIL_ITEM=KEN-82
expect 2 "lane-mail-check: context=600000" "a detached lane the brief named is refused at the mark"
INIT_CMD="$(grep -F -- "workflow-state init KEN-82" "$ERR_FILE")"
assert_eq "$([ -n "$INIT_CMD" ] && echo named || echo absent) branch=$(grep -cF -- '--branch' "$ERR_FILE")" \
  "named branch=0" "the refusal names an init with no branch where HEAD names none"
(cd "$LANE" && eval "$INIT_CMD" > /dev/null)
record_handoff KEN-82
stop_at "$TRANSCRIPT" false LANE_MAIL_ITEM=KEN-82
expect 0 - "and the init it named is a command that runs, so the record clears the mark"

# The third route into the marks: a mailbox written and read, so the reader
# reports a count with nothing unread under it.
new_handoff_lane handoff_read KEN-64
send KEN-64 'Rebase first.'
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: unread=1" "the directive refuses the turn end before any mark is judged"
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "a lane whose mailbox has been read is judged on the marks at its next turn end"

# --- the overseer's own turn end ------------------------------------------
# The fleet's overseer is no lane: it carries no launch marker, no claim and no
# item of its own, so every rule above passed it in silence and it rode past
# 500 thousand tokens with the fleet unattended. It meets two marks of its own
# here, and this hook judges neither: `oversee-succeed --check-marks` decides
# where they sit and what this session's pane and account say, and the rows
# below are about which of its answers refuses a turn end and which ends one.
#
# What establishes an overseer is the pane: `oversee-watch` records the
# overseer's tmux server and pane in the fleet state, and a session whose own
# pane key is that pair is that overseer. The tmux stub below is the one read
# that asks — the server a pane belongs to, which the orch library pairs with
# $TMUX_PANE.
TMUX_BIN="$TMP_ROOT/tmux-bin"
mkdir -p "$TMUX_BIN"
cat > "$TMUX_BIN/tmux" <<'TMUXSTUB'
#!/bin/sh
# `display-message -p -t <pane> '#{pid}'` and nothing else: TMUX_SERVER_ID is
# what this fixture's server answers, and no value at all is a pane tmux cannot
# resolve, which is every session outside a live server.
[ -n "${TMUX_SERVER_ID:-}" ] || { echo "can't find pane" >&2; exit 1; }
printf '%s\n' "$TMUX_SERVER_ID"
TMUXSTUB
chmod +x "$TMUX_BIN/tmux"

OVERSEER_PANE=%9
OVERSEER_SERVER=7000

# The judge, and the whole of what this hook reads about an overseer's marks.
# It records its argv, so a row can pin that the hook asked for the judgement
# and nothing else, and answers from files a row writes: `out` its keyed line,
# `rc` its exit status, `err` its own words, `hang` a read that outlasts the
# hook's ceiling. Its own behaviour is oversee_succeed.sh's subject.
JUDGE_DIR="$TMP_ROOT/judge"
mkdir -p "$JUDGE_DIR"
plant_judge() {
  plant_install oversee-succeed
  cat > "$LANE/.claude/skills/orch/scripts/oversee-succeed" <<JUDGE
#!/bin/sh
printf '%s\n' "\$*" >> "$JUDGE_DIR/args"
# stdout is handed away before the wait: the hook reads this in a command
# substitution, which stays open while any writer holds that pipe, so a sleep
# left behind by the ceiling would outlast the kill.
[ ! -f "$JUDGE_DIR/hang" ] || { exec 1>/dev/null; sleep 120; }
[ ! -f "$JUDGE_DIR/err" ] || cat "$JUDGE_DIR/err" >&2
[ ! -f "$JUDGE_DIR/out" ] || cat "$JUDGE_DIR/out"
exit "\$(cat "$JUDGE_DIR/rc" 2>/dev/null || echo 0)"
JUDGE
  chmod +x "$LANE/.claude/skills/orch/scripts/oversee-succeed"
  rm -f -- "${JUDGE_DIR:?}/args" "${JUDGE_DIR:?}/out" "${JUDGE_DIR:?}/err" \
    "${JUDGE_DIR:?}/rc" "${JUDGE_DIR:?}/hang"
}
judge_says() { printf '%s\n' "$1" > "$JUDGE_DIR/out"; }
judge_calls() { [ -f "$JUDGE_DIR/args" ] && wc -l < "$JUDGE_DIR/args" | tr -d ' ' || echo 0; }
judge_argv() { cat "$JUDGE_DIR/args" 2>/dev/null || true; }

CONTEXT_MARK_LINE="oversee-succeed: mark-reached kind=context value=612000 mark=500000 succession=on headroom=80"
# The same crossing with the succession the operator turned off, which the
# judgement reports on its own line and this hook reads nowhere else.
OFF_MARK_LINE="oversee-succeed: mark-reached kind=context value=612000 mark=500000 succession=off headroom=80"
HEADROOM_MARK_LINE="oversee-succeed: mark-reached kind=headroom value=4 mark=10 succession=on account=eclaude resets=2026-07-27T06:00:00Z"
RATE_MARK_LINE="oversee-succeed: mark-reached kind=rate value=30 mark=30 succession=on account=eclaude"
QUALIFYING_MARK_LINE="oversee-succeed: mark-reached kind=qualifying value=1 mark=1 succession=on"
BELOW_MARK_LINE="oversee-succeed: context-below-mark tokens=100000 mark=500000 headroom=80"

# An overseer session: a repository on a branch no mailbox is named for, so the
# lane rules find nothing, with the orch install and the judge beside the hook
# and a fleet state whose `.overseer` names this pane.
new_overseer() { # NAME [PANE] [SERVER]
  new_lane "$1" main
  unclaim
  plant_judge
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
  record_overseer "${2:-$OVERSEER_PANE}" "${3:-$OVERSEER_SERVER}"
}

record_overseer() { # PANE SERVER
  local record
  record="$(jq -nc --arg s "$2" --arg p "$1" \
    '{server: $s, pane: $p, window: "@7", launch_line: "claude -n overseer"}')"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" \
    set oversee overseer "$record" >/dev/null)
}

# The environment a session inside the overseer's own pane carries.
overseer_env() { # [PANE]
  printf '%s\n' "PATH=$TMUX_BIN:$PATH" "TMUX=fake" "TMUX_PANE=${1:-$OVERSEER_PANE}" \
    "TMUX_SERVER_ID=$OVERSEER_SERVER"
}

# The record that ends an overseer's refusal, written on the fleet's own item.
# It names the session that wrote it in both of the two names this hook reads,
# the payload's id and the pane key, and a row supplies another value for
# whichever name it is about.
record_overseer_handoff() { # [SESSION_ID] [PANE_KEY]
  local record
  record="$(jq -nc --arg s "${1:-s1}" --arg k "${2:-$OVERSEER_SERVER $OVERSEER_PANE}" \
    '{written_at:"2026-09-20T06:20:00Z",handoff_file:"tmp/handoffs/OVERSEER-HANDOFF.md",
      pane_key:$k,session_id:$s}')"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set oversee handoff \
    "$record" >/dev/null)
}

# A turn end from a harness whose payload names no session, which is what sends
# this hook to the pane key.
stop_unnamed() { # [ENV=VAL...]
  run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
    '{stop_hook_active:false,transcript_path:$p}')" "$@"
}

# The two commands an overseer's refusal names, counted in the stderr it wrote.
overseer_route() { grep -cF -- "/oversee-succeed -- [THE PERMISSION" "$ERR_FILE"; }
overseer_record_named() { grep -cF -- "workflow-state set oversee handoff " "$ERR_FILE"; }

new_overseer overseer_context
judge_says "$BELOW_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 0 - "an overseer the judgement puts under both marks ends its turn"
assert_eq "$(judge_argv)" "--check-marks" \
  "and the hook asked for the judgement and nothing else, opening no window" "$ERR_FILE"
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "an overseer the judgement puts at the context mark is refused with the figure it read"
assert_eq "route=$(overseer_route) record=$(overseer_record_named)" "route=1 record=1" \
  "the refusal names the succession as the route, with the record that clears a succession that refuses"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" true $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "and repeats on the continued turn, as a lane's does"
record_overseer_handoff
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) judged=$(judge_calls)" "RC=0 first=- judged=3" \
  "an overseer whose own handoff record stands ends its turn, and the judgement is not even asked"
# The fleet item is one item, shared by every overseer of the fleet in turn. A
# record the session before this one wrote and exited on answers for nobody
# here: the replacement a refused succession leaves the operator to start by
# hand would otherwise ride past both its marks in silence for its whole life,
# in the predecessor's own pane.
record_overseer_handoff other-session
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "a record another session wrote holds nobody, so this overseer meets the mark"
assert_eq "record=$(overseer_record_named) named=$(grep -cF -- '"session_id":"s1"' "$ERR_FILE")" \
  "record=1 named=1" "and the record it is told to write names this session"
assert_eq "$(grep -cF -- "\"pane_key\":\"$OVERSEER_SERVER $OVERSEER_PANE\"" "$ERR_FILE")" "1" \
  "with the pane key beside it, for a harness that names no session" "$ERR_FILE"

# Where the payload names no session the pane key answers, which tells a
# successor in ANOTHER pane from the writer and is all that is available there.
new_overseer overseer_unnamed_session
judge_says "$CONTEXT_MARK_LINE"
record_overseer_handoff "" "$OVERSEER_SERVER $OVERSEER_PANE"
# shellcheck disable=SC2046
stop_unnamed $(overseer_env)
expect 0 - "a record carrying this session's own pane key ends the turn of a payload with no id"
record_overseer_handoff "" "$OVERSEER_SERVER %4"
# shellcheck disable=SC2046
stop_unnamed $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "and one carrying another pane's key holds nobody"

# The account mark is the judge's own, on the judge's own setting: this hook
# reads neither, so the figure and the mark it names come off that one line.
new_overseer overseer_headroom
judge_says "$HEADROOM_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: headroom=4" \
  "an overseer the judgement puts at its account mark is refused with the headroom it read"
assert_eq "named=$(grep -cF -- 'the ORCH_OVERSEER_HEADROOM_PCT mark of 10' "$ERR_FILE") route=$(overseer_route)" \
  "named=1 route=1" "and the refusal names the judge's own setting and the succession"

for mark_row in \
  "rate|$RATE_MARK_LINE|30|ORCH_OVERSEER_WALL_MINUTES" \
  "qualifying|$QUALIFYING_MARK_LINE|1|ORCH_OVERSEER_SUCCESSOR_ACCOUNTS"; do
  IFS='|' read -r mark_kind mark_line mark_value mark_setting <<<"$mark_row"
  new_overseer "overseer_$mark_kind"
  judge_says "$mark_line"
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env)
  expect 2 "lane-mail-check: $mark_kind=$mark_value" \
    "an overseer at its $mark_kind mark is refused with the value it read"
  assert_eq "setting=$(grep -cF -- "$mark_setting" "$ERR_FILE") route=$(overseer_route)" \
    "setting=1 route=1" "and the refusal names the setting and succession route"
done

# What the marks cannot judge is reported and passed, never refused: an
# overseer whose marks nothing could measure must still end a turn, exactly as
# a lane whose account nothing measured does.
new_overseer overseer_gaps
judge_says "oversee-succeed: mark-unmeasured kind=headroom reason=headroom-unreadable succession=on"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 0 "lane-mail-check: marks=unmeasured" \
  "a reading the judgement could not take is reported and the turn ends"
assert_eq "$(grep -cF -- "reason=headroom-unreadable" "$ERR_FILE")" "1" \
  "with the judge's own line under it, naming the figure that was missing"
printf '3\n' > "$JUDGE_DIR/rc"
printf 'oversee-succeed: pane-unreadable pane=%s\n' "$OVERSEER_PANE" > "$JUDGE_DIR/err"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) cause=$(grep -c 'oversee-succeed: pane-unreadable' "$ERR_FILE")" \
  "RC=0 first=lane-mail-check: marks=unjudged cause=1" \
  "a judgement that did not answer is reported with its own words and the turn ends"
rm -f -- "${JUDGE_DIR:?}/rc" "${JUDGE_DIR:?}/err"
judge_says "oversee-succeed: mark-reached kind=context mark=500000 succession=on"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 0 "lane-mail-check: marks=unjudged" \
  "a reached mark naming no figure is an answer this hook cannot act on, and the turn ends"

# The judgement reads every account the fleet can launch on, which can outlast
# this hook's budget; a hook killed at its budget writes no line at all.
if command -v timeout >/dev/null 2>&1; then
  variant short-real-judge -e 's@^ACCOUNT_CEILING=20$@ACCOUNT_CEILING=3@'
  new_overseer overseer_fast_context
  install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
  rm -f -- "$LANE/.claude/skills/orch/scripts/oversee-succeed" \
    "$LANE/.claude/skills/orch/scripts/lanes"
  ln -s "$REPO_ROOT/skills/orch/scripts/oversee-succeed" \
    "$LANE/.claude/skills/orch/scripts/oversee-succeed"
  cat > "$LANE/.claude/skills/orch/scripts/lanes" <<'SLOWCAPACITY'
#!/bin/sh
case " $* " in
  *" --lane "*)
    printf '%s\n' '{"wall":20,"alias":"claude","binding_resets_at":"2026-09-24T00:00:00Z","usage_rate_state":"not-increasing","projected_wall_minutes":null}'
    ;;
  *) sleep 120 ;;
esac
SLOWCAPACITY
  chmod +x "$LANE/.claude/skills/orch/scripts/lanes"
  REAL_TMUX_BIN="$TMP_ROOT/real-tmux-bin"; mkdir -p "$REAL_TMUX_BIN"
  cat > "$REAL_TMUX_BIN/tmux" <<'REALTMUX'
#!/bin/sh
case " $* " in
  *"#{pid}"*) printf '%s\n' "$FIXTURE_TMUX_SERVER" ;;
  *"#{window_id}"*) printf '%s\n' '@7' ;;
  *"#{pane_current_path}"*) printf '%s\n' "$FIXTURE_TMUX_PATH" ;;
  *"#{pane_current_command}"*) printf '%s\n' claude ;;
  *" capture-pane "*) printf '%s\n' '  kendex (ken-1453) Fable 5.1 (1M context) 52% (fixture@example.com)     /rc' ;;
  *) exit 1 ;;
esac
REALTMUX
  chmod +x "$REAL_TMUX_BIN/tmux"
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env) "PATH=$REAL_TMUX_BIN:$PATH" \
    "FIXTURE_TMUX_SERVER=$OVERSEER_SERVER" "FIXTURE_TMUX_PATH=$LANE" \
    "ORCH_OVERSEER_SUCCESSOR_ACCOUNTS=1"
  expect 2 "lane-mail-check: context=520000" \
    "a real hook returns an available context mark before a slow capacity sweep reaches its ceiling"

  variant short-judge -e 's@^ACCOUNT_CEILING=20$@ACCOUNT_CEILING=1@'
  new_overseer overseer_ceiling
  install_hook "$VARIANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
  judge_says "$CONTEXT_MARK_LINE"
  touch "$JUDGE_DIR/hang"
  # shellcheck disable=SC2046
  stop_at "$TRANSCRIPT" false $(overseer_env)
  expect 0 "lane-mail-check: marks=timeout" \
    "a judgement that passes the ceiling is reported as a gap and the turn ends"
  rm -f -- "${JUDGE_DIR:?}/hang"
else
  printf '  skip  a judgement past the ceiling: this host has no timeout to bound it with\n'
fi

# What is NOT an overseer. Each row is the same session, the judgement standing
# at a reached mark, with one leg of the identification missing, and each must
# end its turn in silence without the judgement being asked at all: a test that
# took every session with no lane for the overseer would hold an ordinary
# session's turn end on marks nobody set for it.
new_overseer overseer_identity
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env "%3")
assert_eq "RC=$RC first=$(first_line) judged=$(judge_calls)" "RC=0 first=- judged=0" \
  "a pane the fleet state does not name is no overseer and is judged on nothing"
record_overseer "$OVERSEER_PANE" 7001
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 0 - "the same pane id on another tmux server is another session, not this overseer"
record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER"
stop_at "$TRANSCRIPT" false "PATH=$TMUX_BIN:$PATH"
expect 0 - "a session outside tmux has no pane to be the overseer's"
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) judged=$(judge_calls)" "RC=0 first=- judged=0" \
  "a fleet state recording no overseer names nobody, so nobody is judged"

# The mailbox rules are untouched: an overseer's checkout carries the fleet's
# own mailbox directory, and its branch names no mailbox in it.
new_overseer overseer_mailbox
mkdir -p "$LANE/tmp/lane-mail/overseer"
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "the fleet mailbox in the overseer's own checkout names no lane, and the marks are judged"

# Succession off is the route turned off, and a refusal whose route is off is a
# turn end nothing the overseer does can reach. The setting is read off the
# judgement's own line and nowhere else, so a spelling this hook would take for
# `on` and that script refuses cannot exist. The watch still reports the mark,
# so the fleet is not left silent by this.
new_overseer overseer_succession_off
judge_says "$OFF_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "a crossing whose line says the succession is off ends the turn"
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env) ORCH_OVERSEER_SUCCESSION=off
expect 2 "lane-mail-check: context=612000" \
  "and the setting in the environment decides nothing here: the line does"

# The command the overseer's route names has to be in the install, or the
# refusal sends it to one it has not got.
new_overseer overseer_script
plant_install oversee-succeed
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line) record=$(overseer_record_named)" \
  "RC=2 first=lane-mail-check: script=$LANE/.claude/skills/orch/scripts/oversee-succeed record=1" \
  "an install with no oversee-succeed is refused, with the record that still clears it"

# A subagent of the overseer runs its own window on its own turn, as a lane's
# does.
new_overseer overseer_subagent
judge_says "$CONTEXT_MARK_LINE"
run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
  '{session_id:"s1",stop_hook_active:false,agent_id:"a1",transcript_path:$p}')" \
  $(overseer_env)
assert_eq "RC=$RC first=$(first_line) judged=$(judge_calls)" "RC=0 first=- judged=0" \
  "a subagent of the overseer is judged on neither mark"

mutant() { # NAME SED-ARGUMENT... — MUTANT_SOURCE names a file other than the hook
  MUTANT_PATH="$TMP_ROOT/$1.sh"
  local name="$1" source="${MUTANT_SOURCE:-$HOOK}"
  shift
  sed "$@" "$source" > "$MUTANT_PATH"
  assert_eq "$(cmp -s "$MUTANT_PATH" "$source" && echo same || echo differs)" "differs" \
    "control: the $name mutant really differs from the hook"
}

mutant no-block -e 's@^  message unread "\$COUNT"$@  exit 0@'
BLOCK_MUTANT="$MUTANT_PATH"
new_lane control ken-11
send KEN-11 'Block me.'
install_hook "$BLOCK_MUTANT" "$LANE/.claude/hooks/lane-mail-check.sh"
stop
expect 0 - "control: without its refusal the hook lets the turn end with the message unread"

mutant unbound -e 's@^  \[ "\$BOUND" != "\$ROOT" \] || LAUNCHED=yes$@  LAUNCHED=yes@'
unlaunched control_unmarked KEN-22 "" "$MUTANT_PATH"
expect 2 "lane-mail-check: unread=1" "control: without the marker rule a committed mailbox poses as a lane"

# The acknowledgement moved ahead of the refusal, both still made: killed
# between them, the hook has consumed a directive it never showed.
mutant ack-first -e '/^  message unread "\$COUNT"$/d' \
  -e '/--ack "\$LINES"/,$ s@^  exit 2$@  message unread "$COUNT"; exit 2@'
killed_stop control_killed KEN-19 2 "$MUTANT_PATH"
assert_eq "$KILLED" "lost" "control: acknowledged before its refusal, a killed hook consumes the directive unseen"

# The containment rule's control: its refusal arm replaced by the assignment
# it guards, so the repository's script runs and leaves its marker.
mutant no-containment -e 's@^        return 2$@        READER="$ROOT/.agents/skills/orch/scripts/lane-mail"@'
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
  -e 's@^    \[ ! -x "\$CANDIDATE" \] || READER="\$CANDIDATE"$@    :@'
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

tool() { # ARM [COMMAND] [FIELD] — FIELD, agent_id or agent_type, marks a subagent's call
  local judge="$CASE_HOOK"
  CASE_HOOK="$LANE/.claude/hooks/lane-mail-$1.sh"
  run_payload "$(jq -nc --arg c "${2:-git status}" --arg f "${3:-}" \
    '{tool_name: "Bash", tool_input: {command: $c}} + (if $f == "" then {} else {($f): "dev-1"} end)')"
  CASE_HOOK="$judge"
}

# The event a deliver run's JSON names and the first line of the context it
# carries; `-` for no output.
context_line() {
  [ -s "$TMP_ROOT/stdout" ] || { echo -; return; }
  jq -r '"\(.hookSpecificOutput.hookEventName) \(.hookSpecificOutput.additionalContext | split("\n")[0])"' "$TMP_ROOT/stdout"
}

# An install with no orch skill beside the hook and nothing in the mailbox:
# there is nothing to hand over and nothing to record a handoff with either, so
# every arm ends rather than holding a lane it cannot help.
new_lane noreader_empty ken-60
mkdir -p "$LANE/tmp/lane-mail/KEN-60"
install_arms
rm -f "$LANE/.claude/skills/orch" "$LANE/.agents/skills/orch/scripts"
EMPTY_READER="$LANE/.agents/skills/orch/scripts/lane-mail"
stop
expect 0 "lane-mail-check: handoff-skipped=$EMPTY_READER" \
  "a launched lane with an empty mailbox and no reader ends its turn, reporting the gap"
tool deliver
assert_eq "RC=$RC context=$(context_line) stderr=$(first_line)" "RC=0 context=- stderr=-" \
  "the same lane's finished tool call carries nothing and says nothing"
tool halt
expect 0 - "the same lane's next tool call runs"

# A reader the open repository supplies, on a lane with an empty mailbox: the
# marks cannot be judged with a script this hook is not installed beside, and
# that gap has its own key. Sent to install a skill, an operator whose skill is
# installed inside the repository would look for a fault that is not there.
new_lane outside_empty ken-64
mkdir -p "$LANE/tmp/lane-mail/KEN-64"
OUTSIDE_READER="$LANE/.agents/skills/orch/scripts/lane-mail"
plant_reader "$TMP_ROOT/outside-empty-ran"
install_hook "$HOOK" "$TMP_ROOT/outside-empty/hooks/lane-mail-check.sh"
stop
assert_eq "RC=$RC first=$(first_line) ran=$([ -e "$TMP_ROOT/outside-empty-ran" ] && echo ran || echo not-run)" \
  "RC=0 first=lane-mail-check: handoff-outside=$OUTSIDE_READER ran=not-run" \
  "a reader only the open repository supplies leaves the marks unjudged under its own key, unrun"

new_lane arms ken-30
install_arms
send KEN-30 'Rebase first.'
tool halt
expect 0 - "an unread directive that is no halt passes the tool call"
tool deliver
assert_eq "RC=$RC context=$(context_line) stderr=$(first_line)" \
  "RC=0 context=PostToolUse lane-mail-check: unread=1 stderr=-" \
  "a directive reaches a working lane in the context its next tool call's hook output carries"
assert_eq "$(jq -r '.hookSpecificOutput.additionalContext' "$TMP_ROOT/stdout" | grep -cF 'Rebase first.')" "1" \
  "that context carries the directive itself"
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" "a finished tool call with nothing unread carries nothing"

send KEN-30 'Stop pushing.' --halt
HALT_ID=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-30/to-lane.jsonl")
printf -v READ_HALT '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-30 "$LANE"
tool halt
expect 2 "lane-mail-check: halt=$HALT_ID" "an unread halt refuses the next tool call"
assert_eq "directive=$(grep -cF 'Stop pushing.' "$ERR_FILE") command=$(grep -cxF -- "$READ_HALT" "$ERR_FILE")" \
  "directive=1 command=1" "the halt refusal carries the directive and the one command that reads it"
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

# A mailbox refusal carries no handoff instruction and pays for none. The
# instruction is built at its own site, so nothing below the reader resolves
# runs `workflow-state` to decide whether the item has a state file yet.
new_lane halt_no_state ken-88
mkdir -p "$LANE/tmp/lane-mail/KEN-88"
install_arms
plant_install workflow-state
STATE_LOG="$TMP_ROOT/halt-state-calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s\nexit 3\n' "$STATE_LOG" \
  > "$LANE/.claude/skills/orch/scripts/workflow-state"
chmod +x "$LANE/.claude/skills/orch/scripts/workflow-state"
send KEN-88 'Stop here.' --halt
HALT_88=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-88/to-lane.jsonl")
tool halt
assert_eq "RC=$RC first=$(first_line) state=$([ -s "$STATE_LOG" ] && echo ran || echo none)" \
  "RC=2 first=lane-mail-check: halt=$HALT_88 state=none" \
  "a halt refusal runs no workflow-state: it carries no instruction to build"

# Lane mail is the lead's: a subagent's call, marked by either field a harness
# sends, neither takes it nor clears a halt.
for row in agent_id:KEN-36 agent_type:KEN-37; do
  field=${row%%:*} item=${row#*:}
  new_lane "sub_$field" "$(printf '%s' "$item" | tr 'A-Z' 'a-z')"
  install_arms
  send "$item" 'Rebase again.'
  tool deliver "git status" "$field"
  tool deliver
  assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: unread=1" \
    "a subagent's call marked by $field leaves the directive unread for the lead's next call"
  send "$item" 'Stop again.' --halt
  SUB_HALT=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/$item/to-lane.jsonl")
  printf -v SUB_READ '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" "$item" "$LANE"
  tool halt "$SUB_READ" "$field"
  expect 2 "lane-mail-check: halt=$SUB_HALT" \
    "a subagent's call marked by $field carrying the acknowledging command is refused while a halt stands"
  tool halt
  expect 2 "lane-mail-check: halt=$SUB_HALT" "the halt still stands for the lead after the $field refusal"
done

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

# The judges read the lane's own mailbox whatever checkout a call is made
# from: a lane runs its post-merge steps from the main clone, which has no
# mailbox of its own. Claude Code names the directory the session started in;
# a harness that names none reaches the lane through the claim for the item its
# brief set. With neither the call's own checkout answers, and the main clone
# is no lane.
new_worktree_lane from_main ken-95
install_arms
send KEN-95 'Hold the merge.' --halt
HALT_95=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-95/to-lane.jsonl")
CALL_DIR="$MAIN"
# Each row: the variable the harness sets, the status, the keyed line, and
# what names the lane. `NO_LANE=` sets nothing the hook reads.
for row in "CLAUDE_PROJECT_DIR=$LANE|2|lane-mail-check: halt=$HALT_95|the directory the harness started in" \
  "LANE_MAIL_ITEM=KEN-95|2|lane-mail-check: halt=$HALT_95|the claim for the brief's item" \
  "NO_LANE=|0|-|nothing, so the main clone answers and is no lane"; do
  CALL_ENV=("${row%%|*}")
  rest=${row#*|}
  want_rc=${rest%%|*}
  rest=${rest#*|}
  tool halt
  expect "$want_rc" "${rest%%|*}" "a halt judge run from the main clone reads the lane through ${rest#*|}"
done
CALL_ENV=("CLAUDE_PROJECT_DIR=$LANE")
tool halt
ACK_95=$(sed -n 3p "$ERR_FILE")
printf -v READ_95 '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-95 "$LANE"
assert_eq "$ACK_95" "$READ_95" "the halt refusal names the lane's root in the command that reads it"
(cd "$MAIN" && env -u CLAUDE_PROJECT_DIR bash -c "$ACK_95" >/dev/null)
tool halt
expect 0 - "that command run from the main clone reads the halt, and the next call passes"
send KEN-95 'Rebase first.'
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=PostToolUse lane-mail-check: unread=1" \
  "a deliver judge run from the main clone hands the lane its directive"
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" \
  "and acknowledges it in the lane's own mailbox, so the next call carries nothing"
CALL_DIR=""
CALL_ENV=()

# A root a launch claimed with no mailbox directory: every arm refuses it,
# naming the claim, and the one command that restores the directory passes.
new_lane claimed_no_mailbox ken-96
install_arms
CLAIM_96="$LANE/.git/lane-mail/ken-96"
printf -v MKDIR_96 'mkdir -p -- %q' "$LANE/tmp/lane-mail"
tool halt
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "a claimed root with no mailbox directory refuses the next tool call"
assert_eq "claim=$(grep -cF -- "$CLAIM_96" "$ERR_FILE") command=$(grep -cxF -- "$MKDIR_96" "$ERR_FILE")" \
  "claim=1 command=1" "the refusal names the claim and the one command that restores the mailbox"
tool halt "$MKDIR_96" agent_id
assert_eq "RC=$RC first=$(first_line) command=$(grep -cxF -- "$MKDIR_96" "$ERR_FILE")" \
  "RC=2 first=lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail command=0" \
  "a subagent's call carrying that command is refused and is never shown it"
stop_active
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "the continued turn is refused too: the lane clears it with one command"
tool halt "$MKDIR_96"
expect 0 - "the lead's call running that command passes"
(cd "$LANE" && bash -c "$MKDIR_96")
tool halt
expect 0 - "once the directory stands the next call passes"
unclaim
rmdir "$LANE/tmp/lane-mail"
tool halt
expect 0 - "a root with neither a claim nor a mailbox directory passes a tool call silently"

# The directory the harness started in dropped: the judge asks the call's cwd.
mutant no-project-dir -e 's@^LANE_DIR=\${CLAUDE_PROJECT_DIR:-\.}$@LANE_DIR=.@'
new_worktree_lane control_from_main ken-97
install_arms "$MUTANT_PATH"
send KEN-97 'Hold the merge.' --halt
CALL_DIR="$MAIN"
CALL_ENV=("CLAUDE_PROJECT_DIR=$LANE")
tool halt
expect 0 - "control: without the harness's directory a halt judge run from the main clone passes the call"
# The root dropped from the reader's peek: the reader roots itself at the call's
# cwd and reads the main clone.
mutant peek-no-root -e 's@inbox --item "\$ITEM" --root "\$ROOT" --peek@inbox --item "$ITEM" --peek@'
install_arms "$MUTANT_PATH"
tool halt
expect 0 - "control: without the root the reader's peek from the main clone finds nothing and passes the call"
# The claim read dropped: LANE_MAIL_ITEM no longer reaches the lane's root.
mutant no-claim-root -e 's@|| ROOT="\$BOUND"$@|| :@'
install_arms "$MUTANT_PATH"
CALL_ENV=("LANE_MAIL_ITEM=KEN-97")
tool halt
expect 0 - "control: without the claim read a harness naming no directory passes the call"
# The read command written without the root: run from the main clone, it
# reads the main clone and the halt stands.
mutant ack-no-root -e 's@'"'"'%q inbox --item %q --root %q'"'"' "\$READER" "\$ITEM" "\$ROOT"@'"'"'%q inbox --item %q'"'"' "$READER" "$ITEM"@'
install_arms "$MUTANT_PATH"
CALL_ENV=("CLAUDE_PROJECT_DIR=$LANE")
tool halt
(cd "$MAIN" && env -u CLAUDE_PROJECT_DIR bash -c "$(sed -n 3p "$ERR_FILE")" >/dev/null 2>&1) || :
tool halt
expect 2 "lane-mail-check: halt=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-97/to-lane.jsonl")" \
  "control: without the root in it the command run from the main clone leaves the halt standing"
CALL_DIR=""
CALL_ENV=()

# The refusal replaced by a pass, and the command's pass removed.
mutant no-mailbox-missing -e 's@^    refuse mailbox-missing "\$MAIL_ROOT"$@    exit 0@'
new_lane control_no_mailbox ken-98
install_arms "$MUTANT_PATH"
tool halt
expect 0 - "control: without its refusal a claimed root with no mailbox passes the call"
mutant no-mailbox-pass -e 's@^    lead_runs "\$MAILBOX_COMMAND" && exit 0$@    :@'
install_arms "$MUTANT_PATH"
printf -v MKDIR_98 'mkdir -p -- %q' "$LANE/tmp/lane-mail"
tool halt "$MKDIR_98"
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "control: without its pass the one command that restores the mailbox is refused"

# A condition the lane cannot clear without a tool call: before a tool call
# it is reported and the call runs, where a fresh turn end refuses it.
new_lane halt_workdir ken-36
install_arms
ARM_ARGS=(halt)
run_payload '{"tool_name":"Bash","tool_input":{"command":"git status"}}' "TMPDIR=$TMP_ROOT/absent"
ARM_ARGS=()
expect 0 "lane-mail-check: workdir=$TMP_ROOT/absent" \
  "a work directory the halt arm cannot make is reported and the tool call runs"
stop "TMPDIR=$TMP_ROOT/absent"
expect 2 "lane-mail-check: workdir=$TMP_ROOT/absent" \
  "control: the same condition refuses a fresh turn end"

# The halt refusal replaced by a pass, its judgement still made.
mutant no-halt -e 's@^    refuse halt "\$HALT_ID"$@    exit 0@'
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
tool deliver "git status" agent_id
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" \
  "control: without the deliver check a subagent's call consumes the lead's directive"
mutant lead-halt -e 's@^  { \[ "\$ARM" = halt \] && \[ "\$CALLER" = lead \]; } || return 1$@  [ "$ARM" = halt ] || return 1@'
new_lane control_sub_halt ken-35
install_arms "$MUTANT_PATH"
send KEN-35 'Halt the lead.' --halt
printf -v SUB_READ '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-35 "$LANE"
tool halt "$SUB_READ" agent_id
expect 0 - "control: without the halt check a subagent's call carrying the acknowledging command passes"

# The agent_type read dropped, agent_id still read: a subagent the pi-hooks
# carrier marks is judged as the lead.
mutant no-agent-type -e 's@str(\.agent_id) + str(\.agent_type) == ""@str(.agent_id) == ""@'
new_lane control_sub_type ken-38
install_arms "$MUTANT_PATH"
send KEN-38 'For the lead.'
tool deliver "git status" agent_type
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" \
  "control: without the agent_type read a subagent's call consumes the lead's directive"
send KEN-38 'Halt the lead.' --halt
printf -v SUB_READ '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-38 "$LANE"
tool halt "$SUB_READ" agent_type
expect 0 - "control: without the agent_type read a subagent's call carrying the acknowledging command passes"

# The deliver context written without its envelopes, the keyed line kept.
mutant no-envelopes -e 's@^    NOTICE=\$(message unread "\$COUNT" 2>&1)$@    NOTICE=$(UNREAD= message unread "$COUNT" 2>\&1)@'
new_lane control_envelopes ken-39
install_arms "$MUTANT_PATH"
send KEN-39 'Rebase first.'
tool deliver
assert_eq "context=$(context_line) carried=$(jq -r '.hookSpecificOutput.additionalContext' "$TMP_ROOT/stdout" | grep -cF 'Rebase first.')" \
  "context=PostToolUse lane-mail-check: unread=1 carried=0" \
  "control: without its envelopes the deliver context keeps its key and loses the directive"

# The halt refusal written without the acknowledging command.
mutant no-ack-command -e 's@"\$ACK_COMMAND" "\$HALT_TEXT"@"" "$HALT_TEXT"@'
new_lane control_ack_command ken-41
install_arms "$MUTANT_PATH"
send KEN-41 'Stop pushing.' --halt
printf -v ACK_READ '%q inbox --item %q --root %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-41 "$LANE"
tool halt
assert_eq "key=$(first_line | cut -d= -f1) command=$(grep -cxF -- "$ACK_READ" "$ERR_FILE")" \
  "key=lane-mail-check: halt command=0" \
  "control: without the command the halt refusal keeps its key and loses the one read that clears it"

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

# Each handoff mark's refusal replaced by a pass, its judgement still made.
mutant no-context-mark -e 's@^    refuse_handoff context "\$TOKENS"$@    :@'
new_handoff_lane control_context KEN-56
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 "$GAP" "control: without its context refusal a lane past the mark ends its turn"

mutant no-headroom-mark -e 's@^      refuse_handoff headroom "\$HEADROOM"$@      :@'
new_handoff_lane control_headroom KEN-57
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .nclaude)
expect 0 - "control: without its account refusal a lane at its account's mark ends its turn"

# The verb's own status 2 folded back in with the statuses it cannot attribute:
# an unreadable state file then reads as an install that does not carry the
# verb, and the operator is sent to refresh an install that is current while
# the state file that actually stopped the read is never named.
mutant fold-unreadable \
  -e 's@^    "$HANDOFF_VERDICT=unreadable") HANDOFF_STATE=unreadable ;;$@    "$HANDOFF_VERDICT=unreadable") HANDOFF_STATE=unanswered ;;@'
new_handoff_lane control_unreadable KEN-89
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
CONTROL_STATE="$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" path KEN-89)"
printf '{"handoff":' > "$CONTROL_STATE"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 "lane-mail-check: handoff-unanswered=$LANE/.claude/skills/orch/scripts/workflow-state" \
  "control: folded in, an unreadable state file reads as an install that lacks the verb"
assert_eq "$(grep -c "$CONTROL_STATE" "$ERR_FILE")" "0" \
  "control: and the file that actually stopped the read is never named"

# The library probe moved out of this shell and into a child of it. Bash 3.2
# kills the shell on a source it cannot parse even as the condition of an `if`,
# where bash 5 takes the non-zero status and carries on, and this hook's EXIT
# teardown then succeeds and lends the dead run its own 0: the turn passes with
# the account mark unjudged and not one line on stderr, which is the one answer
# the marks forbid. What the masking costs depends on the interpreter the
# shebang picks, so the control runs only under the one that dies.
mutant in-process-probe \
  -e 's@^  if ! "\$BASH" -euo pipefail -c .* 2>"\$WORK_DIR/lib.err"; then$@  if ! { . "$SCRIPTS/lib/lane-context.sh" \&\& declare -F lane_context_caller_cfg >/dev/null; } 2>"$WORK_DIR/lib.err"; then@'
new_handoff_lane control_probe KEN-93
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
plant_install lib
mkdir -p "$LANE/.claude/skills/orch/scripts/lib"
for name in "$REPO_ROOT/skills/orch/scripts/lib"/*.sh; do
  [ "${name##*/}" != lane-context.sh ] || continue
  ln -s -f -n "$name" "$LANE/.claude/skills/orch/scripts/lib/${name##*/}"
done
printf '# shellcheck shell=bash\nthis is ( not shell\n' \
  > "$LANE/.claude/skills/orch/scripts/lib/lane-context.sh"
write_transcript "$TRANSCRIPT" 1000
if [ "$HOOK_BASH_MAJOR" -lt 4 ]; then
  stop_at "$TRANSCRIPT" false
  expect 0 - \
    "control: probed in-process, a library this shell cannot parse kills the hook and its teardown passes the turn in silence"
else
  printf '  skip  control: probed in-process, the masking needs a shell that dies on a sourced parse error; this one is bash %s\n' \
    "$HOOK_BASH_MAJOR"
fi

# The record test answering yes whatever the state holds: the mark then clears
# itself and no lane ever writes one.
mutant record-always \
  -e 's@^    "$HANDOFF_VERDICT=none") HANDOFF_STATE=none; return 0 ;;$@    "$HANDOFF_VERDICT=none") HANDOFF_STATE=stands; return 0 ;;@'
new_handoff_lane control_record KEN-58
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 - "control: with the record test inverted a lane past the mark with no record ends its turn"

# The continued turn routed back to a plain pass: a lane that declined the
# first refusal then ends the session with nothing recorded.
mutant active-passes -e 's@^handoff_check$@[ "$CONTINUED" = true ] || handoff_check@'
new_handoff_lane control_active KEN-59
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" true
expect 0 - "control: with the continued turn routed past the marks a lane ends past the mark"

# A read mailbox routed to a plain pass rather than on to the marks: the lane
# that has already been messaged is then the one never judged.
mutant read-passes -e 's@^  \[ -n "\$UNREAD" \] || return 0$@  [ -n "$UNREAD" ] || exit 0@'
new_handoff_lane control_read KEN-73
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
send KEN-73 'Rebase first.'
stop
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 - "control: with a read mailbox routed past the marks a lane ends past the mark"

# The first usage line taken instead of the last: a long first turn a
# compaction reset would then hold the lane for ever.
mutant first-usage -e 's@^    tail -n 1$@    head -n 1@'
new_handoff_lane control_first_usage KEN-74
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
append_transcript "$TRANSCRIPT" 1000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "control: reading the first usage line holds a lane whose window was reset"

# The continued turn refusing every resolution failure again: the session then
# never ends, which is the loop stop_hook_active exists to end.
mutant active-refuses -e 's@^  if \[ "\$REPORTED" = true \]; then$@  if false; then@'
new_lane control_stall ken-75
mkdir -p "$LANE/tmp/lane-mail/KEN-75"
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
stop_active LANE_MAIL_ITEM='bad item!'
expect 2 "lane-mail-check: item=invalid" \
  "control: without the continued turn's report the same refusal is made again"

# The gap left unreported: an account nothing measured then reads as room.
mutant silent-gap -e 's@^    \*) message account unmeasured .*$@    *) : ;;@'
new_handoff_lane control_gap KEN-76
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .openclaude)
expect 0 - "control: without its report an account nothing measured passes silently"

# An unattributable status read as "no record stands": the lane that wrote its
# record is then refused at every turn end by an install that never saw it.
mutant record-on-any -e 's@^    \*) HANDOFF_STATE=unanswered ;;$@    *) HANDOFF_STATE=none ;;@'
new_handoff_lane control_old_state KEN-77
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
old_dispatcher
record_handoff KEN-77
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=600000" \
  "control: read as no record, an older install refuses a lane that has already handed off"

# The whole-file fallback dropped: a session whose recent window is all tool
# results reads as no context at all and runs to its wall.
MUTANT_SOURCE="$WINDOW_HOOK" mutant no-window-fallback \
  -e 's@^    \[ -n "\$TOKENS" \] || TOKENS=\$(transcript_tokens <"\$TRANSCRIPT") ||$@    false ||@' \
  -e 's@^      refuse_handoff transcript unread "\$(cat -- "\$WORK_DIR/transcript.err")"$@      :@'
new_handoff_lane control_window KEN-78
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
filler "$TRANSCRIPT" 2000
stop_at "$TRANSCRIPT" false
expect 0 "$GAP" \
  "control: without the fallback a usage line before the window reads as no context at all"

# Pi's spelling dropped from the filter, the rest of it intact: a Pi lane past
# the mark then answers with the word for a usage nothing read, and the refusal
# that would have held it is never made.
mutant no-pi-usage \
  -e 's@^         elif has("input") or has("cacheRead") or has("cacheWrite")$@         elif false@'
new_handoff_lane control_pi_usage KEN-92
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
usage_line pi 600000 > "$TRANSCRIPT"
stop_at "$TRANSCRIPT" false
expect 0 "lane-mail-check: usage-unread=$TRANSCRIPT" \
  "control: without Pi's spelling a Pi lane past the context mark is never refused"

# The unread answer folded back into a figure of zero: a usage object neither
# spelling reads then passes as a small window, with no key to say the mark
# went unjudged, which is the silence every other unjudgeable mark here breaks.
mutant zero-usage -e 's@^         else empty end) // \$unread.*@         else 0 end)'"'"' 2>"$WORK_DIR/transcript.err" |@'
new_handoff_lane control_zero_usage KEN-93
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
usage_line unread 900000 > "$TRANSCRIPT"
stop_at "$TRANSCRIPT" false
expect 0 "$GAP" \
  "control: summed to zero, a usage object neither spelling reads passes as a small window"

# The record's time put back in the template: the lane is asked for it again,
# and the row above that says it is not goes red.
mutant asks-written-at -e 's@{"merged":@{"written_at":"[NOW]","merged":@'
new_handoff_lane control_written_at KEN-94
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
assert_eq "$(template_fields | tr ',' '\n' | grep -cx written_at || true)" "1" \
  "control: with written_at back in the template the lane is asked for the record's time"

# The overseer identification's control: the pane comparison removed, so any
# session with no lane is taken for the overseer. An ordinary session in a
# fleet checkout is then held at its own turn end on marks nobody set for it.
mutant any-session-overseer -e 's@^  \[ "\$RECORDED_KEY" = "\$CALLER_KEY" \] || return 1$@  :@'
new_overseer control_any_session
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "$CONTEXT_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env "%3")
expect 2 "lane-mail-check: context=612000" \
  "control: without the pane comparison a session the fleet state never named is held"

# The succession field's control: the arm that passes the turn removed. The
# refusal then names a route the operator has turned off, which no turn end the
# overseer reaches can clear.
mutant overseer-succession -e 's@^  \[ "\$SUCCESSION" != off \] || return 0$@  :@'
new_overseer control_succession_off
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "$OFF_MARK_LINE"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: context=612000" \
  "control: without the field read the overseer is refused with its route turned off"

# The fleet record's own control: the writer comparison removed, so a record
# any session left on the shared item answers for this one and its turn end is
# passed with both marks unjudged, for the life of the session.
mutant overseer-record-owner -e 's@^      if \[ "\$ROLE" != overseer \] || handoff_is_mine; then$@      if true; then@'
new_overseer control_record_owner
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "$CONTEXT_MARK_LINE"
record_overseer_handoff other-session
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "control: without the writer comparison another session's record passes this one past its mark"

# The judged line's own control: the three-field guard removed, so a keyed line
# missing a figure refuses anyway and names nothing the judgement read.
mutant overseer-fields \
  -e 's@^  if \[ -z "\$MARK_KIND" \] || \[ -z "\$MARK_VALUE" \] || \[ -z "\$MARK" \]; then$@  if false; then@'
new_overseer control_overseer_fields
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
judge_says "oversee-succeed: mark-reached kind=context mark=500000 succession=on"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(overseer_env)
expect 2 "lane-mail-check: context=" \
  "control: without the three-field guard a line naming no figure refuses on one"

# The silence a session that is neither a lane nor the recorded overseer keeps.
# Two arms hold it, one where the install cannot be resolved and one where that
# install has no workflow-state, and the candidate flag is what both read.
# Without them a plain repository carrying a rendered orch tree, opened from a
# harness whose own install has no orch skill, writes a keyed line at every
# turn end of every session in the checkout.
new_lane control_not_a_lane main
unclaim
rm -f -- "${LANE:?}/.claude/skills/orch" "${LANE:?}/.agents/skills/orch/scripts"
SILENT_READER="$LANE/.agents/skills/orch/scripts/lane-mail"
# shellcheck disable=SC2046
stop $(overseer_env "%3")
expect 0 - "a session that is no lane and no overseer says nothing about an install it has not got"
mutant unresolved-speaks -e 's@^    \[ "\$NO_LANE_ITEM" -eq 0 \] || return 0$@    :@'
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
# shellcheck disable=SC2046
stop $(overseer_env "%3")
expect 0 "lane-mail-check: handoff-skipped=$SILENT_READER" \
  "control: without the candidate arms that session reports a gap at every turn end"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
