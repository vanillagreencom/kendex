#!/usr/bin/env bash
# Help is inert: second-opinion answers -h/--help at any argument position
# before sourcing project configuration, so the script repository's .env
# never runs as shell code under --help. The script resolves its project
# root from its own location, so the copy under test lives inside the
# fixture repository.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1"; shift
  local out
  if out=$("$TMP/repo/scripts/second-opinion" "$@") && grep -qF "Cross-model second opinion" <<<"$out"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$name"
  fi
}

echo "=== second-opinion help is answered before project config loads ==="

mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
cp -R "$SCRIPTS_DIR" "$TMP/repo/scripts"
printf 'touch "%s/env-executed"\n' "$TMP" >"$TMP/repo/.env"

check "--help prints help" --help
check "-h prints help" -h
check "review --help prints help" review --help
check "quick -h prints help" quick -h

if [[ -e "$TMP/env-executed" ]]; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "help sourced the project .env"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "no help form sourced the project .env"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
