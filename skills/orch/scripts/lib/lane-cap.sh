# shellcheck shell=bash
#
# Owner: open-terminal, the one script that sources this file.
#
# The fleet cap a fleet launch is judged on: the count, the launch lock, the
# reservation and the gate. What the cap bounds is stated where open-terminal
# decides whether a launch is judged. It reads open-terminal's globals
# (CLAIM_ROOT, WORKFLOW_STATE, the cap setting and options) and calls
# its ot_message and lane_rejudge, so it is loaded by that script alone.
#
# Sourced, never run.

# The lock is held on descriptor 7, and a flock stays held while any copy of
# its descriptor is open. It is held only across the count and the reservation
# write, whose children all exit before cap_release, so no child of the launch
# itself inherits it.
CAP_LOCK=""
# The fleet a judged launch belongs to: its oversee state file, canonical, which
# every claim it writes carries so a claim store several fleets share still
# tells their lanes apart. Empty for a launch that is not judged.
CAP_FLEET=""
CAP_HELD=false
# The current item's reservation, empty once its claim stands or the item ends.
CAP_RESERVE=""
# Far past any queue of counts; a wait that reaches it is a holder that is
# stuck.
CAP_LOCK_WAIT_SECS=900
# How often --wait-slot counts again, holding no lock between counts.
WAIT_SLOT_POLL_SECS=5
# The cap the current item's --over-cap launch passed, `fleet`, empty for a
# launch inside it; lane_record_write records it as over_cap.
CAP_PASSED=""

cap_release() {
  [[ "$CAP_HELD" == true ]] || return 0
  exec 7>&-
  orch_release_lock
  CAP_HELD=false
}

# Writes the admitted item's reservation into the claim store and releases the
# lock. Returns 1 with the refusal printed when it cannot be written: the next
# count would not see this launch.
cap_reserve() { # ITEM WINDOW
  local store
  store="$(lane_claims_dir "$CLAIM_ROOT")"
  if ! lane_claim_reserve "$store" "$$" "$2" "$CAP_FLEET"; then
    cap_release
    ot_message cap-reserve-failed "item=$1" "store=$store" >&2
    return 1
  fi
  CAP_RESERVE="$LANE_CLAIM_PATH"
  cap_release
}

# Drops the item's reservation once its claim stands or the item ends. One
# that cannot be removed lapses when this launcher exits, its pid being the
# reservation's liveness.
cap_unreserve() {
  [[ -n "$CAP_RESERVE" ]] || return 0
  rm -f -- "$CAP_RESERVE" || ot_message reserve-unremoved "path=$CAP_RESERVE" >&2
  CAP_RESERVE=""
}

# Takes the fleet's launch lock, printing lock-waiting once when another launch
# holds it, so a long wait reads as a wait. The first try's own diagnostic is
# dropped: it is the one-second probe, and the bounded wait that follows
# reports its own. A take that fails prints the refusal naming its cause and
# releases whatever it holds: a fleet state whose path workflow-state could not
# give, a lock file the shell could not open, or a lock another launch held
# past the bound.
cap_take() { # ITEM
  local state
  if [[ -z "$CAP_LOCK" ]]; then
    if ! state="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} path oversee)"; then
      ot_message cap-unreadable "item=$1" "source=state" >&2
      return 1
    fi
    CAP_FLEET="$(lane_claims_canon "${state%/*}")/${state##*/}"
    CAP_LOCK="$CAP_FLEET.launch.lock"
  fi
  if ! exec 7>"$CAP_LOCK"; then
    ot_message cap-lock-unopenable "item=$1" "lock=$CAP_LOCK" >&2
    return 1
  fi
  CAP_HELD=true
  orch_take_lock 7 "$CAP_LOCK" 1 2>/dev/null && return 0
  ot_message lock-waiting "item=$1" "lock=$CAP_LOCK" "wait-s=$CAP_LOCK_WAIT_SECS"
  orch_take_lock 7 "$CAP_LOCK" "$CAP_LOCK_WAIT_SECS" && return 0
  cap_release
  ot_message cap-lock-failed "item=$1" "lock=$CAP_LOCK" >&2
  return 1
}

