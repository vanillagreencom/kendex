#!/usr/bin/env bash
# lane-mail-check on Copilot: the lane-mail hooks installed where kendex
# renders them for Copilot, run with the payloads Copilot's hooks reference
# gives, and a Copilot call reaching a Claude copy registered in
# `.claude/settings.json` by hand or by kendex before the Copilot skip, which
# Copilot also runs. The shared world is
# lib/lane-mail-world.sh; lane-mail-check.test.sh holds every other harness's
# rows. HOOK_UNDER_TEST overrides the script the must-fail controls at the end
# run against.
set -euo pipefail

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

echo "=== lane-mail-check: copilot ==="

# --- copilot -----------------------------------------------------------
# On Copilot the hooks run from `.github/hooks`, the event is agentStop, the
# payload spells its fields in camelCase, and every refusal is also the
# documented JSON answer on stdout. Every row here installs the hooks where
# kendex renders them for Copilot and sends the payload in the camelCase shape
# Copilot's hooks reference gives for its event, not a captured one. A custom
# subagent's agentStop carries its own session id and the lead's transcript,
# the shape Copilot CLI 1.0.88 was measured sending (the copilot_stop rows
# run with COP_SESSION=c1); a sessionStart or prompt payload carrying agent_id
# or agent_type (the copilot_context rows passing FIELD) is assumed, not
# referenced. Every run gets a user home of its own, COP_HOME, where the
# judge keeps its Copilot lead records, and each lane starts with none.
CALL_ENV=("HOME=$COP_HOME")
COP_SESSION=s1
# The lead records the judge holds, comma-joined in name order, and a cache
# the records directory cannot be made under.
cop_recorded() {
  local f out=""
  for f in "$COP_LEADS"/*; do
    [ -e "$f" ] || continue
    out="$out,${f##*/}"
  done
  printf '%s' "${out#,}"
}
cop_unrecordable() {
  cop_clear_leads
  mkdir -p "$COP_HOME/.cache"
  : > "$COP_HOME/.cache/lane-mail"
}
new_copilot_lane() { # NAME BRANCH [JUDGE]
  new_lane "$1" "$2"
  cop_clear_leads
  rm -f -- "${LANE:?}/.claude/hooks/lane-mail-check.sh"
  install_hook "$TEST_DIR/../lane-mail-deliver.sh" "$LANE/.github/hooks/lane-mail-deliver.sh"
  install_hook "$TEST_DIR/../lane-mail-halt.sh" "$LANE/.github/hooks/lane-mail-halt.sh"
  install_hook "$TEST_DIR/../lane-mail-start.sh" "$LANE/.github/hooks/lane-mail-start.sh"
  install_hook "$TEST_DIR/../lane-mail-prompt.sh" "$LANE/.github/hooks/lane-mail-prompt.sh"
  install_hook "${3:-$HOOK}" "$LANE/.github/hooks/lane-mail-check.sh"
}
# The lead's transcript sits in the directory named for the session. The
# session each payload names is COP_SESSION: s1 is the lead, c1 a subagent.
COP_TRANSCRIPT="$TMP_ROOT/session-state/s1/events.jsonl"
mkdir -p "${COP_TRANSCRIPT%/*}"
: > "$COP_TRANSCRIPT"
copilot_stop() { # TRANSCRIPT [ACTIVE] [ENV=VAL...]
  local path="$1" active="${2:-false}"
  shift; [ $# -eq 0 ] || shift
  run_payload "$(jq -nc --arg s "$COP_SESSION" --arg p "$path" --argjson a "$active" \
    '{sessionId:$s, timestamp:1, cwd:"/w", transcriptPath:$p, stopReason:"end_turn", stop_hook_active:$a}')" "$@"
}
copilot_tool() { # ARM [COMMAND] [object|string]
  local judge="$CASE_HOOK" shape="${3:-object}"
  CASE_HOOK="$LANE/.github/hooks/lane-mail-$1.sh"
  run_payload "$(jq -nc --arg s "$COP_SESSION" --arg c "${2:-git status}" --arg shape "$shape" \
    '{sessionId:$s, timestamp:1, cwd:"/w", toolName:"bash",
      toolArgs: (if $shape == "string" then ({command:$c} | tojson) else {command:$c} end)}')"
  CASE_HOOK="$judge"
}
# A Copilot session start or prompt, as the lane-mail-start or lane-mail-prompt
# hook beside the judge receives it: sessionStart carries `source`,
# userPromptSubmitted the prompt. FIELD, agent_id or agent_type, marks a
# subagent's run; SOURCE is the start's, new unless named.
copilot_context() { # start|prompt [FIELD] [SOURCE]
  local judge="$CASE_HOOK"
  CASE_HOOK="$LANE/.github/hooks/lane-mail-$1.sh"
  run_payload "$(jq -nc --arg s "$COP_SESSION" --arg arm "$1" --arg f "${2:-}" --arg src "${3:-new}" \
    '{sessionId:$s, timestamp:1, cwd:"/w"}
      + (if $arm == "start" then {source:$src} else {prompt:"Carry on."} end)
      + (if $f == "" then {} else {($f): "dev-1"} end)')"
  CASE_HOOK="$judge"
}
# The same prompt run with the hook's stdout closed, so the context it writes
# there fails: a wrapper closes it and runs the hook.
copilot_context_unwritable() { # start|prompt
  local judge="$CASE_HOOK"
  printf '#!/usr/bin/env bash\nexec >&-\nexec bash %q "$@"\n' "$LANE/.github/hooks/lane-mail-$1.sh" \
    > "$TMP_ROOT/closed-stdout.sh"
  CASE_HOOK="$TMP_ROOT/closed-stdout.sh"
  run_payload '{"sessionId":"s1","timestamp":1,"cwd":"/w"}'
  CASE_HOOK="$judge"
}
# How many unread lines of ITEM's mailbox carry TEXT, read without moving the
# cursor.
lane_unread() { # ITEM TEXT
  (cd "$LANE" && "$LANE_MAIL" inbox --item "$1" --root "$LANE" --peek) | grep -cF -- "$2" || :
}
# A Copilot lane's passing turn end in the offline world reports three gaps:
# the context, since no usage reading of its session stands
# (lane-mail-usage.test.sh) and no status line wrote a session record for s1
# under the account, the fallback's own line, and the account, which that
# world's home holds no lane for.
cop_gap() { # ITEM
  printf 'reading-unrecorded=%s;session-record=missing;account=unlisted' "$LANE/tmp/lane-mail/$1/context.json"
}
stdout_field() { # JQ
  jq -r "$1" "$TMP_ROOT/stdout" 2>/dev/null || echo unparseable
}
# The real orch skill where a Copilot hook's install walk finds it, `.github/
# skills` beside `.github/hooks`, with SKIP left out: the walk from
# `.github/hooks` never reaches `.claude/skills`, so plant_install holes
# nothing a Copilot lane runs.
plant_copilot_install() { # [SKIP]
  rm -rf -- "${LANE:?}/.github/skills/orch"
  rm -rf -- "${LANE:?}/.github/skills/mailbox"
  mkdir -p "$LANE/.github/skills/orch/scripts"
  mkdir -p "$LANE/.github/skills/mailbox/scripts"
  ln -s -f -n "$REPO_ROOT/skills/mailbox/scripts/lane-mail" "$LANE/.github/skills/mailbox/scripts/lane-mail"
  plant_siblings "$LANE/.github/skills/orch/scripts" "${1:-}"
}

