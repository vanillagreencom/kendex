#!/usr/bin/env bash
# Context use per session, read from the records the harness itself writes and
# never from a pane. A session's turn-end hook reads its own transcript through
# the adapter for its harness (lib/adapters/), which answers the tokens the last
# response left in the context and its verified compaction point, and records that
# reading in the session's mailbox directory. Every other reader, `lanes
# context`, `oversee-succeed` and the watch through it, reads that record, so a
# hosted lane reads the same as a local one and a scrolled or quiet pane changes
# nothing.
#
# One judge: lane_context_handoff_due enforces the absolute token cap and the
# remaining-capacity mark. ORCH_HANDOFF_CONTEXT_PCT can request an earlier
# handoff. lane_context_window_full is the one judge of a reading that fills
# its window. No reader carries its own arithmetic. Missing capacity is
# unmeasured below the absolute cap, never judged against a guess.
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
# shellcheck source=adapters/copilot.sh
source "${BASH_SOURCE[0]%/*}/adapters/copilot.sh"

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
# The agent-runtime executable beside this package, the session-file lookup's
# owner; a suite names its own through AGENT_RUNTIME_CLI.
LANE_CONTEXT_AGENT_RUNTIME="${AGENT_RUNTIME_CLI:-$LANE_CONTEXT_SCRIPTS/../../agent-runtime/scripts/agent-runtime}"

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

# lane_context_pane_shape CMD PANE_PID — lane_context_shape for a pane whose
# foreground process is CMD and whose own process is PANE_PID, into
# LANE_PANE_SHAPE, naming a Copilot CLI pane too. That pane reads `node`, its
# npm loader, or `copilot`, the binary started directly, so its harness is a
# process carrying one of Copilot's own names (lib/lane-state.sh §
# lane_harness_process_re) at most two levels under the pane: its shell, the
# loader, the binary. A Codex pane also reads `node`, and a Copilot run it
# starts sits deeper, under its own tool shell, so it is not this pane's
# harness. The process reads are lib/lane-state.sh's, which the caller sources.
#
# LANE_PANE_ACCOUNT is a Copilot pane's account, read off the nearest such
# process, whose environment is the session's own wherever the reader runs:
# the COPILOT_HOME it was started with, else its HOME's `.copilot`, the root
# Copilot itself defaults to. It is empty for any other pane, and where that
# environment cannot be read, as on a host without /proc, so the caller names
# no account it did not read. Status 2 is a process table that could not be
# read.
#
# This read stands in for the session's own sessionStart row
# (hooks/session-start-row.sh through lib/session-rows.sh session_rows_write),
# the one documented source of its account, since Copilot reports a running
# session's account to nothing outside it. That row cannot answer here: a
# session started before the hook install, or with no overseer mailbox
# directory, writes none, and lib/overseer-launch.sh ol_caller_known keeps
# only a row naming claude or codex.
LANE_PANE_SHAPE="" LANE_PANE_ACCOUNT=""
lane_context_pane_shape() { # CMD PANE_PID
  local table name_re found pid var copilot_home="" home=""
  LANE_PANE_SHAPE="" LANE_PANE_ACCOUNT=""
  case "$1" in
    node | copilot)
      table="$(lane_process_table)" || return 2
      name_re="$(lane_harness_process_re copilot)" || return 2
      found="$(lane_process_below "$table" "$2" "$name_re" 1 2 pids)" || return 2
      if [[ -n "$found" ]]; then
        LANE_PANE_SHAPE=copilot
        pid="$(awk 'NR == 1 || $1 < hops { hops = $1; pid = $2 } END { print pid }' <<<"$found")" || return 2
        # A process gone since the table was read has no environment left to
        # read, the same answer as a host with none.
        while IFS= read -r -d '' var; do
          case "$var" in
            COPILOT_HOME=*) copilot_home="${var#*=}" ;;
            HOME=*) home="${var#*=}" ;;
          esac
        done 2>/dev/null <"/proc/$pid/environ" || :
        [[ -n "$copilot_home" || -z "$home" ]] || copilot_home="$home/.copilot"
        LANE_PANE_ACCOUNT="$copilot_home"
        return 0
      fi
      ;;
  esac
  LANE_PANE_SHAPE="$(lane_context_shape "$1")"
}

# The config directory a session of shape $1 runs its credential out of: a
# lane's, and an overseer's where its launch record names none. The lane's own
# turn-end hook asks it for the account its headroom is judged on
# (hooks/lane-mail-check.sh); it records no account. A recorded overseer's
# account is its launch record's (lib/overseer-launch.sh § ol_record_current),
# which `oversee-succeed` judges it on; the hook reads this function alone, so
# it judges that overseer's headroom on another account where the session's
# environment disagrees with its record.
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
# `pi` is no shape a pane offers: it is the Copilot pool's account harness a
# pi overseer names (lib/overseer-launch.sh § ol_account), whose account is the
# Pi root it runs on, PI_CODING_AGENT_DIR or the home's `.pi/agent`.
#
# Copilot's variable is COPILOT_HOME, the whole config root, and a Copilot
# launch builds no private home under it, so the value is the account. The
# shape naming no harness does not read it: a session that shape describes is
# claude or codex or neither.
lane_context_caller_cfg() { # SHAPE
  local home="${LANES_HOME:-$HOME}"
  case "${1:-}" in
    claude) printf '%s\n' "${CLAUDE_CONFIG_DIR:-$home/.claude}" ;;
    codex) lane_launch_home_account "$(lane_context_caller_home codex)" ;;
    pi) lane_adapter_pi_agent_dir ;;
    copilot) printf '%s\n' "${COPILOT_HOME:-$home/.copilot}" ;;
    *)
      [ -n "${CLAUDE_CONFIG_DIR:-}" ] && [ -n "${CODEX_HOME:-}" ] ||
        lane_launch_home_account "${CLAUDE_CONFIG_DIR:-${CODEX_HOME:-}}"
      ;;
  esac
}

