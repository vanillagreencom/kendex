# shellcheck shell=bash
#
# The one answer to "how does a resolved lane reach the launched harness, and
# is the pane really running it". Every launcher that starts a harness on a
# chosen account builds its command here — open-terminal for a work item,
# oversee-succeed for a successor overseer — so a second builder cannot drift
# from the first and launch onto an account nobody picked.
#
# Sourced, never run.

# lane_account_check below compares two config dirs through lane_claims_canon,
# the one normaliser for a lane path. A caller that had not sourced that sibling
# would run both comparisons as an absent command, and two DIFFERENT accounts
# would compare equal as the empty string — the guard reporting `verified` for
# the very disagreement it exists to catch. The dependency is this file's, so
# this file takes it. That sibling sets `set -euo pipefail` as it loads, so a
# caller that must stay errexit-free restores its own posture after sourcing
# this file, the way `lanes` already does at its lib seam.
# shellcheck source=lane-claims.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lane-claims.sh"

# The env prefix that puts a launch on a chosen account: the harness names the
# variable, the directory IS the account. One mapping for every caller — the
# chooser in `lanes` that hands a picked lane back as a prefix, and the
# launchers that render it into a command — so a harness added to one of them
# cannot go on being prefixed with the other harness's variable, which starts it
# on whatever account that harness defaults to with nothing on screen saying so.
#
# Codex is named and every other harness takes the Claude variable, which is
# what a local `--lane` launch on a further harness has always done; `lanes`
# measures claude and codex only and produces no third value here. A harness
# added to this repository adds its arm HERE.
lane_env_prefix() { # HARNESS DIR
  local var=CLAUDE_CONFIG_DIR
  [[ "$1" != codex ]] || var=CODEX_HOME
  printf '%s=%s\n' "$var" "$2"
}

# A value the pane's own shell reads back as itself.
lane_single_quote() { # VALUE
  local escaped="'\\''"
  printf "'%s'" "${1//\'/$escaped}"
}

