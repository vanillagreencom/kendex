# shellcheck shell=bash
#
# The steps every overseer launch takes, whoever asks for one: `oversee
# launch` opening a fleet's first overseer, and `oversee-succeed` opening a
# successor in a predecessor's place. One launcher, so a first launch and a
# succession cannot come to open, verify or record a session differently.
# What differs between them is policy and stays with the caller: which marks
# fire and which entries the account walk tries; the walk and the flag
# assembly apply that policy the same way for both. `oversee-watch` sources
# it too, through lib/watch-overseer-record.sh, for OL_JQ_DEFS, ol_preference,
# ol_session_inspect and ol_fleet_log. What is shared is here:
#
#   ol_preference          the ORCH_OVERSEER_PREFERENCE value, its default
#                          where the setting is unset
#   ol_preference_entries  the shared overseer and lane preference parse
#   ol_account             the account a session spends, as `lanes` judges it
#   ol_pi_model            a pi session's model, out of the sources naming it
#   ol_entry_model         one entry's harness, model and effort, as written
#   ol_lanes               `lanes` on this machine's copy of each account
#   ol_pick_record         one `lanes pick --json` record, for a caller's
#                          own counts
#   ol_pick_lane           one `lanes pick` for one entry, with the counts a
#                          refusal reports
#   ol_account_id          an account directory as its comparable identity
#   ol_walk                the account walk: the entries in order, the first
#                          whose lane qualifies, a predecessor's own entry and
#                          the rules a succession skips an entry on included
#   ol_entry_permitted     whether an entry's harness takes the posture its
#                          source allows
#   ol_launch_flags        the flag words of the entry the walk chose, a
#                          predecessor's words carried over as its harness
#                          and the entry's allow
#   ol_command_line        the harness command for a picked lane, brief
#                          included, made trusted and put under the lane form
#   ol_identity            the launch identity the next record write stores
#   ol_runtime_supported   the runtime resolved and held to the one these
#                          launchers can verify a session on
#   ol_checkout_sync       the checkout a session opens in fast-forwarded
#                          to its base branch's origin head, through
#                          sync-base, before the session opens there
#   ol_checkout_notice     a sync's refusal as the caller's keyed line, on
#                          stderr and in the fleet log
#   ol_session_open        the runtime's `create`, through overseer-host
#   ol_record_*            the session record in the oversee state's
#                          `overseer` object: read, written before the first
#                          turn, restored when the launch is abandoned, the
#                          pending successor written apart from it, the
#                          current session's launch identity read back, and
#                          a record lacking a fact its session knows healed
#   ol_session_verify      the account read, the first working turn and the
#                          confirming read, inside one deadline
#   ol_session_inspect     the runtime's `inspect` of a recorded session: its
#                          liveness, window, server and state
#   ol_succession          one succession from the pending record to the
#                          committing stop, the caller's words at each step
#   ol_session_stop        the runtime's `stop`
#   ol_session_abandon     the close-out every refusal after `create` takes:
#                          the session stopped, the prior record put back
#   ol_fleet_log           one `close` row about the overseer in the fleet log
#   ol_fleet_log_notice    one keyed line of the caller's as that row
#
# Every function returns 0 for the answer its name promises and 1 for a
# refusal the caller prints, with the reason in OL_REASON and its fields in
# the OL_* variables each function documents; none of them prints a keyed
# line of its own, save the preference deprecation warning and conversion, because
# the caller owns its own refusal prefix and words: ol_checkout_notice and
# ol_fleet_log_notice print theirs through the caller's `message`. Every
# dependency writes its stderr to DEP_ERR, which the caller relays under its
# keyed line.
#
# Requires, of a caller that runs its functions: SCRIPT_DIR (the orch scripts
# directory), DEP_ERR (a file), lib/lane-launch.sh and lib/lane-state.sh
# sourced by the caller, the github skill installed beside orch, whose
# lib/bounded.sh ol_checkout_sync sources, and, of a caller that opens a
# session or writes a notice to the fleet log, `message KEY FIELD=VALUE...`
# defined, with a `checkout-unsynced` text of its own where it opens a
# session. Sourcing it defines names and runs nothing. Sourced, never run.

# The file a session's own event rows land in, which the record names: its
# path is lib/session-rows.sh's, named by expansion as lib/lane-context.sh
# names its siblings.
# shellcheck source=session-rows.sh
source "${BASH_SOURCE[0]%/*}/session-rows.sh"
# The start time the record binds its tmux server by is lib/tmux-server.sh's.
# shellcheck source=tmux-server.sh
source "${BASH_SOURCE[0]%/*}/tmux-server.sh"

# The runtime the caller launches into, resolved once per process.
OL_RUNTIME=""
ol_runtime() {
  [[ -n "$OL_RUNTIME" ]] && return 0
  OL_RUNTIME="$("$SCRIPT_DIR/overseer-host" resolve 2>"$DEP_ERR")" || { OL_REASON=host-unresolved; return 1; }
  [[ -n "$OL_RUNTIME" ]] || { OL_REASON=host-unresolved; return 1; }
}

# ol_runtime_supported — the runtime resolved, and 0 only where it is one
# these launchers can open a session on. Both of them verify the new
# session's account off its tmux pane (lane_account_check reads the pane's
# process environment), so a runtime other than tmux returns 1 with
# OL_REASON=runtime-unsupported and the value in OL_RUNTIME: a provider path
# ORCH_OVERSEER_HOST names is refused before anything opens, never opened
# through and recorded as tmux. Resolution failing is OL_REASON=host-unresolved.
ol_runtime_supported() {
  ol_runtime || return 1
  [[ "$OL_RUNTIME" == tmux ]] || { OL_REASON=runtime-unsupported; return 1; }
}

# ORCH_OVERSEER_PREFERENCE where no settings file names it: the owner's order,
# Opus 5.5 on claude, then GPT-6.1 Sol on codex, each at high effort,
# so an Opus wall moves the overseer onto the next
# model with room, at a mark and at the wall alike. This value is the
# setting's default and the only model order any script holds: the walk reads
# the setting and nothing else, so a new or retired model is an edit to the
# setting and never to a script. Set to empty, the setting names no entries,
# which is a caller's own rule to read.
OL_DEFAULT_PREFERENCE="claude:claude-opus-5-5:high,codex:gpt-6.1-sol:high"
ol_preference() {
  printf '%s\n' "${ORCH_OVERSEER_PREFERENCE-$OL_DEFAULT_PREFERENCE}"
}

# ol_preference_entries VALUE — VALUE, ORCH_OVERSEER_PREFERENCE's or ORCH_LANE_PREFERENCE's
# comma-separated `harness:model:effort` entries, into OL_ENTRIES, with
# OL_NAMED the count. `harness` is claude, codex, copilot or pi; `model` is
# the model the harness's `--model` word takes, on pi its own `provider/id`;
# `effort` is the level as that harness spells it, on pi its thinking level.
# Consumer settings can still name a positive account number. Those entries
# become harness::effort, which ol_entry_model resolves on the caller's model.
# An overseer walk without that model uses the same-harness default entry.
# OL_DEPRECATED_ENTRIES keeps their original spelling for the refresh report.
# One stderr warning per process names the first deprecated entry.
# OL_REFUSED_ENTRIES holds every refused entry; a refusal returns 1 and keeps
# the first in OL_BAD_ENTRY for launchers. Empty VALUE is no entries.
OL_ENTRIES=()
OL_NAMED=0
OL_BAD_ENTRY=""
OL_REFUSED_ENTRIES=()
OL_DEPRECATED_ENTRIES=()
OL_DEPRECATION_WARNED=0
OL_DEPRECATION_CONVERTED=0
ol_preference_entries() { # VALUE
  local rest="$1" entry LC_ALL=C status=0
  OL_ENTRIES=()
  OL_NAMED=0
  OL_BAD_ENTRY=""
  OL_REFUSED_ENTRIES=()
  OL_DEPRECATED_ENTRIES=()
  [[ -z "$rest" ]] || rest+=","
  while [[ -n "$rest" ]]; do
    entry="${rest%%,*}"
    rest="${rest#*,}"
    if [[ "$entry" =~ ^(claude|codex|copilot|pi):[1-9][0-9]*:[a-z]+$ ]]; then
      OL_DEPRECATED_ENTRIES+=("$entry")
      if (( ! OL_DEPRECATION_WARNED )); then
        printf 'preference-deprecated entry=%s form=harness:model:effort\n' "$entry" >&2
        OL_DEPRECATION_WARNED=1
      fi
      entry="${entry%%:*}::${entry##*:}"
    elif ! [[ "$entry" =~ ^(claude|codex|copilot):[a-z][a-z0-9.-]*:[a-z]+$ \
       || "$entry" =~ ^pi:[a-z][a-z0-9.-]*/[a-z0-9][a-z0-9._/-]*:[a-z]+$ ]]; then
      (( status != 0 )) || OL_BAD_ENTRY="$entry"
      OL_REFUSED_ENTRIES+=("$entry")
      status=1
      continue
    fi
    OL_ENTRIES+=("$entry")
    OL_NAMED=$((OL_NAMED + 1))
  done
  return "$status"
}

# ol_account HARNESS MODEL — the account a session of HARNESS on MODEL spends,
# as `lanes` measures it: OL_ACCOUNT_HARNESS the harness `lanes pick` judges it
# under, OL_ACCOUNT_MODEL the model it judges it on. lib/lane-launch.sh §
# lane_pick_harness alone maps a provider to its account: claude, codex and
# copilot spend their own accounts, a pi session on a `github-copilot/` model
# spends the Copilot pool `lanes pick --harness pi` reads, and one on a
# `pi-claude/` model spends a claude account. This function only normalizes
# that answer for a pi session: a claude account is judged on the claude model
# after `pi-claude/` (pi-extensions/pi-claude-bridge), and `unmeasured` splits
# into `none`, a model naming a provider `lanes` measures no account of, and
# `unknown`, one naming no provider or no model at all, pi resolving a bare
# model to a provider itself. A pi model's `:<thinking>` suffix is pi's level,
# never the model. The model is empty for `none` and `unknown`.
OL_ACCOUNT_HARNESS="" OL_ACCOUNT_MODEL=""
ol_account() { # HARNESS MODEL
  local model="${2:-}"
  [[ "${1:-}" != pi ]] || model="${model%%:*}"
  OL_ACCOUNT_HARNESS="$(lane_pick_harness "${1:-}" "$model")" OL_ACCOUNT_MODEL="$model"
  [[ "${1:-}" == pi ]] || return 0
  case "$OL_ACCOUNT_HARNESS" in
    claude) OL_ACCOUNT_MODEL="${model#pi-claude/}" ;;
    unmeasured)
      OL_ACCOUNT_MODEL="" OL_ACCOUNT_HARNESS=unknown
      [[ "$model" != ?*/?* ]] || OL_ACCOUNT_HARNESS=none
      ;;
  esac
}