# lane_context_caller_home HARNESS — the launch home a session of HARNESS runs
# from, read off this process's own environment: the directory the harness
# variable carries, or the harness's own default where none is set. For claude
# and copilot that is the account itself (lane_context_caller_cfg); for codex
# it is CODEX_HOME as it stands, a private home built under an account
# included, since that home is where its rollouts are written. The home a
# transcript is bound to (lane_context_transcript_owned) is this one, so the
# turn-end hook fills a fleet record naming no home from it
# (lib/overseer-launch.sh § ol_record_heal). Exit 1, printing nothing, for a
# harness with no transcript shape.
lane_context_caller_home() { # HARNESS
  case "${1:-}" in
    claude | copilot) lane_context_caller_cfg "$1" ;;
    codex) printf '%s\n' "${CODEX_HOME:-${LANES_HOME:-$HOME}/.codex}" ;;
    *) return 1 ;;
  esac
}

# lane_context_mark_model HARNESS MODEL — the model a session of HARNESS
# launched on MODEL is judged on by its own account mark, which reads the model
# its recorded reading names. A claude session's account mark is judged on
# MODEL's own buckets; a codex session's is judged on the account's binding
# bucket, the reading the fleet has always taken of one, and this answers empty.
# A pi session's is MODEL as pi spells it, `provider/id`, which
# lib/overseer-launch.sh § ol_account turns into the account and model `lanes`
# judges.
#
# It exists so a caller CHOOSING an account for a session it is about to
# launch holds that account to the reading the session will take of itself. A
# choice made on a narrower reading than the session's own picks an account
# the session then judges as spent, hands over again, and pays a window swap
# and a handoff every cycle.
lane_context_mark_model() { # HARNESS MODEL
  case "${1:-}" in
    claude | pi) printf '%s\n' "${2:-}" ;;
    *) printf '\n' ;;
  esac
}

# lane_context_reading HARNESS [WINDOW] [DIR] [SESSION] [BOX] — one reading of
# the transcript on stdin, or for copilot of the session record
# copilot_session_read accepted, through HARNESS's adapter:
# `<tokens>\t<window>\t<model>`, the word LANE_CONTEXT_UNREAD for a usage
# object the adapter does not read, or nothing for a transcript holding no
# usage yet. WINDOW is a window the harness named outside its transcript,
# which only Pi's hook payloads do, at a turn end and after a tool call. Exit 3
# names a harness no adapter reads; any other failure is the adapter's own.
# DIR is the session project for Pi settings, and SESSION and BOX the session
# id and mailbox directory whose record a Pi reading with no WINDOW takes its
# window from (lane_adapter_pi_reading). The reading's window field holds the
# verified compaction point, empty when the effective configuration is
# unresolved.
lane_context_reading() { # HARNESS [WINDOW] [DIR] [SESSION] [BOX]
  case "${1:-}" in
    claude) lane_adapter_claude_reading "$LANE_CONTEXT_UNREAD" ;;
    codex) lane_adapter_codex_reading "$LANE_CONTEXT_UNREAD" ;;
    pi) lane_adapter_pi_reading "$LANE_CONTEXT_UNREAD" "${2:-}" "${3:-$PWD}" "${4:-}" "${5:-}" ;;
    copilot) lane_adapter_copilot_reading "$LANE_CONTEXT_UNREAD" ;;
    *) return 3 ;;
  esac
}

# lane_context_transcript_owned HARNESS PATH SESSION HOME — whether PATH is
# the transcript HARNESS writes for the session SESSION under the launch home
# HOME, by the path shape that harness's adapter states. SESSION is the id the
# harness's Stop payload names and HOME the launch home the fleet record's
# `.overseer.home` names, written by lib/overseer-launch.sh
# (../../schemas/workflow-state.md § Oversee state). The overseer turn-end path of
# hooks/lane-mail-check.sh
# asks here before it reads the overseer's transcript, so that session is not
# judged on a file another session wrote: a newer transcript beside it, a
# predecessor's in the same pane, or one under another account's home. The
# lane path reads its payload's transcript unbound. 0 where PATH is that file;
# 1 with the word for what failed in LANE_CONTEXT_OWNED_REASON, `binding-missing`
# where PATH or SESSION is empty, `home-unnamed` where HOME is, and the
# adapter's own `session-mismatch` or `home-mismatch`; 3 with `harness-unlisted`,
# ahead of every other answer, for a harness no adapter states a shape for, an
# empty one included; the hook passes that answer on, so the list of harnesses
# with a shape lives here alone. Whether the bound file can be read is the
# reader's question, answered where the file is opened.
LANE_CONTEXT_OWNED_REASON=""
lane_context_transcript_owned() { # HARNESS PATH SESSION HOME
  LANE_CONTEXT_OWNED_REASON=""
  case "${1:-}" in
    claude | codex | copilot) ;;
    *) LANE_CONTEXT_OWNED_REASON=harness-unlisted; return 3 ;;
  esac
  if [ -z "${2:-}" ] || [ -z "${3:-}" ]; then
    LANE_CONTEXT_OWNED_REASON=binding-missing
    return 1
  fi
  if [ -z "${4:-}" ]; then
    LANE_CONTEXT_OWNED_REASON=home-unnamed
    return 1
  fi
  if ! "lane_adapter_${1}_transcript_owned" "$2" "$3" "$4"; then
    LANE_CONTEXT_OWNED_REASON="$LANE_ADAPTER_OWNED_REASON"
    return 1
  fi
}

# Normalize the requested handoff percentage for the judge and its reports.
# A larger setting cannot weaken the mandatory remaining-capacity mark.
lane_context_handoff_pct() { # PCT
  case "${1:-}" in '' | *[!0-9]* | 0*) return 2 ;; esac
  [ "$1" -le 100 ] || return 2
  if [ "$1" -gt 90 ]; then printf '90\n'; else printf '%s\n' "$1"; fi
}

# lane_context_handoff_due TOKENS WINDOW PCT [AGENT_RESERVE] — one context
# reading: `due` at 400000 used tokens or strictly past PCT percent of WINDOW,
# with PCT capped at 90. WINDOW is the effective capacity before compaction,
# or the actual window when compaction is disabled. Exit 1 below the token cap
# where WINDOW is empty or 0, which is unmeasured and never room. Exit 2 where
# PCT is not a whole number from 1
# to 100, or a figure is not a whole number or carries a leading zero a shell
# would read as octal. Every reader of a reading asks here, so a lane, the
# overseer and the report cannot judge one reading two ways.
lane_context_handoff_due() { # TOKENS WINDOW PCT [AGENT_RESERVE]
  local pct cap_mark window_mark
  lane_context_marks "$@" || return 2
  if [ "$1" -ge "$cap_mark" ]; then printf 'due\n'; return 0; fi
  case "$window_mark" in '') return 1 ;; invalid) return 2 ;; esac
  # A launch must keep its reserve before either mark. Equality refuses a
  # launch, while the existing handoff percentage remains strictly greater.
  if [ "$#" -ge 4 ]; then
    if [ "$1" -ge "$window_mark" ]; then printf 'due\n'; else printf 'room\n'; fi
  elif [ "$1" -gt "$window_mark" ]; then
    printf 'due\n'
  else
    printf 'room\n'
  fi
}

