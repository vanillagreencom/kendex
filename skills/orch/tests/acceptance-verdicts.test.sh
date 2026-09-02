#!/usr/bin/env bash
# dev-artifact-check --verdict field, review-artifact-check --path mode, and
# ci-wait's none-configured route: each acceptance answer must be a single
# deterministic word the orchestrator can act on without combining checks.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$TEST_DIR/../scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # check <desc> <expected> <actual>
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

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

check "no artifact for the round → wait" "wait" "$(v r-none || true)"

"$SCRIPTS/dev-return-write" --worktree "$WT" --kind implement --issue T-1 --round-id r-good \
  --branch main --commit "$SHA" --validate pass --no-summary --summary ok >/dev/null
check "valid artifact → accept" "accept" "$(v r-good)"

"$SCRIPTS/dev-return-write" --worktree "$WT" --kind implement --issue T-1 --round-id r-failing \
  --branch main --commit "$SHA" --validate "FAILING: cargo test" --no-summary --summary ok >/dev/null
check "validate FAILING → retry" "retry" "$(v r-failing)"

printf '{"round_id":"r-broken"}' > "$WT/tmp/dev-return-T-1-r-broken.json"
check "schema-invalid artifact → retry" "retry" "$(v r-broken || true)"

# --- review-artifact-check --path ---
p="$("$SCRIPTS/review-artifact-check" --path "$WT" reviewer-test)"
if [[ "$p" =~ ^"$WT"/tmp/review-reviewer-test-[0-9]{8}-[0-9]{6}\.json$ ]]; then
  ok "--path prints the canonical timestamped path"
else
  bad "--path prints the canonical timestamped path (got '$p')"
fi
[[ -d "$WT/tmp" ]] && ok "--path creates tmp/" || bad "--path creates tmp/"
if "$SCRIPTS/review-artifact-check" --path "$WT" 'evil/../name' >/dev/null 2>&1; then
  bad "--path rejects a path-unsafe agent name"
else
  ok "--path rejects a path-unsafe agent name"
fi
if "$SCRIPTS/review-artifact-check" --path "$TMP/nope" reviewer-test >/dev/null 2>&1; then
  bad "--path rejects a missing worktree"
else
  ok "--path rejects a missing worktree"
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

out=$(cd "$WT" && GH_STUB_LOG="$TMP/gh.log" CI_WAIT_NO_CHECKS_GRACE=1 \
  PATH="$BIN:$PATH" GH_TOKEN=stub "$SCRIPTS/ci-wait" 1 1 5 --json 2>/dev/null || true)
check "no workflows + no protection + no rules → verdict none" "none" "$(jq -r '.verdict // empty' <<<"$out")"
check "none-configured is status complete" "complete" "$(jq -r '.status // empty' <<<"$out")"

# Teeth: with active workflows present the shortcut must NOT fire — the run
# falls through to the grace path and, at grace 1s with no checks, errors out.
out2=$(cd "$WT" && GH_STUB_WORKFLOWS=3 CI_WAIT_NO_CHECKS_GRACE=1 \
  PATH="$BIN:$PATH" GH_TOKEN=stub "$SCRIPTS/ci-wait" 1 1 5 --json 2>/dev/null || true)
v2="$(jq -r '.verdict // empty' <<<"$out2")"
if [[ "$v2" != "none" ]]; then
  ok "active workflows suppress the none-configured shortcut (teeth)"
else
  bad "active workflows suppress the none-configured shortcut (teeth)"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
