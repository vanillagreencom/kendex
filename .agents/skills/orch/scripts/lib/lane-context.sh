#!/usr/bin/env bash
# Context use per live work lane, read from the lane's own pane status line
# and nothing else. A harness session file is a private format whose fields
# are ambiguous to anyone but the harness; the status line is the number the
# harness itself stands behind, on the screen the operator is looking at.
#
# Two shapes, two directions:
#   Claude prints `Opus 5 41%`       — the percentage USED.
#   Codex  prints `Context 86% left` — the percentage REMAINING, or
#                 `Context 14% used` when its status item is configured the
#                 other way round. Both spellings ship in one binary.
# The shape that matched decides the direction, so nothing has to record
# which harness a pane runs. Both are reported as CONTEXT_USED_PCT: one
# direction, and a rising number always means a fuller context.
#
# Only the BOTTOM of the screen is read, and the last match there wins. The
# status line sits at the bottom; a model name beside a percentage anywhere
# above it is prose or scrollback, and this fleet's panes carry both.
#
# A lane is live while its claim's pane is (lib/lane-claims.sh). A pane that
# cannot be captured — on another tmux server, or gone between the claim read
# and here — is reported `unreadable` with no number: an unmeasured lane must
# never read as an empty one.
set -euo pipefail

# One record. $1 window, $2 pane id, $3 config dir, $4 account label,
# $5 harness, $6 used percent, $7 status, $8 detail. Empty numeric or label
# fields become null, never 0 or "".
lane_context_emit() {
  jq -nc \
    --arg lane "$1" --arg pane "$2" --arg cfg "$3" --arg account "$4" \
    --arg harness "$5" --arg used "$6" --arg status "$7" --arg detail "$8" '
    {
      lane: (if $lane == "" then null else $lane end),
      pane: $pane,
      account: (if $account == "" then null else $account end),
      config_dir: (if $cfg == "" then null else $cfg end),
      harness: (if $harness == "" then null else $harness end),
      context_used_pct: (if $used == "" then null else ($used | tonumber) end),
      status: $status,
      detail: (if $detail == "" then null else $detail end)
    }'
}

# Read one context figure from a captured screen on stdin. Prints
# `<harness>\t<used percent>`; exits 1 when the screen carries neither shape.
#
# Blank lines are dropped and only the last few survivors are matched: the
# status line is the bottom of the screen, so anything with later output
# below it is scrollback — a pane that exited to its shell, one showing a
# pager, a transcript line about a lane's own context use. Read as current,
# any of them reports a number the lane left behind.
#
# Matching is done on a lowercased copy of each line: a model name is a word,
# and the harness spells it differently in different places. The codex shape
# is tested first and consumes its line, so a screen carrying both never
# takes the claude direction for a codex reading. Codex's status item is
# user-configured and both directions ship, so both are matched and only
# `left` is converted. A percentage over 100 is not a context figure and is
# dropped rather than reported, whichever shape carried it.
lane_context_parse() {
  local out
  out="$(awk '/[^ \t]/' | tail -n 5 | awk '
    {
      low = tolower($0)
      if (match(low, /context:?[ \t]+[0-9]+%[ \t]+(left|used)/)) {
        s = substr(low, RSTART, RLENGTH)
        remaining = (s ~ /left$/)
        gsub(/[^0-9]/, "", s)
        if (s + 0 <= 100) { harness = "codex"; used = remaining ? 100 - (s + 0) : s + 0 }
        next
      }
      if (match(low, /(opus|sonnet|haiku|fable)[^%]*[0-9]+%/)) {
        s = substr(low, RSTART, RLENGTH)
        sub(/%$/, "", s)
        sub(/^.*[^0-9]/, "", s)
        if (s != "" && s + 0 <= 100) { harness = "claude"; used = s + 0 }
      }
    }
    END { if (harness != "") printf "%s\t%d\n", harness, used }
  ')"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# One record per live lane claim, as a JSON array. $1: `lane_claims_read`
# output, $2: the name of a function mapping a config dir to its account
# label.
#
# `capture-pane -t %N` resolves a pane id against the CURRENT client's server
# and no other, while pane ids restart at %0 on every server — which is why a
# claim's liveness key is `<server pid> <pane id>` (lib/lane-claims.sh), and
# why claims from other servers survive that read. A pane id alone is not
# that key: a foreign claim whose number also exists here would be measured
# against an unrelated local pane and emitted as ok. So the claim's server is
# compared against this one, enumerated once, before anything is captured.
lane_context_collect() {
  local claims="$1" alias_fn="$2" cfg lane server pane screen parsed
  local this_server detail
  this_server="$(tmux list-panes -a -F '#{pid} #{pane_id}' 2>/dev/null | head -n 1)"
  this_server="${this_server%% *}"
  {
    while IFS=$'\t' read -r cfg lane server pane; do
      [[ -n "$pane" ]] || continue
      if [[ "$server" != "$this_server" ]]; then
        # Empty means nothing could be enumerated at all: no pane id here
        # resolves, and reporting the local screen for any of them would be
        # the same fabrication.
        detail="the pane belongs to another tmux server; its pane id names nothing here"
        [[ -n "$this_server" ]] || detail="no tmux server could be enumerated; no pane id resolves"
        lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" "" "" \
          "unreadable" "$detail"
        continue
      fi
      if ! screen="$(tmux capture-pane -pJ -t "$pane" 2>/dev/null)"; then
        lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" "" "" \
          "unreadable" "the pane could not be captured; it is gone from this server"
        continue
      fi
      if ! parsed="$(lane_context_parse <<<"$screen")"; then
        lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" "" "" \
          "no_status_line" "the screen carries neither harness's context figure"
        continue
      fi
      lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" \
        "${parsed%%$'\t'*}" "${parsed##*$'\t'}" "ok" ""
    done <<<"$claims"
  } | jq -s '.'
}

# Table for the records on stdin. The legend is part of the output, not a
# nicety: a bare percentage column is read in whichever direction the reader
# last saw one, and the two harnesses print opposite directions.
lane_context_render() {
  local recs
  recs="$(cat)"
  if [[ "$(jq -r 'length' <<<"$recs")" == "0" ]]; then
    printf 'No live lane claims — nothing to measure.\n'
    return 0
  fi
  jq -r '
    (["LANE","PANE","ACCOUNT","HARNESS","CONTEXT_USED_PCT","STATUS"] | @tsv),
    (.[] | [ (.lane // "-"), .pane, (.account // "-"), (.harness // "-"),
             (if .context_used_pct == null then "-" else (.context_used_pct | tostring) + "%" end),
             .status ] | @tsv)
  ' <<<"$recs" | column -t -s "$(printf '\t')"
  printf 'CONTEXT_USED_PCT: percent of the context window CONSUMED. A Codex lane prints what is LEFT; it is converted here.\n'
}
