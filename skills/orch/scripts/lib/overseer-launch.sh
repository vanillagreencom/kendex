# shellcheck shell=bash
#
# The steps every overseer launch takes, whoever asks for one: `oversee
# launch` opening a fleet's first overseer, and `oversee-succeed` opening a
# successor in a predecessor's place. One launcher, so a first launch and a
# succession cannot come to open, verify or record a session differently.
# What differs between them is policy and stays with the caller: which marks
# fire, how a predecessor's flags carry over, which entries the account walk
# tries. `oversee-watch` sources it too, through lib/watch-overseer-record.sh,
# for OL_JQ_DEFS and ol_preference. What is shared is here:
#
#   ol_preference          the ORCH_OVERSEER_PREFERENCE value, its default
#                          ladder where the setting is unset
#   ol_preference_entries  the ORCH_OVERSEER_PREFERENCE parse
#   ol_account             the account a session spends, as `lanes` judges it
#   ol_pi_model            a pi session's model, out of the sources naming it
#   ol_entry_model         one entry's harness, model and effort
#   ol_lanes               `lanes` on this machine's copy of each account
#   ol_pick_record         one `lanes pick --json` record, for a caller's
#                          own counts
#   ol_pick_lane           one `lanes pick` for one entry, with the counts a
#                          refusal reports
#   ol_command_line        the harness command for a picked lane, brief
#                          included, made trusted and put under the lane form
#   ol_identity            the launch identity the next record write stores
#   ol_runtime_supported   the runtime resolved and held to the one these
#                          launchers can verify a session on
#   ol_session_open        the runtime's `create`, through overseer-host
#   ol_record_*            the session record in the oversee state's
#                          `overseer` object: read, written before the first
#                          turn, restored when the launch is abandoned, the
#                          pending successor written apart from it, and the
#                          current session's launch identity read back
#   ol_session_verify      the account read, the first working turn and the
#                          confirming read, inside one deadline
#   ol_session_stop        the runtime's `stop`
#   ol_session_abandon     the close-out every refusal after `create` takes:
#                          the session stopped, the prior record put back
#
# Every function returns 0 for the answer its name promises and 1 for a
# refusal the caller prints, with the reason in OL_REASON and its fields in
# the OL_* variables each function documents; none of them prints a keyed
# line, because the caller owns its own prefix and its own words. Every
# dependency writes its stderr to DEP_ERR, which the caller relays under its
# keyed line.
#
# Requires, of a caller that runs its functions: SCRIPT_DIR (the orch scripts
# directory), DEP_ERR (a file), and lib/lane-launch.sh and lib/lane-state.sh
# sourced by the caller. Sourcing it defines names and runs nothing. Sourced,
# never run.

# The file a session's own event rows land in, which the record names: its
# path is lib/session-rows.sh's, named by expansion as lib/lane-context.sh
# names its siblings.
# shellcheck source=session-rows.sh
source "${BASH_SOURCE[0]%/*}/session-rows.sh"

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

# The ladder a fleet walks where no settings file names
# ORCH_OVERSEER_PREFERENCE: Fable, then Opus 5.5, then GPT-5.6 Sol on codex,
# each at high effort, so a Fable wall moves the overseer onto another model
# rather than leaving it with no successor, at a mark and at the wall alike.
# Set to empty, the setting names no entries, which is a caller's own rule to
# read.
OL_DEFAULT_PREFERENCE="claude:fable:high,claude:claude-opus-5-5:high,codex:gpt-5.6-sol:high"
ol_preference() {
  printf '%s\n' "${ORCH_OVERSEER_PREFERENCE-$OL_DEFAULT_PREFERENCE}"
}

# ol_preference_entries VALUE — VALUE, ORCH_OVERSEER_PREFERENCE's
# comma-separated `harness:model:effort` entries, into OL_ENTRIES, with
# OL_NAMED the count. `model` is a model name or a kendex tier ladder rank,
# which is digits alone and which no model name is. A pi entry's model is pi's
# own `provider/id`, and never a rank: the tier ladder names no pi model. An
# entry outside the shape returns 1 with it in OL_BAD_ENTRY. An empty VALUE is
# no entries and no refusal.
OL_ENTRIES=()
OL_NAMED=0
OL_BAD_ENTRY=""
ol_preference_entries() { # VALUE
  local rest="$1" entry LC_ALL=C
  OL_ENTRIES=()
  OL_NAMED=0
  OL_BAD_ENTRY=""
  [[ -z "$rest" ]] || rest+=","
  while [[ -n "$rest" ]]; do
    entry="${rest%%,*}"
    rest="${rest#*,}"
    [[ "$entry" =~ ^(claude|codex):([1-9][0-9]*|[a-z][a-z0-9.-]*):[a-z]+$ \
       || "$entry" =~ ^pi:[a-z][a-z0-9.-]*/[a-z0-9][a-z0-9._/-]*:[a-z]+$ ]] || { OL_BAD_ENTRY="$entry"; return 1; }
    OL_ENTRIES+=("$entry")
    OL_NAMED=$((OL_NAMED + 1))
  done
}

