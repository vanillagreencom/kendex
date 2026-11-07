#!/usr/bin/env bash
# Launch claims per auth lane: one file per lane window an earlier install's
# launch wrote under a resolved lane, which `lanes pick` counts beside an
# account's usage numbers while the claim's pane lives.
#
# Home: $OVERSEE_WATCH_STATE_DIR/claims, else <project root>/tmp/oversee-watch/
# claims — the directory the fleet watch keeps its claim store in.
#
# A claim is live while its tmux pane is. The liveness key is
# `<server pid> <pane id>`: pane ids restart at %0 on a separate tmux server, so the
# pid keeps a claim that outlived its server from matching an unrelated pane.
#
# `tmux list-panes -a` sees ONE server — the current client's. It is authority
# over claims carrying that server's pid, and says nothing about the rest: a
# claim on another socket, or one this process could not enumerate at all, is
# judged by whether its server process still runs. Deleting a claim we could
# not measure would report a busy account as free, so it is kept and counted
# until its server is provably gone. A server process another account owns
# refuses `kill -0` as EPERM, which is no evidence it is gone: only the owning
# account can tell, so that claim is kept and counted too. Claims are recorded
# for tmux lanes only — a launch with no pane handle would leave a claim
# nothing can prune.
#
# One store can serve several homes on one host, each home's claims directory a
# link to it: every record is written group-readable whatever the writer's
# umask, so a store whose group every fleet user shares reads across homes, and
# `lanes` counts a claim by the account its config dir names, never by the
# home-specific path alone.
#
# Record: `<server pid>\t<pane id>\t<config dir>\t<window>\t<created at>\t
# <fleet>\t<named>\t<kind>\t<pool>`.
# Pool is the allowance the pick judged: plan, copilot, cloud-credit or
# api-credit. Older records without it remain plan claims.
# The config dir is canonical; `named` is the spelling the launch named the lane
# by, before canonicalisation, so a reader can name the account as `lanes list`
# does from a discovered path. A record written before it carried one has none,
# and a reader names that claim's account from its canonical config dir.
# The fleet is the oversee state file of the fleet the launch was judged in,
# empty for a launch naming no fleet, and it is what lets one store serve
# several fleets: `lanes pick` charges an account with matching-pool claims
# from any fleet that names it. A claim with an empty fleet, written by a
# launch naming no fleet or before claims carried one, counts toward its
# account.
#
# A reservation is the same record under `.reserve`, with the launcher's pid as
# its server and `-` as its pane: a place in a count held while that launcher
# runs. Its config dir is empty: only the count and cap modes of
# lane_claims_read carry reservations. Every other reader reads claims alone.
#
# No shipped launch writes a claim or a reservation: the runtime charges the
# fleet cap from its records and the kernel table. This reader stays for the
# rows of earlier installs, which it prunes as their panes and servers go.
set -euo pipefail

# Callers preserve positional values for this diagnostic catalog.
lane_claims_message() {
  local _message_key="$1"
  shift
  case "$_message_key" in
    not-directory)
      printf 'lane-claims: not-directory dir=%s\n' "$dir"
      printf '%s\n' "lane-claims: claims path $dir is not a directory; launches already in flight cannot be read"
      ;;
    unreadable-directory)
      printf 'lane-claims: unreadable-directory dir=%s\n' "$dir"
      printf '%s\n' "lane-claims: claims directory $dir is not readable; launches already in flight are invisible"
      ;;
    unreadable-claim)
      printf 'lane-claims: unreadable-claim f=%s\n' "$f"
      printf '%s\n' "lane-claims: cannot read claim $f; leaving it in place"
      ;;
  esac
}


# Directory holding the claim files. $1: project root (may be empty).
lane_claims_dir() {
  if [[ -n "${OVERSEE_WATCH_STATE_DIR:-}" ]]; then
    printf '%s/claims\n' "$OVERSEE_WATCH_STATE_DIR"
  else
    printf '%s/tmp/oversee-watch/claims\n' "${1:-$PWD}"
  fi
}

