#!/usr/bin/env bash
# Run every orchestration regression test script in this directory.
# Exits 0 if all pass, 1 if any fails. Output is per-script so a failure
# in one file does not hide failures in another.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

overall=0
ran=0
for t in "$TEST_DIR"/*.sh; do
  [[ -f "$t" ]] || continue
  name=$(basename "$t")
  [[ "$name" == "run-all.sh" ]] && continue
  ran=$((ran + 1))
  printf '\n### %s ###\n' "$name"
  if ! bash "$t"; then
    overall=1
  fi
done

if [[ "$ran" -eq 0 ]]; then
  echo "run-all.sh: no test scripts found under $TEST_DIR" >&2
  exit 1
fi

if [[ "$overall" -eq 0 ]]; then
  printf '\nrun-all: all %d test script(s) passed\n' "$ran"
else
  printf '\nrun-all: one or more test scripts failed\n' >&2
fi

exit "$overall"
