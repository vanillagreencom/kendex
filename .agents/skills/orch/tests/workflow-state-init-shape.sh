#!/usr/bin/env bash
# `workflow-state init` seeds the list-valued keys its callers read back, so a
# reader that forgets its `// []` default meets a list rather than null.
# `near_ceiling` is the one ../workflows/dev-start.md § Store Near-Ceiling Lines
# writes and the delegation templates read; it is seeded like `qa_labels`.
# Row per key: the seeded value, and the same read on a key nothing seeds,
# which is what tells a seeded empty list apart from an absent one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

sd="$TMP_ROOT/state"
"$WS" --state-dir "$sd" init KEN-1 --worktree "$REPO_ROOT" --branch ken-1 >/dev/null
STATE="$sd/workflow-state-KEN-1.json"

echo "=== init seeds the list keys its readers expect ==="

# ABSENT distinguishes a key holding an empty list from a key that is not
# there: `// []` at every call site would read the same for both.
seeded() { jq -c --arg k "$1" 'if has($k) then .[$k] else "ABSENT" end' "$STATE"; } # KEY

while IFS='|' read -r key want name; do
  [ -n "$key" ] || continue
  assert_eq "$(seeded "$key")" "$want" "$name"
done <<'ROWS'
near_ceiling|[]|near_ceiling is an empty list, not absent: the delegation templates read it back
qa_labels|[]|qa_labels is seeded the same way, the shape near_ceiling matches
no_such_key|"ABSENT"|control: a key init does not seed reads ABSENT, so the rows above are not vacuous
ROWS

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