# One spelling per account: config dirs are compared as strings, so a lane
# given as `~/.claude/`, through a symlink, or relative to somewhere else must
# reduce to what discovery reports or its claims count against nothing. A path
# that cannot be resolved keeps its own spelling, trailing slashes off.
lane_claims_canon() {
  local p="$1" previous="$PWD"
  LANE_CLAIMS_CANON="$p"
  if [[ -n "$p" ]] && cd -P -- "$p" 2>/dev/null; then
    LANE_CLAIMS_CANON="$PWD"
    cd -- "$previous" || return 1
  else
    while [[ "$LANE_CLAIMS_CANON" == */ && "$LANE_CLAIMS_CANON" != / ]]; do
      LANE_CLAIMS_CANON="${LANE_CLAIMS_CANON%/}"
    done
  fi
  [[ "${2:-}" == silent || -z "$LANE_CLAIMS_CANON" ]] || printf '%s\n' "$LANE_CLAIMS_CANON"
}

lane_claims_pane_live() { # LIVE SERVER PANE
  case $'\n'"$1"$'\n' in *$'\n'"$2 $3"$'\n'*) return 0 ;; esac
  return 1
}

# Prune dead claims, print the live ones as `<config dir>\t<window>\t<server
# pid>\t<pane id>` lines. Where $2 is `count`, each line ends in
# `\t<fleet>\t<named>` and the live
# reservations are among them, read in full before the claims are listed: a
# launch writes its claim or its record before it drops its reservation, so a
# reservation gone by the time it is read is a claim the later listing finds,
# or a record for a caller that reads its records after this.
# Mode `cap` adds the declared kind after named and
# includes reservations. Older claims carry no kind and count as fleet lanes.
# The four-field form is the default because lane-context appends its own
# fifth field. Mode `fleet` carries fleet and named without adding
# reservations, with pool after named; a context selector removes them before the caller flag is
# appended.
# $1: claims directory. Exits 2 when the store cannot be read at
# all: a caller deciding where to launch must fail closed on that, and only
# the caller knows whether it is deciding or reporting.
lane_claims_read() {
  local dir="$1" mode="${2:-}" live this_server f server pane cfg window fleet named host_kind pool rc=0
  local rechecked=0 recheck_ok=1 live_now fresh line rest kinds=claim kind
  # Absent is genuinely empty; anything else that is not a directory is a
  # misconfiguration, and an unreadable store is not an empty one. Reporting
  # no claims for either would report every busy account as free.
  if [[ ! -e "$dir" ]]; then
    return 0
  fi
  if [[ ! -d "$dir" ]]; then
    lane_claims_message not-directory "$@" >&2
    return 2
  fi
  if [[ ! -r "$dir" || ! -x "$dir" ]]; then
    lane_claims_message unreadable-directory "$@" >&2
    return 2
  fi
  live="$(tmux list-panes -a -F '#{pid} #{pane_id}' 2>/dev/null)" || live=""
  # The enumerated server's pid, empty when nothing could be enumerated.
  this_server="${live%%$'\n'*}"
  this_server="${this_server%% *}"
  [[ "$mode" != count && "$mode" != cap ]] || kinds="reserve claim"
  for kind in $kinds; do
    for f in "$dir"/*."$kind"; do
      [[ -f "$f" ]] || continue
      # Cleared every iteration: a failed read must never leave the previous
      # record's fields standing in for this one.
      server=""; pane=""; cfg=""; window=""; fleet=""; named=""; host_kind=""; pool=""
      if [[ ! -r "$f" ]]; then
        # A claim that cannot be read is a launch that cannot be seen: reported,
        # left in place, and carried out as a failure so a caller deciding where
        # to launch refuses rather than counting it as absent.
        lane_claims_message unreadable-claim "$@" >&2
        rc=2
        continue
      fi
      line=""
      IFS= read -r line < "$f" || true
      # Split by hand, never `IFS=$'\t' read`: a TAB is IFS whitespace, so read
      # folds a reservation's empty config dir and shifts every later field left.
      rest="$line"$'\t'
      server="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      pane="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      cfg="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      window="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      # The creation stamp is for a reader of the file, not for liveness.
      rest="${rest#*$'\t'}"
      fleet="${rest%%$'\t'*}"
      rest="${rest#*$'\t'}"
      named="${rest%%$'\t'*}"
      rest="${rest#*$'\t'}"
      host_kind="${rest%%$'\t'*}"
      rest="${rest#*$'\t'}"
      pool="${rest%%$'\t'*}"
      if [[ -z "$pane" ]] || [[ ! "$server" =~ ^[0-9]+$ ]]; then
        rm -f -- "$f"
        continue
      fi
      live_now=0
      if [[ "$f" == *.reserve ]]; then
        # A reservation is live while the launcher that wrote it runs.
        ! lane_claims_pid_runs "$server" || live_now=1
      elif lane_claims_pane_live "$live" "$server" "$pane"; then
        live_now=1
      elif [[ "$server" == "$this_server" ]]; then
        # The pane list predates this record: another launcher can create its
        # window and write its claim in between, and deleting that record would
        # hand a running account straight back out. One re-enumeration settles
        # every same-server miss in this pass.
        if [[ "$rechecked" -eq 0 ]]; then
          rechecked=1
          # A re-enumeration that FAILS says nothing: it neither replaces the
          # snapshot nor settles the record that provoked it.
          if fresh="$(tmux list-panes -a -F '#{pid} #{pane_id}' 2>/dev/null)"; then
            live="$fresh"
          else
            recheck_ok=0
          fi
        fi
        if [[ "$recheck_ok" -eq 0 ]]; then
          # Only a snapshot taken after this record was written can call it
          # dead, and none is available: unknown, and an unknown claim is kept.
          live_now=1
        elif lane_claims_pane_live "$live" "$server" "$pane"; then
          live_now=1
        fi
      elif lane_claims_pid_runs "$server"; then
        # A server this process cannot enumerate, still running.
        live_now=1
      fi
      if [[ "$live_now" -eq 0 ]]; then
        rm -f -- "$f"
        continue
      fi
      # Canonical on the way out, whatever spelling the record carries: the
      # count compares strings, and a hand-written or older record must still
      # land on the account discovery reports.
      lane_claims_canon "$cfg" silent || return 2
      if [[ "$mode" == count || "$mode" == fleet || "$mode" == cap ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s' "$LANE_CLAIMS_CANON" "$window" "$server" "$pane" "$fleet" "$named"
        [[ "$mode" != cap ]] || printf '\t%s' "$host_kind"
        [[ "$mode" != fleet ]] || printf '\t%s' "${pool:-plan}"
        printf '\n'
      else
        printf '%s\t%s\t%s\t%s\n' "$LANE_CLAIMS_CANON" "$window" "$server" "$pane"
      fi
    done
  done
  return "$rc"
}

# Whether process PID may still run. `kill -0` fails alike for a gone process
# (ESRCH) and another account's (EPERM), and its exit status is all the shell
# gives; `ps -p` answers existence whoever owns the process. A `ps` that cannot
# answer (exit above 1) leaves the process unknown, and an unknown server keeps
# its claim.
lane_claims_pid_runs() {
  local rc=0
  kill -0 "$1" 2>/dev/null && return 0
  ps -p "$1" >/dev/null 2>&1 || rc=$?
  [[ "$rc" -ne 1 ]]
}

# The one shell answer to which oversee lane records are lanes in flight, as
# jq definitions a caller prefixes to its own program (lib/launch-overlap.sh).
# Hand-appended entries that are not objects are no lane.
LANE_RUNNING_JQ='def running: type == "object" and .status == "running";
def held: running or (type == "object" and .status == "preparing");
def in_flight: held or (type == "object" and .status == "parked");'
