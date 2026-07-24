#!/usr/bin/env bash
# Regression test for the second-opinion CLI-failure gate (vstack#809).
#
# When the external CLI fails to produce ANY review — it exits non-zero
# (quota/auth/network), times out, or returns nothing on a zero exit — the
# wrapper used to exit 0 with no artifact and no sidecar (or a generic exit 1),
# so a caller trusting the documented exit-code contract recorded success with
# no external opinion, invisibly, exactly when the lane was down. The fix routes
# these into the no-verdict class (like the no-scope/no-review gates): review/
# audit modes preserve whatever partial output exists as <output>.failed.json,
# echo the CLI's own error text on stderr, and exit EXIT_CLI_FAILED (5). This
# stays distinct from exit 4 (a model that answered but unusably) and does not
# apply to challenge/quick, which keep the generic exit 1.
#
# Drives the real script with a fake target CLI (no network). The stub is
# named `claude` and placed on PATH so the script's `command -v` validation
# passes; its exit code, stdout, stderr, and an optional sleep (for the timeout
# path) are controlled by env vars, and it records each invocation so the
# no-retry expectation on a hard failure can be asserted.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SECOND_OPINION="$REPO_ROOT/skills/second-opinion/scripts/second-opinion"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected: %s\n        got:      %s\n' "$want" "$got" >&2
  fi
}