new_copilot_lane copilot_stop ken-201
send KEN-201 'Rebase onto main.'
REPORT_ITEM=KEN-201
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: unread=1 decision=block" \
  "a Copilot lead's turn end with unread mail is held with the documented block answer and exit 0"
assert_eq "recorded=$(cop_recorded)" "recorded=s1" \
  "that turn end, its transcript under the directory named for its session, records the session as the lead"
assert_eq "$(stdout_field .reason | grep -c 'Rebase onto main.') $(stdout_field .reason | head -n 1)" \
  "1 lane-mail-check: unread=1" "the block reason is the refusal text, keyed line first, directive under it"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC keyed=$(hook_keys) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 keyed=$(cop_gap KEN-201) stdout=" \
  "a second stop passes with the gaps reported and no answer on stdout: the block acknowledged the mail"

send KEN-201 'Then re-arm auto-merge.'
COP_SESSION=c1 copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$TMP_ROOT/stdout") recorded=$([ -e "$COP_LEADS/c1" ] && echo yes || echo no)" \
  "RC=0 first=- stdout= recorded=no" \
  "a subagent's stop, its own session naming the lead's transcript, is handed nothing, judged on nothing and recorded as no lead"
copilot_stop "$COP_TRANSCRIPT"
expect 0 "lane-mail-check: unread=1" "the lead's next turn end still finds that directive unread"
send KEN-201 'And push.'
run_payload '{"sessionId":"s1","stop_hook_active":false}'
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: unread=1 decision=block" \
  "a stop naming no transcript is read as the lead's"
send KEN-201 'Name no session.'
run_payload "$(jq -nc --arg p "$COP_TRANSCRIPT" '{transcriptPath:$p, stop_hook_active:false}')"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: unread=1 decision=block" \
  "a stop naming a transcript and no session is read as the lead's: an empty name matches no directory"
# A directive holding a backslash and a quote: the block answer is built
# without jq, and its reason still parses and carries the directive exactly.
COP_ESCAPED='grep -E "a\.b" C:\path'
send KEN-201 "$COP_ESCAPED"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC decision=$(stdout_field .decision) exact=$(stdout_field .reason | tail -n 1 | jq -r .text 2>/dev/null | grep -cxF -- "$COP_ESCAPED")" \
  "RC=0 decision=block exact=1" \
  "a directive holding a backslash and a quote reaches the block reason byte for byte"
send KEN-201 'Continued.'
copilot_stop "$COP_TRANSCRIPT" true
assert_eq "RC=$RC keyed=$(hook_keys)" "RC=0 keyed=$(cop_gap KEN-201)" \
  "the turn Copilot continued after a block skips the mailbox check, as on every harness"

# The halt arm: the deny answer under exit 2. A call from a session the judge
# holds no lead record of never shows the command that reads the halt; the
# lead's turn end names it and records the lead, whose own deny then names it
# too. A call of either kind running it passes, read out of toolArgs in both
# shapes, since the reader's --ack stops short of an unread halt and a lead
# whose record could not be written would otherwise be refused for good.
new_copilot_lane copilot_halt ken-202
send KEN-202 'Stop pushing.' --halt
HALT_202=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-202/to-lane.jsonl")
printf -v READ_HALT_202 '%q inbox --item %q --root %q' "$LANE/.agents/skills/mailbox/scripts/lane-mail" KEN-202 "$LANE"
copilot_tool halt
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .permissionDecision)" \
  "RC=2 first=lane-mail-check: halt=$HALT_202 decision=deny" \
  "an unread halt denies a Copilot tool call with the documented answer under exit 2"
assert_eq "command=$(stdout_field .permissionDecisionReason | grep -cxF -- "$READ_HALT_202") directive=$(stdout_field .permissionDecisionReason | grep -cF 'Stop pushing.')" \
  "command=0 directive=1" "the deny reason for a session with no lead record carries the directive and not the command that reads it"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC decision=$(stdout_field .decision) directive=$(stdout_field .reason | grep -cF 'Stop pushing.') command=$(stdout_field .reason | grep -cxF -- "$READ_HALT_202") unread=$(lane_unread KEN-202 'Stop pushing.')" \
  "RC=0 decision=block directive=1 command=1 unread=1" \
  "the lead's turn end is held with the halt and the command that reads it, and leaves the halt unread"
copilot_tool halt
assert_eq "RC=$RC first=$(first_line) command=$(stdout_field .permissionDecisionReason | grep -cxF -- "$READ_HALT_202")" \
  "RC=2 first=lane-mail-check: halt=$HALT_202 command=1" \
  "the recorded lead's next call is denied, and its deny names the command that reads the halt"
COP_SESSION=c1 copilot_tool halt
assert_eq "RC=$RC first=$(first_line) command=$(stdout_field .permissionDecisionReason | grep -cxF -- "$READ_HALT_202")" \
  "RC=2 first=lane-mail-check: halt=$HALT_202 command=0" \
  "a subagent's call is denied without that command"
COP_SESSION=c1 copilot_tool halt "$READ_HALT_202" string
expect 0 - "the command that reads the halt, run from a session with no lead record and read out of a JSON-string toolArgs, passes"
copilot_tool halt "$READ_HALT_202" object
expect 0 - "and run by the recorded lead, read out of an object toolArgs"
# orch-env stubbed to record each call and answer its default: the handoff
# marks read their settings through it, so a call is a mark being judged.
plant_orch_env_stub() { # CALLS
  plant_copilot_install orch-env
  printf '#!/bin/sh\ntouch %s\nprintf "%%s\\n" "$2"\n' "$1" > "$LANE/.github/skills/orch/scripts/orch-env"
  chmod +x "$LANE/.github/skills/orch/scripts/orch-env"
}
ENV_CALLS="$TMP_ROOT/copilot-halt-env-calls"
plant_orch_env_stub "$ENV_CALLS"
"$LANE_MAIL" inbox --item KEN-202 --root "$LANE" >/dev/null
copilot_tool halt
assert_eq "RC=$RC marks=$([ -e "$ENV_CALLS" ] && echo judged || echo unjudged)" "RC=0 marks=unjudged" \
  "the halt decision is the mailbox alone: no handoff mark is judged before a tool call"
# The same planted install reaches the turn end, which is the arm the marks
# belong to: the row above is not silence from an install the walk never
# found.
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC marks=$([ -e "$ENV_CALLS" ] && echo judged || echo unjudged)" "RC=0 marks=judged" \
  "the turn end reaches the same planted orch-env, so the halt row's silence is the arm's own"

# The one command that restores a marked lane's missing mailbox, read out of
# toolArgs in both shapes: it clears nothing a lead must read, so a Copilot
# call may run it.
new_copilot_lane copilot_mkdir ken-208
printf -v MKDIR_208 'mkdir -p -- %q' "$LANE/tmp/lane-mail"
copilot_tool halt
assert_eq "RC=$RC first=$(first_line) command=$(stdout_field .permissionDecisionReason | grep -cxF -- "$MKDIR_208")" \
  "RC=2 first=lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail command=1" \
  "a marked Copilot lane with no mailbox is denied, naming the command that restores it"
