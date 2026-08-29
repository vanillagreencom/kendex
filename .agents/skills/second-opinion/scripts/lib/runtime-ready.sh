#!/usr/bin/env bash

second_opinion_wait_for_setup() {
  local supervisor_pid="$1" runtime_dir="$2" log="$3" prefix="$4"
  local setup_deadline line job_pid running supervisor_rc=0
  setup_deadline=$(($(date +%s) + 5))
  while [[ ! -f "$runtime_dir/ready" ]]; do
    line=$(completion_line "$log" "$prefix") || {
      echo "Error: cannot read supervisor setup log" >&2
      return 1
    }
    [[ -z "$line" ]] || return 0
    running=false
    for job_pid in $(jobs -r -p); do
      [[ "$job_pid" == "$supervisor_pid" ]] && running=true
    done
    if ! $running; then
      wait "$supervisor_pid" 2>/dev/null || supervisor_rc=$?
      line=$(completion_line "$log" "$prefix") || true
      [[ -z "$line" ]] || return 0
      echo "Error: detached supervisor exited during setup without completion (status $supervisor_rc)" >&2
      return 1
    fi
    if [[ $(date +%s) -ge $setup_deadline ]]; then
      echo "Error: detached supervisor did not finish setup within 5 seconds" >&2
      return 1
    fi
    sleep 0.01
  done
}
