#!/usr/bin/env bash
# tools/hook-table --check: the tree's hooks/README.md is what its hooks
# generate, and each frontmatter rule the check holds turns a copy of that tree
# red on the one defect its row plants. The hand-edited table cell is
# guard.test.sh's row, through the guard lane that runs this check. Every
# finding opens with `hook-table: <key>=<value>`; a row pins that line and the
# exit status.
set -euo pipefail
TOOLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="$TOOLS/../hooks"
TMP="$(mktemp -d)" || { echo "hook-table.test: mktemp -d failed" >&2; exit 2; }
trap 'rm -rf -- "$TMP"' EXIT
PASS=0
FAIL=0

check() { # DIR LABEL WANT
  local rc=0 first
  (cd "$1" && "$TOOLS/hook-table" --check) >/dev/null 2>"$TMP/stderr" || rc=$?
  first=$(sed -n 1p "$TMP/stderr")
  if [ "rc=$rc first=$first" = "$3" ]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      rc=%s first=%s\n' "$2" "$3" "$rc" "$first"
  fi
}

check "$TOOLS/.." "the tree's hooks/README.md is what its hooks generate" "rc=0 first="

rows=0
while IFS='|' read -r label hook edit want; do
  [ -n "$label" ] || continue
  rows=$((rows + 1))
  rm -rf -- "$TMP/tree"
  mkdir -p "$TMP/tree/hooks"
  cp "$HOOKS"/*.sh "$HOOKS/README.md" "$TMP/tree/hooks/"
  sed "$edit" "$HOOKS/$hook.sh" >"$TMP/tree/hooks/$hook.sh"
  if cmp -s "$HOOKS/$hook.sh" "$TMP/tree/hooks/$hook.sh"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        the edit changed nothing\n' "$label"
    continue
  fi
  check "$TMP/tree" "$label" "$want"
done <<'ROWS'
a harness the line leaves out with no reason sentence|reviewer-stop-check|s/Not run on copilot: [^.]*\. //|rc=1 first=hook-table: missing-reason=reviewer-stop-check:copilot
a harness id outside the eight|lane-mail-check|s/harnesses: \[claude,/harnesses: [claude-code,/|rc=1 first=hook-table: unknown-harness=lane-mail-check:claude-code
ROWS
[ "$rows" -gt 0 ] || { echo "hook-table.test: no row was read" >&2; exit 2; }

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