# The marks lane_context_handoff_due and lane_context_handoff_decision judge
# and record for the same arguments, computed once, into the CALLER's locals
# pct, cap_mark and window_mark. cap_mark is the token count due at or past.
# window_mark is the whole token count the window percentage leaves after any
# reserve: due strictly past it without a reserve and at or past it with one,
# which is exact for whole token counts. It is empty where WINDOW is empty or
# 0, `invalid` where WINDOW is malformed, and empty with cap_mark 0 where the
# reserve leaves no room below the absolute mark. Exit 2 where PCT, TOKENS or
# the reserve is rejected.
lane_context_marks() { # TOKENS WINDOW PCT [AGENT_RESERVE]
  pct=$(lane_context_handoff_pct "${3:-}") || return 2
  case "${1:-}" in '' | *[!0-9]*) return 2 ;; 0) ;; 0*) return 2 ;; esac
  cap_mark=400000
  window_mark=""
  if [ "$#" -ge 4 ]; then
    case "$4" in '' | *[!0-9]*) return 2 ;; 0) ;; 0*) return 2 ;; esac
    # No arithmetic uses an unbounded setting: any reserve this large leaves
    # no room below the absolute mark, even if the capacity is unknown.
    if [ "${#4}" -gt 6 ] || [ "$4" -ge 400000 ]; then
      cap_mark=0
      return 0
    fi
    cap_mark=$((400000 - $4))
  fi
  case "${2:-}" in
    '' | 0) ;;
    *[!0-9]* | 0*) window_mark=invalid ;;
    *)
      if [ "$#" -ge 4 ]; then
        window_mark=$((($2 * pct + 99) / 100 - $4))
      else
        window_mark=$(($2 * pct / 100))
      fi
      ;;
  esac
}

# lane_context_handoff_decision TOKENS WINDOW PCT [AGENT_RESERVE] — the
# reading lane_context_handoff_due judges for the same arguments, as the one
# JSON object a handoff records: tokens, window, the absolute cap, the
# effective mark_pct, the cap_mark and window_mark it compared against, and
# whether and how much reserve applied. A window or window mark nothing
# measured is null. Exit 2, printing nothing, where that judge exits 2. Only
# a caller that records the decision asks for it.
lane_context_handoff_decision() { # TOKENS WINDOW PCT [AGENT_RESERVE]
  local pct cap_mark window_mark window=null applied=false reserve=0
  lane_context_marks "$@" || return 2
  case "$window_mark" in
    '') window_mark=null ;;
    invalid)
      [ "$1" -ge "$cap_mark" ] || return 2
      window_mark=null
      ;;
  esac
  case "${2:-}" in '' | *[!0-9]* | 0?*) ;; *) window=$2 ;; esac
  if [ "$#" -ge 4 ]; then
    applied=true
    reserve=$4
  fi
  printf '{"tokens":%s,"window":%s,"cap":400000,"mark_pct":%s,"cap_mark":%s,"window_mark":%s,"reserve_applied":%s,"reserve_tokens":%s}\n' \
    "$1" "$window" "$pct" "$cap_mark" "$window_mark" "$applied" "$reserve"
}

# lane_context_handoff_context DECISION HARNESS SESSION TRANSCRIPT PANE_KEY
# SOURCE COMPACTED — the `context` a handoff record carries: DECISION, a
# lane_context_handoff_decision object or null, beside the native session it
# was read for. An empty field stays null, as does COMPACTED unless it reads
# true or false. Exit nonzero, printing nothing, where DECISION is not JSON.
lane_context_handoff_context() { # DECISION HARNESS SESSION TRANSCRIPT PANE_KEY SOURCE COMPACTED
  jq -nc --argjson decision "$1" --arg harness "$2" --arg session "$3" --arg transcript "$4" \
    --arg pane "$5" --arg source "$6" --arg compacted "$7" '
    def nul: if . == "" then null else . end;
    {decision:$decision, source:{harness:($harness | nul), session_id:($session | nul),
      transcript:($transcript | nul), pane_key:($pane | nul), capacity_source:($source | nul),
      compacted:({"true":true, "false":false}[$compacted])}}'
}

# lane_context_window_full TOKENS WINDOW HARNESS — whether a reading of a
# HARNESS session fills the window it names, so that session can take no turn
# again: exit 0 where it does, 1 where it does not or cannot. Only the window a
# claude, codex or pi reading names is the hard limit a session stops at, since
# each adapter names one only where the harness would not compact first
# (lib/adapters/). A copilot reading's window is the point Copilot starts to
# compact, which cannot be turned off, so a copilot reading at it is a session
# about to compact and never full. A reading with no window is never full.
# Exit 2 where a figure is not a whole number, and 3 for a harness no adapter
# reads.
lane_context_window_full() { # TOKENS WINDOW HARNESS
  case "${3:-}" in
    claude | codex | pi) ;;
    copilot) return 1 ;;
    *) return 3 ;;
  esac
  case "${1:-}" in
    '' | *[!0-9]*) return 2 ;;
    0) ;;
    0*) return 2 ;;
  esac
  case "${2:-}" in
    '' | 0) return 1 ;;
    *[!0-9]* | 0*) return 2 ;;
  esac
  [ "$1" -ge "$2" ]
}

# lane_context_file_write BOX FILE JQ_ARGS... — the document jq prints from
# JQ_ARGS, which end with its filter, written to BOX/FILE through a file
# renamed over it so no reader meets half a record. `at` is bound to the time
# of writing. Exit non-zero where the file could not be written, the cause on
# stderr. Every record this library names is written through here.
lane_context_file_write() { # BOX FILE JQ_ARGS...
  local box="${1:?}" file="${2:?}" staged at
  shift 2
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ) || return 1
  staged="$box/.$file.$$"
  if ! jq -nc --arg at "$at" "$@" >"$staged"; then
    rm -f -- "${staged:?}"
    return 1
  fi
  mv -f -- "$staged" "$box/$file" || { rm -f -- "${staged:?}"; return 1; }
}

