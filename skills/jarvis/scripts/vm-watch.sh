#!/usr/bin/env bash
# Usage: vm-watch.sh [--home PATH] [--side NAME] [--cursor JSON] [--presence]
# One mail pass. The complete output ends with its public cursor record.
set -euo pipefail
SCRIPT_ROOT="$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)"
if [ -n "${_KENDEX_JARVIS_PYTHON:-}" ]; then
  exec "$_KENDEX_JARVIS_PYTHON" caller-script "$SCRIPT_ROOT/lib" "$SCRIPT_ROOT/lib/watch.py" pass --bash "$BASH" "$@"
fi
exec python3 -B "$SCRIPT_ROOT/lib/watch.py" pass --bash "$BASH" "$@"
