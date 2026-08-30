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
# WHERE the status line sits is not a line count. Claude draws ONE ROW PER
# RUNNING AGENT below it, so the footer grows with the fleet — and the
# deepest footers belong to the orchestrating lanes, the ones this
# measurement exists for. The whole captured screen is read and the
# BOTTOM-MOST reading wins: anything above it is an earlier render of the
# same lane, from before it compacted. Bottom-most is safe only because a
# reading is a whole STATUS LINE and never a fragment prose can carry too:
# otherwise the lowest sentence naming a model and a percentage beats the
# real status line above it.
#
# A screen that outlived its harness is refused rather than measured, and
# that refusal takes positive evidence, never distance: the pane's
# foreground process must BE a harness this reader knows. A pane that has
# outlived its harness would otherwise have its last render reported as
# current forever.
#
# A lane is live while its claim's pane is (lib/lane-claims.sh). A pane that
# cannot be captured — on another tmux server, or gone between the claim read
# and here — is reported `unreadable` with no number: an unmeasured lane must
# never read as an empty one.
set -euo pipefail

# The foreground processes that ARE a harness, matched whole. A denylist of
# shells cannot establish that one is running: after a harness exits, a pane
# running less, vim or git log still holds the old footer and passes any
# not-a-shell test. `[a-z0-9]*claude` covers the per-account wrappers this
# fleet launches through — nclaude, dclaude, 1claude — which exec the real
# binary, and agent-confine is the launcher they exec through. Anything else
# is refused BY NAME, so a harness missing from this list reads as a named
# refusal in the report rather than as a lane that stopped being measured.
LANE_CONTEXT_HARNESSES='[a-z0-9]*claude|codex|pi|agent-confine'

