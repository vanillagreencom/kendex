# shellcheck shell=bash
#
# The steps every overseer launch takes, whoever asks for one: `oversee
# launch` opening a fleet's first overseer, and `oversee-succeed` opening a
# successor in a predecessor's place. One launcher, so a first launch and a
# succession cannot come to open, verify or record a session differently.
# What differs between them is policy and stays with the caller: which marks
# fire, how a predecessor's flags carry over, which entries the account walk
# tries. What is shared is here:
#
#   ol_preference_entries  the ORCH_OVERSEER_PREFERENCE parse
#   ol_pick_lane           one `lanes pick` for one entry, with the counts a
#                          refusal reports
#   ol_command_line        the harness command for a picked lane, brief
#                          included, made trusted and put under the lane form
#   ol_session_open        the runtime's `create`, through overseer-host
#   ol_record_*            the session record in the oversee state's
#                          `overseer` object: read, written before the first
#                          turn, restored when the launch is abandoned
#   ol_session_verify      the account read, the first working turn and the
#                          confirming read, inside one deadline
#   ol_session_stop        the runtime's `stop`
#
# Every function returns 0 for the answer its name promises and 1 for a
# refusal the caller prints, with the reason in OL_REASON and its fields in
# the OL_* variables each function documents; none of them prints a keyed
# line, because the caller owns its own prefix and its own words. Every
# dependency writes its stderr to DEP_ERR, which the caller relays under its
# keyed line.
#
# Requires: SCRIPT_DIR (the orch scripts directory), DEP_ERR (a file), and
# lib/lane-launch.sh and lib/lane-state.sh sourced by the caller. Sourced,
# never run.

# The runtime the caller launches into, resolved once per process.
OL_RUNTIME=""
ol_runtime() {
  [[ -n "$OL_RUNTIME" ]] && return 0
  OL_RUNTIME="$("$SCRIPT_DIR/overseer-host" resolve 2>"$DEP_ERR")" || { OL_REASON=host-unresolved; return 1; }
  [[ -n "$OL_RUNTIME" ]] || { OL_REASON=host-unresolved; return 1; }
}

