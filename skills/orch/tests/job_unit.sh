#!/usr/bin/env bash
# Tests for lib/job-unit.sh through its executable interface, the contract a
# markdown recipe calls: --help, name, launch, attach, end, stop, kill-group
# and stop-job, with the fallbacks behind a failing systemd-run and each rule
# under which a stop leaves a group alone. The unit rows run only where a user
# manager answers.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB_UNIT="$TEST_DIR/../scripts/lib/job-unit.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
# A user manager is used only where it lingers, which this host's may not:
# every row reaches it through a loginctl that says it does, except the rows
# that plant their own answer.
mkdir -p "$TMP_ROOT/linger"
printf '#!/bin/sh\necho yes\n' > "$TMP_ROOT/linger/loginctl"
chmod +x "$TMP_ROOT/linger/loginctl"
export PATH="$TMP_ROOT/linger:$PATH"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
# orch_fixture_shared_libs: attach forks through the github skill's
# group-leader prefix, which a copy of the executable reaches beside it.
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"

OUT=""
ERR=""
RC=0
run() { # SCRIPT ARG...
  set +e
  OUT="$("$@" 2>"$TMP_ROOT/err")"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/err")"
}

# A copy of the executable with one literal substitution applied, for the
# controls: one per rule a row below pins, the kill_sites reading among them.
# The copy sits in an installed layout, the github skill's libs beside it. The
# counts are the edit's proof.
MUTANT=""
mutant() { # NAME OLD NEW
  mkdir -p "$TMP_ROOT/mutants/$1/orch/scripts/lib"
  orch_fixture_shared_libs "$TMP_ROOT/mutants/$1/orch"
  MUTANT="$TMP_ROOT/mutants/$1/orch/scripts/lib/job-unit.sh"
  assert_eq "$(grep -c -F -- "$2" "$JOB_UNIT")" "1" "control $1 finds one line to mutate"
  awk -v old="$2" -v new="$3" '{
    i = index($0, old)
    if (i > 0) { $0 = substr($0, 1, i - 1) new substr($0, i + length(old)) }
    print
  }' "$JOB_UNIT" > "$MUTANT"
  chmod +x "$MUTANT"
  assert_eq "$(grep -c -F -- "$2" "$MUTANT")" "0" "control $1 applied its mutation"
}

echo "=== job-unit executable ==="

run "$JOB_UNIT" --help
assert_eq "$RC $(sed -n '1s/ — .*$//p' <<<"$OUT")" "0 job-unit.sh" \
  "--help prints the header, which opens on the script's name, and exits 0"
assert_eq "$(grep -c -E '^  job-unit\.sh (name|launch|attach|end|stop|kill-group|stop-job) ' <<<"$OUT")" "7" \
  "and names every subcommand"
run "$JOB_UNIT" launch validate-x
assert_eq "$RC $ERR" "3 job-unit: usage subcommand=launch" "a launch missing its arguments is refused as usage"
# A cap is optional and, given, a positive whole number; a launch names a job.
# launch arguments|label
while IFS='|' read -r args label; do
  # shellcheck disable=SC2086 # the arguments column is words
  run "$JOB_UNIT" launch $args
  assert_eq "$RC $ERR" "3 job-unit: usage subcommand=launch" "$label"
done <<ROWS
validate-x $TMP_ROOT/usage.record --cap 0 -- true|a zero cap is refused as usage
validate-x $TMP_ROOT/usage.record --cap -- true|a cap with no number is refused as usage
validate-x $TMP_ROOT/usage.record --|a launch with no command is refused as usage
validate-x $TMP_ROOT/usage.record --memory-max 0 -- true|a zero memory bound is refused as usage
ROWS

# --- An attached start -------------------------------------------------------
# attach arguments|label
while IFS='|' read -r args label; do
  # shellcheck disable=SC2086 # the arguments column is words
  run "$JOB_UNIT" attach $args
  assert_eq "$RC $ERR" "3 job-unit: usage subcommand=attach" "$label"
done <<ROWS
$TMP_ROOT/usage.record|an attach missing its command is refused as usage
$TMP_ROOT/usage.record true|an attach with no -- before its command is refused as usage
ROWS

# The job writes its pid and its process group; a leader's are one number.
ATTACH_JOB='echo "$$ $(ps -o pgid= -p $$)" > "$0"'
# What an attach answers: exit and stderr, the record, and whether the job
# ran as the leader of its own group.
attach_state() { # SCRIPT NAME
  local record="$TMP_ROOT/$2.record" ran="$TMP_ROOT/$2.ran" pid pgid
  run "$1" attach "$record" -- bash -c "$ATTACH_JOB" "$ran"
  if [[ ! -s "$ran" ]]; then
    ran=not-run
  else
    read -r pid pgid < "$ran"
    if [[ "$pid" == "$pgid" ]]; then ran=leader; else ran=not-leader; fi
  fi
  if [[ -f "$record" ]]; then record="$(tr '\n' ';' < "$record")"; else record=unrecorded; fi
  printf '%s|%s|%s|%s' "$RC" "$ERR" "$record" "$ran"
}
assert_eq "$(attach_state "$JOB_UNIT" attached)" "0||runner=attached;line=runner=attached;|leader" \
  "attach records the attached runner, runs the job as the leader of its own group, and says nothing on stderr"
mutant no-attach-dispatch '    attach) [[ $# -ge 3 ]] || rc=3 ;;' ''
assert_eq "$(attach_state "$MUTANT" attached-undispatched)" "3|job-unit: usage subcommand=attach|unrecorded|not-run" \
  "control: with no attach in the dispatch the start is refused as usage and nothing runs"
mutant no-group-leader '"${KENDEX_GROUP_LEADER[@]}" "$@"' '"$@"'
assert_eq "$(attach_state "$MUTANT" attached-unled)" "0||runner=attached;line=runner=attached;|not-leader" \
  "control: without the group-leader prefix the job runs in the caller's group"

# A copy with no github skill beside it has no group-leader prefix to fork
# through: attach refuses, and neither records nor runs anything.
LONE="$TMP_ROOT/lone/orch/scripts/lib"
mkdir -p "$LONE"
cp -- "$JOB_UNIT" "$LONE/job-unit.sh"
assert_eq "$(attach_state "$LONE/job-unit.sh" attached-lone)" \
  "2|job-unit: group-leader-missing path=$LONE/../../../github/scripts/lib/group-leader.sh|unrecorded|not-run" \
  "attach with no github skill beside it exits 2 as group-leader-missing and starts nothing"
mutant no-leader-refusal ' || { job_unit_fail group-leader-missing "path=$lib" 2; return; }' ''
rm -rf -- "${TMP_ROOT:?}/mutants/no-leader-refusal/github"
assert_eq "$(attach_state "$MUTANT" attached-lone-unrefused | cut -d'|' -f3)" "runner=attached;line=runner=attached;" \
  "control: without that refusal the start goes ahead with no prefix and writes its record"

# A host with no perl cannot run the prefix: attach refuses by name, and
# neither records nor runs anything.
NO_PERL="$TMP_ROOT/no-perl"
mkdir -p "$NO_PERL"
for name in bash mv; do
  ln -sf "$(command -v "$name")" "$NO_PERL/$name"
done
no_perl_attach() { # SCRIPT NAME — exit, stderr and whether a record was written
  local record="$TMP_ROOT/$2.record"
  run env PATH="$NO_PERL" "$1" attach "$record" -- /bin/true
  printf '%s|%s|%s' "$RC" "$ERR" "$([[ -f "$record" ]] && echo recorded || echo unrecorded)"
}
assert_eq "$(no_perl_attach "$JOB_UNIT" attached-no-perl)" "2|job-unit: missing-command commands=perl|unrecorded" \
  "attach on a host with no perl exits 2 as missing-command naming perl and starts nothing"
