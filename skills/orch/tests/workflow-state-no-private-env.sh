#!/usr/bin/env bash
# The `--no-private-env` global flag on workflow-state: a caller reading
# another checkout's state parses that checkout's settings files and never
# sources its private env file, which would run the checkout's shell in the
# caller, and takes ORCH_STATE_DIR alone from those settings, so no PATH or
# loader variable of the checkout's reaches a tool the caller runs. Each row
# reads the fleet state in a checkout whose settings move the state directory
# and whose private env file or [env] table would run its own code. The
# must-fail controls close the file, one per rule, each on a private copy.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd -P)"
# mktemp alone, so set -e stops the suite on its failure: nested in the cd,
# a failed mktemp would resolve to this directory and the trap would remove it.
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
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
git -C "$PEER" config gc.auto 0
git -C "$PEER" config maintenance.auto false
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

# A peer whose [env] points PATH at its own jq and head, each writing RAN
# before running the real one, and sets LD_PRELOAD to a path of its own. The
# sender's jq, first on this shell's PATH, writes the LD_PRELOAD it was
# handed. .kendex/settings.toml moves the state past kendex.settings.toml's:
# each directory holds a state answering its own name.
ARMED="$TMP_ROOT/armed"
RAN="$TMP_ROOT/ran"
SEEN="$TMP_ROOT/seen"
git init -q "$ARMED"
git -C "$ARMED" config gc.auto 0
git -C "$ARMED" config maintenance.auto false
mkdir -p "$ARMED/bin" "$ARMED/.kendex" "$ARMED/fleet" "$ARMED/fleet2" "$TMP_ROOT/sender"
for tool in jq head; do
  printf '#!/bin/sh\n: > %q\nexec %q "$@"\n' "$RAN" "$(command -v "$tool")" > "$ARMED/bin/$tool"
  chmod +x "$ARMED/bin/$tool"
done
printf '#!/bin/sh\nprintf %%s "${LD_PRELOAD-unset}" > %q\nexec %q "$@"\n' "$SEEN" "$(command -v jq)" \
  > "$TMP_ROOT/sender/jq"
chmod +x "$TMP_ROOT/sender/jq"
printf '[env]\nPATH = "%s"\nLD_PRELOAD = "%s"\nORCH_STATE_DIR = "fleet"\n' \
  "$ARMED/bin" "$ARMED/preload.so" > "$ARMED/kendex.settings.toml"
printf '[env]\nORCH_STATE_DIR = "fleet2"\n' > "$ARMED/.kendex/settings.toml"
printf '{"answer":"fleet"}\n' > "$ARMED/fleet/workflow-state-oversee.json"
printf '{"answer":"fleet2"}\n' > "$ARMED/fleet2/workflow-state-oversee.json"
armed_get() { # SCRIPT
  rm -f -- "$RAN" "$SEEN"
  OUT="$(cd "$ARMED" && env -u ORCH_STATE_DIR -u KENDEX_ENV_FILE -u LD_PRELOAD \
    PATH="$TMP_ROOT/sender:$PATH" "$1" --no-private-env get oversee .answer 2>/dev/null)" || OUT="refused"
  if [ -e "$RAN" ]; then OUT="$OUT ran"; else OUT="$OUT unrun"; fi
  OUT="$OUT preload=$(cat -- "$SEEN" 2>/dev/null || echo none)"
}
armed_get "$WS"
assert_eq "$OUT" "fleet2 unrun preload=unset" \
  "the flag takes ORCH_STATE_DIR alone: the peer's PATH and LD_PRELOAD never reach the sender's jq"

# --- must-fail controls ------------------------------------------------------
mutant() { # NAME OLD NEW
  MUTANT="$(mutant_scripts "mutants/$1" workflow-state)/workflow-state" || exit 1
  mutate_file "$MUTANT" "$2" "$3"
}

mutant sources-anyway 'if [[ "$parse_rc" -eq 9 ]]; then' 'if true; then'
path_of "$MUTANT" --no-private-env
assert_eq "$(sourced)" "sourced" "control: a loader that ignores the flag sources the private env file"

mutant no-settings 'for settings_file in kendex.settings.toml .kendex/settings.toml; do' 'for settings_file in; do'
path_of "$MUTANT" --no-private-env
assert_eq "$OUT" "$PEER/tmp/workflow-state-oversee.json" \
  "control: without the settings load the flag reads the default state directory"

mutant whole-table '        settings_dir="$(settings_state_dir "$PROJECT_ROOT/$settings_file")" || exit 1' \
  '        kendex_load_settings_file "$PROJECT_ROOT/$settings_file" || exit 1; settings_dir=""'
armed_get "$MUTANT"
assert_eq "${OUT#* }" "ran preload=none" \
  "control: a loader that sets the whole [env] table in the sender runs the peer's own tools"

mutant file-order 'for settings_file in kendex.settings.toml .kendex/settings.toml; do' \
  'for settings_file in .kendex/settings.toml kendex.settings.toml; do'
armed_get "$MUTANT"
assert_eq "${OUT%% *}" "fleet" \
  "control: read in the other order, kendex.settings.toml's state directory outranks .kendex/settings.toml's"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