# ol_pi_model MODEL... — the model a pi session runs, out of the sources that
# can name it given in precedence order, its launch record, its `--model` word
# and its context reading: the first that names its provider, `provider/id`,
# which is what names its account (ol_account), else the first that names a
# model at all, else empty. Pi resolves a bare model to a provider itself, so
# a bare model from any source never outranks one naming its provider, and
# answers only where none does, which ol_account reads as `unknown`.
ol_pi_model() { # MODEL...
  local m
  for m in "$@"; do [[ "$m" != ?*/?* ]] || { printf '%s\n' "$m"; return 0; }; done
  for m in "$@"; do [[ -z "$m" ]] || { printf '%s\n' "$m"; return 0; }; done
  printf '\n'
}

# ol_entry_model ENTRY — one entry ol_preference_entries admitted, split into
# OL_ENTRY_HARNESS, OL_ENTRY_MODEL and OL_ENTRY_EFFORT. A normalized numeric
# entry has no model word and uses the caller's launch or observed model, which
# is spelled for the caller's harness: ol_entry_permitted skips such an entry
# naming another harness rather than hand that spelling to its CLI. The
# setting is the one source of which models the walk tries and in what order,
# so nothing here holds a model list to check a name against: the launch line
# carries the model the entry names, and a name its harness does not know is
# the setting's to fix.
OL_ENTRY_HARNESS="" OL_ENTRY_MODEL="" OL_ENTRY_EFFORT=""
# oversee-succeed supplies the observed model before account measurement,
# which deliberately drops codex's model to judge its binding bucket.
OL_PREFERENCE_CALLER_MODEL=""
ol_entry_model() { # ENTRY
  IFS=: read -r OL_ENTRY_HARNESS OL_ENTRY_MODEL OL_ENTRY_EFFORT <<<"$1"
  [[ -n "$OL_ENTRY_MODEL" ]] || OL_ENTRY_MODEL="${OL_WALK_CALLER_MODEL:-$OL_PREFERENCE_CALLER_MODEL}"
}

# ol_lanes ARGS... — `lanes` as every overseer read of an account asks it,
# under ORCH_LANE_HOST=local: an overseer opens through overseer-host on this
# machine, under this machine's copy of the account, so a provider's reading
# of that account is not the one its session spends. The successor walk and
# the caller's own headroom mark both read through here, so the two never
# judge one account on two copies.
ol_lanes() { # ARGS...
  ORCH_LANE_HOST=local "$SCRIPT_DIR/lanes" "$@"
}

# ol_pick_record HARNESS MODEL TRIGGER [EXCLUDE_DIR] — the one `lanes pick
# --json` over HARNESS at TRIGGER, its record into OL_PICK_RECORD on every
# exit, since exit 3 prints its counts too, and `lanes pick`'s own status
# returned. The pick ol_pick_lane makes and every count a caller holds a
# launch to ask this one question, so no two of them judge an account two
# ways. HARNESS and MODEL are the launch's, and `lanes` is asked about the
# account they spend (ol_account); a launch
# spending none `lanes` measures, or one nothing can name, returns 4 with no
# record and asks nothing.
# It passes --for-overseer: the pick seats an overseer, so the accounts
# fleets record for their overseers, which a lane pick omits, stay candidates.
OL_PICK_RECORD=""
ol_pick_record() { # HARNESS MODEL TRIGGER [EXCLUDE_DIR]
  local floor=() exclude=() rc=0 harness model LC_ALL=C
  OL_PICK_RECORD=""
  ol_account "$1" "$2"
  harness="$OL_ACCOUNT_HARNESS" model="$OL_ACCOUNT_MODEL"
  ol_account_measured "$harness" || return 4
  [[ -n "$(lane_context_mark_model "$harness" "$model")" ]] || floor=(--binding-floor)
  [[ -z "${4:-}" ]] || exclude=(--exclude-lane "$4")
  OL_PICK_RECORD="$(ol_lanes pick --harness "$harness" --min-headroom-pct "$3" --for-overseer \
    ${floor[@]+"${floor[@]}"} ${exclude[@]+"${exclude[@]}"} ${model:+--model "$model"} --json 2>"$DEP_ERR")" || rc=$?
  return "$rc"
}

