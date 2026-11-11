#!/usr/bin/env bash
# Inputs: hooks/, skills/agent-runtime/, skills/github/scripts/, skills/mailbox/scripts/,
# skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/, skills/worktree/scripts/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
python3 "$(dirname "${BASH_SOURCE[0]}")/lib/lane-host-ssh-tests.py"