mutant no-perl-refusal 'command -v perl >/dev/null 2>&1 || { job_unit_fail missing-command commands=perl 2; return; }' ':'
assert_eq "$(no_perl_attach "$MUTANT" attached-no-perl-unrefused | cut -d'|' -f1,3)" "0|recorded" \
  "control: without that refusal the start exits 0 and records a job that never ran"

# --- The unit name shape ---------------------------------------------------------
# name|pid|unit name
NAME_ROWS=(
  'validate-ken-1784|180993|orch-validate-ken-1784-180993'
  'validate-proj-${HOME}|1|orch-validate-proj-__HOME_-1'
  'watch a b/c|7|orch-watch_a_b_c-7'
)
for row in "${NAME_ROWS[@]}"; do
  IFS='|' read -r name pid want <<<"$row"
  run "$JOB_UNIT" name "$name" "$pid"
  assert_eq "$OUT" "$want" "name '$name' and pid $pid name the unit $want"
done
mutant no-sanitize "| LC_ALL=C tr -c 'A-Za-z0-9_.-' '_'" ''
run "$MUTANT" name 'watch a b/c' 7
assert_eq "$OUT" "orch-watch a b/c-7" "control: unsanitized, the name's spaces and slash reach the unit name"

# --- The slice a launch names for its unit ----------------------------------------
# The cgroup file each row plants is one the kernel writes: a pane under the
# agent warden's placement, a lane in a nested slice, a tmux service, a login
# session outside the user manager, a process under another user's manager, a
# cgroup v1 host, a hybrid v1 and v2 host, and macOS, which has no /proc.
# cgroup file lines (\n between them), or `none` for no file|slice|label
while IFS='|' read -r lines want label; do
  file="$TMP_ROOT/cgroup.$RANDOM"
  [[ "$lines" == none ]] || printf '%b\n' "${lines//UID/$UID}" > "$file"
  # shellcheck source=/dev/null # the library under test, sourced for one function
  assert_eq "$(source "$JOB_UNIT"; job_unit_slice "$file")" "$want" "$label"
done <<ROWS
0::/user.slice/user-UID.slice/user@UID.service/agents.slice/agent-confine-1-a.scope|agents.slice|a process in an agents.slice scope names agents.slice
0::/user.slice/user-UID.slice/user@UID.service/agents.slice/agents-lane.slice/x.scope|agents-lane.slice|a process in a nested slice names the innermost one
0::/user.slice/user-UID.slice/user@UID.service/app.slice/tmux.service|app.slice|a process in a service names that service's slice
0::/user.slice/user-UID.slice/session-4.scope||a login session scope, outside the user manager, names no slice
0::/user.slice/user-UID.slice/user@9UID.service/agents.slice/x.scope||a process under another user's manager names no slice
1:name=systemd:/user.slice/user-UID.slice/user@UID.service/agents.slice/x.scope||a cgroup v1 line names no slice
12:pids:/user.slice\n0::/user.slice/user-UID.slice/user@UID.service/agents.slice/x.scope|agents.slice|a hybrid file names the slice on its cgroup v2 line
none||no cgroup file names no slice
ROWS
printf '0::/user.slice/user-%s.slice/session-4.scope\n' "$UID" > "$TMP_ROOT/session.cgroup"
mutant no-manager-check '[[ "$path" == */user@"$UID".service/* ]] || return 0' ':'
# shellcheck source=/dev/null # the control's copy of that library
assert_eq "$(source "$MUTANT"; job_unit_slice "$TMP_ROOT/session.cgroup")" "user-$UID.slice" \
  "control: without the manager check a login session names the system's user slice"

# --- The task and memory caps a launch copies from its own cgroup -------------------
# Each row plants one cgroup v2 limit file as the kernel writes it: a number, or
# `max` for no limit, or no file where the cgroup lacks that controller.
# file|content, or `none` for no file|printed cap|label
while IFS='|' read -r limit content want label; do
  dir="$TMP_ROOT/cgroup-dir.$RANDOM"
  mkdir -p -- "$dir"
  [[ "$content" == none ]] || printf '%s\n' "$content" > "$dir/$limit"
  # shellcheck source=/dev/null # the library under test, sourced for one function
  assert_eq "$(source "$JOB_UNIT"; job_unit_cgroup_cap "$dir" "$limit")" "$want" "$label"
done <<ROWS
pids.max|8192|8192|a task cap the cgroup holds is copied
memory.high|68719476736|68719476736|a memory soft cap the cgroup holds is copied
pids.max|max||a cgroup with no task cap gives none
memory.high|none||a cgroup with no memory controller gives no memory soft cap
ROWS
mkdir -p -- "$TMP_ROOT/uncapped"
printf 'max\n' > "$TMP_ROOT/uncapped/pids.max"
mutant no-number-check '[[ "$value" =~ ^[0-9]+$ ]] || return 0' ':'
# shellcheck source=/dev/null # the control's copy of that library
assert_eq "$(source "$MUTANT"; job_unit_cgroup_cap "$TMP_ROOT/uncapped" pids.max)" "max" \
  "control: without the number check an uncapped cgroup's max reaches the unit, which systemd refuses"

# --- A launch where no systemd-run is installed ------------------------------------
# A PATH holding what the setsid launch and its job call, and no systemd-run.
FARM="$TMP_ROOT/farm"
mkdir -p "$FARM"
for name in bash setsid sleep mv tr cat ps awk; do
  ln -sf "$(command -v "$name")" "$FARM/$name"
done
# The pid the job wrote, once that process has exec'd `sleep 30`: the job
# writes its pid before its exec, and the rows match its argv against
# `*sleep 30`. Exit 1 when the bound passes first.
wait_job() { # FILE
  local n=0 pid=""
  while (( n < 50 )); do
    pid="$(cat "$1" 2>/dev/null || true)"
    if [[ -n "$pid" && "$(ps -ww -o args= -p "$pid" 2>/dev/null || true)" == *"sleep 30" ]]; then
      echo "$pid"
      return 0
    fi
    sleep 0.1
    n=$((n + 1))
  done
  echo "$pid"
  return 1
}

# One job launched under setsid, writing its pid where the row can read it.
JOB_PID=""
launch_setsid_job() { # RECORD PIDFILE
  run env PATH="$FARM" "$JOB_UNIT" launch validate-id-1 "$1" --cap 60 \
    -- bash -c 'echo $$ > "$0"; exec sleep 30' "$2"
  JOB_PID="$(wait_job "$2")" ||
    fail "the setsid job runs sleep 30 within 5 s" "pid file: $2, pid: [${JOB_PID}]"
}

