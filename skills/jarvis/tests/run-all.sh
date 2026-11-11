#!/usr/bin/env bash
# Run every Jarvis suite in this directory, `nproc` at a time, through the
# orch battery's runner, whose header states the name filters, the worker
# pool, --alone and the report. tools/guard runs a changed tree's selected
# suites through this file, and CI's jarvis leg already runs this battery
# through the same runner. A suite here shares its host with the others, so it
# keeps its files, tmux servers and processes inside its own scratch; one
# holding a wall-clock window that a loaded host makes it miss takes an
# `--alone NAME` after `--battery "$dir"` below, which runs it by itself after
# the rest.
#
# Usage:
#   bash skills/jarvis/tests/run-all.sh
#   bash skills/jarvis/tests/run-all.sh =succession.test   # one suite
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$dir/../../orch/tests/run-all.sh" --battery "$dir" "$@"