# ol_pick_lane HARNESS MODEL TRIGGER [EXCLUDE_DIR] — the config dir `lanes
# pick` names for HARNESS, into OL_PICKED_DIR. MODEL is the one the launched
# session will run, empty where nothing names one: the bound is judged on the
# bucket that walls THAT model. The pick is held to the reading the SESSION
# will take of itself at its own account mark, so it is never opened onto an
# account its first judgement reads as spent: lib/lane-context.sh names that
# reading, a claude line naming its model and a codex line none, and the pick
# adds `--binding-floor` where the line names none.
#
# Returns `lanes pick`'s own status: 0 with a lane, 3 where none of that
# harness clears TRIGGER, which a caller skips the entry on, and anything
# else as the judge failing. On 3 the `walled` and `unmeasured` counts join
# OL_WALKED_WALLED and OL_WALKED_UNMEASURED for the refusal a caller prints
# when the walk ends empty; a record carrying neither leaves them alone.
#
# A launch spending no account `lanes` measures (ol_account's `none`), a pi
# model on a provider neither pi-claude nor the Copilot pool, returns 0 with
# OL_PICKED_DIR empty: no account can be picked or
# refused for it, so it launches with no lane variable, and its first working
# turn, which ol_session_verify waits for, is the one reading of its room. A pi
# model naming no provider names no account to pick either, and returns 4.
OL_PICKED_DIR=""
OL_WALKED_WALLED=0
OL_WALKED_UNMEASURED=0
ol_pick_lane() { # HARNESS MODEL TRIGGER [EXCLUDE_DIR]
  local record rc=0 walled unmeasured LC_ALL=C
  OL_PICKED_DIR=""
  ol_account "$1" "$2"
  [[ "$OL_ACCOUNT_HARNESS" != none ]] || return 0
  ol_pick_record "$@" || rc=$?
  record="$OL_PICK_RECORD"
  if (( rc == 3 )); then
    walled="$(jq -r '.walled // empty' <<<"$record" 2>/dev/null)" || walled=""
    unmeasured="$(jq -r '.unmeasured // empty' <<<"$record" 2>/dev/null)" || unmeasured=""
    [[ ! "$walled" =~ ^[0-9]+$ ]] || OL_WALKED_WALLED=$((OL_WALKED_WALLED + 10#$walled))
    [[ ! "$unmeasured" =~ ^[0-9]+$ ]] || OL_WALKED_UNMEASURED=$((OL_WALKED_UNMEASURED + 10#$unmeasured))
  fi
  (( rc == 0 )) || return "$rc"
  OL_PICKED_DIR="$(jq -r '.config_dir // empty' <<<"$record" 2>"$DEP_ERR")" || return 1
  [[ -n "$OL_PICKED_DIR" ]] || return 1
}

# ol_account_id DIR — one account directory as its comparable identity, empty
# for an empty input. The pairing is lib/lane-launch.sh's own, the one
# lane_account_check compares an observed account against a picked one with:
# lane_launch_home_account turns a private codex launch home back into the
# account it was built under, and lane_claims_canon resolves the path, so an
# account spelled two ways is one account.
ol_account_id() { # DIR
  [[ -n "$1" ]] || return 0
  lane_claims_canon "$(lane_launch_home_account "$1")"
}

# ol_walk TRIGGER EXCLUDE_DIR ENTRY... — the account walk every overseer
# launch takes, a first launch and a succession alike: ENTRY... in order, the
# first that names a lane into OL_CHOSEN, with OL_HARNESS, OL_MODEL,
# OL_EFFORT and OL_LANE_DIR beside it and OL_PICK_MODEL the model its pick was
# judged on. A named entry's pick is judged on the bucket that walls the model
# the entry names (ol_entry_model), the model its launch passes; ol_pick_lane
# picks at TRIGGER, leaving EXCLUDE_DIR out, and its exit 3 skips the entry.
# An entry spending no account `lanes` measures takes no pick and no lane
# (ol_pick_lane).
#
# The entry `caller` is a predecessor's own, as OL_WALK_CALLER_* describe it:
# its harness, its lane, the model and effort its record pairs, empty where
# the record names no model, and the model its pick is judged on, the one the
# predecessor already runs. It keeps its own lane unpicked where
# OL_WALK_CALLER_KEEP is 1. A pi predecessor whose model names no provider
# spends an account nothing names (ol_account), so its entry refuses
# pi-account-unknown rather than launch a successor no pick holds off a spent
# account. OL_FALLBACK_WALKED names the harness it swept, or `none` where the
# walk never reached it.
#
# A named entry is launched under a permission posture its source allows
# (ol_entry_permitted), and skipped before its pick where it cannot be. A
# Copilot entry installs the shared context reader before it can be chosen,
# including a retained caller account. A failed setup skips the entry as
# successor-status-line, with the installer detail and fallback cause.
# The rules a succession adds, each off while its setting is
# empty or 0: each skip is a notice for the caller to print, one line of
# tab-separated key and fields in OL_WALK_SKIPS.
#   OL_WALK_REFUSE_ID       a pick naming this account (ol_account_id) is
#                           skipped as successor-lane-spent: the backstop for
#                           an inventory that still names EXCLUDE_DIR
#   OL_WALK_SUCCESSOR_BOUND a pick is skipped where the successor opened on it
#                           would read other accounts above TRIGGER, the lane
#                           picked counted in, and that count stays at or
#                           below the bound; a successor on no measured
#                           account reads no count and settles nothing
#
# Returns 0 with an entry chosen, 3 where none qualifies, the counts in
# OL_WALKED_WALLED and OL_WALKED_UNMEASURED, and 1 with OL_REASON
# lanes-failed or pi-account-unknown and its fields in OL_FIELDS, the
# dependency's words in DEP_ERR.
OL_WALK_CALLER_HARNESS="" OL_WALK_CALLER_LANE="" OL_WALK_CALLER_MODEL="" OL_WALK_CALLER_EFFORT=""
OL_WALK_CALLER_PICK_MODEL="" OL_WALK_CALLER_KEEP=0
OL_WALK_SOURCE_HARNESS="" OL_WALK_SOURCE_FLAGS="" OL_WALK_SOURCE_ROWS=0 OL_WALK_REFUSE_ID="" OL_WALK_SUCCESSOR_BOUND=0
OL_CHOSEN="" OL_HARNESS="" OL_MODEL="" OL_EFFORT="" OL_PICK_MODEL="" OL_LANE_DIR="" OL_FALLBACK_WALKED=none
OL_WALK_SKIPS=() OL_FIELDS=()
ol_walk() { # TRIGGER EXCLUDE_DIR ENTRY...
  local trigger="$1" exclude="$2" entry rc count defaults default_entry tab=$'\t'
  shift 2
  OL_CHOSEN="" OL_LANE_DIR="" OL_FALLBACK_WALKED=none OL_WALK_SKIPS=() OL_FIELDS=()
  for entry in "$@"; do
    if [[ "$entry" == caller ]]; then
      OL_HARNESS="$OL_WALK_CALLER_HARNESS" OL_MODEL="$OL_WALK_CALLER_MODEL" OL_EFFORT="$OL_WALK_CALLER_EFFORT"
      OL_PICK_MODEL="$OL_WALK_CALLER_PICK_MODEL" OL_FALLBACK_WALKED="${OL_WALK_CALLER_HARNESS:-none}"
      ol_account "$OL_HARNESS" "$OL_PICK_MODEL"
      if [[ "$OL_ACCOUNT_HARNESS" == unknown ]]; then
        OL_REASON=pi-account-unknown OL_FIELDS=("model=${OL_PICK_MODEL:-none}")
        return 1
      fi
      if (( OL_WALK_CALLER_KEEP )); then
        OL_LANE_DIR="$OL_WALK_CALLER_LANE" OL_CHOSEN=caller
        if [[ "$OL_HARNESS" == copilot ]] && ! copilot_context_install "$OL_LANE_DIR"; then
          OL_WALK_SKIPS+=("successor-status-line${tab}lane=$OL_LANE_DIR${tab}entry=$entry${tab}detail=$COPILOT_CONTEXT_DETAIL${tab}cause=${COPILOT_CONTEXT_CAUSE:-none}")
          OL_CHOSEN=""
          continue
        fi
        return 0
      fi
    else
      ol_entry_model "$entry"
      if [[ -z "$OL_ENTRY_MODEL" ]]; then
        defaults="$OL_DEFAULT_PREFERENCE,"
        while [[ -n "$defaults" ]]; do
          default_entry="${defaults%%,*}" defaults="${defaults#*,}"
          [[ "${default_entry%%:*}" == "$OL_ENTRY_HARNESS" ]] || continue
          OL_ENTRY_MODEL="${default_entry#*:}" OL_ENTRY_MODEL="${OL_ENTRY_MODEL%%:*}"
          break
        done
      fi
      OL_HARNESS="$OL_ENTRY_HARNESS" OL_MODEL="$OL_ENTRY_MODEL" OL_EFFORT="$OL_ENTRY_EFFORT"
      OL_PICK_MODEL="$OL_ENTRY_MODEL"
      ol_entry_permitted "$entry" || continue
    fi
    rc=0
    ol_pick_lane "$OL_HARNESS" "$OL_PICK_MODEL" "$trigger" "$exclude" || rc=$?
    case "$rc" in
      0) ;;
      3) continue ;;
      *) OL_REASON=lanes-failed OL_FIELDS=("entry=$entry" "exit=$rc"); return 1 ;;
    esac
    if [[ -n "$OL_WALK_REFUSE_ID" && "$(ol_account_id "$OL_PICKED_DIR")" == "$OL_WALK_REFUSE_ID" ]]; then
      OL_WALK_SKIPS+=("successor-lane-spent${tab}lane=$exclude${tab}entry=$entry")
      continue
    fi
    if [[ "$OL_HARNESS" == copilot ]] && ! copilot_context_install "$OL_PICKED_DIR"; then
      OL_WALK_SKIPS+=("successor-status-line${tab}lane=$OL_PICKED_DIR${tab}entry=$entry${tab}detail=$COPILOT_CONTEXT_DETAIL${tab}cause=${COPILOT_CONTEXT_CAUSE:-none}")
      continue
    fi
    if (( OL_WALK_SUCCESSOR_BOUND > 0 )); then
      [[ -n "$OL_PICKED_DIR" ]] || continue
      rc=0
      ol_pick_record "$OL_HARNESS" "$OL_PICK_MODEL" "$trigger" "$OL_PICKED_DIR" || rc=$?
      case "$rc" in
        0|3) ;;
        *) OL_REASON=lanes-failed OL_FIELDS=("entry=$entry" "exit=$rc" step=successor-count); return 1 ;;
      esac
      count="$(jq -r '.qualifying_count // empty' <<<"$OL_PICK_RECORD" 2>"$DEP_ERR")" || count=""
      case "$count" in
        '' | *[!0-9]*) OL_REASON=lanes-failed OL_FIELDS=("entry=$entry" step=successor-count); return 1 ;;
      esac
      if (( count > 0 && count + 1 <= OL_WALK_SUCCESSOR_BOUND )); then continue; fi
    fi
    OL_LANE_DIR="$OL_PICKED_DIR" OL_CHOSEN="$entry"
    if [[ "$entry" == *::* ]] && (( ! OL_DEPRECATION_CONVERTED )); then
      if [[ -n "$OL_MODEL" ]]; then
        printf 'preference-deprecated-conversion replacement=%s:%s:%s\n' "$OL_HARNESS" "$OL_MODEL" "$OL_EFFORT" >&2
      else
        printf 'preference-deprecated-conversion harness=%s model=harness-default (the harness default model runs)\n' "$OL_HARNESS" >&2
      fi
      OL_DEPRECATION_CONVERTED=1
    fi
    return 0
  done
  return 3
}

# ol_entry_permitted ENTRY — whether ol_walk may launch ENTRY, of harness
# OL_HARNESS, under the posture its source allows, a skip notice queued in
# OL_WALK_SKIPS where it may not. A first launch, OL_WALK_SOURCE_HARNESS empty,
# needs the full-bypass word the harness row writes, and a row naming none,
# pi's, has no unattended launch to open: entry-permission-unwritable. An
# entry of another harness than its source needs that word too, and the
# source's posture to cross to it: OL_WALK_SOURCE_FLAGS held to exactly one
# transferable posture (lib/lane-launch.sh §
# launch_choice_permission_transferable), entry-permission-untransferable
# where not; with OL_WALK_SOURCE_ROWS 1, a judgement handed no permission
# words, the source row naming a transferable posture, and a skip says
# nothing. So no posture crosses to or from pi, whose row names none. A
# numeric entry of another harness than its source is skipped the same way,
# with `model=` naming the caller's model: that model is spelled for the
# source harness (copilot's `claude-opus-5.5` is claude's `claude-opus-5-5`),
# and no table here translates one harness's spelling into another's.
ol_entry_permitted() { # ENTRY
  local tab=$'\t'
  if [[ -z "$OL_WALK_SOURCE_HARNESS" ]]; then
    launch_choice_permission_write "$OL_HARNESS" >/dev/null && return 0
    OL_WALK_SKIPS+=("entry-permission-unwritable${tab}entry=$1${tab}harness=$OL_HARNESS")
    return 1
  fi
  [[ "$OL_HARNESS" != "$OL_WALK_SOURCE_HARNESS" ]] || return 0
  if [[ "$1" == *::* ]]; then
    (( OL_WALK_SOURCE_ROWS )) \
      || OL_WALK_SKIPS+=("entry-permission-untransferable${tab}entry=$1${tab}source=$OL_WALK_SOURCE_HARNESS${tab}target=$OL_HARNESS${tab}model=${OL_MODEL:-none}")
    return 1
  fi
  if launch_choice_permission_write "$OL_HARNESS" >/dev/null; then
    if (( OL_WALK_SOURCE_ROWS )); then
      [[ -z "$(launch_choice_transfer_permission_spellings "$OL_WALK_SOURCE_HARNESS")" ]] || return 0
    elif launch_choice_permission_transferable "$OL_WALK_SOURCE_HARNESS" "$OL_WALK_SOURCE_FLAGS"; then
      return 0
    fi
  fi
  (( OL_WALK_SOURCE_ROWS )) \
    || OL_WALK_SKIPS+=("entry-permission-untransferable${tab}entry=$1${tab}source=$OL_WALK_SOURCE_HARNESS${tab}target=$OL_HARNESS")
  return 1
}