if command -v setsid >/dev/null 2>&1; then
  record="$TMP_ROOT/setsid.record"
  launch_setsid_job "$record" "$TMP_ROOT/setsid-1.pid"
  # The launcher read the child's identity from the kernel table before it
  # returned: the pid the job wrote for itself and the start /proc holds for
  # it, on the runner line and in the record, no `ticks:0`.
  JOB_START="$(set -- $(sed 's/.*) //' "/proc/$JOB_PID/stat"); printf 'ticks:%s' "${20}")"
  assert_eq "$RC $OUT" "0 runner=setsid reason=no-systemd-run pid=$JOB_PID start=$JOB_START" \
    "a launch with no systemd-run prints the setsid runner line with the job's identity"
  assert_eq "$(cat "$record")" "$(printf 'runner=setsid\npid=%s\nstart=%s\nline=runner=setsid reason=no-systemd-run pid=%s start=%s' "$JOB_PID" "$JOB_START" "$JOB_PID" "$JOB_START")" \
    "and records that runner, the identity the launcher read and the line, with no unit"
  assert_eq "$([[ "$JOB_PID" =~ ^[0-9]+$ ]] && kill -0 "$JOB_PID" 2>/dev/null && echo running || echo absent)" "running" \
    "and the job runs"
  # The one stat reader refused: a `cat` that cannot read /proc stands in for
  # a host without it. The launcher ends the child it started and refuses
  # `identity-unread`; nothing runs unrecorded and nothing is manufactured.
  mkdir -p "$TMP_ROOT/no-proc"
  printf '#!/usr/bin/env bash\ncase "$1" in /proc/*) exit 1 ;; esac\nexec /bin/cat "$@"\n' > "$TMP_ROOT/no-proc/cat"
  chmod +x "$TMP_ROOT/no-proc/cat"
  run env PATH="$TMP_ROOT/no-proc:$FARM" "$JOB_UNIT" launch validate-id-1 "$TMP_ROOT/unread.record" --cap 60 \
    -- bash -c 'echo $$ > "$0"; exec sleep 30' "$TMP_ROOT/unread.pid"
  assert_eq "$RC|$ERR|$(grep -c '^pid=' "$TMP_ROOT/unread.record")" "4|job-unit: launch-failed status=identity-unread|0" \
    "a start the launcher cannot read refuses status=identity-unread and records no identity"
  unread_pid="$(cat "$TMP_ROOT/unread.pid" 2>/dev/null || true)"
  assert_eq "$([[ -z "$unread_pid" ]] || ! kill -0 "$unread_pid" 2>/dev/null && echo gone || echo alive)" gone \
    "and the child it started is ended"

  # The child caught before it ran its own `setsid`: a farm `setsid` that
  # blocks without exec'ing the real one leads no process group, so a group
  # teardown alone would miss it. The farm `cat` refuses /proc, so the
  # identity read fails and the unread-start path runs; the child is ended by
  # its own pid, never running to write its survival marker.
  mkdir -p "$TMP_ROOT/barrier"
  printf '#!/usr/bin/env bash\nsleep 2 && echo survived > "$BARRIER_MARKER"\n' > "$TMP_ROOT/barrier/setsid"
  printf '#!/usr/bin/env bash\ncase "$1" in /proc/*) exit 1 ;; esac\nexec /bin/cat "$@"\n' > "$TMP_ROOT/barrier/cat"
  chmod +x "$TMP_ROOT/barrier/setsid" "$TMP_ROOT/barrier/cat"
  rm -f "$TMP_ROOT/barrier.marker"
  run env PATH="$TMP_ROOT/barrier:$FARM" BARRIER_MARKER="$TMP_ROOT/barrier.marker" \
    "$JOB_UNIT" launch validate-id-1 "$TMP_ROOT/barrier.record" --cap 60 -- sleep 30
  assert_eq "$RC|$ERR|$([[ -f "$TMP_ROOT/barrier.marker" ]] && echo survived || echo gone)" \
    "4|job-unit: launch-failed status=identity-unread|gone" \
    "a child caught before its setsid is ended by its own pid, not by a group that does not exist yet"
  # The durable record names the ended launch: a reader that finds no identity
  # settles the job by this word rather than holding it.
  assert_eq "$(grep -o '^status=.*' "$TMP_ROOT/barrier.record")|$(grep -c '^pid=' "$TMP_ROOT/barrier.record")" \
    "status=identity-unread|0" \
    "and the record is rewritten with the status word the runtime reads as nothing started"
  # control: with the pid-kill removed, the group teardown misses the
  # pre-setsid child and it runs to write its marker.
  mutant no-end-child '  job_unit_end_child "$1"' '  :'
  rm -f "$TMP_ROOT/barrier.marker"
  run env PATH="$TMP_ROOT/barrier:$FARM" BARRIER_MARKER="$TMP_ROOT/barrier.marker" \
    "$MUTANT" launch validate-id-1 "$TMP_ROOT/barrier.record" --cap 60 -- sleep 30
  assert_eq "$([[ -f "$TMP_ROOT/barrier.marker" ]] && echo survived || echo gone)" "survived" \
    "control: without the pid-kill the pre-setsid child survives the group-only teardown"

  # The sibling path: the identity reads, but the final record write fails. A
  # farm `mv` that refuses once its destination exists lets the pre-write
  # through and fails the identity write; the child, caught before its setsid
  # as above, is ended by its own pid and never writes its marker. The ended
  # record cannot be written either, so the reply alone carries the status the
  # runtime reads as nothing started, with `record=unwritable`; the record
  # keeps the pre-write it could not replace.
  mkdir -p "$TMP_ROOT/record-fail"
  printf '#!/usr/bin/env bash\nsleep 2 && echo survived > "$BARRIER_MARKER"\n' > "$TMP_ROOT/record-fail/setsid"
  printf '#!/usr/bin/env bash\nfor a; do last=$a; done\n[[ ! -e "$last" ]] || exit 1\nexec /bin/mv "$@"\n' > "$TMP_ROOT/record-fail/mv"
  chmod +x "$TMP_ROOT/record-fail/setsid" "$TMP_ROOT/record-fail/mv"
  rm -f "$TMP_ROOT/barrier.marker" "$TMP_ROOT/record-fail.record"
  run env PATH="$TMP_ROOT/record-fail:$FARM" BARRIER_MARKER="$TMP_ROOT/barrier.marker" \
    "$JOB_UNIT" launch validate-id-1 "$TMP_ROOT/record-fail.record" --cap 60 -- sleep 30
  assert_eq "$RC|$ERR|$([[ -f "$TMP_ROOT/barrier.marker" ]] && echo survived || echo gone)|$(grep -c '^pid=\|^status=' "$TMP_ROOT/record-fail.record")" \
    "1|job-unit: record-unwritable path=$TMP_ROOT/record-fail.record status=record-unwritable record=unwritable|gone|0" \
    "a child whose identity record cannot be written is ended by its own pid before the launch is refused, and the reply carries the status the record cannot"
  rm -f "$TMP_ROOT/barrier.marker" "$TMP_ROOT/record-fail.record"
  run env PATH="$TMP_ROOT/record-fail:$FARM" BARRIER_MARKER="$TMP_ROOT/barrier.marker" \
    "$MUTANT" launch validate-id-1 "$TMP_ROOT/record-fail.record" --cap 60 -- sleep 30
  assert_eq "$RC|$([[ -f "$TMP_ROOT/barrier.marker" ]] && echo survived || echo gone)" "1|survived" \
    "control: without the pid-kill the child of a failed record write survives the group-only teardown"

  # kill-group: the job leads its group, and its argv decides whether it is
  # the one meant.
  # argv glob|exit|the job after
  KILL_ROWS=(
    "*sleep 29|1|alive"
    "*sleep 30|0|gone"
  )
  for row in "${KILL_ROWS[@]}"; do
    IFS='|' read -r glob want_rc want_state <<<"$row"
    run "$JOB_UNIT" kill-group "$JOB_PID" "$glob"
    assert_eq "$RC $(proc_state_after "$JOB_PID")" "$want_rc $want_state" \
      "kill-group with argv glob '$glob' exits $want_rc and leaves the job $want_state"
  done

  # stop-job on the record a setsid launch wrote stops that job's group.
  launch_setsid_job "$record" "$TMP_ROOT/setsid-2.pid"
  run "$JOB_UNIT" stop-job "$record" "$JOB_PID" "*sleep 30"
  assert_eq "$RC $(proc_state_after "$JOB_PID")" "0 gone" \
    "stop-job on a setsid record kills the job's group"
  launch_setsid_job "$record" "$TMP_ROOT/setsid-4.pid"
  mutant no-teardown '  job_unit_teardown "$pid"' '  return 0'
  run "$MUTANT" stop-job "$record" "$JOB_PID" "*sleep 30"
  assert_eq "$RC $(proc_state_after "$JOB_PID")" "0 alive" \
    "control: a stop-job that signals nothing leaves the job's group alive"
  run "$JOB_UNIT" kill-group "$JOB_PID" "*sleep 30"

  # end is the job's own last call, here made for it: its group ends.
  launch_setsid_job "$record" "$TMP_ROOT/setsid-3.pid"
  run "$JOB_UNIT" end "$record" "$JOB_PID"
  assert_eq "$RC $(proc_state_after "$JOB_PID")" "0 gone" \
    "end on a setsid record kills the group its leader names"

  # The kill-group rules under which the group is left alone. A process with
  # the job's argv that leads no group of its own is not the job's group.
  sleep 30 &
  member=$!
  run "$JOB_UNIT" kill-group "$member" "*sleep 30"
  assert_eq "$RC $(proc_state_after "$member")" "1 alive" \
    "kill-group on a matching process that leads no group exits 1 and leaves it running"
  mutant no-leader-check '  [[ "${pgid// /}" == "$pid" ]] || return 1' '  :'
  run "$MUTANT" kill-group "$member" "*sleep 30"
  assert_eq "$RC" "0" "control: without the leader check a process outside its own group passes as the job"
  kill -KILL "$member" 2>/dev/null || :
  wait "$member" 2>/dev/null || :
  # A job whose group cannot be read while it runs is a failure named by its
  # step, never a group found gone; one that ends before its group is read
  # leaves nothing to end. The farm `ps` answers the argv and refuses the
  # group read, ending the job first where the row asks it to.
  mkdir -p "$TMP_ROOT/pgid-unread"
  printf '#!/usr/bin/env bash\ncase "$*" in *pgid=*) [[ -z "${END_FIRST:-}" ]] || { kill -KILL "${@: -1}"; n=0; while kill -0 "${@: -1}" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done; }; exit 1 ;; esac\nexec /bin/ps "$@"\n' \
    > "$TMP_ROOT/pgid-unread/ps"
  chmod +x "$TMP_ROOT/pgid-unread/ps"
  launch_setsid_job "$record" "$TMP_ROOT/setsid-5.pid"
  run env PATH="$TMP_ROOT/pgid-unread:$PATH" "$JOB_UNIT" kill-group "$JOB_PID" "*sleep 30"
  assert_eq "$RC $ERR $(proc_state_after "$JOB_PID")" "2 job-unit: kill-group-failed pid=$JOB_PID step=read alive" \
    "kill-group on a running job whose group cannot be read refuses kill-group-failed step=read and leaves it running"
  run env PATH="$TMP_ROOT/pgid-unread:$PATH" END_FIRST=1 "$JOB_UNIT" kill-group "$JOB_PID" "*sleep 30"
  assert_eq "$RC $ERR" "1 " "kill-group on a job that ends before its group is read exits 1 with nothing to end"
  mutant no-gone-check '    kill -0 "$pid" 2>/dev/null || return 1' '    :'
  launch_setsid_job "$record" "$TMP_ROOT/setsid-6.pid"
  run env PATH="$TMP_ROOT/pgid-unread:$PATH" END_FIRST=1 "$MUTANT" kill-group "$JOB_PID" "*sleep 30"
  assert_eq "$RC" "2" "control: without the gone check a job that ended reads as a group that could not be read"

  # The teardown sends SIGTERM first, so the job's own trap runs before the
  # grace's SIGKILL, as a unit's stop sends it.
  term_job() { # SCRIPT RECORD MARKER
    local pidfile="$TMP_ROOT/term.pid"
    rm -f -- "$pidfile" "$3"
    run env PATH="$FARM" "$1" launch validate-term "$2" --cap 60 -- bash -c \
      'trap "echo term > \"$1\"; exit 0" TERM; echo $$ > "$0"; n=0; while [ "$n" -lt 300 ]; do sleep 0.1; n=$((n + 1)); done' \
      "$pidfile" "$3"
    JOB_PID=""
    n=0
    while [[ -z "$JOB_PID" ]] && (( n < 50 )); do JOB_PID="$(cat "$pidfile" 2>/dev/null || true)"; sleep 0.1; n=$((n + 1)); done
    run "$1" stop-job "$2" "$JOB_PID" "*echo term*"
    proc_state_after "$JOB_PID" >/dev/null
    cat "$3" 2>/dev/null || echo none
  }
  assert_eq "$(term_job "$JOB_UNIT" "$TMP_ROOT/term.record" "$TMP_ROOT/term.marker")" "term" \
    "stop-job sends a setsid job's group SIGTERM first, and its trap runs"
  mutant kill-first '  kill -TERM -- "-$1" 2>/dev/null || return 0' '  kill -KILL -- "-$1" 2>/dev/null || return 0'
  assert_eq "$(term_job "$MUTANT" "$TMP_ROOT/term.record" "$TMP_ROOT/term.marker")" "none" \
    "control: a teardown that opens with SIGKILL runs no trap"

  # A child that exited before its row was read is a launch failure by its
  # status: a setsid that cannot start the job, read through a `cat` that
  # answers after the child is gone, so the row is not raced by the exit.
  mkdir -p "$TMP_ROOT/failing-setsid"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP_ROOT/failing-setsid/setsid"
  printf '#!/usr/bin/env bash\ncase "$1" in /proc/*) sleep 0.3 ;; esac\nexec /bin/cat "$@"\n' > "$TMP_ROOT/failing-setsid/cat"
  chmod +x "$TMP_ROOT/failing-setsid/setsid" "$TMP_ROOT/failing-setsid/cat"
  run env PATH="$TMP_ROOT/failing-setsid:$FARM" "$JOB_UNIT" launch validate-id-1 "$record" --cap 60 -- sleep 30
  assert_eq "$RC $ERR|$(grep -o '^status=.*' "$record")" "4 job-unit: launch-failed status=1|status=exited-1" \
    "a setsid that cannot start the job exits 4 as launch-failed with the child's status, the durable record naming the exit"
  mutant no-launch-failed '    job_unit_launch_ended "$record" "$word" "$status" launch-failed 4' '    :'
  run env PATH="$TMP_ROOT/failing-setsid:$FARM" "$MUTANT" launch validate-id-1 "$record" --cap 60 -- sleep 30
  assert_eq "$RC $ERR" "0 " \
    "control: without the status read a child that exited before its row was read passes as launched"

  # An exited leader proves nothing about what it started. The job forks a
  # descendant into its group, records that pid, and exits 7 before the
  # launcher's identity read (the farm `cat` answers for /proc only once the
  # descendant is recorded). The launcher tears the group down and reads it
  # empty before it reports `exited-7`: the descendant is ended, and the
  # durable record says so.
  mkdir -p "$TMP_ROOT/exit-with-child"
  printf '#!/usr/bin/env bash\ncase "$1" in /proc/*)\n  while [[ ! -f "$PROBE_ROOT/descendant" ]]; do /bin/sleep .01; done\n  /bin/sleep .2\n;; esac\nexec /bin/cat "$@"\n' > "$TMP_ROOT/exit-with-child/cat"
  chmod +x "$TMP_ROOT/exit-with-child/cat"
  rm -f "$TMP_ROOT/exit-with-child/descendant" "$TMP_ROOT/exit-with-child.record"
  run env PATH="$TMP_ROOT/exit-with-child:$FARM" PROBE_ROOT="$TMP_ROOT/exit-with-child" \
    "$JOB_UNIT" launch validate-id-1 "$TMP_ROOT/exit-with-child.record" --cap 60 \
    -- bash -c 'sleep 60 & echo $! > "$PROBE_ROOT/descendant"; exit 7'
  descendant="$(cat "$TMP_ROOT/exit-with-child/descendant" 2>/dev/null || true)"
  assert_eq "$RC|$ERR|$(grep -o '^status=.*' "$TMP_ROOT/exit-with-child.record")|$(proc_state_after "$descendant")" \
    "4|job-unit: launch-failed status=7|status=exited-7|gone" \
    "an exited leader's descendant is ended and the group read empty before the launch is reported exited-7"
  # control: with the exited branch skipping the group teardown, the record
  # says exited-7 while the descendant still runs.
  mutant no-exited-unwind '    job_unit_unwind_child "$JOB_UNIT_PID" exited || { word=unwound-failed; status=$word; }' '    :'
  rm -f "$TMP_ROOT/exit-with-child/descendant" "$TMP_ROOT/exit-with-child.record"
  run env PATH="$TMP_ROOT/exit-with-child:$FARM" PROBE_ROOT="$TMP_ROOT/exit-with-child" \
    "$MUTANT" launch validate-id-1 "$TMP_ROOT/exit-with-child.record" --cap 60 \
    -- bash -c 'sleep 60 & echo $! > "$PROBE_ROOT/descendant"; exit 7'
  descendant="$(cat "$TMP_ROOT/exit-with-child/descendant" 2>/dev/null || true)"
  assert_eq "$(grep -o '^status=.*' "$TMP_ROOT/exit-with-child.record")|$(proc_state_after "$descendant")" "status=exited-7|alive" \
    "control: without the exited branch's group teardown the record says exited-7 over a running descendant"
  [[ -z "$descendant" ]] || kill -KILL "$descendant" 2>/dev/null || true

  # The exited leader's launch, with the kernel-row read failing at the shell
  # builtin during the group read after the teardown. The leader's start was
  # never read, so the record can name no identity, but the launch is reported
  # `unwound-failed` with the group's key, `pgid=` the leader's pid, which the
  # runtime reads the group by until it empties; no `pid=`/`start=` is made
  # up. The job writes `$$ $!` so the row knows the leader's pid. Answers:
  # exit|stderr|status line|pgid line|pid and start count|descendant.
  launch_exited_leader_with_unreadable_rows() { # SCRIPT RECORD
    (
      # shellcheck source=/dev/null # the script under test, or its control's copy
      source "$1"
      read() { return 1; }
      export PATH="$TMP_ROOT/exit-with-child:$FARM" PROBE_ROOT="$TMP_ROOT/exit-with-child"
      rc=0
      job_unit_main launch validate-id-1 "$2" --cap 60 -- bash -c 'sleep 60 & echo "$$ $!" > "$PROBE_ROOT/descendant"; exit 7' 2>"$TMP_ROOT/unknown-leader.err" >/dev/null || rc=$?
      printf '%s|%s' "$rc" "$(/bin/cat "$TMP_ROOT/unknown-leader.err")"
    )
  }
  rm -f -- "${TMP_ROOT:?}/exit-with-child/descendant" "${TMP_ROOT:?}/exit-with-child.record"
  answer="$(launch_exited_leader_with_unreadable_rows "$JOB_UNIT" "$TMP_ROOT/exit-with-child.record")"
  leader="$(cut -d' ' -f1 "$TMP_ROOT/exit-with-child/descendant" 2>/dev/null || true)"
  descendant="$(cut -d' ' -f2 "$TMP_ROOT/exit-with-child/descendant" 2>/dev/null || true)"
  assert_eq "$answer|$(grep -o '^status=.*' "$TMP_ROOT/exit-with-child.record")|$(grep -o '^pgid=.*' "$TMP_ROOT/exit-with-child.record")|$(grep -c '^pid=\|^start=' "$TMP_ROOT/exit-with-child.record")|$(proc_state_after "$descendant")" \
    "6|job-unit: launch-unconfirmed status=unwound-failed|status=unwound-failed|pgid=$leader|0|gone" \
    "an exited leader whose group rows cannot be read is reported possibly started, unwound-failed with the group's key, pgid= the leader's pid, no identity made up, the descendant ended"
  [[ -z "$descendant" ]] || kill -KILL "$descendant" 2>/dev/null || true
  # control: with the group key dropped from the ended record, the record
  # names nothing the runtime can read the group by.
  mutant no-pgid '-z "$JOB_UNIT_PID" ]] || printf '"'"'pgid=' '-z "$JOB_UNIT_PID" ]] || : || printf '"'"'pgid='
  rm -f -- "${TMP_ROOT:?}/exit-with-child/descendant" "${TMP_ROOT:?}/exit-with-child.record"
  answer="$(launch_exited_leader_with_unreadable_rows "$MUTANT" "$TMP_ROOT/exit-with-child.record")"
  descendant="$(cut -d' ' -f2 "$TMP_ROOT/exit-with-child/descendant" 2>/dev/null || true)"
  assert_eq "$(cut -d'|' -f1 <<<"$answer")|$(grep -o '^status=.*' "$TMP_ROOT/exit-with-child.record")|$(grep -c '^pgid=\|^pid=\|^start=' "$TMP_ROOT/exit-with-child.record")" \
    "6|status=unwound-failed|0" \
    "control: without the group key the unwound-failed record of an exited leader names no group"
  [[ -z "$descendant" ]] || kill -KILL "$descendant" 2>/dev/null || true

  # The group reader is three-valued. Over an owned live setsid sleeper it
  # reads a member; with the kernel-row read failing at the shell builtin, a
  # row that still stands is unknown, never a member gone, and the reader
  # signals nothing: the sleeper is live after both reads. Answers:
  # readable|injected|live.
  group_reader_answers() { # SCRIPT
    (
      # shellcheck source=/dev/null # the script under test, or its control's copy
      source "$1"
      setsid /bin/sleep 60 </dev/null >/dev/null 2>&1 &
      pid=$!
      n=0
      while (( n < 100 )) && [[ "$(/bin/ps -o pgid= -p "$pid" | tr -d ' ')" != "$pid" ]]; do /bin/sleep .01; n=$((n + 1)); done
      readable=0
      job_unit_group_empty "$pid" || readable=$?
      read() { return 1; }
      injected=0
      job_unit_group_empty "$pid" || injected=$?
      unset -f read
      live=gone
      ! kill -0 "$pid" 2>/dev/null || live=live
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      printf '%s|%s|%s' "$readable" "$injected" "$live"
    )
  }
  assert_eq "$(group_reader_answers "$JOB_UNIT")" "1|2|live" \
    "the group reader reads a live member as 1 and a row it cannot read as unknown, 2, never empty, and signals nothing"
  # The same injection through the launcher, on the one post-fork path that
  # holds the child's identity when it unwinds: the identity write refused
  # once (a farm `mv` that refuses the first replacement of an existing record
  # and allows the next), the child ended by its pid, then the group read with
  # every kernel row unreadable. The launch is reported `unwound-failed`,
  # never `record-unwritable` over an unknown group, and the ended record
  # keeps the leader's pid and start, the group's id the runtime reads by
  # until it empties. The child never writes its marker. Answers: exit|stderr.
  mkdir -p "$TMP_ROOT/record-once"
  printf '#!/usr/bin/env bash\nsleep 2 && echo survived > "$BARRIER_MARKER"\n' > "$TMP_ROOT/record-once/setsid"
  printf '#!/usr/bin/env bash\nfor a; do last=$a; done\nif [[ -e "$last" && ! -e "$MV_REFUSED" ]]; then : > "$MV_REFUSED"; exit 1; fi\nexec /bin/mv "$@"\n' > "$TMP_ROOT/record-once/mv"
  chmod +x "$TMP_ROOT/record-once/setsid" "$TMP_ROOT/record-once/mv"
  launch_with_unreadable_rows() { # SCRIPT RECORD
    (
      # shellcheck source=/dev/null # the script under test, or its control's copy
      source "$1"
      read() { return 1; }
      export PATH="$TMP_ROOT/record-once:$FARM" BARRIER_MARKER="$TMP_ROOT/unknown.marker" MV_REFUSED="$TMP_ROOT/unknown.refused"
      rc=0
      job_unit_main launch validate-id-1 "$2" --cap 60 -- sleep 30 2>"$TMP_ROOT/unknown.err" >/dev/null || rc=$?
      printf '%s|%s' "$rc" "$(/bin/cat "$TMP_ROOT/unknown.err")"
    )
  }
  rm -f -- "${TMP_ROOT:?}/unknown.record" "${TMP_ROOT:?}/unknown.marker" "${TMP_ROOT:?}/unknown.refused"
  assert_eq "$(launch_with_unreadable_rows "$JOB_UNIT" "$TMP_ROOT/unknown.record")|$(grep -o '^status=.*' "$TMP_ROOT/unknown.record")|$(grep -c '^pid=\|^start=' "$TMP_ROOT/unknown.record")" \
    "6|job-unit: launch-unconfirmed path=$TMP_ROOT/unknown.record status=unwound-failed|status=unwound-failed|2" \
    "a child whose identity write failed and whose group rows cannot be read is reported possibly started, unwound-failed, and the ended record keeps the leader's pid and start"
  assert_eq "$(sed -n 's/^pid=//p' "$TMP_ROOT/unknown.record" | grep -c '^[0-9][0-9]*$') $(sed -n 's/^start=//p' "$TMP_ROOT/unknown.record" | grep -c '^ticks:[0-9][0-9]*$') $([[ -f "$TMP_ROOT/unknown.marker" ]] && echo survived || echo gone)" "1 1 gone" \
    "and the kept identity is the leader's pid and its kernel start, the child ended by its pid"
  # control: with a failed row read skipped as a vanished member, the
  # unreadable group reads empty and the launch is reported by the write
  # failure alone, the record keeping no identity for a group it says ended.
  mutant read-or-continue '    { IFS= read -r row < "$stat"; } 2>/dev/null || { [[ ! -e "$stat" ]] || unknown=1; continue; }' '    { IFS= read -r row < "$stat"; } 2>/dev/null || continue'
  rm -f -- "${TMP_ROOT:?}/unknown.record" "${TMP_ROOT:?}/unknown.marker" "${TMP_ROOT:?}/unknown.refused"
  assert_eq "$(launch_with_unreadable_rows "$MUTANT" "$TMP_ROOT/unknown.record" | cut -d'|' -f1)|$(grep -o '^status=.*' "$TMP_ROOT/unknown.record")|$(grep -c '^pid=\|^start=' "$TMP_ROOT/unknown.record")" \
    "1|status=record-unwritable|0" \
    "control: with the failed read skipped as a vanished member the unreadable group reads empty and the launch is reported record-unwritable over it"

  # No process group holds a memory bound, so a launch that would run under
  # setsid refuses one, naming its runner line, and starts nothing.
  rm -f -- "${TMP_ROOT:?}/memory.record"
  run env PATH="$FARM" "$JOB_UNIT" launch validate-id-1 "$TMP_ROOT/memory.record" --memory-max 512 -- true
  assert_eq "$RC $ERR $([[ -e "$TMP_ROOT/memory.record" ]] && echo recorded || echo unrecorded)" \
    "5 job-unit: memory-max-unheld runner=setsid reason=no-systemd-run unrecorded" \
    "a --memory-max launch that would run under setsid exits 5 as memory-max-unheld and starts nothing"
