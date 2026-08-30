# shellcheck shell=bash

merge_queue_supervise() {
  local state_file="$1" watch_id="$2" waiter="$3" poll="$4" max_wait="$5"
  local repo pr head artifact log runtime deadline temp output observed="" worker_pid="" worker_rc=0
  local published=false canceled=false
  repo=$(jq -r .repository "$state_file"); pr=$(jq -r .pr_number "$state_file")
  head=$(jq -r .head_sha "$state_file"); artifact=$(jq -r .artifact_path "$state_file")
  log=$(jq -r .log_path "$state_file"); runtime=$(jq -r .runtime_dir "$state_file")
  deadline=$(jq -r .deadline "$state_file"); temp="$runtime/worker.json"; output="$runtime/artifact.tmp"
  [[ -d "$runtime" && ! -L "$runtime" && "$(cat < "$runtime/token")" == "$watch_id" ]] || return 1

  stop_worker() {
    local i
    [[ -n "$worker_pid" ]] || return 0
    kill -0 -- "-$worker_pid" 2>/dev/null || { wait "$worker_pid" 2>/dev/null || true; return 0; }
    kill -TERM -- "-$worker_pid" 2>/dev/null || true
    for ((i=0; i<50; i++)); do kill -0 -- "-$worker_pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 -- "-$worker_pid" 2>/dev/null; then kill -KILL -- "-$worker_pid" 2>/dev/null || true; fi
    wait "$worker_pid" 2>/dev/null || true
  }
  observe_head() { gh pr view "$pr" --repo "$repo" --json headRefOid --jq .headRefOid 2>/dev/null || true; }
  publish_unknown() {
    local reason="$1" rc="$2"
    [[ -e "$artifact" ]] && return 0
    observed=$(observe_head)
    jq -n --arg repo "$repo" --argjson pr "$pr" --arg head "$head" --arg observed "$observed" \
      --arg watch "$watch_id" --arg reason "$reason" --argjson rc "$rc" --arg log "$log" \
      '{schema_version:1,status:"error",verdict:"unknown",repository:$repo,pr_number:$pr,
        expected_head:$head,observed_head:$observed,watch_id:$watch,cause:$reason,
        worker_exit_code:$rc,diagnostic_path:$log}' > "$output" || return 1
    chmod 600 "$output" && ln "$output" "$artifact" && published=true
  }
  cleanup() {
    local rc=$?
    stop_worker
    $published || publish_unknown "supervisor_exit" "$rc" || true
    printf '%s\n' "$rc" > "$runtime/terminal" 2>/dev/null || true
  }
  trap cleanup EXIT
  trap 'canceled=true; exit 143' TERM HUP
  trap 'canceled=true; exit 130' INT

  printf '%s\n' "$$" > "$runtime/supervisor.pid"; chmod 600 "$runtime/supervisor.pid"
  set -m
  GH_REPO="$repo" "$waiter" "$pr" "$poll" "$max_wait" --json > "$temp" 2>> "$log" &
  worker_pid=$!
  set +m
  kill -0 "$worker_pid" 2>/dev/null || return 1
  : > "$runtime/ready"; chmod 600 "$runtime/ready"
  while kill -0 "$worker_pid" 2>/dev/null; do
    if [[ $(date +%s) -ge "$deadline" ]]; then stop_worker; worker_rc=124; break; fi
    sleep 0.1
  done
  if [[ "$worker_rc" -eq 0 ]]; then wait "$worker_pid" || worker_rc=$?; fi
  worker_pid=""
  $canceled && return 143
  observed=$(observe_head)
  if [[ -z "$observed" ]] || ! jq -e 'type=="object" and (.status|IN("complete","timeout","error")) and
      (.verdict|IN("merged","ejected","disarmed","dequeued","closed","queued","not_queued","unknown"))' "$temp" >/dev/null 2>&1; then
    publish_unknown "worker_output_invalid" "$worker_rc"; trap - EXIT TERM HUP INT; return 0
  fi
  jq --arg repo "$repo" --argjson pr "$pr" --arg head "$head" --arg observed "$observed" \
    --arg watch "$watch_id" --arg log "$log" '. + {schema_version:1,repository:$repo,pr_number:$pr,
      expected_head:$head,observed_head:$observed,watch_id:$watch,diagnostic_path:$log}' "$temp" > "$output"
  chmod 600 "$output" && ln "$output" "$artifact" || return 1
  published=true
  printf '%s\n' "$worker_rc" > "$runtime/terminal"; chmod 600 "$runtime/terminal"
  trap - EXIT TERM HUP INT
}
