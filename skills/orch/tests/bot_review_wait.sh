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

# Assert stdout is a single parseable JSON object (vstack#453: --json must never
# finish silently, on any exit path).
assert_json() {
  local doc="$1" name="$2"
  if [[ -n "$doc" ]] && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$doc"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        stdout was not parseable JSON: %s\n' "$name" "$doc"
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
  if [[ "${2:-}" == "3" || "${2:-}" == "9" || "${2:-}" == "14" ]]; then
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
      if [[ -n "${FAKE_GH_AUTH_STATUS_COUNT_FILE:-}" ]]; then
        count=0
        if [[ -f "$FAKE_GH_AUTH_STATUS_COUNT_FILE" ]]; then
          count="$(cat "$FAKE_GH_AUTH_STATUS_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$FAKE_GH_AUTH_STATUS_COUNT_FILE"
      fi
      if [[ "${FAKE_GH_AUTH_MODE:-token-invalid-keyring-ok}" == "hang" ]]; then
        sleep 5
      fi
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
    if [[ "$endpoint" == "user" ]]; then
      if [[ -n "${FAKE_GH_USER_COUNT_FILE:-}" ]]; then
        count=0
        if [[ -f "$FAKE_GH_USER_COUNT_FILE" ]]; then
          count="$(cat "$FAKE_GH_USER_COUNT_FILE")"
        fi
        count=$((count + 1))
        printf '%s' "$count" > "$FAKE_GH_USER_COUNT_FILE"
      fi
      if [[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]]; then
        if [[ -n "${STUB_GH_VALID_TOKEN:-}" && "${GH_TOKEN:-${GITHUB_TOKEN:-}}" == "$STUB_GH_VALID_TOKEN" ]]; then
          echo "test-user"
          exit 0
        fi
        echo "HTTP 401: Bad credentials" >&2
        exit 1
      fi
      if [[ "${FAKE_GH_AUTH_MODE:-token-invalid-keyring-ok}" == "fail" ]]; then
        echo "HTTP 401: Bad credentials" >&2
        exit 1
      fi
      echo "test-user"
      exit 0
    fi
    case "$endpoint" in
      graphql)
        if [[ "$*" == *"pr=4"* ]]; then
          echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"vg-claude"}}]}}]}}}}}'
        elif [[ "$*" == *"pr=5"* || "$*" == *"pr=6"* ]]; then
          echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"human-reviewer"}}]}}]}}}}}'
        elif [[ "$*" == *"pr=7"* || "$*" == *"pr=8"* ]]; then
          pr_id="7"
          [[ "$*" == *"pr=8"* ]] && pr_id="8"
          count_file="${FAKE_GH_STATE_DIR:-}/pr${pr_id}-reactions-count"
          count=0
          if [[ -n "${FAKE_GH_STATE_DIR:-}" && -f "$count_file" ]]; then
            count="$(cat "$count_file")"
          fi
          if [[ "$count" -ge 2 ]]; then
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector[bot]"}}]}}]}}}}}'
          else
            echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}'
          fi
        elif [[ "$*" == *"pr=15"* ]]; then
          # PR 15 (#518): the real GraphQL review-thread author login for a GitHub
          # App bot is the BARE app slug (no "[bot]" suffix), while the reviewer is
          # configured/detected as "chatgpt-codex-connector[bot]". Attribution must
          # normalize both sides or it misses this unresolved inline thread.
          echo '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"}}]}}]}}}}}'
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
      repos/*/pulls/5/reviews|repos/*/pulls/6/reviews|repos/*/pulls/7/reviews|repos/*/pulls/8/reviews|repos/*/pulls/12/reviews|repos/*/pulls/13/reviews)
        echo '[]'
        exit 0
        ;;
      repos/*/pulls/9/reviews)
        echo '[{"user":{"login":"vg-claude"},"state":"CHANGES_REQUESTED","submitted_at":"2026-01-01T00:00:00Z"}]'
        exit 0
        ;;
      repos/*/pulls/11/reviews)
        # PR 11 (#450): claude[bot] formally approves; codex only reacts 👀.
        echo '[{"user":{"login":"claude[bot]"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"}]'
        exit 0
        ;;
      repos/*/pulls/14/reviews)
        # PR 14 (#487): claude[bot] formal approval; codex 👍 (own reactions),
        # zero unresolved threads, but a stale sticky "- [ ]" checklist. Both
        # reviewers are terminal-approved via their OWN signals, so completion
        # must not block on the checklist drain regardless of MAX_WAIT budget.
        echo '[{"user":{"login":"claude[bot]"},"state":"APPROVED","submitted_at":"2026-01-01T00:00:00Z"}]'
        exit 0
        ;;
      repos/*/pulls/15/reviews)
        # PR 15 (#518): Codex posts a formal COMMENTED review (which alone sets no
        # terminal status) alongside an unresolved inline thread it authored.
        echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"2026-01-01T00:10:00Z"}]'
        exit 0
        ;;
      repos/*/pulls/10/reviews)
        count_file="${FAKE_GH_STATE_DIR:-}/pr10-reviews-count"
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
          echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"state":"COMMENTED","submitted_at":"2026-01-01T00:10:00Z"}]'
        else
          echo '[]'
        fi
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
      repos/*/issues/5/comments|repos/*/issues/6/comments|repos/*/issues/7/comments|repos/*/issues/8/comments|repos/*/issues/9/comments|repos/*/issues/10/comments|repos/*/issues/11/comments|repos/*/issues/12/comments|repos/*/issues/13/comments|repos/*/issues/14/comments|repos/*/issues/15/comments)
        echo '[]'
        exit 0
        ;;
      repos/*/issues/1/comments|repos/*/issues/1/reactions|repos/*/issues/2/reactions|repos/*/issues/12/reactions|repos/*/issues/13/reactions|repos/*/issues/15/reactions|repos/*/issues/comments/*/reactions)
        echo '[]'
        exit 0
        ;;
      repos/*/issues/14/reactions)
        # PR 14 (#487): Codex approved the PR body with 👍.
        echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1"}]'
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
      repos/*/issues/9/reactions)
        echo '[]'
        exit 0
        ;;
      repos/*/issues/5/reactions)
        echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"eyes"}]'
        exit 0
        ;;
      repos/*/issues/11/reactions)
        # Codex only acknowledged the PR body with 👀 — never approved.
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
      repos/*/issues/7/reactions)
        count_file="${FAKE_GH_STATE_DIR:-}/pr7-reactions-count"
        count=0
        if [[ -n "${FAKE_GH_STATE_DIR:-}" && -f "$count_file" ]]; then
          count="$(cat "$count_file")"
        fi
        count=$((count + 1))
        if [[ -n "${FAKE_GH_STATE_DIR:-}" ]]; then
          mkdir -p "$FAKE_GH_STATE_DIR"
          printf '%s' "$count" > "$count_file"
        fi
        echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1"}]'
        exit 0
        ;;
      repos/*/issues/8/reactions)
        count_file="${FAKE_GH_STATE_DIR:-}/pr8-reactions-count"
        count=0
        if [[ -n "${FAKE_GH_STATE_DIR:-}" && -f "$count_file" ]]; then
          count="$(cat "$count_file")"
        fi
        count=$((count + 1))
        if [[ -n "${FAKE_GH_STATE_DIR:-}" ]]; then
          mkdir -p "$FAKE_GH_STATE_DIR"
          printf '%s' "$count" > "$count_file"
        fi
        echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1"}]'
        exit 0
        ;;
      repos/*/issues/comments/5001/reactions)
        echo '[]'
        exit 0
        ;;
      repos/*/issues/10/reactions)
        count_file="${FAKE_GH_STATE_DIR:-}/pr10-reactions-count"
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
          echo '[]'
        else
          echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1"}]'
        fi
        exit 0
        ;;
    esac
    ;;
  pr)
    case "${2:-}" in
      view)
        if [[ "${3:-}" == "3" || "${3:-}" == "4" || "${3:-}" == "5" || "${3:-}" == "6" || "${3:-}" == "8" || "${3:-}" == "11" || "${3:-}" == "14" ]]; then
          echo '{"reviewDecision":"APPROVED"}'
        else
          echo '{"reviewDecision":"REVIEW_REQUIRED"}'
        fi
        exit 0
        ;;
      checks)
        if [[ "${3:-}" == "3" || "${3:-}" == "4" || "${3:-}" == "8" ]]; then
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
export GH_TOKEN=bad-token
export GH_BOT_TOKEN=ghs_VALIDBOT123
EOF
stderr="$TMP_ROOT/stale-env-bot.err"
user_count_file="$TMP_ROOT/stale-env-bot-api-user-count"
output=$(FAKE_GH_AUTH_MODE=fail STUB_GH_VALID_TOKEN=ghs_VALIDBOT123 FAKE_GH_USER_COUNT_FILE="$user_count_file" run_wait 1 1 5 --json --reviewers 'review-bot[bot]' 2>"$stderr")
assert_eq "$(jq -r .status <<<"$output")" "complete" "bad GH_TOKEN falls back to GH_BOT_TOKEN when keyring fails"
assert_eq "$(jq -r .verdict <<<"$output")" "approved" "bot-token fallback returns terminal JSON"
assert_eq "$(cat "$user_count_file")" "2" "stale env and bot token are each validated once"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
export GH_TOKEN=bad-project-token
EOF
stderr="$TMP_ROOT/env-first.err"
output=$(GH_TOKEN=ghs_CALLER123 STUB_GH_VALID_TOKEN=ghs_CALLER123 run_wait 1 1 5 --json --reviewers 'review-bot[bot]' 2>"$stderr")
assert_eq "$(jq -r .status <<<"$output")" "complete" "caller GH_TOKEN wins over project GH_TOKEN"
assert_eq "$(cat "$stderr")" "" "caller GH_TOKEN does not trigger sanitizer fallback"

