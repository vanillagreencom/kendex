#!/usr/bin/env bash
# The thin four-harness native path: start a real session in a disposable
# home and working directory on a private tmux server, confirm its start
# identity, hand it work after its first turn completed, hand it a second
# later instruction, then stop it exactly and confirm the stop.
#
# This spends one short model session per harness on the operator's own
# account. It runs only when a person invokes it; nothing in CI calls it.
#
# Usage: thin-path.sh [--harness claude|codex|copilot|pi]... --out DIR
#                     [--deadline-secs N]
#   Writes DIR/<harness>.json, the evidence record, and DIR/<harness>/ with
#   the launch record, each inspection, the first-run record and the final
#   pane capture. One harness runs at a time on its own private server at
#   DIR/tmux.sock; the server is ended before the next harness starts.
set -euo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
runtime="$here/../../runtime"
bin="$runtime/target/debug/agent-runtime"
harnesses=()
out=""
deadline_secs=600
while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness) harnesses+=("$2"); shift 2 ;;
    --out) out="$2"; shift 2 ;;
    --deadline-secs) deadline_secs="$2"; shift 2 ;;
    *) echo "thin-path: usage=--harness H --out DIR [--deadline-secs N]" >&2; exit 2 ;;
  esac
done
[ -n "$out" ] || { echo "thin-path: usage=--out DIR required" >&2; exit 2; }
[ "${#harnesses[@]}" -gt 0 ] || harnesses=(claude codex copilot pi)
[ -x "$bin" ] || (cd "$runtime" && cargo build --quiet)
mkdir -p -- "$out"
out="$(cd -- "$out" && pwd -P)"
socket="$out/tmux.sock"
now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch() { date +%s; }

# prepare_home HARNESS HOME CWD: a disposable account home carrying only the
# operator's login, the trust record for CWD and the documented settings
# keys that record each harness's first-run dialogs as answered, never
# sessions or hooks. Writes HOME/../first-run.json naming the mechanism.
prepare_home() {
  local h="$1" home="$2" cwd="$3" src version
  ( umask 077 && mkdir -p -- "$home" )
  case "$h" in
    claude)
      src="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
      cp -p -- "$src/.credentials.json" "$home/.credentials.json"
      jq -n --arg dir "$cwd" '{hasCompletedOnboarding: true, projects: {($dir): {hasTrustDialogAccepted: true, allowedTools: []}}}' > "$home/.claude.json"
      # The bypass-permissions acceptance dialog is recorded in user settings
      # as `skipDangerousModePermissionPrompt` (the 2.1.310 settings schema:
      # "Whether the user has accepted the bypass permissions mode dialog").
      jq -n '{skipDangerousModePermissionPrompt: true}' > "$home/settings.json"
      jq -n '{mechanism: "pre-recorded", files: {".claude.json": ["hasCompletedOnboarding", "projects[cwd].hasTrustDialogAccepted"], "settings.json": ["skipDangerousModePermissionPrompt"]}}' > "$home/../first-run.json"
      ;;
    codex)
      src="${CODEX_HOME:-$HOME/.codex}"
      cp -p -- "$src/auth.json" "$home/auth.json"
      # The account's model and provider tables, plus trust for CWD and no
      # hooks table, so the probe session loads none of the account's hooks.
      # The copied [tui] table carries `screen_reader_detection_done` and
      # the model-availability notice counts, both first-run notices.
      sed -E '/^\s*hooks\s*=/d' -- "$src/config.toml" > "$home/config.toml"
      printf '\n[projects."%s"]\ntrust_level = "trusted"\n' "$cwd" >> "$home/config.toml"
      jq -n '{mechanism: "pre-recorded", files: {"config.toml": ["projects[cwd].trust_level", "tui.screen_reader_detection_done", "tui.model_availability_nux"]}, launch_words: ["--dangerously-bypass-hook-trust", "check_for_update_on_startup=false"]}' > "$home/../first-run.json"
      ;;
    copilot)
      src="${COPILOT_HOME:-$HOME/.copilot}"
      cp -p -- "$src/config.json" "$home/config.json"
      # The stored login lives in config.json (`loggedInUsers`); folder
      # trust comes from COPILOT_ALLOW_ALL=true, which the launcher sets
      # under bypass. The startup tips and banner are settings keys.
      jq '{showTipsOnStartup: false, banner: "never", autoUpdate: false, telemetry} | with_entries(select(.value != null))' "$src/settings.json" > "$home/settings.json"
      jq -n '{mechanism: "pre-recorded", files: {"config.json": ["loggedInUsers", "appTipShown"], "settings.json": ["showTipsOnStartup", "banner", "autoUpdate"]}, launch_env: ["COPILOT_ALLOW_ALL=true"]}' > "$home/../first-run.json"
      ;;
    pi)
      src="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}"
      for f in auth.json models.json; do [ -f "$src/$f" ] && cp -p -- "$src/$f" "$home/$f"; done
      version="$("$bin" probe --harness pi | jq -r '.result[0].version // empty')"
      # `lastChangelogVersion` at the installed version keeps the release
      # notes closed; `quietStartup` drops the banner.
      jq --arg v "$version" '{defaultProvider, defaultModel, defaultThinkingLevel, aiPrivacyWarningAccepted, quietStartup: true, lastChangelogVersion: $v, compaction: {enabled: false}} | with_entries(select(.value != null))' "$src/settings.json" > "$home/settings.json"
      jq -n --arg dir "$cwd" '{($dir): true}' > "$home/trust.json"
      jq -n '{mechanism: "pre-recorded", files: {"trust.json": ["[cwd]"], "settings.json": ["aiPrivacyWarningAccepted", "quietStartup", "lastChangelogVersion"]}}' > "$home/../first-run.json"
      ;;
  esac
}