# ol_launch_flags [--question-off] HARNESS MODEL EFFORT PICK_MODEL SOURCE
# [FLAG...] — the flag words of one overseer launch, as argv into OL_FLAGS,
# for ol_command_line to write, whether it is a first launch or a successor:
# MODEL and EFFORT written from HARNESS's row of lib/lane-launch.sh's table,
# then SOURCE's words FLAG... as HARNESS may take them, the predecessor's
# harness and flags, both empty on a first launch. An entry with neither
# MODEL nor EFFORT keeps every predecessor word. A numeric first-launch
# entry without a same-harness default names EFFORT alone. One of the same harness strips
# the predecessor's model and effort and keeps its permission words exactly.
# One of another harness, a first launch among them, writes HARNESS's
# full-bypass permission words and keeps no predecessor word at all: its
# posture must transfer (launch_choice_permission_transferable), and every
# other word is spelled for the predecessor's CLI, a run-mode word such as
# copilot's `--autopilot` or a count beside it among them. The words
# kept are led by the harness's launch settings, the compaction words for the
# model the launch runs (MODEL, else the one the kept words name, else
# PICK_MODEL) and, with --question-off, its question-tool words
# (launch_choice_lead_settings). Returns 1 with OL_REASON
# launch-choice-failed, or model-window-unknown where a claude model has no
# window named, and its fields in OL_FIELDS.
OL_FLAGS=()
ol_launch_flags() { # [--question-off] HARNESS MODEL EFFORT PICK_MODEL SOURCE [FLAG...]
  local question=() words lead_model
  if [[ "$1" == --question-off ]]; then question=(--question-off); shift; fi
  local harness="$1" model="$2" effort="$3" pick_model="$4" source="$5"
  shift 5
  OL_FLAGS=() OL_FIELDS=()
  OL_REASON=launch-choice-failed
  words="$(launch_choice_write "$harness" "$model" "$effort")" || { OL_FIELDS=("harness=$harness"); return 1; }
  [[ -z "$words" ]] || eval "OL_FLAGS=($words)"
  if [[ -z "$model" && -z "$effort" ]]; then
    LAUNCH_CHOICE_KEPT=("$@")
  elif [[ "$harness" == "$source" ]]; then
    launch_choice_strip "$source" "$@" || { OL_FIELDS=("harness=$source"); return 1; }
  else
    OL_FIELDS=(reason=permission-transfer "source=${source:-none}" "target=$harness")
    [[ -z "$source" ]] || launch_choice_permission_transferable "$source" "$*" || return 1
    words="$(launch_choice_permission_write "$harness")" || return 1
    eval "OL_FLAGS+=($words)"
    LAUNCH_CHOICE_KEPT=()
    OL_FIELDS=()
  fi
  lead_model="$model"
  [[ -n "$lead_model" ]] || lead_model="$(launch_choice_value "$(launch_choice_model_spellings "$harness")" \
    "${LAUNCH_CHOICE_KEPT[*]+${LAUNCH_CHOICE_KEPT[*]}}")"
  [[ -n "$lead_model" ]] || lead_model="$pick_model"
  launch_choice_lead_settings ${question[@]+"${question[@]}"} ${lead_model:+--model "$lead_model"} \
    "$harness" ${LAUNCH_CHOICE_KEPT[@]+"${LAUNCH_CHOICE_KEPT[@]}"}
  if [[ "$LAUNCH_CHOICE_COMPACTION" == no-window ]]; then
    OL_REASON=model-window-unknown OL_FIELDS=("model=$lead_model")
    return 1
  fi
  OL_FLAGS+=(${LAUNCH_CHOICE_KEPT[@]+"${LAUNCH_CHOICE_KEPT[@]}"})
}

# ol_command_line HARNESS HANDOFF LANE_DIR LAUNCH_DIR FLAG... — the whole
# command the session runs, into OL_CMD: the harness, FLAG... each quoted,
# and the brief naming HANDOFF; OL_LANE_VAR is the account variable the
# harness reads, OL_LAUNCH_HOME the home the launch runs under and OL_FORM
# the form the lane reaches the harness by (lib/lane-launch.sh). OL_IDENTITY
# is the launch identity the command carries (ol_identity), the model and
# effort read out of FLAG... by lib/lane-launch.sh's own readers, a pi model
# with the provider a split `--provider` word names, so the
# record a launch writes names what the line runs and nothing a caller
# restated beside it. An identity jq could not build is left empty, which the
# record writers refuse as their own step rather than record as unknown.
#
# The brief crosses the pane's shell inside single quotes, so it holds only
# shell-inert characters, and HANDOFF is held to the same alphabet by every
# caller. One plain sentence on claude and codex, the contract each of them
# already reads as its opening prompt; pi opens on its skill command, as
# open-terminal's pi lane brief does. The account variable is
# lib/lane-launch.sh § lane_env_prefix's for the harness and the model FLAG...
# names: pi's is claude's, which the pi-claude bridge reads, and
# PI_CODING_AGENT_DIR on the Copilot pool. An empty LANE_DIR, which ol_walk
# hands on for a pi model on a provider no lane measures (ol_pick_lane),
# launches the command bare.
#
# A codex session reads folder trust for LAUNCH_DIR before it reads its own
# arguments, and the pane it opens in has nobody at it, so the entry is made
# through the builder `open-terminal` uses; a launch whose entry could not be
# made returns 1 with OL_REASON=launch-trust-missing, the builder's reason
# in OL_TRUST_REASON and its dependency's own words, where the refusal has
# any, in DEP_ERR for the caller's refusal to print, rather than opening on
# the question. The lane reaches
# the harness through the same builder too: on a host whose `claude` is an
# account shim, an env prefix in front of it is overwritten for the shim's
# own name and the session starts on the bare account with nothing on screen
# saying so.
#
# The brief is a positional prompt on claude and codex; copilot takes it as
# the value of `-i`, which starts the interactive session and submits it.
OL_CMD="" OL_LANE_VAR="" OL_LAUNCH_HOME="" OL_FORM="" OL_TRUST_REASON="" OL_TRUST_ROUTE=""
ol_command_line() { # HARNESS HANDOFF LANE_DIR LAUNCH_DIR FLAG...
  local harness="$1" handoff="$2" lane_dir="$3" launch_dir="$4" flag cmd brief brief_flag="" model
  shift 4
  brief="Read .agents/skills/orch/SKILL.md and execute the orch oversee workflow after reading the overseer handoff at $handoff"
  case "$harness" in
    claude) cmd="claude -n overseer" ;;
    copilot) cmd="copilot" brief_flag=" -i" ;;
    pi) cmd="pi" brief="/skill:orch oversee after reading the overseer handoff at $handoff" ;;
    *) cmd="codex" ;;
  esac
  model="$(launch_choice_launch_model "$harness" "$*")"
  OL_LANE_VAR="$(lane_env_prefix "$harness" - "$model")"
  OL_LANE_VAR="${OL_LANE_VAR%%=*}"
  for flag in "$@"; do
    cmd+=" $(printf %q "$flag")"
  done
  cmd+="$brief_flag '$brief'"
  if ! lane_trust_prepare "$harness" "$lane_dir" "$launch_dir"; then
    OL_REASON=launch-trust-missing
    OL_TRUST_REASON="$LANE_TRUST_REASON"
    printf '%s' "$LANE_TRUST_DETAIL" > "$DEP_ERR"
    return 1
  fi
  OL_TRUST_ROUTE="${LANE_TRUST_ROUTE:-none}"
  # Always a path where a lane was picked: lane_trust_prepare returns
  # the lane or a home under it.
  OL_LAUNCH_HOME="$LANE_TRUST_HOME"
  OL_FORM="$(lane_launch_form "$cmd" "$harness" "$OL_LAUNCH_HOME" "")"
  OL_CMD="$cmd"
  [[ -z "$OL_LAUNCH_HOME" ]] || OL_CMD="$(lane_launch_line "$cmd" "$harness" "$OL_LANE_VAR" "$OL_LAUNCH_HOME" "$OL_FORM")"
  ol_identity "$harness" "$lane_dir" "$OL_LAUNCH_HOME" "$model" \
    "$(launch_choice_effort "$harness" "$*")" "$launch_dir" || OL_IDENTITY=""
}

