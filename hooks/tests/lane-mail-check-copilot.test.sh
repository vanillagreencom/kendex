#!/usr/bin/env bash
# lane-mail-check on Copilot: the lane-mail hooks installed where kendex
# renders them for Copilot, run with the payloads Copilot's hooks reference
# gives, and a Copilot call reaching the Claude copy `.claude/settings.json`
# registers, which Copilot also runs. The shared world is
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
# Copilot's hooks reference gives for its event, not a captured one. Two
# shapes are assumed, not referenced: a subagent's agentStop naming a
# transcript outside `session-state/<sessionId>/` (the copilot_stop rows
# passing one), and a sessionStart or prompt payload carrying agent_id or
# agent_type (the copilot_context rows passing FIELD).
new_copilot_lane() { # NAME BRANCH [JUDGE]
  new_lane "$1" "$2"
  rm -f -- "${LANE:?}/.claude/hooks/lane-mail-check.sh"
  install_hook "$TEST_DIR/../lane-mail-deliver.sh" "$LANE/.github/hooks/lane-mail-deliver.sh"
  install_hook "$TEST_DIR/../lane-mail-halt.sh" "$LANE/.github/hooks/lane-mail-halt.sh"
  install_hook "$TEST_DIR/../lane-mail-start.sh" "$LANE/.github/hooks/lane-mail-start.sh"
  install_hook "$TEST_DIR/../lane-mail-prompt.sh" "$LANE/.github/hooks/lane-mail-prompt.sh"
  install_hook "${3:-$HOOK}" "$LANE/.github/hooks/lane-mail-check.sh"
}
# The lead's transcript sits in the directory named for the session.
COP_TRANSCRIPT="$TMP_ROOT/session-state/s1/events.jsonl"
mkdir -p "${COP_TRANSCRIPT%/*}"
: > "$COP_TRANSCRIPT"
copilot_stop() { # TRANSCRIPT [ACTIVE] [ENV=VAL...]
  local path="$1" active="${2:-false}"
  shift; [ $# -eq 0 ] || shift
  run_payload "$(jq -nc --arg p "$path" --argjson a "$active" \
    '{sessionId:"s1", timestamp:1, cwd:"/w", transcriptPath:$p, stopReason:"end_turn", stop_hook_active:$a}')" "$@"
}
copilot_tool() { # ARM [COMMAND] [object|string]
  local judge="$CASE_HOOK" shape="${3:-object}"
  CASE_HOOK="$LANE/.github/hooks/lane-mail-$1.sh"
  run_payload "$(jq -nc --arg c "${2:-git status}" --arg shape "$shape" \
    '{sessionId:"s1", timestamp:1, cwd:"/w", toolName:"bash",
      toolArgs: (if $shape == "string" then ({command:$c} | tojson) else {command:$c} end)}')"
  CASE_HOOK="$judge"
}
# A Copilot session start or prompt, as the lane-mail-start or lane-mail-prompt
# hook beside the judge receives it: sessionStart carries `source`,
# userPromptSubmitted the prompt. FIELD, agent_id or agent_type, marks a
# subagent's run.
copilot_context() { # start|prompt [FIELD]
  local judge="$CASE_HOOK"
  CASE_HOOK="$LANE/.github/hooks/lane-mail-$1.sh"
  run_payload "$(jq -nc --arg arm "$1" --arg f "${2:-}" \
    '{sessionId:"s1", timestamp:1, cwd:"/w"}
      + (if $arm == "start" then {source:"new"} else {prompt:"Carry on."} end)
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
# A Copilot lane's passing turn end reports two gaps: the context, which no
# orch adapter reads out of a Copilot transcript, and the account, which
# `lanes` keeps no Copilot inventory for.
cop_gap() {
  printf 'harness-unlisted=%s;account=unlisted' "$LANE/.github/hooks"
}
# Every keyed value the run wrote, in order, each under its own English: the
# leading run keyed_block reads stops at the first explanation.
cop_keys() {
  sed -n 's/^lane-mail-check: \([a-z-]*=[^ ]*\).*/\1/p' "$ERR_FILE" | paste -sd';' -
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
  mkdir -p "$LANE/.github/skills/orch/scripts"
  ln -s -f -n "$REPO_ROOT/skills/orch/scripts/lane-mail" "$LANE/.github/skills/orch/scripts/lane-mail"
  plant_siblings "$LANE/.github/skills/orch/scripts" "${1:-}"
}

new_copilot_lane copilot_stop ken-201
send KEN-201 'Rebase onto main.'
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: unread=1 decision=block" \
  "a Copilot lead's turn end with unread mail is held with the documented block answer and exit 0"
assert_eq "$(stdout_field .reason | grep -c 'Rebase onto main.') $(stdout_field .reason | head -n 1)" \
  "1 lane-mail-check: unread=1" "the block reason is the refusal text, keyed line first, directive under it"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC keyed=$(cop_keys) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 keyed=$(cop_gap) stdout=" \
  "a second stop passes with the two gaps reported and no answer on stdout: the block acknowledged the mail"

send KEN-201 'Then re-arm auto-merge.'
copilot_stop "$TMP_ROOT/session-state/sub-7/events.jsonl"
assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 first=- stdout=" \
  "a stop naming a transcript under another directory is a subagent's: handed nothing, judged on nothing"
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
assert_eq "RC=$RC keyed=$(cop_keys)" "RC=0 keyed=$(cop_gap)" \
  "the turn Copilot continued after a block skips the mailbox check, as on every harness"

# The halt arm: the deny answer under exit 2. A Copilot call names no agent,
# so its deny never shows the command that reads the halt; the lead's turn
# end names it, and a Copilot call running it passes, read out of toolArgs in
# both shapes, since the reader's --ack stops short of an unread halt and a
# halt nothing could read would refuse the lead's every call.
new_copilot_lane copilot_halt ken-202
send KEN-202 'Stop pushing.' --halt
HALT_202=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-202/to-lane.jsonl")
printf -v READ_HALT_202 '%q inbox --item %q --root %q' "$LANE/.agents/skills/orch/scripts/lane-mail" KEN-202 "$LANE"
copilot_tool halt
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .permissionDecision)" \
  "RC=2 first=lane-mail-check: halt=$HALT_202 decision=deny" \
  "an unread halt denies a Copilot tool call with the documented answer under exit 2"
