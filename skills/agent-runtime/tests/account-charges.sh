#!/usr/bin/env bash
# agent-runtime's account pick in a project that holds orch counts the lanes
# orch counts: the pick runs the project's `orch-runtime lane charges` once
# and judges with that count, so `agent-runtime accounts pick --record F`
# charges an account's live lane exactly as `orch-runtime lane pick --file F`
# does, and a lane whose process is gone charges neither. Both entries are
# the shipped wrappers over the built runtimes (the two-package set-up form:
# AGENT_RUNTIME_CACHE holds both); the usage endpoint is the runtime's `curl`
# fixture, and the lane's process a `sleep` this suite owns.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
# shellcheck source=../../orch/tests/lib/git-env.sh
source "$REPO_ROOT/skills/orch/tests/lib/git-env.sh"
unset ORCH_LANE_HOST ORCH_STATE_DIR

TMP_ROOT="$(mktemp -d)" || { echo "account-charges: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "account-charges: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "account-charges: scratch=resolve-failed" >&2; exit 1; }
LANE_PID=""
cleanup() {
  [[ -z "$LANE_PID" ]] || kill "$LANE_PID" 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
# shellcheck source=../../orch/tests/lib/assertions.sh
source "$REPO_ROOT/skills/orch/tests/lib/assertions.sh"

# The project: a checkout whose install holds both packages, linked where an
# apply puts them.
PROJECT="$TMP_ROOT/project"
mkdir -p "$PROJECT/.agents/skills"
git -C "$PROJECT" init -q
git -C "$PROJECT" config gc.auto 0
git -C "$PROJECT" config maintenance.auto false
for package in orch agent-runtime; do
  ln -s "$REPO_ROOT/skills/$package" "$PROJECT/.agents/skills/$package"
done
AGENT_RUNTIME="$PROJECT/.agents/skills/agent-runtime/scripts/agent-runtime"
ORCH_RUNTIME="$PROJECT/.agents/skills/orch/scripts/orch-runtime"

# One Claude account with a fresh credential, its week at 40 percent.
HOME_DIR="$TMP_ROOT/home"
ACCOUNT="$HOME_DIR/.aclaude"
USAGE="$TMP_ROOT/usage"
BIN="$TMP_ROOT/bin"
mkdir -p "$ACCOUNT" "$USAGE" "$BIN" "$TMP_ROOT/state"
ln -s "$REPO_ROOT/skills/agent-runtime/tests/rust/fixtures/usage-curl/curl" "$BIN/curl"
jq -cn --argjson expires "$((($(date +%s) + 3600) * 1000))" \
  '{claudeAiOauth: {accessToken: "token-aclaude", refreshToken: "refresh", expiresAt: $expires, subscriptionType: "max"}}' \
  > "$ACCOUNT/.credentials.json"
jq -n '{seven_day: {utilization: 40, resets_at: "2099-08-01T06:00:00Z"}}' > "$USAGE/token-aclaude.usage.json"
ENV=(env HOME="$HOME_DIR" PATH="$BIN:$PATH" AGENT_RUNTIME_ACCOUNT_DIRS="$ACCOUNT" USAGE_FIXTURE_DIR="$USAGE"
  AGENT_RUNTIME_ACCOUNT_STATE_DIR="$TMP_ROOT/state" AGENT_RUNTIME_USAGE_TTL=0 AGENT_RUNTIME_USAGE_MAX_AGE=0)

# The fleet record F: one running lane on the account, its launch identity
# the suite's own `sleep`, recorded in the `ps -o lstart` form every host
# reads, in the locale and zone the runtime's reader asks `ps` for.
FLEET="$TMP_ROOT/fleet.json"
sleep 300 &
LANE_PID=$!
START="$(LC_ALL=C TZ=UTC ps -o lstart= -p "$LANE_PID" | tr -s ' ' | sed 's/^ //; s/ $//')"
jq -n --arg account "$ACCOUNT" --argjson pid "$LANE_PID" --arg start "$START" '{
  issue_id: "oversee", triaged: [], launch_queue: [], fleet_log: [],
  lanes: [{item: "KEN-1", window: "orch-KEN-1", harness: "claude", status: "running",
    account: $account, launched_at: "2026-01-01T00:00:00Z", running_at: "2026-01-01T00:00:00Z",
    launch: {pid: $pid, start: $start, pane: "%1", server: 1}}]}' > "$FLEET"

# claims ENTRY: the named account's charged lanes as the entry's pick reads
# them, `rc=N` where it answered no record.
claims() {
  local out rc=0
  case "$1" in
    agent-runtime)
      out="$(cd "$PROJECT" && "${ENV[@]}" "$AGENT_RUNTIME" accounts pick --harness claude \
        --account "$ACCOUNT" --record "$FLEET" 2>"$TMP_ROOT/err")" || rc=$? ;;
    orch-runtime)
      out="$(cd "$PROJECT" && "${ENV[@]}" "$ORCH_RUNTIME" lane pick --file "$FLEET" --harness claude \
        --lane "$ACCOUNT" 2>"$TMP_ROOT/err")" || rc=$? ;;
  esac
  [[ "$rc" -eq 0 ]] || { printf 'rc=%s %s' "$rc" "$(head -c 300 "$TMP_ROOT/err")"; return 0; }
  jq -r '.result.record.claims' <<<"$out"
}

echo "=== a live lane is charged by both entries ==="
assert_eq "agent-runtime=$(claims agent-runtime) orch-runtime=$(claims orch-runtime)" \
  "agent-runtime=1 orch-runtime=1" \
  "the shared pick charges the live lane orch's own pick charges" "$TMP_ROOT/err"

echo "=== a lane whose process is gone is charged by neither ==="
kill "$LANE_PID"
wait "$LANE_PID" 2>/dev/null || true
LANE_PID=""
assert_eq "agent-runtime=$(claims agent-runtime) orch-runtime=$(claims orch-runtime)" \
  "agent-runtime=0 orch-runtime=0" \
  "a gone lane is charged by neither entry" "$TMP_ROOT/err"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
