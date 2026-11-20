#!/usr/bin/env bash
# Inputs: skills/agent-runtime/scripts/, skills/github/scripts/,
# skills/mailbox/scripts/, skills/worktree/scripts/.
# lib/lane-host-ssh-tests.py copies or runs these from paths it builds on
# its package's parent, reads the scan cannot see.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
python3 "$(dirname "${BASH_SOURCE[0]}")/lib/lane-host-ssh-tests.py"
