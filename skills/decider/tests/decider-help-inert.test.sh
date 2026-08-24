#!/usr/bin/env bash
# Help is inert: decisions answers every help form before sourcing project
# configuration, so a repository .env never runs as shell code under --help,
# and help needs neither jq nor a decisions directory.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$TEST_DIR/.." && pwd)/scripts/decisions"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1"; shift
  local out
  if out=$(cd "$TMP/repo" && "$SCRIPT" "$@") && grep -qF "Decision Lookup Tool" <<<"$out"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$name"
  fi
}

echo "=== decisions help is answered before project config loads ==="

mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
printf 'touch "%s/env-executed"\n' "$TMP" >"$TMP/repo/.env"

check "bare invocation prints help"
check "help action prints help" help
check "--help prints help" --help
check "-h prints help" -h
check "bare search prints help" search
check "search --help prints help" search --help

if [[ -e "$TMP/env-executed" ]]; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "help sourced the project .env"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "no help form sourced the project .env"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