copilot_tool halt "$MKDIR_208" string
expect 0 - "that command read out of a JSON-string toolArgs passes"
copilot_tool halt "$MKDIR_208" object
expect 0 - "and out of an object toolArgs"

# The deliver arm hands the lines over under the key Copilot's reference
# reads, top-level `additionalContext`, to a session the judge recorded as a
# lead, and acknowledges them; a custom subagent's call carries a session id
# nothing recorded, the shape Copilot CLI 1.0.88 was measured sending, and is
# handed nothing, saying so on stderr alone. Whether a built-in task-tool
# subagent's calls carry their own session id or the lead's is a pending
# live-lane proof, so no row sends one.
new_copilot_lane copilot_deliver ken-203
mkdir -p "$LANE/tmp/lane-mail/KEN-203"
copilot_context start
assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") stderr=$(first_line) recorded=$(cop_recorded)" \
  "RC=0 stdout= stderr=- recorded=s1" "the lead's session start records the session as the lead"
send KEN-203 'Rebase first.'
REPORT_ITEM=KEN-203
COP_SESSION=c1 copilot_tool deliver
assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") stderr=$(first_line) unread=$(lane_unread KEN-203 'Rebase first.')" \
  "RC=0 stdout= stderr=lane-mail-check: session-unrecorded=c1 unread=1" \
  "a subagent's finished call is handed nothing, acknowledges nothing and says so on stderr"
copilot_tool deliver
assert_eq "RC=$RC context=$(stdout_field '.additionalContext' | head -n 1) nested=$(stdout_field '.hookSpecificOutput') stderr=$(first_line)" \
  "RC=0 context=lane-mail-check: unread=1 nested=null stderr=-" \
  "the lead's finished call is handed the unread lines under the top-level key Copilot appends to the tool result"
assert_eq "carried=$(stdout_field '.additionalContext' | grep -cF 'Rebase first.') unread=$(lane_unread KEN-203 'Rebase first.')" \
  "carried=1 unread=0" "that context carries the directive and acknowledges it"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 stdout=" \
  "the lead's turn end then has nothing to hold it on"
copilot_tool deliver
assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 stdout=" \
  "the next finished call is handed nothing"

# Two Copilot sessions in one lane at once, and a resumed one: each start
# records its own session beside the other's, so the lead of either is handed
# the lines, and a resumed session records itself as it did when new.
COP_SESSION=s2 copilot_context start
send KEN-203 'Then push.'
COP_SESSION=s2 copilot_tool deliver
assert_eq "RC=$RC carried=$(stdout_field '.additionalContext' | grep -cF 'Then push.') unread=$(lane_unread KEN-203 'Then push.') recorded=$(cop_recorded)" \
  "RC=0 carried=1 unread=0 recorded=s1,s2" \
  "a second lead session started beside the first is recorded beside it, and its finished call is handed the lines"
rm -f -- "${COP_LEADS:?}/s1"
copilot_context start '' resume
assert_eq "RC=$RC recorded=$(cop_recorded)" "RC=0 recorded=s1,s2" \
  "a resumed session start records the session again"
send KEN-203 'After the resume.'
copilot_tool deliver
assert_eq "RC=$RC carried=$(stdout_field '.additionalContext' | grep -cF 'After the resume.') unread=$(lane_unread KEN-203 'After the resume.')" \
  "RC=0 carried=1 unread=0" "and the resumed lead's finished call is handed the lines"

# The records a crashed or ended session left: matched by no other session,
# and removed at a start once untouched for 30 days. The window is staged on
# both sides, s1 aged 29 days and kept, s2 aged 31 and removed, so a window
# under 29 days or over 30 fails the row; perl ages them because
# `touch -d` spells a relative date on GNU alone.
perl -e '$t = time - $ARGV[0] * 86400; utime($t, $t, $ARGV[1]) or die "utime: $!\n"' 29 "$COP_LEADS/s1"
perl -e '$t = time - $ARGV[0] * 86400; utime($t, $t, $ARGV[1]) or die "utime: $!\n"' 31 "$COP_LEADS/s2"
touch -t 200001010000 "$COP_LEADS/crashed"
# The pending reading markers beside them, on the same window.
COP_USAGE="$COP_HOME/.cache/lane-mail/copilot-usage"
mkdir -p "$COP_USAGE"
: > "$COP_USAGE/young"
: > "$COP_USAGE/old"
perl -e '$t = time - $ARGV[0] * 86400; utime($t, $t, $ARGV[1]) or die "utime: $!\n"' 29 "$COP_USAGE/young"
perl -e '$t = time - $ARGV[0] * 86400; utime($t, $t, $ARGV[1]) or die "utime: $!\n"' 31 "$COP_USAGE/old"
COP_SESSION=s3 copilot_context start
assert_eq "RC=$RC stderr=$(first_line) recorded=$(cop_recorded) pending=$(ls "$COP_USAGE" | paste -sd, -)" \
  "RC=0 stderr=- recorded=s1,s3 pending=young" \
  "a session start prunes the records and pending markers untouched for 30 days and keeps the younger ones"
COP_SESSION=crashed copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC recorded=$(cop_recorded)" "RC=0 recorded=s1,s3" \
  "a stop whose session is not the one its transcript is named for records nothing"
# find replaced on PATH by one that fails, as an unreadable records directory
# would make it.
FAKE_FIND_BIN="$TMP_ROOT/fake-find-bin"
mkdir -p "$FAKE_FIND_BIN"
printf '#!/bin/sh\necho "find: planted failure" >&2\nexit 1\n' > "$FAKE_FIND_BIN/find"
chmod +x "$FAKE_FIND_BIN/find"
CALL_ENV=("HOME=$COP_HOME" "PATH=$FAKE_FIND_BIN:$PATH")
copilot_context start
CALL_ENV=("HOME=$COP_HOME")
assert_eq "RC=$RC keys=$(hook_keys) cause=$(grep -cxF 'find: planted failure' "$ERR_FILE")" \
  "RC=0 keys=leads-unpruned=$COP_LEADS;leads-unpruned=$COP_USAGE cause=2" \
  "a prune that fails is reported for each directory with its cause, and the start still passes"

# A lead whose record cannot be written: reported and never refused, and its
# tool calls are then a session the judge cannot name, handed no mail, while
# its turn end still hands the lines over.
cop_unrecordable
copilot_context start
assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$TMP_ROOT/stdout")" \
  "RC=0 first=lane-mail-check: lead-unrecorded=$COP_LEADS/s1 stdout=" \
  "a start whose record cannot be written reports it on stderr and passes"
send KEN-203 'Unrecorded.'
copilot_tool deliver
assert_eq "RC=$RC stderr=$(first_line) unread=$(lane_unread KEN-203 'Unrecorded.')" \
  "RC=0 stderr=lane-mail-check: session-unrecorded=s1 unread=1" \
  "that lead's finished call is handed nothing"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision) reason=$(stdout_field .reason | head -n 1) unread=$(lane_unread KEN-203 'Unrecorded.')" \
  "RC=0 first=lane-mail-check: lead-unrecorded=$COP_LEADS/s1 decision=block reason=lane-mail-check: unread=1 unread=0" \
  "its turn end reports the record again and is held with the lines, acknowledging them"
