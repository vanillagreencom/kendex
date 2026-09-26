#!/usr/bin/env bash
# Context use per session, read from the records the harness itself writes and
# never from a pane. A session's turn-end hook reads its own transcript through
# the adapter for its harness (lib/adapters/), which answers the tokens the last
# response left in the context and the window the model has, and records that
# reading in the session's mailbox directory. Every other reader, `lanes
# context`, `oversee-succeed` and the watch through it, reads that record, so a
# hosted lane reads the same as a local one and a scrolled or quiet pane changes
# nothing.
#
# One judge: lane_context_handoff_due enforces the absolute token cap and the
# remaining-capacity mark. ORCH_HANDOFF_CONTEXT_PCT can request an earlier
# handoff. No reader carries its own arithmetic. Missing capacity is unmeasured
# below the absolute cap, never judged against a guess.
set -euo pipefail

# A launch home reaches this library in CODEX_HOME, and only lane-home.sh says
# which account such a path belongs to. Sourced here rather than left to the
# caller: the turn-end hook that asks the account question loads this file
# alone. The sibling is named by expansion and not by `dirname` and `pwd`,
# because this library is also loaded under a PATH holding jq, awk and cat and
# nothing else, where an external would leave it half loaded.
# shellcheck source=lane-home.sh
source "${BASH_SOURCE[0]%/*}/lane-home.sh"
# The adapters, one per harness a transcript is read for, named the same way.
# shellcheck source=adapters/claude.sh
source "${BASH_SOURCE[0]%/*}/adapters/claude.sh"
# shellcheck source=adapters/codex.sh
source "${BASH_SOURCE[0]%/*}/adapters/codex.sh"
# shellcheck source=adapters/pi.sh
source "${BASH_SOURCE[0]%/*}/adapters/pi.sh"

# The word an adapter prints for a usage object whose field names it does not
# read, kept apart from a reading and from the empty answer a transcript with
# no usage line gives: a reader reports this one rather than summing it to zero.
LANE_CONTEXT_UNREAD=unread

# The file a session's reading is recorded in, inside its mailbox directory:
# `tmp/lane-mail/<item>/` for a lane and `tmp/lane-mail/overseer/` for the
# overseer. A hosted lane's mailbox is already read through its host, so the
# record reaches the overseer by the same road.
LANE_CONTEXT_RECORD=context.json
# The orch scripts directory this library sits under, where git-context is.
LANE_CONTEXT_SCRIPTS="${BASH_SOURCE[0]%/*}/.."

# lane_context_overseer_box DIR — the overseer mailbox directory for the
# checkout DIR is in: `tmp/lane-mail/overseer` at its main checkout, where
# lane-mail keeps the overseer mailbox, or at DIR itself where git-context
# names no main checkout. Every writer and reader of the overseer's reading
# asks here.
lane_context_overseer_box() { # DIR
  local root
  root=$("$LANE_CONTEXT_SCRIPTS/git-context" common-root "$1" 2>/dev/null) || root="$1"
  printf '%s/tmp/lane-mail/overseer\n' "${root:-$1}"
}

