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

RC=0
# The judge's argument, empty for the turn-end run the harness makes.
ARM_ARGS=()
run_payload() { # RAW-JSON [ENV=VAL...]
  local payload="$1"
  shift
  RC=0
  : > "$ERR_FILE"
  printf '%s' "$payload" |
    (cd "$LANE" && env -u CLAUDE_CONFIG_DIR -u CODEX_HOME -u LANE_MAIL_ITEM \
      -u ORCH_HANDOFF_CONTEXT_TOKENS -u ORCH_HANDOFF_HEADROOM_PCT -u ORCH_STATE_DIR \
      "LANES_HOME=$OFFLINE_HOME" "ORCH_LANES_FETCH_CMD=$NO_FETCH" \
      "$@" bash "$CASE_HOOK" ${ARM_ARGS[@]+"${ARM_ARGS[@]}"}) >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
}

stop() { # [ENV=VAL...]
  run_payload '{"session_id":"s1","stop_hook_active":false}' "$@"
}

# A turn end whose payload names a transcript, as the harness writes one.
stop_at() { # TRANSCRIPT ACTIVE [ENV=VAL...]
  local path="$1" active="$2"
  shift 2
  run_payload "$(jq -nc --arg p "$path" --argjson a "$active" \
    '{session_id:"s1",stop_hook_active:$a,transcript_path:$p}')" "$@"
}

# One assistant line carrying the usage the harness recorded for it; the
# context is its input tokens plus the cache the prompt was read from.
write_transcript() { # PATH TOKENS
  jq -nc --argjson t "$2" \
    '{type:"assistant",message:{usage:{input_tokens:1,cache_read_input_tokens:($t - 1),cache_creation_input_tokens:0}}}' \
    > "$1"
}

# The scripts a kendex install renders beside the mailbox reader. The handoff
# marks are judged with them, so a case planting its own reader plants them
# too, the way an install has them.
plant_siblings() { # SCRIPTS_DIR
  local name
  for name in orch-env lanes workflow-state lib; do
    ln -s -f -n "$REPO_ROOT/skills/orch/scripts/$name" "$1/$name"
  done
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
# --- the handoff marks ---------------------------------------------------
#
# A lane hands itself off at the context mark and at its account's wall, so no
# overseer has to read a pane for it. Every row here is a turn end on a lane
# with an empty mailbox, which is the path the marks are judged on.

# A lane whose mailbox holds nothing, so each row below judges the marks alone.
new_handoff_lane() { # NAME ITEM
  new_lane "$1" "$(printf '%s' "$2" | tr 'A-Z' 'a-z')"
  mkdir -p "$LANE/tmp/lane-mail/$2"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init "$2" >/dev/null)
}

# The record the lane writes at the safe point, and the field a relaunch sets
# on it once the item is resumed.
record_handoff() { # ITEM [RESUMED_AT]
  local value
  value="$(jq -nc --arg r "${2:-}" \
    '{written_at:"2026-09-18T08:05:00Z",merged:[],remaining:["submit-pr"],branch:"b",worktree:"w",open_pr:null,traps:[]}
     | if $r == "" then . else .resumed_at = $r end')"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" set "$1" handoff "$value" >/dev/null)
}

TRANSCRIPT="$TMP_ROOT/transcript.jsonl"

new_handoff_lane handoff_context KEN-50
write_transcript "$TRANSCRIPT" 499999
stop_at "$TRANSCRIPT" false
expect 0 - "a lane under the context mark ends its turn"
write_transcript "$TRANSCRIPT" 500000
stop_at "$TRANSCRIPT" false
expect 2 "lane-mail-check: context=500000" "a lane at the context mark is refused with the figure it reached"
assert_eq "$(grep -cF -- "workflow-state set KEN-50 handoff " "$ERR_FILE")" "1" \
  "the refusal names the one command that writes the record"
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

new_handoff_lane handoff_setting KEN-51
write_transcript "$TRANSCRIPT" 500000
stop_at "$TRANSCRIPT" false ORCH_HANDOFF_CONTEXT_TOKENS=900000
expect 0 - "a mark the setting raises is not reached at the same figure"

new_handoff_lane handoff_subagent KEN-52
write_transcript "$TRANSCRIPT" 800000
run_payload "$(jq -nc --arg p "$TRANSCRIPT" \
  '{session_id:"s1",stop_hook_active:false,agent_id:"a1",transcript_path:$p}')"