# ol_account HARNESS MODEL — the account a session of HARNESS on MODEL spends,
# as `lanes` measures it: OL_ACCOUNT_HARNESS the harness `lanes pick` judges it
# under, OL_ACCOUNT_MODEL the model it judges it on. lib/lane-launch.sh §
# lane_pick_harness answers first: claude and codex spend their own accounts,
# and a pi session on a `github-copilot/` model spends the Copilot pool `lanes
# pick --harness pi` reads. Where it answers none for pi, a model on the
# pi-claude provider runs the claude model after `pi-claude/` under
# CLAUDE_CONFIG_DIR (pi-extensions/pi-claude-bridge), so it spends a claude
# account on that model; a model on any other provider spends no account
# `lanes` measures, `none`; and one naming no provider, or no model at all,
# spends an account nothing here can name, `unknown`, pi resolving a bare
# model to a provider itself. A pi model's `:<thinking>` suffix is pi's level,
# never the model. The model is empty for `none` and `unknown`.
OL_ACCOUNT_HARNESS="" OL_ACCOUNT_MODEL=""
ol_account() { # HARNESS MODEL
  local model="${2:-}"
  [[ "${1:-}" != pi ]] || model="${model%%:*}"
  OL_ACCOUNT_HARNESS="$(lane_pick_harness "${1:-}" "$model")" OL_ACCOUNT_MODEL="$model"
  [[ "${1:-}" == pi && -z "$OL_ACCOUNT_HARNESS" ]] || return 0
  case "$model" in
    pi-claude/?*) OL_ACCOUNT_HARNESS=claude OL_ACCOUNT_MODEL="${model#pi-claude/}" ;;
    ?*/?*) OL_ACCOUNT_HARNESS=none OL_ACCOUNT_MODEL="" ;;
    *) OL_ACCOUNT_HARNESS=unknown OL_ACCOUNT_MODEL="" ;;
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
# OL_ENTRY_HARNESS, OL_ENTRY_MODEL and OL_ENTRY_EFFORT: a rank as `kendex
# tier-model` names it, a name as written once the tier ladder is shown to
# know it. A codex name is known where it IS a model the ladder names for
# codex; a claude name where it carries one, since the claude ladder names
# model families (`opus`) that a full id (`claude-opus-5-5`) spells inside it.
# A pi name on the pi-claude provider runs a claude model and is held to the
# claude ladder the same way (ol_account); a pi name on any other provider is
# taken as written, the ladder naming none.
# Returns 1 for a rank the ladder cannot answer and for a name it does not
# know, which the walk refuses rather than skips: either is a setting to fix,
# and a misspelled name would otherwise reach the pick, which then drops
# every model-scoped window, and the launch line as written.
OL_ENTRY_HARNESS="" OL_ENTRY_MODEL="" OL_ENTRY_EFFORT=""
ol_entry_model() { # ENTRY
  local rank=1 known harness name
  IFS=: read -r OL_ENTRY_HARNESS OL_ENTRY_MODEL OL_ENTRY_EFFORT <<<"$1"
  harness="$OL_ENTRY_HARNESS" name="$OL_ENTRY_MODEL"
  if [[ "$harness" == pi ]]; then
    ol_account pi "$name"
    [[ "$OL_ACCOUNT_HARNESS" == claude ]] || return 0
    harness=claude name="$OL_ACCOUNT_MODEL"
  elif [[ "$name" =~ ^[0-9]+$ ]]; then
    OL_ENTRY_MODEL="$(kendex tier-model "$OL_ENTRY_HARNESS" "$OL_ENTRY_MODEL" 2>"$DEP_ERR")" && [[ -n "$OL_ENTRY_MODEL" ]]
    return
  fi
  # Every rank until `kendex tier-model` refuses one past the ladder's end.
  while known="$(kendex tier-model "$harness" "$rank" 2>"$DEP_ERR")" && [[ -n "$known" ]]; do
    case "$harness:$name" in
      "codex:$known"|"claude:"*"$known"*) return 0 ;;
    esac
    rank=$((rank + 1))
  done
  return 1
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
  case "$harness" in claude | codex | pi) ;; *) return 4 ;; esac
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
# PI_CODING_AGENT_DIR on the Copilot pool. An empty LANE_DIR, a pi model on a
# provider no lane measures (ol_pick_lane), launches the command bare.
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
# spells either question a second time: `ol_identity` is the launch identity
# an object carries, its six fields in their one order, and `ol_names($server;
# $session)` is whether a record names that session on that server, the pane
# on tmux and the session elsewhere. lib/watch-overseer-record.sh takes the
# second for the watch start.
OL_JQ_DEFS='def ol_identity: {harness, account, home, model, effort, cwd};
  def ol_names($server; $session): type == "object" and (.server // "") == $server
    and ((.pane // .session // "") == $session);'

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

# ol_session_open CWD NAME LINE PLACEMENT — the runtime's `create`: a session
# named NAME with its shell in CWD running LINE under `overseer-run`, which
# writes the harness's exit status into the session record once LINE returns
# (ol_record_exit), placed by PLACEMENT, which is
# `--after SESSION` for a successor beside its predecessor or `--session
# NAME` for a first launch into a tmux session. Into OL_SESSION, OL_WINDOW
# and OL_SERVER. Returns 1 with OL_REASON=create-failed; the provider's own
# line is in DEP_ERR.
#
# OL_OPEN_OUT holds the provider's raw answer from the moment the call
# returns, before it is parsed: a signal that lands during `create` runs its
# trap once the call returns, and a trap that closes a session opened by a
# call the signal interrupted reads it from there through
# ol_session_from_out.
OL_SESSION="" OL_WINDOW="" OL_SERVER="" OL_OPEN_OUT=""
ol_session_open() { # CWD NAME LINE PLACEMENT_FLAG PLACEMENT_VALUE
  OL_SESSION="" OL_WINDOW="" OL_SERVER="" OL_OPEN_OUT=""
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
# relays; the stop's and the restore's own words go nowhere. Returns 0, or 1
# where the restore failed, with OL_REASON=restore-failed and the writer's
# words in OL_DETAIL, for the caller to report under its own key before its
# refusal.
ol_session_abandon() {
  local detail rc=0
  detail="$(cat -- "$DEP_ERR" 2>/dev/null)" || detail=""
  [[ -n "$OL_SESSION" ]] || ol_session_from_out
  [[ -z "$OL_SESSION" ]] || ol_session_stop "$OL_SESSION" || true
  if [[ -n "$OL_PRIOR" ]] && ! ol_record_restore; then
    OL_REASON=restore-failed
    OL_DETAIL="$(cat -- "$DEP_ERR" 2>/dev/null)" || OL_DETAIL=""
    rc=1
  fi
  if [[ -n "$detail" ]]; then printf '%s\n' "$detail" > "$DEP_ERR"; else : > "$DEP_ERR"; fi
  return "$rc"
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

# ol_record_read — the current object into OL_PRIOR as JSON, `null` where the
# state carries none. A state that cannot be read at all returns 1: the
# fleet's state is where the record lives, and a run outside a fleet has none,
# which a caller reports as a notice and never as a reason to stop a launch.
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
# where the launch does not know it, so no field of another session's
# survives into this one's), `launch_line` where LINE is given, and `generation`: one more than
# the prior record's, or 1 where none was recorded, and the prior's own where
# the prior names this very session on this server, which is a registration
# repeated and never a second session. On tmux the session is the pane, and
# the object keeps `pane` as the spelling the turn-end hook and the watch
# already read it under, and `session_rows` names the file that pane's own
# event rows land in (lib/session-rows.sh), under the overseer mailbox of the
# checkout the session starts in, IDENTITY's `cwd`, or this launcher's own
# where that is unknown. `pending` is
# dropped: the successor it named is the session written here, or a launch
# that never opened. `exit` is dropped: it is a session's that ended. The
# prior's `launch_line` goes with it where LINE is empty: `oversee register`
# writes a session a person opened by hand, whose line nothing here knows, and
# a line kept from the prior would be replayed for this session's death as if
# it were its own, the prior's account and permission words included. Every
# other field the prior carried stays. The generation written is in
# OL_GENERATION. Returns 1 with the writer's words in DEP_ERR.
OL_GENERATION=""
ol_record_write() { # RUNTIME SESSION WINDOW SERVER IDENTITY [LINE]
  local prior="${OL_PRIOR:-null}" record cwd rows=""
  if [[ "$1" == tmux ]]; then
    cwd="$(jq -r '.cwd // empty' <<<"$5" 2>"$DEP_ERR")" || return 1
    rows="$(session_rows_overseer_file "${cwd:-$PWD}" "$4" "$2")"
  fi
  record="$(jq -cn --argjson prior "$prior" --argjson identity "$5" --arg runtime "$1" \
    --arg session "$2" --arg window "$3" --arg server "$4" --arg line "${6:-}" --arg rows "$rows" "$OL_JQ_DEFS"'
      ($prior // {}) as $p
      | (($p.generation // 0) | if type == "number" then . else 0 end) as $g
      | (if ($p | ol_names($server; $session)) and $g > 0 then $g else $g + 1 end) as $next
      | ($p | del(.pending, .exit, .launch_line)) + {runtime: $runtime, server: $server, window: $window, generation: $next}
      + $identity
      + (if $runtime == "tmux" then {pane: $session, session_rows: $rows} else {session: $session} end)
      + (if $line == "" then {} else {launch_line: $line} end)' 2>"$DEP_ERR")" \
    || return 1
  OL_GENERATION="$(jq -r '.generation' <<<"$record" 2>"$DEP_ERR")" || return 1
  "$SCRIPT_DIR/workflow-state" set oversee overseer "$record" >/dev/null 2>"$DEP_ERR"
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
  local record fields sep=$'\x1f'
  OL_CUR_HARNESS="" OL_CUR_ACCOUNT="" OL_CUR_HOME="" OL_CUR_MODEL="" OL_CUR_EFFORT="" OL_CUR_CWD=""
  "$SCRIPT_DIR/workflow-state" exists oversee >/dev/null 2>&1 || return 1
  record="$(ol_record_get)" || return 2
  fields="$(jq -r --arg server "$1" --arg pane "$2" --arg sep "$sep" "$OL_JQ_DEFS"'
      if ol_names($server; $pane) then ol_identity | map(. // "" | tostring) | join($sep)
      else empty end' <<<"$record" 2>"$DEP_ERR")" || return 2
  [[ -n "$fields" ]] || return 1
  IFS="$sep" read -r OL_CUR_HARNESS OL_CUR_ACCOUNT OL_CUR_HOME OL_CUR_MODEL OL_CUR_EFFORT OL_CUR_CWD <<<"$fields"
}

# ol_record_exit_clear SERVER PANE — the record's `exit` member dropped where
# the record names that session on that server: `overseer-run` asks it before
# its line runs, so a launch line run again in the same pane leaves no status
# its predecessor earned. Returns 1 with the writer's words in DEP_ERR.
ol_record_exit_clear() { # SERVER PANE
  "$SCRIPT_DIR/workflow-state" update oversee --arg server "$1" --arg pane "$2" "$OL_JQ_DEFS"'
      if (.overseer | ol_names($server; $pane)) then .overseer |= del(.exit) else . end' \
    >/dev/null 2>"$DEP_ERR"
}

# ol_record_exit SERVER PANE STATUS — the harness's exit status and the UTC
# time it returned, as the record's `exit` member `{status, at}`, written by
# `overseer-run` once the launch line it runs returns. Only a record naming
# that session on that server takes it: a line that outlived its record, a
# successor's having replaced it, says nothing about the session recorded now.
# oversee-watch reads it as the session's death where the pane's process is a
# bare shell with nothing under it, the state this return leaves.
# Returns 1 with the writer's words in DEP_ERR.
ol_record_exit() { # SERVER PANE STATUS
  local at
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  "$SCRIPT_DIR/workflow-state" update oversee --arg server "$1" --arg pane "$2" \
    --argjson status "$3" --arg at "$at" "$OL_JQ_DEFS"'
      if (.overseer | ol_names($server; $pane)) then .overseer.exit = {status: $status, at: $at} else . end' \
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
  local session="$1" lane_var="$2" lane_dir="$3" form="$4" out keyed state
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
    out="$("$SCRIPT_DIR/overseer-host" inspect --launch --session "$session" 2>"$DEP_ERR")" \
      || { OL_REASON=inspect-failed; OL_STEP=inspect; return 1; }
    keyed="${out%%$'\n'*}"
    OL_DETAIL="${out#*$'\n'}"
    [[ "$OL_DETAIL" != "$out" ]] || OL_DETAIL=""
    state=""
    case " $keyed " in
      *" state=working "*) state=working ;;
      *" state=asking "*) state=asking ;;
      *" state=idle "*) state=idle ;;
      *" state=gone "*) state=gone ;;
    esac
    case "$state" in
      working) break ;;
      asking)
        OL_REASON=dialog; OL_WAITED="$(ol_waited)"
        printf '%s\n' "$OL_DETAIL" > "$DEP_ERR"
        return 1 ;;
      idle) ;;
      *)
        printf '%s\n' "$keyed" > "$DEP_ERR"
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
