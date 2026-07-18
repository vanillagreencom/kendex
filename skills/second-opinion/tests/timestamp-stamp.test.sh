#!/usr/bin/env bash
# Regression test for second-opinion artifact timestamp stamping (vstack#629).
#
# The review artifact's `timestamp` field was serialized by the reviewing model,
# so a stale or fabricated value could survive into the written JSON — and orch's
# --file acceptance did not re-derive freshness. The fix: after the model
# responds and before writing the artifact, the wrapper overwrites `timestamp`
# with its own `date -u` UTC wall clock so the content timestamp is trustworthy
# and consistent with the file's mtime.
#
# Drives the real script with a fake target CLI that emits a review JSON carrying
# a deliberately BOGUS timestamp, then asserts the written artifact's timestamp
# was overwritten to ~now while the rest of the findings are preserved.

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

assert_ne() {
  local got="$1" unwanted="$2" name="$3"
  if [[ "$got" != "$unwanted" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected NOT: %s\n        got:          %s\n' "$unwanted" "$got" >&2
  fi
}

# BOGUS_TS is the stale/fabricated timestamp the model emits. It must never
# survive into the written artifact.
BOGUS_TS="2020-01-01T00:00:00Z"

# --- Fake target CLI ----------------------------------------------------------
# Consumes the prompt on stdin and emits a valid review JSON whose `timestamp`
# is the bogus value. Named `claude` so `command -v claude` passes; the actual
# command run is this stub via SECOND_OPINION_CLAUDE_CMD.
mkdir -p "$TMP_ROOT/bin"
STUB="$TMP_ROOT/bin/claude"
cat > "$STUB" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null   # consume the prompt on stdin
cat <<'JSON'
{"agent":"external-claude","timestamp":"$BOGUS_TS","verdict":"action_required","summary":"One blocker found","blockers":[{"id":1,"title":"Null deref in parser","location":"src/parse.rs (\`parse\`)","description":"pointer may be null","recommendation":"guard it","priority":1,"estimate":2}],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON
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

mkdir -p "$TMP_ROOT/out"
OUT="$TMP_ROOT/out/review.json"

echo "=== artifact timestamp is wrapper-stamped, not model-supplied ==="

before=$(date -u +%s)
rc=0
set +e
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=claude \
  SECOND_OPINION_CLAUDE_CMD="$STUB" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$OUT" \
  >/dev/null 2>"$TMP_ROOT/stderr"
rc=$?
set -e
after=$(date -u +%s)

assert_eq "$rc" "0" "review exits 0"

if [[ ! -f "$OUT" ]]; then
  fail "artifact was written"
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  exit 1
fi
pass "artifact was written"

written_ts="$(jq -r '.timestamp' "$OUT")"

# The bogus model-supplied value must have been overwritten.
assert_ne "$written_ts" "$BOGUS_TS" "written timestamp is NOT the model-supplied bogus value"

# The written value must be the wrapper's own wall clock: parse it to epoch and
# confirm it falls within the [before, after] window of the run.
written_epoch="$(date -u -d "$written_ts" +%s 2>/dev/null || echo "")"
if [[ -z "$written_epoch" ]]; then
  fail "written timestamp parses as an ISO-8601 UTC time (got '$written_ts')"
elif (( written_epoch >= before && written_epoch <= after )); then
  pass "written timestamp is the wrapper's own ~now stamp"
else
  fail "written timestamp is the wrapper's own ~now stamp"
  printf '        window: [%s, %s]  got: %s (%s)\n' "$before" "$after" "$written_epoch" "$written_ts" >&2
fi

# The rest of the model's findings must be preserved unchanged.
assert_eq "$(jq -r '.verdict' "$OUT")" "action_required" "verdict is preserved"
assert_eq "$(jq -r '.summary' "$OUT")" "One blocker found" "summary is preserved"
assert_eq "$(jq -r '.blockers[0].title' "$OUT")" "Null deref in parser" "blocker findings are preserved"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