# Shells choose the refusal's wording and nothing else: a pane back at its
# shell ended its session, which says more than the process name does.
LANE_CONTEXT_SHELLS='sh|bash|zsh|fish|dash|ksh|mksh|tcsh|csh|nu|xonsh|elvish'

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
# Every line is offered and the LAST match wins. No window is taken off the
# bottom: the footer under the status line is one row per running agent and
# has no bound, so any count would lose exactly the busiest lanes.
#
# Matching is done on a lowercased copy of each line: a model name is a word,
# and the harness spells it differently in different places. The claude
# reading is a WHOLE LINE, never a fragment of one: the status line runs
# `<cwd> [(<branch>)] <model> <version> [(<window>)] <N>% (<account>)`, so a
# match starts at the line's own beginning with a working directory and runs
# to the line's own END. BOTH ends, because either alone leaves the fragment
# in: prose carries it before — `Opus 5 92% is already heavily used` — and
# after — `/fake Opus 5 99% (work) is an example`, whose status-shaped PREFIX
# matched while the sentence it sits in did not have to. Under a bottom-most
# rule either sentence outranks the real status line above it. What the
# account may be followed by is claude's own right-hand hint, a slash
# command (`/rc`) — never running text. The branch parenthetical is optional:
# a lane outside a repository has none, and a session that has not rendered a
# percentage yet matches nothing at all.
# The codex reading is a WHOLE LINE at both ends for the same reason: the
# context item OPENS its line — leading whitespace or box decoration only,
# nothing alphanumeric — and what may follow it is another status item behind
# a separator, never running text. `Documentation: Context 60% used means
# compact now` fails the opening; `Context 60% used means compact now` fails
# the end; and `Context 60% used · and that is an example` fails it too,
# because a trailing item is capped at three tokens — the longest status item
# this reader has seen (`Opus 5 41%`) — where a sentence is longer. Each is a
# fragment a bottom-most rule would otherwise let take the verdict from the
# real line above it.
# The codex shape is tested first and consumes its line, so a screen carrying
# both never takes the claude direction for a codex reading. Codex's status
# item is user-configured and both directions ship, so both are matched and
# only `left` is converted. A percentage over 100 is not a context figure and
# is dropped rather than reported, whichever shape carried it.
lane_context_parse() {
  local out
  out="$(awk '
    {
      low = tolower($0)
      if (match(low, /^[^a-z0-9]*context:?[ \t]+[0-9]+%[ \t]+(left|used)([ \t]+(·|[|])[ \t]+[^ \t]+([ \t]+[^ \t]+){0,2})?[ \t]*$/)) {
        s = substr(low, RSTART, RLENGTH)
        match(s, /[0-9]+%[ \t]+(left|used)/)
        s = substr(s, RSTART, RLENGTH)
        remaining = (s ~ /left$/)
        gsub(/[^0-9]/, "", s)
        if (s + 0 <= 100) { harness = "codex"; used = remaining ? 100 - (s + 0) : s + 0 }
        next
      }
      if (match(low, /^[ \t]*[^ \t()]+([ \t]+\([^)]*\))?[ \t]+(opus|sonnet|haiku|fable)[ \t]+[0-9]+(\.[0-9]+)?([ \t]*\([^)]*\))?[ \t]+[0-9]+%[ \t]+\([^) \t]+\)([ \t]+\/[^ \t]*)*[ \t]*$/)) {
        s = substr(low, RSTART, RLENGTH)
        match(s, /[0-9]+%[ \t]+\([^) \t]+\)/)
        s = substr(s, RSTART, RLENGTH)
        sub(/%.*$/, "", s)
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
# The same enumeration carries each pane's foreground process, which is what
# says whether a harness is still drawing the screen about to be read.
lane_context_collect() {
  local claims="$1" alias_fn="$2" cfg lane server pane screen parsed
  local this_server detail cmd pane_cmds p_pid p_pane p_cmd
  # `<pane id> <command>` per line, not an associative array: macOS Bash 3.2
  # has none and rejects an associative-array declaration, which under this
  # file's errexit would abort the whole report rather than lose one lane.
  pane_cmds=""
  this_server=""
  while read -r p_pid p_pane p_cmd; do
    [[ -n "$p_pane" ]] || continue
    [[ -n "$this_server" ]] || this_server="$p_pid"
    pane_cmds+="$p_pane $p_cmd"$'\n'
  done < <(tmux list-panes -a -F '#{pid} #{pane_id} #{pane_current_command}' 2>/dev/null)
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
      # tmux names a login shell with the dash it was started with.
      cmd="$(awk -v p="$pane" '$1 == p { print $2; exit }' <<<"$pane_cmds")"
      cmd="${cmd#-}"
      # An empty name means the pane is on no list this server printed, so it
      # is gone: the capture below is what says so, and says it as unreadable.
      if [[ -n "$cmd" && ! "$cmd" =~ ^($LANE_CONTEXT_HARNESSES)$ ]]; then
        detail="the pane is running $cmd, not a harness this reader measures; any reading left on its screen is what the lane ended with"
        [[ ! "$cmd" =~ ^($LANE_CONTEXT_SHELLS)$ ]] || detail="the pane has exited to its shell; any reading left on its screen is what the lane ended with"
        lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" "" "" \
          "no_status_line" "$detail"
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

# Align the tab-separated table on stdin; both lane tables render through
# here. `column` is util-linux, not one of orch's declared dependencies (jq,
# bash 3.2, flock), and installations that satisfy those ship without it —
# where the pipeline fails and every row is lost, which on the compaction
# rule reads as a fleet with no lanes rather than as a table that could not
# be drawn. The rows matter more than their spacing, so the columns are
# padded here when it is absent. awk stands in because POSIX mandates it and
# this file already parses every screen with it.
lane_context_columns() {
  if command -v column >/dev/null 2>&1; then
    column -t -s "$(printf '\t')"
    return 0
  fi
  awk -F'\t' '
    { rows[NR] = $0; if (NF > cols) cols = NF
      for (i = 1; i <= NF; i++) if (length($i) > w[i]) w[i] = length($i) }
    END {
      for (r = 1; r <= NR; r++) {
        n = split(rows[r], f, "\t"); line = ""
        for (i = 1; i <= n; i++)
          line = line (i < cols ? sprintf("%-" (w[i] + 2) "s", f[i]) : f[i])
        sub(/[ \t]+$/, "", line)
        print line
      }
    }'
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
  ' <<<"$recs" | lane_context_columns
  printf 'CONTEXT_USED_PCT: percent of the context window CONSUMED. A Codex lane prints what is LEFT or what is USED; only LEFT is converted here.\n'
}
