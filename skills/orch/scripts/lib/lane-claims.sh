#!/usr/bin/env bash
# Live launch claims per auth lane: one file per lane window launched under a
# resolved lane, so `lanes pick` sees the launches already in flight on an
# account instead of only its usage numbers, which lag a launch by minutes.
#
# Home: $OVERSEE_WATCH_STATE_DIR/claims, else <project root>/tmp/oversee-watch/
# claims — the directory oversee-watch keeps its own state in.
#
# A claim is live while its tmux pane is. The liveness key is
# `<server pid> <pane id>`: pane ids restart at %0 on a new tmux server, so the
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
# Record: `<server pid>\t<pane id>\t<config dir>\t<window>\t<created at>`.
set -euo pipefail

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

# Prune dead claims, print the live ones as `<config dir>\t<window>` lines.
# $1: claims directory.
lane_claims_read() {
  local dir="$1" live this_server f server pane cfg window created
  [[ -d "$dir" ]] || return 0
  # An unreadable store is not an empty one: reporting no claims here would
  # report every busy account as free.
  if [[ ! -r "$dir" || ! -x "$dir" ]]; then
    echo "lane-claims: claims directory $dir is not readable; launches already in flight are invisible" >&2
    return 0
  fi
  live="$(tmux list-panes -a -F '#{pid} #{pane_id}' 2>/dev/null)" || live=""
  # The enumerated server's pid, empty when nothing could be enumerated.
  this_server="${live%%$'\n'*}"
  this_server="${this_server%% *}"
  for f in "$dir"/*.claim; do
    [[ -f "$f" ]] || continue
    # Cleared every iteration: a failed read must never leave the previous
    # record's fields standing in for this one.
    server=""; pane=""; cfg=""; window=""; created=""
    if [[ ! -r "$f" ]]; then
      echo "lane-claims: cannot read claim $f; leaving it in place" >&2
      continue
    fi
    IFS=$'\t' read -r server pane cfg window created < "$f" || true
    if [[ -z "$pane" ]] || [[ ! "$server" =~ ^[0-9]+$ ]]; then
      rm -f -- "$f"
      continue
    fi
    if ! grep -qxF -- "$server $pane" <<<"$live"; then
      # Absent from its own server's pane list, or on a server that is gone.
      if [[ "$server" == "$this_server" ]] || ! kill -0 "$server" 2>/dev/null; then
        rm -f -- "$f"
        continue
      fi
    fi
    # Canonical on the way out, whatever spelling the record carries: the
    # count compares strings, and a hand-written or older record must still
    # land on the account discovery reports.
    printf '%s\t%s\n' "$(lane_claims_canon "$cfg")" "$window"
  done
}

# Live claims against one config dir. $1: `lane_claims_read` output, $2: dir.
lane_claims_count() {
  awk -F'\t' -v d="$(lane_claims_canon "$2")" '$1 == d { n++ } END { print n + 0 }' <<<"$1"
}

# Config dir claimed by a tmux window, empty when no live claim names it.
# $1: `lane_claims_read` output, $2: window name.
lane_claims_config_dir() {
  awk -F'\t' -v w="$2" '$2 == w { print $1; exit }' <<<"$1"
}

# Record one claim. $1: claims dir, $2: server pid, $3: pane id, $4: config
# dir, $5: window. A missing pane handle or config dir records nothing.
lane_claim_write() {
  local dir="$1" server="$2" pane="$3" cfg="$4" window="$5" tmp
  [[ -n "$server" && -n "$pane" && -n "$cfg" ]] || return 0
  cfg="$(lane_claims_canon "$cfg")"
  mkdir -p -- "$dir" || return 1
  tmp="$(mktemp -- "$dir/claim.XXXXXX")" || return 1
  # Named .claim only once complete: a reader must never see a half-written
  # record and prune a live lane over it.
  printf '%s\t%s\t%s\t%s\t%s\n' "$server" "$pane" "$cfg" "$window" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$tmp.claim" || { rm -f -- "$tmp"; return 1; }
}
