#!/usr/bin/env bash
# Run every orch test in tests/*.sh.
#
# Each individual *.sh test is self-contained: builds its own sandbox,
# exercises the target script, prints `pass: N   fail: M`, exits 0 iff
# all assertions passed. This runner just invokes them in lexical order
# and aggregates the overall exit code so CI / pre-commit hooks have a
# single entry point.
#
# Usage:
#   bash skills/orch/tests/run-all.sh
#   bash skills/orch/tests/run-all.sh session_init      # subset by name
#   bash skills/orch/tests/run-all.sh open-terminal oversee   # either name
#   bash skills/orch/tests/run-all.sh '!open-terminal' '!oversee'  # neither
#
# Each argument is a substring of a suite's base name. A bare one selects,
# one written `!name` rejects, and a file runs when it matches a selector —
# or none was given — and matches no rejector. Two runs whose arguments are
# a set and that set negated therefore partition the battery: every suite
# runs in exactly one of them, and a suite added later lands in the negated
# run rather than in neither. CI's orch shards are that partition.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SELECT=()
REJECT=()
for arg in "$@"; do
  case "$arg" in
    '') echo "run-all.sh: empty name filter; a filter is a substring of a suite's base name" >&2; exit 1 ;;
    '!'*) REJECT+=("${arg#\!}") ;;
    *) SELECT+=("$arg") ;;
  esac
done
FILTER="$*"

# Bash 3.2 under `set -u` errors on "${arr[@]}" when arr is empty, so each
# expansion below sits behind its own count.
wanted() { # BASE
  local keep=1 pat
  if [ "${#SELECT[@]}" -gt 0 ]; then
    keep=0
    for pat in "${SELECT[@]}"; do
      case "$1" in *"$pat"*) keep=1; break ;; esac
    done
  fi
  if [ "$keep" -eq 1 ] && [ "${#REJECT[@]}" -gt 0 ]; then
    for pat in "${REJECT[@]}"; do
      case "$1" in *"$pat"*) keep=0; break ;; esac
    done
  fi
  [ "$keep" -eq 1 ]
}

FAIL_FILES=()
RUN=0

for test_file in "$TEST_DIR"/*.sh; do
  [[ -f "$test_file" ]] || continue
  base=$(basename "$test_file" .sh)
  [[ "$base" == "run-all" ]] && continue
  wanted "$base" || continue
  RUN=$((RUN + 1))
  printf '\n──── %s ────\n' "$base"
  bash "$test_file"
  test_status=$?
  if [[ "$test_status" -eq 0 ]]; then
    :
  else
    FAIL_FILES+=("$base")
  fi
done

if [[ "$RUN" -eq 0 ]]; then
  if [[ -n "$FILTER" ]]; then
    echo "run-all.sh: no test scripts matched filter '$FILTER' under $TEST_DIR" >&2
  else
    echo "run-all.sh: no test scripts found under $TEST_DIR" >&2
  fi
  exit 1
fi

echo
echo "============================================"
if [[ ${#FAIL_FILES[@]} -eq 0 ]]; then
  printf 'orch tests: all %d file(s) passed\n' "$RUN"
  exit 0
else
  printf 'orch tests: %d/%d file(s) FAILED:\n' "${#FAIL_FILES[@]}" "$RUN"
  for f in "${FAIL_FILES[@]}"; do
    printf '  - %s\n' "$f"
  done
  exit 1
fi
