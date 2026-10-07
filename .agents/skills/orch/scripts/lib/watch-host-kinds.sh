# shellcheck shell=bash
# How oversee-watch reads each lane by what its host kind declares
# (../../schemas/lane-host.md § Host kinds): the host a state record names and
# its capability line, which fleet_merge routes the record by, where each
# lane's files are read and the host a lane-host read of it runs under, the
# judgement of a lane whose kind declares status=none, which no process read
# reaches, and the lane-long age of every running or parked lane. Sourced by oversee-watch, and like the rest of its lib/ it reads
# that script's globals (SCRIPT_DIR, HOSTED, ROOTS, REPOS, WORK_DIR, PW_SEEN,
# PASS_NOW, MARK_REPEAT, LANE_STALL_SECS, LANE_AGE_SECS, LANE_AGES,
# RECORDED_ITEMS) and calls its `die`, `ow_message`,
# `lane_failure_set` and lane row helpers, and those of lib/lane-gitfile.sh and
# lib/lane-capabilities.sh, which that script sources before this file.

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
# A hosted lane is read through `lane-host` under its record's host. One
# passed by hand with --hosted names none, so it is read under the host
# `lane-host resolve` answers, and where that is `local` every such read
# would be made on this disk where the lane is not. Asked once per process,
# the first time such a lane is carried, so a fleet that gains one while the
# run loops is judged then.
LANE_HOST_SPEC=""
check_lane_host() {
  local out entry items=""
  for entry in ${HOSTED[@]+"${HOSTED[@]}"}; do
    record_host "${entry%%=*}" || items+="${items:+,}${entry%%=*}"
  done
  [[ -n "$items" ]] || return 0
  if [[ -z "$LANE_HOST_SPEC" ]]; then
    out="$("$SCRIPT_DIR/lane-host" resolve 2>&1)" \
      || die host-resolve-failed "$out" "path=$SCRIPT_DIR/lane-host"
    LANE_HOST_SPEC="$out"
  fi
  [[ "$LANE_HOST_SPEC" == local ]] || return 0
  die hosted-without-host "" "items=$items" "host=local"
}
# HOSTED_ROOT is the item's lane root on its own host, empty for a lane on this
# disk, and HOSTED_HOST the host every lane-host read of it runs under: the
# one its record names, or for a --hosted entry the one lane-host resolves.
# Set rather than printed: a substitution would carry the lookup's own status
# out under errexit, and a fleet with no hosted lane at all is the common case.
HOSTED_ROOT=""
HOSTED_HOST=""
hosted_root() { # ITEM
  local entry
  HOSTED_ROOT=""
  HOSTED_HOST=""
  for entry in ${HOSTED[@]+"${HOSTED[@]}"}; do
    [[ "${entry%%=*}" == "$1" ]] || continue
    HOSTED_ROOT="${entry#*=}"
    HOSTED_HOST="$LANE_HOST_SPEC"
    ! record_host "$1" || HOSTED_HOST="$RECORD_HOST"
    return 0
  done
}
# The item's lane worktree on this disk as LOCAL_ROOT, from a --root entry;
# empty when none names it, and the mail pass then lets lane-mail resolve it.
LOCAL_ROOT=""
local_root() { # ITEM
  local entry
  LOCAL_ROOT=""
  for entry in ${ROOTS[@]+"${ROOTS[@]}"}; do
    [[ "${entry%%=*}" == "$1" ]] || continue
    LOCAL_ROOT="${entry#*=}"
    return 0
  done
}
# Whether a route of either type already names the item, for the state merge:
# a state record of either type displaces a hand-passed entry, so a lane that
# moved between this disk and a host is read where its record says.
route_listed() { # ITEM
  hosted_root "$1"
  [[ -z "$HOSTED_ROOT" ]] || return 0
  local_root "$1"
  [[ -n "$LOCAL_ROOT" ]]
}
# The clone a hosted lane's worktree belongs to, which its record does not
# carry: the worktree's `.git` file names it while the worktree stands, read
# through lane-gitfile.sh's lane_hosted_clone, and STATE's clone-root row
# keeps it for after ../../workflows/merge-pr.md § 5 removes the worktree. A
# root that is itself a clone is its own clone. Sets HOSTED_CLONE, and
# HOSTED_GONE to 1 when the worktree is gone. Call after hosted_root.
hosted_clone() { # ITEM STATE
  local rc=0
  HOSTED_GONE=0
  ORCH_LANE_HOST="$HOSTED_HOST" lane_hosted_clone "$SCRIPT_DIR/lane-host" "$1" "$HOSTED_ROOT" "$WORK_DIR/gitfile" "$WORK_DIR/host.err" || rc=$?
  case "$rc" in
    0) HOSTED_CLONE="$LANE_HOSTED_CLONE" ;;
    3)
      lane_failure_set handoff-read-failed "" "item=$1" "path=$HOSTED_ROOT/.git" "value=${LANE_HOSTED_GITLINE:-<empty>}"
      return 1 ;;
    4) lane_failure_set lane-host-busy "" "item=$1"; return 1 ;;
    1)
      HOSTED_GONE=1
      if ! HOSTED_CLONE="$(lane_row_get clone-root "$2" "$1")" || [[ -z "$HOSTED_CLONE" ]]; then
        lane_failure_set handoff-read-failed "" "item=$1" "clone=unknown"
        return 1
      fi ;;
    *)
      lane_failure_set handoff-read-failed "$(cat "$WORK_DIR/host.err")" \
        "item=$1" "path=$HOSTED_ROOT/.git"
      return 1 ;;
  esac
}
# One hosted state file, ROOT's STATE_DIR copy of ITEM's, fetched into DEST.
hosted_state_fetch() { # ITEM ROOT STATE_DIR DEST
  local rc=0
  lane_hosted_state_path "$2" "$3" "$1"
  ORCH_LANE_HOST="$HOSTED_HOST" lane_host_fetch "$SCRIPT_DIR/lane-host" "$1" "$LANE_HOSTED_STATE_PATH" \
    "$4/workflow-state-$1.json" "$WORK_DIR/host.err" || rc=$?
  [[ "$rc" -ne 4 ]] || { lane_failure_set lane-host-busy "" "item=$1"; return 1; }
  if [[ "$rc" -gt 1 ]]; then
    lane_failure_set handoff-read-failed "$(cat "$WORK_DIR/host.err")" "item=$1" "path=${LANE_HOSTED_STATE_PATH%/*}"
    return 1
  fi
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
      [.[] | lane_own($branch; $owner; null)] | first // empty' <<<"$list")" || { rc=2; break; }
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

# A running or parked lane LANE_AGE_SECS past its record's launched_at, which
# --relaunch and handoffs keep and a fresh launch after lane-close renews, is
# reported lane-long once per age interval, its stage the Step line of its
# status file. Keep the launch with the interval so a fresh launch starts over.
check_lane_long() {
  local entry item launched age interval prior rows="${PW_SEEN[0]}"
  for entry in ${LANE_AGES[@]+"${LANE_AGES[@]}"}; do
    item="${entry%%=*}"
    launched="${entry#*=}"
    age=$((PASS_NOW - launched))
    (( age >= LANE_AGE_SECS )) || continue
    interval=$((age / LANE_AGE_SECS))
    if ! prior="$(lane_row_get lane-long "$rows" "$item")"; then
      die state-read-failed "" "item=$item" "row=lane-long"
    fi
    # Older watch runs stored only launched_at after their first report.
    [[ "$prior" != "$launched" ]] || prior="$launched|1"
    [[ "$prior" != "$launched|$interval" ]] || continue
    lane_step "$item"
    echo "EVENT lane-long $item age=$age stage=$LANE_STEP"
    PASS_EVENT=1
    rows="$(lane_row_set lane-long "$rows" "$item" "$launched|$interval")"
  done
  # Pruned only once no record names the item, so the gap a relaunch or a
  # handoff leaves between running records keeps the reported interval.
  rows="$(lane_row_prune lane-long "$rows" ${RECORDED_ITEMS[@]+"${RECORDED_ITEMS[@]}"})"
  lane_row_commit "$rows"
}

# The Step line of ITEM's status file as LANE_STEP: `parked` for a parked lane,
# whose disk is stopped, `unread` where its read failed, and `none` where
# the lane writes no file or its file names no step.
lane_step() { # ITEM
  local file
  LANE_STEP=parked
  ! item_parked "$1" || return 0
  LANE_STEP=none
  hosted_root "$1"
  local_root "$1"
  if item_in "$1" ${FILELESS[@]+"${FILELESS[@]}"}; then return 0
  elif [[ -n "$HOSTED_ROOT" ]]; then
    file="$WORK_DIR/status-probe"
    ORCH_LANE_HOST="$HOSTED_HOST" lane_host_fetch "$SCRIPT_DIR/lane-host" "$1" "$HOSTED_ROOT/tmp/lane-status-$1.md" \
      "$file" "$WORK_DIR/host.err" || { [[ $? -eq 1 ]] || LANE_STEP=unread; return 0; }
  elif [[ -n "$LOCAL_ROOT" ]]; then file="$LOCAL_ROOT/tmp/lane-status-$1.md"
  else return 0
  fi
  [[ -f "$file" ]] || return 0
  # Lanes write the line bare or as a Markdown list item.
  if ! LANE_STEP="$(awk 'tolower($0) ~ /^([-*][ \t]+)?step:/ { sub(/^[^:]*:[ \t]*/, ""); print; exit }' "$file")"; then LANE_STEP=unread
  elif [[ -z "$LANE_STEP" ]]; then LANE_STEP=none
  fi
}