# lane_context_record BOX HARNESS TOKENS WINDOW MODEL [SESSION] [PANE_KEY]
# [GAP] [CAPACITY_SOURCE] — write a session's reading to
# BOX/$LANE_CONTEXT_RECORD. `used_pct` is the whole percent of the window
# used, null with the window. SESSION is the id the harness names the session
# by and PANE_KEY the `<server pid> <pane id>` it runs in, which is how a
# successor overseer's reader tells its own record from the one its
# predecessor left in the same mailbox. GAP is the word for why a turn end
# took no reading, with TOKENS `null`: the overseer's turn-end hook writes one
# where its gate refused the read, so the record still advances at every turn
# end and says why it carries no figure. CAPACITY_SOURCE names where WINDOW
# came from where it is not the window the harness itself reported as its
# capacity, a Copilot CLI one (lane_context_copilot_reading);
# `capacity_source` is null otherwise.
lane_context_record() { # BOX HARNESS TOKENS WINDOW MODEL [SESSION] [PANE_KEY] [GAP] [CAPACITY_SOURCE]
  lane_context_file_write "$1" "$LANE_CONTEXT_RECORD" --arg harness "$2" --argjson tokens "$3" \
    --arg window "$4" --arg model "$5" --arg session "${6:-}" --arg pane_key "${7:-}" \
    --arg gap "${8:-}" --arg source "${9:-}" '
    def nul: if . == "" then null else . end;
    ($window | nul | if . == null then null else tonumber end) as $w
    | {harness: $harness, model: ($model | nul), tokens: $tokens, window: $w,
       used_pct: (if $w == null or $w == 0 then null else ($tokens * 100 / $w | floor) end),
       capacity_source: ($source | nul),
       session_id: ($session | nul), pane_key: ($pane_key | nul), gap: ($gap | nul), at: $at}'
}

# The share of a Copilot CLI session's prompt token limit at which Copilot
# starts its automatic compaction, which nothing turns off: the capacity a
# Copilot session is judged against, so the shared rule hands it off before
# that compaction and needs no threshold of its own. It is the Copilot SDK's
# documented `InfiniteSessionConfig.backgroundCompactionThreshold` default,
# 0.80 (copilot-sdk types.d.ts), and the CLI compacts at the first
# `session.usage_info` reading at or past it.
# Where Copilot's usage event gains a field naming the compaction limit, that
# figure replaces this share.
LANE_CONTEXT_COPILOT_COMPACTION_PCT=80
LANE_CONTEXT_COPILOT_CAPACITY_SOURCE="80% of tokenLimit, Copilot's backgroundCompactionThreshold default"

# lane_context_copilot_reading — the reading the orch copilot-lane-context
# extension hands on stdin, {current_tokens, token_limit} from one
# `session.usage_info` event, read as `TOKENS<TAB>CAPACITY<TAB>SOURCE`: the
# tokens in context, LANE_CONTEXT_COPILOT_COMPACTION_PCT percent of the token
# limit rounded down, and LANE_CONTEXT_COPILOT_CAPACITY_SOURCE. Exit non-zero
# where the payload is not an object carrying a whole `current_tokens` and a
# whole `token_limit` above 0.
lane_context_copilot_reading() {
  jq -r --argjson pct "$LANE_CONTEXT_COPILOT_COMPACTION_PCT" --arg source "$LANE_CONTEXT_COPILOT_CAPACITY_SOURCE" '
    def whole: type == "number" and . >= 0 and . == floor;
    if type != "object" then error("not an object")
    elif (.current_tokens | whole | not) then error("current_tokens is no whole number")
    elif (.token_limit | whole | not) or .token_limit == 0 then error("token_limit is no whole number above 0")
    else [(.current_tokens | tostring), (.token_limit * $pct / 100 | floor | tostring), $source] | join("\t")
    end'
}

# The file a Copilot session's automatic compaction is flagged in, beside its
# reading in its mailbox directory. The reading is rewritten at every model
# call, so the flag is a file of its own, which no reading touches: the backstop for a turn that crosses into Copilot's compaction
# before a reading past the mark reaches a turn end.
LANE_CONTEXT_COMPACTION=compaction.json

# lane_context_compaction_flag BOX HARNESS TRIGGER [SESSION] [PANE_KEY] — flag
# the session SESSION's compaction, begun on TRIGGER, in
# BOX/$LANE_CONTEXT_COMPACTION. Exit non-zero where it could not be written,
# the cause on stderr.
lane_context_compaction_flag() { # BOX HARNESS TRIGGER [SESSION] [PANE_KEY]
  lane_context_file_write "$1" "$LANE_CONTEXT_COMPACTION" --arg harness "$2" --arg trigger "$3" \
    --arg session "${4:-}" --arg pane_key "${5:-}" '
    def nul: if . == "" then null else . end;
    {harness: $harness, trigger: $trigger, session_id: ($session | nul),
     pane_key: ($pane_key | nul), at: $at}'
}

# lane_context_compaction_flagged BOX SESSION — whether BOX/$LANE_CONTEXT_COMPACTION
# flags the session SESSION: 0 where it does, 1 where no flag stands or it
# names another session, a predecessor's in the same mailbox included, and 2
# with the cause on stderr where a flag stands and cannot be read as one. An
# empty SESSION matches a flag naming none. The one reader of the flag, so the
# turn end and any report cannot read it two ways.
lane_context_compaction_flagged() { # BOX SESSION
  local file="${1:?}/$LANE_CONTEXT_COMPACTION" doc rc=0
  [ -e "$file" ] || [ -L "$file" ] || return 1
  doc=$(cat -- "$file") || return 2
  jq -e --arg s "${2:-}" 'if type != "object" then error("not a compaction flag")
    else (.session_id // "") == $s end' <<<"$doc" >/dev/null || rc=$?
  case "$rc" in
    0 | 1) return "$rc" ;;
    *) return 2 ;;
  esac
}

