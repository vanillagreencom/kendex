#!/usr/bin/env bash
# Help is inert: issues.sh answers every help form before sourcing its
# libraries — common.sh sources the repository's .env.local as shell code
# and resolves API auth, and help needs neither.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$TEST_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
ISSUES_SH="$SKILL_DIR/scripts/commands/issues.sh"
LINEAR_SH="$SKILL_DIR/scripts/linear.sh"

assert_tmpdir TMP
TMP="$(cd "$TMP" && pwd -P)"

check() {
  local name="$1" script="$2"
  shift 2
  local out="" rc=0

  out=$(cd "$TMP/repo" && bash "$script" "$@" 2>&1) || rc=$?

  assert_eq "$name: exits zero" "$rc" 0
  assert_contains "$name" "$out" "Issue Operations"
}

mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q
printf 'touch "%s/env-executed"\n' "$TMP" >"$TMP/repo/.env.local"

check "--help prints issue help" "$ISSUES_SH" --help
check "help prints issue help" "$ISSUES_SH" help
check "bare invocation prints issue help" "$ISSUES_SH"
check "activate --help prints issue help" "$ISSUES_SH" activate --help
check "get --help prints issue help" "$ISSUES_SH" get --help
check "validate-completion --help prints issue help" "$ISSUES_SH" validate-completion --help
check "routed linear.sh issues --help prints issue help" "$LINEAR_SH" issues --help
# Any argv position, with option values skipped: --limit consumes the 5.
check "get KEN-1 --help prints issue help" "$ISSUES_SH" get KEN-1 --help
check "list --limit 5 -h prints issue help" "$ISSUES_SH" list --limit 5 -h

assert_not "no help form sourced the project .env.local" test -e "$TMP/env-executed"

# -h supplied as an option's VALUE stays data: the libraries load (the
# marker appears) and no help prints.
value_out=""
value_out=$(cd "$TMP/repo" && bash "$ISSUES_SH" create --title -h 2>&1) || true

assert_not_contains "create --title -h treats -h as data" "$value_out" "Issue Operations"
assert "create --title -h loads the libraries" test -e "$TMP/env-executed"
