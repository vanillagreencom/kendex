#!/usr/bin/env bash
# lane-mail-check: a Stop hook that blocks a lane's turn end while its overseer
# mailbox holds unread lines, so a directive or a ruling reaches the lane with
# no keystroke, no pane and no question tool.
#
# Every case builds a lane repository under TMP_ROOT, writes to its mailbox
# with the real `lane-mail`, and asserts the hook's exit status and the keyed
# first line of stderr. The orch reader is the real script: it owns the cursor,
# so the second-stop case proves the two halves agree rather than that a
# fixture was written twice.
#
# HOOK_UNDER_TEST overrides the script under test, which is what the must-fail
# control at the end runs against these same assertions.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/lane-mail-check.sh}"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
LANE_MAIL="$REPO_ROOT/skills/orch/scripts/lane-mail"
TMP_ROOT="$(mktemp -d)"
trap 'chmod -R u+rwx -- "${TMP_ROOT:?}" 2>/dev/null || :; rm -rf -- "${TMP_ROOT:?}"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
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

# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# A lane: a git repository on a branch named for its item, with the orch
# scripts where a lane's own `.agents` tree holds them. The commit is what
# gives HEAD a branch to name.
LANE=""
new_lane() { # NAME BRANCH
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE/.agents/skills/orch"
  git -C "$LANE" init -q
  git -C "$LANE" checkout -q -b "$2"
  git -C "$LANE" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  ln -sfn "$REPO_ROOT/skills/orch/scripts" "$LANE/.agents/skills/orch/scripts"
}

RC=0
run_payload() { # RAW-JSON [ENV=VAL...]
  local payload="$1"
  shift
  RC=0
  : > "$ERR_FILE"
  printf '%s' "$payload" |
    (cd "$LANE" && env "$@" bash "$HOOK") >"$TMP_ROOT/stdout" 2>"$ERR_FILE" || RC=$?
}

stop() { # [ENV=VAL...]
  run_payload '{"session_id":"s1","stop_hook_active":false}' "$@"
}

send() { # ITEM KIND TEXT
  printf '%s\n' "$3" > "$TMP_ROOT/msg.txt"
  if [ "$2" = directive ]; then
    "$LANE_MAIL" send --item "$1" --root "$LANE" --directive --file "$TMP_ROOT/msg.txt"
  else
    "$LANE_MAIL" send --item "$1" --root "$LANE" --re some-ask --file "$TMP_ROOT/msg.txt"
  fi
}

echo "=== lane-mail-check ==="

# --- a session that is not a lane ---------------------------------------
new_lane plain ken-1
stop
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" "a repository with no mailbox directory passes silently"
mkdir -p "$LANE/tmp/lane-mail/KEN-2"
stop
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "a mailbox naming another item is not this branch's lane and passes silently"
git -C "$LANE" checkout -q --detach
stop
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" "a detached HEAD names no lane and passes silently"
# GIT_CEILING_DIRECTORIES stops discovery at TMP_ROOT, so this directory reads
# as no repository however the suite's own temp root was placed — a runner
# whose TMPDIR sits inside a checkout would otherwise resolve that checkout.
LANE="$TMP_ROOT/norepo"
CEILING=(GIT_CEILING_DIRECTORIES="$TMP_ROOT")
mkdir -p "$LANE"
stop "${CEILING[@]}"
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "a directory git reports no repository for holds no mailbox and passes silently"
mkdir -p "$LANE/tmp/lane-mail/KEN-1"
stop "${CEILING[@]}"
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: git=rev-parse --show-toplevel" \
  "a mailbox git can report no repository for is refused, never passed"

# --- an empty mailbox ---------------------------------------------------
new_lane empty ken-3
mkdir -p "$LANE/tmp/lane-mail/KEN-3"
stop
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "a mailbox with no to-lane.jsonl passes silently"
: > "$LANE/tmp/lane-mail/KEN-3/to-lane.jsonl"
stop
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" "an empty mailbox passes silently"

# --- unread mail --------------------------------------------------------
new_lane unread ken-4
send KEN-4 directive 'Hold the PR until the owner answers.'
stop
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: unread=1" \
  "unread mail refuses with the count on the first line"
assert_eq "$(cause_below)" "present" "the messages stand under the keyed line"
assert_eq "$(grep -c 'Hold the PR until the owner answers.' "$ERR_FILE")" "1" \
  "the refusal carries the message the overseer sent"
assert_eq "$(cat "$TMP_ROOT/stdout")" "" "the hook writes nothing to stdout"
stop
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "a second stop passes: the reader advanced the cursor past what it handed over"

send KEN-4 directive 'And rebase first.'
send KEN-4 directive 'Then re-arm auto-merge.'
stop
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: unread=2" \
  "two new messages refuse once, naming both"

# --- an answer is not the inbox's --------------------------------------
new_lane answered ken-5
send KEN-5 answer 'Merge it.'
stop
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "an answer belongs to the wait that asked for it and never stops a turn"

# --- the item the brief named -------------------------------------------
new_lane named ken-6
send OTHER-1 directive 'Brief-named mailbox.'
stop
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "a mailbox the branch does not name is not read without LANE_MAIL_ITEM"
stop LANE_MAIL_ITEM=OTHER-1
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: unread=1" \
  "LANE_MAIL_ITEM selects the lane's mailbox whatever the branch is"
stop LANE_MAIL_ITEM=../escape
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: item=invalid" \
  "an item outside its alphabet is refused rather than resolved to a path"

new_lane ambiguous ken-7
mkdir -p "$LANE/tmp/lane-mail/KEN-7" "$LANE/tmp/lane-mail/ken-7"
stop
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: item=ambiguous" \
  "two mailboxes lowercasing to one branch decide nothing and are refused"

# --- what the hook cannot read ------------------------------------------
new_lane noreader ken-8
send KEN-8 directive 'unreachable'
rm -f "$LANE/.agents/skills/orch/scripts"
stop
assert_eq "RC=$RC first=$(first_line)" \
  "RC=2 first=lane-mail-check: reader=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "a mailbox with no reader beside it is refused, never passed"

new_lane unreadable ken-9
send KEN-9 directive 'sealed'
chmod 000 "$LANE/tmp/lane-mail/KEN-9/to-lane.jsonl"
stop
chmod 644 "$LANE/tmp/lane-mail/KEN-9/to-lane.jsonl"
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: inbox=2" \
  "a mailbox that cannot be read is refused with the reader's status"
assert_eq "$(grep -c '^lane-mail: file-unreadable=' "$ERR_FILE")" "1" \
  "the reader's own keyed line is replayed under the hook's"

new_lane payload ken-10
send KEN-10 directive 'x'
run_payload 'not json'
assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: payload=invalid-json" \
  "a payload that is not JSON is refused rather than skipped"
run_payload '{"stop_hook_active":true}'
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "the turn the harness already continued is not blocked again"

# --- must-fail control --------------------------------------------------
# The refusal removed and nothing else: the hook still reads the mailbox and
# still advances the cursor, so a control that only deleted the read would
# prove the assertion runs rather than that the block does.
MUTANT="$TMP_ROOT/mutant.sh"
sed 's@^refuse unread "\$COUNT"$@exit 0@' "$HOOK" > "$MUTANT"
assert_eq "$(cmp -s "$MUTANT" "$HOOK" && echo same || echo differs)" "differs" \
  "control: the mutant really removes the unread block"
new_lane control ken-11
send KEN-11 directive 'Block me.'
HOOK="$MUTANT" stop
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=-" \
  "control: without its refusal the hook lets the turn end with the message unread"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
