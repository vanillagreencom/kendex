#!/usr/bin/env bash
# Pins for scripts/py-names: a staged Python script holding an undefined name
# is refused at its path and line, and a clean one is judged and passes. A row
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

echo "=== an undefined name is refused; a clean script passes ==="
ROW=0
for row in \
  "a staged script using an undefined name is refused at its line|x = 1\nprint(undefined_x)\n|rc=1 py-names: undefined-name=script.py:2" \
  "a clean staged script is judged and passes|import os\nprint(os.sep)\n|rc=0 py-names: summary=violations=0 files=1 scope=staged skipped=0"; do
  IFS='|' read -r label content expect <<<"$row"
  ROW=$((ROW + 1))
  r="$TMP/row-$ROW"
  git -c init.defaultBranch=main init -q "$r"
  printf '%b' "$content" >"$r/script.py"
  git -C "$r" add script.py
  assert_eq "$label" "$expect" "$(run "$r")"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
