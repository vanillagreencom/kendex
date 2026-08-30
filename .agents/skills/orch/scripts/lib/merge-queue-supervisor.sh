# shellcheck shell=bash

merge_queue_supervise() {
  local state_file="$1" watch_id="$2" waiter="$3" poll="$4" max_wait="$5"
  local repo pr head main_root artifact log runtime deadline temp output worker_pid="" worker_rc=0 event=""
  local event_fifo owner_fifo watchdog_pid="" published=false
  repo=$(jq -r .repository "$state_file"); pr=$(jq -r .pr_number "$state_file")
  head=$(jq -r .head_sha "$state_file"); artifact=$(jq -r .artifact_path "$state_file")
  main_root=$(jq -r .main_repo_root "$state_file")
  log=$(jq -r .log_path "$state_file"); runtime=$(jq -r .runtime_dir "$state_file")
  deadline=$(jq -r .deadline "$state_file"); temp="$runtime/worker.json"; output="$runtime/artifact.tmp"
  event_fifo="$runtime/events"; owner_fifo="$runtime/deadline-owner"
  [[ -d "$runtime" && ! -L "$runtime" && "$(cat < "$runtime/token")" == "$watch_id" ]] || return 1
  [[ -d "$main_root" ]] || return 1

  stop_worker() {
    local i
    [[ -n "$worker_pid" ]] || return 0
    kill -0 -- "-$worker_pid" 2>/dev/null || { wait "$worker_pid" 2>/dev/null || true; return 0; }
    kill -TERM -- "-$worker_pid" 2>/dev/null || true
    for ((i=0; i<50; i++)); do kill -0 -- "-$worker_pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 -- "-$worker_pid" 2>/dev/null && kill -KILL -- "-$worker_pid" 2>/dev/null || true
    wait "$worker_pid" 2>/dev/null || true
  }
  publish_unknown() {
    local reason="$1" rc="$2"
    [[ -e "$artifact" ]] && return 0
    jq -n --arg repo "$repo" --argjson pr "$pr" --arg head "$head" --arg watch "$watch_id" \
      --arg reason "$reason" --argjson rc "$rc" --arg log "$log" \
      '{schema_version:1,status:"error",verdict:"unknown",repository:$repo,pr_number:$pr,
        expected_head:$head,observed_head:"",watch_id:$watch,cause:$reason,
        worker_exit_code:$rc,diagnostic_path:$log}' > "$output" || return 1
    chmod 600 "$output" && ln "$output" "$artifact" && published=true
  }
  cleanup() {
    local rc=$?
    exec 6>&- 7>&- 8>&- 9>&- 2>/dev/null || true
    [[ -z "$watchdog_pid" ]] || { kill "$watchdog_pid" 2>/dev/null || true; wait "$watchdog_pid" 2>/dev/null || true; }
    stop_worker
    $published || publish_unknown supervisor_exit "$rc" || true
    printf '%s\n' "$rc" > "$runtime/terminal" 2>/dev/null || true
  }
  trap cleanup EXIT
  trap 'exit 143' TERM HUP
  trap 'exit 130' INT

  rm -f -- "$event_fifo" "$owner_fifo"; mkfifo "$event_fifo" "$owner_fifo"
  exec 6<>"$owner_fifo" 7<>"$event_fifo"
  (
    exec 6>&- 7>&-
    delay=$((deadline - $(date +%s))); ((delay > 0)) && IFS= read -r -t "$delay" _ < "$owner_fifo" || true
    [[ $(date +%s) -lt "$deadline" ]] || printf 'deadline\n' > "$event_fifo"
  ) & watchdog_pid=$!
  printf '%s\n' "$$" > "$runtime/supervisor.pid"; chmod 600 "$runtime/supervisor.pid"
  set -m
  (
    exec 7>"$event_fifo"
    set +e
    cd "$main_root" || exit 1
    env -u GH_REPO -u GITHUB_REPOSITORY GH_REPO="$repo" \
      "$waiter" "$pr" "$poll" "$max_wait" --json > "$temp" 2>> "$log"
    rc=$?; printf '%s\n' "$rc" > "$runtime/worker.status"; printf 'worker\n' >&7; exit "$rc"
  ) & worker_pid=$!
  set +m
  kill -0 "$worker_pid" 2>/dev/null || return 1
  : > "$runtime/ready"; chmod 600 "$runtime/ready"
  IFS= read -r event < "$event_fifo" || true
  exec 6>&- 7>&-
  wait "$watchdog_pid" 2>/dev/null || true; watchdog_pid=""
  if [[ "$event" == deadline && ! -f "$runtime/worker.status" ]]; then stop_worker; worker_pid=""; publish_unknown supervisor_deadline 124; trap - EXIT TERM HUP INT; return 0; fi
  wait "$worker_pid" || worker_rc=$?; worker_pid=""
  if ! jq -e 'type=="object" and (.status|IN("complete","timeout","error")) and
      (.verdict|IN("merged","conflicting","ejected","disarmed","dequeued","closed","queued","not_queued","unknown"))' "$temp" >/dev/null 2>&1; then
    publish_unknown worker_output_invalid "$worker_rc"; trap - EXIT TERM HUP INT; return 0
  fi
  jq --arg repo "$repo" --argjson pr "$pr" --arg head "$head" --arg watch "$watch_id" --arg log "$log" \
    '. + {schema_version:1,repository:$repo,pr_number:$pr,expected_head:$head,
      observed_head:"",watch_id:$watch,diagnostic_path:$log}' "$temp" > "$output"
  chmod 600 "$output" && ln "$output" "$artifact" || return 1
  published=true; printf '%s\n' "$worker_rc" > "$runtime/terminal"; chmod 600 "$runtime/terminal"
  trap - EXIT TERM HUP INT
}
