#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: jarvis-session succeed and interrupted succession recovery.
# Inputs: skills/jarvis/scripts/, skills/jarvis/tests/, skills/orch/scripts/,
# skills/mailbox/scripts/, skills/orch/tests/fixtures/oversee-watch/, rust-toolchain.toml.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
export JARVIS_TEST_BASH="$BASH"
exec python3 "$ROOT/skills/jarvis/tests/succession_test.py" "$@"
