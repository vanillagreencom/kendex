#!/usr/bin/env bash
# Regression test for second-opinion review scope gating (vstack#652).
#
# A review invoked with no usable diff scope could still produce a schema-valid
# `verdict: "pass"` artifact while the external model admitted it reviewed
# nothing (qa_metadata.review_performed=false, reason no_scope_provided). The
# fix is two-sided in this script:
#   1. Scope is derived from the worktree BEFORE invoking the CLI (branch,
#      diff range, diffstat, changed-file list embedded in the prompt); an
#      empty or invalid diff fails with distinct exit 3 and never calls the CLI.
#   2. A response whose qa_metadata self-reports no review is never written to
#      --output: it is preserved as <output>.noreview.json and exits 4.
#
# Drives the real script with a fake target CLI (no network). The stub captures
# the prompt it receives on stdin so scope passthrough can be asserted.

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
# Captures the prompt it receives on stdin (for scope-passthrough assertions),
# increments an on-disk counter, and emits the canned response. Named `claude`
# and placed on PATH so the script's `command -v claude` validation passes.
mkdir -p "$TMP_ROOT/bin"
STUB="$TMP_ROOT/bin/claude"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > "$STUB_PROMPT_FILE"   # capture the prompt for assertions
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0)
[[ -n "$n" ]] || n=0
n=$((n + 1))
printf '%s' "$n" > "$STUB_COUNTER"
cat "$STUB_RESP_FILE"
SH
chmod +x "$STUB"

# --- Throwaway git repos for --cwd --------------------------------------------
# CLEAN: committed state only, so `--range HEAD` yields an empty diff.
# DIRTY: same plus an uncommitted change, so `--range HEAD` has real scope.
make_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  printf 'hello\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" -c commit.gpgsign=false commit -q -m init
  git -C "$dir" checkout -q -b scope-branch
}
CLEAN="$TMP_ROOT/clean"
DIRTY="$TMP_ROOT/dirty"
make_repo "$CLEAN"
make_repo "$DIRTY"
printf 'world\n' >> "$DIRTY/file.txt"

COUNTER="$TMP_ROOT/counter"
PROMPT_CAPTURE="$TMP_ROOT/captured-prompt.txt"
mkdir -p "$TMP_ROOT/out"

# run_review <cwd> <resp_file> <output_path> <stderr_file> -> exit code
run_review() {
  printf '0' > "$COUNTER"   # reset invocation counter before each run
  : > "$PROMPT_CAPTURE"
  local rc=0
  set +e
  PATH="$TMP_ROOT/bin:$PATH" \
    SECOND_OPINION_TARGET=claude \
    SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_COUNTER="$COUNTER" \
    STUB_PROMPT_FILE="$PROMPT_CAPTURE" \
    STUB_RESP_FILE="$2" \
    "$SECOND_OPINION" review --range HEAD --cwd "$1" --output "$3" \
      >/dev/null 2>"$4"
  rc=$?
  set -e
  return "$rc"
}

REVIEWED_RESP="$TMP_ROOT/reviewed-resp.txt"
cat > "$REVIEWED_RESP" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Clean, no issues found","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON

# --- Scenario 1: empty scope fails loudly without invoking the CLI ------------
echo "=== scenario 1: empty diff scope exits 3, CLI never invoked ==="
s1_out="$TMP_ROOT/out/review1.json"
s1_err="$TMP_ROOT/s1.stderr"
rc1=0
run_review "$CLEAN" "$REVIEWED_RESP" "$s1_out" "$s1_err" || rc1=$?
assert_eq "$rc1" "3" "empty scope exits with distinct code 3"
assert_file_absent "$s1_out" "empty scope writes no artifact"
assert_eq "$(cat "$COUNTER")" "0" "empty scope never invokes the external CLI"
assert_file_contains "$s1_err" "nothing to review" "empty scope error names the condition"

# --- Scenario 2: derived scope is passed through in the prompt ----------------
echo "=== scenario 2: scoped worktree embeds derived scope in the prompt ==="
s2_out="$TMP_ROOT/out/review2.json"
s2_err="$TMP_ROOT/s2.stderr"
rc2=0
run_review "$DIRTY" "$REVIEWED_RESP" "$s2_out" "$s2_err" || rc2=$?
assert_eq "$rc2" "0" "scoped review exits 0"
assert_file_exists "$s2_out" "scoped review writes the --output artifact"
assert_file_contains "$PROMPT_CAPTURE" "Branch: scope-branch" "prompt carries the derived branch"
assert_file_contains "$PROMPT_CAPTURE" "Diff range: HEAD" "prompt carries the diff range"
assert_file_contains "$PROMPT_CAPTURE" "file.txt" "prompt carries the changed-file list"
assert_file_contains "$PROMPT_CAPTURE" "git diff HEAD" "prompt still gives the diff command to run"

# --- Scenario 3: self-reported no-review is never written as the artifact -----
echo "=== scenario 3: qa_metadata.review_performed=false exits 4, no artifact ==="
s3_resp="$TMP_ROOT/noreview-resp.txt"
cat > "$s3_resp" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"No review was actually performed — there is no diff, PR, or file set in scope","blockers":[],"suggestions":[],"questions":["Which diff, branch, or PR should be reviewed?"],"qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}
JSON
s3_out="$TMP_ROOT/out/review3.json"
s3_err="$TMP_ROOT/s3.stderr"
rc3=0
run_review "$DIRTY" "$s3_resp" "$s3_out" "$s3_err" || rc3=$?
assert_eq "$rc3" "4" "no-review response exits with distinct code 4"
assert_file_absent "$s3_out" "no-review response writes no --output artifact"
assert_file_exists "$s3_out.noreview.json" "no-review response is preserved as <output>.noreview.json"
assert_file_contains "$s3_out.noreview.json" "no_scope_provided" "sidecar preserves the model's self-report"
assert_file_contains "$s3_err" "no review was performed" "error JSON names the no-review condition"
assert_file_contains "$s3_err" "no_scope_provided" "error JSON carries the model's reason"

# --- Scenario 4: review_performed=true passes the gate ------------------------
echo "=== scenario 4: explicit review_performed=true still writes the artifact ==="
s4_resp="$TMP_ROOT/performed-resp.txt"
cat > "$s4_resp" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Reviewed the diff, no issues","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{"review_performed":true}}
JSON
s4_out="$TMP_ROOT/out/review4.json"
s4_err="$TMP_ROOT/s4.stderr"
rc4=0
run_review "$DIRTY" "$s4_resp" "$s4_out" "$s4_err" || rc4=$?
assert_eq "$rc4" "0" "review_performed=true exits 0"
assert_file_exists "$s4_out" "review_performed=true writes the --output artifact"
assert_file_contains "$s4_out" "Reviewed the diff, no issues" "artifact contains the findings"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