else
  echo "  skip  setsid is not installed; the setsid launch rows did not run"
fi

# A systemd-run that fails after the probe answered, as a client-side timeout
# does while the manager may still start the unit. The manager's word on the
# recorded name decides: a unit it has is the job, one it has no record of
# falls back to setsid, and no answer fails the launch rather than risk a
# second copy of the job. The stubs stand for systemd-run and for the manager.
TIMED_OUT="$TMP_ROOT/timed-out"
mkdir -p "$TIMED_OUT"
printf '#!/usr/bin/env bash\n[[ "${*: -1}" == true ]] && exit 0\necho "Failed to start transient service unit: Connection timed out" >&2\nexit 1\n' > "$TIMED_OUT/systemd-run"
printf '#!/usr/bin/env bash\n[[ "$STUB_LOAD" != none ]] || exit 1\nprintf "%%s\\n" "$STUB_LOAD"\n' > "$TIMED_OUT/systemctl"
cp "$TMP_ROOT/linger/loginctl" "$TIMED_OUT/loginctl"
chmod +x "$TIMED_OUT/systemd-run" "$TIMED_OUT/systemctl"
# What a launch answers, its unit's pid folded to PID: exit, stdout, stderr and
# the record's runner.
timed_out_launch() { # STUB_LOAD
  record="$TMP_ROOT/timed-out.record"
  rm -f -- "$record"
  run env PATH="$TIMED_OUT:$FARM" STUB_LOAD="$1" "$JOB_UNIT" launch validate-id-9 "$record" --cap 60 -- sleep 5
  printf '%s|%s|%s|%s' "$RC" "$OUT" "$ERR" "$(sed -n 's/^runner=//p' "$record" 2>/dev/null)" \
    | sed 's/orch-validate-id-9-[0-9]*/orch-validate-id-9-PID/g; s/ pid=[0-9]* start=ticks:[0-9]*/ pid=PID start=START/'
}
if command -v setsid >/dev/null 2>&1; then
  detail="detail=Failed to start transient service unit: Connection timed out"
  # manager's answer|what the launch answers|label
  TIMED_OUT_ROWS=(
    "loaded%0|runner=systemd unit=orch-validate-id-9-PID||systemd%a unit the manager has after a failed call is the job, never a second copy"
    "not-found%0|runner=setsid reason=unit-launch-failed $detail pid=PID start=START||setsid%a unit the manager has no record of falls back to setsid, the launcher reading the job's identity"
    "none%6||job-unit: launch-unconfirmed unit=orch-validate-id-9-PID.service step=show $detail|systemd%a manager that does not answer leaves the launch possibly started, its unit named"
  )
  for row in "${TIMED_OUT_ROWS[@]}"; do
    IFS='%' read -r load want label <<<"$row"
    assert_eq "$(timed_out_launch "$load")" "$want" "$label"
  done