# One report row. $1 lane, $2 pane id, $3 config dir, $4 account label, $5
# status, $6 detail, $7 the tmux server the pane id belongs to, $8 non-empty on
# the READER'S OWN row, $9 the judged reading's JSON, empty where there is none.
# Empty fields become null, never 0 or "".
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
    --arg status "$5" --arg detail "$6" --arg server "${7:-}" --arg caller "${8:-}" \
    --arg reading "${9:-}" '
    def nul: if . == "" then null else . end;
    (if $reading == "" then {} else ($reading | fromjson) end) as $r
    | {
        lane: ($lane | nul),
        pane: $pane,
        server: ($server | nul),
        caller: ($caller != ""),
        account: ($account | nul),
        config_dir: ($cfg | nul),
        harness: ($r.harness // null),
        model: ($r.model // null),
        context_used_pct: ($r.used_pct // null),
        context_tokens: ($r.tokens // null),
        context_window: ($r.window // null),
        context_at: ($r.at // null),
        context_handoff_due: (if $r | has("handoff_due") then $r.handoff_due else null end),
        status: $status,
        detail: ($detail | nul)
      }'
}

# The shape a pane's foreground process ($1) offers, decided here and in no
# other place: `codex` the codex shape alone, a claude wrapper spelling the
# claude shape alone, and anything else `both`, because a reader with no rule
# for a harness has nothing better than the shapes themselves — `pi`, an empty
# name for a pane that has left the enumeration, and `agent-confine`, which is
# the launcher BOTH harnesses exec through and so names neither. The account a
# session spends and the harness its succession launches both select on this
# answer, so a wrapper spelling is read the same way by both.
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
#
# What CODEX_HOME holds is not always an account. A codex launch that had to
# make its own folder-trust record runs under a private home built under one,
# so lib/lane-home.sh turns such a path back into the account it was built
# under. Without that the mail a turn-end hook hands off, and the lane it has
# `lanes pick` judge, name a directory no claim was taken on, and a second
# session is launched onto an account this one is already spending. Both arms
# that can answer with that variable go through the rule: the codex shape, and
# the shape naming no harness, which is what a pane running `lanes` itself
# offers. A claude answer passes through it unchanged, carrying no such shape.
lane_context_caller_cfg() { # SHAPE
  local home="${LANES_HOME:-$HOME}"
  case "${1:-}" in
    claude) printf '%s\n' "${CLAUDE_CONFIG_DIR:-$home/.claude}" ;;
    codex) lane_launch_home_account "${CODEX_HOME:-$home/.codex}" ;;
    *)
      [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -n "${CODEX_HOME:-}" ] ||
        lane_launch_home_account "${CLAUDE_CONFIG_DIR:-${CODEX_HOME:-}}"
      ;;
  esac
}

# lane_context_mark_model HARNESS MODEL — the model a session of HARNESS
# launched on MODEL is judged on by its own account mark, which reads the model
# its recorded reading names. A claude session's account mark is judged on
# MODEL's own buckets; a codex session's is judged on the account's binding
# bucket, the reading the fleet has always taken of one, and this answers empty.
#
# It exists so a caller CHOOSING an account for a session it is about to
# launch holds that account to the reading the session will take of itself. A
# choice made on a narrower reading than the session's own picks an account
# the session then judges as spent, hands over again, and pays a window swap
# and a handoff every cycle.
lane_context_mark_model() { # HARNESS MODEL
  case "${1:-}" in
    claude) printf '%s\n' "${2:-}" ;;
    *) printf '\n' ;;
  esac
}

# lane_context_reading HARNESS [WINDOW] — one reading of the transcript on
# stdin, through HARNESS's adapter: `<tokens>\t<window>\t<model>`, the word
# LANE_CONTEXT_UNREAD for a usage object the adapter does not read, or nothing
# for a transcript holding no usage yet. WINDOW is a window the harness named
# outside its transcript, which only Pi's turn-end payload does. Exit 3 names a
# harness no adapter reads; any other failure is the adapter's own.
lane_context_reading() { # HARNESS [WINDOW]
  case "${1:-}" in
    claude) lane_adapter_claude_reading "$LANE_CONTEXT_UNREAD" ;;
    codex) lane_adapter_codex_reading "$LANE_CONTEXT_UNREAD" ;;
    pi) lane_adapter_pi_reading "$LANE_CONTEXT_UNREAD" "${2:-}" ;;
    *) return 3 ;;
  esac
}

# Normalize the requested handoff percentage for the judge and its reports.
# A larger setting cannot weaken the mandatory remaining-capacity mark.
lane_context_handoff_pct() { # PCT
  case "${1:-}" in '' | *[!0-9]* | 0*) return 2 ;; esac
  [ "$1" -le 100 ] || return 2
  if [ "$1" -gt 90 ]; then printf '90\n'; else printf '%s\n' "$1"; fi
}

# lane_context_handoff_due TOKENS WINDOW PCT — the one judgement of a context
# reading: `due` at 400000 used tokens or strictly past PCT percent of WINDOW,
# with PCT capped at 90. WINDOW is the effective capacity before compaction,
# or the actual window when compaction is disabled. Exit 1 below the token cap
# where WINDOW is empty or 0, which is unmeasured and never room. Exit 2 where
# PCT is not a whole number from 1
# to 100, or a figure is not a whole number or carries a leading zero a shell
# would read as octal. Every reader of a reading asks here, so a lane, the
# overseer and the report cannot judge one reading two ways.
lane_context_handoff_due() { # TOKENS WINDOW PCT
  local pct
  pct=$(lane_context_handoff_pct "${3:-}") || return 2
  case "${1:-}" in '' | *[!0-9]*) return 2 ;; 0) ;; 0*) return 2 ;; esac
  if [ "$1" -ge 400000 ]; then
    printf 'due\n'
    return 0
  fi
  case "${2:-}" in '' | 0) return 1 ;; *[!0-9]* | 0*) return 2 ;; esac
  if [ $(($1 * 100)) -gt $(($2 * pct)) ]; then
    printf 'due\n'
  else
    printf 'room\n'
  fi
}

