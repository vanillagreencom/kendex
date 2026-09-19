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
# codex version, tokens used, working directory), and `gpt-6-astra default`
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
# match instead: anything above it is a prior render of the same lane,
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

# The window a Claude model runs on, for a status line that names none. A
# fleet status-line command that divides by the window and prints the
# percentage alone names none on EVERY line, so this table is not a
# default-window fallback: it is the window itself, wherever the line is
# silent. Claude's own built-in line names one, and a named window wins.
#
# An entry is the window the model ACTUALLY runs, established by measuring
# the largest prompt the model has been sent on this fleet, and a model whose
# window that does not establish is LEFT OUT. Absent yields no window, which
# the report prints as a dash and the overseer reads as unmeasured — the
# honest answer. A wrong figure is worse than none in both directions: too
# small hides a nearly full lane behind a confident low number and it rides
# into compaction, too large launches a successor an overseer with room does
# not need.
#
# The key is the TIER WORD the status line prints, so Opus 5 and Opus 4.8
# share one entry.
LANE_CONTEXT_DEFAULT_WINDOWS='fable=1000000 opus=1000000'

# One record. $1 window, $2 pane id, $3 config dir, $4 account label,
# $5 harness, $6 used percent, $7 status, $8 detail, $9 context tokens,
# ${10} the tmux server the pane id belongs to, ${11} non-empty on the
# READER'S OWN row. Empty numeric or label fields become null, never 0 or "".
#
# `caller` is the answer to "which row is this session", and
# lane_context_with_caller is the one place that decides it: it already holds
# the reader's server and pane and matches the claims on that pair, so a
# consumer reads the flag instead of rebuilding the key. Pane ids restart at %0
# on every tmux server, so a consumer keying on the pane id alone can be handed
# another server's lane; `server` stays on the record for the table and for
# readers asking a different question.
lane_context_emit() {
  jq -nc \
    --arg lane "$1" --arg pane "$2" --arg cfg "$3" --arg account "$4" \
    --arg harness "$5" --arg used "$6" --arg status "$7" --arg detail "$8" \
    --arg tokens "${9:-}" --arg server "${10:-}" --arg caller "${11:-}" '
    {
      lane: (if $lane == "" then null else $lane end),
      pane: $pane,
      server: (if $server == "" then null else $server end),
      caller: ($caller != ""),
      account: (if $account == "" then null else $account end),
      config_dir: (if $cfg == "" then null else $cfg end),
      harness: (if $harness == "" then null else $harness end),
      context_used_pct: (if $used == "" then null else ($used | tonumber) end),
      context_tokens: (if $tokens == "" then null else ($tokens | tonumber) end),
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
# included to one list and not the other cannot read one harness's screen and
# name the other's in its refusal.
lane_context_shape() {
  case "${1:-}" in
    codex) printf 'codex\n' ;;
    *claude) printf 'claude\n' ;;
    *) printf 'both\n' ;;
  esac
}

# The config directory a session of shape $1 runs its credential out of,
# decided here and in no other place: `lanes context` asks it about the pane it
# is reading, and the lane's own turn-end hook asks it about itself, so one
# session is never joined to one account by the report and to another by the
# hook that hands it off.
#
# Which variable names the account is decided by the SHAPE, never by which
# variable happens to be set: every launcher here prefixes one without clearing
# the other, so both can be, and reading Claude's on a Codex session reports a
# whole other account's headroom. A session started by hand sets neither, which
# is the overseer, and takes the directory its harness itself defaults to. A
# shape naming neither harness has only the variables to go on and takes one
# only where exactly one is set, so no session is joined to an account that was
# never established; empty is the honest answer, and its caller reports an
# account it could not name rather than reading it as room.
lane_context_caller_cfg() { # SHAPE
  local home="${LANES_HOME:-$HOME}"
  case "${1:-}" in
    claude) printf '%s\n' "${CLAUDE_CONFIG_DIR:-$home/.claude}" ;;
    codex) printf '%s\n' "${CODEX_HOME:-$home/.codex}" ;;
    *)
      [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -n "${CODEX_HOME:-}" ] ||
        printf '%s\n' "${CLAUDE_CONFIG_DIR:-${CODEX_HOME:-}}"
      ;;
  esac
}

