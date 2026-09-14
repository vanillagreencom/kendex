#!/usr/bin/env bash
# Pins for scripts/py-names: a staged Python script holding an undefined name
# or a syntax error is refused at its path and line, and a clean one is judged
# and passes. A row
# stages CONTENT as script.py in a fresh repository, runs the lane with
# --staged, and pins the exit status with the first stable line printed.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PY_NAMES="$SKILL_DIR/scripts/py-names"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

run() { # REPO — the exit status and the first stable line
  local rc=0 out=""
  out="$(cd "$1" && "$PY_NAMES" --staged 2>&1)" || rc=$?
  out="$(printf '%s\n' "$out" | LC_ALL=C awk '/^py-names: [a-z-]+=/ && !seen { print; seen=1 }')"
  printf 'rc=%s %s' "$rc" "$out"
}

echo "=== an undefined name and a syntax error are refused; a clean script passes ==="
ROW=0
for row in \
  "a staged script using an undefined name is refused at its line|x = 1\nprint(undefined_x)\n|rc=1 py-names: undefined-name=script.py:2" \
  "a staged script that does not parse is refused at its line|x = 1\ndef f(:\n|rc=1 py-names: invalid-syntax=script.py:2" \
  "a clean staged script is judged and passes|import os\nprint(os.sep)\n|rc=0 py-names: summary=violations=0 files=1 scope=staged skipped=0" \
  "a staged script using builtins Python 3.13 added passes|print(ExceptionGroup, PythonFinalizationError)\n|rc=0 py-names: summary=violations=0 files=1 scope=staged skipped=0"; do
  IFS='|' read -r label content expect <<<"$row"
  ROW=$((ROW + 1))
  r="$TMP/row-$ROW"
  git -c init.defaultBranch=main init -q "$r"
  printf '%b' "$content" >"$r/script.py"
  git -C "$r" add script.py
  assert_eq "$label" "$expect" "$(run "$r")"
done

echo "=== with neither tool reachable the lane refuses and names the CI remedy ==="
# A shim cannot hide a real ruff from `command -v`, so every PATH entry holding
# one is dropped; a python3 that exits 1 stands in for the pyflakes probe, the
# lane's only other use of python3 before it picks a tool.
mkdir -p "$TMP/no-tool-bin"
printf '#!/bin/sh\nexit 1\n' >"$TMP/no-tool-bin/python3"
chmod +x "$TMP/no-tool-bin/python3"
NO_TOOL_PATH="$TMP/no-tool-bin"
while IFS= read -r dir; do
  [ -x "$dir/ruff" ] || NO_TOOL_PATH="$NO_TOOL_PATH:$dir"
done <<<"${PATH//:/$'\n'}"
r="$TMP/row-tool-missing"
git -c init.defaultBranch=main init -q "$r"
printf 'x = 1\n' >"$r/script.py"
git -C "$r" add script.py
rc=0
out="$(cd "$r" && PATH="$NO_TOOL_PATH" "$PY_NAMES" --staged 2>&1)" || rc=$?
assert_eq "a selected file with neither tool installed refuses at the stable key" \
  "rc=2 py-names: tool-missing=ruff,pyflakes" \
  "rc=$rc $(printf '%s\n' "$out" | LC_ALL=C awk '/^py-names: [a-z-]+=/ && !seen { print; seen=1 }')"
assert_eq "the refusal carries the CI ordering remedy" \
  "  In CI, install ruff, or pyflakes for python3, in a step before the commit-guards step, and on every run, including a harness-only run." \
  "$(printf '%s\n' "$out" | LC_ALL=C awk '/^  In CI, /')"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
