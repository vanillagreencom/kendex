#!/usr/bin/env bash
# The `--no-private-env` global flag on workflow-state: a caller reading
# another checkout's state parses that checkout's settings files and never
# sources its private env file, which would run the checkout's shell in the
# caller. Each row reads the fleet state's path in a checkout whose settings
# move the state directory and whose private env file writes a sentinel. The
# must-fail controls close the file, one per rule, each on a private copy.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd -P)"
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo "=== workflow-state --no-private-env ==="

PEER="$TMP_ROOT/peer"
SENTINEL="$TMP_ROOT/sourced"
git init -q "$PEER"
printf '[env]\nORCH_STATE_DIR = "fleet"\n' > "$PEER/kendex.settings.toml"
printf 'touch %q\n' "$SENTINEL" > "$PEER/.env.local"

OUT=""
path_of() { # SCRIPT [GLOBAL OPTS...]
  local script="$1"
  shift
  rm -f -- "$SENTINEL"
  OUT="$(cd "$PEER" && env -u ORCH_STATE_DIR -u KENDEX_ENV_FILE "$script" "$@" path oversee)"
}
sourced() { if [ -e "$SENTINEL" ]; then echo sourced; else echo unsourced; fi; }

# ARGS|PATH|SENTINEL|LABEL, ARGS `-` for none.
while IFS='|' read -r args want sentinel label; do
  if [ "$args" = - ]; then path_of "$WS"; else path_of "$WS" "$args"; fi
  assert_eq "$OUT $(sourced)" "$want $sentinel" "$label"
done <<EOF
-|$PEER/fleet/workflow-state-oversee.json|sourced|without the flag the private env file is sourced
--no-private-env|$PEER/fleet/workflow-state-oversee.json|unsourced|the flag reads the settings and never sources the private env file
EOF

path_of "$WS" --state-dir "$TMP_ROOT/given" --no-private-env
assert_eq "$OUT $(sourced)" "$TMP_ROOT/given/workflow-state-oversee.json unsourced" \
  "the flag stands beside --state-dir"

# --- must-fail controls ------------------------------------------------------
mutant() { # NAME OLD NEW
  MUTANT="$(mutant_scripts "mutants/$1" workflow-state)/workflow-state" || exit 1
  mutate_file "$MUTANT" "$2" "$3"
}

mutant sources-anyway 'if [[ "$parse_rc" -eq 9 ]]; then' 'if true; then'
path_of "$MUTANT" --no-private-env
assert_eq "$(sourced)" "sourced" "control: a loader that ignores the flag sources the private env file"

mutant no-settings '    kendex_load_settings_file "$PROJECT_ROOT/kendex.settings.toml"' '    :'
path_of "$MUTANT" --no-private-env
assert_eq "$OUT" "$PEER/tmp/workflow-state-oversee.json" \
  "control: without the settings load the flag reads the default state directory"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
