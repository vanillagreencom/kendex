#!/usr/bin/env bash
# The battery's entry for the one-job suite: run-all.sh globs tests/*.sh, and
# the suite itself lives in tests/job/ beside the stub harness it launches.
# Every argument reaches it (a row filter).
# Inputs: skills/orch/scripts/, skills/orch/tests/.
set -euo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/job/one-job.sh" "$@"
