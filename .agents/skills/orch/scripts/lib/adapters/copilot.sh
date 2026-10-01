# shellcheck shell=bash
#
# The Copilot adapter: the context a session has used, read from the session
# record its `statusLine` command writes (lib/copilot-session.sh), never from
# the transcript, which holds no live count, and never from the pane. It is the
# fallback reader: a turn end reads the reading the orch copilot-lane-context
# extension records from Copilot's own usage event first, and this record only
# where no such reading of the session stands.
#
# Copilot has no switch that turns its automatic compaction off: its CLI starts
# compacting at about 80 percent of the window (GitHub's Copilot CLI context
# management documentation). The capacity this adapter hands the shared judge
# is that point, so the percentage mark fires with a margin before compaction
# on any window, and on the 1M window every launch selects (lib/lane-launch.sh,
# `--context long_context`) the 400000-token cap fires first.
#
# Sourced by lib/lane-context.sh, never run.

# shellcheck source=../copilot-session.sh
source "${BASH_SOURCE[0]%/*}/../copilot-session.sh"

# The share of the window at which Copilot starts compacting is
# LANE_CONTEXT_COPILOT_COMPACTION_PCT (lib/lane-context.sh), the one figure
# both Copilot readers judge against. A reading taken here is recorded under
# this capacity source, so a turn end tells it from the reading the orch
# copilot-lane-context extension records, which it reads first.
LANE_ADAPTER_COPILOT_CAPACITY_SOURCE="80% of context_window_size, from the Copilot statusLine session record"

# One reading from a session record on stdin, as copilot_session_read accepted
# it: `<tokens>\t<capacity>\t<model>`, the capacity empty where the record names
# no window, and `$1` where the record carries no token count.
lane_adapter_copilot_reading() { # UNREAD
  local capacity=""
  copilot_session_fields "$(cat)" || return 1
  if [ -z "$CS_TOKENS" ]; then
    printf '%s\n' "$1"
    return 0
  fi
  [ -z "$CS_WINDOW" ] || capacity=$((CS_WINDOW * LANE_CONTEXT_COPILOT_COMPACTION_PCT / 100))
  printf '%s\t%s\t%s\n' "$CS_TOKENS" "$capacity" "$CS_MODEL"
}

# lane_adapter_copilot_transcript_owned PATH SESSION HOME — whether PATH is the
# transcript Copilot writes for the session SESSION under the account directory
# HOME: `HOME/session-state/SESSION/events.jsonl`. 0 where it is; 1 with
# `session-mismatch` in LANE_ADAPTER_OWNED_REASON where the file is not in the
# directory named for SESSION, and `home-mismatch` where it sits outside HOME.
lane_adapter_copilot_transcript_owned() { # PATH SESSION HOME
  LANE_ADAPTER_OWNED_REASON=""
  case "$1" in
    */session-state/"$2"/events.jsonl) ;;
    *) LANE_ADAPTER_OWNED_REASON=session-mismatch; return 1 ;;
  esac
  case "$1" in
    "${3%/}"/session-state/"$2"/events.jsonl) ;;
    *) LANE_ADAPTER_OWNED_REASON=home-mismatch; return 1 ;;
  esac
}

