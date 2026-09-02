#!/usr/bin/env bash
# Regression tests for the unsupported `view` action hint (kendex#687).
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
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# This root's own cache is the subject, so it replaces the assert lib's default
# sandbox — still scratch, so the exit verdict's containment check holds.
export LINEAR_CACHE_ROOT="$TMP_ROOT"
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

ERR_FILE="$TMP_ROOT/stderr"

# Captures stdout in $out, stderr in $err, exit code in $rc.
run_linear() {
  rc=0
  out=$(cd "$TMP_ROOT" && PATH="$TMP_ROOT/bin:$PATH" LINEAR_API_KEY=test-token \
    bash "$LINEAR_SH" ${ARGS[@]+"${ARGS[@]}"} 2>"$ERR_FILE") || rc=$?
  err="$(cat "$ERR_FILE")"
}

echo "=== linear.sh unsupported view action hint (kendex#687) ==="

# --- Unsupported `view` action gets a targeted hint ---------------------------
ARGS=(issues view PROJ-42 --format=safe)
run_linear
assert_eq "issues view exits nonzero" "$rc" "1"
assert_eq "issues view emits no stdout result" "$out" ""
assert_contains "issues view names the unknown action" "$err" "Unknown action 'view'"
assert_contains "issues view hint names bulk-get" "$err" "linear.sh issues bulk-get"
assert_contains "issues view hint names the cache lookup" "$err" "linear.sh cache issues get"
ARGS=(issues show PROJ-42)
run_linear
assert_eq "issues show near-miss exits nonzero" "$rc" "1"
assert_contains "issues show hint names bulk-get" "$err" "linear.sh issues bulk-get"
# Singular resource normalizes to `issues` and still reaches the hint.
ARGS=(issue view PROJ-42)
run_linear
assert_eq "issue view (singular) exits nonzero" "$rc" "1"
assert_contains "issue view (singular) hint names bulk-get" "$err" "linear.sh issues bulk-get"
# --- Other unknown actions keep the generic error + usage pointer -------------
ARGS=(issues frobnicate PROJ-42)
run_linear
assert_eq "unknown action exits nonzero" "$rc" "1"
assert_contains "unknown action reports generic error" "$err" "Unknown action 'frobnicate'"
assert_contains "unknown action points at usage" "$err" "Run 'issues.sh --help' for usage."
assert_not_contains "unknown action gets no view hint" "$err" "bulk-get"
# --- Cache issues namespace gets the same targeted hint -----------------------
ARGS=(cache issues view PROJ-42)
run_linear
assert_eq "cache issues view exits nonzero" "$rc" "1"
assert_contains "cache issues view names the unknown action" "$err" "Unknown issues action: view"
assert_contains "cache issues view hint names the cache lookup" "$err" "cache issues get"
ARGS=(cache issues frobnicate PROJ-42)
run_linear
assert_eq "unknown cache action exits nonzero" "$rc" "1"
assert_contains "unknown cache action reports generic error" "$err" "Unknown issues action: frobnicate"
assert_not_contains "unknown cache action gets no view hint" "$err" "bulk-get"
# --- Real commands still route ------------------------------------------------
ARGS=(issues bulk-get --help)
run_linear
assert_eq "issues bulk-get --help routes and exits 0" "$rc" "0"
assert_contains "issues bulk-get --help prints issues usage" "$out" "Issue Operations"
ARGS=(cache issues get --help)
run_linear
assert_eq "cache issues get --help routes and exits 0" "$rc" "0"
echo
