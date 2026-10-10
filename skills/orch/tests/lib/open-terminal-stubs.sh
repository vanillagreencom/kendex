# shellcheck shell=bash
#
# The stub commands an open-terminal suite puts ahead of PATH: worktree, gh,
# tmux, sleep and ghostty. Each but sleep logs what the launcher asked of it
# and answers as the real command would, so a row reads the windows a launch
# opened, the lines it typed and the worktrees it created without opening a
# real window; sleep logs nothing, and returns at once for a whole-second
# argument where OT_SLEEP_INSTANT is set. The suites that drive open-terminal
# through lanes, hosts and cloud sessions share them: the open-terminal-lane
# suites, open-terminal-brief-file.sh, open-terminal-cloud.sh and the others
# that call ot_stub_bin. ot_fleet_state seeds the fleet state a launch under
# --state-dir binds to.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run.

# ot_stub_bin DIR — writes the five stubs into DIR, which it creates.
ot_stub_bin() {
mkdir -p "$1"
# `worktree create` hands back a fresh directory beside its log, under the
# run the suite's trap removes, and logs the call, so a row can assert that
# no worktree was created when the lane refused.
cat > "$1/worktree" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OT_WT_LOG"
if [[ "${1:-}" == "create" ]]; then
  # $OT_WT_FIXED pins the path for a row whose account config has to name the
  # launch directory before the launch reads it.
  if [[ -n "${OT_WT_FIXED:-}" ]]; then d="$OT_WT_FIXED"; mkdir -p "$d"
  else d="$(mktemp -d "$(dirname "$OT_WT_LOG")/wt.XXXXXX")" || exit 1; fi
  git init -q "$d"
  git -C "$d" config gc.auto 0
  git -C "$d" config maintenance.auto false
  printf '%s\n' "$d" >> "${OT_WT_PATH:-/dev/null}"
  printf '%s\n' "$d"
  exit 0
fi
exit 0
STUBEOF
cat > "$1/gh" <<'STUBEOF'
#!/usr/bin/env bash
[[ "$*" != 'repo view --json nameWithOwner -q .nameWithOwner' || -z "${OT_CHECKOUT_REPO-o/r}" ]] || { printf '%s\n' "${OT_CHECKOUT_REPO-o/r}"; exit 0; }
exit 1
STUBEOF
# tmux logs every call; $OT_TMUX_FAIL names one subcommand that fails after
# logging, so a window can be created and claimed while its launch fails, and
# $OT_TMUX_FAIL_NTH aims a failure at one call of a subcommand several readers
# share. The server pid is this test process, so claims recorded against it are
# live; $OT_TMUX_PANES counts the windows created and list-panes reports each.
#
# The hosted rows get a pane that behaves as a terminal does, replayed from
# this log rather than timed by the row. An ssh line pasted while the pane is
# already running ssh is typed INTO that client and opens no connection, which
# is the whole of what the retry has to work around; only a paste made while
# the pane is at its own shell dials. An interrupt (send-keys C-c) is what
# returns the pane to its shell. So the replay carries two facts:
#   state        ssh while a dialling paste is the newest event, shell before
#                the first one and after every interrupt
#   connections  pastes that dialled, which is pastes made at the shell
# $OT_SSH_CONNECTS_ON names the connection whose host answers with a prompt;
# earlier ones show a connecting screen and no prompt, so a row puts the prompt
# on the first dial, on the retry's dial, or on neither. $OT_SSH_DIES_AFTER
# names how many pane_current_command reads a connection survives; past it the
# pane is back at its shell, which is a session that died under the wait.
# $OT_SSH_IGNORES_INTERRUPT is the other end of that: a client already past
# connect, whose raw-mode terminal forwards the interrupt to the remote instead
# of dying, so the pane stays in ssh and no retyped line can reach a shell.
# $OT_SSH_SCREEN names a file holding the connected screen, several lines and
# not one, which is what a login printing a banner above its prompt draws.
# $OT_COMPOSER_ON_ENTER=N is a harness whose first screen lacks the brief: the
# pane shows a prompt until the log holds N Enter keystrokes, a ready, empty
# composer at N, and past N the first line pasted after the Nth Enter, as the
# turn it submitted.
#
# A local launch line, `clear; ` and no ssh, starts the harness in the pane.
# $OT_HARNESS_LATE=N is a shell still starting: the pane runs it for the first
# N pane_current_command reads after the line, the harness from the next.
# $OT_HARNESS_EXITS=M is a harness that refuses its arguments: after M reads
# running it, the pane is back at its shell. $OT_SCREEN_FILE names a file
# holding the screen a cloud session draws once its composer is up: shown from
# the $OT_SCREEN_ON-th capture (default 1) after the one that drew the
# $OT_COMPOSER_ON_ENTER composer, whole under `-S -` and its last five lines, a
# pane five rows tall, without it. $OT_SCREEN_ON=0 shows it from the first
# capture, composer or none: a CLI that prints its session and draws no
# composer.
cat > "$1/tmux" <<'STUBEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$OT_TMUX_LOG"
if [[ -n "${OT_TMUX_FAIL:-}" && "${1:-}" == "$OT_TMUX_FAIL" ]]; then
  exit 1
fi
# $OT_TMUX_FAIL_NTH is SUB:N — the Nth call of subcommand SUB in the run fails,
# counted from the log above, this call included. $OT_TMUX_FAIL fails every
# call of a subcommand for the whole run, which cannot be aimed at one reader
# where several of them read the same subcommand.
if [[ -n "${OT_TMUX_FAIL_NTH:-}" && "${1:-}" == "${OT_TMUX_FAIL_NTH%%:*}" ]]; then
  seen="$(grep -c "^${OT_TMUX_FAIL_NTH%%:*} " "$OT_TMUX_LOG")" || true
  [[ "$seen" != "${OT_TMUX_FAIL_NTH##*:}" ]] || exit 1
fi
n=0; [[ -f "${OT_TMUX_PANES:-}" ]] && n="$(cat "$OT_TMUX_PANES")"
# The pane replayed from the log the launcher's own calls wrote: `state` is ssh
# or shell, `connections` counts the pastes that dialled, and `reads` counts the
# pane_current_command reads since the newest dial.
eval "$(awk '
  /^clear; ssh / { if (state != "ssh") { conn++; state = "ssh"; reads = 0 } ; next }
  /^send-keys .* C-c$/ { if (ENVIRON["OT_SSH_IGNORES_INTERRUPT"] == "") state = "shell"; next }
  /^display-message .*pane_current_command/ { if (state == "ssh") reads++ }
  END { printf "state=%s connections=%d reads=%d\n", (state == "ssh" ? "ssh" : "shell"), conn + 0, reads + 0 }
' "$OT_TMUX_LOG")"
# A connection the row says has outlived its welcome: the pane is back at its
# own shell, exactly as one whose ssh was interrupted is.
if [[ "$state" == ssh && -n "${OT_SSH_DIES_AFTER:-}" && "$reads" -gt "$OT_SSH_DIES_AFTER" ]]; then
  state=shell
fi
case "${1:-}" in
  new-window)
    n=$((n + 1)); [[ -z "${OT_TMUX_PANES:-}" ]] || printf '%s' "$n" > "$OT_TMUX_PANES"
    echo "$OT_TMUX_SERVER_PID %$n" ;;
  list-panes)
    # The pane ids alone where the read asks for nothing more, as tmux prints them.
    # The pane writer's identity read also asks what each pane runs, replayed
    # for the newest window since only it is written to: ssh while a dial
    # holds it, the harness once a local launch line has been typed, and the
    # window's own shell before either and after an interrupt.
    running="$(awk -v late="${OT_HARNESS_LATE:-0}" -v exits="${OT_HARNESS_EXITS:-}" '
      /^new-window / { s = "bash" }
      /^clear; ssh / { s = "ssh"; next }
      /^send-keys .* C-c$/ { if (ENVIRON["OT_SSH_IGNORES_INTERRUPT"] == "") s = "bash"; next }
      /^clear; / { s = "claude"; reads = 0; next }
      /^list-panes .*pane_current_command/ { reads++ }
      END {
        if (s == "claude" && (reads <= late || (exits != "" && reads > late + exits))) s = "bash"
        print (s == "" ? "bash" : s)
      }
    ' "$OT_TMUX_LOG")"
    i=1; while [[ "$i" -le "$n" ]]; do
      if [[ "${*: -1}" == '#{pane_id}' ]]; then echo "%$i"
      elif [[ "$*" == *pane_current_command* ]]; then printf '%%%s\t%s\t%s\n' "$i" "$OT_TMUX_SERVER_PID" "$running"
      else echo "$OT_TMUX_SERVER_PID %$i"; fi
      i=$((i + 1))
    done ;;
  list-windows)
    # A relaunch asks for existing same-name windows. This neutral fixture
    # holds none; the unfiltered index read still sees the controller window.
    [[ " $* " == *' -f '* ]] || echo "1" ;;
  show-environment)
    # The tmux environment a new pane inherits, which is not the launcher's own.
    # tmux keeps TWO of them and the read names which: the SESSION scope without
    # -g, the GLOBAL scope with it, the latter being where the environment the
    # server was started with lands. A pane takes the session entry wherever it
    # has one. So this arm answers per scope, from a variable of that scope's
    # own, and a scope holding nothing fails the read the way the real tmux
    # reports an unknown variable. The value `-` is that scope's removal marker,
    # which tmux prints as a leading dash on the name and which hides the
    # variable from the pane.
    var="${!#}"
    if [[ "${2:-}" == -g ]]; then value="${OT_TMUX_ENV_GLOBAL_CODEX_HOME:-}"
    else value="${OT_TMUX_ENV_SESSION_CODEX_HOME:-}"; fi
    { [[ "$var" == CODEX_HOME ]] && [[ -n "$value" ]]; } || exit 1
    if [[ "$value" == - ]]; then printf -- '-%s\n' "$var"; else printf '%s=%s\n' "$var" "$value"; fi ;;
  display-message)
    if [[ "$*" == *pane_current_command* ]]; then
      if [[ "$state" == ssh ]]; then echo ssh; else echo bash; fi
    elif [[ "$*" == *pane_pid* ]]; then
      # The moment the account check starts: a row that holds its leaf back
      # until then puts the first read inside the window it is pinning.
      [[ -z "${OT_PANE_PID_TRIGGER:-}" ]] || : > "$OT_PANE_PID_TRIGGER"
      printf '%s\n' "${OT_PANE_PID:-0}"
    else echo 0; fi ;;
  capture-pane)
    # A connection whose host has not answered yet: a screen ending in a full
    # stop, which carries no prompt character.
    if [[ "$state" == ssh && -n "${OT_SSH_CONNECTS_ON:-}" && "$connections" -lt "$OT_SSH_CONNECTS_ON" ]]; then printf 'Connecting to lane.example...\n'
    # $OT_HARNESS_SCREEN names a file holding the screen a hosted harness
    # draws once the remote command, opened by the stub host's remote prefix,
    # is typed into the connected session.
    elif [[ "$state" == ssh && -n "${OT_HARNESS_SCREEN:-}" ]] && grep -q '^exec bash -lc ' "$OT_TMUX_LOG"; then cat "$OT_HARNESS_SCREEN"
    # With a gate named, the pane shows nothing a launch check accepts until
    # that file exists: a row can then hold "launched" back until the wrapper
    # has handed the account over, which is the order the real thing has.
    # The connected screen a row spells out, from a file because a screen is
    # several lines while run_ot's env list is one.
    elif [[ "$state" == ssh && -n "${OT_SSH_SCREEN:-}" ]]; then cat "$OT_SSH_SCREEN"
    elif [[ -n "${OT_SCREEN_FILE:-}" ]] && (( $(awk -v n="${OT_COMPOSER_ON_ENTER:-1}" '
        /^send-keys .* Enter$/ { e++ }
        /^capture-pane / { if (up) c++; else if (e >= n) up = 1 }
        END { print c + 0 }' "$OT_TMUX_LOG") >= ${OT_SCREEN_ON:-1} )); then
      if [[ " $* " == *' -S - '* ]]; then cat "$OT_SCREEN_FILE"; else tail -n 5 "$OT_SCREEN_FILE"; fi
    elif [[ -n "${OT_COMPOSER_ON_ENTER:-}" ]]; then
      enters="$(grep -c '^send-keys .* Enter$' "$OT_TMUX_LOG")" || true
      if (( enters < OT_COMPOSER_ON_ENTER )); then printf 'dev@lane:~$\n'
      elif (( enters == OT_COMPOSER_ON_ENTER )); then printf '\xe2\x9d\xaf\xc2\xa0\n'
      else
        awk -v n="$OT_COMPOSER_ON_ENTER" '
          /^send-keys .* Enter$/ { e++; next }
          loaded { if (e >= n) { print; exit } loaded = 0; next }
          /^load-buffer / { loaded = 1 }' "$OT_TMUX_LOG"
      fi
    elif [[ -n "${OT_LAUNCHED_GATE:-}" && ! -e "$OT_LAUNCHED_GATE" ]]; then printf 'dev@lane:~$\n'
    else printf '%s\n' "${OT_PANE_TEXT:-dev@lane:~\$}"; fi ;;
  # pane-write passes text on stdin and files by path. Read either once:
  # logging must not consume stdin before the inline host replay reads it.
  load-buffer)
    line="$(cat -- "${!#}")" || exit 1
    printf '%s\n' "$line" >> "$OT_TMUX_LOG" || exit 1
    # A relaunch row can execute the rendered command before the screen read.
    # The real selector writes its result to the fixture host's filesystem.
    if [[ -n "${OT_REPLAY_LIB:-}" && "$line" == 'exec bash -lc '* ]]; then
      source "${OT_REPLAY_LIB%/*}/shared-skill-libs.sh" || exit 1
      source "$OT_REPLAY_LIB" || exit 1
      ot_replay_relaunch "$line" "$OT_REPLAY_SCRIPTS" "$OT_REPLAY_RUN" "$OT_REPLAY_HARNESS" "$OT_REPLAY_KIND" 0 "${OT_REPLAY_ITEM:-CC-1}" > "$OT_REPLAY_RUN/replay.out" || exit 1
    fi ;;
esac
exit 0
STUBEOF
# sleep: the launcher's tmux waits poll the pane above once per `sleep 1`,
# and the pane is replayed from the log, never timed, so with
# $OT_SLEEP_INSTANT set a whole-second sleep returns at once and every wait
# makes the same looks in no wall time. Unset, and for any other argument,
# it is the real sleep, which a row racing a real process keeps.
real_sleep="$(command -v sleep)" || { echo "ot_stub_bin: no sleep on PATH" >&2; return 1; }
cat > "$1/sleep" <<STUBEOF
#!/usr/bin/env bash
if [[ -n "\${OT_SLEEP_INSTANT:-}" && "\${1:-}" =~ ^[0-9]+\$ && "\$#" -eq 1 ]]; then exit 0; fi
exec "$real_sleep" "\$@"
STUBEOF
# ghostty is where open_gui ends: $OT_CAPTURE, when a row sets it, receives the
# command it hands `bash -lc`, its last argument.
cat > "$1/ghostty" <<'STUBEOF'
#!/usr/bin/env bash
[[ -z "${OT_CAPTURE:-}" ]] || printf '%s\n' "${!#}" > "$OT_CAPTURE"
exit 0
STUBEOF
chmod +x "$1/worktree" "$1/gh" "$1/tmux" "$1/ghostty" "$1/sleep"
}

# Read the remote command from a pane log and remove the two shell-quote
# layers around the hosted selection command. Never execute the logged text.
ot_hosted_relaunch_text() { # LOG
  local line
  line="$(grep -m1 '^exec bash -lc ' "$1")" || return 1
  printf '%s\n' "$line" | sed "s/'\\\\''/'/g" | sed "s/'\\\\''/'/g"
}

# Replay real host selection; KIND names its store, STATUS the harness exit.
ot_replay_relaunch() { # LINE SCRIPTS RUN HARNESS KIND STATUS [ITEM]
  local line="$1" scripts="$2" run="$3" harness="$4" kind="$5" status="$6" item="${7:-CC-1}"
  local sandbox="${OT_REPLAY_SANDBOX:-$run/sandbox}" home="$run/host-home" root session_cwd rc=0 metadata
  local arg previous="" runs=0 resume=0 fresh=0 target=0 unattended expected_prompt
  unattended="$(
    source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib/lane-launch.sh" && printf '%s' "$LAUNCH_UNATTENDED_TEXT"
  )" || return 1
  [[ -n "$unattended" ]] || { echo "ot-replay-relaunch: unattended-text=empty" >&2; return 1; }
  mkdir -p "$sandbox/.agents/skills/orch" "$sandbox/tmp/lane-mail/$item" "$home" "$run/harness-bin" || return 1
  ln -s "$scripts" "$sandbox/.agents/skills/orch/scripts" || return 1
  orch_fixture_shared_libs "$sandbox/.agents/skills/orch"
  case "$harness" in
    codex) root="$home/codex account/sessions"; expected_prompt="Read .agents/skills/orch/SKILL.md and execute the orch start workflow for $item. $unattended" ;;
    pi) root="$home/pi agent/sessions"; expected_prompt="/skill:orch start $item $unattended" ;;
  esac
  session_cwd="$sandbox"
  [[ "$kind" != foreign ]] || session_cwd="$run/other-repo/$item"
  case "$kind" in
    matching | foreign | newer-foreign | newer-worker | newer-exec | newer-parent)
      mkdir -p "$root" || return 1
      if [[ "$harness" == codex ]]; then
        jq -nc --arg cwd "$session_cwd" '{type:"session_meta",payload:{id:"11111111-1111-4111-8111-111111111111",cwd:$cwd,source:"cli"}}' > "$root/session.jsonl" || return 1
      else
        jq -nc --arg cwd "$session_cwd" '{type:"session",version:3,id:"11111111-1111-4111-8111-111111111111",cwd:$cwd,parentSession:"/previous/lead.jsonl"}' > "$root/session.jsonl" || return 1
      fi ;;
    empty) mkdir -p "$root"; : > "$root/session.jsonl" ;;
    scan-failed) mkdir -p "${root%/*}"; : > "$root" ;;
    none) ;;
  esac
  # Foreign sessions can repeat a kickoff; SessionMeta owns source and parent.
  case "$kind" in
    newer-foreign) metadata='"source":"cli"'; session_cwd="$run/other-repo/$item" ;;
    newer-worker | worker-only) metadata='"source":{"subagent":{"thread_spawn":{"parent_thread_id":"11111111-1111-4111-8111-111111111111","depth":1}}},"parent_thread_id":"11111111-1111-4111-8111-111111111111"' ;;
    newer-exec | exec-only) metadata='"source":"exec"' ;;
    newer-parent | parent-only) metadata='"source":"cli","parent_thread_id":"11111111-1111-4111-8111-111111111111"' ;;
    *) metadata="" ;;
  esac
  if [[ -n "$metadata" ]]; then
    mkdir -p "$root" || return 1
    if [[ "$harness" == codex ]]; then
      jq -nc --arg cwd "$session_cwd" --arg item "$item" --argjson meta "{$metadata}" '{type:"session_meta",payload:($meta+{id:"22222222-2222-4222-8222-222222222222",cwd:$cwd})},{type:"event_msg",payload:{type:"user_message",message:("start " + $item)}}' > "$root/worker.jsonl" || return 1
    else
      jq -nc --arg cwd "$session_cwd" --arg item "$item" '{type:"session",version:3,id:"22222222-2222-4222-8222-222222222222",cwd:$cwd},{type:"message",message:{role:"user",content:[{type:"text",text:("start " + $item)}]}}' > "$root/worker.jsonl" || return 1
    fi
    # Fixed mtimes prove the newer foreign session loses, without a wait.
    [[ ! -f "$root/session.jsonl" ]] || touch -t 202601010000 "$root/session.jsonl" || return 1
    touch -t 202601010001 "$root/worker.jsonl" || return 1
  fi
  cat > "$run/harness-bin/$harness" <<'EOF'
