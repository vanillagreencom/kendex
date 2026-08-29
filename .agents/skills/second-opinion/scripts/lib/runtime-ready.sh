#!/usr/bin/env bash

second_opinion_wait_for_setup() {
  local supervisor_pid="$1" runtime_dir="$2" log="$3" prefix="$4"
  local setup_deadline line job_pid running supervisor_rc=0 jobs_file="$runtime_dir/setup.jobs"
  SECOND_OPINION_SETUP_REAPED=false
  setup_deadline=$(($(date +%s) + 5))
  while [[ ! -f "$runtime_dir/ready" ]]; do
    line=$(completion_line "$log" "$prefix") || {
      echo "Error: cannot read supervisor setup log" >&2
      return 1
    }
    [[ -z "$line" ]] || return 0
    running=false
    jobs -r -p > "$jobs_file" || true
    while IFS= read -r job_pid; do
      [[ "$job_pid" == "$supervisor_pid" ]] && running=true
    done < "$jobs_file"
    rm -f -- "$jobs_file" || true
    if ! $running; then
      wait "$supervisor_pid" 2>/dev/null || supervisor_rc=$?
      SECOND_OPINION_SETUP_REAPED=true
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

second_opinion_cleanup_failed_launch() {
  local supervisor_pid="$1" runtime_dir="$2" token="$3" end job_pid running
  exec 8<&- 9>&-
  if ! ${SECOND_OPINION_SETUP_REAPED:-false}; then
    kill -TERM "$supervisor_pid" 2>/dev/null || true
    end=$(($(date +%s) + 2))
    while :; do
      running=false
      if ! jobs -r -p > "$runtime_dir/cleanup.jobs"; then running=true; break; fi
      while IFS= read -r job_pid; do
        [[ "$job_pid" == "$supervisor_pid" ]] && running=true
      done < "$runtime_dir/cleanup.jobs"
      rm -f -- "$runtime_dir/cleanup.jobs" || true
      $running && [[ $(date +%s) -lt $end ]] || break
      sleep 0.1
    done
    $running && kill -KILL "$supervisor_pid" 2>/dev/null || true
    wait "$supervisor_pid" 2>/dev/null || true
  fi
  runtime_dir_valid "$runtime_dir" "$token" && rm -rf -- "$runtime_dir" || true
}