cop_clear_leads
CASE_HOOK="$LANE/.github/hooks/lane-mail-start.sh" run_payload '{"timestamp":1,"cwd":"/w","source":"new"}'
assert_eq "RC=$RC first=$(first_line) recorded=$(cop_recorded)" \
  "RC=0 first=lane-mail-check: lead-unrecorded=none recorded=" \
  "a session start naming no session id reports that it records none"

# A refusal after a Copilot tool call is handed over as context at exit 0:
# Copilot logs a postToolUse exit 2 for the user and never shows the model.
new_copilot_lane copilot_deliver_refuse ken-209
send KEN-209 'Unreachable.'
rm -f -- "${LANE:?}/.claude/skills/orch" "${LANE:?}/.agents/skills/orch/scripts"
rm -f -- "${LANE:?}/.claude/skills/mailbox" "${LANE:?}/.agents/skills/mailbox/scripts"
copilot_tool deliver
assert_eq "RC=$RC first=$(first_line) context=$(stdout_field '.additionalContext' | head -n 1)" \
  "RC=0 first=lane-mail-check: reader=$LANE/.agents/skills/mailbox/scripts/lane-mail context=lane-mail-check: reader=$LANE/.agents/skills/mailbox/scripts/lane-mail" \
  "a Copilot deliver run with no reader hands the keyed refusal over as additionalContext"

# The start and prompt arms, one row set per arm: at a Copilot session start
# and at each prompt the unread lines are handed over under the same top-level
# key. Only session start acknowledges it. Nothing is ever refused.
COP_CONTEXT_N=230
for arm in start prompt; do
  COP_CONTEXT_N=$((COP_CONTEXT_N + 1))
  item="KEN-$COP_CONTEXT_N"
  new_copilot_lane "copilot_$arm" "ken-$COP_CONTEXT_N"
  mkdir -p "$LANE/tmp/lane-mail/$item"
  copilot_context "$arm"
  assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") stderr=$(first_line)" "RC=0 stdout= stderr=-" \
    "$arm: a lane with no mail gets no output"
  send "$item" 'Rebase first.'
  copilot_context "$arm"
  assert_eq "RC=$RC context=$(stdout_field '.additionalContext' | head -n 1) nested=$(stdout_field '.hookSpecificOutput') stderr=$(first_line)" \
    "RC=0 context=lane-mail-check: unread=1 nested=null stderr=-" \
    "$arm: the unread lines are handed over under the top-level additionalContext"
  case "$arm" in
    start) expected_unread=0 ;;
    prompt) expected_unread=1 ;;
  esac
  assert_eq "$(stdout_field '.additionalContext' | grep -cF 'Rebase first.') $(lane_unread "$item" 'Rebase first.')" "1 $expected_unread" \
    "$arm: context carries the directive and only session start marks it read"
  (cd "$LANE" && "$LANE_MAIL" inbox --item "$item" --root "$LANE") > "$TMP_ROOT/context-inbox"
  assert_eq "$(jq -s 'map(select(.text == "Rebase first.")) | length' "$TMP_ROOT/context-inbox")" "$expected_unread" \
    "$arm: plain inbox prints any directive the hook left unread"
  copilot_context "$arm"
  assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 stdout=" "$arm: after inbox the next run carries no mail"

  send "$item" 'Then push.'
  copilot_context_unwritable "$arm"
  assert_eq "RC=$RC first=$(first_line) unread=$(lane_unread "$item" 'Then push.')" \
    "RC=0 first=lane-mail-check: notice=unwritten unread=1" \
    "$arm: a context that cannot be written is reported at exit 0 and leaves the directive unread"
  copilot_context "$arm" agent_id
  assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") stderr=$(first_line) unread=$(lane_unread "$item" 'Then push.')" \
    "RC=0 stdout= stderr=- unread=1" "$arm: a subagent's run is handed nothing and acknowledges nothing"
  copilot_context "$arm" agent_type
  assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") unread=$(lane_unread "$item" 'Then push.')" \
    "RC=0 stdout= unread=1" "$arm: and so is one marked by agent_type"
  copilot_context "$arm"
  assert_eq "RC=$RC context=$(stdout_field '.additionalContext' | head -n 1)" "RC=0 context=lane-mail-check: unread=1" \
    "$arm: the lead's next run is handed the directive the failed write and the subagent left"
  (cd "$LANE" && "$LANE_MAIL" inbox --item "$item" --root "$LANE") > "$TMP_ROOT/context-inbox"

  # A mailbox no launch recorded is no lane: its mail is handed to nobody.
  send "$item" 'Not a lane.'
  unmark_lanes
  copilot_context "$arm"
  assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") stderr=$(first_line) unread=$(lane_unread "$item" 'Not a lane.')" \
    "RC=0 stdout= stderr=- unread=1" "$arm: a session that is no lane gets no output"

  # What the judge refuses at a turn end is reported here and passed.
  new_copilot_lane "copilot_${arm}_missing" "ken-$COP_CONTEXT_N"
  copilot_context "$arm"
  assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$TMP_ROOT/stdout")" \
    "RC=0 first=lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail stdout=" \
    "$arm: a refusal the judge makes is its keyed line on stderr at exit 0, never a refused $arm"
  rm -f -- "${LANE:?}/.github/hooks/lane-mail-check.sh"
  copilot_context "$arm"
  expect 0 "lane-mail-$arm: judge=$LANE/.github/hooks/lane-mail-check.sh" \
    "$arm: the hook with no judge beside it reports the gap and passes"
done

# jq off PATH on a Copilot lane: the refusal is still the documented block
# answer, built without it, so a turn end nothing can judge is held rather
# than logged and skipped. The PATH holds the two commands the refusal
# reaches before the dependency check: the shell, and cat for the check's
# own list.
NOJQ_BIN="$TMP_ROOT/nojq-bin"
mkdir -p "$NOJQ_BIN"
ln -s -f -n "$(command -v bash)" "$NOJQ_BIN/bash"
ln -s -f -n "$(command -v cat)" "$NOJQ_BIN/cat"
new_copilot_lane copilot_nojq ken-206
send KEN-206 'Rebase first.'
copilot_stop "$COP_TRANSCRIPT" false "PATH=$NOJQ_BIN"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision) reason=$(stdout_field .reason | head -n 1)" \
  "RC=0 first=lane-mail-check: missing-tools=jq decision=block reason=lane-mail-check: missing-tools=jq" \
  "a Copilot turn end with jq off PATH is held with the block answer, built without jq"

# A global Copilot install under an account directory spelled any way at
# all: the harness is known by the registry document kendex writes beside the
# script, so the refusal takes the Copilot shape there too.
new_copilot_lane copilot_marker ken-207
send KEN-207 'Read from the account install.'
COP_ACCOUNT="$TMP_ROOT/cop-home/.copilot-work"
mkdir -p "$COP_ACCOUNT/skills/orch/scripts"
mkdir -p "$COP_ACCOUNT/skills/mailbox/scripts"
ln -s -f -n "$REPO_ROOT/skills/mailbox/scripts/lane-mail" "$COP_ACCOUNT/skills/mailbox/scripts/lane-mail"
plant_siblings "$COP_ACCOUNT/skills/orch/scripts"
install_hook "$HOOK" "$COP_ACCOUNT/hooks/lane-mail-check.sh"
printf '{"version":1,"hooks":{}}\n' > "$COP_ACCOUNT/hooks/lane-mail-check.json"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: unread=1 decision=block" \
  "a hook under an account directory not spelled copilot is Copilot's by the registry document beside it"