fi

# Every SIGKILL the library sends follows a SIGTERM and grace: the group's in
# job_unit_teardown, the pre-group child's in job_unit_end_child, so none is
# sent alone. The floor names a broken extractor, not a missing site.
kill_sites() { # SCRIPT — `1 1`: a grace-guarded function holds a SIGKILL, and holds every one
  local guarded all
  guarded="$(awk '
    /^job_unit_teardown[(][)]/ || /^job_unit_end_child[(][)]/ { on = 1 }
    on { print }
    on && /^}/ { on = 0 }
  ' "$1" | grep -c 'kill -KILL' || true)"
  all="$(grep -c 'kill -KILL' "$1" || true)"
  printf '%s %s' "$(( guarded >= 1 ))" "$(( all == guarded ))"
}
assert_eq "$(kill_sites "$JOB_UNIT")" "1 1" "every SIGKILL in job-unit.sh follows a SIGTERM and grace"
mutant kill-alone '  job_unit_teardown "$pid"' '  kill -KILL -- "-$pid"'
assert_eq "$(kill_sites "$MUTANT")" "1 0" "control: a SIGKILL sent outside a grace-guarded function is found"

# stop-job on a record the library cannot read is a failure, named.
printf 'runner=bogus\n' > "$TMP_ROOT/bogus.record"
run "$JOB_UNIT" stop-job "$TMP_ROOT/bogus.record" 1 "*"
assert_eq "$RC $ERR" "2 job-unit: record-unreadable path=$TMP_ROOT/bogus.record" \
  "stop-job on an unreadable record exits 2 and names it"

