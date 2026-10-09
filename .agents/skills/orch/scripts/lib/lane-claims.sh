#!/usr/bin/env bash
# Live launch claims per auth lane: one file per lane window launched under a
# resolved lane, so `lanes pick` sees the launches already in flight on an
# account instead of only its usage numbers, which lag a launch by minutes.
#
# Home: $OVERSEE_WATCH_STATE_DIR/claims, else <project root>/tmp/oversee-watch/
# claims — the directory oversee-watch keeps its own state in.
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
# <fleet>\t<named>\t<kind>`.
# The config dir is canonical; `named` is the spelling the launch named the lane
# by, before canonicalisation, so a reader can name the account as `lanes list`
# does from a discovered path. A record written before it carried one has none,
# and a reader names that claim's account from its canonical config dir.
# The fleet is the oversee state file of the fleet the launch was judged in
# (`open-terminal --state-dir`), empty for a launch naming no fleet, and it is
# what lets one store serve several fleets: open-terminal's fleet cap counts
# only its own fleet's claims, while `lanes pick` charges an account with
# whatever fleet's claims name it. A claim with an empty fleet, written by a
# launch naming no fleet or before claims carried one, counts toward its
# account and toward no fleet's cap; a fleet's report (lane_claims_for_fleet)
# takes it as the lane of that fleet's running or preparing record whose window
# and account it names.
#
# A reservation is the same record under `.reserve`, with the launcher's pid as
# its server and `-` as its pane: the place in the count a judged launch holds
# from its count until its claim or record stands, or the item ends, live while
# that launcher runs. Its config dir is empty: only the count form of
# lane_claims_read carries reservations, and the fleet cap that reads it judges
# a reservation by its window and fleet, never its account. Every other reader
# reads claims alone.
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
  local p="$1"
  [[ -n "$p" ]] || return 0
  ( cd -- "$p" 2>/dev/null && pwd -P ) && return 0
  while [[ "$p" == */ && "$p" != "/" ]]; do p="${p%/}"; done
  printf '%s\n' "$p"
}

