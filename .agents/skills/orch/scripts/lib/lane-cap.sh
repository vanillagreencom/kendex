# shellcheck shell=bash
#
# Owner: open-terminal, the one script that sources this file.
#
# What a fleet launch is judged on: the overseer binding, the repository the
# launch may run in, and the fleet cap, its count, launch lock, reservation and
# gate. What the cap bounds is stated where open-terminal decides whether a
# launch is judged. It reads open-terminal's globals (CLAIM_ROOT, STATE_DIR,
# WORKFLOW_STATE, the cap setting and options) and calls its ot_message and
# lane_rejudge, so it is loaded by that script alone.
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
# The cap the current item's --over-cap launch passed, `fleet` or `cloud`, empty for a
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
  if ! lane_claim_reserve "$store" "$$" "$2" "$CAP_FLEET" "$HOST_KIND"; then
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

# Sets CAP_RUNNING (records lib/lane-claims.sh's LANE_RUNNING_JQ calls
# in_flight, running, preparing or parked, here called held, in the launch's
# cap), CAP_INFLIGHT
# (live claims and reservations naming this fleet that are no held record's
# own: a lane whose pane outlived its record's running status, or a launch not
# yet recorded), and CAP_ITEM_HELD (whether KEY's own record holds a slot in
# the launch's cap). A claim
# of this fleet is a held record's own where it names the record's window, so a
# relaunch onto another account is not a second lane of the fleet, and a parked
# lane's resume, whose reservation names the window its record kept, is counted
# once. A record's window is `SESSION:WINDOW`, or bare
# where written by hand, and a claim's is the bare name, so the two are
# compared on the name. The records are this fleet's durable count: a GUI
# launch writes no claim and a claim write can fail, and either lane still has
# its record. They are read after the claim store, because a launch writes its
# record before it drops its reservation: a lane whose reservation the claim
# read missed is a record this read finds. Returns 1 on a store it could not
# read: a count missing a lane is a cap that admits one lane too many.
cap_count() { # ITEM KEY
  local lanes out held windows="" claims tag window kind rc=0
  claims="$(lane_claims_read "$(lane_claims_dir "$CLAIM_ROOT")" cap)" || rc=$?
  [[ "$rc" -eq 0 ]] || { ot_message cap-unreadable "item=$1" "source=claims" >&2; return 1; }
  lanes="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} get oversee '.lanes // []')" || rc=$?
  # One line per held record, tagged and joined by the unit separator, which
  # keeps an empty window a field of its own.
  [[ "$rc" -eq 0 ]] && out="$(jq -r --arg key "$2" --arg kind "$HOST_KIND" "$LANE_RUNNING_JQ"'
    def same_cap: (.kind == "claude-cloud") == ($kind == "claude-cloud");
    ([.[] | objects | select(.item == $key)] | first) as $own
    | (if $own == null then "absent" elif ($own | in_flight and same_cap) then "held" else "stopped" end),
      (.[] | select(in_flight) | ["held", (.window // "" | sub("^[^:]*:"; "")), (.kind // "")] | join("\u001f"))' <<<"$lanes")" || rc=1
  [[ "$rc" -eq 0 ]] || { ot_message cap-unreadable "item=$1" "source=state" >&2; return 1; }
  { read -r CAP_ITEM_HELD; held="$(cat)"; } <<<"$out"
  CAP_RUNNING=0
  while IFS=$'\037' read -r tag window kind; do
    [[ "$tag" == held ]] || continue
    if [[ ( "$kind" == claude-cloud && "$HOST_KIND" == claude-cloud ) || ( "$kind" != claude-cloud && "$HOST_KIND" != claude-cloud ) ]]; then
      CAP_RUNNING=$((CAP_RUNNING + 1))
      [[ -z "$window" ]] || windows+="$window"$'\n'
    fi
  done <<<"$held"
  # Only this cap's held windows exclude their own claims. A landing reserves
  # a fleet slot while its old cloud record still holds the same window.
  CAP_INFLIGHT="$(CAP_WINDOWS="$windows" CAP_FLEET="$CAP_FLEET" CAP_KIND="$HOST_KIND" awk -F'\t' '
    BEGIN {
      n = split(ENVIRON["CAP_WINDOWS"], w, "\n")
      for (i = 1; i <= n; i++) if (w[i] != "") window[w[i]] = 1
    }
    NF && $5 == ENVIRON["CAP_FLEET"] && !($2 in window) && (($7 == "claude-cloud") == (ENVIRON["CAP_KIND"] == "claude-cloud")) { f++ }
    END { print f + 0 }' <<<"$claims")"
}

# Returns 0 with the item's reservation written and the lock released when
# this item may launch, and 1 having released it when it may not, its refusal
# printed. A relaunch of a held record in the same cap replaces its lane, so
# it is inside that cap. A cloud landing needs a fleet slot instead. A parked
# lane's resume takes back the slot its record kept. A saved
# foreground preparation continues in its held slot after its identity is
# checked by host_launch_resume. --over-cap admits the launch past the cap and names it in CAP_PASSED;
# --wait-slot counts again every WAIT_SLOT_POLL_SECS until the cap has room,
# printing slot-waiting whenever the count it waits on changes, and judges the
# lane again before the count that admits it.
cap_gate() { # ITEM KEY WINDOW
  local item="$1" key="$2" stale=false waited_on="" cap setting cap_kind
  CAP_PASSED=""
  while :; do
    # The declared kind owns both the count and the bound. A preference
    # rejudgment can change it while --wait-slot is waiting.
    cap="$FLEET_CAP"; setting=ORCH_OVERSEER_LANES; cap_kind=fleet
    if [[ "$HOST_KIND" == claude-cloud ]]; then
      cap="$CLOUD_CAP"; setting=ORCH_OVERSEER_CLOUD_LANES; cap_kind=cloud
    fi
    cap_take "$item" || return 1
    cap_count "$item" "$key" || { cap_release; return 1; }
    if [[ ( "$RELAUNCH" == true || -n "$host_line" ) && "$CAP_ITEM_HELD" == held ]] || (( CAP_RUNNING + CAP_INFLIGHT < cap )); then
      [[ "$stale" == true ]] || { cap_reserve "$item" "$3"; return; }
      cap_release
      lane_rejudge "$item" || return 1
      stale=false
      continue
    fi
    if [[ "$OVER_CAP" == true ]]; then
      cap_reserve "$item" "$3" || return 1
      # shellcheck disable=SC2034  # read by open-terminal's lane_record_write
      CAP_PASSED="$cap_kind"
      ot_message over-cap-admitted "item=$item" "cap=$cap" "running=$CAP_RUNNING" "claims=$CAP_INFLIGHT" "setting=$setting" >&2
      return 0
    fi
    cap_release
    if [[ "$WAIT_SLOT" != true ]]; then
      ot_message cap-reached "item=$item" "cap=$cap" "running=$CAP_RUNNING" "claims=$CAP_INFLIGHT" "setting=$setting" >&2
      return 1
    fi
    if [[ "$waited_on" != "$setting $CAP_RUNNING $CAP_INFLIGHT" ]]; then
      waited_on="$setting $CAP_RUNNING $CAP_INFLIGHT"
      ot_message slot-waiting "item=$item" "cap=$cap" "running=$CAP_RUNNING" "claims=$CAP_INFLIGHT" "setting=$setting"
    fi
    sleep "$WAIT_SLOT_POLL_SECS"
    stale=true
  done
}

# The overseer binding overseer_bind leaves: `own` for a launch in the
# overseer's repository, `connected` for one its ORCH_CONNECTED_REPOS lists,
# whose OWNER/REPO is CONNECTED_REPO, `foreign` for any other, which every item
# refuses naming LAUNCH_NAME and OVERSEER_NAME, `unread` for a state the cap
# count reads first, and `none` for a launch that names no fleet.
OVERSEER_BIND=none
# Retained by the binding owner for connected launches' fleet settings.
OVERSEER_DIR=""
CONNECTED_REPO=""
LAUNCH_NAME=""
OVERSEER_NAME=""

# dotgit_above DIR — whether DIR, a physical path, or a directory above it
# holds a .git entry (a file, a directory or a link, dangling included) where
# git's own discovery would look: the walk stops below the first
# GIT_CEILING_DIRECTORIES entry it reaches, as git does, and DIR itself is
# looked at whatever the ceiling. As in git, an empty entry leaves the entries
# after it unresolved.
dotgit_above() {
  local at="$1" entry ceiling resolve=true ceilings=() parts=()
  IFS=: read -r -a parts <<<"${GIT_CEILING_DIRECTORIES:-}"
  for entry in ${parts[@]+"${parts[@]}"}; do
    [[ -n "$entry" ]] || { resolve=false; continue; }
    ceiling="${entry%/}"
    [[ "$resolve" != true ]] || ceiling="$(cd -P -- "$entry" 2>/dev/null && pwd -P)" || ceiling="${entry%/}"
    ceilings+=("${ceiling:-/}")
  done
  while :; do
    [[ ! -e "$at/.git" && ! -L "$at/.git" ]] || return 0
    [[ "$at" != / ]] || return 1
    at="${at%/*}"
    at="${at:-/}"
    for ceiling in ${ceilings[@]+"${ceilings[@]}"}; do
      [[ "$at" != "$ceiling" ]] || return 1
    done
  done
}

# overseer_bind — judges a --state-dir launch on the repository it runs in,
# before the state is touched: the item check reads the checkout the launch
# runs from, and nothing there binds that checkout to the fleet it records
# into. The overseer's directory is the state's `.overseer.cwd`, else the
# nearest existing directory of the state directory workflow-state resolves
# --state-dir to, which lives in the overseer's checkout. A state that records no overseer directory and sits in
# no checkout names no overseer repository, so the launch binds to its own
# checkout's and goes ahead: absent input never refuses the overseer's own
# work. A recorded directory git cannot read refuses, and so does a state
# directory git cannot read below a .git entry. A checkout sharing that
# directory's git common root, as its worktrees do, or whose origin names the
# same OWNER/REPO, as a second clone does, is own. Any other is connected
# where ORCH_CONNECTED_REPOS lists its origin OWNER/REPO, compared
# case-insensitively, read by lib/gh-repo.sh's orch_connected_repos in the
# overseer's directory with the launcher's own value and private-file selector
# dropped: those are the settings of the checkout the launcher is installed in,
# which can be the target's. A state
# that does not parse is the cap count's cap-unreadable on the first item; a
# wake, which the cap does not count, refuses on it here. Returns 1 with the
# refusal printed.
overseer_bind() {
  local cwd="" dir physical root launch_root same connected listed
  if "$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} exists oversee; then
    if ! cwd="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} get oversee '.overseer.cwd // empty')"; then
      [[ "$CAP_GATED" == true ]] || { ot_message overseer-unjudged cause=state-read state=oversee >&2; return 1; }
      OVERSEER_BIND=unread
      return 0
    fi
  fi
  launch_root="$("$SCRIPT_DIR/git-context" common-root "$CLAIM_ROOT")" \
    || { ot_message overseer-unjudged cause=checkout-root "path=$CLAIM_ROOT" >&2; return 1; }
  if [[ -n "$cwd" ]]; then
    dir="$cwd"
    root="$("$SCRIPT_DIR/git-context" common-root "$dir")" \
      || { ot_message overseer-unjudged cause=overseer-root "path=$cwd" >&2; return 1; }
  else
    # The state directory is the one workflow-state resolves --state-dir to,
    # never its raw spelling: a relative value names a directory under the
    # launch checkout's main root, not under the launcher's cwd. path prints
    # the file whether or not it exists yet.
    dir="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} path oversee)" \
      || { ot_message overseer-unjudged cause=state-read state=oversee >&2; return 1; }
    dir="${dir%/*}"
    dir="${dir:-/}"
    while [[ ! -d "$dir" ]]; do dir="$(dirname -- "$dir")"; done
    physical="$(cd -P -- "$dir" && pwd -P)" \
      || { ot_message overseer-unjudged cause=overseer-root "path=$dir" >&2; return 1; }
    dir="$physical"
    # git exits alike for a directory in no checkout and for a checkout it
    # cannot read: a .git entry at or above the directory tells them apart.
    # With one, git's failure refuses, git's own line above the refusal. With
    # none, git answered for the launch checkout above, so a failure reads as
    # a state directory outside any checkout, and git's line for it is noise.
    if dotgit_above "$dir"; then
      root="$("$SCRIPT_DIR/git-context" common-root "$dir")" \
        || { ot_message overseer-unjudged cause=overseer-root "path=$dir" >&2; return 1; }
    else
      root="$("$SCRIPT_DIR/git-context" common-root "$dir" 2>/dev/null)" || { root="$launch_root"; }
    fi
  fi
  OVERSEER_DIR="$dir"
  OVERSEER_BIND=own
  [[ "$root" != "$launch_root" ]] || return 0
  LAUNCH_NAME="$(kendex_github_origin_slug "$CLAIM_ROOT")" || LAUNCH_NAME=""
  OVERSEER_NAME="$(kendex_github_origin_slug "$dir")" || OVERSEER_NAME=""
  if [[ -n "$LAUNCH_NAME" ]]; then
    same="$(jq -n --arg a "$LAUNCH_NAME" --arg b "$OVERSEER_NAME" '($a | ascii_downcase) == ($b | ascii_downcase)')" \
      || { ot_message overseer-unjudged cause=origin "path=$CLAIM_ROOT" >&2; return 1; }
    [[ "$same" != true ]] || return 0
  fi
  OVERSEER_BIND=foreign
  connected="$(cd -- "$dir" && unset ORCH_CONNECTED_REPOS KENDEX_ENV_FILE && orch_connected_repos)" \
    || { ot_message overseer-unjudged cause=setting "path=$dir" >&2; return 1; }
  if [[ -n "$connected" ]]; then
    [[ -n "$LAUNCH_NAME" ]] || { ot_message overseer-unjudged cause=origin "path=$CLAIM_ROOT" >&2; return 1; }
    listed="$(printf '%s' "$LAUNCH_NAME" | tr '[:upper:]' '[:lower:]')"
    # shellcheck disable=SC2034  # read by open-terminal's item loop and lane_record_write
    if grep -qxF -- "$listed" <<<"$connected"; then OVERSEER_BIND=connected; CONNECTED_REPO="$LAUNCH_NAME"; fi
  fi
  OVERSEER_NAME="${OVERSEER_NAME:-$root}"
  LAUNCH_NAME="${LAUNCH_NAME:-$launch_root}"
}