# The three hooks a Copilot CLI fleet session is judged by, in the form kendex
# renders a Copilot hook (crates/core/src/engine/targets.rs, copilot_hook):
# `<name>.sh` beside the registry document `<name>.json` Copilot loads it
# from. lane-mail-check judges the turn end and records the context readings
# the orch copilot-lane-context extension hands it, which spells this rule
# again, being a copy in the Copilot home with no orch install beside it;
# lane-mail-compact flags the automatic compaction; lane-mail-start records
# the session as the lead at its sessionStart, the record lane-mail-check
# needs before it takes a usage reading or a compaction flag as the lead's,
# which otherwise waits for the first turn end.
LANE_CONTEXT_COPILOT_HOOKS="lane-mail-check lane-mail-compact lane-mail-start"

# lane_context_copilot_hooks ROOT HOME — the hook directory a Copilot CLI
# session working in the repository ROOT under the Copilot home HOME loads
# all of LANE_CONTEXT_COPILOT_HOOKS from: ROOT/.github/hooks, the project
# scope, else HOME/hooks, the global one. Exit 1 where neither holds all, an
# empty ROOT or HOME naming no scope.
lane_context_copilot_hooks() { # ROOT HOME
  local dir name held
  for dir in "${1:+$1/.github/hooks}" "${2:+$2/hooks}"; do
    [ -n "$dir" ] || continue
    held=1
    for name in $LANE_CONTEXT_COPILOT_HOOKS; do
      { [ -f "$dir/$name.sh" ] && [ -f "$dir/$name.json" ]; } || { held=0; break; }
    done
    if [ "$held" -eq 1 ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  return 1
}

# lane_context_copilot_pending_dir — the directory the orch
# copilot-lane-context extension writes a session's pending marker in:
# `.cache/lane-mail/copilot-usage` under HOME, the home a Copilot process
# started from this environment runs under. The extension spells it again from
# its own os.homedir(), being a copy in the Copilot home with no orch install
# beside it, and tests/copilot-lane-context.sh holds the two spellings to the
# same directory.
lane_context_copilot_pending_dir() {
  printf '%s\n' "${HOME:-}/.cache/lane-mail/copilot-usage"
}

# lane_context_record_fields RECORD — one record split into LANE_CTX_HARNESS,
# LANE_CTX_TOKENS, LANE_CTX_WINDOW, LANE_CTX_MODEL, LANE_CTX_PANE_KEY,
# LANE_CTX_SESSION, LANE_CTX_GAP, LANE_CTX_AT and LANE_CTX_SOURCE, the
# record's `capacity_source`, each empty where the record holds none. A
# reading carries a token count and no gap; a gap record carries the gap and
# no token count. Exit 1, every field empty, where RECORD is neither shape
# lane_context_record writes.
lane_context_record_fields() { # RECORD
  local fields rest
  LANE_CTX_HARNESS="" LANE_CTX_TOKENS="" LANE_CTX_WINDOW=""
  LANE_CTX_MODEL="" LANE_CTX_PANE_KEY="" LANE_CTX_SESSION="" LANE_CTX_GAP="" LANE_CTX_AT=""
  LANE_CTX_SOURCE=""
  fields=$(jq -er 'select(type == "object" and (((.tokens | type) == "number" and .gap == null)
      or (.tokens == null and (.gap | type) == "string" and .gap != "")))
    | [(.harness // ""), (.tokens // "" | tostring), (.window // "" | tostring),
       (.model // ""), (.pane_key // ""), (.session_id // ""), (.gap // ""), (.at // ""),
       (.capacity_source // "")] | join("\t")' <<<"${1:-}" 2>/dev/null) || return 1
  # Split by hand, never `IFS=$'\t' read`: a TAB is IFS whitespace, so an
  # empty field would otherwise collapse into its neighbour.
  rest="$fields"
  LANE_CTX_HARNESS="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_TOKENS="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_WINDOW="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_MODEL="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_PANE_KEY="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_SESSION="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_GAP="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  LANE_CTX_AT="${rest%%$'\t'*}"
  LANE_CTX_SOURCE="${rest#*$'\t'}"
}

# The key a live session's own row is matched on, `<tmux server pid> <pane id>`
# on one line; 1 where the caller sits on no pane this reader can ask about.
#
# Pane ids restart at %0 on every tmux server, so the PAIR is the key and the id
# alone is not. Every consumer that compares one session's key against another
# session's record reads it here: `oversee` and `overseer-run` record the
# overseer's by it, the session rows name it, and the turn-end hook compares
# its own against that record, so none of them can spell one session
# differently.
lane_context_caller_key() {
  local pane="${TMUX_PANE:-}" server
  [ -n "$pane" ] || return 1
  server="$(tmux display-message -p -t "$pane" '#{pid}' 2>/dev/null)" || return 1
  [ -n "$server" ] || return 1
  printf '%s %s\n' "$server" "$pane"
}

# Align the tab-separated table on stdin; the lane listing (`lanes list`)
# renders through here. `column` is util-linux, not one of orch's declared dependencies (jq,
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

# The HEADROOM cell the lane listing prints, as a jq def over one record: the
# credit balance of a Codex account room on its credits, binding_bucket
# `credits`, whose window headroom is spent and says nothing of its room;
# otherwise headroom_pct, which for a dollar API grant is its share left.
# shellcheck disable=SC2016  # jq source, never expanded by the shell.
LANE_HEADROOM_CELL_JQ='
def headroom_cell:
  if .binding_bucket == "credits" and .credits.unit != "usd"
  then (.credits.balance | if . >= 1000 then (((. / 100) | floor) / 10 | tostring) + "k cr"
                           else (floor | tostring) + " cr" end)
  elif .headroom_pct == null then "-" else (.headroom_pct | tostring) + "%" end;
'

# The live reader shared by the hook and the pre-panel check. The hook supplies
# its session inputs, WORK_DIR and the message/refuse_handoff callbacks. Direct
# execution below supplies the same contract for review-pr. Both use the
# harness adapter and Copilot extension owner; neither reads a cached record
# as a prerequisite to refreshing it.
TRANSCRIPT_WINDOW=1048576

# lane_context_session_file HARNESS SESSION CWD — the transcript of session
# SESSION under HARNESS's home for CWD, found by the id its launch bound and
# never by its age, through the agent-runtime executable's one lookup
# (`session-file`), into TRANSCRIPT. Exit 1 with READ_GAP naming why no path
# was found: `transcript-unnamed` with no session id, or a harness other than
# codex; `session-file-absent` where the
# harness has written no file for the id yet; `session-store-unreadable`
# where its store could not be read; `session-lookup-unavailable` where the
# executable gave no answer, a host where it is not built included. Each is a
# gap the caller reports and passes, never a refusal of the turn.
lane_context_session_file() { # HARNESS SESSION CWD
  local home reply reading
  # The Codex rollout is the one session file its harness names by the id
  # alone, in a dated store no caller can name a path into; the other
  # harnesses' turn-end payloads name their transcript, and a payload naming
  # none is their gap.
  [ "$1" = codex ] && [ -n "${2:-}" ] || return 1
  home=$(lane_context_caller_home "$1") || return 1
  if ! reply=$("$LANE_CONTEXT_AGENT_RUNTIME" session-file --harness "$1" --home "$home" --cwd "$3" --id "$2" 2>"$WORK_DIR/session-file.err"); then
    READ_GAP=session-lookup-unavailable
    message session-lookup-unavailable "$1" "$(cat -- "$WORK_DIR/session-file.err")"
    return 1
  fi
  reading=$(jq -r '[.result.reading // "", .result.file // "", .result.cause // ""] | join("\t")' <<<"$reply" 2>/dev/null) || reading=""
  case "${reading%%"$TAB"*}" in
    live)
      reading=${reading#*"$TAB"}
      TRANSCRIPT=${reading%%"$TAB"*}
      [ -n "$TRANSCRIPT" ] || { READ_GAP=session-lookup-unavailable; message session-lookup-unavailable "$1" "$reply"; return 1; }
      return 0
      ;;
    gone) READ_GAP=session-file-absent; return 1 ;;
    unreadable)
      READ_GAP=session-store-unreadable
      message session-store-unreadable "$1" "${reading##*"$TAB"}"
      return 1
      ;;
    *) READ_GAP=session-lookup-unavailable; message session-lookup-unavailable "$1" "$reply"; return 1 ;;
  esac
}

# This session's context, read from the transcript the payload names through
# the adapter for HARNESS, into TOKENS, WINDOW and MODEL, and recorded in BOX
# for report readers. TOKENS is empty where there is nothing to read — no
# transcript named, no usage line in it, or a harness no adapter reads — and
# LANE_CONTEXT_UNREAD for a usage object the adapter does not read; neither is
# recorded, and READ_GAP names which it was: `transcript-unnamed` (no path
# and no session id to find one by) or a lookup gap of
# lane_context_session_file, `usage-absent`, `usage-unread` or, for a Copilot
# session with no extension reading, `session-record`, empty where a reading
# was taken or the harness is one no adapter reads. A transcript named and unreadable is
# refused, since the record is
# what clears it. A record that cannot be written is reported and the reading
# still judged: the mark rests on this read, the record serves the others.
#
# A bounded tail first: a session transcript grows without limit and parsing
# the whole of one at every turn end costs more than the rest of this hook
# together. The full file answers only where that window holds no usage line —
# a session on its first turns, or one whose recent lines are all tool results.
# The tail's own words go to a file and are replayed under the refusal: an
# adapter that stops reading leaves the tail a write error, which reaching
# stderr ahead of the keyed line would take its place.
#
# A Copilot transcript holds no live count. A Copilot session is read first
# from the reading the orch copilot-lane-context extension recorded
# (copilot_context_read). Only where no such reading of this session stands is
# it read from the session record its statusLine command writes, bound through
# lib/copilot-session.sh to the payload's session id, its transcript where it
# names one, and the account the session runs on, and held to the record's
# freshness bound: the fallback for a home whose EXTENSIONS feature is off,
# since the extension's usage event is the interface Copilot offers and the
# statusLine is a display command. That reading is recorded with its own
# capacity source, so no later turn end takes it for the extension's. A record
# that does not answer leaves the context unmeasured under
# `reading-unrecorded=<path>` and `session-record=<reason>` and the gap
# `session-record`, reported and passed like a transcript that names no usage,
# and never read as room. The record is read beside an extension reading too,
# for its stop cause alone, reported as `stop-cause=<cause>`.
context_read_and_record() { # BOX PANE_KEY
  TOKENS=""
  WINDOW=""
  MODEL=""
  READ_GAP=""
  COMPACTED=false
  SOURCE=""
  # An install directory naming no harness has no adapter to read its context,
  # so it is reported unmeasured where the payload names a transcript to go
  # unread. No gap is named for it, whatever the payload carries: this hook
  # never reads that context, so a gap would stand at every turn end for the
  # life of the session, and the record stays as it was, the mark documented
  # as unjudged there. Decided before anything else, so no path through such
  # an install names one.
  if [ -z "$HARNESS" ]; then
    [ -z "$TRANSCRIPT" ] || message harness-unlisted "$HOOK_DIR"
    return 0
  fi
  if [ "$HARNESS" = copilot ]; then
    # The extension's reading is the session's own and is never overwritten
    # here: the reader owns the record. The statusLine record alone carries
    # allow_all_enabled, so it is read for the stop cause beside either reading.
    EXTENSION_READ=true
    copilot_context_read "$1" || EXTENSION_READ=false
    [ "$COMPACTED" = false ] || return 0
    if ! copilot_session_read "$(lane_context_caller_cfg copilot)" "$SESSION" "$TRANSCRIPT" "$(date +%s)"; then
      [ "$EXTENSION_READ" = false ] || return 0
      READ_GAP=session-record
      message reading-unrecorded "$1/$LANE_CONTEXT_RECORD"
      message session-record "$COPILOT_SESSION_REASON"
      return 0
    fi
    ! STOP_CAUSE=$(copilot_session_stop_cause "$COPILOT_SESSION_RECORD" "${COPILOT_ALLOW_ALL:-}") || message stop-cause "$STOP_CAUSE"
    [ "$EXTENSION_READ" = false ] || return 0
    READING=$(lane_context_reading copilot <<<"$COPILOT_SESSION_RECORD" 2>"$WORK_DIR/transcript.err") ||
      refuse_handoff transcript unread "$(cat -- "$WORK_DIR/transcript.err")"
    SOURCE=$LANE_ADAPTER_COPILOT_CAPACITY_SOURCE
  else
    READ_GAP=transcript-unnamed
    [ -n "$TRANSCRIPT" ] || lane_context_session_file "$HARNESS" "$SESSION" "$LANE_DIR" || return 0
    { [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; } || refuse_handoff transcript unreadable
    if ! READING=$(tail -c "$TRANSCRIPT_WINDOW" -- "$TRANSCRIPT" 2>"$WORK_DIR/tail.err" |
      lane_context_reading "$HARNESS" "$PAYLOAD_WINDOW" "$LANE_DIR" "$SESSION" "$1" 2>"$WORK_DIR/transcript.err"); then
      refuse_handoff transcript unread "$(cat -- "$WORK_DIR/transcript.err" "$WORK_DIR/tail.err")"
    fi
    if [ -z "$READING" ] && ! READING=$(lane_context_reading "$HARNESS" "$PAYLOAD_WINDOW" "$LANE_DIR" "$SESSION" "$1" <"$TRANSCRIPT" 2>"$WORK_DIR/transcript.err"); then
      refuse_handoff transcript unread "$(cat -- "$WORK_DIR/transcript.err")"
    fi
  fi
  if [ -s "$WORK_DIR/transcript.err" ]; then
    message compaction-unread "$HARNESS" "$(cat -- "$WORK_DIR/transcript.err")"
  fi
  case "$READING" in
    '')
      READ_GAP=usage-absent
      return 0
      ;;
    "$LANE_CONTEXT_UNREAD")
      TOKENS=$READING
      READ_GAP=usage-unread
      return 0
      ;;
  esac
  READ_GAP=""
  TOKENS=${READING%%"$TAB"*}
  READING=${READING#*"$TAB"}
  WINDOW=${READING%%"$TAB"*}
  MODEL=${READING#*"$TAB"}
  lane_context_record "$1" "$HARNESS" "$TOKENS" "$WINDOW" "$MODEL" "$SESSION" "$2" "" "$SOURCE" \
    2>"$WORK_DIR/record.err" ||
    message context-unrecorded "$1/$LANE_CONTEXT_RECORD" "$(cat -- "$WORK_DIR/record.err")"
  return 0
}

# A Copilot session's context at its turn end, from BOX, as the orch
# copilot-lane-context extension recorded it: COMPACTED true where the
# lane-mail-compact hook flagged this session's automatic compaction, and
# TOKENS, WINDOW and MODEL from the reading the usage arm last recorded
# for this session, WINDOW being the capacity it named, the limit Copilot
# compacts at. 0 once either is taken; nothing is written here, since the
# reader owns the record. 1 where no reading of the extension's stands for
# this session: no record, one naming another session, a predecessor's in the
# same mailbox included, and one whose capacity source is not the one the
# usage arm writes, which a gap record, written by the turn end of an overseer
# the fleet record lost, and a reading the statusLine fallback recorded both
# are. The caller then takes the statusLine
# fallback, and never reads that as room. A reading the extension handed on
# and no run has recorded yet leaves the context unmeasured under
# `reading-pending` (copilot_reading_pending), 0 with no fallback: the
# extension runs for this session, and the record standing is older than the
# reading on its way. A flag or a record that stands and cannot be read is
# refused, since the handoff record is what clears that.
copilot_context_read() { # BOX
  FLAG_RC=0
  lane_context_compaction_flagged "$1" "$SESSION" 2>"$WORK_DIR/flag.err" || FLAG_RC=$?
  case "$FLAG_RC" in
    0)
      # Past the mark whatever the reading says: the refusal follows, and a
      # report on the reading ahead of it would stand before its keyed line.
      COMPACTED=true
      return 0
      ;;
    1) ;;
    *) refuse_handoff record "$1/$LANE_CONTEXT_COMPACTION" "$(cat -- "$WORK_DIR/flag.err")" ;;
  esac
  if copilot_reading_pending; then
    message reading-pending "$PENDING_FILE"
    return 0
  fi
  [ -e "$1/$LANE_CONTEXT_RECORD" ] || return 1
  RECORD=$(cat -- "$1/$LANE_CONTEXT_RECORD" 2>"$WORK_DIR/record.err") ||
    refuse_handoff record "$1/$LANE_CONTEXT_RECORD" "$(cat -- "$WORK_DIR/record.err")"
  lane_context_record_fields "$RECORD" ||
    refuse_handoff record "$1/$LANE_CONTEXT_RECORD" "it is neither a reading nor a gap record"
  if [ "$LANE_CTX_SESSION" != "$SESSION" ] ||
    [ "$LANE_CTX_SOURCE" != "$LANE_CONTEXT_COPILOT_CAPACITY_SOURCE" ]; then
    return 1
  fi
  TOKENS=$LANE_CTX_TOKENS
  WINDOW=$LANE_CTX_WINDOW
  MODEL=$LANE_CTX_MODEL
  SOURCE=$LANE_CTX_SOURCE
  return 0
}