# The context mark on Copilot is judged on its recorded usage reading first and
# else on the session record its status line writes, never on the transcript:
# with neither the mark is reported unjudged and never holds a turn end,
# whatever the transcript carries.
new_copilot_lane copilot_context ken-204
mkdir -p "$LANE/tmp/lane-mail/KEN-204"
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init KEN-204 >/dev/null)
REPORT_ITEM=KEN-204
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC keyed=$(hook_keys) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 keyed=$(cop_gap KEN-204) stdout=" \
  "a Copilot lane with no unread mail and no context reading ends its turn with the context and account reported unjudged"
usage_line claude 900000 > "$COP_TRANSCRIPT"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC keyed=$(hook_keys) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 keyed=$(cop_gap KEN-204) stdout=" \
  "a Copilot transcript is never read for a figure, so a usage line past the mark does not hold the turn end"
: > "$COP_TRANSCRIPT"

# The record copilot-statusline writes under the account the session runs on,
# COPILOT_HOME, for session s1 and its transcript, then judged by the shared
# judge on the capacity the copilot adapter names: 80 percent of the window.
COP_ACCOUNT="$TMP_ROOT/cop-account"
cop_record() { # TOKENS WINDOW [TRANSCRIPT] [ALLOW_ALL]
  jq -nc --arg t "${3:-$COP_TRANSCRIPT}" --argjson n "$1" --argjson w "$2" --arg a "${4:-}" \
    '{session_id:"s1", transcript_path:$t, model:{id:"claude-opus-5"},
      context_window:{current_context_tokens:$n, context_window_size:$w}}
     + (if $a == "" then {} else {allow_all_enabled: ($a == "true")} end)' |
    COPILOT_HOME="$COP_ACCOUNT" "$REPO_ROOT/skills/orch/scripts/copilot-statusline" >/dev/null
}
cop_context_recorded() { # the reading the hook recorded in the lane's mailbox
  jq -c '[.harness, .tokens, .window, .model]' "$LANE/tmp/lane-mail/KEN-204/context.json" 2>/dev/null || echo none
}
# COPILOT_HOME names the account, which `lanes` lists and reads no stored login in:
# the account is unmeasured until the login row below.
cop_record 100000 1000000
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT"
assert_eq "RC=$RC keyed=$(hook_keys) recorded=$(cop_context_recorded)" \
  'RC=0 keyed=account=unmeasured recorded=["copilot",100000,800000,"claude-opus-5"]' \
  "a Copilot lane's fresh record is read, recorded with the compaction point as capacity, and judged room"
cop_record 400000 1000000
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: context=400000 decision=block" \
  "with no extension reading of the session, a fresh status-line record at the 400000-token cap holds the turn end with the documented block answer"
cop_record 130000 200000
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT"
assert_eq "RC=$RC first=$(first_line)" "RC=0 first=lane-mail-check: context=130000" \
  "a 200K window is judged on its own compaction point, past half of 160000"
cop_record 400000 1000000 "$TMP_ROOT/session-state/s2/events.jsonl"
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT"
assert_eq "RC=$RC keyed=$(hook_keys)" "RC=0 keyed=reading-unrecorded=$LANE/tmp/lane-mail/KEN-204/context.json;session-record=wrong-transcript;account=unmeasured" \
  "a record naming another transcript is unmeasured, never read as this session's"
cop_record 400000 1000000
jq -c '.written_at = 1' "$COP_ACCOUNT/lane-status/s1.json" > "$TMP_ROOT/stale.json"
mv -- "$TMP_ROOT/stale.json" "$COP_ACCOUNT/lane-status/s1.json"
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT"
assert_eq "RC=$RC keyed=$(hook_keys)" "RC=0 keyed=reading-unrecorded=$LANE/tmp/lane-mail/KEN-204/context.json;session-record=stale;account=unmeasured" \
  "a record the status line stopped refreshing is unmeasured, never read as room"
# The extension's reading is read first: one below the mark stands although
# the status line's record of the same session is past it.
# cop_extension_reading ITEM TOKENS CAPACITY [SESSION]: the reading the usage
# arm records for SESSION, s1 by default, in the lane's mailbox, under the
# capacity source it writes.
cop_extension_reading() { # ITEM TOKENS CAPACITY [SESSION]
  bash -c 'set -euo pipefail; . "$1/lib/lane-context.sh"
    lane_context_record "$2" copilot "$3" "$4" "" "$5" "" "" "$LANE_CONTEXT_COPILOT_CAPACITY_SOURCE"' \
    _ "$REPO_ROOT/skills/orch/scripts" "$LANE/tmp/lane-mail/$1" "$2" "$3" "${4:-s1}"
}
# cop_gap_record ITEM: the gap record an overseer's turn end that took no
# reading writes for s1 (overseer_gap_record): no figure, no capacity source.
cop_gap_record() { # ITEM
  bash -c 'set -euo pipefail; . "$1/lib/lane-context.sh"
    lane_context_record "$2" copilot null "" "" s1 "" pane-unrecorded' \
    _ "$REPO_ROOT/skills/orch/scripts" "$LANE/tmp/lane-mail/$1"
}
cop_record 400000 1000000
cop_extension_reading KEN-204 100000 800000
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT"
assert_eq "RC=$RC keyed=$(hook_keys) decision=$(stdout_field .decision)" "RC=0 keyed=account=unmeasured decision=" \
  "an extension reading below the mark is judged room, never overridden by a status-line record past it"
# A record that is no extension reading of this session is passed over for
# the status-line record: a predecessor's in the same mailbox, and a gap record.
cop_record 400000 1000000
cop_extension_reading KEN-204 100000 800000 s0
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: context=400000 decision=block" \
  "an extension reading of another session gives way to this session's fresh status-line record past the mark"
cop_record 400000 1000000
cop_gap_record KEN-204
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: context=400000 decision=block" \
  "a gap record gives way to this session's fresh status-line record past the mark"
rm -f -- "${LANE:?}/tmp/lane-mail/KEN-204/context.json"

# A record reporting allow_all_enabled false in a session its launch line
# granted allow-all, COPILOT_ALLOW_ALL=true, is a policy stop, reported under
# its own cause at the turn end the lane reaches, and the turn end is still
# judged: at the cap it is held. A launch without allow-all carries
# COPILOT_ALLOW_ALL empty (lib/lane-launch.sh lane_copilot_env) and reads
# false by design, so it names none; true names none. The extension's reading
# carries no allow_all_enabled, so where one stands the record is still read
# for the cause, and the context judged on the extension's reading.
while IFS='|' read -r allow grant extension want; do
  cop_record 400000 1000000 "" "$allow"
  [ -z "$extension" ] || cop_extension_reading KEN-204 "$extension" 800000
  copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT" "COPILOT_ALLOW_ALL=$grant"
  assert_eq "RC=$RC keyed=$(hook_keys) decision=$(stdout_field .decision)" "RC=0 keyed=$want decision=block" \
    "a record at the cap whose allow_all_enabled is $allow at the turn end, COPILOT_ALLOW_ALL=[$grant], extension reading [$extension]"
  rm -f -- "${LANE:?}/tmp/lane-mail/KEN-204/context.json"