inspect_to() { # RECORD FILE
  "$bin" inspect --record "$1" > "$2" 2>"$2.err" || :
}

# The judge's word and cause from an inspection file. An empty file (the
# binary never answered) reads as unread; a refusal reply has no state and
# reads as unread too.
state_of() { local s; s="$(jq -r '.result.state.state // "unread"' "$1")"; echo "${s:-unread}"; }
cause_of() { jq -r '.result.state.cause // empty' "$1"; }

# The seconds left in the current harness's wall-clock budget, at least 0.
run_deadline=0
remaining() {
  local left=$(( run_deadline - $(epoch) ))
  [ "$left" -gt 0 ] && echo "$left" || echo 0
}
min() { [ "$1" -lt "$2" ] && echo "$1" || echo "$2"; }

# await_file RECORD FILE SECONDS NAME: poll every 2 s for FILE, inspecting
# the session each round into NAME.json. Returns 0 when the file exists,
# 1 at the deadline, 2 when the session reached a state no file will follow
# (asking, walled, exited, pane gone), with that inspection kept.
await_file() {
  local record="$1" file="$2" secs="$3" name="$4" deadline state cause
  deadline=$(( $(epoch) + secs ))
  while :; do
    [ -s "$file" ] && return 0
    inspect_to "$record" "$name.json"
    state="$(state_of "$name.json")"
    cause="$(cause_of "$name.json")"
    case "$state" in
      asking|walled|rate-limit-switch|exited) return 2 ;;
      unjudged) [ "$cause" != pane-gone ] || return 2 ;;
    esac
    [ "$(epoch)" -lt "$deadline" ] || return 1
    sleep 2
  done
}

# await_idle RECORD SECONDS NAME: poll for the judge's idle. Returns as
# await_file does.
await_idle() {
  local record="$1" secs="$2" name="$3" deadline state cause
  deadline=$(( $(epoch) + secs ))
  while :; do
    inspect_to "$record" "$name.json"
    state="$(state_of "$name.json")"
    cause="$(cause_of "$name.json")"
    case "$state" in
      idle) return 0 ;;
      asking|walled|rate-limit-switch|exited) return 2 ;;
      unjudged) [ "$cause" != pane-gone ] || return 2 ;;
    esac
    [ "$(epoch)" -lt "$deadline" ] || return 1
    sleep 2
  done
}

# The value of the harness's home variable in the live process, read from
# /proc, so the evidence shows the disposable home was the one honoured.
home_var_of() { # HARNESS PID
  local var
  case "$1" in
    claude) var=CLAUDE_CONFIG_DIR ;; codex) var=CODEX_HOME ;;
    copilot) var=COPILOT_HOME ;; pi) var=PI_CODING_AGENT_DIR ;;
  esac
  [ -r "/proc/$2/environ" ] || return 0
  tr '\0' '\n' < "/proc/$2/environ" | sed -n "s/^$var=//p"
}

server_pid=""
server_start=""
start_server() { # CWD
  tmux -S "$socket" new-session -d -s probe -c "$1" -x 220 -y 60
  server_pid="$(tmux -S "$socket" display-message -p '#{pid}')"
  server_start="$("$bin" process identity "$server_pid" | jq -r '.result.start')"
}

