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
#     passes it to the one under it, and the timed suite's own handler names
#     the suite it stops, so the row reads the runner's acknowledgement and
#     the suite's end rather than when a handler in the suite ran
#   - a missed stop names the first level whose TERM handler never ran, and
#     prints the runner's trace, the inner run's log and the suite's identity
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
source "$SCRIPT_DIR/lib/control-runner.sh"
# started_at: the runner's own process identity reader, which a zombie and a
# reused pid both fail.
source "$SCRIPT_DIR/../../orch/tests/lib/suite-process.sh" || exit 2
assert_tmpdir TMP
# The runner's TERM handlers append their entries here; an empty file is a
# runner that wrote none.
export CONTROL_TRACE="$TMP/trace"
: >"$CONTROL_TRACE"

# A suite that writes its pid once it has started, then runs until a signal
# ends it. The runner's cap would stop it too, so the cap sits past the
# deadline below, and the acknowledgement it waits for is the TERM's.
root="$TMP/skill"
marks="$TMP/marks"
mkdir -p "$root/scripts" "$root/tests/controls" "$marks"
cat >"$root/tests/alpha.test.sh" <<SUITE
#!/usr/bin/env bash
printf '%s\\n' "\$\$" >"$marks/started"
while :; do sleep 0.05; done
SUITE
printf '%s\n' 'control_expect "unused"' >"$root/tests/controls/alpha.control.sh"
control_runner_install "$root"

# wait_for COMMAND... — whether COMMAND succeeds within ten seconds.
wait_for() {
    local i
    for ((i = 0; i < 200; i++)); do
        "$@" && return 0
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
if ! wait_for test -s "$marks/started"; then
    kill -TERM "$runner" 2>/dev/null
    wait "$runner"
    assert_stop "the fixture suite starts under the runner" "$(cat "$TMP/run.log")"
fi
read -r suite_pid <"$marks/started"
if ! suite_start="$(started_at "$suite_pid")"; then
    kill -TERM "$runner" 2>/dev/null
    wait "$runner"
    assert_stop "the fixture suite's identity reads before the TERM" "pid=$suite_pid" "$(cat "$TMP/run.log")"
fi
kill -TERM "$runner"
kill_rc=$?
wait "$runner"
wait_rc=$?
waited="$(clock)"

# suite_stopped — the timed suite's handler acknowledged the TERM for this
# suite, and this suite has ended, by that TERM or by the KILL after its grace.
suite_stopped() {
    grep -Fq -- " timed_suite TERM suite=[$suite_pid]" "$CONTROL_TRACE" &&
        [ "$(started_at "$suite_pid")" != "$suite_start" ]
}

stopped=no
wait_for suite_stopped && stopped=yes
assert_eq "a TERM to the runner stops the suite it is running" "$stopped" yes

# The stop chain's levels in order, each as the trace line its TERM handler
# writes on entry. The first one missing is the level the stop never reached.
# With every handler entered, the suite still running is the rest: the tree
# stop or the identity reader under the timed suite missed it.
if [ "$stopped" != yes ]; then
    step=trace-unread
    now="$(started_at "$suite_pid")" || now=ended
    capture=(
        "test: kill=$kill_rc wait=$wait_rc waited=$waited gave-up=$(clock)"
        "marks: started=$(mark_time "$marks/started")"
        "suite: pid=$suite_pid start=$suite_start now=$now"
    )
    if [ -r "$CONTROL_TRACE" ]; then
        step=suite-alive
        for entry in "runner-term| runner TERM pid=" "job-term| job TERM body=" \
            "timed-suite-term| timed_suite TERM suite=[$suite_pid]"; do
            grep -Fq -- "${entry#*|}" "$CONTROL_TRACE" || { step="${entry%%|*}"; break; }
        done
        while IFS= read -r line; do capture+=("trace: $line"); done <"$CONTROL_TRACE"
    fi
    while IFS= read -r line; do capture+=("run.log: $line"); done <"$TMP/run.log"
    assert_fail "a missed TERM stop names its first missing step: $step" "${capture[@]}"
fi
