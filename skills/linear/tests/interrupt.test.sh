#!/usr/bin/env bash
# bash-runtime: 3.2
# What a TERM to tests/must-fail-controls.sh stops, driven against a synthetic
# one-suite skill rather than this one.
#
# The runner removes its scratch as it exits, so a suite it leaves running
# goes on against a deleted copy, and the job that launched it goes on to
# stage the next copy under a scratch that is gone. Nothing in a run over
# skills/linear sends the runner a signal, so only a fixture reaches this.
#
#   - a TERM to the runner while a suite runs stops that suite: each level
#     passes it to the one under it
#   - a missed stop names the first step of that chain its trace lacks, and
#     prints the trace, the inner run's log and the marks under that name
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/control-runner.sh"
source "$SCRIPT_DIR/../../orch/tests/lib/suite-process.sh"
assert_tmpdir TMP
# The stop chain's trace: the runner's levels write it through suite_trace,
# the fixture below in the same line format.
export SUITE_TRACE="$TMP/trace"

# A suite that says it has started, then runs until a TERM stops it and says
# so. The runner's cap would stop it too, so the cap sits past the deadline
# below: a suite stopped within the deadline was stopped by the TERM. Its trap
# takes half a second, inside the one second the runner grants before KILL.
root="$TMP/skill"
marks="$TMP/marks"
mkdir -p "$root/scripts" "$root/tests/controls" "$marks"
cat >"$root/tests/alpha.test.sh" <<SUITE
#!/usr/bin/env bash
trap 'printf "%s fixture TERM\\n" "\${EPOCHREALTIME:--}" >>"$SUITE_TRACE"; sleep 0.5; : >"$marks/stopped"; printf "%s fixture stop-mark rc=%s\\n" "\${EPOCHREALTIME:--}" "\$?" >>"$SUITE_TRACE"; exit 143' TERM
: >"$marks/started"
printf '%s fixture started pid=%s ppid=%s\n' "\${EPOCHREALTIME:--}" "\$\$" "\$PPID" >>"$SUITE_TRACE"
while :; do sleep 0.05; done
SUITE
printf '%s\n' 'control_expect "unused"' >"$root/tests/controls/alpha.control.sh"
control_runner_install "$root"

# wait_for FILE — whether FILE appears within ten seconds.
wait_for() {
    local i
    for ((i = 0; i < 200; i++)); do
        [ -e "$1" ] && return 0
        sleep 0.05
    done
    return 1
}

# A wall clock and a file's modification time for the capture, read in this
# shell, where a fork delays no step of the stop. Perl reads sub-second time on
# both macOS and Linux; Bash 3.2 and BSD date do not.
clock() {
    perl -MTime::HiRes=time -e 'printf "%.6f\n", time' 2>/dev/null || echo unread
}
mark_time() { # FILE
    [ -e "$1" ] || { echo absent; return 0; }
    perl -MTime::HiRes=stat -e 'printf "%.6f\n", (stat $ARGV[0])[9]' "$1" 2>/dev/null || echo unread
}

CONTROL_TIMEOUT=20 bash "$root/tests/must-fail-controls.sh" >"$TMP/run.log" 2>&1 &
runner=$!
if ! wait_for "$marks/started"; then
    kill -TERM "$runner" 2>/dev/null
    wait "$runner"
    assert_stop "the fixture suite starts under the runner" "$(cat "$TMP/run.log")"
fi
runner_start="$(lane_process_start "$runner")" || runner_start=unread
# The runner counts its grace in SECONDS, which steps on the wall clock's
# whole seconds. A TERM sent 0.6s past one leaves 0.4s to the next, less than
# the fixture's trap takes, so a grace that can end at the next step reddens
# this row on every run rather than by chance.
if ! perl -MTime::HiRes=time,sleep -e '$f = time - int(time); sleep(($f < 0.6 ? 0.6 : 1.6) - $f)'; then
    kill -TERM "$runner" 2>/dev/null
    wait "$runner"
    assert_stop "the TERM is sent at a known point of the wall-clock second"
fi
kill -TERM "$runner"
kill_rc=$?
wait "$runner"
wait_rc=$?
suite_trace "test runner=$runner kill=$kill_rc wait=$wait_rc wait-start=$(clock)"

stopped=no
wait_for "$marks/stopped" && stopped=yes
suite_trace "test wait-end=$(clock) stopped=$stopped"
assert_eq "a TERM to the runner stops the suite it is running" "$stopped" yes

# The chain's steps in order, each as the trace line that shows it done. The
# first one missing is the step the stop never reached; with none missing the
# mark came after the wait ended.
if [ "$stopped" != yes ]; then
    step=trace-unread
    traced=""
    capture=(
        "bash: $(command -v bash) $(bash -c 'echo "$BASH_VERSION"'); this shell $BASH_VERSION"
        "tools: ps=$(command -v ps) perl=$(command -v perl || echo absent) timeout=$(command -v timeout)"
        "runner: pid=$runner start=$runner_start"
        "marks: started=$(mark_time "$marks/started") stopped=$(mark_time "$marks/stopped")"
    )
    if [ -f "$SUITE_TRACE" ]; then
        step=late
        while IFS='|' read -r key pattern; do
            grep -Eq -- "$pattern" "$SUITE_TRACE" || { step="$key"; break; }
        done <<'STEPS'
runner-term| runner TERM pid=
runner-forward| runner forwarded rc=0$
job-term| job TERM body=
job-forward| job forwarded body=[0-9]+ rc=0$
timed-suite-term| timed_suite TERM suite=
tree-read| tree root=[0-9]+ hops=0 pid=[0-9]+ start=[A-Z]
suite-signal| signal TERM pid=[0-9]+ rc=0$
fixture-term| fixture TERM$
fixture-mark| fixture stop-mark rc=0$
STEPS
        while IFS= read -r line; do capture+=("trace: $line"); done <"$SUITE_TRACE"
        traced="$(sed -n -e 's/.* jobs=\[\([0-9 ]*\)\].*/\1/p' -e 's/.* body=\[\([0-9]*\)\].*/\1/p' \
            -e 's/.* fixture started pid=\([0-9]*\) ppid=\([0-9]*\)$/\1 \2/p' "$SUITE_TRACE")"
    fi
    # Each process the trace names and each child of one, as it stands now:
    # gone, or where it waits.
    for pid in $traced; do
        line="$(ps -o pid= -o ppid= -o stat= -o wchan= -o command= -p "$pid" 2>&1)" || line="$pid gone"
        capture+=("process: $line")
    done
    if table="$(ps -A -o pid= -o ppid= -o stat= -o wchan= -o command= 2>&1)"; then
        # shellcheck disable=SC2086 # one word per traced pid
        while IFS= read -r line; do
            [ -z "$line" ] || capture+=("child: $line")
        done <<<"$(awk -v traced=" $(printf '%s ' $traced)" 'index(traced, " " $2 " ")' <<<"$table")"
    else
        capture+=("children: unread: $table")
    fi
    while IFS= read -r line; do capture+=("run.log: $line"); done <"$TMP/run.log"
    assert_fail "a missed TERM stop names its first missing step: $step" "${capture[@]}"
fi