# Whether a context reading of this session is on its way to the record: 0
# where the extension's pending marker for SESSION, PENDING_FILE, still stands
# after PENDING_POLLS polls of 0.2 s, 1 where it is gone or the payload names
# no session. The extension hands each reading to a usage run apart from the
# session and removes the marker once a run records the last one, so nothing
# else orders that run before this turn end, and the record standing while it
# goes is an earlier reading, which can lie below the mark this one crossed.
# The wait covers a run that is recording as the turn ends; a marker that
# outlives it is a run still going or one that failed, and neither is read.
PENDING_POLLS=25
PENDING_WAIT="5 seconds"
PENDING_FILE=""
copilot_reading_pending() {
  local polls=0
  [ -n "$SESSION" ] || return 1
  PENDING_FILE="$COPILOT_USAGE/$SESSION"
  while [ -e "$PENDING_FILE" ]; do
    [ "$polls" -lt "$PENDING_POLLS" ] || return 0
    sleep 0.2
    polls=$((polls + 1))
  done
  return 1
}

# The checkpoint or attached-launch caller invokes this library with the
# native session inputs a hook payload supplies, but for its window: HARNESS
# SESSION TRANSCRIPT BOX PROJECT. A session runs it from its own shell tool,
# where no payload exists, so a window there could only be a number the caller
# typed, and the adapter finds a Pi window itself (lane_adapter_pi_reading). A
# sixth argument, empty or not, is the window the earlier review-pr text
# passed, which a lane that loaded that text still sends: it reads, unused,
# with one warning naming this form, until the next kendex major release. The
# caller's launch home stays in the harness environment. Without --checkpoint
# the reading is judged with the agent reserve, for an impending attached
# launch, which --attached-launch names; --checkpoint, an ordinary
# checkpoint, uses the plain mark.
# Explicit Codex attached-launch callers also get alternate-review when only
# the reserve refuses the launch. review-pr runs that panel through job-unit;
# the native hook and unflagged callers keep the reserve's due answer.
# stdout is room, due or alternate-review, or with --reading one JSON object
# carrying `verdict`, `decision` and `source`; an unavailable read exits
# nonzero. The hook keeps its own callbacks and never enters this arm.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  CLI_OPERATION=""
  CLI_OUTPUT_READING=false
  while :; do
    case "${1:-}" in
      --attached-launch | --checkpoint)
        if [ -n "$CLI_OPERATION" ]; then
          printf '%s\n' "lane-context: operation=$1" 'Pass one of --attached-launch and --checkpoint.' >&2
          exit 2
        fi
        CLI_OPERATION=${1#--}
        shift
        ;;
      --reading) CLI_OUTPUT_READING=true; shift ;;
      *) break ;;
    esac
  done
  if [ "${1:-}" = --help ]; then
    printf '%s\n' 'Usage: bash lib/lane-context.sh [--attached-launch | --checkpoint] [--reading] HARNESS SESSION TRANSCRIPT BOX PROJECT' \
      'Print room, due or alternate-review for the current session context. The agent reserve applies, as for an impending attached launch,' \
      'unless --checkpoint asks for the plain mark of an ordinary checkpoint.' \
      'Explicit Codex --attached-launch returns alternate-review when the plain mark still has room; review-pr uses process-owned reviewers.' \
      '--reading prints the native verdict, decision and source binding as JSON for the handoff record.'
    exit 0
  fi
  case "$#" in
    5) ;;
    6)
      printf '%s\n' "lane-context: window-argument=$6" \
        'The window argument is no longer read: run lane-context.sh --attached-launch --reading HARNESS SESSION TRANSCRIPT BOX PROJECT.' >&2
      ;;
    *)
      printf '%s\n' 'lane-context: arguments=unavailable' >&2
      exit 2
      ;;
  esac
  HARNESS=$1 SESSION=$2 TRANSCRIPT=$3 BOX=$4 LANE_DIR=$5 PAYLOAD_WINDOW=""
  HOOK_DIR="${BASH_SOURCE[0]%/*}"
  TAB=$(printf '\t')
  COPILOT_USAGE=$(lane_context_copilot_pending_dir)
  WORK_DIR="$(mktemp -d)" || { printf '%s\n' 'lane-context: scratch=mktemp-failed' >&2; exit 2; }
  [[ -d $WORK_DIR && ! -L $WORK_DIR ]] || { printf '%s\n' 'lane-context: scratch=not-a-directory' >&2; exit 2; }
  WORK_DIR="$(cd -- "$WORK_DIR" && pwd -P)" || { printf '%s\n' 'lane-context: scratch=resolve-failed' >&2; exit 2; }
  trap 'rm -rf -- "${WORK_DIR:?}"' EXIT
  message() {
    printf 'lane-context: %s=%s\n' "$1" "${2:-}" >&2
    [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
    return 0
  }
  refuse_handoff() { message "$@"; exit 2; }
  context_read_and_record "$BOX" ""
  if [ "$COMPACTED" = true ]; then
    VERDICT=due
  else
    if [ -z "$TOKENS" ] || [ "$TOKENS" = "$LANE_CONTEXT_UNREAD" ]; then
      message context-unmeasured "${READ_GAP:-reading-unavailable}"
      exit 2
    fi
    MARK=$("$LANE_CONTEXT_SCRIPTS/orch-env" ORCH_HANDOFF_CONTEXT_PCT 90) || exit 2
    JUDGE_ARGS=("$TOKENS" "$WINDOW" "$MARK")
    if [ "$CLI_OPERATION" != checkpoint ]; then
      AGENT_RESERVE=$("$LANE_CONTEXT_SCRIPTS/orch-env" ORCH_HANDOFF_AGENT_RESERVE_TOKENS "") || exit 2
      AGENT_RESERVE=${AGENT_RESERVE:-150000}
      JUDGE_ARGS+=("$AGENT_RESERVE")
    fi
    JUDGE_RC=0
    VERDICT=$(lane_context_handoff_due "${JUDGE_ARGS[@]}") || JUDGE_RC=$?
    case "$JUDGE_RC" in
      0) ;;
      1) message context-unmeasured window-unavailable; exit 2 ;;
      *) message context-judge invalid-input; exit 2 ;;
    esac
    if [ "$HARNESS" = codex ] && [ "$CLI_OPERATION" = attached-launch ] && [ "$VERDICT" = due ]; then
      # A reserve-only refusal is not a parent handoff. An unmeasured or invalid
      # plain reading cannot establish room, even if the reserve proved its cap due.
      PLAIN_RC=0
      PLAIN_VERDICT=$(lane_context_handoff_due "$TOKENS" "$WINDOW" "$MARK") || PLAIN_RC=$?
      case "$PLAIN_RC" in
        0) [ "$PLAIN_VERDICT" != room ] || VERDICT=alternate-review ;;
        1 | 2) ;;
        *) message context-judge invalid-input; exit 2 ;;
      esac
    fi
  fi
  if [ "$CLI_OUTPUT_READING" = true ]; then
    # Compaction is due before any judgement, so it records no decision.
    DECISION=null
    if [ "$COMPACTED" != true ]; then
      DECISION=$(lane_context_handoff_decision "${JUDGE_ARGS[@]}") || exit 2
    fi
    CONTEXT=$(lane_context_handoff_context "$DECISION" "$HARNESS" "$SESSION" "$TRANSCRIPT" "" "$SOURCE" "$COMPACTED") || exit 2
    jq -c --arg verdict "$VERDICT" '{verdict:$verdict} + .' <<<"$CONTEXT"
  else
    printf '%s\n' "$VERDICT"
  fi
fi