# lane_context_record BOX HARNESS TOKENS WINDOW MODEL [SESSION] [PANE_KEY] —
# write a session's reading to BOX/$LANE_CONTEXT_RECORD, through a file renamed
# over it so no reader meets half a record. `used_pct` is the whole percent of
# the window used, null with the window. SESSION is the id the harness names
# the session by and PANE_KEY the `<server pid> <pane id>` it runs in, which is
# how a successor overseer's reader tells its own record from the one its
# predecessor left in the same mailbox. Exit non-zero where the record could not
# be written, the cause on stderr.
lane_context_record() { # BOX HARNESS TOKENS WINDOW MODEL [SESSION] [PANE_KEY]
  local box="${1:?}" staged at
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
  staged="$box/.$LANE_CONTEXT_RECORD.$$"
  if ! jq -nc --arg harness "$2" --argjson tokens "$3" --arg window "$4" --arg model "$5" \
    --arg session "${6:-}" --arg pane_key "${7:-}" --arg at "$at" '
    def nul: if . == "" then null else . end;
    ($window | nul | if . == null then null else tonumber end) as $w
    | {harness: $harness, model: ($model | nul), tokens: $tokens, window: $w,
       used_pct: (if $w == null or $w == 0 then null else ($tokens * 100 / $w | floor) end),
       session_id: ($session | nul), pane_key: ($pane_key | nul), at: $at}' >"$staged"; then
    rm -f -- "${staged:?}"
    return 1
  fi
  mv -f -- "$staged" "$box/$LANE_CONTEXT_RECORD" || { rm -f -- "${staged:?}"; return 1; }
}

