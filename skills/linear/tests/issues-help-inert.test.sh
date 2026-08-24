#!/usr/bin/env bash
# Help is inert: issues.sh answers every help form before sourcing its
# libraries — common.sh sources the repository's .env files as shell code
# and resolves API auth, and help needs neither.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
ISSUES_SH="$SKILL_DIR/scripts/commands/issues.sh"
LINEAR_SH="$SKILL_DIR/scripts/linear.sh"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1" script="$2"; shift 2
  local out
  if out=$(cd "$TMP/repo" && bash "$script" "$@") && grep -qF "Issue Operations" <<<"$out"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$name"
  fi
}

echo "=== issues.sh help is answered before the libraries load ==="

mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
printf 'touch "%s/env-executed"\n' "$TMP" >"$TMP/repo/.env"

check "--help prints issue help" "$ISSUES_SH" --help
check "help prints issue help" "$ISSUES_SH" help
check "bare invocation prints issue help" "$ISSUES_SH"
check "activate --help prints issue help" "$ISSUES_SH" activate --help
check "get --help prints issue help" "$ISSUES_SH" get --help
check "validate-completion --help prints issue help" "$ISSUES_SH" validate-completion --help
check "routed linear.sh issues --help prints issue help" "$LINEAR_SH" issues --help

if [[ -e "$TMP/env-executed" ]]; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "help sourced the project .env"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "no help form sourced the project .env"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
