# shellcheck shell=bash
#
# Owner: open-terminal, the one script that sources this file.
#
# The fleet and account caps a fleet launch is judged on: the count, the two
# launch locks, the reservation and the gate. What each cap bounds is stated
# where open-terminal decides whether a launch is judged. It reads
# open-terminal's globals (CLAIM_ROOT, LANE_ENV, WORKFLOW_STATE, the cap
# settings and options) and calls its ot_message and lane_rejudge, so it is
# loaded by that script alone.
#
# Sourced, never run.

# The locks are held on descriptors 7 (the fleet's) and 8 (the claim store's),
# and a flock stays held while any copy of its descriptor is open. They are
# held only across the count and the reservation write, whose children all
# exit before cap_release, so no child of the launch itself inherits them.
CAP_LOCK=""
CAP_STORE_LOCK=""
# The lock the last take failed on, which cap-lock-failed names.
CAP_LOCK_FAILED=""
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
# The caps the current item's --over-cap launch passed, comma-separated, empty
# for a launch inside both; lane_record_write records it as over_cap.
CAP_PASSED=""

cap_release() {
  [[ "$CAP_HELD" == true ]] || return 0
  exec 7>&- 8>&-
  orch_release_lock
  CAP_HELD=false
}

# Writes the admitted item's reservation into the claim store and releases the
# locks. Returns 1 with the refusal printed when it cannot be written: the next
# count would not see this launch.
cap_reserve() { # ITEM WINDOW
  local lane_dir="" store
  [[ -z "$LANE_ENV" ]] || lane_dir="${LANE_ENV#*=}"
  store="$(lane_claims_dir "$CLAIM_ROOT")"
  if ! lane_claim_reserve "$store" "$$" "$lane_dir" "$2" "$CAP_FLEET"; then
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

# Takes one launch lock on FD, printing lock-waiting once when another launch
# holds it, so a long wait reads as a wait. The first try's own diagnostic is
# dropped: it is the one-second probe, and the bounded wait that follows
# reports its own.
cap_lock_take() { # FD LOCK ITEM
  CAP_LOCK_FAILED="$2"
  case "$1" in
    7) exec 7>"$2" || return 1 ;;
    8) exec 8>"$2" || return 1 ;;
  esac
  if ! orch_take_lock "$1" "$2" 1 2>/dev/null; then
    ot_message lock-waiting "item=$3" "lock=$2" "wait-s=$CAP_LOCK_WAIT_SECS"
    orch_take_lock "$1" "$2" "$CAP_LOCK_WAIT_SECS" || return 1
  fi
}

# Takes the fleet's lock, then the claim store's. A take that fails releases
# whatever it holds.
cap_take() { # ITEM
  local state
  if [[ -z "$CAP_LOCK" ]]; then
    state="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} path oversee)" || return 1
    CAP_FLEET="$(lane_claims_canon "${state%/*}")/${state##*/}"
    CAP_LOCK="$CAP_FLEET.launch.lock"
    CAP_STORE_LOCK="$(lane_claims_dir "$CLAIM_ROOT").launch.lock"
  fi
  CAP_HELD=true
  cap_lock_take 7 "$CAP_LOCK" "$1" && mkdir -p -- "${CAP_STORE_LOCK%/*}" && cap_lock_take 8 "$CAP_STORE_LOCK" "$1" && return 0
  cap_release
  return 1
}