assert_eq "command=$(stdout_field .permissionDecisionReason | grep -cxF -- "$READ_HALT_202") directive=$(stdout_field .permissionDecisionReason | grep -cF 'Stop pushing.')" \
  "command=0 directive=1" "the deny reason carries the directive and not the command that reads it"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC decision=$(stdout_field .decision) directive=$(stdout_field .reason | grep -cF 'Stop pushing.') command=$(stdout_field .reason | grep -cxF -- "$READ_HALT_202") unread=$(lane_unread KEN-202 'Stop pushing.')" \
  "RC=0 decision=block directive=1 command=1 unread=1" \
  "the lead's turn end is held with the halt and the command that reads it, and leaves the halt unread"
copilot_tool halt
expect 2 "lane-mail-check: halt=$HALT_202" "any other call stays refused while the halt stands"
copilot_tool halt "$READ_HALT_202" string
expect 0 - "the command that reads the halt, read out of a JSON-string toolArgs, passes"
copilot_tool halt "$READ_HALT_202" object
expect 0 - "and out of an object toolArgs"
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
# reads, top-level `additionalContext`, and acknowledges none: the call names
# no agent, so the lead's turn end is where they are acknowledged.
new_copilot_lane copilot_deliver ken-203
send KEN-203 'Rebase first.'
copilot_tool deliver
assert_eq "RC=$RC context=$(stdout_field '.additionalContext' | head -n 1) nested=$(stdout_field '.hookSpecificOutput') stderr=$(first_line)" \
  "RC=0 context=lane-mail-check: unread=1 nested=null stderr=-" \
  "a finished Copilot tool call is handed the unread lines under the top-level key Copilot appends to the tool result"
assert_eq "carried=$(stdout_field '.additionalContext' | grep -cF 'Rebase first.') unread=$(lane_unread KEN-203 'Rebase first.')" \
  "carried=1 unread=1" "that context carries the directive and leaves it unread"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC decision=$(stdout_field .decision) directive=$(stdout_field .reason | grep -cF 'Rebase first.') unread=$(lane_unread KEN-203 'Rebase first.')" \
  "RC=0 decision=block directive=1 unread=0" \
  "the lead's turn end is held with the directive and acknowledges it"
