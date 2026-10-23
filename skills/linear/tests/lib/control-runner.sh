# shellcheck shell=bash
# Install the runner and its test-only process owner beside a synthetic skill.
CONTROL_RUNNER_TESTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
control_runner_install() {
    local root="$1"
    mkdir -p "$root/tests/lib" "$root/../orch/tests/lib" "$root/../orch/scripts/lib"
    cp "$CONTROL_RUNNER_TESTS/must-fail-controls.sh" "$root/tests/must-fail-controls.sh"
    cp "$CONTROL_RUNNER_TESTS/lib/control-runner.sh" "$root/tests/lib/control-runner.sh"
    cp "$CONTROL_RUNNER_TESTS/../../orch/tests/lib/suite-process.sh" "$root/../orch/tests/lib/suite-process.sh"
    cp "$CONTROL_RUNNER_TESTS/../../orch/scripts/lib/lane-state.sh" "$root/../orch/scripts/lib/lane-state.sh"
}
