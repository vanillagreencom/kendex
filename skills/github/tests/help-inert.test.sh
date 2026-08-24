#!/usr/bin/env bash
# Help is inert: github.sh answers help and routes a subcommand's --help
# before loading project configuration or touching auth, so a repository
# .env never runs as shell code under --help and help cannot fail on auth.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GITHUB_SH="$(cd "$TEST_DIR/.." && pwd)/scripts/github.sh"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

check() {
  local name="$1" token="$2"; shift 2
  local out
  if out=$(cd "$TMP/repo" && "$GITHUB_SH" "$@") && grep -qF "$token" <<<"$out"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$name"
  fi
}

echo "=== github.sh help is answered before project config and auth ==="

mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
printf 'touch "%s/env-executed"\n' "$TMP" >"$TMP/repo/.env"

check "--help prints the command index" "GitHub API CLI" --help
check "help prints the command index" "GitHub API CLI" help
check "-h prints the command index" "GitHub API CLI" -h
check "bare invocation prints the command index" "GitHub API CLI"
check "label-add --help routes to the subcommand help" "Add a label" label-add --help
check "pr-view --help routes to the subcommand help" "View PR details" pr-view --help
check "pr-merge -h routes to the subcommand help" "Merge PR" pr-merge -h
check "pr-view 123 --help routes late-position help" "View PR details" pr-view 123 --help
check "pr-merge 42 -h routes late-position help" "Merge PR" pr-merge 42 -h

if [[ -e "$TMP/env-executed" ]]; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "help sourced the project .env"
else
  PASS=$((PASS + 1)); printf '  ok    %s\n' "no help form sourced the project .env"
fi

echo
echo "=== -h/--help supplied as an option's VALUE stays data ==="

# A stub gh keeps the run local: the point is only that the router loads
# project configuration (the marker) instead of routing to help.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 1\n' >"$TMP/bin/gh"
chmod +x "$TMP/bin/gh"

value_case() {
  local name="$1" token="$2"; shift 2
  local out
  rm -f "$TMP/env-executed"
  set +e
  out=$(cd "$TMP/repo" && PATH="$TMP/bin:$PATH" "$GITHUB_SH" "$@" 2>&1)
  set -e
  if grep -qF "$token" <<<"$out"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (printed help)\n' "$name"
  else
    PASS=$((PASS + 1)); printf '  ok    %s treats it as data\n' "$name"
  fi
  if [[ -e "$TMP/env-executed" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s loads project config\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s loads project config\n' "$name"
  fi
}

value_case "find-comment 42 --pattern -h" "Find PR Comment" find-comment 42 --pattern -h
value_case "post-comment 42 --body -h" "Post PR-Level Comment" post-comment 42 --body -h

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