copilot_tool deliver
assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 stdout=" \
  "the next finished call is handed nothing"

# A refusal after a Copilot tool call is handed over as context at exit 0:
# Copilot logs a postToolUse exit 2 for the user and never shows the model.
new_copilot_lane copilot_deliver_refuse ken-209
send KEN-209 'Unreachable.'
rm -f -- "${LANE:?}/.claude/skills/orch" "${LANE:?}/.agents/skills/orch/scripts"
copilot_tool deliver
assert_eq "RC=$RC first=$(first_line) context=$(stdout_field '.additionalContext' | head -n 1)" \
  "RC=0 first=lane-mail-check: reader=$LANE/.agents/skills/orch/scripts/lane-mail context=lane-mail-check: reader=$LANE/.agents/skills/orch/scripts/lane-mail" \
  "a Copilot deliver run with no reader hands the keyed refusal over as additionalContext"

# The start and prompt arms, one row set per arm: at a Copilot session start
# and at each prompt the unread lines are handed over under the same top-level
# key, acknowledged only once written, and nothing is ever refused.
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
  assert_eq "$(stdout_field '.additionalContext' | grep -cF 'Rebase first.') $(lane_unread "$item" 'Rebase first.')" "1 0" \
    "$arm: that context carries the directive, which then reads as read"
  copilot_context "$arm"
  assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 stdout=" "$arm: the next run hands nothing over again"

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
ln -s -f -n "$REPO_ROOT/skills/orch/scripts/lane-mail" "$COP_ACCOUNT/skills/orch/scripts/lane-mail"
plant_siblings "$COP_ACCOUNT/skills/orch/scripts"
install_hook "$HOOK" "$COP_ACCOUNT/hooks/lane-mail-check.sh"
printf '{"version":1,"hooks":{}}\n' > "$COP_ACCOUNT/hooks/lane-mail-check.json"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: unread=1 decision=block" \
  "a hook under an account directory not spelled copilot is Copilot's by the registry document beside it"

# The context mark on Copilot: no orch adapter reads a Copilot transcript, so
# the mark is reported unjudged and never holds a turn end, whatever the
# transcript carries.
new_copilot_lane copilot_context ken-204
mkdir -p "$LANE/tmp/lane-mail/KEN-204"
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init KEN-204 >/dev/null)
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC keyed=$(cop_keys) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 keyed=$(cop_gap) stdout=" \
  "a Copilot lane with no unread mail ends its turn with the context and account reported unjudged"
usage_line claude 900000 > "$COP_TRANSCRIPT"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC keyed=$(cop_keys) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 keyed=$(cop_gap) stdout=" \
  "a Copilot transcript is never read for a figure, so a usage line past the mark does not hold the turn end"
: > "$COP_TRANSCRIPT"

