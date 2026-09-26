# shellcheck shell=bash
#
# The ONE writer into a tmux pane. Every keystroke orch sends, and every paste,
# goes through pane_write: the launch lines open-terminal types into a window it
# just opened, the successor line overseer-host-tmux's create types into the
# window it opens, and what the overseer still has to type through
# ../pane-write, such as a
# harness dialog's answer or a continuation line: a walled lane's nudge, a
# hosted Codex relaunch's line, the resend after model-capacity. A raw
# `tmux paste-buffer -t ""` types into whatever pane the caller sits in, which
# is how an overseer pasted `/exit` into itself; a write into a pane whose
# process has changed lands its keystrokes in a process nobody meant. Both are refused here, before anything is typed.
#
# This is the whole of pane input, the capability a later thread API (turn
# start, interrupt, stop) replaces: moving a caller onto that API removes its
# call here, and nothing else in orch types into a pane.
#
# Sourced, never run. lib/lane-state.sh is sourced first: the pane resolution is
# its lane_pane_resolve and lane_pane_by_id, the shell names its is_bare_shell,
# and the process read its lane_process_table and lane_process_below.
#
# pane_write KIND TARGET EXPECT ACTION VALUE
#
#   KIND    `window`: TARGET is a lane record's window, resolved through
#           lane_pane_resolve. `pane`: TARGET is a pane id (%N) the caller
#           proved, which is new-window's own -P output for a pane it opened.
#   EXPECT  the process the pane must be running. `shell` is a shell in the
#           foreground, what a window opened seconds ago holds: a name
#           is_bare_shell knows, or the name of tmux's default-shell, read
#           again for up to PANE_WRITE_SETTLE_SECS (default 2) while a
#           default-command wrapper still holds the pane. Any other
#           word is a process name: the pane's foreground command, or the pane
#           process or a process below it, carries that name. The second form
#           is a harness started under a shell or through a wrapper script.
#   ACTION  `text`: paste VALUE itself as one bracketed paste, then press
#           Enter. `file`: the same with a file's bytes. `key`: press the one
#           key VALUE names, from PANE_WRITE_KEYS.
#
# Copy mode is cancelled, and read back as cancelled, before every keystroke:
# a key sent to a pane in copy mode drives the copy-mode cursor and never
# reaches the program.
#
# Status 0 wrote. Status 1 refused before anything was typed, and status 2 is a
# tmux write that failed after the checks passed, so part of the input may
# have landed. Either prints its keyed line, then a `fix=` line, on stderr.
#
# The identity is read before the copy-mode check and the buffer load, and the
# Enter that follows a paste is not checked again: a process that changes after
# that read is not caught.

# The keys a caller may press, each with its producer: Enter (the composer
# after a paste, a dialog's default), Up and Down (moving a Claude Code
# dialog's selection), C-c (interrupting a stalled ssh client), and a digit
# (a Codex dialog's numbered choice).
PANE_WRITE_KEYS='Enter Up Down C-c 0 1 2 3 4 5 6 7 8 9'
PANE_WRITE_ID=""
PANE_WRITE_PID=""
PANE_WRITE_CMD=""

pane_write_message() { # KEY FIELD=VALUE...
  local key="$1" field
  shift
  printf 'pane-write: %s' "$key"
  for field in "$@"; do printf ' %s' "$field"; done
  printf '\n'
  case "$key" in
    pane-unresolved) printf '%s\n' 'fix=name the lane by its recorded window (--window), or a pane you opened by the pane id (%N) new-window printed (--pane)' ;;
    pane-self) printf '%s\n' 'fix=the target is the pane this command runs in; name the lane'"'"'s own window' ;;
    pane-missing) printf '%s\n' 'fix=no pane on this tmux server carries the target; read the lane record'"'"'s window again, or relaunch a lane whose window closed' ;;
    pane-ambiguous) printf '%s\n' 'fix=more than one pane carries the window name; rename the one that is not the lane'"'"'s, as lane-reach.md § Wake refusals says' ;;
    pane-read-failed) printf '%s\n' 'fix=tmux or the process table did not answer; nothing was typed, and a retry is safe once it does' ;;
    process-mismatch)
      case " $* " in
        *" expected=shell "*) printf '%s\n' 'fix=a window just opened must be at its shell, one of bash, zsh, fish, sh, dash or tmux'"'"'s default-shell; set default-shell to the shell it runs, and where a default-command wraps the shell (systemd-run, a confine script) raise PANE_WRITE_SETTLE_SECS past the time the wrapper takes to hand the pane to it' ;;
        *) printf '%s\n' 'fix=the pane does not run the expected process; read the lane'"'"'s state with lanes state before writing to it' ;;
      esac ;;
    settle-invalid) printf '%s\n' 'fix=PANE_WRITE_SETTLE_SECS is a whole number of seconds from 0 to 99; nothing was typed' ;;
    expect-missing) printf '%s\n' 'fix=name the process the pane must run: shell for a window just opened, or the harness, or ssh for a hosted lane' ;;
    action-invalid) printf '%s\n' 'fix=the action is text, file or key; this is a defect in the caller' ;;
    key-invalid) printf '%s\n' "fix=press one of: $PANE_WRITE_KEYS" ;;
    file-unreadable) printf '%s\n' 'fix=write the input to a regular file first, with the harness file tool' ;;
    argument-invalid) printf '%s\n' 'fix=run pane-write --help' ;;
    write-failed) printf '%s\n' 'fix=a tmux write failed after the checks passed and part of the input may have landed; read the pane before writing again' ;;
    *) printf '%s\n' "fix=pane_write has no message for $key; this is a defect in lib/pane-write.sh" ;;
  esac
}

