#!/usr/bin/env bash
# What a TERM to tests/must-fail-controls.sh stops, driven against a synthetic
# one-suite skill rather than this one.
#
# The runner removes its scratch as it exits, so a suite it leaves running
# goes on against a deleted copy, and the job that launched it goes on to
# stage the next copy under a scratch that is gone. Nothing in a run over
# skills/linear sends the runner a signal, so only a fixture reaches this.
#
#   - a TERM to the runner while a suite runs stops that suite: each level
#     passes it to the one under it, down through `timeout`
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
RUNNER="$SCRIPT_DIR/must-fail-controls.sh"
assert_tmpdir TMP

# A suite that says it has started, then runs until a TERM stops it and says
# so. The runner's cap would stop it too, so the cap sits past the deadline
# below: a suite stopped within the deadline was stopped by the TERM.
root="$TMP/skill"
marks="$TMP/marks"
mkdir -p "$root/scripts" "$root/tests/controls" "$marks"
cat >"$root/tests/alpha.test.sh" <<SUITE
#!/usr/bin/env bash
trap ': >"$marks/stopped"; exit 143' TERM
: >"$marks/started"
while :; do sleep 0.05; done
SUITE
printf '%s\n' 'control_expect "unused"' >"$root/tests/controls/alpha.control.sh"
cp "$RUNNER" "$root/tests/must-fail-controls.sh"

# wait_for FILE — whether FILE appears within ten seconds.
wait_for() {
    local i
    for ((i = 0; i < 200; i++)); do
        [ -e "$1" ] && return 0
        sleep 0.05
    done
    return 1
}

CONTROL_TIMEOUT=20 bash "$root/tests/must-fail-controls.sh" >"$TMP/run.log" 2>&1 &
runner=$!
if ! wait_for "$marks/started"; then
    kill -TERM "$runner" 2>/dev/null
    wait "$runner"
    assert_stop "the fixture suite starts under the runner" "$(cat "$TMP/run.log")"
fi
kill -TERM "$runner"
wait "$runner"

stopped=no
wait_for "$marks/stopped" && stopped=yes
assert_eq "a TERM to the runner stops the suite it is running" "$stopped" yes
