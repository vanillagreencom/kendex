#!/usr/bin/env bash
# Regression tests for the unsupported `issue` action hint (vstack#641).
#
# During an orch dev-fix cycle, generated guidance told a specialist to run
# `decisions issue CC-125`. The CLI has no `issue` action — the supported
# lookup is `decisions search --issue CC-125` — but the generic unknown-action
# error gave no pointer to it. The dispatcher now catches `issue`/`issues`
# with a targeted error naming the supported form so an agent that receives
# stale guidance self-corrects in one step. These tests assert that hint, that
# other unknown actions keep the generic error + usage, and that the supported
# `search --issue` lookup still works.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DECISIONS="$SKILL_DIR/scripts/decisions"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ERR_FILE="$TMP_ROOT/stderr"

# Run the decisions script from a given directory with DECISIONS_DIR removed
# from the parent environment (pass VAR=value args to set it explicitly).
# Captures stdout in $out, stderr in $err, exit code in $rc.
run_decisions() {
  local dir="$1"
  shift
  set +e
  out=$( (cd "$dir" && env -u DECISIONS_DIR "$@" "$DECISIONS" ${ARGS[@]+"${ARGS[@]}"}) 2>"$ERR_FILE")
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
}

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
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

echo "=== decisions unsupported issue action hint (vstack#641) ==="

# Fixture: a project with one decision linked to CC-125, so the supported
# lookup has a real match to return.
PROJ="$TMP_ROOT/project"
mkdir -p "$PROJ/docs/decisions"
cat >"$PROJ/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-10 | D001 | CC-125 | Use Redis for session caching | Fast and simple | If latency degrades | Active | [Full](D001-session-caching.md) |
EOF

# --- Unsupported `issue` action gets a targeted hint --------------------------
ARGS=(issue CC-125)
run_decisions "$PROJ" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "1" "issue action exits nonzero"
assert_eq "$out" "" "issue action emits no stdout result"
assert_contains "$err" "Unknown action 'issue'" "issue action names the unknown action"
assert_contains "$err" "search --issue" "issue action hint names the supported lookup"

ARGS=(issues CC-125)
run_decisions "$PROJ" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "1" "issues action exits nonzero"
assert_contains "$err" "search --issue" "issues action hint names the supported lookup"

# --- Other unknown actions keep the generic error + usage ---------------------
ARGS=(bogus CC-125)
run_decisions "$PROJ" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "1" "unknown action exits nonzero"
assert_contains "$err" "Unknown action 'bogus'" "unknown action reports generic error"
assert_contains "$out" "Usage: decisions" "unknown action prints usage"

# --- Supported issue lookup still works ---------------------------------------
ARGS=(search --issue CC-125)
run_decisions "$PROJ" DECISIONS_DIR=docs/decisions
assert_eq "$rc" "0" "search --issue exits 0"
assert_contains "$out" '"D001"' "search --issue returns the linked decision"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
