#!/usr/bin/env bash
# Context use per session, read from the records the harness itself writes and
# never from a pane. A session's turn-end hook reads its own transcript through
# the adapter for its harness (lib/adapters/), which answers the tokens the last
# response left in the context and its verified compaction point, and records that
# reading in the session's mailbox directory. Every other reader, the
# runtime watch (`orch-runtime watch`) and its `marks` judge, reads that
# record, so a hosted lane reads the same as a local one and a scrolled or
# quiet pane changes nothing.
#
# The judge of a reading is the runtime's one context judge, asked through
# `orch-runtime marks --item ITEM --context TOKENS:WINDOW`; nothing here
# carries its arithmetic. Missing capacity is unmeasured below the absolute
# cap, never judged against a guess.
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
# shellcheck source=adapters/pi.sh
source "${BASH_SOURCE[0]%/*}/adapters/pi.sh"
# shellcheck source=adapters/copilot.sh
source "${BASH_SOURCE[0]%/*}/adapters/copilot.sh"

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
# which the runtime's `marks --fleet` judges it on; the hook reads this
# function alone, so it judges that overseer's headroom on another account
# where the session's environment disagrees with its record.
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
# (`orch-runtime state heal --fleet`). Exit 1, printing nothing, for a
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
# bucket, the reading the fleet takes of one, and this answers empty.
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