done <<'ROWS'
false|true||stop-cause=allow-all-blocked-by-policy;context=400000
false|||context=400000
true|true||context=400000
false|true|700000|stop-cause=allow-all-blocked-by-policy;context=700000
true|true|700000|context=700000
ROWS

# The account mark on Copilot: the account the session runs on is measured
# through `lanes`, and a pool at zero holds the turn end at the headroom mark.
cop_record 100000 1000000
printf '{"copilot_tokens":"gho_test"}\n' > "$COP_ACCOUNT/config.json"
COP_FETCH="$TMP_ROOT/cop-fetch"
printf '#!/bin/sh\nprintf "200 \\n"\nprintf "%%s\\n" "$COP_POOL"\n' > "$COP_FETCH"
chmod +x "$COP_FETCH"
COP_SPENT='{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":0,"overage_permitted":true}}}'
COP_ROOM='{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":900}}}'
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT" "ORCH_LANES_FETCH_CMD=$COP_FETCH" "COP_POOL=$COP_SPENT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: headroom=0 bucket=monthly mark=3 decision=block" \
  "a Copilot account whose pool is at zero holds the turn end, overage permitted or not"
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT" "ORCH_LANES_FETCH_CMD=$COP_FETCH" "COP_POOL=$COP_ROOM" "ORCH_LANES_USAGE_TTL=0"
assert_eq "RC=$RC keyed=$(hook_keys) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 keyed= stdout=" \
  "a Copilot account with room and a fresh record end the turn with nothing to report"
rm -f -- "${COP_ACCOUNT:?}/config.json"

# The idle judge on Copilot: a lead that sent nothing through lane mail is held
# with the documented block answer, and on the turn Copilot continued the
# overseer is sent the lane notice and nothing holds the turn.
new_copilot_lane copilot_idle ken-205
mkdir -p "$LANE/tmp/lane-mail/KEN-205"
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init KEN-205 >/dev/null)
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC keyed=$(hook_keys) decision=$(stdout_field .decision) reason=$(stdout_field .reason | head -n 1)" \
  "RC=0 keyed=$(cop_gap KEN-205);idle=KEN-205 decision=block reason=lane-mail-check: idle=KEN-205" \
  "a Copilot lead that sent nothing is held with the block answer, the idle refusal its reason"
copilot_stop "$COP_TRANSCRIPT" true
assert_eq "RC=$RC keyed=$(hook_keys) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 keyed=$(cop_gap KEN-205);idle-notice=KEN-205 stdout=" \
  "the turn Copilot continued is reported to the overseer and not held"

# --- the checkout's overseer mailbox --------------------------------------
# The overseer mailbox has one reader, the session the checkout's fleet record
# names by tmux server and pane. A second Copilot session in the checkout, in
# another pane of the same server, is handed nothing at its session start, its
# prompt, after a tool call or at its turn end; the named session is handed
# the note once. The named session's turn end is lane-mail-check.test.sh's:
# it is the overseer's, whose marks a judge rules on.
new_copilot_named() { # NAME
  new_copilot_lane "$1" main
  # Mailbox delivery uses a configured reader. The missing-reader SessionStart
  # rule has its own fixture in orch/tests/oversee_launch.sh.
  env -i PATH="$PATH" HOME="$COP_HOME" bash -euo pipefail -c \
    '. "$1/lib/lane-context.sh" && copilot_context_install "$2"' \
    _ "$REPO_ROOT/skills/orch/scripts" "$COP_HOME/.copilot"
  unmark_lanes
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init oversee >/dev/null)
  record_overseer "$OVERSEER_PANE" "$OVERSEER_SERVER"
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" update oversee '.overseer.home = null' >/dev/null)
}
# shellcheck disable=SC2207
COP_OTHER_ENV=("HOME=$COP_HOME" $(overseer_env %3))
# shellcheck disable=SC2207
COP_NAMED_ENV=("HOME=$COP_HOME" $(overseer_env))
# The prompt-mode child inherits the pane, both harness homes and its own
# native payload id. It must leave every persisted overseer mailbox file alone.
copilot_child() { # NAME ARM [RECORD_KIND] [NATIVE_LIB]
  new_copilot_named "$1"
  plant_copilot_install oversee-succeed
  plant_judge "$LANE/.github/skills/orch/scripts"
  judge_says "$BELOW_MARK_LINE"
  if [ "${3:-full}" = harness-only ]; then
    (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" update oversee '.overseer.harness = "pi" | .overseer.home = null | del(.overseer.session_id)' >/dev/null)
  else
    bind_overseer claude "$OVERSEER_HOME_DIR" parent
  fi
  if [ -n "${4:-}" ]; then
    hole_install lib/overseer-launch.sh "$LANE/.github/skills/orch/scripts"
    cp -- "$4" "$LANE/.github/skills/orch/scripts/lib/overseer-launch.sh"
  fi
  mkdir -p "$LANE/tmp/lane-mail/overseer"
  printf '%s\n' '{"session_id":"parent","tokens":366308}' > "$LANE/tmp/lane-mail/overseer/context.json"
  printf '%s\n' 'parent previous-gap' > "$LANE/tmp/lane-mail/overseer/context-told"
  peer_send 'Parent only.'
  local before state_before
  before=$(overseer_snapshot)
  state_before=$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" get oversee .overseer)
  CALL_ENV=("${COP_NAMED_ENV[@]}" "COPILOT_HOME=$COP_HOME/.copilot")
  case "$2" in
    start) copilot_context start ;;
    deliver) copilot_tool deliver ;;
    stop) copilot_stop "$COP_TRANSCRIPT" ;;
    usage)
      ARM_ARGS=(usage)
      run_payload '{"session_id":"s1","current_tokens":123442,"token_limit":1000000}'
      ARM_ARGS=() ;;
  esac
  CALL_ENV=("HOME=$COP_HOME")
  CHILD_RESULT="RC=$RC stdout=$(cat "$TMP_ROOT/stdout") unchanged=$([ "$before" = "$(overseer_snapshot)" ] && echo yes || echo no) state=$([ "$state_before" = "$(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" get oversee .overseer)" ] && echo same || echo changed) judged=$(judge_calls)"
}
for child_arm in deliver stop usage start; do
  copilot_child "native_copilot_$child_arm" "$child_arm"
  assert_eq "$CHILD_RESULT" 'RC=0 stdout= unchanged=yes state=same judged=0' \
    "$child_arm: a Copilot child in the Claude pane receives no mail and writes no context or gap"
  assert_eq "$(first_line)|$(wc -l < "$ERR_FILE" | tr -d ' ')" \
    "lane-mail-check: session-unbound=s1 harness=claude home=$OVERSEER_HOME_DIR remedy=oversee register|1" \
    "the child receives one session diagnostic and no missing-reader notice for the Claude home"
done
for child_arm in deliver stop usage start; do
  copilot_child "native_harness_$child_arm" "$child_arm" harness-only
  assert_eq "$CHILD_RESULT" 'RC=0 stdout= unchanged=yes state=same judged=0' \
    "$child_arm: the recorded harness alone refuses a child before the first session binding"
  assert_eq "$(first_line)|$(wc -l < "$ERR_FILE" | tr -d ' ')" \
    'lane-mail-check: session-unbound=s1 harness=pi home=none remedy=oversee register|1' \
    'the harness-only refusal gives one stderr diagnostic'
