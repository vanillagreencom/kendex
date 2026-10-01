#!/usr/bin/env bash
# kendex runs repository-effect installers from the consumer root.
set -euo pipefail
SCRIPT_DIR="$(dirname -- "${BASH_SOURCE[0]}")" || exit 1
SCRIPT_DIR="$(cd -- "$SCRIPT_DIR" && pwd -P)" || exit 1
workflow=.github/workflows/mac-run.yml

if [ -e "$workflow" ] || [ -L "$workflow" ]; then
  printf 'xcode-run: preserved=%s\n' "$workflow"
  exit 0
fi

mkdir -p .github/workflows
# A workflow created after the presence check is still consumer-owned.
set -o noclobber
cat -- "$SCRIPT_DIR/../templates/mac-run.yml" > "$workflow"
printf 'xcode-run: installed=%s\n' "$workflow"