# pane_write_refuse STATUS KEY FIELD=VALUE... — the one exit of every refusal.
pane_write_refuse() {
  local status="$1"
  shift
  pane_write_message "$@" >&2
  return "$status"
}

# The pane a TARGET names, into PANE_WRITE_ID, _PID and _CMD.
pane_write_resolve() { # KIND TARGET
  local rc=0
  PANE_WRITE_ID=""; PANE_WRITE_PID=""; PANE_WRITE_CMD=""
  [[ -n "$2" ]] || { pane_write_refuse 1 pane-unresolved "kind=$1" 'target='; return; }
  case "$1" in
    window)
      lane_pane_resolve "$2" || rc=$?
      case "$rc" in
        0) ;;
        1)
          if [[ "$LANE_PANE_COUNT" == 0 ]]; then
            pane_write_refuse 1 pane-missing "window=$2"
          else
            pane_write_refuse 1 pane-ambiguous "window=$2" "count=$LANE_PANE_COUNT"
          fi
          return ;;
        *) pane_write_refuse 1 pane-read-failed "window=$2" operation=list-panes; return ;;
      esac
      PANE_WRITE_ID="$LANE_PANE_ID"; PANE_WRITE_PID="$LANE_PANE_PID"; PANE_WRITE_CMD="$LANE_PANE_CMD" ;;
    pane)
      # A pane id and nothing else: tmux reads any other word as a window or
      # session name, which is the resolution this KIND exists to skip.
      [[ "$2" =~ ^%[0-9]+$ ]] || { pane_write_refuse 1 pane-unresolved kind=pane "target=$2"; return; }
      lane_pane_by_id "$2" || rc=$?
      case "$rc" in
        0) ;;
        1) pane_write_refuse 1 pane-missing "pane=$2"; return ;;
        *) pane_write_refuse 1 pane-read-failed "pane=$2" operation=list-panes; return ;;
      esac
      PANE_WRITE_ID="$LANE_PANE_ID"; PANE_WRITE_PID="$LANE_PANE_PID"; PANE_WRITE_CMD="$LANE_PANE_CMD" ;;
    *) pane_write_refuse 1 pane-unresolved "kind=$1" "target=$2"; return ;;
  esac
  if [[ -n "${TMUX_PANE:-}" && "$PANE_WRITE_ID" == "$TMUX_PANE" ]]; then
    pane_write_refuse 1 pane-self "pane=$PANE_WRITE_ID"
    return
  fi
}

