#!/usr/bin/env bash
# Regression tests for orch/scripts/bot-review-wait.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/repo/.agents/skills/github"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config user.email test@example.com
git -C "$TMP_ROOT/repo" config user.name Test

FAKE_GITHUB_SH="$TMP_ROOT/fake-github.sh"
cat > "$FAKE_GITHUB_SH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "sticky-comment" && "${3:-}" == "--body" ]]; then
  if [[ "${2:-}" == "3" ]]; then
    printf '%s\n' '- [ ] stale checklist item'
  fi
  exit 0
fi
printf 'unexpected github.sh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$FAKE_GITHUB_SH"

cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" ]]; then
      if [[ "${FAKE_GH_AUTH_MODE:-token-invalid-keyring-ok}" == "fail" ]]; then
        echo "gh auth failed" >&2
        exit 1
      fi
      if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
        if [[ -n "${STUB_GH_VALID_TOKEN:-}" && "${GH_TOKEN:-${GITHUB_TOKEN:-}}" == "$STUB_GH_VALID_TOKEN" ]]; then
          echo "Logged in"
          exit 0
        fi
        echo "GH_TOKEN invalid" >&2
        exit 1
      fi
      echo "Logged in"
      exit 0
    fi
    ;;
  repo)
    if [[ "${2:-}" == "view" ]]; then
      echo '{"owner":{"login":"owner"},"name":"repo"}'
      exit 0
    fi
    ;;
  api)
    endpoint="${2:-}"
    case "$endpoint" in
      graphql)
        if [[ "$*" == *"pr=4"* ]]; then
          echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"vg-claude"}}]}}]}}}}}'
        elif [[ "$*" == *"pr=5"* || "$*" == *"pr=6"* ]]; then
          echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"human-reviewer"}}]}}]}}}}}'
        else
          echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
        fi
        exit 0
        ;;
      repos/*/pulls/1/reviews)
        echo '[{"user":{"login":"review-bot[bot]"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"}]'
        exit 0
        ;;
      repos/*/pulls/2/reviews)
        echo '[]'
        exit 0
        ;;
      repos/*/pulls/3/reviews)
        echo '[]'
        exit 0
        ;;
      repos/*/pulls/4/reviews)
        echo '[]'
        exit 0
        ;;
      repos/*/pulls/5/reviews|repos/*/pulls/6/reviews)
        echo '[]'
        exit 0
        ;;
      repos/*/issues/2/comments)
        cat <<'JSON'
[
  {
    "id": 2001,
    "user": {"login": "claude[bot]"},
    "body": "**Claude finished @vg-claude's task in 1m 44s** —— [View job](https://github.com/example/actions/runs/1)\n\n---\n### Review Summary\n✅ Approved — 0 inline comments posted",
    "created_at": "2026-06-02T08:18:35Z",
    "updated_at": "2026-06-02T08:20:33Z"
  }
]
JSON
        exit 0
        ;;
      repos/*/issues/3/comments)
        cat <<'JSON'
