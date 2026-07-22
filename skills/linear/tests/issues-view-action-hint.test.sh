#!/usr/bin/env bash
# Regression tests for the unsupported `view` action hint (vstack#687).
#
# A focused Linear issue audit's read-only post-mutation verification produced
# `linear.sh issues view` — an action the issues namespace does not have; the
# supported lookups are `issues get`, `issues bulk-get`, and `cache issues
# get` — but the generic unknown-action error gave no pointer to them. The
# issues dispatcher now catches `view` (and the `show` near-miss) with a
# targeted error naming the supported lookups, and the cache issues namespace
# does the same, so an agent that receives stale guidance self-corrects in one
# step. These tests assert those hints, that other unknown actions keep the
# generic error, and that real commands still route.
# Hermetic: curl is stubbed on PATH to fail loudly — no network.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
LINEAR_SH="$TMP_ROOT/.agents/skills/linear/scripts/linear.sh"

# The dispatcher must reject unsupported actions before any API call.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
echo "curl must not be called by dispatcher-hint tests" >&2
exit 1
SH
chmod +x "$TMP_ROOT/bin/curl"

# Minimal cache so cache-query.sh reaches its action dispatch.
mkdir -p "$TMP_ROOT/.cache/linear"
printf '{"synced_at": "2026-01-01T00:00:00Z"}\n' >"$TMP_ROOT/.cache/linear/meta.json"

PASS=0
FAIL=0
ERR_FILE="$TMP_ROOT/stderr"

# Captures stdout in $out, stderr in $err, exit code in $rc.
run_linear() {
  set +e
  out=$(cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$LINEAR_SH" ${ARGS[@]+"${ARGS[@]}"} 2>"$ERR_FILE")
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

assert_not_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected NOT to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

echo "=== linear.sh unsupported view action hint (vstack#687) ==="

# --- Unsupported `view` action gets a targeted hint ---------------------------
ARGS=(issues view PROJ-42 --format=safe)
run_linear
assert_eq "$rc" "1" "issues view exits nonzero"
assert_eq "$out" "" "issues view emits no stdout result"
assert_contains "$err" "Unknown action 'view'" "issues view names the unknown action"
assert_contains "$err" "linear.sh issues bulk-get" "issues view hint names bulk-get"
assert_contains "$err" "linear.sh cache issues get" "issues view hint names the cache lookup"

ARGS=(issues show PROJ-42)
run_linear
assert_eq "$rc" "1" "issues show near-miss exits nonzero"
assert_contains "$err" "linear.sh issues bulk-get" "issues show hint names bulk-get"

# Singular resource normalizes to `issues` and still reaches the hint.
ARGS=(issue view PROJ-42)
run_linear
assert_eq "$rc" "1" "issue view (singular) exits nonzero"
assert_contains "$err" "linear.sh issues bulk-get" "issue view (singular) hint names bulk-get"

# --- Other unknown actions keep the generic error + usage pointer -------------
ARGS=(issues frobnicate PROJ-42)
run_linear
assert_eq "$rc" "1" "unknown action exits nonzero"
assert_contains "$err" "Unknown action 'frobnicate'" "unknown action reports generic error"
assert_contains "$err" "Run 'issues.sh --help' for usage." "unknown action points at usage"
assert_not_contains "$err" "bulk-get" "unknown action gets no view hint"

# --- Cache issues namespace gets the same targeted hint -----------------------
ARGS=(cache issues view PROJ-42)
run_linear
assert_eq "$rc" "1" "cache issues view exits nonzero"
assert_contains "$err" "Unknown issues action: view" "cache issues view names the unknown action"
assert_contains "$err" "cache issues get" "cache issues view hint names the cache lookup"

ARGS=(cache issues frobnicate PROJ-42)
run_linear
assert_eq "$rc" "1" "unknown cache action exits nonzero"
assert_contains "$err" "Unknown issues action: frobnicate" "unknown cache action reports generic error"
assert_not_contains "$err" "bulk-get" "unknown cache action gets no view hint"

# --- Real commands still route ------------------------------------------------
ARGS=(issues bulk-get --help)
run_linear
assert_eq "$rc" "0" "issues bulk-get --help routes and exits 0"
assert_contains "$out" "Issue Operations" "issues bulk-get --help prints issues usage"

ARGS=(cache issues get --help)
run_linear
assert_eq "$rc" "0" "cache issues get --help routes and exits 0"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