# Sets CAP_RUNNING (records lib/lane-claims.sh's LANE_RUNNING_JQ calls held,
# running or preparing), CAP_INFLIGHT (live claims and reservations naming this
# fleet that are no held record's own: a lane whose pane outlived its record's
# running status, or a launch not yet recorded), and CAP_ITEM_HELD (whether
# KEY's own record is held). A claim of this fleet is a held record's own where
# it names the record's window, so a relaunch onto another account is not a
# second lane of the fleet. A record's window is `SESSION:WINDOW`, or bare
# where written by hand, and a claim's is the bare name, so the two are
# compared on the name. The records are this fleet's durable count: a GUI
# launch writes no claim and a claim write can fail, and either lane still has
# its record. They are read after the claim store, because a launch writes its
# record before it drops its reservation: a lane whose reservation the claim
# read missed is a record this read finds. Returns 1 on a store it could not
# read: a count missing a lane is a cap that admits one lane too many.
cap_count() { # ITEM KEY
  local lanes out held windows="" claims tag window rc=0
  claims="$(lane_claims_read "$(lane_claims_dir "$CLAIM_ROOT")" count)" || rc=$?
  [[ "$rc" -eq 0 ]] || { ot_message cap-unreadable "item=$1" "source=claims" >&2; return 1; }
  lanes="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} get oversee '.lanes // []')" || rc=$?
  # One line per held record, tagged and joined by the unit separator, which
  # keeps an empty window a field of its own.
  [[ "$rc" -eq 0 ]] && out="$(jq -r --arg key "$2" "$LANE_RUNNING_JQ"'
    ([.[] | objects | select(.item == $key)] | first) as $own
    | (if $own == null then "absent" elif ($own | held) then "held" else "stopped" end),
      (.[] | select(held) | ["held", (.window // "" | sub("^[^:]*:"; ""))] | join("\u001f"))' <<<"$lanes")" || rc=1
  [[ "$rc" -eq 0 ]] || { ot_message cap-unreadable "item=$1" "source=state" >&2; return 1; }
  { read -r CAP_ITEM_HELD; held="$(cat)"; } <<<"$out"
  CAP_RUNNING=0
  while IFS=$'\037' read -r tag window; do
    [[ "$tag" == held ]] || continue
    CAP_RUNNING=$((CAP_RUNNING + 1))
    [[ -z "$window" ]] || windows+="$window"$'\n'
  done <<<"$held"
  # A held record's own claims are that record's lane, counted above; this
  # fleet's other claims are the fleet cap's in-flight lanes.
  CAP_INFLIGHT="$(CAP_WINDOWS="$windows" CAP_FLEET="$CAP_FLEET" awk -F'\t' '
    BEGIN {
      n = split(ENVIRON["CAP_WINDOWS"], w, "\n")
      for (i = 1; i <= n; i++) if (w[i] != "") window[w[i]] = 1
    }
    NF && $5 == ENVIRON["CAP_FLEET"] && !($2 in window) { f++ }
    END { print f + 0 }' <<<"$claims")"
}

# Returns 0 with the item's reservation written and the lock released when
# this item may launch, and 1 having released it when it may not, its refusal
# printed. A relaunch of a held record replaces its lane, so it is inside the
# cap. --over-cap admits the launch past the cap and names it in CAP_PASSED;
# --wait-slot counts again every WAIT_SLOT_POLL_SECS until the cap has room,
# printing slot-waiting whenever the count it waits on changes, and judges the
# lane again before the count that admits it.
cap_gate() { # ITEM KEY WINDOW
  local item="$1" key="$2" stale=false waited_on=""
  CAP_PASSED=""
  while :; do
    cap_take "$item" || return 1
    cap_count "$item" "$key" || { cap_release; return 1; }
    if [[ "$RELAUNCH" == true && "$CAP_ITEM_HELD" == held ]] || (( CAP_RUNNING + CAP_INFLIGHT < FLEET_CAP )); then
      [[ "$stale" == true ]] || { cap_reserve "$item" "$3"; return; }
      cap_release
      lane_rejudge "$item" || return 1
      stale=false
      continue
    fi
    if [[ "$OVER_CAP" == true ]]; then
      cap_reserve "$item" "$3" || return 1
      # shellcheck disable=SC2034  # read by open-terminal's lane_record_write
      CAP_PASSED=fleet
      ot_message over-cap-admitted "item=$item" "cap=$FLEET_CAP" "running=$CAP_RUNNING" "claims=$CAP_INFLIGHT" >&2
      return 0
    fi
    cap_release
    if [[ "$WAIT_SLOT" != true ]]; then
      ot_message cap-reached "item=$item" "cap=$FLEET_CAP" "running=$CAP_RUNNING" "claims=$CAP_INFLIGHT" >&2
      return 1
    fi
    if [[ "$waited_on" != "$CAP_RUNNING $CAP_INFLIGHT" ]]; then
      waited_on="$CAP_RUNNING $CAP_INFLIGHT"
      ot_message slot-waiting "item=$item" "cap=$FLEET_CAP" "running=$CAP_RUNNING" "claims=$CAP_INFLIGHT"
    fi
    sleep "$WAIT_SLOT_POLL_SECS"
    stale=true
  done
}