done
wake_mutant native-harness-control '    and ((.harness // "") == "" or .harness == $harness)' '    and true' "$REPO_ROOT/skills/orch/scripts/lib/overseer-launch.sh"
copilot_child native_harness_control_deliver deliver harness-only "$MUTANT_PATH"
assert_eq "$([ "$CHILD_RESULT" = 'RC=0 stdout= unchanged=yes state=same judged=0' ] && echo accepted || echo rejected)" rejected \
  "control: dropping only the harness rule fails the same deliver refusal assertion"

new_copilot_named native_copilot_reader
CALL_ENV=("${COP_NAMED_ENV[@]}" "COPILOT_HOME=$COP_HOME/.copilot")
copilot_context start
assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") stderr=$(first_line)" 'RC=0 stdout= stderr=-' \
  'the native Copilot start reads its installed reader from its own home'
CALL_ENV=("HOME=$COP_HOME")

new_copilot_named copilot_overseer
peer_send 'For the named session.'
CALL_ENV=("${COP_OTHER_ENV[@]}")
for arm in start prompt deliver stop; do
  case "$arm" in
    start | prompt) copilot_context "$arm" ;;
    deliver) copilot_tool deliver ;;
    stop) copilot_stop "$COP_TRANSCRIPT" ;;
  esac
  assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") stderr=$(first_line)" "RC=0 stdout= stderr=-" \
    "$arm: a second Copilot session in another pane is handed nothing from the overseer mailbox"
done
CALL_ENV=("HOME=$COP_HOME")
assert_eq "$(overseer_unread 'For the named session.')" "1" "and the note stays unread for the named session"
CALL_ENV=("${COP_NAMED_ENV[@]}")
copilot_context start
assert_eq "RC=$RC context=$(stdout_field '.additionalContext | split("\n") | map(select(startswith("lane-mail-check: "))) | map(split(" ")[0:2] | join(" ")) | join(";")') carried=$(stdout_field '.additionalContext' | grep -cF 'For the named session.')" \
  "RC=0 context=lane-mail-check: context-reader=missing;lane-mail-check: unread=1 carried=1" \
  "the named Copilot session is handed the missing-reader notice above the note at its session start"
copilot_context prompt
CALL_ENV=("HOME=$COP_HOME")
assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout") unread=$(overseer_unread 'For the named session.')" "RC=0 stdout= unread=0" \
  "and marks it read, so its next prompt is handed nothing"

# Copilot CLI 1.0.91 runs userPromptSubmitted on a background-command
# completion and can discard its response. No prompt-field discriminator is
# trusted: drive the production prompt wrapper for both payload classes,
# discard its context, then read the owner body through the real inbox.
copilot_prompt_inbox() { # NAME PROMPT
  new_copilot_named "$1"
  peer_send 'Read this owner body.'
  local owner_id judge inbox second
  owner_id=$(jq -r '.id' "$LANE/tmp/lane-mail/overseer/to-lane.jsonl")
  judge="$CASE_HOOK"
  CASE_HOOK="$LANE/.github/hooks/lane-mail-prompt.sh"
  CALL_ENV=("${COP_NAMED_ENV[@]}")
  run_payload "$(jq -nc --arg prompt "$2" \
    '{sessionId:"s1",timestamp:1,cwd:"/w"} + (if $prompt == "" then {} else {prompt:$prompt} end)')"
  CASE_HOOK="$judge"
  CALL_ENV=("HOME=$COP_HOME")
  PROMPT_STATUS=$RC
  : > "$TMP_ROOT/stdout"
  inbox=$(cd "$LANE" && "$LANE_MAIL" inbox --item overseer --root "$LANE")
  second=$(cd "$LANE" && "$LANE_MAIL" inbox --item overseer --root "$LANE")
  PROMPT_INBOX=$(jq -s --arg id "$owner_id" \
    'map(select(.id == $id and .text == "Read this owner body.")) | length' <<<"$inbox")
  PROMPT_SECOND=$second
}
for prompt_case in absent typed; do
  case "$prompt_case" in
    absent) prompt_text="" ;;
    typed) prompt_text='Carry on.' ;;
  esac
  copilot_prompt_inbox "copilot_completion_$prompt_case" "$prompt_text"
  assert_eq "RC=$PROMPT_STATUS body=$PROMPT_INBOX second=$PROMPT_SECOND" 'RC=0 body=1 second=' \
    "$prompt_case: discarded prompt context leaves the owner body for one real inbox read"
done

