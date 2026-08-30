# shellcheck shell=bash

MERGE_QUEUE_REPORT_FILTER='{issue_id,watch_id,status,action,repository,pr_number,head_sha,
  gate_mode,recovery_count,artifact_path,log_path,deadline,verdict,verdict_cause,
  lane_postmerge,cleanup,diagnostic,error:(.diagnostic.error // null),
  worker_exit_code:(.diagnostic.worker_exit_code // null),
  diagnostic_path:(.diagnostic.diagnostic_path // .log_path)}'

json_report() { jq -c "$MERGE_QUEUE_REPORT_FILTER" "$STATE_FILE"; }
consume_report() {
  jq -c "$MERGE_QUEUE_REPORT_FILTER | .claimed_action=.action |
    .action=(if .status==\"claimed\" then \"resume_\"+(.action // \"unknown\")
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
