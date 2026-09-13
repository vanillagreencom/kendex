#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
python3 "$(dirname "${BASH_SOURCE[0]}")/lib/lane-host-tests.py"