# The overseer's tool-call judgement requires the Copilot lead cache even
# when the native ID matches. A missing cache leaves that caller unknown,
# judged on nothing and writing no overseer context record.
unknown_tool_rows() { # NAME
  new_copilot_named "$1"
  # Isolate the missing lead-cache rule from a native-ID mismatch.
  (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" update oversee '.overseer.session_id = "c1"' >/dev/null)
  mkdir -p "$LANE/tmp/lane-mail/overseer"
  CALL_ENV=("${COP_NAMED_ENV[@]}")
  COP_SESSION=c1
  copilot_tool deliver
  COP_SESSION=s1
  CALL_ENV=("HOME=$COP_HOME")
  UNKNOWN_TOOL="RC=$RC stdout=$(cat "$TMP_ROOT/stdout") record=$([ -e "$LANE/tmp/lane-mail/overseer/context.json" ] && echo written || echo none)"
}
unknown_tool_rows copilot_overseer_unknown_tool
assert_eq "$UNKNOWN_TOOL" "RC=0 stdout= record=none" \
  "a Copilot call in the named pane from no recorded lead is judged on nothing and writes no context record" "$ERR_FILE"

# A crossed mark and a mailbox refusal on the same Copilot tool call: the
# refusal's additionalContext opens with the context mark, so the refusal
# never withholds it. The context is the session record the account's status
# line writes, and the refusal is the watch library read failing.
refused_mark_rows() { # NAME
  new_copilot_named "$1"
  plant_copilot_install
  mkdir -p "$LANE/tmp/lane-mail/overseer" "$COP_LEADS"
  : > "$COP_LEADS/s1"
  cop_record 400000 1000000
  peer_send 'Beside a crossed mark.'
  watch_stub "$LANE/.github/skills/orch/scripts"
  CALL_ENV=("${COP_NAMED_ENV[@]}" "COPILOT_HOME=$COP_ACCOUNT")
  copilot_tool deliver
  CALL_ENV=("HOME=$COP_HOME")
  REFUSED_MARK="RC=$RC context=$(stdout_field '.additionalContext' | head -n 1) fleet=$(stdout_field '.additionalContext' | grep -c '^lane-mail-check: fleet-state=')"
}
refused_mark_rows copilot_overseer_refused_mark
assert_eq "$REFUSED_MARK" "RC=0 context=lane-mail-check: context=400000 fleet=1" \
  "a Copilot tool call past the mark whose mailbox check refuses hands the mark over ahead of the refusal" "$ERR_FILE"

# --- a Copilot call reaching the Claude copy ------------------------------
# Copilot runs a Claude copy registered in `.claude/settings.json` by hand or
# by kendex before the Copilot skip, where no refresh has rewritten it,
# kendex's own current registration exiting before the script
# (docs/adapters/claude.md § Cross-reads), under its PascalCase name, and
# hands it the snake_case format
# its reference gives: `hook_event_name`, an ISO 8601 `timestamp` and the
# Claude tool name. Each row installs both copies, the Claude one under
# `.claude/hooks` and the Copilot one under `.github/hooks`, and runs the
# Claude script as that registration would. FORMAT
# pascal is that referenced format; camel is Copilot's own format with no
# `timestamp`, which only the `sessionId` spelling marks as Copilot's.
install_claude_copy() {
  install_hook "$TEST_DIR/../lane-mail-deliver.sh" "$LANE/.claude/hooks/lane-mail-deliver.sh"
  install_hook "$TEST_DIR/../lane-mail-halt.sh" "$LANE/.claude/hooks/lane-mail-halt.sh"
  install_hook "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
  CASE_HOOK="$LANE/.github/hooks/lane-mail-check.sh"
}
claude_copy() { # stop|halt|deliver pascal|camel
  local judge="$CASE_HOOK" payload
  CASE_HOOK="$LANE/.claude/hooks/lane-mail-$1.sh"
  [ "$1" != stop ] || CASE_HOOK="$LANE/.claude/hooks/lane-mail-check.sh"
  payload=$(jq -nc --arg arm "$1" --arg format "$2" --arg p "$COP_TRANSCRIPT" '
    if $format == "pascal" then
      {session_id:"s1", timestamp:"2026-09-28T00:00:00.000Z", cwd:"/w"}
      + if $arm == "stop" then
          {hook_event_name:"Stop", transcript_path:$p, stop_reason:"end_turn", stop_hook_active:false}
        else
          {hook_event_name:(if $arm == "halt" then "PreToolUse" else "PostToolUse" end),
           tool_name:"Bash", tool_input:{command:"git status"}}
        end
    elif $arm == "stop" then {sessionId:"s1", transcriptPath:$p, stop_hook_active:false}
    else {sessionId:"s1", toolName:"bash", toolArgs:{command:"git status"}}
    end')
  run_payload "$payload"
  CASE_HOOK="$judge"
}
# Silence on both streams and the mailbox left as it was.
claude_copy_quiet() { # ITEM TEXT
  printf 'RC=%s stdout=%s stderr=%s unread=%s' "$RC" "$(cat "$TMP_ROOT/stdout")" "$(first_line)" "$(lane_unread "$1" "$2")"
}

new_copilot_lane copilot_cross ken-250
install_claude_copy
send KEN-250 'Rebase first.'
for format in pascal camel; do
  for arm in deliver stop; do
    claude_copy "$arm" "$format"
    assert_eq "$(claude_copy_quiet KEN-250 'Rebase first.')" "RC=0 stdout= stderr=- unread=1" \
      "$format $arm: a Copilot call through the Claude copy passes silently and leaves the directive unread"
  done
done
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC decision=$(stdout_field .decision) unread=$(lane_unread KEN-250 'Rebase first.')" \
  "RC=0 decision=block unread=0" "the Copilot copy beside it holds the lead's turn end with the directive, acknowledging it there"
send KEN-250 'Then push.'
copilot_tool deliver
assert_eq "RC=$RC context=$(stdout_field '.additionalContext' | head -n 1) carried=$(stdout_field '.additionalContext' | grep -cF 'Then push.')" \
  "RC=0 context=lane-mail-check: unread=1 carried=1" \
  "and hands the lead that turn end recorded the next directive after a tool call"

new_copilot_lane copilot_cross_halt ken-251
install_claude_copy
send KEN-251 'Stop pushing.' --halt
HALT_251=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-251/to-lane.jsonl")
for format in pascal camel; do
  claude_copy halt "$format"
  assert_eq "$(claude_copy_quiet KEN-251 'Stop pushing.')" "RC=0 stdout= stderr=- unread=1" \
    "$format halt: a Copilot call through the Claude copy is neither refused nor shown the halt"
done
copilot_tool halt
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .permissionDecision)" \
  "RC=2 first=lane-mail-check: halt=$HALT_251 decision=deny" \
  "the Copilot copy beside it still denies the call while the halt stands"

# A Claude call is still the Claude copy's: the rule reads the call, so the
# same install refuses a Claude turn end as before.
CASE_HOOK="$LANE/.claude/hooks/lane-mail-check.sh"
run_payload '{"session_id":"s1","hook_event_name":"Stop","stop_hook_active":false}'
CASE_HOOK="$LANE/.github/hooks/lane-mail-check.sh"
expect 2 "lane-mail-check: unread=1" "a Claude turn end through the same copy is refused as before"

# --- copilot controls ----------------------------------------------------
# The block answer removed: the mail is acknowledged and the turn ends in
# silence, which is the loss the answer exists to prevent.
mutant copilot-no-block -e "s@^      stop) printf '{\"decision\":\"block\".*@      stop) : ;;@"
new_copilot_lane control_cop_block ken-213 "$MUTANT_PATH"
send KEN-213 'Rebase onto main.'
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 first=lane-mail-check: unread=1 stdout=" \
  "control: without the block answer a Copilot turn end passes with the directive acknowledged unseen"

# The Copilot arm of the context read cut: a Copilot turn end falls to the
# transcript read, which holds no count, and a record at the cap no longer
# holds it. Held to the context read, so the block answer refuse() writes for
# Copilot stands.
MUTANT_SOURCE="$REPO_ROOT/skills/orch/scripts/lib/lane-context.sh" mutant copilot-no-record -e '/^context_read_and_record() {/,/^}/s@^  if \[ "\$HARNESS" = copilot \]; then$@  if false; then@'
CONTEXT_LIB_VARIANT="$MUTANT_PATH" new_copilot_lane control_cop_record ken-217
mkdir -p "$LANE/tmp/lane-mail/KEN-217"
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init KEN-217 >/dev/null)
REPORT_ITEM=KEN-217
cop_record 400000 1000000
copilot_stop "$COP_TRANSCRIPT" "" "COPILOT_HOME=$COP_ACCOUNT"
assert_eq "RC=$RC decision=$(stdout_field .decision)" "RC=0 decision=" \
  "control: without the record read a Copilot lane at the cap ends its turn"

# Each wrapper: its arm swapped for deliver, which answers a refusal on
# stdout where its own arm only reports it on stderr.
COP_CONTEXT_N=241
for arm in start prompt; do
  COP_CONTEXT_N=$((COP_CONTEXT_N + 1))
  MUTANT_SOURCE="$TEST_DIR/../lane-mail-$arm.sh" mutant "$arm-as-deliver" \
    -e "s@ \"\\\$JUDGE\" $arm\$@ \"\\\$JUDGE\" deliver@"
  new_copilot_lane "control_${arm}_arm" "ken-$COP_CONTEXT_N"
  install_hook "$MUTANT_PATH" "$LANE/.github/hooks/lane-mail-$arm.sh"
  copilot_context "$arm"
  assert_eq "RC=$RC context=$(stdout_field .additionalContext | head -n 1)" \
    "RC=0 context=lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
    "control: the $arm hook running the deliver arm answers what its own arm only reports"
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
