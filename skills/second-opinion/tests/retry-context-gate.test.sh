#!/usr/bin/env bash
# Regression test for second-opinion retry context + qa_metadata gate (vstack#672).
#
# The JSON-extraction retry ran in a fresh session but resent only the raw
# first response plus the schema — NOT the original request. With the scope
# block lost, the retry model had nothing to review and could produce a
# schema-valid context-free "pass" that became a false-green artifact. Two-part
# fix in the script:
#   1. build_retry_prompt embeds the FULL original request (scope block
#      included), so the retry reviews the same scope as the first call.
#   2. Every response path — first or retried — passes the no-review gate, and
#      a response with no qa_metadata object at all is rejected as
#      non-conforming (the schema requires qa_metadata, {} for a performed
#      review): preserved as <output>.noreview.json, exit 4, no artifact.
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

GARBAGE_RESP="$TMP_ROOT/garbage-resp.txt"
printf 'My review is complete; the final JSON verdict was already delivered above.\n' > "$GARBAGE_RESP"

# --- Scenario 1: retried no-review response is rejected, not written ----------
echo "=== scenario 1: garbage first + no-review retry exits 4, no artifact ==="
s1_r2="$TMP_ROOT/s1-resp2.txt"
cat > "$s1_r2" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"No review was actually performed — there is no diff, PR, or file set in context","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{"review_performed":false,"reason":"no_scope_provided"}}
JSON
s1_out="$TMP_ROOT/out/review1.json"
s1_err="$TMP_ROOT/s1.stderr"
rc1=0
run_review "$GARBAGE_RESP" "$s1_r2" "$s1_out" "$s1_err" || rc1=$?
assert_eq "$rc1" "4" "retried no-review exits with distinct code 4"
assert_file_absent "$s1_out" "retried no-review writes no --output artifact"
assert_file_exists "$s1_out.noreview.json" "retried no-review is preserved as <output>.noreview.json"
assert_file_contains "$s1_err" "no review was performed" "error JSON names the no-review condition"
assert_eq "$(cat "$COUNTER")" "2" "scenario 1 invoked the CLI twice (retry ran)"

# --- Scenario 2: retry prompt carries the full original request ---------------
echo "=== scenario 2: garbage first + performed retry succeeds with scope resent ==="
s2_r2="$TMP_ROOT/s2-resp2.txt"
cat > "$s2_r2" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"action_required","summary":"One blocker found","blockers":[{"id":1,"title":"Null deref in parser","location":"src/parse.rs (`parse`)","description":"pointer may be null","recommendation":"guard it","priority":1,"estimate":2}],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON
s2_out="$TMP_ROOT/out/review2.json"
s2_err="$TMP_ROOT/s2.stderr"
rc2=0
run_review "$GARBAGE_RESP" "$s2_r2" "$s2_out" "$s2_err" || rc2=$?
assert_eq "$rc2" "0" "scenario 2 exits 0 after retry"
assert_file_exists "$s2_out" "scenario 2 writes the --output artifact"
assert_file_contains "$s2_out" "Null deref in parser" "artifact contains the retry's findings"
assert_eq "$(cat "$COUNTER")" "2" "scenario 2 invoked the CLI twice (retry ran)"
s2_retry_prompt="$PROMPT_DIR/prompt-2.txt"
assert_file_contains "$s2_retry_prompt" "Branch: scope-branch" "retry prompt carries the derived branch"
assert_file_contains "$s2_retry_prompt" "Diff range: HEAD" "retry prompt carries the diff range"
assert_file_contains "$s2_retry_prompt" "file.txt" "retry prompt carries the changed-file list"
assert_file_contains "$s2_retry_prompt" "git diff HEAD" "retry prompt still gives the diff command to run"
assert_file_contains "$s2_retry_prompt" "already delivered above" "retry prompt embeds the captured first response"

# --- Scenario 3: first response missing qa_metadata is non-conforming ---------
echo "=== scenario 3: first response with no qa_metadata exits 4, no artifact ==="
s3_r1="$TMP_ROOT/s3-resp1.txt"
cat > "$s3_r1" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Clean, no issues found","blockers":[],"suggestions":[],"questions":[]}
JSON
s3_out="$TMP_ROOT/out/review3.json"
s3_err="$TMP_ROOT/s3.stderr"
rc3=0
run_review "$s3_r1" "$GARBAGE_RESP" "$s3_out" "$s3_err" || rc3=$?
assert_eq "$rc3" "4" "missing qa_metadata exits with distinct code 4"
assert_file_absent "$s3_out" "missing qa_metadata writes no --output artifact"
assert_file_exists "$s3_out.noreview.json" "missing qa_metadata is preserved as <output>.noreview.json"
assert_file_contains "$s3_err" "missing_qa_metadata" "error JSON names the non-conforming reason"
assert_eq "$(cat "$COUNTER")" "1" "scenario 3 invoked the CLI once (valid JSON, no retry)"

# --- Scenario 4: retried response missing qa_metadata is rejected too ---------
echo "=== scenario 4: garbage first + qa_metadata-less retry exits 4 ==="
s4_r2="$TMP_ROOT/s4-resp2.txt"
cat > "$s4_r2" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-18T00:00:00Z","verdict":"pass","summary":"Nothing to evaluate in this session","blockers":[],"suggestions":[],"questions":[]}
JSON
s4_out="$TMP_ROOT/out/review4.json"
s4_err="$TMP_ROOT/s4.stderr"
rc4=0
run_review "$GARBAGE_RESP" "$s4_r2" "$s4_out" "$s4_err" || rc4=$?
assert_eq "$rc4" "4" "retried qa_metadata-less response exits with distinct code 4"
assert_file_absent "$s4_out" "retried qa_metadata-less response writes no --output artifact"
assert_file_exists "$s4_out.noreview.json" "retried qa_metadata-less response is preserved as sidecar"
assert_file_contains "$s4_err" "missing_qa_metadata" "error JSON names the non-conforming reason"
assert_eq "$(cat "$COUNTER")" "2" "scenario 4 invoked the CLI twice (retry ran)"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