# Sets CAP_RUNNING (records lib/lane-claims.sh's LANE_RUNNING_JQ calls held,
# running or preparing), CAP_INFLIGHT (live claims and reservations naming this
# fleet that are no held record's own: a lane whose pane outlived its record's
# running status, or a launch not yet recorded), CAP_ACCOUNT (the lanes on
# LANE, canonical: CAP_ACCOUNT_RECORDS, this fleet's held records whose account
# is LANE, plus CAP_ACCOUNT_OTHER, the live claims and reservations on LANE
# that are no held record's own, which are other fleets' lanes and lanes
# nothing recorded), and CAP_ITEM_HELD and CAP_ITEM_ACCOUNT (whether KEY's own
# record is held, and the account it names). For the fleet count a claim of
# this fleet is a held record's own where it names the record's window, so a
# relaunch onto another account is not a second lane of the fleet. For the
# account count it is one where it names the record's window and account and
# this fleet or none, lib/lane-claims.sh's header saying which claims carry
# none. A record's window is `SESSION:WINDOW`, or bare where written by hand,
# and a claim's is the bare name, so the two are compared on the name. The
# records are this fleet's durable count: a GUI launch writes no claim and a
# claim write can fail, and either lane still has its record. They are read
# after the claim store, because a launch writes its record before it drops
# its reservation: a lane whose reservation the claim read missed is a record
# this read finds. Returns 1 on a store it could not read: a count missing a
# lane is a cap that admits one lane too many.
cap_count() { # ITEM KEY LANE
  local lanes out held owned="" claims counts tag account window rc=0
  claims="$(lane_claims_read "$(lane_claims_dir "$CLAIM_ROOT")" count)" || rc=$?
  [[ "$rc" -eq 0 ]] || { ot_message cap-unreadable "item=$1" "source=claims" >&2; return 1; }
  lanes="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} get oversee '.lanes // []')" || rc=$?
  # One line per held record, tagged and joined by the unit separator, which
  # keeps an empty account or window a field of its own.
  [[ "$rc" -eq 0 ]] && out="$(jq -r --arg key "$2" "$LANE_RUNNING_JQ"'
    ([.[] | objects | select(.item == $key)] | first) as $own
    | (if $own == null then "absent" elif ($own | held) then "held" else "stopped" end),
      ($own.account // ""),
      (.[] | select(held) | ["held", (.account // ""), (.window // "" | sub("^[^:]*:"; ""))] | join("\u001f"))' <<<"$lanes")" || rc=1
  [[ "$rc" -eq 0 ]] || { ot_message cap-unreadable "item=$1" "source=state" >&2; return 1; }
  { read -r CAP_ITEM_HELD; read -r CAP_ITEM_ACCOUNT; held="$(cat)"; } <<<"$out"
  CAP_RUNNING=0
  CAP_ACCOUNT_RECORDS=0
  while IFS=$'\037' read -r tag account window; do
    [[ "$tag" == held ]] || continue
    CAP_RUNNING=$((CAP_RUNNING + 1))
    account="$(lane_claims_canon "$account")" || { ot_message cap-unreadable "item=$1" "source=state" >&2; return 1; }
    [[ -z "$window" ]] || owned+="$window"$'\t'"$account"$'\n'
    [[ -z "$3" || -z "$account" || "$account" != "$3" ]] || CAP_ACCOUNT_RECORDS=$((CAP_ACCOUNT_RECORDS + 1))
  done <<<"$held"
  # A held record's own claims are that record's lane, counted above; this
  # fleet's other claims are the fleet cap's in-flight lanes.
  counts="$(CAP_OWNED="$owned" CAP_FLEET="$CAP_FLEET" CAP_LANE="$3" awk -F'\t' '
    BEGIN {
      n = split(ENVIRON["CAP_OWNED"], w, "\n")
      for (i = 1; i <= n; i++) if (w[i] != "") { owned[w[i]] = 1; sub(/\t.*/, "", w[i]); window[w[i]] = 1 }
    }
    NF && $5 == ENVIRON["CAP_FLEET"] && !($2 in window) { f++ }
    NF && ENVIRON["CAP_LANE"] != "" && $1 == ENVIRON["CAP_LANE"] &&
      !(($5 == ENVIRON["CAP_FLEET"] || $5 == "") && (($2 "\t" $1) in owned)) { a++ }
    END { print f + 0, a + 0 }' <<<"$claims")"
  CAP_INFLIGHT="${counts% *}"
  CAP_ACCOUNT_OTHER="${counts#* }"
  CAP_ACCOUNT=$((CAP_ACCOUNT_RECORDS + CAP_ACCOUNT_OTHER))
}

# Returns 0 with the item's reservation written and the locks released when
# this item may launch, and 1 having released them when it may not, its
# refusal printed. --over-cap admits the
# launch past whichever caps it meets and names them in CAP_PASSED;
# --wait-slot counts again every WAIT_SLOT_POLL_SECS until both caps have room,
# printing slot-waiting whenever the count it waits on changes, and judges the
# lane again before the count that admits it.
cap_gate() { # ITEM KEY WINDOW
  local item="$1" key="$2" lane over stale=false waited_on=""
  CAP_PASSED=""
  while :; do
    lane=""
    [[ -z "$LANE_ENV" ]] || lane="$(lane_claims_canon "${LANE_ENV#*=}")"
    cap_take "$item" || { ot_message cap-lock-failed "item=$item" "lock=$CAP_LOCK_FAILED" >&2; return 1; }
    cap_count "$item" "$key" "$lane" || { cap_release; return 1; }
    over=""
    # A relaunch of a held record replaces its lane, and on the same account
    # its claim.
    if [[ "$RELAUNCH" != true || "$CAP_ITEM_HELD" != held ]]; then
      (( CAP_RUNNING + CAP_INFLIGHT < FLEET_CAP )) || over=fleet
    fi
    if [[ -n "$lane" ]] && (( ACCOUNT_CAP > 0 && CAP_ACCOUNT >= ACCOUNT_CAP )) &&
      [[ "$RELAUNCH" != true || "$CAP_ITEM_HELD" != held || "$(lane_claims_canon "$CAP_ITEM_ACCOUNT")" != "$lane" ]]; then
      over="${over:+$over,}account"
    fi
    if [[ -z "$over" ]]; then
      [[ "$stale" == true ]] || { cap_reserve "$item" "$3"; return; }
      cap_release
      lane_rejudge "$item" || return 1
      stale=false
      continue
    fi
    if [[ "$OVER_CAP" == true ]]; then
      cap_reserve "$item" "$3" || return 1
      # shellcheck disable=SC2034  # read by open-terminal's lane_record_write
      CAP_PASSED="$over"
      ot_message over-cap-admitted "item=$item" "passed=$over" "cap=$FLEET_CAP" "running=$CAP_RUNNING" \
        "claims=$CAP_INFLIGHT" "lane=$lane" "account-cap=$ACCOUNT_CAP" "account-claims=$CAP_ACCOUNT" >&2
      return 0
    fi
    cap_release
    if [[ "$WAIT_SLOT" != true ]]; then
      if [[ "$over" == account ]]; then
        ot_message account-cap-reached "item=$item" "lane=$lane" "cap=$ACCOUNT_CAP" "claims=$CAP_ACCOUNT" \
          "records=$CAP_ACCOUNT_RECORDS" "claims-other=$CAP_ACCOUNT_OTHER" >&2
      else
        ot_message cap-reached "item=$item" "cap=$FLEET_CAP" "running=$CAP_RUNNING" "claims=$CAP_INFLIGHT" >&2
      fi
      return 1
    fi
    # Only the account is full: an auto lane moves to whichever account has room.
    if [[ "$stale" == true && "$over" == account && "$LANE_AUTO" == true ]]; then
      lane_rejudge "$item" || return 1
      stale=false
      continue
    fi
    if [[ "$waited_on" != "$over $CAP_RUNNING $CAP_INFLIGHT $lane $CAP_ACCOUNT" ]]; then
      waited_on="$over $CAP_RUNNING $CAP_INFLIGHT $lane $CAP_ACCOUNT"
      ot_message slot-waiting "item=$item" "over=$over" "cap=$FLEET_CAP" "running=$CAP_RUNNING" \
        "claims=$CAP_INFLIGHT" "lane=$lane" "account-cap=$ACCOUNT_CAP" "account-claims=$CAP_ACCOUNT"
    fi
    sleep "$WAIT_SLOT_POLL_SECS"
    stale=true
  done
}
