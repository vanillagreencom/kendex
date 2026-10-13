#!/usr/bin/env bash
# Session-row and context fixtures for the overseer watch contracts.
# Row shapes as Claude Code 2.1.283 emits them, read from that binary's hook
# input builders: every event carries session_id, transcript_path and cwd;
# SessionStart adds source and model, SessionEnd reason (clear, resume,
# logout, prompt_input_exit, other), StopFailure error (rate_limit among
# them), error_details and last_assistant_message, which the writer keeps as
# `message`. The writer adds at, event, harness and account.
ROWS_FILE() { printf '%s/tmp/lane-mail/overseer/session-7000-9.jsonl' "$CASE_REPO_ROOT"; }
row() { # EVENT HARNESS [KEY=VALUE]...
  local event="$1" harness="$2" args=()
  shift 2
  for kv in "$@"; do args+=(--arg "${kv%%=*}" "${kv#*=}"); done
  jq -cn --arg event "$event" --arg harness "$harness" ${args[@]+"${args[@]}"} \
    '{at: 1788364000, event: $event, harness: $harness, session_id: "5f0c", transcript_path: "/home/me/.claude/projects/x/5f0c.jsonl", cwd: "/home/me/kendex"} + ($ARGS.named | del(.event, .harness))'
}
START="$(row SessionStart claude source=startup model=claude-fable-5-1 account=/home/me/.claude)"
END_EXIT="$(row SessionEnd claude reason=prompt_input_exit)"
END_CLEAR="$(row SessionEnd claude reason=clear)"
WALL_MESSAGE="You've hit your limit · resets 9:50am (America/Los_Angeles)"
FAILURE="$(row StopFailure claude error=rate_limit "message=$WALL_MESSAGE")"
OVERLOADED="$(row StopFailure claude error=overloaded message=overloaded)"
# The failure a session whose context filled its window meets on every turn:
# Claude Code's own `Prompt is too long` as the turn's last message.
TOO_LONG="$(row StopFailure claude error=invalid_request "message=Prompt is too long")"
# The same failure with the words in `error_details` and an empty message,
# the two fields hooks/stop-failure-row.sh keeps apart.
TOO_LONG_DETAILS="$(row StopFailure claude error=invalid_request message= "error_details=Prompt is too long")"
STOP="$(row Stop claude)"
CODEX_START="$(row SessionStart codex source=startup)"
# A Pi overseer's rows, as the pi-hooks carrier's payloads give them: Pi's
# `quit` said as Claude Code's `prompt_input_exit` (pi-hooks vocab.ts).
PI_START="$(row SessionStart pi source=startup)"
PI_END="$(row SessionEnd pi reason=prompt_input_exit)"
# A Pi turn end: no end and no failure, which is all a Pi session whose
# carrier dispatches no StopFailure writes at a wall.
PI_STOP="$(row Stop pi)"

# rows_case NAME PANE_STATE ROW... — overseer_case's sandbox with the fleet
# state naming the rows file for this pane and ROW... written to it, one per
# line; no ROW leaves the file absent. The pane reads PANE_STATE, `blank` being
# a live harness process over a screen showing nothing at all.
rows_case() { # NAME PANE_STATE ROW...
  local name="$1" pane_state="$2" row
  shift 2
  if [[ "$pane_state" == blank ]]; then
    overseer_case "$name" idle
    : > "$STUB_DIR/pane-$PANE.txt"
  else
    overseer_case "$name" "$pane_state"
  fi
  touch "$STUB_DIR/repeat-child"
  state_with "$LINE"
  jq --arg rows "$(ROWS_FILE)" '.overseer.session_rows = $rows' "$STUB_DIR/oversee-state.json" \
    > "$STUB_DIR/state.tmp" && mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
  mkdir -p "$CASE_REPO_ROOT/tmp/lane-mail/overseer"
  for row in "$@"; do printf '%s\n' "$row" >> "$(ROWS_FILE)"; done
}
# A rows wall stands unless the account judgement measures room: the stub's
# default below-mark line is room, so a case that means the wall to stand
# gives it a mark reached above zero, which is no room and no zero wall.
FIVE_MARK="oversee-succeed: mark-reached kind=headroom value=5 mark=10 succession=on account=1claude resets=2026-09-28T03:00:00Z"
ZERO_MARK="oversee-succeed: mark-reached kind=headroom value=0 mark=10 succession=on account=1claude resets=2026-09-28T03:00:00Z"
no_room() { printf '%s\n' "$FIVE_MARK" > "$STUB_DIR/succeed.check"; }


CTX_FILE() { printf '%s/tmp/lane-mail/overseer/context.json' "$CASE_REPO_ROOT"; }
# The rows above are stamped ROW_AT, so a record is placed before or after
# that turn by its offset from it.
ROW_AT=1788364000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
# context_case NAME PANE_STATE RECORD_OFFSET NOW_OFFSET GAP ROW... — a rows
# sandbox whose context record was written RECORD_OFFSET seconds after ROW_AT,
# naming the pane key CTX_KEY, with GAP as its gap or `-` for a reading, and a
# clock NOW_OFFSET seconds after ROW_AT; then one long pass. CONTEXT_EVENT is
# the context event it printed, or none. CTX_FLEET_HARNESS, where set, is the
# harness the fleet record names for this pane.
CTX_KEY="7000 $PANE"
CTX_FLEET_HARNESS=""
# A start in the same pane naming a new session, as a session opened there by
# hand, or a /clear, writes.
RESTART="$(row SessionStart claude source=startup model=claude-fable-5-1 session_id=9a1b)"
# ctx_record AT GAP — the context record the hook writes at AT, naming the
# pane key CTX_KEY: a reading below the mark where GAP is `-`, else GAP.
ctx_record() { # AT GAP
  if [[ "$2" == - ]]; then
    jq -cn --arg at "$1" --arg key "$CTX_KEY" '{harness: "claude", model: "claude-fable-5-1", tokens: 300000, window: 1000000,
      used_pct: 30, session_id: "5f0c", pane_key: $key, gap: null, at: $at}' > "$(CTX_FILE)"
  else
    jq -cn --arg at "$1" --arg gap "$2" --arg key "$CTX_KEY" '{harness: "claude", model: null, tokens: null, window: null,
      used_pct: null, session_id: "5f0c", pane_key: $key, gap: $gap, at: $at}' > "$(CTX_FILE)"
  fi
}
context_case() { # NAME PANE_STATE RECORD_OFFSET NOW_OFFSET GAP ROW...
  local name="$1" pane_state="$2" at now="$((ROW_AT + $4))" gap="$5"
  at="$(iso "$((ROW_AT + $3))")"
  shift 5
  rows_case "$name" "$pane_state" "$@"
  if [[ -n "$CTX_FLEET_HARNESS" ]]; then
    jq --arg h "$CTX_FLEET_HARNESS" '.overseer.harness = $h' "$STUB_DIR/oversee-state.json" > "$STUB_DIR/state.tmp" \
      && mv -- "$STUB_DIR/state.tmp" "$STUB_DIR/oversee-state.json"
  fi
  printf '%s\n' "$now" > "$STUB_DIR/now.epoch"
  ctx_record "$at" "$gap"
  run TMUX_PANE="$PANE" -- --max-loops 1
  CONTEXT_EVENT="$(grep '^EVENT overseer-context-' <<<"$OUT" || echo none)"
}