# The jq definitions every reader and writer of the record shares, so none
# spells a question a second time: `ol_identity` is the launch identity an
# object carries, its six fields in their one order.
# `ol_names($server; $start; $session)` is whether a record names that
# session on that server, the pane on tmux and the session elsewhere. $start
# is the start ol_session_start printed for that session's server, empty
# where it could not be read: ol_names names the session only on the server
# started at the record's `server_start`, since after a tmux restart a new
# server may be handed the recorded pid and numbers its panes from %0 again,
# and never from a record carrying no start. ol_record_current, the
# generation bump, the exit writes and oversee-watch's identification take
# that strict answer; `oversee launch` takes it beside ol_owns for its
# liveness refusal.
# `ol_unstarted($server; $session)` is a record naming that session on that
# server with no start at all, which no current writer leaves but a record
# written before starts were recorded, or put back whole by
# ol_record_restore, still is. The session in that pane is the one the
# record was written for. The lane-mail-check hook's identification and
# lane-mail's peer reader ask it rather than read an empty start.
# `ol_owns($server; $start; $session)` is either answer: the record is that
# session's, bound or unstarted. Its readers are the two writers that bind an
# unstarted record to its session instead of reading it as another
# session's: the watch start (lib/watch-overseer-record.sh §
# overseer_command_record), which keeps its launch identity, and
# ol_record_heal, which the lane-mail-check hook runs from the overseer's
# turn ends and tool calls; `oversee launch` reads it for its liveness
# refusal, so a live pane a startless record names blocks a second overseer.
OL_JQ_DEFS='def ol_identity: {harness, account, home, model, effort, cwd};
  def ol_names($server; $start; $session): type == "object" and (.server // "") == $server
    and ((.pane // .session // "") == $session)
    and (.server_start | tostring) == $start;
  def ol_unstarted($server; $session): type == "object" and (.server // "") == $server
    and ((.pane // .session // "") == $session)
    and .server_start == null;
  def ol_owns($server; $start; $session): ol_names($server; $start; $session) or ol_unstarted($server; $session);'

# ol_session_start SERVER SESSION — the start ol_names judges SESSION on
# SERVER by: tmux_server_start's for a pane. Returns 1, printing nothing, where
# it cannot be read, and each caller states what an unread start does: one
# judged as no start would read a record bound to this very session as
# another session's.
ol_session_start() { # SERVER SESSION
  tmux_server_start "$2" "$1"
}

# ol_identity HARNESS ACCOUNT HOME MODEL EFFORT CWD — the launch identity into
# OL_IDENTITY as the JSON object the record carries, null for each field the
# launch does not know. ACCOUNT is the account folder a lane pick names and
# HOME the directory the harness variable carries: the same folder for claude,
# and for codex a private CODEX_HOME built under the account where folder
# trust needed one (lib/lane-home.sh), so both are kept and neither is read
# back from the other. Returns 1 with jq's words in DEP_ERR.
OL_IDENTITY=""
ol_identity() { # HARNESS ACCOUNT HOME MODEL EFFORT CWD
  OL_IDENTITY="$(jq -cn --arg harness "$1" --arg account "$2" --arg home "$3" \
    --arg model "$4" --arg effort "$5" --arg cwd "$6" \
    "$OL_JQ_DEFS"' $ARGS.named | ol_identity | map_values(if . == "" then null else . end)' 2>"$DEP_ERR")"
}

# ol_record_line_identity LINE — into OL_IDENTITY, the launch identity OL_PRIOR
# records for LINE: the pending successor's where LINE is its line, the
# current session's where LINE is that one's, and every field null where the
# record holds neither. A relaunch that replays a recorded line builds no
# command of its own, and this is the identity that line was built with.
ol_record_line_identity() { # LINE
  OL_IDENTITY="$(jq -c --arg line "$1" "$OL_JQ_DEFS"'
      if type == "object" and (.pending.launch_line // null) == $line then .pending | ol_identity
      elif type == "object" and (.launch_line // null) == $line then ol_identity
      else null | ol_identity end' <<<"${OL_PRIOR:-null}" 2>"$DEP_ERR")"
}

# ol_checkout_sync CWD — the checkout CWD lies in fast-forwarded to the
# origin head of its base branch through `sync-base`, the one owner of that
# fast-forward, so a merged hook, render or orch script is what a session
# opened there loads. It runs at the handoff, just before `create`: in a
# succession the predecessor still runs in that checkout, waiting on its
# succession call, or is dead or walled. A succession abandoned after the
# sync leaves the predecessor on the fast-forwarded tree, as a `sync-base`
# run there after a merge does, and the launcher that called it, its own
# source already loaded, calls the moved helpers for the rest of its run. The
# checkout must have the base branch checked out, since `sync-base` moves
# that branch wherever it is checked out, or its ref where it is checked out
# nowhere, and would leave a tree on any other branch where it stands.
#
# `sync-base` runs under ORCH_OVERSEER_SYNC_TIMEOUT_S seconds, 60 by
# default, which the github skill's kendex_github_run_bounded holds. Its
# fetch never prompts for a credential and gives up on an HTTP transfer
# slower than 1000 bytes a second for 30 seconds. An origin that stalls is
# then one more refusal, and the watch's dead-pane and walled-pane recovery,
# which runs a launch with no bound of its own, still opens a successor.
#
# Returns 0 with the tree at that head, and 1 with OL_REASON=checkout-unsynced,
# the tree left as it stood. OL_SYNC_CAUSE is `not-worktree` for a directory
# in no Git worktree, `base-unresolved` where resolve-base-branch named no
# base, `off-base` for another branch or a detached head and `head-unread`
# where the head could not be read, all found before `sync-base` runs;
# `sync-timeout` where the bound cut `sync-base` off; the key of the first
# line of its stderr that starts `sync-base: `, which may follow Git's own
# lines, such as a merge's `Already up to date.`: `dirty`,
# `fast-forward-failed` for a diverged base or an untracked or ignored file
# in the way, `base-mismatch` for a base ahead of its origin, `fetch-failed`
# and the rest of its keys; or `sync-failed` where it exited nonzero with no
# such line. OL_SYNC_PATH is the checkout, OL_SYNC_FIX what clears the cause,
# and the dependency's own lines are in DEP_ERR. The fix texts are this
# table's alone, so both launchers name one, and name no path: the fleet log
# row that carries one is bounded by ORCH_FLEET_LOG_ROW_BYTES, and the session
# reading it starts in that checkout.
OL_SYNC_CAUSE="" OL_SYNC_PATH="" OL_SYNC_FIX=""
ol_checkout_sync() { # CWD
  local base="" branch="" rc=0 seconds="${ORCH_OVERSEER_SYNC_TIMEOUT_S:-60}"
  local run='then run .agents/skills/orch/scripts/sync-base'
  OL_SYNC_CAUSE="" OL_SYNC_PATH="" OL_SYNC_FIX=""
  if ! OL_SYNC_PATH="$(git -C "$1" rev-parse --show-toplevel 2>"$DEP_ERR")"; then
    OL_SYNC_PATH="$1" OL_SYNC_CAUSE=not-worktree
  elif ! base="$("$SCRIPT_DIR/resolve-base-branch" "$OL_SYNC_PATH" 2>"$DEP_ERR")"; then
    OL_SYNC_CAUSE=base-unresolved
  else
    branch="$(git -C "$OL_SYNC_PATH" symbolic-ref --quiet --short HEAD 2>"$DEP_ERR")" || rc=$?
    case "$rc" in
      0) [[ "$branch" == "$base" ]] || OL_SYNC_CAUSE=off-base ;;
      1) OL_SYNC_CAUSE=off-base branch="a detached head" ;;
      *) OL_SYNC_CAUSE=head-unread ;;
    esac
  fi
  if [[ -z "$OL_SYNC_CAUSE" ]]; then
    # Sourced on its one consumer's path, through the path lib/gh-auth.sh
    # reaches the github skill by: lanes, open-terminal and lane-mail source
    # this file for its other functions. Only the bound answers 124: neither
    # sync-base nor git exits so.
    # shellcheck source=../../../github/scripts/lib/bounded.sh
    source "${BASH_SOURCE[0]%/*}/../../../github/scripts/lib/bounded.sh"
    rc=0
    kendex_github_run_bounded "$seconds" \
      env GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=30 \
      "$SCRIPT_DIR/sync-base" "$OL_SYNC_PATH" >/dev/null 2>"$DEP_ERR" || rc=$?
    if ((rc == 124)); then
      OL_SYNC_CAUSE=sync-timeout
    elif ((rc != 0)); then
      OL_SYNC_CAUSE="$(awk 'index($0, "sync-base: ") == 1 { $0 = substr($0, 12); sub(/ .*/, ""); print; exit }' "$DEP_ERR")" \
        || OL_SYNC_CAUSE=""
      OL_SYNC_CAUSE="${OL_SYNC_CAUSE:-sync-failed}"
    fi
  fi
  [[ -n "$OL_SYNC_CAUSE" ]] || return 0
  case "$OL_SYNC_CAUSE" in
    not-worktree) OL_SYNC_FIX="open the overseer in a Git checkout of its repository's base branch" ;;
    base-unresolved) OL_SYNC_FIX="clear what resolve-base-branch refused for this checkout, $run" ;;
    off-base) OL_SYNC_FIX="switch from $branch to $base, $run" ;;
    head-unread) OL_SYNC_FIX="repair the checkout's HEAD so git can read it, $run" ;;
    sync-timeout) OL_SYNC_FIX="check that origin answers a fetch inside ${seconds}s, $run" ;;
    dirty) OL_SYNC_FIX="commit or discard the tracked changes, $run" ;;
    fast-forward-failed) OL_SYNC_FIX="bring $base back onto origin/$base or move the untracked or ignored file the merge would overwrite, $run" ;;
    base-mismatch) OL_SYNC_FIX="bring $base back onto origin/$base, $run" ;;
    sync-failed) OL_SYNC_FIX="clear the failure sync-base printed, $run" ;;
    *) OL_SYNC_FIX="clear the cause sync-base names, $run" ;;
  esac
  OL_REASON=checkout-unsynced
  return 1
}

# ol_checkout_notice — ol_checkout_sync's refusal as the caller's
# `checkout-unsynced cause= path= fix=` line on stderr, the dependency's lines
# relayed under it, and that line without its path as one fleet log row
# (ol_fleet_log_notice), which the next overseer reads at takeover. The row
# leaves the path out: it is the checkout its reader starts in, and a row is
# bounded by ORCH_FLEET_LOG_ROW_BYTES. The launch goes on whatever becomes of
# the row.
ol_checkout_notice() {
  message checkout-unsynced "cause=$OL_SYNC_CAUSE" "path=$OL_SYNC_PATH" "fix=$OL_SYNC_FIX" >&2
  [[ ! -s "$DEP_ERR" ]] || cat -- "$DEP_ERR" >&2
  ol_fleet_log_notice checkout-unsynced "cause=$OL_SYNC_CAUSE" "fix=$OL_SYNC_FIX"
}

# ol_session_open CWD NAME LINE PLACEMENT — the runtime's `create`: a session
# named NAME with its shell in CWD running LINE under `overseer-run`, which
# writes the harness's exit status into the session record once LINE returns
# (ol_record_exit), placed by PLACEMENT, which is
# `--after SESSION` for a successor in its predecessor's session or `--session
# NAME` for a first launch into a tmux session. The checkout is synced first
# (ol_checkout_sync), whichever launcher opens it; a sync that refuses is
# ol_checkout_notice, and the session opens on the tree as it stands. Into
# OL_SESSION, OL_WINDOW and OL_SERVER. Returns 1 with OL_REASON=create-failed;
# the provider's own line is in DEP_ERR.
#
# OL_OPEN_OUT holds the provider's raw answer from the moment the call
# returns, before it is parsed: a signal that lands during `create` runs its
# trap once the call returns, and a trap that closes a session opened by a
# call the signal interrupted reads it from there through
# ol_session_from_out.
OL_SESSION="" OL_WINDOW="" OL_SERVER="" OL_OPEN_OUT=""
ol_session_open() { # CWD NAME LINE PLACEMENT_FLAG PLACEMENT_VALUE
  OL_SESSION="" OL_WINDOW="" OL_SERVER="" OL_OPEN_OUT=""
  ol_checkout_sync "$1" || ol_checkout_notice
  OL_OPEN_OUT="$("$SCRIPT_DIR/overseer-host" create --cwd "$1" --name "$2" "$4" "$5" \
    --line "$(lane_single_quote "$SCRIPT_DIR/overseer-run") $3" 2>"$DEP_ERR")" \
    || { OL_REASON=create-failed; return 1; }
  ol_session_from_out
  [[ -n "$OL_SESSION" && -n "$OL_WINDOW" ]] || { OL_REASON=create-failed; return 1; }
}
# The three fields of a `create` answer, out of OL_OPEN_OUT.
ol_session_from_out() {
  local word
  for word in $OL_OPEN_OUT; do
    case "$word" in
      session=*) OL_SESSION="${word#session=}" ;;
      window=*) OL_WINDOW="${word#window=}" ;;
      server=*) OL_SERVER="${word#server=}" ;;
    esac
  done
}

# ol_session_inspect SESSION [--launch] — the runtime's `inspect`, which the
# launch's live-overseer check, the succession's read of its caller and its
# wait for the caller to close, and the watch's per-pass overseer read take.
# The keyed line's state, server, window, cause and probe go into
# OL_INSPECT_STATE, OL_INSPECT_SERVER, OL_INSPECT_WINDOW, OL_INSPECT_CAUSE and
# OL_INSPECT_PROBE, each empty where the line names none, and window and
# server the word `none` for a session the runtime no longer lists; the line
# itself into OL_INSPECT_LINE and the snapshot under it into OL_DETAIL.
# OL_INSPECT_CAUSE is the comma-separated scans the judge could not run, and
# OL_INSPECT_PROBE the child probe's exit status where one of them is
# `process-probe`. Returns 1 with OL_REASON=inspect-failed; the provider's own
# line is in DEP_ERR.
OL_INSPECT_STATE="" OL_INSPECT_SERVER="" OL_INSPECT_WINDOW="" OL_INSPECT_CAUSE="" OL_INSPECT_PROBE="" OL_INSPECT_LINE=""
ol_session_inspect() { # SESSION [--launch]
  local out word
  OL_INSPECT_STATE="" OL_INSPECT_SERVER="" OL_INSPECT_WINDOW="" OL_INSPECT_CAUSE="" OL_INSPECT_PROBE="" OL_DETAIL=""
  out="$("$SCRIPT_DIR/overseer-host" inspect --session "$1" ${2:+"$2"} 2>"$DEP_ERR")" \
    || { OL_REASON=inspect-failed; return 1; }
  OL_INSPECT_LINE="${out%%$'\n'*}"
  for word in $OL_INSPECT_LINE; do
    case "$word" in
      state=*) OL_INSPECT_STATE="${word#state=}" ;;
      server=*) OL_INSPECT_SERVER="${word#server=}" ;;
      window=*) OL_INSPECT_WINDOW="${word#window=}" ;;
      cause=*) OL_INSPECT_CAUSE="${word#cause=}" ;;
      probe=*) OL_INSPECT_PROBE="${word#probe=}" ;;
    esac
  done
  [[ "$out" != *$'\n'* ]] || OL_DETAIL="${out#*$'\n'}"
}

