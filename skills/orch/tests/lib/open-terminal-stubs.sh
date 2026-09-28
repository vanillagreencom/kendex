# shellcheck shell=bash
#
# The stub commands an open-terminal suite puts ahead of PATH: worktree, gh,
# tmux and ghostty. Each logs what the launcher asked of it and answers as the
# real command would, so a row reads the windows a launch opened, the lines it
# typed and the worktrees it created without opening a real window. The two
# suites that drive open-terminal through lanes and hosts, open-terminal-lane.sh
# and open-terminal-brief-file.sh, share them.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run.

# ot_stub_bin DIR — writes the four stubs into DIR, which it creates.
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
  printf '%s\n' "$d" >> "${OT_WT_PATH:-/dev/null}"
  printf '%s\n' "$d"
  exit 0
fi
exit 0
STUBEOF
cat > "$1/gh" <<'STUBEOF'
#!/usr/bin/env bash
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
    running="$(awk '
      /^new-window / { s = "bash" }
      /^clear; ssh / { s = "ssh"; next }
      /^send-keys .* C-c$/ { if (ENVIRON["OT_SSH_IGNORES_INTERRUPT"] == "") s = "bash"; next }
      /^clear; / { s = "claude" }
      END { print (s == "" ? "bash" : s) }
    ' "$OT_TMUX_LOG")"
    i=1; while [[ "$i" -le "$n" ]]; do
      if [[ "${*: -1}" == '#{pane_id}' ]]; then echo "%$i"
      elif [[ "$*" == *pane_current_command* ]]; then printf '%%%s\t%s\t%s\n' "$i" "$OT_TMUX_SERVER_PID" "$running"
      else echo "$OT_TMUX_SERVER_PID %$i"; fi
      i=$((i + 1))
    done ;;
  list-windows) echo "1" ;;
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
    # With a gate named, the pane shows nothing a launch check accepts until
    # that file exists: a row can then hold "launched" back until the wrapper
    # has handed the account over, which is the order the real thing has.
    # The connected screen a row spells out, from a file because a screen is
    # several lines while run_ot's env list is one.
    elif [[ "$state" == ssh && -n "${OT_SSH_SCREEN:-}" ]]; then cat "$OT_SSH_SCREEN"
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
  # The pasted text on a line of its own: a paste carries no newline, and the
  # next call's log line would otherwise run on from it.
  load-buffer) { cat "${!#}"; echo; } >> "$OT_TMUX_LOG" ;;
esac
exit 0
STUBEOF
# ghostty is where open_gui ends: $OT_CAPTURE, when a row sets it, receives the
# command it hands `bash -lc`, its last argument.
cat > "$1/ghostty" <<'STUBEOF'
#!/usr/bin/env bash
[[ -z "${OT_CAPTURE:-}" ]] || printf '%s\n' "${!#}" > "$OT_CAPTURE"
exit 0
STUBEOF
chmod +x "$1/worktree" "$1/gh" "$1/tmux" "$1/ghostty"
}