# Read one context figure from a captured screen on stdin. $1 is the pane's
# foreground process, which `lane_context_shape` turns into the shape offered.
# Prints `<harness>\t<used percent>\t<context tokens>\t<window tokens>\t<window
# source>`; exits 1 when the shape offered found nothing. The window is the
# token count the status line itself names — Claude's `(1M context)`
# parenthetical between the version and the percentage, source `status-line` —
# and the token figure is the percentage times that window. A claude line
# naming no window — every line a status-line command that prints the
# percentage alone draws — takes the window the model named on that same line
# runs, from LANE_CONTEXT_DEFAULT_WINDOWS, source
# `model-default`. All three are empty where neither answers: the codex status
# line never names a window, and a claude line naming none for a model the
# table leaves out is unmeasured rather than guessed at. The overseer's
# handoff mark is an absolute token count, so a lane with no figure never
# reaches it — and the source is what says which reading a refusal rests on.
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
# (`/var/tmp/…`), a model with its reasoning effort (`gpt-6-astra default`), a
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
  out="$(awk -v shape="$shape" -v defaults="$LANE_CONTEXT_DEFAULT_WINDOWS" '
    BEGIN {
      n = split(defaults, pairs, / /)
      for (i = 1; i <= n; i++) { split(pairs[i], kv, "="); default_window[kv[1]] = kv[2] }
    }
    {
      if ($0 ~ /[^ \t]/) last = $0
      if (shape == "codex") next
      low = tolower($0)
      if (match(low, /^[ \t]*[^ \t()]+([ \t]+\([^)]*\))?[ \t]+(opus|sonnet|haiku|fable)[ \t]+[0-9]+(\.[0-9]+)?([ \t]*\([^)]*\))?[ \t]+[0-9]+%[ \t]+\([^) \t]+\)([ \t]+\/[^ \t]*)*[ \t]*$/)) {
        line = substr(low, RSTART, RLENGTH)
        # The window parenthetical is the one naming a token count, so the
        # branch parenthetical before the model never matches it, and a
        # window the line DOES name always wins over the table. With none,
        # the MODEL answers — matched where the status line puts it, before
        # its version, so a working directory or branch spelling a model name
        # cannot stand in for it.
        window = ""; source = ""
        if (match(line, /\([0-9]+(\.[0-9]+)?[km][ \t]+context\)/)) {
          w = substr(line, RSTART + 1, RLENGTH - 2)
          unit = (w ~ /m/) ? 1000000 : 1000
          sub(/[km].*$/, "", w)
          window = w * unit
          source = "status-line"
        } else if (match(line, /[ \t](opus|sonnet|haiku|fable)[ \t]+[0-9]/)) {
          model = substr(line, RSTART + 1, RLENGTH - 1)
          sub(/[ \t].*$/, "", model)
          if (default_window[model] != "") { window = default_window[model]; source = "model-default" }
        }
        match(line, /[0-9]+%[ \t]+\([^) \t]+\)/)
        s = substr(line, RSTART, RLENGTH)
        sub(/%.*$/, "", s)
        if (s != "" && s + 0 <= 100) { c_found = 1; c_used = s + 0; c_window = window; c_source = source }
      }
    }
    END {
      window = ""; source = ""
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
      if (!codex_line && c_found) { harness = "claude"; used = c_used; window = c_window; source = c_source }
      if (harness == "") exit
      if (window == "") printf "%s\t%d\t\t\t\n", harness, used
      else printf "%s\t%d\t%d\t%d\t%s\n", harness, used, int(used * window / 100), window, source
    }
  ')"
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# The claims in $1 plus the CALLER's OWN pane, unless a claim already names it.
# An overseer is started by hand into a window nothing claimed a lane for, so
# its own context — the figure its succession turns on — reaches no report
# built from claims alone, and that session reads as an empty fleet. $1:
# `lane_claims_read` output. $2: the caller's config dir, canonicalised by the
# caller, which owns that spelling.
#
# The pane is matched on `<server pid> <pane id>`, the same key a claim's
# liveness rests on: a pane id alone repeats on every tmux server, and a
# duplicate row would report one session as two lanes. The row that match
# lands on, appended or already present, carries the `caller` flag out, so
# this is the only place that decides which row is the reader's own session.
lane_context_with_caller() {
  local claims="$1" cfg="$2" pane="${TMUX_PANE:-}" server name marked
  if [[ -z "$pane" ]] || ! server="$(tmux display-message -p -t "$pane" '#{pid}' 2>/dev/null)" \
    || [[ -z "$server" ]]
  then
    printf '%s\n' "$claims"
    return 0
  fi
  # A claim already naming this pair IS the caller's row, so the flag goes on
  # the record that is already there rather than on a duplicate beside it.
  if marked="$(awk -F'\t' -v OFS='\t' -v s="$server" -v p="$pane" '
    $3 == s && $4 == p { $5 = "caller"; f = 1 } { print } END { exit !f }' <<<"$claims")"
  then
    printf '%s\n' "$marked"
    return 0
  fi
  name="$(tmux display-message -p -t "$pane" '#{window_name}' 2>/dev/null)" || name=""
  printf '%s\n' "$claims"$'\n'"$cfg"$'\t'"$name"$'\t'"$server"$'\t'"$pane"$'\t'caller
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
  local claims="$1" alias_fn="$2" cfg lane server pane caller screen parsed claim rest
  local this_server detail cmd pane_cmds p_pid p_pane p_cmd harness used tokens
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
    # Split by hand, never `IFS=$'\t' read`: a TAB is IFS whitespace, so read
    # drops a LEADING one and every field of a row whose config dir is empty
    # shifts left. A caller pane whose account cannot be established is such a
    # row, and it would be reported under the pane id of another lane.
    while IFS= read -r claim; do
      cfg="${claim%%$'\t'*}"; rest="${claim#*$'\t'}"
      lane="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      server="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
      pane="${rest%%$'\t'*}"
      # The caller flag is the optional fifth field lane_context_with_caller
      # writes; a claim the store holds carries four and no flag.
      caller=""
      [[ "$rest" != *$'\t'* ]] || caller="${rest#*$'\t'}"
      [[ -n "$pane" && "$claim" == *$'\t'*$'\t'*$'\t'* ]] || continue
      if [[ "$server" != "$this_server" ]]; then
        # Empty means nothing could be enumerated at all: no pane id here
        # resolves, and reporting the local screen for any of them would be
        # the same fabrication.
        detail="the pane belongs to another tmux server; its pane id names nothing here"
        [[ -n "$this_server" ]] || detail="no tmux server could be enumerated; no pane id resolves"
        lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" "" "" \
          "unreadable" "$detail" "" "$server" "$caller"
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
          "no_status_line" "$detail" "" "$server" "$caller"
        continue
      fi
      if ! screen="$(tmux capture-pane -pJ -t "$pane" 2>/dev/null)"; then
        lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" "" "" \
          "unreadable" "the pane could not be captured; it is gone from this server" "" "$server" "$caller"
        continue
      fi
      if ! parsed="$(lane_context_parse "$cmd" <<<"$screen")"; then
        case "$(lane_context_shape "$cmd")" in
          codex) detail="the screen does not end in a valid codex context figure; the last non-empty row is the only row a codex reading is taken from" ;;
          claude) detail="the screen carries no claude status line" ;;
          *) detail="the screen carries neither harness's context figure" ;;
        esac
        lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" "" "" \
          "no_status_line" "$detail" "" "$server" "$caller"
        continue
      fi
      IFS=$'\t' read -r harness used tokens _ <<<"$parsed"
      lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" \
        "$harness" "$used" "ok" "" "$tokens" "$server" "$caller"
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