# Whether the account at HOME runs copilot-statusline as its status line, often
# enough for its record to stay fresh: 0 where HOME/settings.json sets
# `statusLine` to a command whose first word is that script, by any path, an
# executable file there, with a `refreshInterval` in whole seconds above 0 and
# below COPILOT_SESSION_MAX_AGE_S. 1 otherwise, with LANE_ADAPTER_COPILOT_STATUS_REASON
# naming the first thing that failed: `settings-missing`, `settings-unreadable`
# (jq cannot read the file), `no-status-line` (no command statusLine),
# `other-command` (its command is not copilot-statusline), `command-missing`
# (not an executable file), `refresh-interval` (absent, not a whole number, 0,
# or at or above the bound). A session on an account answering 1 writes no record,
# or one its readers take as stale, and its context is never measured.
LANE_ADAPTER_COPILOT_STATUS_REASON=""
lane_adapter_copilot_status_line() { # HOME
  local fields command interval
  LANE_ADAPTER_COPILOT_STATUS_REASON=""
  [ -f "$1/settings.json" ] || { LANE_ADAPTER_COPILOT_STATUS_REASON=settings-missing; return 1; }
  fields=$(jq -r 'if (.statusLine | type) == "object" and .statusLine.type == "command"
    then [((.statusLine.command | strings) // ""),
          (.statusLine.refreshInterval | if type == "number" and . == floor then tostring else "" end)]
         | join("\t")
    else "" end' "$1/settings.json" 2>/dev/null) || { LANE_ADAPTER_COPILOT_STATUS_REASON=settings-unreadable; return 1; }
  [ -n "$fields" ] || { LANE_ADAPTER_COPILOT_STATUS_REASON=no-status-line; return 1; }
  command="${fields%%	*}"
  interval="${fields#*	}"
  command="${command%% *}"
  [ "${command##*/}" = copilot-statusline ] || { LANE_ADAPTER_COPILOT_STATUS_REASON=other-command; return 1; }
  case "$command" in
    */*) ;;
    *) command="$(command -v -- "$command" 2>/dev/null)" || command="" ;;
  esac
  { [ -n "$command" ] && [ -f "$command" ] && [ -x "$command" ]; } \
    || { LANE_ADAPTER_COPILOT_STATUS_REASON=command-missing; return 1; }
  case "$interval" in '' | *[!0-9]*) LANE_ADAPTER_COPILOT_STATUS_REASON=refresh-interval; return 1 ;; esac
  { [ "$interval" -gt 0 ] && [ "$interval" -lt "$COPILOT_SESSION_MAX_AGE_S" ]; } \
    || { LANE_ADAPTER_COPILOT_STATUS_REASON=refresh-interval; return 1; }
}

# The installer uses its own catalog payload, not a launcher's directory.
COPILOT_ADAPTER_SCRIPTS="$(cd -- "${BASH_SOURCE[0]%/*}/../.." && pwd -P)" || return 1
# Make the Copilot home HOME run the kendex context reader, the Copilot
# catalog payload copilot-lane-context/extension.mjs: copied to
# HOME/extensions/kendex-lane-context/extension.mjs, rewritten only where its
# content differs, and loaded by the EXTENSIONS feature, which Copilot keeps
# off until `enabledFeatureFlags.EXTENSIONS` is true in HOME/settings.json.
# Both hold for every session on that home. A settings.json that is a link is
# written through to its target, so the link stays. Each file is renamed into
# place from its own directory, so Copilot never reads half of one. Refused,
# with COPILOT_CONTEXT_FILE naming the file and COPILOT_CONTEXT_DETAIL why:
# `disabled`, an EXTENSIONS flag set false, the operator's choice and never
# overridden; `unreadable`, a file that cannot be read, or settings that are
# no JSON object or carry an EXTENSIONS flag that is no boolean; `unwritable`,
# a write that failed.
COPILOT_CONTEXT_FILE=""
COPILOT_CONTEXT_DETAIL=""
copilot_context_configure() { # HOME
  local source="$COPILOT_ADAPTER_SCRIPTS/copilot-lane-context/extension.mjs" dest target link hops=0 doc='{}' verdict staged
  dest="$1/extensions/kendex-lane-context/extension.mjs"
  COPILOT_CONTEXT_FILE="$source" COPILOT_CONTEXT_DETAIL=unreadable
  [[ -r "$source" ]] || return 1
  COPILOT_CONTEXT_FILE="$dest" COPILOT_CONTEXT_DETAIL=unwritable
  if ! cmp -s -- "$source" "$dest"; then
    mkdir -p -- "${dest%/*}" && staged="$(mktemp "${dest%/*}/.extension.mjs.XXXXXX")" || return 1
    if ! cp -- "$source" "$staged" || ! mv -f -- "$staged" "$dest"; then
      rm -f -- "${staged:?}"
      return 1
    fi
  fi
  # The link's own target, hop by hop: readlink with no option is the one
  # spelling every platform this runs on shares.
  target="$1/settings.json"
  COPILOT_CONTEXT_FILE="$target" COPILOT_CONTEXT_DETAIL=unreadable
  while [[ -L "$target" ]]; do
    hops=$((hops + 1))
    (( hops <= 40 )) && link="$(readlink -- "$target")" || return 1
    case "$link" in /*) target="$link" ;; *) target="${target%/*}/$link" ;; esac
  done
  if [[ -e "$target" ]]; then
    doc="$(cat -- "$target")" || return 1
  fi
  # jq refuses to index a flags value that is no object, which reads as
  # unreadable below.
  verdict="$(jq -r '
    if type != "object" then "unreadable"
    else .enabledFeatureFlags.EXTENSIONS as $on
      | if $on == true then "enabled" elif $on == false then "disabled"
        elif $on == null then "absent" else "unreadable" end
    end' <<<"$doc")" || verdict=unreadable
  case "$verdict" in
    enabled) return 0 ;;
    absent) ;;
    disabled) COPILOT_CONTEXT_DETAIL=disabled; return 1 ;;
    *) return 1 ;;
  esac
  COPILOT_CONTEXT_DETAIL=unwritable
  staged="$(mktemp "${target%/*}/.settings.json.XXXXXX")" || return 1
  if ! jq '.enabledFeatureFlags = ((.enabledFeatureFlags // {}) + {EXTENSIONS: true})' <<<"$doc" >"$staged" \
     || ! mv -f -- "$staged" "$target"; then
    rm -f -- "${staged:?}"
    return 1
  fi
}

# Make the directory the context reader leaves each session's pending marker
# in, lib/lane-context.sh's lane_context_copilot_pending_dir under this
# launcher's HOME, which the lane's Copilot inherits, and prove it writable by
# making and removing one probe file there, the empty file a marker is. The
# marker stands from the moment a reading lands until the lane-mail-check run
# that records it exits 0, so a turn end during a run that fails never judges
# the earlier record as room.
# D015 § D015: A Copilot CLI session is measured by a kendex extension on its usage events, against the limit Copilot compacts at
# A reading the extension could not
# mark would leave that record standing as room. The extension still names a
# marker write that fails after this, as `pending-unwritten`. Refused with
# COPILOT_CONTEXT_FILE naming the directory and COPILOT_CONTEXT_DETAIL
# `pending-unwritable`.
copilot_pending_establish() {
  local dir probe
  dir="$(lane_context_copilot_pending_dir)" || return 1
  COPILOT_CONTEXT_FILE="$dir" COPILOT_CONTEXT_DETAIL=pending-unwritable
  mkdir -p -- "$dir" && probe="$(mktemp "$dir/.probe.XXXXXX")" && rm -f -- "$probe"
}

# copilot_context_install HOME: configure the reader before a session starts.
# An explicit EXTENSIONS=false admits only the statusLine fallback. All other
# setup failures refuse. Callers print FILE, DETAIL and CAUSE under their key.
COPILOT_CONTEXT_MODE="" COPILOT_CONTEXT_CAUSE=""
copilot_context_install() { # HOME
  COPILOT_CONTEXT_MODE="" COPILOT_CONTEXT_CAUSE=""
  COPILOT_CONTEXT_FILE="$1" COPILOT_CONTEXT_DETAIL=relative-home
  [[ "$1" == /* ]] || return 1
  if copilot_context_configure "$1" && copilot_pending_establish; then
    COPILOT_CONTEXT_MODE=extension
    return 0
  fi
  [[ "$COPILOT_CONTEXT_DETAIL" == disabled ]] || return 1
  if lane_adapter_copilot_status_line "$1"; then
    COPILOT_CONTEXT_MODE=status-line
    return 0
  fi
  COPILOT_CONTEXT_CAUSE="$LANE_ADAPTER_COPILOT_STATUS_REASON"
  return 1
}

# copilot_context_reader HOME: the reader a new session can load. SessionStart
# uses this check, not the installer: a hook must not change the operator's home.
copilot_context_reader() { # HOME
  if [[ -r "$1/extensions/kendex-lane-context/extension.mjs" ]] &&
      jq -e '.enabledFeatureFlags.EXTENSIONS == true' "$1/settings.json" >/dev/null 2>&1; then
    return 0
  fi
  lane_adapter_copilot_status_line "$1"
}

# copilot_hooks_gate WORKTREE HOME: the same hook scope and settings judge for
# a fleet lane and a registering overseer. The caller decides whether a failure
# blocks a new launch or warns an already-running session.
COPILOT_HOOK_REASON="" COPILOT_HOOK_ERROR="" COPILOT_HOOK_FIELDS=()
copilot_hooks_gate() { # WORKTREE HOME
  local scope="" name answer err query_rc=0 off="" documents=()
  COPILOT_HOOK_REASON=no-context-hooks COPILOT_HOOK_ERROR=""
  COPILOT_HOOK_FIELDS=("scope=$1/.github/hooks" "scope=$2/hooks")
  scope="$(lane_context_copilot_hooks "$1" "$2")" || return 1
  COPILOT_HOOK_REASON=hooks-unjudged COPILOT_HOOK_FIELDS=(exit=scratch)
  err="$(mktemp)" || return 1
  for name in $LANE_CONTEXT_COPILOT_HOOKS; do
    documents+=(--hook-document "$scope/$name.json")
  done
  answer="$(kendex hooks-off --copilot-home "$2" --project "$1" "${documents[@]}" 2>"$err")" || query_rc=$?
  [[ "$query_rc" -ne 0 ]] || off="$(jq -rn 'input
    | if type == "object" and has("switched_off_by")
        and ((.switched_off_by | type) as $t | $t == "string" or $t == "null")
      then .switched_off_by // "" else error("no switched_off_by answer") end' <<<"$answer" 2>>"$err")" || query_rc=answer
  if [[ "$query_rc" != 0 ]]; then
    COPILOT_HOOK_FIELDS=("exit=$query_rc")
    COPILOT_HOOK_ERROR="$(cat -- "$err")" || { rm -f -- "${err:?}"; return 1; }
    rm -f -- "${err:?}"
    return 1
  fi
  rm -f -- "${err:?}"
  [[ -n "$off" ]] || return 0
  COPILOT_HOOK_REASON=hooks-disabled COPILOT_HOOK_FIELDS=("file=$off")
  return 1
}