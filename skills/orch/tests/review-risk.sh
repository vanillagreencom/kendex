#!/usr/bin/env bash
# review-risk helper contract: one checked invocation the review-pr workflow
# can call under restrictive approval policies. Exit 0 + validated level,
# exit 3 when the opt-in key is unset, exit 1 (terse stderr, never the
# captured output) on failure — callers fail open to the full fleet.
# Trust boundary: config + executable resolve from the TRUSTED checkout the
# helper runs from; only the classifier cwd is the reviewed worktree.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# The helper resolves the trusted root from its own location (four dirs up),
# so install a copy under a hermetic root: <root>/.agents/skills/orch/scripts.
ROOT="$TMP_ROOT/trusted"
mkdir -p "$ROOT/.agents/skills/orch/scripts" "$ROOT/tools"
cp "$TEST_DIR/../scripts/review-risk" "$ROOT/.agents/skills/orch/scripts/review-risk"
cp "$TEST_DIR/../scripts/orch-env" "$ROOT/.agents/skills/orch/scripts/orch-env"
cp -R "$TEST_DIR/../scripts/lib" "$ROOT/.agents/skills/orch/scripts/lib" 2>/dev/null || true
REVIEW_RISK="$ROOT/.agents/skills/orch/scripts/review-risk"

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

WT="$TMP_ROOT/wt"
mkdir -p "$WT/only-here"

# Trusted classifier fixture: prints its first arg (or 'low'), proving both
# arg passthrough and that execution CWD is the worktree.
cat > "$ROOT/tools/classify" <<'SH'
#!/usr/bin/env bash
if [ ! -d only-here ]; then echo "wrong-cwd" ; exit 0; fi
printf '%s\n' "${1:-low}"
SH
chmod +x "$ROOT/tools/classify"

echo "=== review-risk helper contract ==="

set +e
out=$(REVIEW_RISK_COMMAND="" "$REVIEW_RISK" "$WT" 2>/dev/null)
rc=$?
set -e
assert_eq "$rc" "3" "unset REVIEW_RISK_COMMAND exits 3"
assert_eq "$out" "" "unset key prints nothing"

for level in high medium low; do
  out=$(REVIEW_RISK_COMMAND="tools/classify $level" "$REVIEW_RISK" "$WT")
  assert_eq "$out" "$level" "classifier '$level' passes through (trusted exe + arg, worktree cwd)"
done

# Classifier stderr must not corrupt the parsed answer.
cat > "$ROOT/tools/noisy" <<'SH'
#!/usr/bin/env bash
echo "scanning..." >&2
echo low
SH
chmod +x "$ROOT/tools/noisy"
out=$(REVIEW_RISK_COMMAND="tools/noisy" "$REVIEW_RISK" "$WT" 2>/dev/null)
assert_eq "$out" "low" "classifier stderr does not break level parsing"

# Shell strings refuse — the classifier is a file, not a bash -c string.
set +e
REVIEW_RISK_COMMAND="echo low && touch $TMP_ROOT/pwned" "$REVIEW_RISK" "$WT" 2>"$TMP_ROOT/err0"
rc=$?
set -e
assert_eq "$rc" "1" "shell metacharacters refuse"
[ ! -e "$TMP_ROOT/pwned" ] || { FAIL=$((FAIL + 1)); printf '  FAIL  refused shell string still executed\n'; }
grep -q "not a shell string" "$TMP_ROOT/err0" || { FAIL=$((FAIL + 1)); printf '  FAIL  refusal explains the file-not-string contract\n'; }

# Path escapes refuse.
set +e
REVIEW_RISK_COMMAND="../outside" "$REVIEW_RISK" "$WT" 2>/dev/null
rc=$?
set -e
assert_eq "$rc" "1" "dot-dot classifier path refuses"

# The executable resolves in the TRUSTED root, not the worktree: a
# worktree-local (attacker) copy at the same relative path is never run.
mkdir -p "$WT/tools"
cat > "$WT/tools/evil" <<'SH'
#!/usr/bin/env bash
echo high
touch pwned-by-worktree
SH
chmod +x "$WT/tools/evil"
set +e
REVIEW_RISK_COMMAND="tools/evil" "$REVIEW_RISK" "$WT" 2>/dev/null
rc=$?
set -e
assert_eq "$rc" "1" "worktree-only classifier is not executed (trusted-root resolution)"
[ ! -e "$WT/pwned-by-worktree" ] || { FAIL=$((FAIL + 1)); printf '  FAIL  worktree copy executed\n'; }

# Contract violations: garbage level, failing exe — exit 1, stderr terse
# (names the relative path, never the captured output).
cat > "$ROOT/tools/garbage" <<'SH'
#!/usr/bin/env bash
echo "critical: secret-token-abc123"
SH
chmod +x "$ROOT/tools/garbage"
set +e
REVIEW_RISK_COMMAND="tools/garbage" "$REVIEW_RISK" "$WT" 2>"$TMP_ROOT/err1"
rc=$?
set -e
assert_eq "$rc" "1" "unrecognized level exits 1"
grep -q "high|medium|low" "$TMP_ROOT/err1" || { FAIL=$((FAIL + 1)); printf '  FAIL  contract error names the expected levels\n'; }
grep -q "secret-token-abc123" "$TMP_ROOT/err1" && { FAIL=$((FAIL + 1)); printf '  FAIL  captured output leaked into stderr\n'; } || true

cat > "$ROOT/tools/failing" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$ROOT/tools/failing"
set +e
REVIEW_RISK_COMMAND="tools/failing" "$REVIEW_RISK" "$WT" 2>"$TMP_ROOT/err2"
rc=$?
set -e
assert_eq "$rc" "1" "failing classifier exits 1"

set +e
REVIEW_RISK_COMMAND="tools/classify" "$REVIEW_RISK" "$TMP_ROOT/missing" 2>/dev/null
rc=$?
set -e
assert_eq "$rc" "1" "missing worktree exits 1"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