expect 0 - "a subagent runs its own window and is judged on neither mark"

new_handoff_lane handoff_no_transcript KEN-53
stop
expect 0 - "a payload naming no transcript leaves the context unread and passes"
stop_at "$TMP_ROOT/absent.jsonl" false
expect 2 "lane-mail-check: transcript=unreadable" \
  "a transcript the payload names and nothing can read is refused, never passed"

# The account mark, measured through the credential the lane runs on. The
# standard home's nclaude sits at exactly 5 percent headroom, which is at the
# default mark; claude has 80 and is room.
source "$REPO_ROOT/skills/orch/tests/lib/lanes-fixture.sh"
standard_home handoff-accounts
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
expect 2 "lane-mail-check: headroom=5" "a lane at its account's handoff mark is refused with the headroom left"
assert_eq "$(grep -cF -- "workflow-state set KEN-54 handoff " "$ERR_FILE")" "1" \
  "the account refusal carries the same instruction as the context refusal"
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .nclaude) ORCH_HANDOFF_HEADROOM_PCT=1
expect 0 - "a mark the setting lowers leaves the same account with room"
record_handoff KEN-54
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .nclaude)
expect 0 - "a lane whose handoff record stands ends its turn at its account's mark"

new_handoff_lane handoff_unmeasured KEN-55
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .openclaude)
expect 2 "lane-mail-check: account=unmeasured" \
  "an account with an inventory entry and no usable credential is refused, never read as room"

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
printf -v READ_HALT '%q inbox --item %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-30
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
  printf -v SUB_READ '%q inbox --item %q' "$LANE/.claude/skills/orch/scripts/lane-mail" "$item"
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
tool deliver "git status" agent_id
tool deliver
assert_eq "RC=$RC context=$(context_line)" "RC=0 context=-" \
  "control: without the deliver check a subagent's call consumes the lead's directive"
mutant lead-halt -e 's@^  if \[ "\$CALLER" = lead \]; then$@  if true; then@'
new_lane control_sub_halt ken-35
install_arms "$MUTANT_PATH"
send KEN-35 'Halt the lead.' --halt
printf -v SUB_READ '%q inbox --item %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-35
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
printf -v SUB_READ '%q inbox --item %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-38
tool halt "$SUB_READ" agent_type
expect 0 - "control: without the agent_type read a subagent's call carrying the acknowledging command passes"

# The deliver context written without its envelopes, the keyed line kept.
mutant no-envelopes -e 's@^  NOTICE=\$(message unread "\$COUNT" 2>&1)$@  NOTICE=$(UNREAD= message unread "$COUNT" 2>\&1)@'
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
printf -v ACK_READ '%q inbox --item %q' "$LANE/.claude/skills/orch/scripts/lane-mail" KEN-41
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
mutant no-context-mark -e 's@^      refuse context "\$TOKENS"$@      :@'
new_handoff_lane control_context KEN-56
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 - "control: without its context refusal a lane past the mark ends its turn"

mutant no-headroom-mark -e 's@^          refuse headroom "\$HEADROOM"$@          :@'
new_handoff_lane control_headroom KEN-57
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 1000
# shellcheck disable=SC2046
stop_at "$TRANSCRIPT" false $(account_env .nclaude)
expect 0 - "control: without its account refusal a lane at its account's mark ends its turn"

# The record test answering yes whatever the state holds: the mark then clears
# itself and no lane ever writes one.
mutant record-always -e 's@^  \[ -n "\$RECORD" \]$@  [ -z "$RECORD" ]@'
new_handoff_lane control_record KEN-58
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" false
expect 0 - "control: with the record test inverted a lane past the mark with no record ends its turn"

# The continued turn routed back to a plain pass: a lane that declined the
# first refusal then ends the session with nothing recorded.
mutant active-passes -e '/^if \[ "\$ARM" = stop \] && \[ "\$ACTIVE" = "true" \]; then$/,/^fi$/ s@^  handoff_pass$@  exit 0@'
new_handoff_lane control_active KEN-59
install_hook "$MUTANT_PATH" "$LANE/.claude/hooks/lane-mail-check.sh"
write_transcript "$TRANSCRIPT" 600000
stop_at "$TRANSCRIPT" true
expect 0 - "control: with the continued turn routed past the marks a lane ends past the mark"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