# A user manager that does not linger, or whose Linger cannot be read, is
# passed over for setsid: it would stop every unit when the last login session
# ends. The stubs stand for a systemd-run that would start anything and for
# loginctl's answer.
if command -v setsid >/dev/null 2>&1; then
  mkdir -p "$TMP_ROOT/no-linger" "$TMP_ROOT/linger-unread"
  printf '#!/bin/sh\nexit 0\n' > "$TMP_ROOT/no-linger/systemd-run"
  printf '#!/bin/sh\necho no\n' > "$TMP_ROOT/no-linger/loginctl"
  cp "$TMP_ROOT/no-linger/systemd-run" "$TMP_ROOT/linger-unread/systemd-run"
  printf '#!/bin/sh\necho "Failed to connect to bus: No such file or directory" >&2\nexit 1\n' > "$TMP_ROOT/linger-unread/loginctl"
  chmod +x "$TMP_ROOT"/no-linger/* "$TMP_ROOT"/linger-unread/*
  assert_linger_launch() { # SCRIPT; the current table row supplies the launch and assertion
    # shellcheck disable=SC2086 # the cap column is words
    run env PATH="$TMP_ROOT/$stub:$FARM" "$1" launch validate-linger "$TMP_ROOT/linger.record" $cap -- sleep 5
    assert_eq "$RC $(sed 's/-[0-9]*$/-PID/; s/ pid=[0-9]* start=ticks:[0-9]*//' <<<"$OUT")" "$want" "$label"
  }
  # stub dir|cap arguments|the runner line, its unit's pid folded|label
  while IFS='|' read -r stub cap want label; do
    assert_linger_launch "$JOB_UNIT"
    if [[ "$stub" == no-linger && -n "$cap" ]]; then
      mutant no-linger-guard 'elif [[ "$linger" != yes ]]; then' 'elif false && [[ "$linger" != yes ]]; then'
      control_failures="$(FAIL=0; assert_linger_launch "$MUTANT" > "$TMP_ROOT/linger-control.out"; printf '%s' "$FAIL")"
      assert_eq "$control_failures" "1" "control: the capped row rejects a bypassed linger guard"
    fi
  done <<ROWS
