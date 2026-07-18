#!/usr/bin/env bash
# Regression test for second-opinion review/audit JSON recovery (vstack#509).
#
# The one-shot reviewer (claude --no-session-persistence / codex --ephemeral)
# sometimes returns prose claiming the JSON verdict was "already delivered
# above" — but there is no prior turn, so extract_json failed and the review was
# lost. The fix: state the full-JSON contract in the prompt, retry ONCE with the
# captured response + schema on extraction failure, and preserve the raw
# response in a <output>.raw.txt sidecar when extraction still fails.
#
# Drives the real script with a fake target CLI (no network, no real claude /
# codex). The stub reads the prompt on stdin and emits a different canned
# response on call 1 vs call 2 via an on-disk invocation counter.

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
# Consumes the prompt on stdin, increments an on-disk counter, and emits the
# canned response for that call number. Named `claude` and placed on PATH so the
# script's `command -v claude` validation passes; the actual command run is this
# stub via SECOND_OPINION_CLAUDE_CMD.
mkdir -p "$TMP_ROOT/bin"
STUB="$TMP_ROOT/bin/claude"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null   # consume the prompt on stdin
n=$(cat "$STUB_COUNTER" 2>/dev/null || echo 0)
[[ -n "$n" ]] || n=0
n=$((n + 1))
printf '%s' "$n" > "$STUB_COUNTER"
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
# Uncommitted change so `--range HEAD` yields a non-empty diff — the scope
# gate (vstack#652) refuses to run a review over an empty diff.
printf 'world\n' >> "$WORK/file.txt"

COUNTER="$TMP_ROOT/counter"
mkdir -p "$TMP_ROOT/out"

# run_review <resp1_file> <resp2_file> <output_path> <stderr_file> -> exit code
run_review() {
  printf '0' > "$COUNTER"   # reset invocation counter before each run
  local rc=0
  set +e
  PATH="$TMP_ROOT/bin:$PATH" \
    SECOND_OPINION_TARGET=claude \
    SECOND_OPINION_CLAUDE_CMD="$STUB" \
    STUB_COUNTER="$COUNTER" \
    STUB_RESP1_FILE="$1" \
    STUB_RESP2_FILE="$2" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$3" \
      >/dev/null 2>"$4"
  rc=$?
  set -e
  return "$rc"
}

# --- Scenario 1: retry recovers findings -------------------------------------
echo "=== scenario 1: retry recovers findings ==="
s1_r1="$TMP_ROOT/s1-resp1.txt"
s1_r2="$TMP_ROOT/s1-resp2.txt"
printf 'My review is complete; the final JSON verdict was already delivered above.\n' > "$s1_r1"
cat > "$s1_r2" <<'JSON'
{"agent":"external-claude","timestamp":"2026-07-13T00:00:00Z","verdict":"action_required","summary":"One blocker found","blockers":[{"id":1,"title":"Null deref in parser","location":"src/parse.rs (`parse`)","description":"pointer may be null","recommendation":"guard it","priority":1,"estimate":2}],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON
s1_out="$TMP_ROOT/out/review1.json"
s1_err="$TMP_ROOT/s1.stderr"
rc1=0
run_review "$s1_r1" "$s1_r2" "$s1_out" "$s1_err" || rc1=$?
assert_eq "$rc1" "0" "scenario 1 exits 0 after retry"
assert_file_exists "$s1_out" "scenario 1 writes the --output artifact"
assert_file_contains "$s1_out" "Null deref in parser" "scenario 1 artifact contains the retry's findings"
assert_eq "$(cat "$COUNTER")" "2" "scenario 1 invoked the CLI twice (retry ran)"

# --- Scenario 2: clean first response, no retry ------------------------------
echo "=== scenario 2: clean first response, no retry ==="
s2_r1="$TMP_ROOT/s2-resp1.txt"
s2_r2="$TMP_ROOT/s2-resp2.txt"
cat > "$s2_r1" <<'FENCE'
Here is my review of the changes:

```json
{"agent":"external-claude","timestamp":"2026-07-13T00:00:00Z","verdict":"pass","summary":"Clean, no issues found","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
```
FENCE
printf 'unused second response\n' > "$s2_r2"
s2_out="$TMP_ROOT/out/review2.json"
s2_err="$TMP_ROOT/s2.stderr"
rc2=0
run_review "$s2_r1" "$s2_r2" "$s2_out" "$s2_err" || rc2=$?
assert_eq "$rc2" "0" "scenario 2 exits 0"
assert_file_exists "$s2_out" "scenario 2 writes the --output artifact"
assert_file_contains "$s2_out" "Clean, no issues found" "scenario 2 artifact contains the first response's findings"
assert_eq "$(cat "$COUNTER")" "1" "scenario 2 invoked the CLI once (no retry)"
assert_file_absent "$s2_out.raw.txt" "scenario 2 writes no raw sidecar"

# --- Scenario 3: total failure preserves raw ---------------------------------
echo "=== scenario 3: total failure preserves raw response ==="
s3_r1="$TMP_ROOT/s3-resp1.txt"
s3_r2="$TMP_ROOT/s3-resp2.txt"
printf 'I found a critical SQL injection in login(); the JSON verdict was already delivered above.\n' > "$s3_r1"
printf 'As I said, the review is done and the JSON was provided previously.\n' > "$s3_r2"
s3_out="$TMP_ROOT/out/review3.json"
s3_err="$TMP_ROOT/s3.stderr"
rc3=0
run_review "$s3_r1" "$s3_r2" "$s3_out" "$s3_err" || rc3=$?
if [[ "$rc3" -ne 0 ]]; then
  pass "scenario 3 exits nonzero"
else
  fail "scenario 3 exits nonzero (got $rc3)"
fi
assert_file_exists "$s3_out.raw.txt" "scenario 3 writes the <output>.raw.txt sidecar"
assert_file_contains "$s3_out.raw.txt" "critical SQL injection in login()" "scenario 3 sidecar preserves the raw findings"
assert_file_contains "$s3_err" "raw_response" "scenario 3 error JSON references the raw sidecar path"
assert_file_absent "$s3_out" "scenario 3 writes no JSON artifact on failure"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
