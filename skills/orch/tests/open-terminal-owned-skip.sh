#!/usr/bin/env bash
# Regression tests for open-terminal's per-item worktree-create handling.
#
# The worktree create is the ownership claim for a fleet launch: exit 75 means
# another session holds the item. Under `set -euo pipefail` an unguarded
# `wt="$(worktree create ...)"` aborted the WHOLE batch on the first owned
# item, so its siblings never launched. An owned item must be skipped (named on
# stderr, counted in the summary) and the remaining items still launch; any
# other create failure is that item's failure alone, not an abort.
#
# The test runs a byte-identical copy of open-terminal inside a temp git repo
# so `git rev-parse --show-toplevel` resolves to a hermetic PROJECT_ROOT, and
# stubs the worktree CLI (scripted per-item exit codes, call log), the GUI
# terminal, and gh so nothing external is launched.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="${OPEN_TERMINAL_UNDER_TEST:-$SCRIPTS_DIR/open-terminal}"
SRC_LIB="$SCRIPTS_DIR/lib/vstack-env.sh"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        forbidden substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

# Shared stub bin: a fake GUI terminal (exit 0 so open_gui's success echo runs)
# and a fake gh (exit 1 so resolve_repo yields empty without touching network).
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/ghostty" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/ghostty" "$BIN/gh"

# Stub worktree CLI: `create <item>` logs the call, then exits with the code in
# $STUB_EXIT_DIR/<item> when that file exists, else makes and prints a dir.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "create" ]]; then
  printf '%s\n' "\${2:-unknown}" >> "\$STUB_CALL_LOG"
  if [[ -f "\$STUB_EXIT_DIR/\${2:-unknown}" ]]; then
    echo "stub: refusing \${2:-unknown}" >&2
    exit "\$(cat "\$STUB_EXIT_DIR/\${2:-unknown}")"
  fi
  d="$TMP_ROOT/wt/\${2:-unknown}"
  mkdir -p "\$d"
  printf '%s\n' "\$d"
  exit 0
fi
echo "unexpected worktree stub call: \$*" >&2
exit 1
EOF
chmod +x "$STUB"

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/scripts/lib"
cp "$SRC_OT" "$REPO/scripts/open-terminal"
cp "$SRC_LIB" "$REPO/scripts/lib/vstack-env.sh"
chmod +x "$REPO/scripts/open-terminal"
git -C "$REPO" init -q
OT="$REPO/scripts/open-terminal"

# run_case <name> -- ITEM...   (stub exit codes pre-seeded in $EXIT_DIR)
run_case() {
  local name="$1"; shift; shift
  CALL_LOG="$TMP_ROOT/$name.calls"
  : > "$CALL_LOG"
  set +e
  OUT=$(PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" STUB_CALL_LOG="$CALL_LOG" STUB_EXIT_DIR="$EXIT_DIR" \
    "$OT" --ghostty --cmd 'echo {item}' "$@" 2>"$TMP_ROOT/$name.err")
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/$name.err")"
}

echo "=== open-terminal: owned item is skipped, siblings launch ==="

# Case 1: one of three items is owned elsewhere (create exit 75).
EXIT_DIR="$TMP_ROOT/exit1"; mkdir -p "$EXIT_DIR"
printf '75' > "$EXIT_DIR/CC-2"
run_case c1 -- CC-1 CC-2 CC-3
assert_eq "$RC" "0" "exit 0 when siblings launched around an owned item"
assert_eq "$(tr '\n' ' ' < "$CALL_LOG")" "CC-1 CC-2 CC-3 " "create attempted for every item (no abort at the owned one)"
assert_contains "$OUT" "Opened terminal 'CC-1'" "item before the owned one launches"
assert_contains "$OUT" "Opened terminal 'CC-3'" "item after the owned one launches"
assert_not_contains "$OUT" "Opened terminal 'CC-2'" "owned item is not launched"
assert_contains "$ERR" "Skipped CC-2: owned by another session (worktree create exit 75)" "owned item named on stderr"
assert_contains "$OUT" "Done: launched 2 handoff session(s), skipped 1 (owned by another session)." "summary reports launched=2 skipped=1"

# Case 2: every item owned elsewhere -> nothing launched, exit 75.
EXIT_DIR="$TMP_ROOT/exit2"; mkdir -p "$EXIT_DIR"
printf '75' > "$EXIT_DIR/CC-1"; printf '75' > "$EXIT_DIR/CC-2"
run_case c2 -- CC-1 CC-2
assert_eq "$RC" "75" "exit 75 when every item is owned by another session"
assert_not_contains "$OUT" "Opened terminal" "nothing launched when every item is owned"
assert_contains "$ERR" "launched 0 handoff session(s), skipped 2 (owned by another session)" "all-skipped summary names the counts"

# Case 3: a non-75 create failure is that item's failure; siblings still launch.
EXIT_DIR="$TMP_ROOT/exit3"; mkdir -p "$EXIT_DIR"
printf '1' > "$EXIT_DIR/CC-2"
run_case c3 -- CC-1 CC-2 CC-3
assert_eq "$RC" "1" "exit 1 when one create fails for a non-ownership reason"
assert_eq "$(tr '\n' ' ' < "$CALL_LOG")" "CC-1 CC-2 CC-3 " "create attempted for every item (no abort at the failed one)"
assert_contains "$OUT" "Opened terminal 'CC-3'" "item after the failed one still launches"
assert_contains "$ERR" "Error: worktree create failed for CC-2 (exit 1)" "create failure names the item and exit code"
assert_contains "$ERR" "1 handoff lane(s) failed; launched 2 successfully." "summary reports failed=1 launched=2"
assert_not_contains "$ERR" "Skipped CC-2" "a non-75 create failure is not reported as skipped"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