assert_file_exists() {
  local file="$1" name="$2"
  if [[ -f "$file" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file to exist: %s\n' "$file" >&2
  fi
}

assert_file_absent() {
  local file="$1" name="$2"
  if [[ ! -e "$file" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file to NOT exist: %s\n' "$file" >&2
  fi
}

assert_file_contains() {
  local file="$1" needle="$2" name="$3"
  if [[ -f "$file" ]] && grep -Fq "$needle" "$file"; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file %s to contain: %s\n' "$file" "$needle" >&2
    if [[ -f "$file" ]]; then
      echo "        --- file contents ---" >&2
      sed -n '1,40p' "$file" >&2
    else
      echo "        (file does not exist)" >&2
    fi
  fi
}

# --- Fake target CLI ----------------------------------------------------------
# Behaviour is env-driven: STUB_RC (exit code), STUB_STDOUT (what it prints),
# STUB_STDERR (its error text, the "cause"), STUB_SLEEP (seconds, for the
# timeout path). Increments an on-disk counter so a hard-failure run can assert
# the wrapper did NOT proceed to the JSON-recovery retry. Named `claude` on PATH.
mkdir -p "$TMP_ROOT/bin"
STUB="$TMP_ROOT/bin/claude"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0)
[[ -n "$n" ]] || n=0
n=$((n + 1))
printf '%s' "$n" > "$STUB_COUNTER"
cat > /dev/null            # drain the prompt on stdin
[[ "${STUB_SLEEP:-0}" != "0" ]] && sleep "$STUB_SLEEP"
[[ -n "${STUB_STDERR:-}" ]] && printf '%s\n' "$STUB_STDERR" >&2
[[ -n "${STUB_STDOUT:-}" ]] && printf '%s' "$STUB_STDOUT"
exit "${STUB_RC:-0}"
SH
chmod +x "$STUB"

# --- Throwaway git repo for --cwd --------------------------------------------
WORK="$TMP_ROOT/work"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
printf 'hello\n' > "$WORK/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" -c commit.gpgsign=false commit -q -m init
git -C "$WORK" checkout -q -b scope-branch
# Uncommitted change so `--range HEAD` yields a non-empty diff — the scope gate
# (vstack#652) refuses to run a review over an empty diff.
printf 'world\n' >> "$WORK/file.txt"

COUNTER="$TMP_ROOT/counter"

# The exact usage-limit shape from the incident report.
QUOTA_ERR="ERROR: You've hit your usage limit. Visit https://chatgpt.com/codex/settings/usage to purchase more credits."

# run_mode <mode> <extra-args...> then env passed via caller — returns rc.
# Runs `second-opinion <mode>` with the stub as target, resetting the counter.
run_review() {
  printf '0' > "$COUNTER"
  local out="$1" errf="$2" mode="${3:-review}"; shift 3 || true
  local rc=0
  set +e
  PATH="$TMP_ROOT/bin:$PATH" \
    SECOND_OPINION_TARGET=claude \
    SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_COUNTER="$COUNTER" \
    "$SECOND_OPINION" "$mode" --range HEAD --cwd "$WORK" --output "$out" "$@" \
      >/dev/null 2>"$errf"
  rc=$?
  set -e
  return "$rc"
}

mkdir -p "$TMP_ROOT/out"

# --- Scenario 1: external CLI exits non-zero (quota) --------------------------
echo "=== scenario 1: non-zero CLI exit (usage limit) exits 5, .failed.json, cause named ==="
s1_out="$TMP_ROOT/out/review1.json"
s1_err="$TMP_ROOT/s1.stderr"
rc1=0
STUB_RC=1 STUB_STDERR="$QUOTA_ERR" run_review "$s1_out" "$s1_err" || rc1=$?
assert_eq "$rc1" "5" "non-zero CLI exit yields EXIT_CLI_FAILED (5)"
assert_file_absent "$s1_out" "non-zero CLI exit writes no --output artifact"
assert_file_exists "$s1_out.failed.json" "non-zero CLI exit preserves <output>.failed.json"
assert_file_contains "$s1_out.failed.json" "hit your usage limit" "sidecar captures the CLI's own cause text"
assert_file_contains "$s1_out.failed.json" "exited with code 1" "sidecar records the failure reason"
assert_file_contains "$s1_err" "hit your usage limit" "stderr surfaces the quota cause, not a bare code"
assert_file_contains "$s1_err" "refusing to write a review artifact" "stderr error JSON explains the refusal"
assert_eq "$(cat "$COUNTER")" "1" "hard CLI failure does not proceed to the recovery retry"

# --- Scenario 2: zero exit but empty stdout ----------------------------------
echo "=== scenario 2: zero exit, empty response exits 5, .failed.json, cause named ==="
s2_out="$TMP_ROOT/out/review2.json"
s2_err="$TMP_ROOT/s2.stderr"
rc2=0
STUB_RC=0 STUB_STDOUT="" STUB_STDERR="$QUOTA_ERR" run_review "$s2_out" "$s2_err" || rc2=$?
assert_eq "$rc2" "5" "empty response on a zero exit yields EXIT_CLI_FAILED (5)"
assert_file_absent "$s2_out" "empty response writes no --output artifact"
assert_file_exists "$s2_out.failed.json" "empty response preserves <output>.failed.json"
assert_file_contains "$s2_out.failed.json" "empty response" "sidecar records the empty-response reason"
assert_file_contains "$s2_out.failed.json" "hit your usage limit" "empty-response sidecar still captures the stderr cause"
assert_file_contains "$s2_err" "hit your usage limit" "empty-response stderr surfaces the cause"

# --- Scenario 3: timeout is a CLI failure too --------------------------------
echo "=== scenario 3: timeout exits 5 with .failed.json ==="
s3_out="$TMP_ROOT/out/review3.json"
s3_err="$TMP_ROOT/s3.stderr"
rc3=0
printf '0' > "$COUNTER"
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$STUB" \
  SECOND_OPINION_TIMEOUT=1 \
  STUB_COUNTER="$COUNTER" \
  STUB_SLEEP=3 \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$s3_out" \
    >/dev/null 2>"$s3_err"
rc3=$?
set -e
assert_eq "$rc3" "5" "timeout yields EXIT_CLI_FAILED (5)"
assert_file_absent "$s3_out" "timeout writes no --output artifact"
assert_file_exists "$s3_out.failed.json" "timeout preserves <output>.failed.json"
assert_file_contains "$s3_out.failed.json" "timed out after 1s" "sidecar records the timeout reason"

# --- Scenario 4: success path is untouched -----------------------------------
echo "=== scenario 4: a valid response still writes the artifact, no sidecar ==="
GOOD_JSON='{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Clean","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
s4_out="$TMP_ROOT/out/review4.json"
s4_err="$TMP_ROOT/s4.stderr"
rc4=0
STUB_RC=0 STUB_STDOUT="$GOOD_JSON" run_review "$s4_out" "$s4_err" || rc4=$?
assert_eq "$rc4" "0" "success path still exits 0"
assert_file_exists "$s4_out" "success path writes the --output artifact"
assert_file_absent "$s4_out.failed.json" "success path writes no .failed.json sidecar"

# --- Scenario 5: challenge/quick are NOT in the no-verdict class -------------
# A CLI failure in a non-review mode keeps the generic exit 1 and writes no
# .failed.json — the exits-3/4/5 contract is review/audit-only.
echo "=== scenario 5: quick-mode CLI failure keeps generic exit 1, no .failed.json ==="
s5_out="$TMP_ROOT/out/quick5.txt"
s5_err="$TMP_ROOT/s5.stderr"
rc5=0
printf '0' > "$COUNTER"
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$STUB" \
  STUB_COUNTER="$COUNTER" \
  STUB_RC=1 STUB_STDERR="$QUOTA_ERR" \
  "$SECOND_OPINION" quick "is this safe?" --cwd "$WORK" --output "$s5_out" \
    >/dev/null 2>"$s5_err"
rc5=$?
set -e
assert_eq "$rc5" "1" "quick-mode CLI failure keeps the generic exit 1"
assert_file_absent "$s5_out.failed.json" "quick mode writes no .failed.json (review/audit-only contract)"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
