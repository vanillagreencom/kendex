#!/usr/bin/env bash
# Regression tests for orch/scripts/session-init worktree auth reporting.
# The worktree fast path must preserve structured linear auth-check failures and
# reserve "not installed" for a missing linear skill command.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/skills/orch/scripts/session-init"
LINEAR_SKILL="$REPO_ROOT/skills/linear"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

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

STUB_BIN="$TMP_ROOT/bin"
mkdir -p "$STUB_BIN"

cat >"$STUB_BIN/git" <<'SH'
#!/usr/bin/env bash
case "$*" in
  "rev-parse --show-toplevel") printf '%s\n' "${TEST_PROJECT_ROOT:?}" ;;
  "rev-parse --git-common-dir")
    if [[ "${TEST_WORKTREE:-true}" == "false" ]]; then
      printf '%s\n' "${TEST_PROJECT_ROOT:?}/.git"
    else
      printf '%s\n' "${TEST_PROJECT_ROOT:?}/../main/.git"
    fi
    ;;
  "branch --show-current") printf '%s\n' "issue-322" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$STUB_BIN/git"

cat >"$STUB_BIN/op" <<'SH'
#!/usr/bin/env bash
echo 'fake op failure' >&2
exit 1
SH
chmod +x "$STUB_BIN/op"

cat >"$STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
      [[ "$tok" == "gho_VALID123" ]] || { echo "auth failed" >&2; exit 1; }
      if [[ "$*" == *"--json hosts"* ]]; then
        printf '%s\n' '{"hosts":{"github.com":[{"login":"test-user","state":"success","gitProtocol":"https","active":true}]}}'
      else
        echo "Logged in"
      fi
      exit 0
    fi
    ;;
  api)
    if [[ "${2:-}" == "user" ]]; then
      tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
      [[ "$tok" == "gho_VALID123" ]] || { echo "HTTP 401: Bad credentials" >&2; exit 1; }
      echo "test-user"
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
SH
chmod +x "$STUB_BIN/gh"

make_worktree() {
  local name="$1" with_linear="${2:-yes}" with_github="${3:-no}"
  local wt="$TMP_ROOT/$name"
  mkdir -p "$wt/.agents/skills"
  if [[ "$with_linear" == "yes" ]]; then
    cp -R "$LINEAR_SKILL" "$wt/.agents/skills/linear"
  fi
  if [[ "$with_github" == "yes" ]]; then
    ln -s "$REPO_ROOT/skills/github" "$wt/.agents/skills/github"
  fi
  printf 'LINEAR_API_KEY=op://vault/item/field\n' >"$wt/.env.local"
  printf '%s\n' "$wt"
}

run_session_init() {
  local wt="$1"
  (
    cd "$wt"
    TEST_PROJECT_ROOT="$wt" PATH="$STUB_BIN:$PATH" "$SCRIPT" --json
  )
}

echo "=== session-init worktree Linear auth diagnostics ==="

WT_OP_FAIL="$(make_worktree wt-op-fail yes)"
out="$(run_session_init "$WT_OP_FAIL")"
err="$(jq -r '.linear_auth.error // empty' <<<"$out")"
ok="$(jq -r '.linear_auth.ok // false' <<<"$out")"
assert_eq "$ok" "false" "1Password resolution failure reports ok=false"
assert_eq "$err" "Failed to resolve LINEAR_API_KEY from 1Password. Run: op signin" "1Password resolution failure preserves auth-check error"

WT_MISSING="$(make_worktree wt-missing-linear no)"
out="$(run_session_init "$WT_MISSING")"
err="$(jq -r '.linear_auth.error // empty' <<<"$out")"
ok="$(jq -r '.linear_auth.ok // false' <<<"$out")"
assert_eq "$ok" "false" "missing linear command reports ok=false"
assert_eq "$err" "not installed" "missing linear command reports not installed"

WT_GITHUB="$(make_worktree wt-github yes)"
out="$(
  cd "$WT_GITHUB"
  TEST_PROJECT_ROOT="$WT_GITHUB" PATH="$STUB_BIN:$PATH" "$SCRIPT" --json github vanillagreencom/vstack#356
)"
issue="$(jq -r '.issue_id // empty' <<<"$out")"
tracker="$(jq -r '.tracker // empty' <<<"$out")"
repo="$(jq -r '.github_repo // empty' <<<"$out")"
number="$(jq -r '.github_issue // empty' <<<"$out")"
assert_eq "$issue" "issue-356" "GitHub refs normalize to issue-N in worktree init"
assert_eq "$tracker" "github" "GitHub refs report github tracker"
assert_eq "$repo" "vanillagreencom/vstack" "GitHub refs preserve owner/repo"
assert_eq "$number" "356" "GitHub refs preserve issue number"

WT_GITHUB_TOKEN="$(make_worktree wt-github-token yes yes)"
out="$(
  cd "$WT_GITHUB_TOKEN"
  TEST_PROJECT_ROOT="$WT_GITHUB_TOKEN" PATH="$STUB_BIN:$PATH" GITHUB_TOKEN=gho_VALID123 "$SCRIPT" --json
)"
gh_auth="$(jq -r '.gh_auth // false' <<<"$out")"
assert_eq "$gh_auth" "true" "worktree GitHub auth accepts selected GITHUB_TOKEN"

WT_DASHBOARD_TOKEN="$(make_worktree wt-dashboard-token yes yes)"
out="$(
  cd "$WT_DASHBOARD_TOKEN"
  TEST_PROJECT_ROOT="$WT_DASHBOARD_TOKEN" TEST_WORKTREE=false PATH="$STUB_BIN:$PATH" GITHUB_TOKEN=gho_VALID123 "$SCRIPT" --json
)"
gh_available="$(jq -r '.gh_auth.available // false' <<<"$out")"
gh_active="$(jq -r '.gh_auth.active_account // empty' <<<"$out")"
assert_eq "$gh_available" "true" "dashboard GitHub auth accepts selected GITHUB_TOKEN"
assert_eq "$gh_active" "test-user" "dashboard GitHub auth reports selected token account"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