# ol_session_stop SESSION [SUCCESSOR] — the runtime's `stop`. Returns the
# provider's status; its words are in DEP_ERR.
ol_session_stop() { # SESSION [SUCCESSOR]
  local args=(--session "$1")
  [[ -z "${2:-}" ]] || args+=(--successor "$2")
  "$SCRIPT_DIR/overseer-host" stop "${args[@]}" >/dev/null 2>"$DEP_ERR"
}

# ol_session_abandon — the close-out every refusal after `create` takes,
# whichever launcher refuses: the session this launch opened is stopped, read
# off the provider's answer where a signal landed before the caller parsed
# it, and the prior record is put back wherever ol_record_read read one,
# whether or not ol_record_write ran: a signal that lands while its writer
# runs is taken only once the writer returns, and the writer may have
# committed. The put-back leaves the record as the launch found it, and an
# empty OL_PRIOR, a state that could not be read, is never written to. Two
# overseers never run, so this is one function and not a copy per caller.
# DEP_ERR is left as the caller had it, holding the detail its refusal
# relays. The provider restores the window placement when it stops the
# abandoned insertion. Returns 0, or 1
# where the stop or record restore failed, with OL_REASON=restore-failed and its
# words in OL_DETAIL, for the caller to report under its own key before its
# refusal.
ol_session_abandon() {
  local detail rc=0 stop_detail=""
  detail="$(cat -- "$DEP_ERR" 2>/dev/null)" || detail=""
  [[ -n "$OL_SESSION" ]] || ol_session_from_out
  if [[ -n "$OL_SESSION" ]] && ! ol_session_stop "$OL_SESSION"; then
    OL_REASON=restore-failed
    stop_detail="$(cat -- "$DEP_ERR" 2>/dev/null)" || stop_detail=""
    OL_DETAIL="$stop_detail"
    rc=1
  fi
  if [[ -n "$OL_PRIOR" ]] && ! ol_record_restore; then
    OL_REASON=restore-failed
    OL_DETAIL="$(cat -- "$DEP_ERR" 2>/dev/null)" || OL_DETAIL=""
    OL_DETAIL="${stop_detail:+$stop_detail$'\n'}$OL_DETAIL"
    rc=1
  fi
  if [[ -n "$detail" ]]; then printf '%s\n' "$detail" > "$DEP_ERR"; else : > "$DEP_ERR"; fi
  return "$rc"
}

# ol_succession PREDECESSOR CWD LINE IDENTITY PENDING LANE_VAR LANE_DIR FORM
# WAIT_SECS — one succession, from the successor's first record write to the
# commit point, whichever launcher runs it: `oversee launch --predecessor` and
# `oversee-succeed` in every mode that launches (succeed, walled and dead). In
# order:
#   1. With PENDING `pending`, LINE and IDENTITY become the record's pending
#      successor (ol_record_pending); `replay`, a relaunch of the line the
#      record already holds, writes none.
#   2. The checkout CWD lies in is fast-forwarded (ol_checkout_sync); one it
#      refuses is the caller's `checkout-unsynced` line on stderr and in the
#      fleet log (ol_checkout_notice), and the launch goes on. The runtime's
#      `create` then opens LINE in CWD at the session's base index.
#   3. The record names the successor (ol_record_write over OL_PRIOR), where
#      the caller's ol_record_read could read one.
#   4. The session is verified (ol_session_verify, LANE_VAR to WAIT_SECS).
#   5. The predecessor is stopped with the successor keeping the base index: the
#      commit point, so HUP, INT and TERM are ignored from here on, and a
#      caller running in the predecessor's own window ends with it.
# The step order is this function's; what a failed record write at step 1 or
# 3 means is the caller's policy. The caller defines ol_succession_hook STEP,
# called at each point it speaks: `pending-unrecorded` and `record-unwritten`
# with the writer's words in DEP_ERR, where a nonzero return refuses the
# succession before its commit point and 0 lets it go on; `opened` once
# OL_SESSION and OL_WINDOW name the successor; and `verified` just before the
# commit point, for its notices and whatever it arranges before its window may
# end. Returns 0 once committed, and 1 with OL_REASON record-unwritten and
# OL_STEP pending or write where the hook refused, create-failed at step 2,
# ol_session_verify's reasons at step 4 and stop-failed at step 5, the
# provider's words in DEP_ERR, any successor left for the caller's
# ol_session_abandon.
ol_succession() { # PREDECESSOR CWD LINE IDENTITY PENDING LANE_VAR LANE_DIR FORM WAIT_SECS
  local predecessor="$1" cwd="$2" line="$3" identity="$4" pending="$5"
  shift 5
  if [[ "$pending" == pending ]] && ! ol_record_pending "$line" "$identity"; then
    ol_succession_hook pending-unrecorded || { OL_REASON=record-unwritten OL_STEP=pending; return 1; }
  fi
  ol_session_open "$cwd" overseer "$line" --after "$predecessor" || return 1
  ol_succession_hook opened
  if [[ -n "$OL_PRIOR" ]] \
     && ! ol_record_write "$OL_RUNTIME" "$OL_SESSION" "$OL_WINDOW" "$OL_SERVER" "$identity" "$line"; then
    ol_succession_hook record-unwritten || { OL_REASON=record-unwritten OL_STEP=write; return 1; }
  fi
  ol_session_verify "$OL_SESSION" "$@" || return 1
  ol_succession_hook verified
  trap '' HUP TERM INT
  ol_session_stop "$predecessor" "$OL_SESSION" || { OL_REASON=stop-failed; return 1; }
}

# ---------------------------------------------------------------------------
# The session record: the `overseer` object of the oversee state
# (../schemas/workflow-state.md), which names the runtime, the server, the
# session and a generation, written before the session's first turn. The
# turn-end hook, the watch and `oversee launch` read it to know which session
# is the overseer, so during a succession it is what tells the predecessor and
# the successor apart, and a launch that is abandoned puts the predecessor's
# record back.
#
# The same object carries the current session's launch identity: its harness,
# account, home, model, effort and working directory. Its `pending` member is
# the successor a succession is about to open, written before that launch and
# never read as the current session's identity: a pending command names the
# account and model the NEXT session will run, and judging this one against
# them would hand the running overseer another session's marks.
# ---------------------------------------------------------------------------