lane_context_message() {
  case "$1" in
    empty)
      printf 'lane-context: empty count=0\nNo live lane claims to measure.\n'
      ;;
    legend)
      printf 'lane-context: percent kind=consumed\n'
      printf 'CONTEXT_USED_PCT: percent of the context window CONSUMED. A Codex lane prints what is LEFT or what is USED; only LEFT is converted here.\n'
      printf 'lane-context: tokens kind=window-percent absent=-\n'
      printf 'CONTEXT_TOKENS: that percent of the window the status line names, as Claude does with (1M context), or of the model default where it names none; a dash where neither answers.\n'
      printf 'lane-context: headroom kind=account-binding handoff=threshold\n'
      printf 'HEADROOM: percent remaining in the account binding bucket; HANDOFF is required at or below ORCH_HANDOFF_HEADROOM_PCT.\n'
      printf 'lane-context: handoff kind=lane-threshold overseer-trigger=ORCH_OVERSEER_HEADROOM_PCT\n'
      printf 'HANDOFF: the LANE threshold and no other. An overseer succeeds itself at ORCH_OVERSEER_HEADROOM_PCT, the higher figure by default (20 against 5), so by default its own row reads - at a headroom that already fires its succession.\n'
      printf 'lane-context: caller kind=lane-marker marker=*\n'
      printf 'LANE: a leading * marks the row of the session that ran this command.\n'
      ;;
  esac
}

# Table for the records on stdin. The legend is part of the output, not a
# nicety: a bare percentage column is read in whichever direction the reader
# last saw one, and the two harnesses print opposite directions.
#
# The caller's own row carries a leading `*` on its lane name. An overseer is
# told its own pane is in this report, and without a mark it has no way to
# find the row — its HANDOFF cell speaks for the lane threshold, which by
# default is the lower figure, so that cell reads `-` at a headroom already
# past the overseer's own succession trigger. Nothing orders the two
# settings, so the legend states the comparison as the default it is.
lane_context_render() {
  local recs
  recs="$(cat)"
  if [[ "$(jq -r 'length' <<<"$recs")" == "0" ]]; then
    lane_context_message empty
    return 0
  fi
  jq -r '
    (["LANE","PANE","ACCOUNT","HARNESS","CONTEXT_USED_PCT","CONTEXT_TOKENS","HEADROOM","HANDOFF","STATUS"] | @tsv),
    (.[] | [ ((if .caller then "*" else "" end) + (.lane // "-")), .pane, (.account // "-"), (.harness // "-"),
             (if .context_used_pct == null then "-" else (.context_used_pct | tostring) + "%" end),
             (if .context_tokens == null then "-" else (.context_tokens | tostring) end),
             (if .headroom_pct == null then "-" else (.headroom_pct | tostring) + "%" end),
             (if .handoff_required then "required" else "-" end),
             .status ] | @tsv)
  ' <<<"$recs" | lane_context_columns
  lane_context_message legend
}
