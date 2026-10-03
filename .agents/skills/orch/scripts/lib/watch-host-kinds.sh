# shellcheck shell=bash
# How oversee-watch reads each lane by what its host kind declares
# (../../schemas/lane-host.md § Host kinds): the host a state record names and
# its capability line, which fleet_merge routes the record by, and the
# judgement of a lane whose kind declares status=none, which no process read
# reaches. Sourced by oversee-watch, and like the rest of its lib/ it reads
# that script's globals (HOSTED, ROOTS, REPOS, WORK_DIR, PW_SEEN, PASS_NOW,
# MARK_REPEAT, LANE_STALL_SECS) and calls its `die`, `ow_message` and lane row
# helpers.

# The records host_route sorts by their host kind: the host each hosted record
# names, as `<item>=<host>`, the items whose kind declares no mailbox channel,
# no file access or no status read, and those whose status is a provider verb.
HOSTS=()
MAILLESS=()
FILELESS=()
STATUSLESS=()
STATUS_VERB=()
host_routes_reset() { HOSTS=(); MAILLESS=(); FILELESS=(); STATUSLESS=(); STATUS_VERB=(); }

# Routes one running record by its host kind's declared line, never by a host
# name: its files decide where its mailbox, status file and state are read,
# its channel whether the mail pass reads it, and its status how it is judged,
# a provider asked only where the kind declares status=verb.
host_route() { # ITEM HOST ROOT
  local files channel status
  host_capabilities "$2"
  lane_capability files files
  lane_capability channel channel
  lane_capability status status
  case "$files" in
    local) [[ -z "$3" ]] || ROOTS+=("$1=$3") ;;
    verb) HOSTED+=("$1=$3"); HOSTS+=("$1=$2") ;;
    none) FILELESS+=("$1") ;;
    *) die host-capabilities-unread "" "host=$2" "files=$files" ;;
  esac
  case "$channel" in
    mailbox) ;;
    session) MAILLESS+=("$1") ;;
    *) die host-capabilities-unread "" "host=$2" "channel=$channel" ;;
  esac
  case "$status" in
    pane) ;;
    verb) STATUS_VERB+=("$1") ;;
    none) STATUSLESS+=("$1") ;;
    *) die host-capabilities-unread "" "host=$2" "status=$status" ;;
  esac
}

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

# The lane's own open pull request on ITEM's branch, in the first repository
# that holds one: its head commit as OPEN_PR_HEAD and a digest of its body as
# OPEN_PR_DIGEST. Only a head the repository owner holds is the lane's,
# lib/lane-state.sh's lane_own rule, so a fork's pull request on a guessable
# branch name stands for nothing. One `gh pr list` per repository per item per
# long pass: the answer is kept, keyed on the item, for that pass's second
# caller, and the forked long pass bounds its life. Status 0 for one found, 1
# for none open, 2 for a list that failed, its words noted.
OPEN_PR_HEAD=""
OPEN_PR_DIGEST=""
OPEN_PR_SEEN=()
item_open_pr() { # ITEM
  local branch repo list row rc=1 entry
  for entry in ${OPEN_PR_SEEN[@]+"${OPEN_PR_SEEN[@]}"}; do
    [[ "${entry%%|*}" == "$1" ]] || continue
    IFS='|' read -r _ rc OPEN_PR_HEAD OPEN_PR_DIGEST <<<"$entry"
    return "$rc"
  done
  OPEN_PR_HEAD="" OPEN_PR_DIGEST=""
  branch="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for repo in "${REPOS[@]}"; do
    if ! list="$(gh pr list --repo "$repo" --head "$branch" --state open --json headRefName,headRepositoryOwner,headRefOid,body 2>"$WORK_DIR/pr.err")"; then
      ow_message pr-read-failed "item=$1" "repo=$repo" >&2; cat -- "$WORK_DIR/pr.err" >&2; rc=2; break
    fi
    row="$(jq -c --arg branch "$branch" --arg owner "${repo%%/*}" "$LANE_MERGED_JQ"'
      [.[] | lane_own($branch; $owner)] | first // empty' <<<"$list")" || { rc=2; break; }
    [[ -n "$row" ]] || continue
    OPEN_PR_HEAD="$(jq -r '.headRefOid // ""' <<<"$row")" && OPEN_PR_DIGEST="$(jq -r '.body // ""' <<<"$row" | cksum)" \
      || die lane-stall-unread "" "item=$1"
    OPEN_PR_DIGEST="${OPEN_PR_DIGEST%% *}"
    rc=0
    break
  done
  OPEN_PR_SEEN+=("$1|$rc|$OPEN_PR_HEAD|$OPEN_PR_DIGEST")
  return "$rc"
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
    digest="$OPEN_PR_DIGEST"
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