# ol_fleet_log NOTICE_FILE RECORD_FILE ERR_FILE [STATE_CMD...] — one `close`
# row about the overseer in the fleet log: the text in NOTICE_FILE, the record
# built in RECORD_FILE, jq's and the writer's words in ERR_FILE. STATE_CMD is
# the workflow-state command and its arguments, this package's own where none
# is given. The record carries no `at`: `workflow-state append-file` stamps
# the fleet log's time from its own clock, so the record written here and the
# one an overseer writes by hand are dated by one reader. Every overseer notice
# the fleet log carries goes through here: the watch's, at its start and from
# its passes, oversee-succeed's refusal of a self-succession once its
# successor launch began, and either launcher's `checkout-unsynced`.
ol_fleet_log() { # NOTICE_FILE RECORD_FILE ERR_FILE [STATE_CMD...]
  local notice="$1" record="$2" errf="$3"
  shift 3
  [[ $# -gt 0 ]] || set -- "$SCRIPT_DIR/workflow-state"
  jq -n --rawfile text "$notice" \
    '{kind: "close", item: "overseer", text: ($text | rtrimstr("\n"))}' > "$record" 2>"$errf" || return 1
  "$@" append-file oversee fleet_log "$record" >/dev/null 2>"$errf"
}

# ol_fleet_log_notice KEY FIELD=VALUE... — the caller's keyed line and its
# text, `message KEY FIELD=VALUE...` joined onto one line, as one
# ol_fleet_log row, so the session that reads the log next learns what the
# launch printed. A row that cannot be written is the caller's
# `fleet-log-unwritten key=KEY step=mktemp|append` on stderr with the writer's
# words under it; DEP_ERR is left as it was, holding the detail the caller
# relays. Returns 0 either way: the line it records is printed whatever
# becomes of its row.
ol_fleet_log_notice() { # KEY FIELD=VALUE...
  local dir
  if ! dir="$(mktemp -d)"; then
    message fleet-log-unwritten "key=$1" step=mktemp >&2
    return 0
  fi
  if ! message "$@" | paste -sd ' ' - > "$dir/notice" || ! ol_fleet_log "$dir/notice" "$dir/record" "$dir/err"; then
    message fleet-log-unwritten "key=$1" step=append >&2
    [[ ! -s "$dir/err" ]] || cat -- "$dir/err" >&2
  fi
  rm -rf -- "${dir:?}"
}

# ol_record_read — the current object into OL_PRIOR as JSON, `null` where the
# state carries none. A state that cannot be read at all returns 1 and leaves
# OL_PRIOR empty. The caller decides whether that absence permits a launch.
OL_PRIOR=""
ol_record_read() {
  OL_PRIOR="$(ol_record_get)" || { OL_PRIOR=""; return 1; }
}
# The object on stdout, `null` where the state carries none; the one read of
# it, which ol_record_read snapshots and ol_record_current only queries.
ol_record_get() {
  local record
  record="$("$SCRIPT_DIR/workflow-state" get oversee '.overseer // null' 2>"$DEP_ERR")" || return 1
  printf '%s\n' "${record:-null}"
}

# ol_record_write RUNTIME SESSION WINDOW SERVER IDENTITY [LINE] — the record
# for a session this launch opened, merged over OL_PRIOR: `runtime`,
# `session`, `window`, `server`, IDENTITY, the launch identity object
# ol_identity or ol_record_line_identity built (every field present, null
# where the launch does not know it), `launch_line` where LINE is given, and
# `generation`: one more than
# the prior record's, or 1 where none was recorded, and the prior's own where
# the prior names this very session on this server, which is a registration
# repeated and never a second session. On tmux the session is the pane, and
# the object keeps `pane` as the spelling the turn-end hook and the watch
# already read it under, and `session_rows` names the file that pane's own
# event rows land in (lib/session-rows.sh), under the overseer mailbox of the
# checkout the session starts in, IDENTITY's `cwd`, or this launcher's own
# where that is unknown, and `server_start` is the server's start time read
# off that pane (lib/tmux-server.sh § tmux_server_start), so no start of
# another server's survives. A start that cannot be read writes nothing: a
# record with no start is bound to no server, and a later server handed the
# same pid and pane id would read it as its own (ol_unstarted). `pending` is
# dropped: the successor it named is the session written here, or a launch
# that never opened. `exit` is dropped: it is a session's that ended. The
# prior's fields survive only where ol_names proves this same server, server
# start and pane. There, only non-empty IDENTITY fields replace prior values,
# and an empty LINE keeps the prior launch line. A different session takes
# IDENTITY's nulls for unknown fields and inherits no launch line or other
# prior fields. OL_GENERATION names the generation written. OL_RECORD_RETAINED
# and OL_RECORD_FRESH name the retained non-empty fields and the fields read
# afresh, as sorted comma-separated lists, or `none`, for register's report.
# All three are empty where the write failed. Returns 1 with the writer's
# words in DEP_ERR.
OL_GENERATION="" OL_RECORD_RETAINED="" OL_RECORD_FRESH=""
ol_record_write() { # RUNTIME SESSION WINDOW SERVER IDENTITY [LINE]
  local prior="${OL_PRIOR:-null}" result record cwd rows="" start="" fields
  OL_GENERATION="" OL_RECORD_RETAINED="" OL_RECORD_FRESH=""
  if [[ "$1" == tmux ]]; then
    cwd="$(jq -r '.cwd // empty' <<<"$5" 2>"$DEP_ERR")" || return 1
    rows="$(session_rows_overseer_file "${cwd:-$PWD}" "$4" "$2")"
    if ! start="$(ol_session_start "$4" "$2")"; then
      printf 'the start of tmux server %s holding pane %s could not be read\n' "$4" "$2" > "$DEP_ERR"
      return 1
    fi
  fi
  result="$(jq -cn --argjson prior "$prior" --argjson identity "$5" --arg runtime "$1" \
    --arg session "$2" --arg window "$3" --arg server "$4" --arg line "${6:-}" --arg rows "$rows" \
    --arg start "$start" "$OL_JQ_DEFS"'
      def nonempty: with_entries(select(.value != null and .value != ""));
      def field_names: keys | if length == 0 then "none" else join(",") end;
      ($prior // {}) as $p
      | ($p | ol_names($server; $start; $session)) as $same
      | (($p.generation // 0) | if type == "number" then . else 0 end) as $g
      | (if $same and $g > 0 then $g else $g + 1 end) as $next
      | ($identity | nonempty) as $known
      | ($known + {runtime: $runtime, server: $server, window: $window, generation: $next}
         + (if $runtime == "tmux"
            then {pane: $session, session_rows: $rows, server_start: ($start | tonumber)}
            else {session: $session} end)
         + (if $line == "" then {} else {launch_line: $line} end)) as $fresh
      | (if $same then $p | del(.pending, .exit) else $identity | map_values(null) end) as $base
      | {record: ($base + $fresh),
         retained: ($base | nonempty | with_entries(select(.key as $key | $fresh | has($key) | not)) | field_names),
         fresh: ($fresh | field_names)}' 2>"$DEP_ERR")" || return 1
  record="$(jq -c '.record' <<<"$result" 2>"$DEP_ERR")" || return 1
  fields="$(jq -r '[.record.generation, .retained, .fresh] | @tsv' <<<"$result" 2>"$DEP_ERR")" || return 1
  "$SCRIPT_DIR/workflow-state" set oversee overseer "$record" >/dev/null 2>"$DEP_ERR" || return 1
  IFS=$'\t' read -r OL_GENERATION OL_RECORD_RETAINED OL_RECORD_FRESH <<<"$fields"
}

# ol_record_pending LINE IDENTITY — the successor a succession is about to
# open, written as the record's `pending` member before its window opens: LINE
# and its launch identity object. The current session's own fields
# are left as they are, so the account and model the running overseer is
# judged on stay its own until ol_record_write names the successor. A
# dead-overseer relaunch replays this LINE ahead of the current one, since a
# death between this write and that one leaves the command the succession
# chose as the last one the fleet decided on. Returns 1 with the writer's
# words in DEP_ERR.
ol_record_pending() { # LINE IDENTITY
  local record
  record="$(jq -cn --argjson identity "$2" --arg line "$1" '$identity + {launch_line: $line}' 2>"$DEP_ERR")" \
    || return 1
  "$SCRIPT_DIR/workflow-state" set oversee overseer.pending "$record" >/dev/null 2>"$DEP_ERR"
}

# ol_record_current SERVER PANE — the launch identity the record holds for the
# session SERVER PANE names, into OL_CUR_HARNESS, OL_CUR_ACCOUNT, OL_CUR_HOME,
# OL_CUR_MODEL, OL_CUR_EFFORT and OL_CUR_CWD, each empty where the record
# names none, so a caller takes its own reading of the pane or the environment
# for that one fact alone. Returns 0 where the record names that session; 1
# where the fleet has no state, or its record names another session or none,
# which is a first session with nothing recorded yet and keeps its caller's
# bootstrap readings; 2 where the state could not be read, with the reader's
# words in DEP_ERR. The `pending` member is never read here, and OL_PRIOR is
# left as it was: that is a launcher's snapshot, which an abandoned launch
# puts back, and a query is not a snapshot.
OL_CUR_HARNESS="" OL_CUR_ACCOUNT="" OL_CUR_HOME="" OL_CUR_MODEL="" OL_CUR_EFFORT="" OL_CUR_CWD=""
ol_record_current() { # SERVER PANE
  local record fields start sep=$'\x1f'
  OL_CUR_HARNESS="" OL_CUR_ACCOUNT="" OL_CUR_HOME="" OL_CUR_MODEL="" OL_CUR_EFFORT="" OL_CUR_CWD=""
  "$SCRIPT_DIR/workflow-state" exists oversee >/dev/null 2>&1 || return 1
  record="$(ol_record_get)" || return 2
  # Unread, the start names no record bound to one: the caller keeps its own
  # readings, and nothing here acts on the record.
  start="$(ol_session_start "$1" "$2")" || start=""
  fields="$(jq -r --arg server "$1" --arg start "$start" --arg pane "$2" --arg sep "$sep" "$OL_JQ_DEFS"'
      if ol_names($server; $start; $pane) then ol_identity | map(. // "" | tostring) | join($sep)
      else empty end' <<<"$record" 2>"$DEP_ERR")" || return 2
  [[ -n "$fields" ]] || return 1
  IFS="$sep" read -r OL_CUR_HARNESS OL_CUR_ACCOUNT OL_CUR_HOME OL_CUR_MODEL OL_CUR_EFFORT OL_CUR_CWD <<<"$fields"
}

# ol_record_heal SERVER PANE START HARNESS HOME — the record naming the session
# SERVER PANE on the server started at START, bound or unstarted (ol_owns),
# given each fact it lacks and the session itself knows: START
# as `server_start`, HARNESS as `harness`, and HOME, the directory the harness
# variable of that session carries, as `home`. A fact the record already
# names stays, and a record naming another session is left as it stands. The
# lane-mail-check hook runs it from the overseer's own turn end and tool calls,
# so a record that lost the facts the transcript binding reads is filled from
# the session they describe instead of leaving its context unread. An empty
# HARNESS or HOME writes nothing for that field. Returns 1 with the writer's
# words in DEP_ERR.
ol_record_heal() { # SERVER PANE START HARNESS HOME
  "$SCRIPT_DIR/workflow-state" update oversee --arg server "$1" --arg pane "$2" --arg start "$3" \
    --arg harness "$4" --arg home "$5" "$OL_JQ_DEFS"'
      if (.overseer | ol_owns($server; $start; $pane))
      then .overseer |= (.server_start = ($start | tonumber)
        | if (.harness // "") == "" and $harness != "" then .harness = $harness else . end
        | if (.home // "") == "" and $home != "" then .home = $home else . end)
      else . end' >/dev/null 2>"$DEP_ERR"
}

# ol_record_exit_clear SERVER PANE — the record's `exit` member dropped where
# the record names that session on that server: `overseer-run` asks it before
# its line runs, so a launch line run again in the same pane leaves no status
# its predecessor earned. Returns 1 with the writer's words in DEP_ERR.
ol_record_exit_clear() { # SERVER PANE
  local start
  # Unread, the start names no record bound to one, and the update leaves it
  # as it stands.
  start="$(ol_session_start "$1" "$2")" || start=""
  "$SCRIPT_DIR/workflow-state" update oversee --arg server "$1" --arg start "$start" --arg pane "$2" "$OL_JQ_DEFS"'
      if (.overseer | ol_names($server; $start; $pane)) then .overseer |= del(.exit) else . end' \
    >/dev/null 2>"$DEP_ERR"
}

# ol_record_exit SERVER PANE STATUS — the harness's exit status and the UTC
# time it returned, as the record's `exit` member `{status, at}`, written by
# `overseer-run` once the launch line it runs returns. Only a record naming
# that session on that server takes it: a line that outlived its record, a
# successor's having replaced it, says nothing about the session recorded now.
# oversee-watch reads it as the session's death where the pane's process is a
# bare shell with nothing but shells under it, the state this return leaves.
# Returns 1 with the writer's words in DEP_ERR.
ol_record_exit() { # SERVER PANE STATUS
  local at start
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  # Unread, as ol_record_exit_clear reads it: no exit is written.
  start="$(ol_session_start "$1" "$2")" || start=""
  "$SCRIPT_DIR/workflow-state" update oversee --arg server "$1" --arg start "$start" --arg pane "$2" \
    --argjson status "$3" --arg at "$at" "$OL_JQ_DEFS"'
      if (.overseer | ol_names($server; $start; $pane)) then .overseer.exit = {status: $status, at: $at} else . end' \
    >/dev/null 2>"$DEP_ERR"
}

# ol_caller_known SERVER PANE DIR — what the session SERVER PANE is known to
# run, from the two records that name it: its launch record
# (ol_record_current) and, for each fact that leaves unknown, its SessionStart
# row (lib/session-rows.sh) in the overseer mailbox of the checkout DIR is in,
# a row naming a harness but claude or codex answering nothing. Into
# OL_KNOWN_HARNESS, OL_KNOWN_ACCOUNT, OL_KNOWN_MODEL and OL_KNOWN_CWD, each
# empty where neither names it, for the caller's own fallbacks, the pane and
# the environment, to answer; OL_CUR_* are left as ol_record_current set them.
# Every reader of a caller's identity asks here, so the watch's succession and
# `lanes context` cannot name one session two ways. Returns
# ol_record_current's status: 2 is a state that could not be read, the
# reader's words in DEP_ERR, and the row still answers.
OL_KNOWN_HARNESS="" OL_KNOWN_ACCOUNT="" OL_KNOWN_MODEL="" OL_KNOWN_CWD=""
ol_caller_known() { # SERVER PANE DIR
  local rc=0
  ol_record_current "$1" "$2" || rc=$?
  # A rows file that cannot be read is no row: the caller's fallbacks answer.
  session_rows_start "$(session_rows_overseer_file "$3" "$1" "$2")" || true
  case "$SR_HARNESS" in claude | codex) ;; *) SR_HARNESS="" SR_ACCOUNT="" SR_MODEL="" SR_CWD="" ;; esac
  OL_KNOWN_HARNESS="${OL_CUR_HARNESS:-$SR_HARNESS}"
  OL_KNOWN_ACCOUNT="${OL_CUR_ACCOUNT:-$SR_ACCOUNT}"
  OL_KNOWN_MODEL="${OL_CUR_MODEL:-$SR_MODEL}"
  OL_KNOWN_CWD="${OL_CUR_CWD:-$SR_CWD}"
  return "$rc"
}

# ol_record_restore — OL_PRIOR written back whole, for an abandoned launch:
# the predecessor keeps running, so the record has to name it again, its own
# launch line included. A prior of null removes the object. Returns 1 with
# the writer's words in DEP_ERR.
ol_record_restore() {
  if [[ "${OL_PRIOR:-null}" == null ]]; then
    "$SCRIPT_DIR/workflow-state" update oversee 'del(.overseer)' >/dev/null 2>"$DEP_ERR"
  else
    "$SCRIPT_DIR/workflow-state" set oversee overseer "$OL_PRIOR" >/dev/null 2>"$DEP_ERR"
  fi
}

# ---------------------------------------------------------------------------
# Verification: the account the session is REALLY on, asked TWICE, and only
# the second answers.
#
# /proc/<pid>/environ is a snapshot taken at execve, so it shows what a process
# was handed, never what a process has since decided. A wrapper that sets the
# account and only then execs the harness carries the value it was given for as
# long as it runs, and a reading taken while it runs is a reading about the
# wrapper. Waiting for that value to settle does not fix this: it settles
# perfectly well on the pre-exec value.
#
# So the FIRST read is an early abort and nothing else. It can prove a
# disagreement that is already true, and proving one there is worth doing,
# because it comes before the session has had a turn in which to open a
# work-item window or write to the tracker on an account nobody picked. It
# cannot prove agreement, so it reports none.
#
# The SECOND read, taken once the session has shown a running turn, is the one
# that speaks and the one a predecessor is stopped on. A running turn is the
# harness itself; whatever exec was going to happen has happened.
#
# What is still not caught: a wrapper that execs onto another account AFTER the
# session reported a running turn and after this read settled. Nothing local
# can rule that out, since no reading proves a future exec.
#
# One deadline covers all three waits, and ol_budget_raw is that deadline:
# every wait asks it rather than subtracting for itself, so the rule is the
# function and not a sentence three call sites have to keep agreeing with.
# ---------------------------------------------------------------------------

OL_STARTED=0
OL_WAIT_SECS=0
# The budget, computed in ONE place off the clock: seconds left of the wait,
# zero or negative once it is spent.
ol_budget_raw() {
  printf '%s\n' "$(( OL_STARTED + OL_WAIT_SECS - $(date +%s) ))"
}
# The same budget as a BOUND for one account read: a share of it when a
# divisor is given, and never below the least a read can settle in.
#
# That floor is the one overrun this deadline allows, and it is deliberate. A
# predecessor is stopped on the deciding read, and a read handed nothing
# cannot catch the handover it exists for, it can only report that the pane
# was changing hands, which is not what happened. So the promise is `the wait
# plus at most one settle`, never `the wait and a read that could not look`.
ol_budget_bound() { # [DIVISOR]
  local left
  left="$(ol_budget_raw)"
  left=$(( left / ${1:-1} ))
  (( left >= LANE_SETTLE_MIN_SECS )) || left="$LANE_SETTLE_MIN_SECS"
  printf '%s\n' "$left"
}
# Seconds since the launch, for the refusals that report how long this run
# waited. Off the same clock ol_budget_raw decides on, so the figure an
# operator reads cannot drift from the deadline that produced it.
ol_waited() { printf '%s\n' "$(( $(date +%s) - OL_STARTED ))"; }

# ol_account_measured ACCOUNT_HARNESS — whether an OL_ACCOUNT_HARNESS answer
# names an account `lanes` measures: a harness lane_pick_harness answered,
# never `none`, `unknown` or the empty answer for a launch nothing judges. The
# one reading of that answer, so no caller keeps a harness list of its own.
ol_account_measured() { # ACCOUNT_HARNESS
  case "${1:-}" in '' | none | unknown) return 1 ;; esac
}
# ol_account_verdict SESSION LANE_VAR LANE_DIR FORM BOUND final|early — one
# account read and its verdict: 0 where the session may keep running, 1 with
# OL_REASON=wrong-lane and the account seen in OL_OBSERVED, or
# OL_REASON=result-unknown with the verdict in OL_RESULT. Only the final read
# reports an unobserved account, in OL_UNOBSERVED: an early one has nothing
# settled to say.
OL_OBSERVED="" OL_RESULT="" OL_UNOBSERVED=""
ol_account_verdict() { # SESSION LANE_VAR LANE_DIR FORM BOUND final|early
  lane_account_check "$1" "$2" "$3" "$4" "$5" || true
  OL_RESULT="$LANE_ACCOUNT_RESULT"
  case "$LANE_ACCOUNT_RESULT" in
    mismatch) OL_REASON=wrong-lane; OL_OBSERVED="$LANE_ACCOUNT_OBSERVED"; return 1 ;;
    skipped|verified) ;;
    unobserved:*) [[ "$6" != final ]] || OL_UNOBSERVED="${LANE_ACCOUNT_RESULT#unobserved:}" ;;
    # Defensive, as open-terminal's twin is: no shipped lane_account_check
    # emits a fourth verdict, so nothing can drive this arm. It exists so a
    # new one closes the session rather than falling through as a pass.
    *) OL_REASON=result-unknown; return 1 ;;
  esac
}

# ol_session_verify SESSION LANE_VAR LANE_DIR FORM WAIT_SECS — the early
# account read, the wait for the session's first working turn through the
# runtime's `inspect --launch`, and the deciding read, all inside WAIT_SECS.
# A SessionStart row is no evidence here: the harness writes it at startup,
# before its first turn runs, so it proves the process started and nothing
# about a turn.
# 0 once the session is working on the picked account. 1 with OL_REASON:
#   wrong-lane      the session runs another account (OL_OBSERVED)
#   result-unknown  an account verdict this library does not know (OL_RESULT)
#   dialog          a dialog nobody is there to answer holds the harness; the
#                   line under the keyed one is in DEP_ERR for the caller's
#                   refusal to relay, and in OL_DETAIL, OL_WAITED the seconds
#                   waited
#   not-working     no working turn inside the wait; the last screen is in
#                   DEP_ERR and OL_DETAIL the same way, OL_WAITED the seconds
#                   waited
#   inspect-failed  the runtime could not read the session; its words are in
#                   DEP_ERR, the step in OL_STEP
# OL_UNOBSERVED carries the deciding read's unobserved reason, empty where it
# observed or skipped, for the notice a caller prints.
OL_DETAIL="" OL_WAITED="" OL_STEP=""
ol_session_verify() { # SESSION LANE_VAR LANE_DIR FORM WAIT_SECS
  local session="$1" lane_var="$2" lane_dir="$3" form="$4"
  OL_WAIT_SECS="$5"
  OL_DETAIL="" OL_WAITED="" OL_STEP="" OL_UNOBSERVED=""
  OL_STARTED="$(date +%s)"
  # Half the budget to the early read, so the running-turn wait keeps a share.
  # An unobservable launch sleeps to its whole cap before it answers, and with
  # the whole budget that would leave the loop one probe to see a running turn.
  ol_account_verdict "$session" "$lane_var" "$lane_dir" "$form" "$(ol_budget_bound 2)" early || return 1
  # The session is up once the runtime reads a turn in flight. `inspect
  # --launch` is the first-turn reading, over the whole screen: the settled
  # judge's higher rungs answer this question wrong, since a first-run dialog
  # or an option list the brief itself prints reads as asking, and the wait
  # would burn the budget on a session that had in fact launched.
  while :; do
    ol_session_inspect "$session" --launch || { OL_STEP=inspect; return 1; }
    case "$OL_INSPECT_STATE" in
      working) break ;;
      asking)
        OL_REASON=dialog; OL_WAITED="$(ol_waited)"
        printf '%s\n' "$OL_DETAIL" > "$DEP_ERR"
        return 1 ;;
      idle) ;;
      *)
        printf '%s\n' "$OL_INSPECT_LINE" > "$DEP_ERR"
        OL_REASON=inspect-failed; OL_STEP="state"
        return 1 ;;
    esac
    # The clock decides, and there is no counter to decide otherwise: a loop
    # counting its own seconds from zero would start a second deadline here,
    # and the deciding read below would reach it with nothing left.
    if (( $(ol_budget_raw) <= 0 )); then
      OL_REASON=not-working; OL_WAITED="$(ol_waited)"
      printf '%s\n' "$OL_DETAIL" > "$DEP_ERR"
      return 1
    fi
    sleep 1
  done
  # The session is running a turn, so the harness is up and this reading is
  # about it rather than about whatever came up first.
  ol_account_verdict "$session" "$lane_var" "$lane_dir" "$form" "$(ol_budget_bound)" final
}
