# shellcheck shell=bash
# How oversee-watch reads each lane by what its host kind declares
# (../../schemas/lane-host.md § Host kinds): the host a state record names and
# its capability line, which fleet_merge routes the record by, where each
# lane's files are read and the host a lane-host read of it runs under, the
# judgement of a lane whose kind declares status=none, which no process read
# reaches, and the lane-long age of every running or parked lane. Sourced by oversee-watch, and like the rest of its lib/ it reads
# that script's globals (SCRIPT_DIR, HOSTED, ROOTS, REPOS, WORK_DIR, PW_SEEN,
# PASS_NOW, MARK_REPEAT, LANE_STALL_SECS, CLOUD_STALL_SECS, LANE_AGE_SECS,
# LANE_AGES, RECORDED_ITEMS, FLEET_STATE) and calls its `die`, `ow_message`,
# `close_hosted_lane`, `lane_failure_set` and lane row helpers, and those of
# lib/lane-gitfile.sh and lib/lane-capabilities.sh, which that script sources
# before this file.

# The cycle owner's interval union also supplies long-lane and report time.
# A malformed or reversed interval is unavailable, never a zero pause.
LANE_INTERVALS_JQ='  def covered_seconds($spans; $from; $to):
    ($spans | map({a: ([.from, $from] | max), b: ([.to // $to, $to] | min)})
     | map(select(.b > .a)) | sort_by(.a)
     | reduce .[] as $p ([]; if length > 0 and $p.a <= .[-1].b
         then .[-1].b = ([.[-1].b, $p.b] | max) else . + [$p] end)) as $union
    | [$union[] | .b - .a] | add // 0;

  def lane_pauses($park_only):
    if .parked.timing_unread == true or .dependency_wait.timing_unread == true
       or (.parked.wait != null and (.parked.phase // "" | . == "stop-unconfirmed" or startswith("start-")))
       or (.dependency_wait.wait != null and .dependency_wait.phase == "stop-unconfirmed")
       or any(.pauses[]?; .timing_unread == true) then error("pause-ack-unread") else . end
    | ([ (.pauses // [])[] | select(($park_only | not) or .cause == "parked")
       | {from:(.from | fromdateiso8601),to:(if .to == null then null else .to | fromdateiso8601 end)} ]
     + [ .parked.at, (if $park_only then null else .walled.at end)
         | select(. != null) | {from:fromdateiso8601,to:null} ])
    | if any(.[]; .to != null and .to < .from) then error("reversed-pause") else . end;
  def lane_parked_seconds($from; $to): lane_pauses(true)
    | if any(.[]; .from > $to or (.to != null and .to > $to)) then error("future-pause") else covered_seconds(.; $from; $to) end;
'

# The successful-push reader is shared with the cycle recorder. The recorded
# commit must be the push tip or contained by a later push on that exact branch.
lane_push_time() { # REPO BRANCH COMMIT LAUNCHED_AT SCRATCH
  local repo="$1" base="$2" commit="$3" launched_at="$4" work="$5" query launched span at after status
  MERGED_AT="" MERGED_CAUSE=""
  : >"$work/push.err"
  query="ref=$(jq -rn --arg r "refs/heads/$base" '$r | @uri')&activity_type=push&per_page=100"
  launched="$(jq -rn --arg at "$launched_at" '$at | fromdate' 2>"$work/push.err")" \
    || { MERGED_CAUSE="launch-unreadable"; return; }
  for span in day:86400 week:604800 month:2419200 quarter:7689600 year:31536000; do
    if [[ -n "$launched" ]] && (( $(date +%s) - launched + 3600 < ${span#*:} )); then
      query+="&time_period=${span%%:*}"
      break
    fi
  done
  if ! gh api --paginate "repos/$repo/activity?$query" >"$work/activity.json" 2>"$work/push.err" \
    || ! jq -rs --arg commit "$commit" --arg since "${launched:-0}" '[.[][] | {at: .timestamp, after}] | sort_by(.at)
      | ([.[] | select(.after == $commit)] | first | .at // empty | "\(.) exact"),
        (.[] | select((.at | fromdate) >= ($since | tonumber)) | "\(.at) \(.after)")' \
      "$work/activity.json" >"$work/pushes" 2>"$work/push.err"; then
    MERGED_CAUSE="activity-unread"
    return
  fi
  while read -r at after; do
    if [[ "$after" != exact ]]; then
      status="$(gh api "repos/$repo/compare/$commit...$after" --jq .status 2>"$work/push.err")" \
        || { MERGED_CAUSE="compare-failed"; return; }
      [[ "$status" == ahead ]] || continue
    fi
    MERGED_AT="$at"
    return
  done <"$work/pushes"
  MERGED_CAUSE="no-push"
}

# The writer supplies its checkout. A recorder in a connected repository uses
# the fleet's registered cwd, then its state directory, to find that checkout.
# Keep linked-worktree roots: the watch stores its rows there, not in the clone.
# A fleet with no checkout address uses the caller, as a watch without state does.
lane_watch_state_dir() { # CALLER_ROOT [FLEET_STATE_FILE]
  local owner="" dir="" root candidate git_context="${BASH_SOURCE[0]%/*}/../git-context"
  if [[ -n "${OVERSEE_WATCH_STATE_DIR:-}" ]]; then
    printf '%s\n' "$OVERSEE_WATCH_STATE_DIR"
    return 0
  fi
  if [[ -n "${2:-}" ]]; then
    owner="$(jq -r '.overseer.cwd // empty' "$2")" || return 2
    dir="${2%/*}"
    [[ "$dir" != "$2" ]] || dir=.
  fi
  for candidate in "$owner" "$dir" "$1"; do
    [[ -n "$candidate" ]] || continue
    if root="$("$git_context" repo-root "$candidate" 2>/dev/null)"; then
      printf '%s/tmp/oversee-watch\n' "$root"
      return 0
    fi
  done
  printf '%s/tmp/oversee-watch\n' "$1"
}

# Shared row reads also serve the cycle recorder after worktree disposal.
lane_row_value() { # ROW PREFIX
  LANE_ROW_VALUE="${1#"$2"}"
  [[ "$1" == "$2"* && "$LANE_ROW_VALUE" != *$'\t'* ]]
}
lane_row_get() {
  local row prefix="$1"$'\t'"$3"$'\t' value
  if [[ "$MAIL_ROW_MODE" -eq 1 ]]; then
    mail_row_find "$prefix"
    LANE_ROW=""
    [[ "$MAIL_ROW_INDEX" -lt 0 ]] || LANE_ROW="${MAIL_ROW_VALUES[$MAIL_ROW_INDEX]}"
    [[ -z "$LANE_ROW" ]] || printf '%s\n' "$LANE_ROW"
    return 0
  fi
  LANE_ROW=""
  while IFS= read -r row; do
    [[ "$row" == "$prefix"* ]] || continue
    lane_row_value "$row" "$prefix" || continue
    value="$LANE_ROW_VALUE"
    LANE_ROW+="$value"$'\n'
  done <<<"$2"
  LANE_ROW="${LANE_ROW%$'\n'}"
  [[ -z "$LANE_ROW" ]] || printf '%s\n' "$LANE_ROW"
  return 0
}

# The watch retains clone-root rows for all its repositories in its primary
# repository's .mail file. A recorder has no --since binding, so all files
# must agree on this item; selecting
# one of conflicting roots could read another launch's rounds.
LANE_RETAINED_CLONE=""
lane_retained_clone() { # ITEM DIRECTORY
  local file rows roots root MAIL_ROW_MODE=0
  LANE_RETAINED_CLONE=""
  for file in "$2/"*.mail; do
    [[ -e "$file" || -L "$file" ]] || continue
    if ! rows="$(cat -- "$file")"; then
      printf 'lane-gitfile: clone-root-unread item=%s path=%s\n' "$1" "$file" >&2
      return 2
    fi
    roots="$(lane_row_get clone-root "$rows" "$1")" || return 2
    while IFS= read -r root; do
      [[ -n "$root" ]] || continue
      if [[ "$root" != /* || "$root" == *$'\t'* ]]; then
        printf 'lane-gitfile: clone-root-invalid item=%s path=%s value=%s\n' "$1" "$file" "$root" >&2
        return 2
      fi
      if [[ -n "$LANE_RETAINED_CLONE" && "$LANE_RETAINED_CLONE" != "$root" ]]; then
        printf 'lane-gitfile: clone-root-ambiguous item=%s path=%s first=%s other=%s\n' "$1" "$file" "$LANE_RETAINED_CLONE" "$root" >&2
        LANE_RETAINED_CLONE=""
        return 2
      fi
      LANE_RETAINED_CLONE="$root"
    done <<<"$roots"
  done
}

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
# A local lane's main checkout, retained for notices sent after merge-pr
# removes its worktree. Call after local_root; sets LOCAL_CLONE and LOCAL_GONE.
local_clone() { # ITEM STATE
  LOCAL_GONE=0
  LOCAL_CLONE=""
  if [[ -d "$LOCAL_ROOT" ]]; then
    # Learning the fallback is advisory while the mailbox itself still stands.
    # An explicit local root can be a plain directory; retry on the next pass.
    LOCAL_CLONE="$("$SCRIPT_DIR/git-context" common-root "$LOCAL_ROOT" 2>/dev/null)" || LOCAL_CLONE=""
  else
    LOCAL_GONE=1
    if ! LOCAL_CLONE="$(lane_row_get clone-root "$2" "$1")" || [[ -z "$LOCAL_CLONE" ]]; then
      lane_failure_set handoff-read-failed "" "item=$1" "clone=unknown"
      return 1
    fi
  fi
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
# OPEN_PR_DIGEST, and its draft flag as OPEN_PR_DRAFT. With none open, OPEN_PR_BRANCH_HEAD holds the item branch's
# heads by repository, including an empty value when no branch exists, and
# OPEN_PR_BRANCH_DATE the newest of their committed dates in epoch seconds. A
# branch head is observed progress; a commit date cannot date its push, but a
# head committed after a launch was pushed after it.
# Only a head the repository owner holds is the lane's,
# lib/lane-state.sh's lane_own rule, so a fork's pull request on a guessable
# branch name stands for nothing. One `gh pr list` per repository per item per
# long pass: the answer is kept, keyed on the item, for that pass's second
# caller, and the forked long pass bounds its life. Status 0 for one found, 1
# for none open, 2 for a list that failed, its words noted.
OPEN_PR_HEAD=""
OPEN_PR_DIGEST=""
OPEN_PR_DRAFT=""
OPEN_PR_BRANCH_HEAD=""
OPEN_PR_BRANCH_DATE=""
OPEN_PR_SEEN=()
item_open_pr() { # ITEM
  local branch repo list row branch_head committed rc=1 entry
  for entry in ${OPEN_PR_SEEN[@]+"${OPEN_PR_SEEN[@]}"}; do
    [[ "${entry%%|*}" == "$1" ]] || continue
    IFS='|' read -r _ rc OPEN_PR_HEAD OPEN_PR_DIGEST OPEN_PR_BRANCH_HEAD OPEN_PR_BRANCH_DATE OPEN_PR_DRAFT <<<"$entry"
    return "$rc"
  done
  OPEN_PR_HEAD="" OPEN_PR_DIGEST="" OPEN_PR_BRANCH_HEAD="" OPEN_PR_BRANCH_DATE="" OPEN_PR_DRAFT=""
  branch="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  for repo in "${REPOS[@]}"; do
    if ! list="$(gh pr list --repo "$repo" --head "$branch" --state open --json headRefName,headRepositoryOwner,headRefOid,body,isDraft 2>"$WORK_DIR/pr.err")"; then
      ow_message pr-read-failed "item=$1" "repo=$repo" >&2; cat -- "$WORK_DIR/pr.err" >&2; rc=2; break
    fi
    row="$(jq -c --arg branch "$branch" --arg owner "${repo%%/*}" "$LANE_MERGED_JQ"'
      [.[] | lane_own($branch; $owner; null)] | first // empty' <<<"$list")" || { rc=2; break; }
    if [[ -z "$row" ]]; then
      if ! list="$(gh api graphql -f owner="${repo%%/*}" -f name="${repo#*/}" -f ref="refs/heads/$branch" \
        -f query='query($owner:String!, $name:String!, $ref:String!) {
          repository(owner:$owner, name:$name) { ref(qualifiedName:$ref) { target { ... on Commit { oid committedDate } } } }
        }' 2>"$WORK_DIR/pr.err")" || ! branch_head="$(jq -er '
          .data.repository | if type != "object" then error("repository unread")
          elif (has("ref") | not) then error("branch unread")
          elif .ref == null then ""
          elif (.ref.target.oid | type == "string" and test("^[0-9a-f]{40}$"))
            and (.ref.target.committedDate | type == "string") then
            "\(.ref.target.oid) \(.ref.target.committedDate | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601)"
          else error("branch head unread") end' <<<"$list" 2>"$WORK_DIR/pr.err")"; then
        ow_message branch-read-failed "item=$1" "repo=$repo" >&2; cat -- "$WORK_DIR/pr.err" >&2; rc=2; break
      fi
      if [[ -n "$branch_head" ]]; then
        committed="${branch_head#* }"
        OPEN_PR_BRANCH_HEAD+="${OPEN_PR_BRANCH_HEAD:+,}$repo:${branch_head%% *}"
        (( ${OPEN_PR_BRANCH_DATE:-0} >= committed )) || OPEN_PR_BRANCH_DATE="$committed"
      fi
      continue
    fi
    OPEN_PR_HEAD="$(jq -r '.headRefOid // ""' <<<"$row")" && OPEN_PR_DIGEST="$(jq -r '.body // ""' <<<"$row" | cksum)" \
      && OPEN_PR_DRAFT="$(jq -r '.isDraft | if type == "boolean" then tostring else "" end' <<<"$row")" \
      || die lane-stall-unread "" "item=$1"
    OPEN_PR_DIGEST="${OPEN_PR_DIGEST%% *}"
    rc=0
    break
  done
  OPEN_PR_SEEN+=("$1|$rc|$OPEN_PR_HEAD|$OPEN_PR_DIGEST|$OPEN_PR_BRANCH_HEAD|$OPEN_PR_BRANCH_DATE|$OPEN_PR_DRAFT")
  return "$rc"
}

# A running lane whose kind declares status=none, a cloud session no process
# read reaches, reports a ready pull request or exhausted account at once.
# Unknown draft or credit readings keep the age route: once its pull request is open,
# neither its head nor the `## Lane status` body moving for
# LANE_STALL_SECS is lane-stalled, whether it stopped on a question, lost its
# machine or spent its credit. The row keeps the head, a digest of the body
# and the epoch either last moved, plus the reported state word. Reported
# once, then every MARK_REPEAT passes while it stands. Before the pull request
# opens the start-stall check holds the lane, reports its branch head standing
# still and bounds a directive its pushes leave unanswered, so a lane with
# none has no row.
check_lane_stall() {
  local item prior head digest since passes age rc state reported rows="${PW_SEEN[0]}" items=()
  for item in ${STATUSLESS[@]+"${STATUSLESS[@]}"}; do
    items+=("$item")
    rc=0
    item_open_pr "$item" || rc=$?
    case "$rc" in
      0) ;;
      1) rows="$(lane_row_clear lane-stalled "$rows" "$item")"; continue ;;
      *) continue ;;
    esac
    state=""
    if [[ "$OPEN_PR_DRAFT" == false ]]; then state=finished
    elif [[ "$OPEN_PR_DRAFT" == true && "$ACCOUNT_ROSTER_RC" -eq 0 ]]; then
      state="$(jq -r --arg item "$item" --argjson accounts "$ACCOUNT_ROSTER_JSON" '
        [.lanes[]? | objects | select(.item == $item) | .account | strings] | first as $account
        | [$accounts[] | select(.config_dir == $account) | .credits | objects
            | select(.locked_reason != null or (.remaining_dollars | numbers | . <= 0))]
        | if length > 0 then "out-of-credit" else "" end' <<<"$FLEET_STATE")" \
        || die lane-stall-unread "" "item=$item"
    fi
    if ! prior="$(lane_row_get lane-stalled "$rows" "$item")"; then
      die state-read-failed "" "item=$item" "row=lane-stalled"
    fi
    IFS='|' read -r head digest since passes reported <<<"$prior"
    digest="$OPEN_PR_DIGEST"
    if [[ "$prior" != "$OPEN_PR_HEAD|$digest|"* ]]; then
      head="$OPEN_PR_HEAD" since="$PASS_NOW"
      [[ -n "$state" ]] || passes=""
    fi
    age=$((PASS_NOW - since))
    if [[ -z "$state" ]] && (( age < LANE_STALL_SECS )); then
      rows="$(lane_row_set lane-stalled "$rows" "$item" "$head|$digest|$since||")"
      continue
    fi
    # A ready PR waits for landing; closing it would relaunch completed work.
    if [[ "$state" != finished ]] && (( age >= LANE_STALL_SECS )) && cloud_stall_close "$item" "$since"; then
      lane_row_commit "$rows"
      [[ -z "$CLOSE_TERMED" ]] || exit 143
      continue
    fi
    [[ "$state" == "$reported" ]] || passes=""
    if [[ -z "$passes" ]]; then passes=0
    else passes=$(( passes + 1 )); (( passes < MARK_REPEAT )) || passes=0; fi
    if (( passes == 0 )); then
      echo "EVENT lane-stalled $item age=$age${state:+ state=$state}"
      PASS_EVENT=1
    fi
    rows="$(lane_row_set lane-stalled "$rows" "$item" "$head|$digest|$since|$passes|$state")"
  done
  rows="$(lane_row_prune lane-stalled "$rows" ${items[@]+"${items[@]}"})"
  lane_row_commit "$rows"
}

# A stalled cloud lane that answered no directive: the directive_send
# lane-mail recorded on its record is at or after SINCE, the last move the
# stall check saw, and CLOUD_STALL_SECS old with nothing pushed since. No read
# of a cloud session's state tells a long step from a dead session (Claude
# Code 2.1.295 documents none), so the bound decides: close_hosted_lane closes
# the record through lane-close, whose fleet-log row carries the send's cause
# readings, and cloud-stall-closed hands the item to the overseer's hosted
# relaunch on its branch. Status 0 for a lane closed, 1 for one the bound does
# not reach or whose close did not close it.
cloud_stall_close() { # ITEM SINCE
  local at
  at="$(jq -r --arg item "$1" '[.lanes[]? | objects | select(.item == $item) | .directive_send.at | numbers] | first // empty' <<<"$FLEET_STATE")" \
    || die state-invalid "" "item=$1" "field=directive_send"
  [[ -n "$at" ]] && (( at >= $2 && PASS_NOW - at >= CLOUD_STALL_SECS )) || return 1
  close_hosted_lane "$1" || { PASS_FAILED=1; return 1; }
  [[ "$CLOSE_RESULT" == closed ]] || return 1
  echo "EVENT cloud-stall-closed $1 directive_age=$((PASS_NOW - at))"
  PASS_EVENT=1
}

# A running or parked lane LANE_AGE_SECS past its record's launched_at, which
# --relaunch and handoffs keep and a fresh launch after lane-close renews, is
# reported lane-long once per age interval, its stage the Step line of its
# status file. Keep the launch with the interval so a fresh launch starts over.
check_lane_long() {
  local entry item launched age paused interval prior rows="${PW_SEEN[0]}" candidates="" timings=""
  local due=()
  for entry in ${LANE_AGES[@]+"${LANE_AGES[@]}"}; do
    item="${entry%%=*}"
    launched="${entry#*=}"
    # Confirmed pauses only subtract: a raw age below the bound cannot be due,
    # even when its pause timing is unavailable.
    (( PASS_NOW - launched >= LANE_AGE_SECS )) || continue
    due+=("$entry")
    candidates+="${candidates:+$'\n'}$entry"
  done
  if [[ ${#due[@]} -gt 0 ]]; then
    timings="$(jq -r --arg candidates "$candidates" --argjson to "$PASS_NOW" "$LANE_INTERVALS_JQ"'
      (reduce (.lanes[]? | objects | select(.item | type == "string")) as $lane
        ({}; .[$lane.item] += [$lane])) as $lanes
      | $candidates | split("\n")[] | split("=")
      | .[0] as $item | (.[1] | tonumber) as $from
      | (try (
          $lanes[$item]
          | if length == 1 then .[0] else error("lane-unread") end
          | lane_parked_seconds($from; $to)
        ) catch "unavailable") as $paused
      | [$item, $from, $paused] | @tsv' <<<"$FLEET_STATE")" || {
      for entry in "${due[@]}"; do ow_message lane-time-unavailable "item=${entry%%=*}" >&2; done
      timings=""
    }
  fi
  while IFS=$'\t' read -r item launched paused; do
    [[ -n "$item" ]] || continue
    [[ "$paused" != unavailable ]] || { ow_message lane-time-unavailable "item=$item" >&2; continue; }
    age=$((PASS_NOW - launched - paused))
    (( age >= LANE_AGE_SECS )) || continue
    interval=$((age / LANE_AGE_SECS))
    if ! prior="$(lane_row_get lane-long "$rows" "$item")"; then
      die state-read-failed "" "item=$item" "row=lane-long"
    fi
    # Older watch runs stored only launched_at after their first report.
    [[ "$prior" != "$launched" ]] || prior="$launched|1"
    [[ "$prior" != "$launched|$interval" ]] || continue
    lane_step "$item"
    lane_long_rounds "$item"
    echo "EVENT lane-long $item age=$age review_rounds=$LANE_REVIEW_ROUNDS fix_receipts=$LANE_FIX_RECEIPTS validation_runs=$LANE_VALIDATION_RUNS restacks=$LANE_RESTACKS repeated_class_rounds=$LANE_REPEATED_CLASS_ROUNDS stage=$LANE_STEP"
    PASS_EVENT=1
    rows="$(lane_row_set lane-long "$rows" "$item" "$launched|$interval")"
  done <<<"$timings"
  # Pruned only once no record names the item, so the gap a relaunch or a
  # handoff leaves between running records keeps the reported interval.
  rows="$(lane_row_prune lane-long "$rows" ${RECORDED_ITEMS[@]+"${RECORDED_ITEMS[@]}"})"
  lane_row_commit "$rows"
}

lane_long_rounds() { # ITEM
  local root host
  lane_state_rounds ""
  ! item_parked "$1" || return 0
  ! item_in "$1" ${FILELESS[@]+"${FILELESS[@]}"} || return 0
  hosted_root "$1"
  local_root "$1"
  root="${HOSTED_ROOT:-$LOCAL_ROOT}"
  host=""
  [[ -z "$HOSTED_ROOT" ]] || host="$HOSTED_HOST"
  if ! lane_item_state "$WORKFLOW_STATE" "$SCRIPT_DIR/lane-host" "$STATE_DIR_SETTING" "$1" "$host" "$root" "$WORK_DIR"; then
    ow_message lane-long-rounds-unread "item=$1" >&2
    cat -- "$WORK_DIR/state.err" >&2
    return 0
  fi
  [[ -n "$LANE_ITEM_STATE" ]] || return 0
  if ! lane_state_rounds "$LANE_ITEM_STATE" "$WORK_DIR/state.err" "$LANE_ITEM_VALIDATION_RUNS"; then
    ow_message lane-long-rounds-unread "item=$1" >&2
    cat -- "$WORK_DIR/state.err" >&2
    return 0
  fi
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
