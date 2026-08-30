# shellcheck shell=bash
MERGE_QUEUE_WATCH="${OVERSEE_WATCH_MERGE_QUEUE_WATCH:-$SCRIPT_DIR/merge-queue-watch}"

check_merge_lifecycle() {
  local item out errf="$WORK_DIR/merge-lifecycle.err" rc
  for item in ${ITEMS[@]+"${ITEMS[@]}"}; do
    : > "$errf"; rc=0
    out=$("$MERGE_QUEUE_WATCH" event --root "$PROJECT_ROOT" --issue "$item" 2>"$errf") || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "EVENT merge-verdict $item ${out##* }"
      pr_watch_context
      exit 0
    fi
    [[ ! -s "$errf" ]] || die "merge lifecycle read failed for $item: $(cat "$errf")"
  done
}
