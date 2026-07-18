#!/usr/bin/env bash
# Regression test for the second-opinion structural-completeness gate (vstack#678).
#
# JSON extraction can yield truncated-but-valid JSON: agent/timestamp/verdict/
# summary survive while the required finding arrays are silently dropped, so the
# model's actual blockers/suggestions are lost and the written artifact looks
# reviewable. Fix in the script:
#   1. A parseable first response missing verdict or any of the blockers/
#      suggestions/questions arrays goes through the existing one-shot retry
#      (full original context, vstack#672) instead of being written.
#   2. A retried response that is STILL structurally incomplete is rejected:
#      preserved as <output>.incomplete.json, exit 4, no artifact.
#   3. A complete response with empty arrays is accepted unchanged, no retry.
#
# Drives the real script with a fake target CLI (no network). The stub captures
# the prompt of EACH call separately so retry-prompt contents can be asserted,
# and emits a different canned response on call 1 vs call 2.

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
# Captures each call's prompt to $STUB_PROMPT_DIR/prompt-<n>.txt (so the retry
# prompt can be asserted independently of the first), increments an on-disk
# counter, and emits the canned response for that call number. Named `claude`
# and placed on PATH so the script's `command -v claude` validation passes.
mkdir -p "$TMP_ROOT/bin"
STUB="$TMP_ROOT/bin/claude"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0)
[[ -n "$n" ]] || n=0
n=$((n + 1))
printf '%s' "$n" > "$STUB_COUNTER"
cat > "$STUB_PROMPT_DIR/prompt-$n.txt"   # capture this call's prompt
if [[ "$n" -eq 1 ]]; then
  cat "$STUB_RESP1_FILE"
else
  cat "$STUB_RESP2_FILE"
fi
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
# Uncommitted change so `--range HEAD` yields a non-empty diff — the scope
# gate (vstack#652) refuses to run a review over an empty diff.
printf 'world\n' >> "$WORK/file.txt"

COUNTER="$TMP_ROOT/counter"
PROMPT_DIR="$TMP_ROOT/prompts"
mkdir -p "$TMP_ROOT/out"

# run_review <resp1_file> <resp2_file> <output_path> <stderr_file> -> exit code
run_review() {
  printf '0' > "$COUNTER"   # reset invocation counter before each run
  rm -rf "$PROMPT_DIR"
  mkdir -p "$PROMPT_DIR"
  local rc=0
  set +e
  PATH="$TMP_ROOT/bin:$PATH" \
    SECOND_OPINION_TARGET=claude \
    SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_COUNTER="$COUNTER" \
    STUB_PROMPT_DIR="$PROMPT_DIR" \
    STUB_RESP1_FILE="$1" \
    STUB_RESP2_FILE="$2" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$3" \
      >/dev/null 2>"$4"
  rc=$?
  set -e
  return "$rc"
}

# The vstack#678 incident shape: parseable JSON carrying ONLY agent/timestamp/
# verdict/summary — the finding arrays (and qa_metadata) were truncated away.
TRUNCATED_RESP="$TMP_ROOT/truncated-resp.txt"
cat > "$TRUNCATED_RESP" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Reviewed the diff, one issue noted"}
JSON

COMPLETE_RESP="$TMP_ROOT/complete-resp.txt"
cat > "$COMPLETE_RESP" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"action_required","summary":"One blocker found","blockers":[{"id":1,"title":"Null deref in parser","location":"src/parse.rs (`parse`)","description":"pointer may be null","recommendation":"guard it","priority":1,"estimate":2}],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON

# --- Scenario 1: truncated first response is retried, retry recovers ----------
echo "=== scenario 1: truncated first response triggers retry, retry recovers ==="
s1_out="$TMP_ROOT/out/review1.json"
s1_err="$TMP_ROOT/s1.stderr"
rc1=0
run_review "$TRUNCATED_RESP" "$COMPLETE_RESP" "$s1_out" "$s1_err" || rc1=$?
assert_eq "$rc1" "0" "scenario 1 exits 0 after retry"
assert_file_exists "$s1_out" "scenario 1 writes the --output artifact"
assert_file_contains "$s1_out" "Null deref in parser" "artifact contains the retry's findings"
assert_eq "$(cat "$COUNTER")" "2" "scenario 1 invoked the CLI twice (retry ran)"
s1_retry_prompt="$PROMPT_DIR/prompt-2.txt"
assert_file_contains "$s1_retry_prompt" "missing required schema fields" "retry prompt names the incomplete-schema defect"
assert_file_contains "$s1_retry_prompt" "Branch: scope-branch" "retry prompt carries the derived branch (full original context)"
assert_file_contains "$s1_retry_prompt" "git diff HEAD" "retry prompt still gives the diff command to run"
assert_file_contains "$s1_retry_prompt" '"verdict":"pass","summary":"Reviewed the diff, one issue noted"' "retry prompt embeds the captured truncated response"

# --- Scenario 2: still-truncated retry is rejected, not written ---------------
echo "=== scenario 2: truncated first + truncated retry exits 4, no artifact ==="
s2_out="$TMP_ROOT/out/review2.json"
s2_err="$TMP_ROOT/s2.stderr"
rc2=0
run_review "$TRUNCATED_RESP" "$TRUNCATED_RESP" "$s2_out" "$s2_err" || rc2=$?
assert_eq "$rc2" "4" "still-incomplete retry exits with distinct code 4"
assert_file_absent "$s2_out" "still-incomplete retry writes no --output artifact"
assert_file_exists "$s2_out.incomplete.json" "still-incomplete retry is preserved as <output>.incomplete.json"
assert_file_contains "$s2_out.incomplete.json" "Reviewed the diff, one issue noted" "sidecar preserves the truncated response"
assert_file_contains "$s2_err" "incomplete_schema" "error JSON names the incomplete_schema reason"
assert_eq "$(cat "$COUNTER")" "2" "scenario 2 invoked the CLI twice (retry ran)"

# --- Scenario 3: complete response with empty arrays is accepted, no retry ----
echo "=== scenario 3: complete-with-empty-arrays first response accepted, no retry ==="
s3_r1="$TMP_ROOT/s3-resp1.txt"
cat > "$s3_r1" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Clean, no issues found","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON
s3_out="$TMP_ROOT/out/review3.json"
s3_err="$TMP_ROOT/s3.stderr"
rc3=0
run_review "$s3_r1" "$TRUNCATED_RESP" "$s3_out" "$s3_err" || rc3=$?
assert_eq "$rc3" "0" "scenario 3 exits 0"
assert_file_exists "$s3_out" "scenario 3 writes the --output artifact"
assert_eq "$(cat "$COUNTER")" "1" "scenario 3 invoked the CLI once (no retry)"
assert_file_absent "$s3_out.incomplete.json" "scenario 3 writes no incomplete sidecar"

# --- Scenario 4: mistyped array is incomplete too, retry recovers -------------
echo "=== scenario 4: non-array blockers triggers retry, retry recovers ==="
s4_r1="$TMP_ROOT/s4-resp1.txt"
cat > "$s4_r1" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"ok","blockers":"none","suggestions":[],"questions":[],"qa_metadata":{}}
JSON
s4_out="$TMP_ROOT/out/review4.json"
s4_err="$TMP_ROOT/s4.stderr"
rc4=0
run_review "$s4_r1" "$COMPLETE_RESP" "$s4_out" "$s4_err" || rc4=$?
assert_eq "$rc4" "0" "scenario 4 exits 0 after retry"
assert_file_contains "$s4_out" "Null deref in parser" "scenario 4 artifact contains the retry's findings"
assert_eq "$(cat "$COUNTER")" "2" "scenario 4 invoked the CLI twice (retry ran)"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