no-linger||0 runner=setsid reason=no-linger|a manager that does not linger is passed over for setsid
no-linger|--cap 60|0 runner=setsid reason=no-linger|a capped launch passes over a manager that does not linger for setsid
linger-unread||0 runner=setsid reason=linger-unread detail=Failed to connect to bus: No such file or directory|a Linger loginctl cannot read is no linger, named with loginctl's words
linger-unread|--cap 60|0 runner=setsid reason=linger-unread detail=Failed to connect to bus: No such file or directory|a capped launch whose Linger loginctl cannot read uses setsid with loginctl's words
ROWS
fi

# With neither systemd-run nor setsid there is no runner, and the launch says
# which command is missing.
NO_RUNNER="$TMP_ROOT/no-runner"
mkdir -p "$NO_RUNNER"
for name in bash mv tr; do
  ln -sf "$(command -v "$name")" "$NO_RUNNER/$name"
done
run env PATH="$NO_RUNNER" "$JOB_UNIT" launch validate-id-1 "$TMP_ROOT/none.record" --cap 60 -- sleep 30
assert_eq "$RC $ERR" "2 job-unit: missing-command commands=setsid" \
  "a host with neither runner exits 2 naming setsid"

# A manager that lingers but cannot start the probe unit is passed over for
# setsid, the line carrying systemd-run's own first words.
if command -v setsid >/dev/null 2>&1; then
  mkdir -p "$TMP_ROOT/probe-failed"
  printf '#!/bin/sh\necho "Failed to connect to bus: No medium found" >&2\nexit 1\n' > "$TMP_ROOT/probe-failed/systemd-run"
  chmod +x "$TMP_ROOT/probe-failed/systemd-run"
  probe_launch() { # SCRIPT
    run env PATH="$TMP_ROOT/probe-failed:$TMP_ROOT/linger:$FARM" "$1" launch validate-probe "$TMP_ROOT/probe.record" --cap 60 \
      -- bash -c 'echo $$ > "$0"; exec sleep 30' "$TMP_ROOT/probe.pid"
    JOB_PID="$(wait_job "$TMP_ROOT/probe.pid")" || :
    sed 's/ pid=[0-9]* start=ticks:[0-9]*//' <<<"$RC $OUT"
    "$JOB_UNIT" kill-group "$JOB_PID" "*sleep 30" >/dev/null 2>&1 || :
  }
  assert_eq "$(probe_launch "$JOB_UNIT")" "0 runner=setsid reason=probe-failed detail=Failed to connect to bus: No medium found" \
    "a manager whose probe unit cannot start is passed over for setsid, named with systemd-run's words"
  mutant probe-words 'reason=probe-failed detail=${probe_err%%' 'reason=probe-failed detail=${linger%%'
  assert_eq "$(probe_launch "$MUTANT")" "0 runner=setsid reason=probe-failed detail=yes" \
    "control: a fallback line that names another read's answer drops systemd-run's words"
fi

# A unit the manager will not stop fails the stop by name; one the manager no
# longer has ended on its own. The stub stands for systemctl's two answers.
mkdir -p "$TMP_ROOT/stop-refused"
printf '#!/bin/sh\ncase "$*" in *" stop "*) echo "Failed to stop orch-x.service: Access denied" >&2; exit 1 ;; esac\necho "${STOP_LOAD:-loaded}"\n' \
  > "$TMP_ROOT/stop-refused/systemctl"
chmod +x "$TMP_ROOT/stop-refused/systemctl"
run env PATH="$TMP_ROOT/stop-refused:$PATH" "$JOB_UNIT" stop orch-x
assert_eq "$RC $ERR" "2 job-unit: stop-failed unit=orch-x.service detail=Failed to stop orch-x.service: Access denied" \
  "a unit the manager refuses to stop fails stop-failed naming the unit and the manager's words"
run env PATH="$TMP_ROOT/stop-refused:$PATH" STOP_LOAD=not-found "$JOB_UNIT" stop orch-x
assert_eq "$RC $ERR" "1 " "a unit the manager has no record of exits 1, nothing stopped"
mutant stop-not-found '&& [[ "$load" == not-found ]]; then' '&& false; then'
run env PATH="$TMP_ROOT/stop-refused:$PATH" STOP_LOAD=not-found "$MUTANT" stop orch-x
assert_eq "$RC" "2" "control: without the not-found read an ended unit is a stop failure"