# lane_context_record_fields RECORD — one recorded reading split into
# LANE_CTX_HARNESS, LANE_CTX_TOKENS, LANE_CTX_WINDOW, LANE_CTX_MODEL,
# LANE_CTX_PANE_KEY and LANE_CTX_AT, each empty where the record holds none.
# Exit 1, every field empty, where RECORD is not a record lane_context_record
# wrote: an object carrying a token count.
lane_context_record_fields() { # RECORD
  local fields rest
  LANE_CTX_HARNESS="" LANE_CTX_TOKENS="" LANE_CTX_WINDOW=""
  LANE_CTX_MODEL="" LANE_CTX_PANE_KEY="" LANE_CTX_AT=""
  fields=$(jq -er 'select(type == "object" and (.tokens | type) == "number")
    | [(.harness // ""), (.tokens | tostring), (.window // "" | tostring),
       (.model // ""), (.pane_key // ""), (.at // "")] | join("\t")' <<<"${1:-}" 2>/dev/null) || return 1
  # Split by hand for the reason lane_context_collect gives: an empty field
  # would otherwise collapse into its neighbour.
  rest="$fields"
  LANE_CTX_HARNESS="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_TOKENS="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_WINDOW="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_MODEL="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_PANE_KEY="${rest%%$'\t'*}"
  LANE_CTX_AT="${rest#*$'\t'}"
}

# lane_context_record_judged RECORD PCT — RECORD with `handoff_due` set from
# lane_context_handoff_due: true, false, or null where capacity is unknown
# below the independent token limit.
# Exit 1 where RECORD is not a record lane_context_record wrote, 2 where PCT is
# out of range; nothing is printed then.
lane_context_record_judged() { # RECORD PCT
  local verdict rc=0 due
  lane_context_record_fields "${1:-}" || return 1
  verdict=$(lane_context_handoff_due "$LANE_CTX_TOKENS" "$LANE_CTX_WINDOW" "${2:-}") || rc=$?
  case "$rc" in
    0)
      due=false
      [ "$verdict" != due ] || due=true
      ;;
    1) due=null ;;
    *) return 2 ;;
  esac
  jq -c --argjson due "$due" '.handoff_due = $due' <<<"$1"
}

# The key a live session's own row is matched on, `<tmux server pid> <pane id>`
# on one line; 1 where the caller sits on no pane this reader can ask about.
#
# Pane ids restart at %0 on every tmux server, so the PAIR is the key and the id
# alone is not. Every consumer that compares one session's key against another
# session's record reads it here: the report below matches its claims on it,
# `oversee-watch` records the overseer's by it, and the turn-end hook compares
# its own against that record, so the three cannot spell one session
# differently.
lane_context_caller_key() {
  local pane="${TMUX_PANE:-}" server
  [ -n "$pane" ] || return 1
  server="$(tmux display-message -p -t "$pane" '#{pid}' 2>/dev/null)" || return 1
  [ -n "$server" ] || return 1
  printf '%s %s\n' "$server" "$pane"
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
  local claims="$1" cfg="$2" key pane server name marked
  if ! key="$(lane_context_caller_key)"; then
    printf '%s\n' "$claims"
    return 0
  fi
  server="${key%% *}"
  pane="${key#* }"
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

# One report row per live lane claim, as a JSON array. $1: `lane_claims_read`
# output with lane_context_with_caller's flag, $2: the name of a function
# mapping a config dir to its account label, $3: the name of a function given a
# row's lane and caller flag that prints that session's recorded reading and
# exits 0, exits 1 where none is recorded, and exits 2 with the cause on stdout
# where the record could not be read. $4: the percentage every row is judged at.
#
# No pane is read. A session that has not ended a turn since its launch has no
# reading, and its row is `unrecorded`, never an empty context; a reading whose
# window its adapter could not name is `window-unread`, never `ok`.
lane_context_collect() {
  local claims="$1" alias_fn="$2" fetch_fn="$3" pct="$4" cfg lane server pane caller claim rest
  local out rc judged
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
      rc=0
      out="$("$fetch_fn" "$lane" "$caller")" || rc=$?
      case "$rc" in
        0) ;;
        1)
          lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" \
            unrecorded "no turn end of this session has recorded a reading" "$server" "$caller"
          continue
          ;;
        *)
          lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" \
            unreadable "$out" "$server" "$caller"
          continue
          ;;
      esac
      rc=0
      judged="$(lane_context_record_judged "$out" "$pct")" || rc=$?
      case "$rc" in
        0)
          # Below the token limit, unknown capacity is neither due nor room.
          # The row reports that gap instead of an ok row with a blank handoff.
          if [[ "$(jq -r '.handoff_due' <<<"$judged")" == null ]]; then
            lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" window-unread \
              "the harness adapter named no context window for this session's model" "$server" "$caller" "$judged"
          else
            lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" ok "" "$server" "$caller" "$judged"
          fi
          ;;
        1)
          lane_context_emit "$lane" "$pane" "$cfg" "$("$alias_fn" "$cfg")" \
            unreadable "the recorded reading is not an object carrying a token count" "$server" "$caller"
          ;;
        *) return 2 ;;
      esac
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
      printf 'CONTEXT_USED_PCT: percent of effective capacity CONSUMED at the recorded turn end; a dash where capacity is unknown.\n'
      printf 'lane-context: tokens kind=recorded absent=-\n'
      printf 'CONTEXT_TOKENS: the tokens the last response left in the context, read from the transcript by the harness adapter at the session'"'"'s last turn end; a dash where no reading is recorded.\n'
      printf 'lane-context: headroom kind=account-binding handoff=threshold\n'
      printf 'HEADROOM: percent remaining in the account binding bucket; HANDOFF is required at or below ORCH_HANDOFF_HEADROOM_PCT.\n'
      printf 'lane-context: handoff kind=lane-threshold context=ORCH_HANDOFF_CONTEXT_PCT overseer-trigger=ORCH_OVERSEER_HEADROOM_PCT\n'
      printf 'HANDOFF: required by the shared context rule, or at the LANE headroom threshold. It never reports the overseer'"'"'s own ORCH_OVERSEER_HEADROOM_PCT, wall or qualifying-accounts triggers: by default the overseer succeeds itself at 5 percent headroom against the lane'"'"'s 3, so its own row can read - at a headroom that already fires its succession.\n'
      printf 'lane-context: caller kind=lane-marker marker=*\n'
      printf 'LANE: a leading * marks the row of the session that ran this command.\n'
      ;;
  esac
}

# Table for the records on stdin. The legend is part of the output, not a
# nicety: a bare percentage column is read in whichever direction the reader
# last saw one.
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
