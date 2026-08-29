#!/usr/bin/env bash
# Bash 3.2 with nounset rejects an empty array expanded as "${array[@]}".
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-$TEST_DIR/../scripts/container-close}"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

check_target() {
  local target="$1" stripped hits status
  stripped="$(sed -E 's/\$\{([_A-Za-z][_A-Za-z0-9]*)\[@\]\+"\$\{\1\[@\]\}"\}//g' "$target")" \
    || { echo "container-close Bash 3.2 guard could not read $target" >&2; return 2; }
  status=0
  hits="$(grep -nE '\$\{[_A-Za-z][_A-Za-z0-9]*\[@\]\}' <<<"$stripped")" || status=$?
  [[ "$status" -le 1 ]] || { echo "container-close Bash 3.2 guard could not scan $target" >&2; return 2; }
  [[ -z "$hits" ]] || { printf 'Bash 3.2-unsafe empty-array expansion in %s:\n%s\n' "$target" "$hits" >&2; return 1; }
}

check_target "$TARGET"
[[ "$TARGET" == "$TEST_DIR/../scripts/container-close" ]] || exit 0

MUTANT="$TMP_ROOT/container-close"
[[ "$(grep -Fc 'for id in ${ids[@]+"${ids[@]}"}; do' "$TARGET")" -eq 1 ]] \
  || { echo "container-close Bash 3.2 control could not find the guarded empty-array loop" >&2; exit 1; }
awk 'index($0, "for id in ${ids[@]+\"${ids[@]}\"}; do") { print "  for id in \"${ids[@]}\"; do"; next } { print }' \
  "$TARGET" > "$MUTANT"
if check_target "$MUTANT" >/dev/null 2>&1; then
  echo "container-close Bash 3.2 guard accepts the unsafe empty-array mutant" >&2
  exit 1
fi

echo "pass: container-close-bash32"
