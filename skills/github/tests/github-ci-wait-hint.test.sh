#!/usr/bin/env bash
# Regression tests for the unsupported `ci-wait` command hint (vstack#662).
#
# During a managed orchestration handoff, generated guidance told an agent to
# run `github.sh ci-wait 296 --json`. The github router has no `ci-wait`
# command — CI waiting is the orch skill's script
# `.agents/skills/orch/scripts/ci-wait <PR_NUMBER> [interval] [max_wait]
# [--json]` — but the generic unknown-command error gave no pointer to it.
# The dispatcher now catches `ci-wait` (and the `ciwait`/`ci_wait`
# near-misses) with a targeted error naming the orch script so an agent that
# receives stale guidance self-corrects in one step. These tests assert that
# hint, that other unknown commands keep the generic error + usage pointer,
# that a real command still routes, and that the hinted orch script exists.
# Hermetic: gh is stubbed on PATH and token env vars are cleared — no network.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
GITHUB_SH="$REPO_ROOT/skills/github/scripts/github.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ERR_FILE="$TMP_ROOT/stderr"

# Sandbox git repo so github.sh's project-env autoload has a clean, empty root.
SANDBOX="$TMP_ROOT/project"
mkdir -p "$SANDBOX"
git -C "$SANDBOX" init -q

# Stub gh: answers the auth probes the router may make at startup and the one
# pr view call the routed real-command check needs. Everything else no-ops.
STUB_DIR="$TMP_ROOT/bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth)
    echo "Logged in"
    exit 0
    ;;
  api)
    if [[ "${2:-}" == "user" ]]; then
      echo "test-user"
      exit 0
    fi
    printf '[]\n'
    exit 0
    ;;
  pr)
    if [[ "${2:-}" == "view" ]]; then
      echo "abc-150-fix"
      exit 0
    fi
    ;;
esac
exit 0
EOF
chmod +x "$STUB_DIR/gh"

# Run github.sh from the sandbox with stubbed gh and no inherited tokens.
# Captures stdout in $out, stderr in $err, exit code in $rc.
run_github() {
  set +e
  out=$( (cd "$SANDBOX" && env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN \
    PATH="$STUB_DIR:$PATH" bash "$GITHUB_SH" ${ARGS[@]+"${ARGS[@]}"}) 2>"$ERR_FILE")
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

echo "=== github.sh unsupported ci-wait command hint (vstack#662) ==="

# --- Unsupported `ci-wait` command gets a targeted hint -----------------------
ARGS=(ci-wait 296 --json)
run_github
assert_eq "$rc" "1" "ci-wait exits nonzero"
assert_eq "$out" "" "ci-wait emits no stdout result"
assert_contains "$err" "Unknown command 'ci-wait'" "ci-wait names the unknown command"
assert_contains "$err" ".agents/skills/orch/scripts/ci-wait" "ci-wait hint names the orch script"

ARGS=(ciwait 296)
run_github
assert_eq "$rc" "1" "ciwait near-miss exits nonzero"
assert_contains "$err" ".agents/skills/orch/scripts/ci-wait" "ciwait hint names the orch script"

ARGS=(ci_wait 296)
run_github
assert_eq "$rc" "1" "ci_wait near-miss exits nonzero"
assert_contains "$err" ".agents/skills/orch/scripts/ci-wait" "ci_wait hint names the orch script"

# --- Other unknown commands keep the generic error + usage pointer ------------
ARGS=(bogus 296)
run_github
assert_eq "$rc" "1" "unknown command exits nonzero"
assert_contains "$err" "Unknown command 'bogus'" "unknown command reports generic error"
assert_contains "$err" "Run './github.sh --help' for usage." "unknown command points at usage"
assert_not_contains "$err" ".agents/skills/orch/scripts/ci-wait" "unknown command gets no ci-wait hint"

# --- A real command still routes ----------------------------------------------
ARGS=(pr-issue 42 --format=text)
run_github
assert_eq "$rc" "0" "pr-issue routes and exits 0"
assert_contains "$out" "ABC-150" "pr-issue extracts the issue from the stubbed branch"

# --- The hinted orch script exists where the hint points ----------------------
if [[ -x "$REPO_ROOT/skills/orch/scripts/ci-wait" ]]; then
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "hinted orch ci-wait script exists and is executable"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "hinted orch ci-wait script missing at skills/orch/scripts/ci-wait"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
