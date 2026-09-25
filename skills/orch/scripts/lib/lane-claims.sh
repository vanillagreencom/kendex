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
# until its server is provably gone. Claims are recorded for tmux lanes only —
# a launch with no pane handle would leave a claim nothing can prune.
#
# Record: `<server pid>\t<pane id>\t<config dir>\t<window>\t<created at>\t<fleet>`.
# The fleet is the oversee state file of the fleet the launch was judged in
# (`open-terminal --state-dir`), empty for a launch naming no fleet, and it is
# what lets one store serve several fleets: open-terminal's fleet cap counts
# only its own fleet's claims, while an account's claims count whatever fleet
# wrote them. A claim with an empty fleet, written by a launch naming no fleet
# or before claims carried one, counts toward its account and toward no fleet's
# cap, and it is the lane of a fleet's running or preparing record whose window
# and account it names, as that fleet's own claims are.
#
# A reservation is the same record under `.reserve`, with the launcher's pid as
# its server and `-` as its pane: the place in the count a judged launch holds
# from its count until its claim or record stands, or the item ends, live while
# that launcher runs. Its config dir is empty for a launch naming no lane. Only
# the count form of lane_claims_read carries reservations; every other reader
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
# pid>\t<pane id>` lines. Where $2 is `count`, the form open-terminal's caps
# count, each line ends in `\t<fleet>` and the live reservations are among
# them, read in full before the claims are listed: a launch writes its claim or
# its record before it drops its reservation, so a reservation gone by the
# time it is read is a claim the later listing finds, or a record for a caller
# that reads its records after this.
# The four-field form is the default because lane-context appends its own
# fifth field. $1: claims directory. Exits 2 when the store cannot be read at
# all: a caller deciding where to launch must fail closed on that, and only
# the caller knows whether it is deciding or reporting.
lane_claims_read() {
  local dir="$1" mode="${2:-}" live this_server f server pane cfg window fleet rc=0
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
  [[ "$mode" != count ]] || kinds="reserve claim"
  for kind in $kinds; do
    for f in "$dir"/*."$kind"; do
      [[ -f "$f" ]] || continue
      # Cleared every iteration: a failed read must never leave the previous
      # record's fields standing in for this one.
      server=""; pane=""; cfg=""; window=""; fleet=""
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
      if [[ -z "$pane" ]] || [[ ! "$server" =~ ^[0-9]+$ ]]; then
        rm -f -- "$f"
        continue
      fi
      live_now=0
      if [[ "$f" == *.reserve ]]; then
        # A reservation is live while the launcher that wrote it runs.
        ! kill -0 "$server" 2>/dev/null || live_now=1
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
      elif kill -0 "$server" 2>/dev/null; then
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
      if [[ "$mode" == count ]]; then
        printf '%s\t%s\t%s\t%s\t%s\n' "$(lane_claims_canon "$cfg")" "$window" "$server" "$pane" "$fleet"
      else
        printf '%s\t%s\t%s\t%s\n' "$(lane_claims_canon "$cfg")" "$window" "$server" "$pane"
      fi
    done
  done
  return "$rc"
}

# Live claims against one config dir. $1: `lane_claims_read` output, $2: dir.
lane_claims_count() {
  # Through the environment, never `awk -v`: that form expands backslash
  # escapes, and a config dir carrying a backslash would then match no record
  # and report a busy account as free.
  LANE_CLAIMS_DIR_Q="$(lane_claims_canon "$2")" \
    awk -F'\t' '$1 == ENVIRON["LANE_CLAIMS_DIR_Q"] { n++ } END { print n + 0 }' <<<"$1"
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
# $6: window, $7: fleet.
lane_claim_put() {
  local dir="$1" suffix="$2" cfg tmp
  cfg="$(lane_claims_canon "$5")"
  mkdir -p -- "$dir" || return 1
  tmp="$(mktemp -- "$dir/claim.XXXXXX")" || return 1
  # Named with its suffix only once complete: a reader must never see a
  # half-written record and prune a live lane over it.
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$3" "$4" "$cfg" "$6" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$7" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$tmp.$suffix" || { rm -f -- "$tmp"; return 1; }
  # shellcheck disable=SC2034  # read by open-terminal's cap_reserve
  LANE_CLAIM_PATH="$tmp.$suffix"
}

# Record one claim. $1: claims dir, $2: server pid, $3: pane id, $4: config
# dir, $5: window, $6: fleet, empty for none. A missing pane handle or config
# dir records nothing.
lane_claim_write() {
  [[ -n "$2" && -n "$3" && -n "$4" ]] || return 0
  lane_claim_put "$1" claim "$2" "$3" "$4" "$5" "${6:-}"
}

# Record one reservation, its path left in LANE_CLAIM_PATH. $1: claims dir,
# $2: the launcher's pid, $3: config dir, empty for none, $4: window, $5: fleet.
lane_claim_reserve() {
  lane_claim_put "$1" reserve "$2" - "$3" "$4" "$5"
}

# The one answer to which oversee lane records are lanes in flight, as jq
# definitions a caller prefixes to its own program: oversee-watch carries the
# running records, and open-terminal counts the held ones against both caps,
# those plus the preparing records of hosted lanes handed to a background job,
# whose window and host are taken before the lane runs. The watch and the cap
# cannot describe two different fleets. Hand-appended entries that are not
# objects are no lane.
LANE_RUNNING_JQ='def running: type == "object" and .status == "running";
def held: running or (type == "object" and .status == "preparing");'
