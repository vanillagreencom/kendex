# shellcheck shell=bash
# How oversee-watch reads each lane by what its host kind declares
# (../../schemas/lane-host.md § Host kinds): the host a state record names and
# its capability line, which fleet_merge routes the record by, and the
# judgement of a lane whose kind declares status=none, which no process read
# reaches. Sourced by oversee-watch, and like the rest of its lib/ it reads
# that script's globals (HOSTS, REPOS, WORK_DIR, PW_SEEN, PASS_NOW,
# MARK_REPEAT, LANE_STALL_SECS) and calls its `die`, `ow_message` and lane row
# helpers.

# RECORD_HOST, the host the item's state record names, from HOSTS; status 1
# for an item no record places on a host.
RECORD_HOST=""
record_host() { # ITEM
  local entry
  RECORD_HOST=""
  for entry in ${HOSTS[@]+"${HOSTS[@]}"}; do
    [[ "${entry%%=*}" == "$1" ]] || continue
    RECORD_HOST="${entry#*=}"
    return 0
  done
  return 1
}
# Whether ITEM is one of the items that follow it, for the per-capability
# item lists fleet_merge builds.
item_in() { # ITEM ITEMS...
  local item="$1" entry
  shift
  for entry in "$@"; do [[ "$entry" != "$item" ]] || return 0; done
  return 1
}
# The capability line each host a record names declares, read once per host
# per process (../../schemas/lane-host.md § Host kinds), as `<host><US><line>`.
HOST_CAPABILITIES=()
host_capabilities() { # HOST — sets LANE_CAPABILITIES
  local entry
  for entry in ${HOST_CAPABILITIES[@]+"${HOST_CAPABILITIES[@]}"}; do
    [[ "${entry%%$'\x1f'*}" == "$1" ]] || continue
    LANE_CAPABILITIES="${entry#*$'\x1f'}"
    return 0
  done
  # lane-host's own words reach stderr ahead of the refusal: the first
  # fleet read runs before the scratch directory a detail is kept in.
  lane_capabilities_read "$SCRIPT_DIR/lane-host" "$1" || die host-capabilities-unread "" "host=$1"
  HOST_CAPABILITIES+=("$1"$'\x1f'"$LANE_CAPABILITIES")
}

# The open pull request on ITEM's branch, in the first repository that holds
# one, its head commit as OPEN_PR_HEAD and its body as OPEN_PR_BODY. Status 0
# for one found, 1 for none open, 2 for a list that failed, its words noted.
OPEN_PR_HEAD=""
OPEN_PR_BODY=""
item_open_pr() { # ITEM
  local branch repo list
  branch="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for repo in "${REPOS[@]}"; do
    list="$(gh pr list --repo "$repo" --head "$branch" --state open --limit 1 --json headRefOid,body 2>"$WORK_DIR/pr.err")" \
      || { ow_message pr-read-failed "item=$1" "repo=$repo" >&2; cat -- "$WORK_DIR/pr.err" >&2; return 2; }
    OPEN_PR_HEAD="$(jq -r '.[0].headRefOid // empty' <<<"$list")" || return 2
    [[ -n "$OPEN_PR_HEAD" ]] || continue
    OPEN_PR_BODY="$(jq -r '.[0].body // ""' <<<"$list")" || return 2
    return 0
  done
  return 1
}

# A running lane whose kind declares status=none, a cloud session no process
# read reaches, is judged by what it pushes: once its pull request is open,
# neither its head nor the `## Lane status` body moving for
# LANE_STALL_SECS is lane-stalled, whether it stopped on a question, lost its
# machine or spent its credit. The row keeps the head, a digest of the body
# and the epoch either last moved, so a change resets the window. Reported
# once, then every MARK_REPEAT passes while it stands. Before the pull request
# opens the start-stall check holds the lane, so a lane with none has no row.
check_lane_stall() {
  local item prior head digest since passes age rc rows="${PW_SEEN[0]}" items=()
  for item in ${STATUSLESS[@]+"${STATUSLESS[@]}"}; do
    items+=("$item")
    rc=0
    item_open_pr "$item" || rc=$?
    case "$rc" in
      0) ;;
      1) rows="$(lane_row_clear lane-stalled "$rows" "$item")"; continue ;;
      *) continue ;;
    esac
    digest="$(printf '%s' "$OPEN_PR_BODY" | cksum)" || die lane-stall-unread "" "item=$item"
    digest="${digest%% *}"
    if ! prior="$(lane_row_get lane-stalled "$rows" "$item")"; then
      die state-read-failed "" "item=$item" "row=lane-stalled"
    fi
    if [[ "$prior" != "$OPEN_PR_HEAD|$digest|"* ]]; then
      rows="$(lane_row_set lane-stalled "$rows" "$item" "$OPEN_PR_HEAD|$digest|$PASS_NOW|")"
      continue
    fi
    IFS='|' read -r head digest since passes <<<"$prior"
    age=$((PASS_NOW - since))
    (( age >= LANE_STALL_SECS )) || continue
    if [[ -z "$passes" ]]; then passes=0
    else passes=$(( passes + 1 )); (( passes < MARK_REPEAT )) || passes=0; fi
    if (( passes == 0 )); then
      echo "EVENT lane-stalled $item age=$age"
      PASS_EVENT=1
    fi
    rows="$(lane_row_set lane-stalled "$rows" "$item" "$head|$digest|$since|$passes")"
  done
  rows="$(lane_row_prune lane-stalled "$rows" ${items[@]+"${items[@]}"})"
  lane_row_commit "$rows"
}
