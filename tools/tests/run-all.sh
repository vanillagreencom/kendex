#!/usr/bin/env bash
# Run every tools/ suite in this directory, `nproc` at a time, through the
# orch battery's runner, whose header states the name filters, the worker
# pool, --alone and the report; tools/guard runs the tree's suites through
# this file. A suite here shares its host with the others, so it keeps every
# file and process it makes inside its own sandbox, and one holding a fixed
# wall-clock window that a loaded host has made it miss takes an
# `--alone NAME` after `--battery "$dir"` below, which runs it by itself after
# the rest. The runner's own ALONE list holds orch's suites, never these.
#
# Usage:
#   bash tools/tests/run-all.sh
#   bash tools/tests/run-all.sh guard   # subset by name, as the runner reads it
set -euo pipefail
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$dir/../../skills/orch/tests/run-all.sh" --battery "$dir" "$@"