# Whether the resolved pane runs EXPECT.
pane_write_expect() { # EXPECT
  local table found default name_re settle="${PANE_WRITE_SETTLE_SECS:-2}" reads=0 rc
  [[ -n "$1" ]] || { pane_write_refuse 1 expect-missing "pane=$PANE_WRITE_ID"; return; }
  if [[ "$1" == shell ]]; then
    # A tmux default-command that wraps the shell, such as one starting it in
    # its own systemd scope, holds a new window's foreground for a moment
    # before the shell does, so the command is read again every tenth of a
    # second until the settle time is spent.
    while :; do
      is_bare_shell "$PANE_WRITE_CMD" && return 0
      if [[ "$reads" == 0 ]]; then
        [[ "$settle" =~ ^[0-9]{1,2}$ ]] \
          || { pane_write_refuse 1 settle-invalid "pane=$PANE_WRITE_ID" setting=PANE_WRITE_SETTLE_SECS "value=$settle"; return; }
        default="$(tmux show-options -gv default-shell 2>/dev/null)" \
          || { pane_write_refuse 1 pane-read-failed "pane=$PANE_WRITE_ID" operation=show-options; return; }
        default="${default##*/}"
      fi
      # A shell is_bare_shell does not name is still the window's own when it
      # is the one tmux starts in a new window.
      [[ -z "$default" || "${PANE_WRITE_CMD#-}" != "$default" ]] || return 0
      [[ "$reads" -lt $((10#$settle * 10)) ]] || break
      reads=$((reads + 1))
      sleep 0.1
      rc=0
      lane_pane_by_id "$PANE_WRITE_ID" || rc=$?
      case "$rc" in
        0) PANE_WRITE_CMD="$LANE_PANE_CMD" ;;
        1) pane_write_refuse 1 pane-missing "pane=$PANE_WRITE_ID"; return ;;
        *) pane_write_refuse 1 pane-read-failed "pane=$PANE_WRITE_ID" operation=list-panes; return ;;
      esac
    done
  else
    [[ "$PANE_WRITE_CMD" == "$1" ]] && return 0
    table="$(lane_process_table)" \
      || { pane_write_refuse 1 pane-read-failed "pane=$PANE_WRITE_ID" operation=ps; return; }
    # The name as a whole-name ERE, its metacharacters escaped.
    name_re="$(printf '%s' "$1" | sed 's/[][\\.*^$+?(){}|]/\\&/g')" \
      || { pane_write_refuse 1 pane-read-failed "pane=$PANE_WRITE_ID" operation=ps; return; }
    found="$(lane_process_below "$table" "$PANE_WRITE_PID" "^$name_re\$" 1)" \
      || { pane_write_refuse 1 pane-read-failed "pane=$PANE_WRITE_ID" operation=ps; return; }
    [[ "$found" != found ]] || return 0
  fi
  pane_write_refuse 1 process-mismatch "pane=$PANE_WRITE_ID" "expected=$1" "running=${PANE_WRITE_CMD:-none}"
}

# Copy mode off, read back as off.
pane_write_mode_clear() {
  local mode
  mode="$(tmux display-message -p -t "$PANE_WRITE_ID" '#{pane_in_mode}' 2>/dev/null)" \
    || { pane_write_refuse 2 write-failed "pane=$PANE_WRITE_ID" step=mode-read; return; }
  if [[ "$mode" == 1 ]]; then
    tmux send-keys -t "$PANE_WRITE_ID" -X cancel 2>/dev/null \
      || { pane_write_refuse 2 write-failed "pane=$PANE_WRITE_ID" step=copy-mode-cancel; return; }
    mode="$(tmux display-message -p -t "$PANE_WRITE_ID" '#{pane_in_mode}' 2>/dev/null)" \
      || { pane_write_refuse 2 write-failed "pane=$PANE_WRITE_ID" step=mode-read; return; }
  fi
  [[ "$mode" == 0 ]] || pane_write_refuse 2 write-failed "pane=$PANE_WRITE_ID" step=copy-mode "mode=$mode"
}

pane_write_key() { # KEY
  pane_write_mode_clear || return
  tmux send-keys -t "$PANE_WRITE_ID" "$1" 2>/dev/null \
    || pane_write_refuse 2 write-failed "pane=$PANE_WRITE_ID" step=send-keys "key=$1"
}

pane_write() { # KIND TARGET EXPECT ACTION VALUE
  local kind="$1" target="$2" expect="$3" action="$4" value="$5" buffer
  # The input is checked before the pane, so a malformed call is refused the
  # same way whatever the target.
  case "$action" in
    key)
      case " $PANE_WRITE_KEYS " in
        *" $value "*) ;;
        *) pane_write_refuse 1 key-invalid "key=$value"; return ;;
      esac ;;
    text) ;;
    file) [[ -f "$value" && -r "$value" ]] || { pane_write_refuse 1 file-unreadable "file=$value"; return; } ;;
    *) pane_write_refuse 1 action-invalid "action=$action"; return ;;
  esac
  pane_write_resolve "$kind" "$target" || return
  pane_write_expect "$expect" || return
  if [[ "$action" == key ]]; then
    pane_write_key "$value"
    return
  fi
  # A named buffer, so another writer's paste cannot take this one's text off
  # the top of the stack; -d deletes it once pasted. $$ alone does not tell
  # writers apart: every subshell and background job of one script shares it,
  # so the pane id is in the name too. Two writers into one pane at once still
  # share a buffer, and their input would interleave in that pane regardless.
  buffer="pane-write-$$-${PANE_WRITE_ID#%}"
  pane_write_mode_clear || return
  # Text reaches the buffer on stdin from a process substitution, never a pipe,
  # so a reader that stops early costs the writer nothing.
  if [[ "$action" == text ]]; then
    tmux load-buffer -b "$buffer" - < <(printf '%s' "$value") 2>/dev/null
  else
    tmux load-buffer -b "$buffer" "$value" 2>/dev/null
  fi || { pane_write_refuse 2 write-failed "pane=$PANE_WRITE_ID" step=load-buffer; return; }
  if ! tmux paste-buffer -p -d -b "$buffer" -t "$PANE_WRITE_ID" 2>/dev/null; then
    # -d deletes only a buffer that was pasted. Left on the server, this text,
    # a hosted lane's ssh line among it, is there for a later paste to type
    # into another pane; the refusal stands whether the delete lands or not.
    tmux delete-buffer -b "$buffer" 2>/dev/null || :
    pane_write_refuse 2 write-failed "pane=$PANE_WRITE_ID" step=paste-buffer
    return
  fi
  pane_write_key Enter
}