#!/usr/bin/env bash
# NUL preserves argument boundaries, including spaces and an empty resume id.
printf '%s\0' __run__ "$@" >> "$HARNESS_LOG"
exit "$HARNESS_RC"
EOF
  chmod +x "$run/harness-bin/$harness" || return 1
  : > "$run/harness.log"
  line="${line/#exec bash -lc /bash -c }"
  line="${line/cd \/srv\/lane /cd $sandbox }"
  env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$run/harness-bin:$PATH" HOME="$home" CODEX_HOME="$home/codex account" \
    PI_CODING_AGENT_DIR="$home/pi agent" HARNESS_LOG="$run/harness.log" HARNESS_RC="$status" \
    bash -c "$line" 2> "$run/replay.err" || rc=$?
  while IFS= read -r -d '' arg; do
    case "$previous" in
      resume) [[ "$arg" != 11111111-1111-4111-8111-111111111111 ]] || target=$((target + 1)) ;;
      --session) [[ "$arg" != "$root/session.jsonl" ]] || target=$((target + 1)) ;;
    esac
    case "$arg" in
      __run__) runs=$((runs + 1)) ;;
      resume | --session) resume=$((resume + 1)) ;;
      "$expected_prompt") fresh=$((fresh + 1)) ;;
    esac
    previous="$arg"
  done < "$run/harness.log"
  printf 'rc=%d runs=%d resume=%d fresh=%d target=%d\n' "$rc" "$runs" "$resume" "$fresh" "$target"
}

# ot_fleet_state WORKFLOW_STATE DIR CWD — a fleet state at DIR whose overseer
# record names CWD, as `oversee register` records the overseer's directory:
# open-terminal binds a launch under --state-dir DIR to CWD's repository, so a
# suite whose launches run from its own checkout seeds it with that directory.
ot_fleet_state() {
  "$1" --state-dir "$2" init oversee >/dev/null || return 1
  "$1" --state-dir "$2" update oversee --arg cwd "$3" '.overseer = {cwd: $cwd}' >/dev/null
}