[
  {
    "id": 3001,
    "user": {"login": "vg-claude"},
    "body": "**Claude is working** —— [View job](https://github.com/example/actions/runs/3)\n\n- [ ] Analyze changes\n- [ ] Post review",
    "created_at": "2026-06-02T08:18:35Z",
    "updated_at": "2026-06-02T08:20:33Z"
  }
]
JSON
        exit 0
        ;;
      repos/*/issues/4/comments)
        cat <<'JSON'
[
  {
    "id": 4001,
    "user": {"login": "vg-claude"},
    "body": "**Claude is working** —— [View job](https://github.com/example/actions/runs/4)\n\n- [ ] Post review",
    "created_at": "2026-06-02T08:18:35Z",
    "updated_at": "2026-06-02T08:20:33Z"
  }
]
JSON
        exit 0
        ;;
      repos/*/issues/5/comments|repos/*/issues/6/comments)
        echo '[]'
        exit 0
        ;;
      repos/*/issues/1/comments|repos/*/issues/1/reactions|repos/*/issues/2/reactions|repos/*/issues/comments/*/reactions)
        echo '[]'
        exit 0
        ;;
      repos/*/issues/3/reactions|repos/*/issues/comments/3001/reactions)
        echo '[]'
        exit 0
        ;;
      repos/*/issues/4/reactions|repos/*/issues/comments/4001/reactions)
        echo '[]'
        exit 0
        ;;
      repos/*/issues/5/reactions)
        echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"eyes"}]'
        exit 0
        ;;
      repos/*/issues/6/reactions)
        count_file="${FAKE_GH_STATE_DIR:-}/pr6-reactions-count"
        count=0
        if [[ -n "${FAKE_GH_STATE_DIR:-}" && -f "$count_file" ]]; then
          count="$(cat "$count_file")"
        fi
        count=$((count + 1))
        if [[ -n "${FAKE_GH_STATE_DIR:-}" ]]; then
          mkdir -p "$FAKE_GH_STATE_DIR"
          printf '%s' "$count" > "$count_file"
        fi
        if [[ "$count" -ge 2 ]]; then
          echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1"}]'
        else
          echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"eyes"}]'
        fi
        exit 0
        ;;
      repos/*/issues/comments/5001/reactions)
        echo '[]'
        exit 0
        ;;
    esac
    ;;
  pr)
    case "${2:-}" in
      view)
        if [[ "${3:-}" == "3" || "${3:-}" == "4" || "${3:-}" == "5" || "${3:-}" == "6" ]]; then
          echo '{"reviewDecision":"APPROVED"}'
          exit 0
        fi
        ;;
      checks)
        if [[ "${3:-}" == "3" || "${3:-}" == "4" ]]; then
          echo 'Claude Code	pass	0	https://github.com/example/actions/runs/3'
          exit 0
        fi
        ;;
    esac
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/bin/gh"

run_wait() {
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" .agents/skills/orch/scripts/bot-review-wait "$@")
}

echo "=== bot-review-wait auth handling ==="

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
export GH_TOKEN=bad-token
EOF
stderr="$TMP_ROOT/fallback.err"
output=$(run_wait 1 1 5 --json --reviewers 'review-bot[bot]' 2>"$stderr")
assert_eq "$(jq -r .status <<<"$output")" "complete" "bad GH_TOKEN falls back to gh keyring auth"
assert_eq "$(jq -r .verdict <<<"$output")" "approved" "approved formal review returns terminal JSON"
assert_contains "$(cat "$stderr")" "unsetting them" "fallback warning explains masked gh auth"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
export GH_TOKEN=bad-project-token
EOF
stderr="$TMP_ROOT/env-first.err"
output=$(GH_TOKEN=ghs_CALLER123 STUB_GH_VALID_TOKEN=ghs_CALLER123 run_wait 1 1 5 --json --reviewers 'review-bot[bot]' 2>"$stderr")
assert_eq "$(jq -r .status <<<"$output")" "complete" "caller GH_TOKEN wins over project GH_TOKEN"
assert_eq "$(cat "$stderr")" "" "caller GH_TOKEN does not trigger sanitizer fallback"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
EOF
output=$(run_wait 2 1 5 --json)
assert_eq "$(jq -r .status <<<"$output")" "complete" "Claude comment-only auto-detect completes without reviewers arg"
assert_eq "$(jq -r .verdict <<<"$output")" "approved" "Claude comment-only auto-detect returns approved verdict"
assert_eq "$(jq -r '.approved_reviewers | join(",")' <<<"$output")" "claude[bot]" "Claude comment-only auto-detect records reviewer"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
BOT_CHECK_NAME="Claude Code"
EOF
output=$(run_wait 3 1 5 --json --reviewers 'vg-claude')
assert_eq "$(jq -r .status <<<"$output")" "complete" "PR-level approved reviewDecision resolves stale pending sticky"
assert_eq "$(jq -r .verdict <<<"$output")" "approved" "PR-level approved fallback returns approved verdict"
assert_eq "$(jq -r .elapsed_seconds <<<"$output")" "0" "PR-level approved fallback skips stale sticky checklist wait"
assert_contains "$(jq -c '.reviewers[0].signals' <<<"$output")" "pr_review_decision:approved" "PR-level approved fallback records signal"

set +e
output=$(run_wait 4 1 1 --json --reviewers 'vg-claude')
code=$?
set -e
assert_eq "$code" "0" "PR-level approved fallback does not fail on unresolved terminal threads"
assert_eq "$(jq -r .status <<<"$output")" "complete" "unresolved threads are terminal"
assert_eq "$(jq -r .verdict <<<"$output")" "changes" "unresolved threads retain changes verdict"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
EOF
set +e
output=$(timeout 4s bash -c 'cd "$1" && PATH="$2:$PATH" .agents/skills/orch/scripts/bot-review-wait 5 10 1 --json --reviewers "chatgpt-codex-connector[bot]"' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin")
code=$?
set -e
assert_eq "$code" "1" "approved PR with unresolved non-reviewer threads exits at max wait"
assert_eq "$(jq -r .status <<<"$output")" "timeout" "approved PR with unresolved non-reviewer threads emits timeout JSON"
assert_eq "$(jq -r .elapsed_seconds <<<"$output")" "1" "approved PR with unresolved non-reviewer threads caps elapsed at max wait"
assert_eq "$(jq -r '.pending_reviewers | join(",")' <<<"$output")" "chatgpt-codex-connector[bot]" "approved PR with unresolved non-reviewer threads keeps Codex pending"

set +e
output=$(timeout 4s bash -c 'cd "$1" && PATH="$2:$PATH" FAKE_GH_STATE_DIR="$3" .agents/skills/orch/scripts/bot-review-wait 6 10 1 --json --reviewers "chatgpt-codex-connector[bot]"' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin" "$TMP_ROOT/state")
code=$?
set -e
assert_eq "$code" "0" "timeout final read observes reviewer terminal state"
assert_eq "$(jq -r .status <<<"$output")" "complete" "timeout final read emits complete JSON for terminal reviewer"
assert_eq "$(jq -r .elapsed_seconds <<<"$output")" "1" "timeout final read keeps elapsed capped at max wait"
assert_contains "$(jq -c '.reviewers[0].signals' <<<"$output")" "reaction:+1" "timeout final read uses refreshed reviewer signals"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
EOF
stderr="$TMP_ROOT/fail.err"
set +e
output=$(FAKE_GH_AUTH_MODE=fail run_wait 1 1 30 --json --reviewers 'review-bot[bot]' 2>"$stderr")
code=$?
set -e
assert_eq "$code" "3" "hard gh auth failure exits 3"
assert_eq "$(jq -r .status <<<"$output")" "error" "hard gh auth failure emits JSON error"
assert_contains "$(cat "$stderr")" "GitHub CLI authentication failed" "hard gh auth failure emits stderr diagnostic"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