# Prune dead claims, print the live ones as `<config dir>\t<window>\t<server
# pid>\t<pane id>` lines. Where $2 is `count`, each line ends in
# `\t<fleet>\t<named>` and the live
# reservations are among them, read in full before the claims are listed: a
# launch writes its claim or its record before it drops its reservation, so a
# reservation gone by the time it is read is a claim the later listing finds,
# or a record for a caller that reads its records after this.
# Mode `cap`, read by open-terminal, adds the declared kind after named and
# includes reservations. Older claims carry no kind and count as fleet lanes.
# The four-field form is the default because lane-context appends its own
# fifth field. Mode `fleet` carries fleet and named without adding
# reservations; a context selector removes them before the caller flag is
# appended.
# $1: claims directory. Exits 2 when the store cannot be read at
# all: a caller deciding where to launch must fail closed on that, and only
# the caller knows whether it is deciding or reporting.
lane_claims_read() {
  local dir="$1" mode="${2:-}" live this_server f server pane cfg window fleet named host_kind rc=0
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
      server=""; pane=""; cfg=""; window=""; fleet=""; named=""; host_kind=""
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
      if [[ -z "$pane" ]] || [[ ! "$server" =~ ^[0-9]+$ ]]; then
        rm -f -- "$f"
        continue
      fi
      live_now=0
      if [[ "$f" == *.reserve ]]; then
        # A reservation is live while the launcher that wrote it runs.
        ! lane_claims_pid_runs "$server" || live_now=1
      elif grep -qxF -- "$server $pane" <<<"$live"; then
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
        elif grep -qxF -- "$server $pane" <<<"$live"; then
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
      if [[ "$mode" == count || "$mode" == fleet || "$mode" == cap ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s' "$(lane_claims_canon "$cfg")" "$window" "$server" "$pane" "$fleet" "$named"
        [[ "$mode" != cap ]] || printf '\t%s' "$host_kind"
        printf '\n'
      else
        printf '%s\t%s\t%s\t%s\n' "$(lane_claims_canon "$cfg")" "$window" "$server" "$pane"
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

# Select context claims from the fleet-field form, emitting the normal four
# fields. Explicit fleet identity owns even an in-flight claim with no record;
# an empty identity needs a held record's window and canonical account.
# Reservations never enter: the caller reads mode `fleet`, not mode `count`.
lane_claims_for_fleet() { # CLAIMS FLEET LANES_JSON
  local rows account window owned=""
  [[ -n "$2" ]] || return 0
  rows=$(jq -r "$LANE_RUNNING_JQ"'
    .[] | select(held) | [(.account // ""), (.window // "" | sub("^[^:]*:"; ""))]
    | join("\u001f")' <<<"$3") || return 1
  while IFS=$'\037' read -r account window; do
    [[ -n "$window" ]] || continue
    account=$(lane_claims_canon "$account") || return 1
    owned+="$window"$'\t'"$account"$'\n'
  done <<<"$rows"
  CLAIM_OWNED="$owned" CLAIM_FLEET="$2" awk -F'\t' '
    BEGIN {
      OFS = "\t"
      n = split(ENVIRON["CLAIM_OWNED"], rows, "\n")
      for (i = 1; i <= n; i++) if (rows[i] != "") owned[rows[i]] = 1
    }
    NF && ($5 == ENVIRON["CLAIM_FLEET"] || ($5 == "" && (($2 "\t" $1) in owned))) {
      print $1, $2, $3, $4
    }' <<<"$1"
}

# Config dir claimed for one pane, empty when no live claim names it. The key
# is `<server pid> <pane id>` — the same key liveness uses — because a window
# NAME is unique to a session, not to a server or across servers, so two lanes
# can carry one name and the wrong account would answer for a pane.
# $1: `lane_claims_read` output, $2: server pid, $3: pane id.
lane_claims_config_dir() {
  [[ -n "${2:-}" && -n "${3:-}" ]] || return 0
  awk -F'\t' -v s="$2" -v p="$3" '$3 == s && $4 == p { print $1; exit }' <<<"$1"
}

# Writes one record under SUFFIX, its path left in LANE_CLAIM_PATH.
# $1: claims dir, $2: suffix, $3: server pid, $4: pane id, $5: config dir,
# $6: window, $7: fleet, $8: declared kind. Old callers omit kind and remain
# fleet lanes. The config dir is recorded canonical and as named.
lane_claim_put() {
  local dir="$1" suffix="$2" cfg tmp
  cfg="$(lane_claims_canon "$5")"
  mkdir -p -- "$dir" || return 1
  tmp="$(mktemp -- "$dir/claim.XXXXXX")" || return 1
  # Named with its suffix only once complete: a reader must never see a
  # half-written record and prune a live lane over it.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$3" "$4" "$cfg" "$6" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$7" "$5" "${8:-}" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  # mktemp creates mode 600, which no default ACL widens: a store shared by
  # several homes would refuse every other home's read as unreadable-claim.
  # `--` before the mode: BSD chmod applies a mode followed by `--`, then
  # exits 1 taking `--` for a file.
  chmod -- g+r "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$tmp.$suffix" || { rm -f -- "$tmp"; return 1; }
  # shellcheck disable=SC2034  # read by lib/lane-cap.sh's cap_reserve
  LANE_CLAIM_PATH="$tmp.$suffix"
}

# Record one claim. $1: claims dir, $2: server pid, $3: pane id, $4: config
# dir, $5: window, $6: fleet, empty for none, $7: declared kind. A missing pane handle or config
# dir records nothing.
lane_claim_write() {
  [[ -n "$2" && -n "$3" && -n "$4" ]] || return 0
  lane_claim_put "$1" claim "$2" "$3" "$4" "$5" "${6:-}" "${7:-}"
}

# Record one reservation, its path left in LANE_CLAIM_PATH, with an empty
# config dir. $1: claims dir, $2: the launcher's pid, $3: window, $4: fleet,
# $5: declared kind. open-terminal supplies it before the record exists, so
# concurrent cloud sessions reserve cloud slots rather than fleet slots.
lane_claim_reserve() {
  lane_claim_put "$1" reserve "$2" - "" "$3" "$4" "${5:-}"
}

# The one answer to which oversee lane records are lanes in flight, as jq
# definitions a caller prefixes to its own program: oversee-watch carries the
# running records. open-terminal counts the in_flight
# records against its fleet cap, so a resume never adds a lane. The watch and
# the cap cannot describe two different fleets. Hand-appended entries that are
# not objects are no lane.
LANE_RUNNING_JQ='def running: type == "object" and .status == "running";
def held: running or (type == "object" and .status == "preparing");
def in_flight: held or (type == "object" and .status == "parked");'

# lane_running_record LANES WINDOW HARNESS — the first running record of a
# HARNESS lane whose window part is WINDOW's, compact on stdout, nothing where
# none is: the one lookup of a lane's record by the window a reader holds, for
# `lanes state` and oversee-watch. LANES is the fleet state's `lanes` array, or
# the state object holding it, and empty is no fleet. Non-zero where LANES is
# not JSON.
lane_running_record() { # LANES WINDOW HARNESS
  jq -c --arg w "${2#*:}" --arg h "$3" "$LANE_RUNNING_JQ"'
    (if type == "object" then .lanes // [] else . end)
    | map(select(running and .harness == $h and ((.window // "") | sub("^.*:"; "")) == $w)) | first // empty' \
    <<<"$1" 2>/dev/null
}