# End the private server and report whether its recorded identity is gone.
end_server() { # -> prints true|false|unread
  [ -n "$server_pid" ] || { echo unread; return; }
  tmux -S "$socket" kill-server 2>/dev/null || :
  local live
  live="$("$bin" process live "$server_pid" "$server_start" | jq -r '.result')"
  case "$live" in
    gone) echo true ;;
    live|zombie) echo false ;;
    *) echo unread ;;
  esac
}

run_one() {
  local h="$1" dir cwd home intent record t0 t_start t_idle t_two t_three t_stop
  local first=false idle=false second=false third=false blocked="" rc
  dir="$out/$h"
  [ -d "$dir" ] && rm -rf -- "${dir:?}/work" "${dir:?}/home"
  mkdir -p -- "$dir"
  cwd="$dir/work"; home="$dir/home"
  mkdir -p -- "$cwd"
  git -C "$cwd" init --quiet
  git -C "$cwd" config gc.auto 0
  git -C "$cwd" config maintenance.auto false
  prepare_home "$h" "$home" "$cwd"
  cat > "$cwd/brief.md" <<'BRIEF'
Create a file named probe-1.txt in the current directory containing exactly the word one and a newline. Use a shell command. Do not create anything else. When it exists, say done and wait for the next instruction.
BRIEF
  intent="$dir/intent.json"
  record="$dir/launch-record.json"
  rm -f -- "${dir:?}/launch-record.json" "${dir:?}/launch-record.json.lock"
  jq -n --arg h "$h" --arg home "$home" --arg cwd "$cwd" --arg brief "$cwd/brief.md" '{
    harness: $h, home: $home, cwd: $cwd,
    permission: "bypass", question_tool: "off", compaction: "native",
    brief: {kind: "file", path: $brief}
  }' > "$intent"
  start_server "$cwd"
  t0="$(epoch)"
  run_deadline=$(( t0 + deadline_secs ))
  if ! "$bin" launch --intent "$intent" --record "$record" --socket "$socket" --session probe --window-name "probe-$h" > "$dir/launch.json" 2> "$dir/launch.err"; then
    local server_ended
    server_ended="$(end_server)"
    jq -n --arg h "$h" --arg at "$(now_utc)" --rawfile err "$dir/launch.err" --arg ended "$server_ended" \
      '{harness: $h, at: $at, outcome: "launch-refused", stderr: $err, server_ended: ($ended == "true")}' > "$out/$h.json"
    return
  fi
  # Start identity: the harness process below the pane, then its first turn.
  local pid=""
  local tries=0
  while [ "$tries" -lt 30 ]; do
    inspect_to "$record" "$dir/inspect-start.json"
    pid="$(jq -r '.result.harness_process.pid // empty' "$dir/inspect-start.json")"
    [ -z "$pid" ] || break
    tries=$(( tries + 1 ))
    sleep 2
  done
  t_start="$(epoch)"
  local home_var=""
  [ -z "$pid" ] || home_var="$(home_var_of "$h" "$pid")"
  if await_file "$record" "$cwd/probe-1.txt" "$(min 240 "$(remaining)")" "$dir/inspect-first"; then
    first=true
  else
    rc=$?
    [ "$rc" -ne 2 ] || blocked="first-turn:$(state_of "$dir/inspect-first.json")"
  fi
  if [ -z "$blocked" ]; then
    if await_idle "$record" "$(min 90 "$(remaining)")" "$dir/inspect-idle"; then
      idle=true
    else
      rc=$?
      [ "$rc" -ne 2 ] || blocked="idle-after-first:$(state_of "$dir/inspect-idle.json")"
    fi
  fi
  t_idle="$(epoch)"
  # Work after a completed turn: the same primary, through the pane.
  printf 'Now create probe-2.txt containing exactly the word two and a newline, with a shell command, then say done and wait.\n' > "$dir/deliver-2.md"
  printf 'Now create probe-3.txt containing exactly the word three and a newline, with a shell command, then say done and wait.\n' > "$dir/deliver-3.md"
  : > "$dir/deliver-2.json"; : > "$dir/deliver-2.err"; : > "$dir/deliver-3.json"; : > "$dir/deliver-3.err"
  if [ -z "$blocked" ] && [ "$idle" = true ]; then
    if "$bin" deliver --record "$record" --file "$dir/deliver-2.md" > "$dir/deliver-2.json" 2> "$dir/deliver-2.err"; then
      if await_file "$record" "$cwd/probe-2.txt" "$(min 180 "$(remaining)")" "$dir/inspect-second"; then
        second=true
      else
        rc=$?
        [ "$rc" -ne 2 ] || blocked="second-turn:$(state_of "$dir/inspect-second.json")"
      fi
    else
      blocked="deliver-2-refused"
    fi
  fi
  t_two="$(epoch)"
  if [ -z "$blocked" ] && [ "$second" = true ]; then
    # A second later event after continuation.
    if await_idle "$record" "$(min 90 "$(remaining)")" "$dir/inspect-idle-2" \
      && "$bin" deliver --record "$record" --file "$dir/deliver-3.md" > "$dir/deliver-3.json" 2> "$dir/deliver-3.err"; then
      if await_file "$record" "$cwd/probe-3.txt" "$(min 180 "$(remaining)")" "$dir/inspect-third"; then
        third=true
      else
        rc=$?
        [ "$rc" -ne 2 ] || blocked="third-turn:$(state_of "$dir/inspect-third.json")"
      fi
    else
      blocked="deliver-3-refused"
    fi
  fi
  t_three="$(epoch)"
  inspect_to "$record" "$dir/inspect-before-stop.json"
  local pane_id
  pane_id="$(jq -r '.pane.id' "$record")"
  tmux -S "$socket" capture-pane -p -J -t "$pane_id" > "$dir/final-screen.txt" 2>/dev/null || :
  "$bin" stop --record "$record" > "$dir/stop.json" 2> "$dir/stop.err" || :
  t_stop="$(epoch)"
  local start live
  pid="$(jq -r '.harness_process.pid // empty' "$record")"
  start="$(jq -r '.harness_process.start // empty' "$record")"
  if [ -n "$pid" ] && [ -n "$start" ]; then
    live="$("$bin" process live "$pid" "$start" | jq -r '.result')"
  else live="unread"; fi
  local server_ended
  server_ended="$(end_server)"
  jq -n --arg h "$h" --arg at "$(now_utc)" \
    --arg version "$("$bin" probe --harness "$h" | jq -r '.result[0].version // "unread"')" \
    --arg os "$(uname -sr)" \
    --slurpfile record "$record" \
    --slurpfile first_run "$dir/first-run.json" \
    --arg home_var "$home_var" --arg home "$home" \
    --arg first "$first" --arg idle "$idle" --arg second "$second" --arg third "$third" \
    --arg blocked "$blocked" --argjson deadline "$deadline_secs" \
    --argjson t_start "$((t_start - t0))" --argjson t_idle "$((t_idle - t0))" --argjson t_two "$((t_two - t0))" --argjson t_three "$((t_three - t0))" --argjson t_stop "$((t_stop - t0))" \
    --slurpfile stop "$dir/stop.json" --arg live "$live" \
    --arg final_screen_bytes "$(wc -c < "$dir/final-screen.txt")" \
    --arg server_ended "$server_ended" --argjson server_pid "${server_pid:-0}" \
    --rawfile d2err "$dir/deliver-2.err" --rawfile d3err "$dir/deliver-3.err" '{
      harness: $h, at: $at, harness_version: $version, os: $os, route: "tmux-pane-paste",
      deadline_secs: $deadline,
      first_run: $first_run[0],
      launched: true,
      start_identity: ($record[0].harness_process // null),
      home_var_in_process: $home_var,
      home_var_matches_disposable_home: ($home_var == $home),
      native_session: ($record[0].native_session // null),
      first_turn_done: ($first == "true"),
      idle_observed_after_first_turn: ($idle == "true"),
      later_work_after_completed_turn: ($second == "true"),
      second_later_event_after_continuation: ($third == "true"),
      blocked: (if $blocked == "" then null else $blocked end),
      deliver_2_refusal: $d2err,
      deliver_3_refusal: $d3err,
      final_screen_captured: (($final_screen_bytes | tonumber) > 0),
      stop: ($stop[0].result // null),
      harness_process_after_stop: $live,
      private_server: {pid: $server_pid, ended: ($server_ended == "true")},
      seconds: {start_identity: $t_start, first_idle: $t_idle, second_file: $t_two, third_file: $t_three, stopped: $t_stop}
    }' > "$out/$h.json"
}

# Never the person's own server: a stale private server from an earlier run
# on this socket is ended first.
tmux -S "$socket" kill-server 2>/dev/null || :
for h in "${harnesses[@]}"; do
  run_one "$h" || echo "thin-path: harness=$h failed=true" >&2
  echo "thin-path: harness=$h evidence=$out/$h.json"
done
