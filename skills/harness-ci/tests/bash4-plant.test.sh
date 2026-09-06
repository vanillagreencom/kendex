#!/usr/bin/env bash
# Teeth for the macOS Bash 3.2 leg: a quoted builtin name the text scan does
# not see. Bash 5 runs it; Bash 3.2 has no such command. Removed next commit.
set -euo pipefail
'mapfile' -t values </dev/null
printf 'ran under Bash %s\n' "$BASH_VERSION"
