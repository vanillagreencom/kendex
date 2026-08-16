#!/usr/bin/env bash
# growth-guards runs on consumer CI images and on macOS system Bash 3.2, so
# shipped scripts may not use Bash 4+ builtins or syntax (mapfile/readarray,
# associative arrays, automatic FD-allocation redirections, case-conversion
# expansions).
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"

PATTERN='mapfile|readarray|declare -A|declare -gA|local -A'
PATTERN="$PATTERN"'|(^|[^$])\{[A-Za-z_][A-Za-z0-9_]*\}[<>]'
PATTERN="$PATTERN"'|\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(,,|\^\^)'

violations="$(grep -rnE "$PATTERN" "$SCRIPTS_DIR" || true)"
if [[ -n "$violations" ]]; then
  echo "Bash 4+ constructs found in growth-guards scripts (must run under Bash 3.2):" >&2
  printf '%s\n' "$violations" >&2
  exit 1
fi

# Syntax-check every shipped script while we are here.
fail=0
for f in "$SCRIPTS_DIR"/growth-guards "$SCRIPTS_DIR"/todo-ban "$SCRIPTS_DIR"/byte-ceiling \
  "$SCRIPTS_DIR"/suppression-ban "$SCRIPTS_DIR"/commit-msg "$SCRIPTS_DIR"/lib/*.sh; do
  if ! bash -n "$f"; then
    echo "FAIL: bash -n $f"
    fail=1
  fi
done
[ "$fail" -eq 0 ] || exit 1

echo "pass: bash32-portability"
