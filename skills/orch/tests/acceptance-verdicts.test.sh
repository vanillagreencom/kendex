#!/usr/bin/env bash
# dev-artifact-check --verdict field, review-artifact-check --path mode, and
# ci-wait's none-configured route: each acceptance answer must be a single
# deterministic word the orchestrator can act on without combining checks, and
# that route's result must name the repository it read like every other one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TEST_DIR/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"
VRUN="$(validate_run_dir "$TMP/validate-run" full)"

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# --- Fixture worktree with a real git repo so commit checks run ---
WT="$TMP/wt"
mkdir -p "$WT"
git -C "$WT" init -q -b main
git -C "$WT" -c user.email=t@t -c user.name=t commit -q --allow-empty -m seed
SHA="$(git -C "$WT" rev-parse HEAD)"
"$SCRIPTS/workflow-state" --state-dir "$WT/tmp" init T-1 --worktree "$WT" --branch main >/dev/null
export ORCH_STATE_DIR="$WT/tmp"

# --- dev-artifact-check verdicts ---
v() { "$SCRIPTS/dev-artifact-check" --worktree "$WT" --issue T-1 --round-id "$1" 2>/dev/null | jq -r '.verdict'; }

assert_eq "$(v r-none || true)" "wait" "no artifact for the round → wait"

"$SCRIPTS/dev-return-write" --worktree "$WT" --kind implement --issue T-1 --round-id r-good \
  --branch main --commit "$SHA" --validate pass --validate-run-dir "$VRUN" --no-summary --summary ok >/dev/null
assert_eq "$(v r-good)" "accept" "valid artifact → accept"

"$SCRIPTS/dev-return-write" --worktree "$WT" --kind implement --issue T-1 --round-id r-failing \
  --branch main --commit "$SHA" --validate "FAILING: cargo test" --no-summary --summary ok >/dev/null
assert_eq "$(v r-failing)" "retry" "validate FAILING → retry"

printf '{"round_id":"r-broken"}' > "$WT/tmp/dev-return-T-1-r-broken.json"
assert_eq "$(v r-broken || true)" "retry" "schema-invalid artifact → retry"

# --- review-artifact-check --path ---
p="$("$SCRIPTS/review-artifact-check" --path "$WT" reviewer-test)"
if [[ "$p" =~ ^"$WT"/tmp/review-reviewer-test-[0-9]{8}-[0-9]{6}\.json$ ]]; then
  pass "--path prints the canonical timestamped path"
else
  fail "--path prints the canonical timestamped path (got '$p')"
fi
[[ -d "$WT/tmp" ]] && pass "--path creates tmp/" || fail "--path creates tmp/"
if "$SCRIPTS/review-artifact-check" --path "$WT" 'evil/../name' >/dev/null 2>&1; then
  fail "--path rejects a path-unsafe agent name"
else
  pass "--path rejects a path-unsafe agent name"
fi
if "$SCRIPTS/review-artifact-check" --path "$TMP/nope" reviewer-test >/dev/null 2>&1; then
  fail "--path rejects a missing worktree"
else
  pass "--path rejects a missing worktree"
fi

# --- ci-wait none-configured route (gh fully stubbed) ---
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
log="${GH_STUB_LOG:-/dev/null}"
printf '%s\n' "$*" >> "$log"
case "$*" in
  "auth status"*) exit 0 ;;
  *"actions/workflows"*) if [[ "${GH_STUB_WORKFLOWS:-0}" == "0" ]]; then echo "0"; else echo "${GH_STUB_WORKFLOWS}"; fi; exit 0 ;;
  *"rules/branches"*) echo "0"; exit 0 ;;
  *"branches/main"*) echo "false"; exit 0 ;;
  *"repo view"*) echo "owner/repo"; exit 0 ;;
  *"pr view"*"baseRefName"*) echo "main"; exit 0 ;;
  *"pr view"*"headRefOid"*) echo "deadbeefcafe"; exit 0 ;;
  *"/status"*) echo "${GH_STUB_EXT_STATUSES:-0}"; exit 0 ;;
  *"pr view"*"mergeStateStatus"*) echo "CLEAN"; exit 0 ;;
  *"pr view"*) echo '{}'; exit 0 ;;
  *"pr checks"*) echo "[]"; exit 0 ;;
  api*) echo "[]"; exit 0 ;;
  *) echo "[]"; exit 0 ;;
esac
EOF
chmod +x "$BIN/gh"

out=$(cd "$WT" && PATH="$BIN:$PATH" env -u GH_REPO GH_STUB_LOG="$TMP/gh.log" \
  CI_WAIT_NO_CHECKS_GRACE=1 GH_TOKEN=stub "$SCRIPTS/ci-wait" 1 1 5 --json 2>/dev/null || true)
assert_eq "$(jq -r '.verdict // empty' <<<"$out")" "none" "no workflows + no protection + no rules → verdict none"
assert_eq "$(jq -r '.status // empty' <<<"$out")" "complete" "none-configured is status complete"
# This route builds its own result object rather than routing through
# emit_result, so the repository every other verdict names is asserted here
# too, on both the JSON object and the plain line.
assert_eq "$(jq -r '.repo // empty' <<<"$out")" "owner/repo" "none-configured names the repository it read"

text=$(cd "$WT" && PATH="$BIN:$PATH" env -u GH_REPO GH_STUB_LOG="$TMP/gh-text.log" \
  CI_WAIT_NO_CHECKS_GRACE=1 GH_TOKEN=stub "$SCRIPTS/ci-wait" 1 1 5 2>/dev/null || true)
assert_eq "${text%%$'\n'*}" \
  "ci-wait: none-configured base=main repo=owner/repo" "the plain none-configured line names its base and repository"

# Teeth: with active workflows present the shortcut must NOT fire — the run
# falls through to the grace path and, at grace 1s with no checks, errors out.
out2=$(cd "$WT" && PATH="$BIN:$PATH" env -u GH_REPO GH_STUB_WORKFLOWS=3 \
  CI_WAIT_NO_CHECKS_GRACE=1 GH_TOKEN=stub "$SCRIPTS/ci-wait" 1 1 5 --json 2>/dev/null || true)
v2="$(jq -r '.verdict // empty' <<<"$out2")"
if [[ "$v2" != "none" ]]; then
  pass "active workflows suppress the none-configured shortcut (teeth)"
else
  fail "active workflows suppress the none-configured shortcut (teeth)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