# --- A launch where a user manager answers ------------------------------------------
# Which runner this host gives is read off the executable's own answer: a host
# where no manager answers skips these rows, saying so.
record="$TMP_ROOT/unit.record"
run "$JOB_UNIT" launch validate-id-2 "$record" --cap 60 -- sleep 30
if [[ "$(sed -n 's/^runner=//p' "$record" 2>/dev/null)" == systemd ]]; then
  unit="$(sed -n 's/^unit=//p' "$record")"
  assert_eq "$RC ${unit%-*}-PID $OUT" "0 orch-validate-id-2-PID runner=systemd unit=$unit" \
    "a launch where a user manager answers prints runner=systemd with a unit of the documented shape"
  assert_eq "$(cat "$record")" "$(printf 'runner=systemd\nunit=%s\nline=runner=systemd unit=%s' "$unit" "$unit")" \
    "and records that runner, unit and line"
  assert_eq "$(systemctl --user is-active -- "$unit.service" 2>/dev/null || true)" "active" \
    "and that unit is running the job"

  # --cap is the unit's RuntimeMaxSec, and a launch with none, the repeat
  # watch's, sets none.
  unit_property() { # PROPERTY ARG... — exit and PROPERTY of the unit launched
    local prop="$1" rec="$TMP_ROOT/cap.record" u
    shift
    rm -f -- "${rec:?}"
    run "$JOB_UNIT" "$@" -- sleep 30
    u="$(sed -n 's/^unit=//p' "$rec" 2>/dev/null)"
    printf '%s %s' "$RC" "$(systemctl --user show -p "$prop" --value -- "${u:-none}.service" 2>/dev/null)"
    [[ -z "$u" ]] || "$JOB_UNIT" stop "$u" >/dev/null 2>&1 || true
  }
  # cap arguments|RuntimeMaxUSec|label
  while IFS='|' read -r cap want label; do
    # shellcheck disable=SC2086 # the cap column is words
    assert_eq "$(unit_property RuntimeMaxUSec launch validate-cap "$TMP_ROOT/cap.record" $cap)" "$want" "$label"
  done <<ROWS
--cap 60|0 1min|a launch with --cap sets that RuntimeMaxSec
|0 infinity|a launch with no --cap sets no RuntimeMaxSec
ROWS
  # --memory-max is the unit's MemoryMax in MiB, and a launch with none sets none.
  while IFS='|' read -r mem want label; do
    # shellcheck disable=SC2086 # the memory column is words
    assert_eq "$(unit_property MemoryMax launch validate-memory "$TMP_ROOT/cap.record" $mem)" "$want" "$label"
  done <<ROWS
--memory-max 512|0 536870912|a launch with --memory-max 512 sets MemoryMax=536870912
|0 infinity|a launch with no --memory-max sets no MemoryMax
ROWS

  # A unit starts in the user-manager slice its launch runs in, so a job an
  # agent starts stays under that agent's slice, and takes that launch's own
  # task cap and memory soft cap, so one job cannot take the slice's whole
  # pool. The launch runs from a scope with a planted TasksMax and MemoryHigh
  # in a slice this row plants; each control's unit misses what it removes.
  PLANTED_SLICE="jobunittest$$.slice" PLANTED_TASKS=321 PLANTED_HIGH=67108864
  launched_from_scope() { # SCRIPT [OPTION...] — the unit's Slice, TasksMax and MemoryHigh, each planted or what else it is
    local script="$1" rec="$TMP_ROOT/slice.record" u slice tasks high
    shift
    rm -f -- "${rec:?}"
    systemd-run --user --scope --quiet --slice="$PLANTED_SLICE" \
      -p "TasksMax=$PLANTED_TASKS" -p "MemoryHigh=$PLANTED_HIGH" \
      -- "$script" launch validate-slice "$rec" --cap 60 "$@" -- sleep 30 </dev/null >/dev/null 2>&1 || true
    u="$(sed -n 's/^unit=//p' "$rec" 2>/dev/null)"
    slice="$(systemctl --user show -p Slice --value -- "${u:-none}.service" 2>/dev/null || true)"
    tasks="$(systemctl --user show -p TasksMax --value -- "${u:-none}.service" 2>/dev/null || true)"
    high="$(systemctl --user show -p MemoryHigh --value -- "${u:-none}.service" 2>/dev/null || true)"
    case "$slice" in
      "$PLANTED_SLICE") slice=planted ;;
      "") slice=none ;;
      *) slice=other ;;
    esac
    [[ "$tasks" != "$PLANTED_TASKS" ]] || tasks=planted
    [[ "$tasks" == planted ]] || tasks=other
    [[ "$high" != "$PLANTED_HIGH" ]] || high=planted
    printf '%s %s %s' "$slice" "$tasks" "$high"
    [[ -z "$u" ]] || "$JOB_UNIT" stop "$u" >/dev/null 2>&1 || true
  }
  assert_eq "$(launched_from_scope "$JOB_UNIT")" "planted planted planted" \
    "a unit starts in the slice its launch runs in, with that launch's task cap and memory soft cap"
  assert_eq "$(launched_from_scope "$JOB_UNIT" --memory-max 512)" "planted planted infinity" \
    "a launch with --memory-max takes no memory soft cap from its caller"
  # control;old text;new text;launch option;unit;label
  while IFS=';' read -r name old new option want label; do
    mutant "$name" "$old" "$new"
    # shellcheck disable=SC2086 # the option column is words
    assert_eq "$(launched_from_scope "$MUTANT" $option)" "$want" "$label"
  done <<'ROWS'
no-slice;unit_props+=(--slice="$slice");:;;other planted planted;control: without the slice pass-through the unit starts in another slice
no-tasks-max;unit_props+=(-p "TasksMax=$cap");:;;planted other planted;control: without the task cap pass-through the unit takes the manager's default
no-memory-high;unit_props+=(-p "MemoryHigh=$cap");:;;planted planted infinity;control: without the memory soft cap pass-through the unit has none
memory-high-over-max;[[ -z "$memory_max" ]] && cap=;cap=;--memory-max 512;planted planted planted;control: without the --memory-max check the caller's soft cap rides beside it
ROWS
  systemctl --user stop -- "$PLANTED_SLICE" >/dev/null 2>&1 || true

  # A service ignores SIGPIPE by default; a unit job takes it at its default,
  # as a job the caller starts does. SigIgn bit 13 is SIGPIPE.
  sigpipe_state() {
    local out="$TMP_ROOT/sigign.$RANDOM" n=0
    run "$JOB_UNIT" launch validate-sigpipe "$TMP_ROOT/sigpipe.record" -- sh -c 'sed -n "s/^SigIgn:[[:space:]]*//p" /proc/self/status > "$0"' "$out"
    while [[ ! -s "$out" ]] && (( n < 50 )); do sleep 0.1; n=$((n + 1)); done
    if [[ -s "$out" ]]; then
      (( (16#$(cat "$out") >> 12) & 1 )) && echo ignored || echo default
    else
      echo unread
    fi
  }
  assert_eq "$(sigpipe_state)" "default" "a unit job takes SIGPIPE at its default"
  # exit of the first stop, then of a second stop of the same name
  STOP_ROWS=("0|a running unit is stopped by its exact name" "1|a unit that has ended answers not-found, apart from a failure")
  for row in "${STOP_ROWS[@]}"; do
    IFS='|' read -r want label <<<"$row"
    run "$JOB_UNIT" stop "$unit"
    assert_eq "$RC" "$want" "$label"
  done
  assert_eq "$(systemctl --user is-active -- "$unit.service" 2>/dev/null || true)" "inactive" \
    "and the unit is gone"

  # Control: a manager's not-found read as a failure.
  mutant no-not-found '&& [[ "$load" == not-found ]]; then' '&& false; then'
  run "$MUTANT" stop "$unit"
  assert_eq "$RC $(sed 's/ detail=.*$//' <<<"$ERR")" "2 job-unit: stop-failed unit=$unit.service" \
    "control: without the not-found read an ended unit is a stop failure, named on stderr"
else
  echo "  skip  no systemd user manager answers on this host ($(sed -n 's/^line=//p' "$record" 2>/dev/null)); the unit rows did not run"
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