# The ONE decision about how a resolved lane reaches the launched harness, made
# once per launch and read both by the launch line and by the account check that
# follows the pane open. Prints one of:
#   launcher:<path>  launch through that file, with no env prefix
#   prefix           launch under the env prefix, and check the pane
#   unchecked        launch under the env prefix where a lane was resolved;
#                    nothing of ours to check either way
#
# A LAUNCHER is a command named for the lane's own config directory — its
# basename without the leading dot — which selects the account itself. Where one
# exists it is the WHOLE selector and the prefix is dropped: such a wrapper
# exports the lane variable for its OWN name, so under `env VAR=<picked> claude`
# it overwrites the prefix and the lane runs on another account with nothing on
# screen saying so. The config directory's basename, never a lane alias: an
# operator can rename a lane to `work`, and no `work` command exists. The name
# is derived the way `lanes` derives its own, `basename --` then the leading
# dot, so every spelling that reaches `lanes` reaches this judge identically.
# `${dir##*/}` is not that: a trailing slash, which `--lane` and an
# ORCH_LANE_DIRS entry both carry through unnormalised, strips the whole value
# and leaves no name to judge. One normalisation, not a case per spelling.
#
# An absolute, executable path only, so a shell builtin sharing the lane's name
# is not mistaken for a wrapper. That path is also what gets RENDERED, quoted.
# A bare word in the launch line is resolved AGAIN by the pane's own shell, and
# a tmux server started before a PATH change or a login shell that reorders PATH
# resolves a different file or none while the env prefix has already been
# dropped — the function judging one file and the pane running another. An
# absolute path leaves the wrapper's own account selection intact, since it
# reads its invocation name and `${0##*/}` of `/…/bin/1claude` is `1claude`.
#
# The name must CARRY the harness word and not BE it. The harness binary is the
# thing being configured, never a configurator: `claude` for a lane at
# `~/.claude` or `<dir>/accounts/claude`, and `codex` for one at
# `~/.config/codex`, would select that harness's own default account while the
# dropped prefix stopped selecting anything. A name belonging to the OTHER
# harness is the same mistake pointed elsewhere — a lane and a harness are
# chosen independently, so a codex lane launched under claude would otherwise
# render `1codex` running claude's arguments. Both fall through to the prefix
# form, which selected these lanes correctly all along.
#
# Local claude and codex launches only, which the caller establishes before it
# asks: a launch on another machine answers about the wrong PATH, and
# CLAUDE_CONFIG_DIR and CODEX_HOME are those two harnesses' own variables. A
# rendered command that does not open on the harness word has no first word to
# replace, so it keeps the prefix — which the account check still verifies.
#
# TEMPLATE non-empty says the command is the CALLER'S own, from a --cmd
# template, whose first word is not ours to replace. It is an input to this
# judge rather than a tag a caller writes for itself, so every launch that ASKS
# gets its form from this one line. A launch that never asks — a hosted one,
# which runs on another machine and carries no local lane prefix — keeps
# whatever its caller initialised the form to, and is read back by nothing.
lane_launch_form() { # CMD HARNESS LANE_DIR [TEMPLATE]
  local cmd="$1" harness="$2" dir="$3" template="${4:-}" name path
  if [[ -z "$dir" || -n "$template" ]] || [[ ! "$harness" =~ ^(claude|codex)$ ]]; then
    printf 'unchecked\n'
    return
  fi
  name="$(basename -- "$dir")" || { printf 'prefix\n'; return; }
  name="${name#.}"
  if [[ "$name" != *"$harness"* || "$name" == "$harness" ]]; then printf 'prefix\n'; return; fi
  path="$(command -v -- "$name" 2>/dev/null)" || path=""
  if [[ "$path" == /* && -x "$path" && "$cmd" == "$harness "* ]]; then
    printf 'launcher:%s\n' "$path"
  else
    printf 'prefix\n'
  fi
}

# The launch line for a command that must run on a chosen account, under the
# form lane_launch_form picked for it.
#
# The prefix value is quoted by lane_single_quote, not wrapped in bare quotes:
# lane dirs are paths, an unquoted space would split the env assignment inside
# the launch shell, and a bare pair closes early on a dir carrying an
# apostrophe — which the pane shell then rejects for an unterminated string,
# starting no harness and leaving the launch to time out naming nothing about
# quoting. Only open-terminal refuses such a dir before it gets here; a lane
# reaching this builder from anywhere else has no such gate, so the escaping is
# this builder's to do.
#
# The lane is recorded in the launched command itself, so `ps` and the pane's
# own first line show which account a stalled session belongs to — as the
# launcher's own path, or as the env prefix where the machine has no launcher.
# Not the window title: both launchers open their window with an explicit -n,
# which turns tmux's automatic rename off, so the title keeps the name it was
# given and never carries the launch line.
lane_launch_line() { # CMD HARNESS LANE_VAR LANE_DIR FORM
  local cmd="$1" harness="$2" var="$3" dir="$4" form="$5"
  case "$form" in
    launcher:*) printf '%s %s\n' "$(lane_single_quote "${form#launcher:}")" "${cmd#"$harness" }" ;;
    *) printf 'env %s=%s %s\n' "$var" "$(lane_single_quote "$dir")" "$cmd" ;;
  esac
}

# The lane variable's value in the DEEPEST process under pane pid $1 that
# carries it, empty when none does. Breadth first, so no carrier found later is
# shallower than one found earlier.
#
# Deepest, not first: under `env VAR=<picked> claude` the env process carries
# the picked value while a wrapper below it can already have replaced it, and a
# shallow read would report an agreement the running harness does not have.
#
# Exit 2 when the descendant probe itself failed, which is not an answer at all:
# pgrep's 0 and 1 are its two answers and anything else is the probe breaking.
# pgrep, not `ps --ppid`, which is procps-only and rejected by BSD ps.
lane_observed_dir() { # PANE_PID NAME
  local name="$2" frontier next pid kids value rc found=""
  frontier="$(pgrep -P "$1" 2>/dev/null)" || { rc=$?; [[ "$rc" -eq 1 ]] || return 2; frontier=""; }
  while [[ -n "$frontier" ]]; do
    next=""
    for pid in $frontier; do
      kids="$(pgrep -P "$pid" 2>/dev/null)" || { rc=$?; [[ "$rc" -eq 1 ]] || return 2; kids=""; }
      [[ -z "$kids" ]] || next+="$kids"$'\n'
      # A process that exits mid-walk takes its /proc entry with it; that is an
      # absent value, not a broken probe.
      # 2> BEFORE <: redirections apply left to right, so a suppression written
      # after the input would report a missing /proc entry on the still-open
      # stderr — a shell error in the launch output for the very case the
      # comment above calls an absent value.
      value="$(tr '\0' '\n' 2>/dev/null < "/proc/$pid/environ" | sed -n "s/^$name=//p" | tail -1)" || value=""
      [[ -z "$value" ]] || found="$value"
    done
    frontier="$next"
  done
  printf '%s\n' "$found"
}

# lane_account_readable FORM — true for a launch this check can read back at
# all: one this machine started under a lane of its own, by env prefix or by
# the account launcher. A hosted launch runs on another machine and an
# `unchecked` one carries no lane, so neither has a local pane to read.
#
# Its own name because a caller has to ask the same question BEFORE the check:
# waiting for the harness to come up ahead of a read that will not happen is
# the whole of that wait spent for nothing.
lane_account_readable() { # FORM
  case "$1" in prefix|launcher:*) return 0 ;; *) return 1 ;; esac
}

# lane_process_env_readable — true where this machine lets a process be read
# back for the environment it was handed. /proc/<pid>/environ is the whole of
# that reading, so a host without /proc — every macOS run — offers the check
# below no observation to make: it names no-process-environment and leaves the
# launch standing, however healthy the pane is.
#
# Its own name because the condition is asked twice: here, by the check, and by
# a test deciding which of its rows this host can produce at all. A second
# spelling would let the two drift and pin an outcome the check cannot reach.
lane_process_env_readable() {
  [[ -r "/proc/$$/environ" ]]
}

# The smallest bound an observation can settle inside, in seconds. A settle is
# two reads a second apart, so a check handed less than this can never verify an
# account and never catch a mismatch, whatever the pane is doing and whatever
# the loop in lane_account_check would otherwise have reported. Callers that
# share one deadline between several waits size their bounds against it.
LANE_SETTLE_MIN_SECS=1

# The account the pane is REALLY running on, against the one that was picked.
# A wrapper on PATH exports the lane variable for its own name, so a launch can
# be running on an account nobody picked while the claim recorded for it counts
# against the picked one and nothing on screen says so.
#
# The guard fails closed on what it OBSERVES and never on what it could not: an
# observed disagreement returns 1 and the caller closes the window, while no
# readable per-process environment, no pane pid, a broken descendant probe and
# no descendant carrying the variable inside the bound each return 0 with the
# reason named, and leave a healthy lane running.
#
# The outcome is one tagged value in LANE_ACCOUNT_RESULT, which every caller
# matches to choose its own message: `skipped`, `verified`, `mismatch`, or
# `unobserved:<reason>`. LANE_ACCOUNT_OBSERVED carries the dir it settled on.
#
# BOUND is how many seconds the caller gives the reading to settle, never below
# LANE_SETTLE_MIN_SECS above.
#
# An observation counts only once it SETTLES: two reads a second apart carrying
# the same value. The first non-empty read is not the harness's answer — under
# the env-prefix form the launch child carries the picked value from its own
# execve until the wrapper's exec lands, and trusting that read would confirm an
# account the pane is about to stop running.
#
# Settling proves repetition, never that the exec has landed. /proc/<pid>/environ
# is written at execve, so a wrapper slower than the settle window carries the
# value it was handed throughout and two agreeing reads agree about the wrapper.
# Only the caller can close that gap, by asking once the harness is certainly
# what answers: once the pane draws the harness's own screen, or once it shows a
# running turn — pane_harness_up in lib/lane-state.sh is that question.
#
# The premise is the CALLER'S, and neither shipped caller treats it as proven.
# open-terminal waits for it best effort and, where the wait comes back empty,
# reports the reading that follows as unobserved rather than as a verified
# account. oversee-succeed's FIRST read is deliberately unpremised — it exists
# to catch a disagreement that is already true, before the successor has had a
# turn — and only its second read, taken once the pane shows a running turn,
# carries the premise and is the one its window closes on.
# shellcheck disable=SC2034  # LANE_ACCOUNT_RESULT and LANE_ACCOUNT_OBSERVED are
# this function's answer, read by the caller that matches on it.
lane_account_check() { # PANE LANE_VAR PICKED FORM BOUND
  local pane="$1" name="$2" picked="$3" form="$4" bound="$5" pid observed rc waited=0 settled=""
  LANE_ACCOUNT_OBSERVED=""
  LANE_ACCOUNT_RESULT=skipped
  lane_account_readable "$form" || return 0
  lane_process_env_readable || { LANE_ACCOUNT_RESULT=unobserved:no-process-environment; return 0; }
  pid="$(tmux display-message -p -t "$pane" '#{pane_pid}')" || pid=""
  # 0 is not a pane's pid, and walking from it reads processes belonging to no
  # pane at all — an unrelated lane's harness among them, which would refuse a
  # healthy window over a reading that was never about it.
  [[ "$pid" =~ ^[0-9]+$ && "$pid" != 0 ]] || { LANE_ACCOUNT_RESULT=unobserved:pane-pid; return 0; }
  # Defensive: no shipped caller can drive this arm. open-terminal passes
  # $ORCH_TMUX_VERIFY_SECS, which its own gate refuses unless it is a positive
  # integer, and oversee-succeed asks succ_budget_bound, which floors every
  # bound at this constant. It exists so a caller that computes its own bound is
  # named for what it did: left to the loop, that bound would answer
  # `unsettled`, `no-lane-variable` or `descendant-probe` by whatever its first
  # read happened to find, each of which tells an operator something about the
  # pane when what happened is that the caller had no budget left to look.
  (( bound >= LANE_SETTLE_MIN_SECS )) || { LANE_ACCOUNT_RESULT=unobserved:no-settle-budget; return 0; }
  while :; do
    rc=0
    observed="$(lane_observed_dir "$pid" "$name")" || rc=$?
    [[ "$rc" -eq 0 ]] || { LANE_ACCOUNT_RESULT=unobserved:descendant-probe; return 0; }
    [[ -z "$observed" || "$observed" != "$settled" ]] || break
    settled="$observed"
    if (( waited >= bound )); then
      # A value that never repeated is a pane still changing hands, which is not
      # the same miss as never seeing one at all.
      if [[ -n "$settled" ]]; then LANE_ACCOUNT_RESULT=unobserved:unsettled
      else LANE_ACCOUNT_RESULT=unobserved:no-lane-variable; fi
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  LANE_ACCOUNT_OBSERVED="$observed"
  if [[ "$(lane_claims_canon "$observed")" == "$(lane_claims_canon "$picked")" ]]; then
    LANE_ACCOUNT_RESULT=verified
    return 0
  fi
  LANE_ACCOUNT_RESULT=mismatch
  return 1
}
