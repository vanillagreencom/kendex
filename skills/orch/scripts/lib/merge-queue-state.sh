# shellcheck shell=bash

MERGE_QUEUE_REPORT_FILTER='{issue_id,watch_id,status,action,repository,pr_number,head_sha,worktree_branch,
  gate_mode,recovery_count,launch_attempt,launch_attempt_id,runtime_dir,artifact_path,log_path,deadline,verdict,verdict_cause,
  lane_postmerge,cleanup,diagnostic,error:(.diagnostic.error // null),
  worker_exit_code:(.diagnostic.worker_exit_code // null),
  diagnostic_path:(.diagnostic.diagnostic_path // .log_path)}'

json_report() { jq -c "$MERGE_QUEUE_REPORT_FILTER" "$STATE_FILE"; }
consume_report() {
  jq -c "$MERGE_QUEUE_REPORT_FILTER | .claimed_action=.action |
    .action=(if .status==\"claimed\" then \"resume_\"+(.action // \"unknown\")
      elif .status==\"launch_failed\" then \"resume_launch\"
      elif .status==\"awaiting_lane_postmerge\" then \"lane_postmerge\"
      elif .status==\"cleanup_pending\" then \"resume_cleanup\"
      elif .status==\"cleanup_complete\" then \"acknowledge\"
      else .status end)" "$STATE_FILE"
}
merge_queue_init_workflow_state() {
  local worktree="" branch="" exists
  while [[ $# -gt 0 ]]; do case "$1" in
    --worktree) worktree="${2:-}"; shift 2 ;; --issue) ISSUE="${2:-}"; shift 2 ;;
    --branch) branch="${2:-}"; shift 2 ;; *) die "unknown init option: $1" ;; esac; done
  [[ -d "$worktree" && -n "$ISSUE" && -n "$branch" ]] || die "init context is incomplete"
  validate_issue
  exists=$(cd "$worktree" && "$WORKFLOW_STATE" exists --json "$ISSUE") || die "cannot inspect workflow state"
  if [[ $(jq -r .exists <<<"$exists") != true ]]; then
    (cd "$worktree" && "$WORKFLOW_STATE" init "$ISSUE" --worktree "$worktree" --branch "$branch" >/dev/null) || die "cannot initialize workflow state"
  fi
  (cd "$worktree" && "$WORKFLOW_STATE" exists --json "$ISSUE")
}

merge_queue_cleanup_worktree() {
  parse_root_issue "$@"; [[ "$(state_value .watch_id)" == "$WATCH_ID" ]] || die "watch id changed"
  local worktree helper required expected_branch owner output="" rc=0 diagnostic disposition current_branch
  local expected_common current_common resolved_worktree dirty
  worktree=$(state_value .worktree); helper="$ROOT/.agents/skills/worktree/scripts/worktree"
  required=$(state_value .cleanup.required); expected_branch=$(state_value .worktree_branch)
  owner="$WATCH_ID-$$-$RANDOM$RANDOM"
  exec 8>"$STATE_FILE.cleanup.lock"
  flock -n 8 || die "cleanup is already owned by another process"
  atomic_update 'if .watch_id!=$watch then error("watch id changed")
    elif .status=="awaiting_lane_postmerge" and (.cleanup.status|IN("pending","failed")) then
      .status="cleanup_pending"|.cleanup.status="running"|.cleanup.owner={token:$owner,pid:$pid,claimed_at:(now|floor)}
    elif .status=="cleanup_pending" and (.cleanup.status|IN("running","failed")) then
      .cleanup.status="running"|.cleanup.owner={token:$owner,pid:$pid,claimed_at:(now|floor)}|
      .cleanup.resume_count=((.cleanup.resume_count // 0)+1)
    else error("cleanup is not pending") end|.updated_at=(now|floor)' \
    --arg watch "$WATCH_ID" --arg owner "$owner" --argjson pid "$$"
  if [[ "$required" != true ]]; then
    output="no issue worktree requires cleanup"; disposition=skipped
  elif [[ ! -d "$worktree" ]]; then
    output="worktree already absent: $worktree"; disposition=absent
  elif [[ ! -x "$helper" ]]; then
    output="cleanup helper is missing: $helper"; rc=1
  else
    if ! expected_common=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then expected_common=""; fi
    if ! current_common=$(git -C "$worktree" rev-parse --path-format=absolute --git-common-dir 2>/dev/null); then current_common=""; fi
    if ! current_branch=$(git -C "$worktree" branch --show-current 2>/dev/null); then current_branch=""; fi
    if ! dirty=$(git -C "$worktree" status --porcelain 2>/dev/null); then dirty=unreadable; fi
    resolved_worktree=$(cd "$ROOT" && "$helper" path "$ISSUE" 2>/dev/null || true)
    if [[ -z "$current_common" || "$current_common" != "$expected_common" ]]; then
      output="kept worktree: repository identity changed: $worktree"; disposition=kept
    elif [[ -z "$current_branch" || "$current_branch" != "$expected_branch" ]]; then
      output="kept worktree: expected branch '$expected_branch', found '${current_branch:-detached HEAD}': $worktree"; disposition=kept
    elif [[ -n "$dirty" ]]; then
      output="kept worktree: uncommitted changes are present: $worktree"; disposition=kept
    elif [[ -z "$resolved_worktree" || "$(cd "$resolved_worktree" 2>/dev/null && pwd -P || true)" != "$worktree" ]]; then
      output="kept worktree: issue now resolves to '${resolved_worktree:-no worktree}': $worktree"; disposition=kept
    else
      cd "$ROOT" || die "cannot enter main repository for cleanup"
      set +e; output=$("$helper" remove "$ISSUE" 2>&1); rc=$?; set -e
      if [[ "$rc" -eq 0 && -d "$worktree" ]]; then output="$output${output:+$'\n'}cleanup helper returned success but kept $worktree"; rc=1; fi
      [[ "$rc" -ne 0 ]] || disposition=removed
    fi
  fi
  if [[ "$rc" -ne 0 ]]; then
    diagnostic="$(state_value .runtime_dir)/cleanup-diagnostic.$$"
    (umask 077; set -C; : > "$diagnostic") || die "cannot bind cleanup diagnostic"
    printf '%s\n' "$output" > "$diagnostic"
    atomic_update 'if .watch_id!=$watch or .status!="cleanup_pending" or .cleanup.owner.token!=$owner then error("cleanup claim lost") else
      .cleanup.status="failed"|.cleanup.diagnostic=$detail|.updated_at=(now|floor) end' \
      --arg watch "$WATCH_ID" --arg owner "$owner" --rawfile detail "$diagnostic"
    rm -f -- "$diagnostic"; printf '%s\n' "$output" >&2; return "$rc"
  fi
  atomic_update 'if .watch_id!=$watch or .status!="cleanup_pending" or .cleanup.owner.token!=$owner then error("cleanup claim lost") else
    .status="cleanup_complete"|.cleanup.status="complete"|.cleanup.disposition=$disposition|
    .cleanup.diagnostic=$detail|.cleanup.owner=null|.updated_at=(now|floor) end' \
    --arg watch "$WATCH_ID" --arg owner "$owner" --arg disposition "$disposition" --arg detail "$output"
  json_report
}
