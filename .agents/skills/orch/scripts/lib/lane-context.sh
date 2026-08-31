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
# WHERE the status line sits differs by harness, and that is what decides
# how each one is found.
#
# Codex draws its status line LAST. In every captured pane it is the final
# non-empty row, with blank rows and nothing else below it, so the codex
# reading is taken from that row and from no other row on the screen. A
# final row that is not a status line is no reading at all, never a search
# up the transcript for something shaped like one. POSITION carries that
# refusal because shape cannot: codex's status items are user-configured
# (`[tui].status_line` — model with reasoning, git branch, project name,
# codex version, tokens used, working directory), and `gpt-5.6-sol default`
# is a configured item while `compact now` is a sentence about compaction,
# and the two are the same shape. A reader that refuses what it does not
# recognise leaves the lane unmeasured, and an unmeasured lane is never
# compacted — which is the outcome compaction exists to prevent. So what
# follows the separator is taken as it comes.
#
# Claude draws ONE ROW PER RUNNING AGENT below its status line, so the
# footer grows with the fleet — and the deepest footers belong to the
# orchestrating lanes, the ones this measurement exists for. Its status line
# is never the final row, so the claude reading is the BOTTOM-MOST whole-line
# match instead: anything above it is an earlier render of the same lane,
# from before it compacted. Bottom-most is safe only because a reading is a
# whole STATUS LINE and never a fragment prose can carry too: otherwise the
# lowest sentence naming a model and a percentage beats the real status line
# above it.
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
# binary, and agent-confine is the launcher both harnesses exec through, so
# it names neither. Anything else is refused BY NAME, so a harness missing
# from this list reads as a named refusal in the report rather than as a lane
# that stopped being measured.
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

# The shape a pane's foreground process ($1) offers, decided here and in no
# other place: `codex` the codex shape alone, a claude wrapper spelling the
# claude shape alone, and anything else `both`, because a reader with no rule
# for a harness has nothing better than the shapes themselves — `pi`, an empty
# name for a pane that has left the enumeration, and `agent-confine`, which is
# the launcher BOTH harnesses exec through and so names neither. Reading the
# screen and refusing it both select on this answer, so a wrapper spelling
# added to one list and not the other cannot read one harness's screen and
# name the other's in its refusal.
lane_context_shape() {
  case "${1:-}" in
    codex) printf 'codex\n' ;;
    *claude) printf 'claude\n' ;;
    *) printf 'both\n' ;;
  esac
}

# Read one context figure from a captured screen on stdin. $1 is the pane's
# foreground process, which `lane_context_shape` turns into the shape offered.
# Prints `<harness>\t<used percent>`; exits 1 when the shape offered found
# nothing.
#
# The codex shape is offered the FINAL NON-EMPTY line and no other. The
# claude shape is offered every line and its LAST match wins; no window is
# taken off the bottom, because the footer under a claude status line is one
# row per running agent and has no bound, so any count would lose exactly the
# busiest lanes. Where both are offered, a final line carrying the codex shape
# settles the reading, out of range included: falling through to a claude
# match higher up would be the search the position rule exists to refuse. On a
# codex pane there is no falling through at all — the claude shape is never
# offered, so a screen that does not end in a codex status line is
# could-not-tell however much of this fleet's transcript sits above it.
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
# The codex reading is a WHOLE LINE at its OPENING and takes what follows as
# it comes. The context item opens the line — leading whitespace or box
# decoration only, nothing alphanumeric — so `Documentation: Context 60% used
# means compact now` is not one, and `Context 60% used means compact now`
# needs the separator its configured items are drawn behind. Past that
# separator the line is read no further. Every candidate for the job — a path
# (`/var/tmp/…`), a model with its reasoning effort (`gpt-5.6-sol default`), a
# git branch, a project name, a version, a token count — is one to three bare
# words, and so is a sentence's opening; a shape that admits the ones this
# reader has seen and refuses the rest refuses configured status lines it has
# not seen, and leaves those lanes unmeasured. Position is what keeps prose
# out, so the shape does not have to try.
# Codex's status item is user-configured and both directions ship, so both
# are matched and only `left` is converted. A percentage over 100 is not a
# context figure and is dropped rather than reported, whichever shape carried
# it.
lane_context_parse() {
  local out shape
  shape="$(lane_context_shape "${1:-}")"
  out="$(awk -v shape="$shape" '
    {
      if ($0 ~ /[^ \t]/) last = $0
      if (shape == "codex") next
      low = tolower($0)
      if (match(low, /^[ \t]*[^ \t()]+([ \t]+\([^)]*\))?[ \t]+(opus|sonnet|haiku|fable)[ \t]+[0-9]+(\.[0-9]+)?([ \t]*\([^)]*\))?[ \t]+[0-9]+%[ \t]+\([^) \t]+\)([ \t]+\/[^ \t]*)*[ \t]*$/)) {
        s = substr(low, RSTART, RLENGTH)
        match(s, /[0-9]+%[ \t]+\([^) \t]+\)/)
        s = substr(s, RSTART, RLENGTH)
        sub(/%.*$/, "", s)
        if (s != "" && s + 0 <= 100) { c_found = 1; c_used = s + 0 }
      }
    }
    END {
      low = (shape == "claude") ? "" : tolower(last)
      if (match(low, /^[^a-z0-9]*context:?[ \t]+[0-9]+%[ \t]+(left|used)([ \t]+(·|[|])[ \t]+[^ \t].*)?[ \t]*$/)) {
        codex_line = 1
        s = substr(low, RSTART, RLENGTH)
        match(s, /[0-9]+%[ \t]+(left|used)/)
        s = substr(s, RSTART, RLENGTH)
        remaining = (s ~ /left$/)
        gsub(/[^0-9]/, "", s)
        if (s + 0 <= 100) { harness = "codex"; used = remaining ? 100 - (s + 0) : s + 0 }
      }
      if (!codex_line && c_found) { harness = "claude"; used = c_used }
      if (harness != "") printf "%s\t%d\n", harness, used
    }
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
# says whether a harness is still drawing the screen about to be read — and
# WHICH harness, which is how the reader knows the shape to look for without
# guessing it from a screen that quotes both all day.
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
      if ! parsed="$(lane_context_parse "$cmd" <<<"$screen")"; then
        case "$(lane_context_shape "$cmd")" in
          codex) detail="the screen does not end in a valid codex context figure; the last non-empty row is the only row a codex reading is taken from" ;;
          claude) detail="the screen carries no claude status line" ;;
          *) detail="the screen carries neither harness's context figure" ;;
        esac
        lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" "" "" \
          "no_status_line" "$detail"
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
