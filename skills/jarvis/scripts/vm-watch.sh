#!/usr/bin/env bash
# Usage: vm-watch.sh [--home PATH] [--side NAME] [--cursor JSON] [--renew]
# One mail pass. The complete output ends with its public cursor record.
set -euo pipefail
SCRIPT_ROOT="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
exec python3 -B "$SCRIPT_ROOT/lib/watch.py" pass --bash "$BASH" "$@"