# ol_preference_entries VALUE — VALUE, ORCH_OVERSEER_PREFERENCE's
# comma-separated `harness:rank:effort` entries, into OL_ENTRIES, with
# OL_NAMED the count. An entry outside the shape returns 1 with it in
# OL_BAD_ENTRY. An empty VALUE is no entries and no refusal.
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
    [[ "$entry" =~ ^(claude|codex):[1-9][0-9]*:[a-z]+$ ]] || { OL_BAD_ENTRY="$entry"; return 1; }
    OL_ENTRIES+=("$entry")
    OL_NAMED=$((OL_NAMED + 1))
  done
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
OL_PICKED_DIR=""
OL_WALKED_WALLED=0
OL_WALKED_UNMEASURED=0
ol_pick_lane() { # HARNESS MODEL TRIGGER [EXCLUDE_DIR]
  local record rc=0 floor=() exclude=() walled unmeasured LC_ALL=C
  OL_PICKED_DIR=""
  [[ -n "$(lane_context_mark_model "$1" "$2")" ]] || floor=(--binding-floor)
  [[ -z "${4:-}" ]] || exclude=(--exclude-lane "$4")
  record="$("$SCRIPT_DIR/lanes" pick --harness "$1" --min-headroom-pct "$3" \
    ${floor[@]+"${floor[@]}"} ${exclude[@]+"${exclude[@]}"} ${2:+--model "$2"} --json 2>"$DEP_ERR")" || rc=$?
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
# the form the lane reaches the harness by (lib/lane-launch.sh).
#
# The brief crosses the pane's shell inside single quotes, so it holds only
# shell-inert characters, and HANDOFF is held to the same alphabet by every
# caller. One plain sentence on every harness: it is the contract each of
# them already reads as its opening prompt.
#
# A codex session reads folder trust for LAUNCH_DIR before it reads its own
# arguments, and the pane it opens in has nobody at it, so the entry is made
# through the builder `open-terminal` uses; a launch whose entry could not be
# made returns 1 with OL_REASON=launch-trust-missing and the builder's reason
# in OL_TRUST_REASON, rather than opening on the question. The lane reaches
# the harness through the same builder too: on a host whose `claude` is an
# account shim, an env prefix in front of it is overwritten for the shim's
# own name and the session starts on the bare account with nothing on screen
# saying so.
OL_CMD="" OL_LANE_VAR="" OL_LAUNCH_HOME="" OL_FORM="" OL_TRUST_REASON="" OL_TRUST_ROUTE=""
ol_command_line() { # HARNESS HANDOFF LANE_DIR LAUNCH_DIR FLAG...
  local harness="$1" handoff="$2" lane_dir="$3" launch_dir="$4" flag cmd
  shift 4
  if [[ "$harness" == claude ]]; then
    OL_LANE_VAR=CLAUDE_CONFIG_DIR
    cmd="claude -n overseer"
  else
    OL_LANE_VAR=CODEX_HOME
    cmd="codex"
  fi
  for flag in "$@"; do
    cmd+=" $(printf %q "$flag")"
  done
  cmd+=" 'Read .agents/skills/orch/SKILL.md and execute the orch oversee workflow after reading the overseer handoff at $handoff'"
  if ! lane_codex_trust_prepare "$harness" "$lane_dir" "$launch_dir"; then
    OL_REASON=launch-trust-missing
    OL_TRUST_REASON="$LANE_TRUST_REASON"
    return 1
  fi
  OL_TRUST_ROUTE="${LANE_TRUST_ROUTE:-none}"
  # Always a path where a lane was picked: lane_codex_trust_prepare returns
  # the lane or a home under it.
  OL_LAUNCH_HOME="$LANE_TRUST_HOME"
  OL_FORM="$(lane_launch_form "$cmd" "$harness" "$OL_LAUNCH_HOME" "")"
  OL_CMD="$(lane_launch_line "$cmd" "$harness" "$OL_LANE_VAR" "$OL_LAUNCH_HOME" "$OL_FORM")"
}

# ol_session_open CWD NAME LINE PLACEMENT — the runtime's `create`: a session
# named NAME with its shell in CWD running LINE, placed by PLACEMENT, which is
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
  OL_OPEN_OUT="$("$SCRIPT_DIR/overseer-host" create --cwd "$1" --name "$2" "$4" "$5" --line "$3" 2>"$DEP_ERR")" \
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

# ---------------------------------------------------------------------------
# The session record: the `overseer` object of the oversee state
# (../schemas/workflow-state.md), which names the runtime, the server, the
# session and a generation, written before the session's first turn. The
# hooks, the watch and the reports read it to know which session is the
# overseer, so during a succession it is what tells the predecessor and the
# successor apart, and a launch that is abandoned puts the predecessor's
# record back.
# ---------------------------------------------------------------------------

# ol_record_read — the current object into OL_PRIOR as JSON, `null` where the
# state carries none. A state that cannot be read at all returns 1: the
# fleet's state is where the record lives, and a run outside a fleet has none,
# which a caller reports as a notice and never as a reason to stop a launch.
OL_PRIOR=""
ol_record_read() {
  OL_PRIOR="$("$SCRIPT_DIR/workflow-state" get oversee '.overseer // null' 2>"$DEP_ERR")" || { OL_PRIOR=""; return 1; }
  [[ -n "$OL_PRIOR" ]] || OL_PRIOR=null
}

# ol_record_write RUNTIME SESSION WINDOW SERVER ACCOUNT [LINE] — the record
# for a session this launch opened, merged over OL_PRIOR: `runtime`,
# `session`, `window`, `server`, `account` (null where no lane was picked),
# `launch_line` where LINE is given, and `generation`: one more than the
# prior record's, or 1 where none was recorded, and the prior's own where the
# prior names this very session on this server, which is a registration
# repeated and never a second session. On tmux the session is the pane, and
# the object keeps `pane` as the spelling the turn-end hook, the watch and
# the report already read it under. Every other field the prior carried
# stays. The generation written is in OL_GENERATION. Returns 1 with the
# writer's words in DEP_ERR.
OL_GENERATION=""
ol_record_write() { # RUNTIME SESSION WINDOW SERVER ACCOUNT [LINE]
  local prior="${OL_PRIOR:-null}" record
  record="$(jq -cn --argjson prior "$prior" --arg runtime "$1" --arg session "$2" \
    --arg window "$3" --arg server "$4" --arg account "$5" --arg line "${6:-}" '
      ($prior // {}) as $p
      | (($p.generation // 0) | if type == "number" then . else 0 end) as $g
      | (if ($p.server // "") == $server and (($p.pane // $p.session // "") == $session) and $g > 0
         then $g else $g + 1 end) as $next
      | $p + {runtime: $runtime, server: $server, window: $window, generation: $next,
              account: (if $account == "" then null else $account end)}
      + (if $runtime == "tmux" then {pane: $session} else {session: $session} end)
      + (if $line == "" then {} else {launch_line: $line} end)' 2>"$DEP_ERR")" \
    || return 1
  OL_GENERATION="$(jq -r '.generation' <<<"$record" 2>"$DEP_ERR")" || return 1
  "$SCRIPT_DIR/workflow-state" set oversee overseer "$record" >/dev/null 2>"$DEP_ERR"
}

# ol_record_restore — OL_PRIOR written back whole, for a launch abandoned
# after ol_record_write: the predecessor keeps running, so the record has to
# name it again. A prior of null removes the object. Returns 1 with the
# writer's words in DEP_ERR.
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
# 0 once the session is working on the picked account. 1 with OL_REASON:
#   wrong-lane      the session runs another account (OL_OBSERVED)
#   result-unknown  an account verdict this library does not know (OL_RESULT)
#   dialog          a dialog nobody is there to answer holds the harness; the
#                   line under the keyed one is in OL_DETAIL, OL_WAITED the
#                   seconds waited
#   not-working     no working turn inside the wait; the last screen is in
#                   OL_DETAIL, OL_WAITED the seconds waited
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
      return 1
    fi
    sleep 1
  done
  # The session is running a turn, so the harness is up and this reading is
  # about it rather than about whatever came up first.
  ol_account_verdict "$session" "$lane_var" "$lane_dir" "$form" "$(ol_budget_bound)" final
}