stderr="$TMP_ROOT/stale-keyring.err"
user_count_file="$TMP_ROOT/stale-keyring-api-user-count"
output=$(GH_TOKEN=ghs_CALLER123 STUB_GH_VALID_TOKEN=ghs_CALLER123 FAKE_GH_AUTH_MODE=fail FAKE_GH_USER_COUNT_FILE="$user_count_file" run_wait 1 1 5 --json --reviewers 'review-bot[bot]' 2>"$stderr")
assert_eq "$(jq -r .status <<<"$output")" "complete" "caller GH_TOKEN ignores stale keyring status"
assert_eq "$(cat "$stderr")" "" "stale keyring does not trigger sanitizer fallback for valid caller token"
assert_eq "$(cat "$user_count_file")" "1" "selected token is validated once at startup"

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
output=$(BOT_REVIEW_SETTLE_SECONDS=0 run_wait 3 1 5 --json --reviewers 'vg-claude')
assert_eq "$(jq -r .status <<<"$output")" "complete" "PR-level approved reviewDecision resolves stale pending sticky"
assert_eq "$(jq -r .verdict <<<"$output")" "approved" "PR-level approved fallback returns approved verdict"
assert_eq "$(jq -r .elapsed_seconds <<<"$output")" "0" "PR-level approved fallback skips stale sticky checklist wait"
assert_contains "$(jq -c '.reviewers[0].signals' <<<"$output")" "pr_review_decision:approved" "PR-level approved fallback records signal"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
EOF
# #450: a global reviewDecision=APPROVED coming from a DIFFERENT reviewer
# (claude[bot] formal approval) must not promote an eyes-only reviewer.
set +e
output=$(run_wait 11 1 1 --json --reviewers 'claude[bot],chatgpt-codex-connector[bot]')
code=$?
set -e
assert_eq "$code" "1" "eyes-only bot with foreign approval times out pending"
assert_eq "$(jq -r .status <<<"$output")" "timeout" "eyes-only bot with foreign approval emits timeout JSON"
assert_eq "$(jq -r .verdict <<<"$output")" "pending" "eyes-only bot keeps overall verdict pending"
assert_eq "$(jq -r '.approved_reviewers | join(",")' <<<"$output")" "claude[bot]" "formal approver is reported approved"
assert_eq "$(jq -r '.pending_reviewers | join(",")' <<<"$output")" "chatgpt-codex-connector[bot]" "eyes-only bot stays pending, not approved"
assert_contains "$(jq -c '.reviewers[] | select(.reviewer == "chatgpt-codex-connector[bot]") | .signals' <<<"$output")" "reaction:eyes" "eyes-only bot records reaction:eyes"
assert_eq "$(jq -r '[.reviewers[] | select(.reviewer == "chatgpt-codex-connector[bot]") | .signals[] | select(. == "pr_review_decision:approved")] | length' <<<"$output")" "0" "eyes-only bot does not inherit pr_review_decision:approved"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
EOF
set +e
output=$(timeout 8s bash -c 'cd "$1" && PATH="$2:$PATH" FAKE_GH_STATE_DIR="$3" BOT_REVIEW_SETTLE_SECONDS=2 BOT_REVIEW_SETTLE_INTERVAL=1 .agents/skills/orch/scripts/bot-review-wait 7 1 5 --json --reviewers "chatgpt-codex-connector[bot]"' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin" "$TMP_ROOT/pr7-state")
code=$?
set -e
assert_eq "$code" "0" "Codex-style approval waits for late inline threads"
assert_eq "$(cat "$TMP_ROOT/pr7-state/pr7-reactions-count")" "3" "Codex-style approval re-reads reviewer status during settle"
assert_eq "$(jq -r .status <<<"$output")" "complete" "late inline thread emits complete JSON"
assert_eq "$(jq -r .verdict <<<"$output")" "changes" "late inline thread changes the verdict"
assert_contains "$(jq -c '.reviewers[0].signals' <<<"$output")" "inline:1" "late inline thread is represented in reviewer signals"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
BOT_CHECK_NAME="Claude Code"
EOF
set +e
output=$(timeout 8s bash -c 'cd "$1" && PATH="$2:$PATH" FAKE_GH_STATE_DIR="$3" BOT_REVIEW_SETTLE_SECONDS=2 BOT_REVIEW_SETTLE_INTERVAL=1 .agents/skills/orch/scripts/bot-review-wait 8 1 5 --json --reviewers "chatgpt-codex-connector[bot]"' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin" "$TMP_ROOT/pr8-state")
code=$?
set -e
assert_eq "$code" "0" "BOT_CHECK_NAME fast path refreshes after late inline threads"
assert_eq "$(cat "$TMP_ROOT/pr8-state/pr8-reactions-count")" "3" "BOT_CHECK_NAME fast path re-reads reviewer status during settle"
assert_eq "$(jq -r .status <<<"$output")" "complete" "BOT_CHECK_NAME late inline thread emits complete JSON"
assert_eq "$(jq -r .verdict <<<"$output")" "changes" "BOT_CHECK_NAME late inline thread changes the verdict"
assert_contains "$(jq -c '.reviewers[0].signals' <<<"$output")" "inline:1" "BOT_CHECK_NAME late inline thread is represented in reviewer signals"

cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
EOF
set +e
output=$(timeout 15s bash -c 'cd "$1" && PATH="$2:$PATH" FAKE_GH_STATE_DIR="$3" BOT_REVIEW_SETTLE_SECONDS=2 BOT_REVIEW_SETTLE_INTERVAL=1 .agents/skills/orch/scripts/bot-review-wait 10 1 6 --json --reviewers "chatgpt-codex-connector[bot]"' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin" "$TMP_ROOT/pr10-state")
code=$?
set -e
assert_eq "$code" "0" "established +1 approval survives later formal COMMENTED review"
assert_eq "$(jq -r .status <<<"$output")" "complete" "COMMENTED after clean +1 emits complete JSON"
assert_eq "$(jq -r .verdict <<<"$output")" "approved" "COMMENTED after clean +1 keeps approved verdict"
assert_eq "$(jq -r '.approved_reviewers | join(",")' <<<"$output")" "chatgpt-codex-connector[bot]" "COMMENTED after clean +1 keeps Codex approved"
assert_eq "$(cat "$TMP_ROOT/pr10-state/pr10-reviews-count")" "3" "settle window re-reads reviewer status after COMMENTED regression"

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
output=$(run_wait 9 1 1 --json --reviewers 'vg-claude')
code=$?
set -e
assert_eq "$code" "2" "changes verdict with pending sticky checklist exits checklist timeout"
assert_eq "$(jq -r .status <<<"$output")" "checklist_timeout" "changes verdict with pending sticky checklist emits timeout JSON"
assert_eq "$(jq -r .verdict <<<"$output")" "changes" "changes verdict with pending sticky checklist preserves changes verdict"

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
# #487: both reviewers are terminal-approved via their OWN signals (claude[bot]
# formal APPROVED, codex 👍) with zero unresolved threads, but a stale sticky
# "- [ ]" checklist never drains. The terminal result must be independent of the
# MAX_WAIT budget: a long-budget waiter must NOT block on the checklist drain
# (which, pre-fix, burned up to PHASE3_MAX / remaining budget and then emitted
# checklist_timeout). Wrapped in `timeout 8s` so a regression that reinstates the
# unbounded checklist wait would kill the run and fail loudly rather than pass.
set +e
long_output=$(timeout 8s bash -c 'cd "$1" && PATH="$2:$PATH" BOT_REVIEW_SETTLE_SECONDS=0 .agents/skills/orch/scripts/bot-review-wait 14 1 600 --json --reviewers "claude[bot],chatgpt-codex-connector[bot]"' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin")
long_code=$?
set -e
assert_eq "$long_code" "0" "own-terminal approval + stale checklist completes on long budget (#487)"
assert_json "$long_output" "own-terminal approval long budget emits parseable JSON"
assert_eq "$(jq -r .status <<<"$long_output")" "complete" "own-terminal approval emits complete, not checklist_timeout (#487)"
assert_eq "$(jq -r .verdict <<<"$long_output")" "approved" "own-terminal approval keeps approved verdict (#487)"
# Must return well under the pre-fix checklist window (PHASE3_MAX=300, capped by
# the 600s budget); a couple of seconds of stub wall-time is fine, 300+ is not.
long_elapsed="$(jq -r .elapsed_seconds <<<"$long_output")"
assert_eq "$([[ "$long_elapsed" =~ ^[0-9]+$ && "$long_elapsed" -lt 30 ]] && echo under || echo "$long_elapsed")" "under" "own-terminal approval does not consume the long budget on the checklist (#487)"
# Resolution must come from reviewer-own signals, not the PR-level fallback
# promotion — neither reviewer should carry pr_review_decision:approved.
assert_eq "$(jq -r '[.reviewers[] | .signals[] | select(. == "pr_review_decision:approved")] | length' <<<"$long_output")" "0" "own-terminal approval resolves without PR-level fallback promotion (#487)"

# Duration independence: the same stubbed state under a short budget yields the
# identical terminal status/verdict.
set +e
short_output=$(timeout 8s bash -c 'cd "$1" && PATH="$2:$PATH" BOT_REVIEW_SETTLE_SECONDS=0 .agents/skills/orch/scripts/bot-review-wait 14 1 10 --json --reviewers "claude[bot],chatgpt-codex-connector[bot]"' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin")
short_code=$?
set -e
assert_eq "$short_code" "0" "own-terminal approval completes on short budget (#487)"
assert_eq "$(jq -r .status <<<"$short_output")" "$(jq -r .status <<<"$long_output")" "long and short budgets agree on status (#487)"
assert_eq "$(jq -r .verdict <<<"$short_output")" "$(jq -r .verdict <<<"$long_output")" "long and short budgets agree on verdict (#487)"

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

stderr="$TMP_ROOT/auth-hang.err"
auth_status_count_file="$TMP_ROOT/auth-hang-status-count"
set +e
output=$(timeout 6s bash -c 'cd "$1" && PATH="$2:$PATH" VSTACK_GITHUB_AUTH_TIMEOUT=1 FAKE_GH_AUTH_MODE=hang FAKE_GH_AUTH_STATUS_COUNT_FILE="$3" .agents/skills/orch/scripts/bot-review-wait 1 1 30 --json --reviewers "review-bot[bot]"' bash "$TMP_ROOT/repo" "$TMP_ROOT/bin" "$auth_status_count_file" 2>"$stderr")
code=$?
set -e
assert_eq "$code" "3" "hanging gh auth status exits through bounded preflight"
assert_eq "$(jq -r .status <<<"$output")" "error" "hanging gh auth status emits JSON error"
assert_contains "$(cat "$stderr")" "GitHub CLI authentication failed" "hanging gh auth status emits stderr diagnostic"
assert_eq "$(cat "$auth_status_count_file")" "1" "hanging keyring auth is probed once"

echo "=== bot-review-wait --json always emits JSON (#453) ==="

# Silent path 1: a missing github CLI used to `exit 1` before arg parse, so
# --json produced no stdout. It must now emit a JSON error object.
cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$TMP_ROOT/does-not-exist.sh"
EOF
set +e
output=$(run_wait 12 1 5 --json --reviewers 'review-bot[bot]' 2>/dev/null)
code=$?
set -e
assert_eq "$code" "3" "missing GIT_HOST_CLI exits 3 in --json mode"
assert_json "$output" "missing GIT_HOST_CLI emits JSON instead of silent exit"
assert_eq "$(jq -r .status <<<"$output")" "error" "missing GIT_HOST_CLI reports status error"
assert_contains "$output" "GIT_HOST_CLI not found" "missing GIT_HOST_CLI JSON carries diagnostic"

# Silent path 2: no bot reviewers detected. --json must still emit a result.
cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
EOF
output=$(run_wait 12 1 5 --json)
code=$?
assert_eq "$code" "0" "no reviewers detected exits 0"
assert_json "$output" "no reviewers path emits parseable JSON"
assert_eq "$(jq -r .status <<<"$output")" "no_reviewers" "no reviewers path reports no_reviewers status"

# Silent path 3: reviewer configured but no review posted yet (the #453 repro —
# reviewDecision=REVIEW_REQUIRED, clear threads). --json must emit a timeout
# result with the reviewer still pending, never finish silently.
set +e
output=$(run_wait 13 1 1 --json --reviewers 'chatgpt-codex-connector[bot]')
code=$?
set -e
assert_eq "$code" "1" "pending reviewer at deadline exits 1"
assert_json "$output" "timeout-with-pending path emits parseable JSON"
assert_eq "$(jq -r .status <<<"$output")" "timeout" "timeout-with-pending reports timeout status"
assert_eq "$(jq -r '.pending_reviewers | join(",")' <<<"$output")" "chatgpt-codex-connector[bot]" "timeout-with-pending keeps reviewer pending"

# Silent path 4: hard auth failure must emit a parseable JSON error object.
stderr="$TMP_ROOT/json-err.err"
set +e
output=$(FAKE_GH_AUTH_MODE=fail run_wait 1 1 5 --json --reviewers 'review-bot[bot]' 2>"$stderr")
code=$?
set -e
assert_eq "$code" "3" "auth failure exits 3 in --json mode"
assert_json "$output" "auth failure path emits parseable JSON"
assert_eq "$(jq -r .status <<<"$output")" "error" "auth failure reports status error"

echo "=== bot-review-wait Codex COMMENTED + unresolved bot thread (#518) ==="

# #518: a Codex reviewer posts a formal COMMENTED review AND leaves an unresolved
# inline review thread. The thread's GraphQL author login is the bare app slug
# ("chatgpt-codex-connector") while the reviewer is "chatgpt-codex-connector[bot]".
# Pre-fix, the exact `author.login == reviewer` match missed the thread, so the
# reviewer stayed unknown with unresolved_threads:0 and the waiter timed out. The
# normalized match must attribute the thread, force the reviewer to "changes", and
# reach a terminal complete/changes result (not unknown/pending, not timeout).
cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
EOF
set +e
output=$(run_wait 15 1 1 --json --reviewers 'chatgpt-codex-connector[bot]')
code=$?
set -e
assert_eq "$code" "0" "COMMENTED + unresolved bot thread reaches terminal exit 0 (#518)"
assert_eq "$(jq -r .status <<<"$output")" "complete" "COMMENTED + unresolved bot thread emits complete JSON (#518)"
assert_eq "$(jq -r .verdict <<<"$output")" "changes" "COMMENTED + unresolved bot thread yields changes verdict (#518)"
assert_eq "$(jq -r '.reviewers[] | select(.reviewer == "chatgpt-codex-connector[bot]") | .status' <<<"$output")" "changes" "unresolved bot thread forces reviewer status changes, not unknown/pending (#518)"
assert_eq "$([[ "$(jq -r '.reviewers[] | select(.reviewer == "chatgpt-codex-connector[bot]") | .unresolved_threads' <<<"$output")" -ge 1 ]] && echo ok)" "ok" "unresolved bot thread is counted (unresolved_threads >= 1) despite [bot]-suffix mismatch (#518)"
assert_eq "$(jq -r '.changes_reviewers | join(",")' <<<"$output")" "chatgpt-codex-connector[bot]" "Codex reviewer is bucketed under changes (#518)"
assert_contains "$(jq -c '.reviewers[] | select(.reviewer == "chatgpt-codex-connector[bot]") | .signals' <<<"$output")" "inline:1" "unresolved bot thread records inline:1 signal (#518)"

echo "=== bot-review-wait interrupt exit status (#520) ==="

# #520: an interrupt (Ctrl-C / SIGTERM) delivered while the waiter is parked in a
# poll sleep must exit the process nonzero AND the EXIT-trap JSON backstop must
# report the SAME nonzero status. Pre-fix, with no INT/TERM trap, the backstop
# captured a normalized $?=0 (JSON "exit 0") while the process itself exited
# 128+signum — the two disagreed. The fix's `trap 'exit 130' INT TERM` makes both
# deterministically 130. SIGINT is inherited-ignored by background jobs in this
# harness, so SIGTERM (the other signal the fix traps) is the reliable proxy for
# the interrupt path; the trap covers both. PR 13 stays pending, so the waiter is
# guaranteed to be sitting in a poll sleep when the signal arrives.
cat > "$TMP_ROOT/repo/.env.local" <<EOF
GIT_HOST_CLI="$FAKE_GITHUB_SH"
EOF
int_out="$TMP_ROOT/int.out"
int_code_file="$TMP_ROOT/int.code"
: > "$int_out"
rm -f "$int_code_file"
(
  cd "$TMP_ROOT/repo"
  # setsid puts the waiter (and its sleep child) in a fresh process group so the
  # signal reaches the whole group like a terminal Ctrl-C — without hitting this
  # test's own shell, which stays in its original group.
  env PATH="$TMP_ROOT/bin:$PATH" setsid .agents/skills/orch/scripts/bot-review-wait 13 10 30 --json --reviewers 'chatgpt-codex-connector[bot]' >"$int_out" 2>/dev/null &
  wpid=$!
  sleep 3
  wpgid=$(ps -o pgid= -p "$wpid" 2>/dev/null | tr -d ' ')
  [[ -n "$wpgid" ]] && kill -TERM -"$wpgid" 2>/dev/null || true
  # Capture the waiter's exit without letting `set -e` abort on its nonzero
  # (interrupted) status before we record it.
  set +e
  wait "$wpid"
  wcode=$?
  set -e
  printf '%s' "$wcode" > "$int_code_file"
)
int_code="$(cat "$int_code_file" 2>/dev/null || echo MISSING)"
int_json="$(cat "$int_out" 2>/dev/null || echo '')"
reported_exit="$(jq -r '.error // ""' <<<"$int_json" 2>/dev/null | grep -oE 'exit [0-9]+' | grep -oE '[0-9]+' | head -1)"
assert_eq "$int_code" "130" "interrupt makes the process exit 130 (#520)"
assert_json "$int_json" "interrupt still emits a parseable JSON backstop (#520)"
assert_eq "$(jq -r .status <<<"$int_json")" "error" "interrupt backstop reports status error (#520)"
assert_eq "$reported_exit" "130" "interrupt backstop JSON reports exit 130, not a normalized 0 (#520)"
assert_eq "$reported_exit" "$int_code" "interrupt backstop JSON exit matches the real process exit (#520)"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