# --- a Copilot call reaching the Claude copy ------------------------------
# Copilot also runs the hooks `.claude/settings.json` registers, under their
# PascalCase names, and hands those the snake_case format its reference gives
# for them: `hook_event_name`, an ISO 8601 `timestamp` and the Claude tool
# name. Each row installs both copies, the Claude one the settings file names
# and the Copilot one under `.github/hooks`, and runs the Claude one. FORMAT
# pascal is that referenced format; camel is Copilot's own format with no
# `timestamp`, which only the `sessionId` spelling marks as Copilot's.
install_claude_copy() { # [JUDGE]
  install_hook "$TEST_DIR/../lane-mail-deliver.sh" "$LANE/.claude/hooks/lane-mail-deliver.sh"
  install_hook "$TEST_DIR/../lane-mail-halt.sh" "$LANE/.claude/hooks/lane-mail-halt.sh"
  install_hook "${1:-$HOOK}" "$LANE/.claude/hooks/lane-mail-check.sh"
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
copilot_tool deliver
assert_eq "RC=$RC context=$(stdout_field '.additionalContext' | head -n 1) carried=$(stdout_field '.additionalContext' | grep -cF 'Rebase first.')" \
  "RC=0 context=lane-mail-check: unread=1 carried=1" \
  "the Copilot copy beside it still hands the directive over after a tool call"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC decision=$(stdout_field .decision) unread=$(lane_unread KEN-250 'Rebase first.')" \
  "RC=0 decision=block unread=0" "and holds the lead's turn end with it, acknowledging it there"

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
# The caller rule removed: a subagent's stop then consumes the lead's mail.
mutant copilot-any-caller -e 's@^        \[ "\$TRANSCRIPT_DIR" = "\$SESSION" \] || CALLER=subagent$@        :@'
new_copilot_lane control_cop_caller ken-211 "$MUTANT_PATH"
send KEN-211 'Rebase onto main.'
copilot_stop "$TMP_ROOT/session-state/sub-7/events.jsonl"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: unread=1 decision=block" \
  "control: without the transcript rule a subagent's stop is handed the lead's directive"

# The camelCase session id unread: the session is empty, so the transcript
# rule never runs and a subagent's stop is read as the lead's.
mutant copilot-snake-session -e 's@str(either(.session_id; .sessionId))@str(.session_id)@'
new_copilot_lane control_cop_session ken-212 "$MUTANT_PATH"
send KEN-212 'Rebase onto main.'
copilot_stop "$TMP_ROOT/session-state/sub-7/events.jsonl"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: unread=1 decision=block" \
  "control: without the camelCase session read a subagent's stop is handed the lead's directive"

# The session gate on the caller rule removed: a stop naming a transcript and
# no session is a subagent's, handed nothing.
mutant copilot-unnamed-subagent -e 's@ && \[ -n "\$SESSION" \]; then$@; then@'
new_copilot_lane control_cop_unnamed ken-219 "$MUTANT_PATH"
send KEN-219 'Rebase onto main.'
run_payload "$(jq -nc --arg p "$COP_TRANSCRIPT" '{transcriptPath:$p, stop_hook_active:false}')"
assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 first=- stdout=" \
  "control: without the session gate a lead's stop naming no session is handed nothing"

# The registry-document rule removed: the account install is no harness the
# hook knows, so it passes the Copilot call silently and leaves the directive
# unread.
mutant copilot-no-marker -e 's@^if \[ -z "\$HARNESS" \] && \[ -f "\${BASH_SOURCE\[0\]%.sh}.json" \]; then HARNESS=copilot; fi$@:@'
new_copilot_lane control_cop_marker ken-220
send KEN-220 'Read from the account install.'
install_hook "$MUTANT_PATH" "$COP_ACCOUNT/hooks/lane-mail-check.sh"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$TMP_ROOT/stdout") unread=$(lane_unread KEN-220 'Read from the account install.')" \
  "RC=0 first=- stdout= unread=1" \
  "control: without the registry-document rule the account install passes a Copilot turn end with the directive unread"

# The block answer built by jq again: with jq off PATH the answer is no JSON
# at all, and Copilot logs and skips the refusal.
mutant copilot-jq-answer -e 's@"\$(json_string "\$text")" ;;$@"$(jq -n --arg t "$text" '"'"'$t'"'"')" ;;@'
new_copilot_lane control_cop_jq ken-221 "$MUTANT_PATH"
send KEN-221 'Rebase first.'
copilot_stop "$COP_TRANSCRIPT" false "PATH=$NOJQ_BIN"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: missing-tools=jq decision=unparseable" \
  "control: with the answer built by jq, a turn end without jq answers no JSON"

# The block answer removed: the mail is acknowledged and the turn ends in
# silence, which is the loss the answer exists to prevent.
mutant copilot-no-block -e "s@^      stop) printf '{\"decision\":\"block\".*@      stop) : ;;@"
new_copilot_lane control_cop_block ken-213 "$MUTANT_PATH"
send KEN-213 'Rebase onto main.'
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$TMP_ROOT/stdout")" "RC=0 first=lane-mail-check: unread=1 stdout=" \
  "control: without the block answer a Copilot turn end passes with the directive acknowledged unseen"

# The deny answer removed: the call is still refused by its exit, and the
# words that name the acknowledging command never reach the model.
mutant copilot-no-deny -e "s@^      halt) printf '{\"permissionDecision\":\"deny\".*@      halt) : ;;@"
new_copilot_lane control_cop_deny ken-214 "$MUTANT_PATH"
send KEN-214 'Stop.' --halt
copilot_tool halt
assert_eq "RC=$RC stdout=$(cat "$TMP_ROOT/stdout")" "RC=2 stdout=" \
  "control: without the deny answer the refusal carries no words the model reads"

# The deliver context in Claude Code's shape on Copilot: the key Copilot
# reads is absent, so the model is handed nothing while the lines are
# acknowledged.
mutant copilot-nested-context -e "s@^      CONTEXT_SHAPE='{additionalContext: \\\$text}'\$@      CONTEXT_SHAPE='{hookSpecificOutput: {hookEventName: \"PostToolUse\", additionalContext: \$text}}'@"
new_copilot_lane control_cop_deliver ken-215 "$MUTANT_PATH"
send KEN-215 'Rebase first.'
copilot_tool deliver
assert_eq "RC=$RC context=$(stdout_field '.additionalContext') nested=$(stdout_field '.hookSpecificOutput.additionalContext' | head -n 1)" \
  "RC=0 context=null nested=lane-mail-check: unread=1" \
  "control: in the nested shape a finished Copilot tool call carries nothing under the key Copilot reads"
# The Copilot tool-call caller read as the lead's: a subagent's finished call
# then consumes the lead's directive.
mutant copilot-tool-lead -e 's@^    copilot:deliver | copilot:halt) CALLER=unknown ;;$@    copilot:deliver | copilot:halt) ;;@'
new_copilot_lane control_cop_unknown ken-223 "$MUTANT_PATH"
send KEN-223 'Rebase first.'
copilot_tool deliver
assert_eq "RC=$RC unread=$(lane_unread KEN-223 'Rebase first.')" "RC=0 unread=0" \
  "control: with a Copilot tool call read as the lead's, the deliver arm acknowledges the directive"

# The deliver acknowledgement offered to an unknown caller: a Copilot finished
# call consumes the directive whoever made it.
mutant copilot-deliver-acks -e 's@^    \[ "\$CALLER" != lead \] || { ACK_LINES@    [ "$CALLER" = subagent ] || { ACK_LINES@'
new_copilot_lane control_cop_deliver_ack ken-224 "$MUTANT_PATH"
send KEN-224 'Rebase first.'
copilot_tool deliver
assert_eq "RC=$RC unread=$(lane_unread KEN-224 'Rebase first.')" "RC=0 unread=0" \
  "control: with the acknowledgement offered to an unknown caller, a Copilot finished call consumes the directive"

# The halt's reading command shown to an unknown caller: a Copilot deny then
# hands it to a subagent, which clears the lead's halt with it.
mutant copilot-halt-shown -e 's@^          unknown)$@          unknown-shown)@' -e 's@^          lead)$@          lead | unknown)@'
new_copilot_lane control_cop_halt_shown ken-225 "$MUTANT_PATH"
send KEN-225 'Stop.' --halt
printf -v READ_HALT_225 '%q inbox --item %q --root %q' "$LANE/.agents/skills/orch/scripts/lane-mail" KEN-225 "$LANE"
copilot_tool halt
assert_eq "RC=$RC command=$(stdout_field .permissionDecisionReason | grep -cxF -- "$READ_HALT_225")" "RC=2 command=1" \
  "control: with the command shown to an unknown caller, a Copilot deny carries it"

# The pass withheld from an unknown caller: the lead's Copilot call running
# the command its turn end named is refused, and the halt stands for good.
mutant copilot-halt-no-pass -e 's@^      lead | unknown) ! call_runs "\$ACK_COMMAND" || exit 0 ;;$@      lead) ! call_runs "$ACK_COMMAND" || exit 0 ;;@'
new_copilot_lane control_cop_halt_pass ken-229 "$MUTANT_PATH"
send KEN-229 'Stop.' --halt
HALT_229=$(jq -r 'select(.halt == true) | .id' "$LANE/tmp/lane-mail/KEN-229/to-lane.jsonl")
printf -v READ_HALT_229 '%q inbox --item %q --root %q' "$LANE/.agents/skills/orch/scripts/lane-mail" KEN-229 "$LANE"
copilot_tool halt "$READ_HALT_229" object
expect 2 "lane-mail-check: halt=$HALT_229" \
  "control: without the pass for an unknown caller, the Copilot call running the reading command is refused"

# The reading command dropped from the lead's notice: a Copilot lead's turn
# end hands it the halt and no way to read it.
mutant notice-no-command -e 's@^        if \[ "\$CALLER" = lead \] && \[ -n "\$ACK_COMMAND" \]; then$@        if false; then@'
new_copilot_lane control_cop_notice ken-230 "$MUTANT_PATH"
send KEN-230 'Stop.' --halt
printf -v READ_HALT_230 '%q inbox --item %q --root %q' "$LANE/.agents/skills/orch/scripts/lane-mail" KEN-230 "$LANE"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC decision=$(stdout_field .decision) command=$(stdout_field .reason | grep -cxF -- "$READ_HALT_230")" \
  "RC=0 decision=block command=0" \
  "control: without the command in the lead's notice, a Copilot turn end hands the halt and no way to read it"

# The Copilot deliver answer removed: a refusal after a tool call writes
# nothing the model reads.
mutant copilot-no-deliver-answer -e "s@^      deliver) printf '{\"additionalContext\".*@      deliver) : ;;@"
new_copilot_lane control_cop_deliver_answer ken-226 "$MUTANT_PATH"
send KEN-226 'Unreachable.'
rm -f -- "${LANE:?}/.claude/skills/orch" "${LANE:?}/.agents/skills/orch/scripts"
copilot_tool deliver
assert_eq "RC=$RC context=$(stdout_field '.additionalContext')" "RC=0 context=" \
  "control: without the deliver answer a Copilot refusal after a tool call reaches no model"

# The backslash rule removed from json_string: a directive holding a
# backslash makes the block answer unparseable.
mutant copilot-no-backslash -e '/^  s=\${s\/\/"\$bs"\/"\$bs\$bs"}$/d'
new_copilot_lane control_cop_backslash ken-227 "$MUTANT_PATH"
send KEN-227 "$COP_ESCAPED"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC reason=$(stdout_field .reason)" "RC=0 reason=unparseable" \
  "control: without the backslash rule a directive holding a backslash leaves the block answer unparseable"

# The retry flag's read removed: a turn Copilot continued after a block is
# held again.
mutant copilot-no-active -e 's@(\.stop_hook_active == true | tostring)@(false | tostring)@'
new_copilot_lane control_cop_active ken-228 "$MUTANT_PATH"
send KEN-228 'Continued.'
copilot_stop "$COP_TRANSCRIPT" true
assert_eq "RC=$RC decision=$(stdout_field .decision)" "RC=0 decision=block" \
  "control: without the stop_hook_active read a continued Copilot turn is held again"

# The toolArgs read dropped: the one command that restores the mailbox is
# refused.
mutant copilot-no-toolargs -e 's@^      // (copilot | strings) // ""@      // ""@'
new_copilot_lane control_cop_toolargs ken-216 "$MUTANT_PATH"
printf -v MKDIR_216 'mkdir -p -- %q' "$LANE/tmp/lane-mail"
copilot_tool halt "$MKDIR_216" object
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "control: without the toolArgs read the command that restores the mailbox is refused"

# The Copilot guard on the transcript read removed: the adapters refuse the
# harness, and every Copilot turn end is held on a transcript nothing reads.
mutant copilot-reads-transcript -e 's@^  if \[ -z "\$HARNESS" \] || \[ "\$HARNESS" = copilot \]; then$@  if [ -z "$HARNESS" ]; then@'
new_copilot_lane control_cop_transcript ken-217 "$MUTANT_PATH"
mkdir -p "$LANE/tmp/lane-mail/KEN-217"
(cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init KEN-217 >/dev/null)
usage_line claude 900000 > "$COP_TRANSCRIPT"
copilot_stop "$COP_TRANSCRIPT"
assert_eq "RC=$RC first=$(first_line) decision=$(stdout_field .decision)" \
  "RC=0 first=lane-mail-check: transcript=unread decision=block" \
  "control: with a Copilot transcript read, the turn end is held on a reading no adapter makes"
: > "$COP_TRANSCRIPT"

# The halt arm judging the marks: an account read then runs before a tool
# call, outside the deadline the halt decision has to land in.
mutant halt-judges-marks -e 's@^  \[ "\$ARM" = stop \] && \[ "\$CALLER" = lead \] || return 0$@  [ "$CALLER" != subagent ] || return 0@'
new_copilot_lane control_cop_local ken-218 "$MUTANT_PATH"
mkdir -p "$LANE/tmp/lane-mail/KEN-218"
CONTROL_ENV_CALLS="$TMP_ROOT/copilot-control-env-calls"
plant_orch_env_stub "$CONTROL_ENV_CALLS"
copilot_tool halt
assert_eq "marks=$([ -e "$CONTROL_ENV_CALLS" ] && echo judged || echo unjudged)" "marks=judged" \
  "control: with the marks judged before a tool call, their reads run inside the halt deadline"

# The context arms' write check dropped: a context that cannot be written is
# acknowledged all the same, and the directive is lost.
mutant context-ack-unwritten -e 's@ || refuse notice unwritten "\$(cat -- "\$WORK_DIR/notice.err")"$@ || :@'
new_copilot_lane control_context_ack ken-240 "$MUTANT_PATH"
send KEN-240 'Then push.'
copilot_context_unwritable prompt
assert_eq "RC=$RC unread=$(lane_unread KEN-240 'Then push.')" "RC=0 unread=0" \
  "control: without the write check an unwritten context acknowledges the directive"

# The start and prompt arms' pass in refuse removed: the judge's refusal is a
# refused session start.
mutant context-refuses -e '/^    start | prompt) exit 0 ;;$/d'
new_copilot_lane control_context_refuse ken-241 "$MUTANT_PATH"
copilot_context start
expect 2 "lane-mail-check: mailbox-missing=$LANE/tmp/lane-mail" \
  "control: without the pass in refuse a session start is refused"

# Each wrapper: its arm swapped for deliver, which answers a refusal on
# stdout where its own arm only reports it on stderr, and its missing-judge
# exit removed, its message still written.
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
  MUTANT_SOURCE="$TEST_DIR/../lane-mail-$arm.sh" mutant "$arm-no-judge-exit" -e 's@^  exit 0$@  :@'
  install_hook "$MUTANT_PATH" "$LANE/.github/hooks/lane-mail-$arm.sh"
  rm -f -- "${LANE:?}/.github/hooks/lane-mail-check.sh"
  copilot_context "$arm"
  assert_eq "$([ "$RC" -eq 0 ] && echo passed || echo failed)" "failed" \
    "control: without its exit the $arm hook with no judge beside it does not pass"
done

# The Copilot pass keyed on the install path alone: the Claude copy then
# judges a Copilot call as a Claude lead's, answers in a shape Copilot does
# not read and acknowledges the directive.
mutant copilot-call-install-path -e 's@^if \[ "\$CALL_HARNESS" = copilot \] && \[ "\$HARNESS" != copilot \]; then exit 0; fi$@:@'
new_copilot_lane control_cop_cross ken-252
install_claude_copy "$MUTANT_PATH"
send KEN-252 'Rebase first.'
claude_copy deliver pascal
assert_eq "RC=$RC unread=$(lane_unread KEN-252 'Rebase first.')" "RC=0 unread=0" \
  "control: with the harness read from the install alone, a Copilot call through the Claude copy acknowledges the directive"

# The `timestamp` read dropped: the referenced PascalCase format names no
# `sessionId`, so the Claude copy reads it as its own.
mutant copilot-call-no-timestamp -e 's@has("timestamp") or @@'
new_copilot_lane control_cop_timestamp ken-253
install_claude_copy "$MUTANT_PATH"
send KEN-253 'Rebase first.'
claude_copy deliver pascal
assert_eq "RC=$RC unread=$(lane_unread KEN-253 'Rebase first.')" "RC=0 unread=0" \
  "control: without the timestamp read, a PascalCase Copilot call through the Claude copy acknowledges the directive"

# The `sessionId` read dropped: a camelCase payload with no `timestamp` is
# read as the Claude copy's own.
mutant copilot-call-no-session -e 's@ or has("sessionId")@@'
new_copilot_lane control_cop_camel ken-254
install_claude_copy "$MUTANT_PATH"
send KEN-254 'Rebase first.'
claude_copy deliver camel
assert_eq "RC=$RC unread=$(lane_unread KEN-254 'Rebase first.')" "RC=0 unread=0" \
  "control: without the sessionId read, a camelCase Copilot call through the Claude copy acknowledges the directive"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
