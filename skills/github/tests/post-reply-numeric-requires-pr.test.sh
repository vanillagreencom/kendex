#!/usr/bin/env bash
# Regression tests for post-reply.sh numeric-comment-ID --pr enforcement (vstack#528).
#
# Numeric comment IDs use the legacy REST reply path and require an explicit
# --pr <N>. Previously the numeric path called resolve_pr_number("") ->
# get_current_pr, silently auto-resolving the PR from the current branch and
# hitting a REST path that collided with the bot's pending review. These tests
# assert the local usage error fires before any gh/API call, that thread IDs
# still work without --pr, and that a numeric id WITH --pr reaches the
# collision-safe /replies endpoint.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
POST_REPLY="$REPO_ROOT/skills/github/scripts/commands/post-reply.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# The lib derives PROJECT_ROOT via `git rev-parse` at source time (set -e), so
# the working directory must be a git repo. gh remains stubbed — no network.
git -C "$TMP_ROOT" init -q

GH_CALLS="$TMP_ROOT/gh.calls"

# Stub gh: log every invocation (so we can assert the API is/ isn't touched),
# and answer the handful of calls the REST path legitimately makes.
cat >"$TMP_ROOT/gh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >>"$GH_CALLS"
case "\${1:-}" in
  auth)
    if [[ "\${2:-}" == "status" ]]; then
      echo "Logged in"
      exit 0
    fi
    ;;
  api)
    endpoint="\${2:-}"
    if [[ "\$endpoint" == user ]]; then
      echo "test-user"
      exit 0
    fi
    if [[ "\$endpoint" == *"/replies" ]]; then
      echo '{"html_url":"https://github.com/owner/repo/pull/23#discussion_r999"}'
      exit 0
    fi
    printf '[]\n'
    exit 0
    ;;
  repo)
    if [[ "\${2:-}" == "view" ]]; then
      echo '{"owner":{"login":"owner"},"name":"repo"}'
      exit 0
    fi
    ;;
  pr)
    if [[ "\${2:-}" == "view" ]]; then
      echo '{"number":77,"headRefName":"feature-branch"}'
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "\$*" >&2
exit 1
EOF
chmod +x "$TMP_ROOT/gh"

# Run post-reply.sh in a clean, network-free environment with the stubbed gh on
# PATH. Env tokens are unset so check_gh_auth takes the (stubbed) keyring path.
run_post_reply() {
  rm -f "$GH_CALLS"
  (cd "$TMP_ROOT" && PATH="$TMP_ROOT:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN "$POST_REPLY" "$@")
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

assert_file_missing() {
  local path="$1" name="$2"
  if [[ ! -e "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected file present: %s\n        contents:\n%s\n' \
      "$name" "$path" "$(cat "$path")"
  fi
}

echo "=== post-reply numeric comment ID requires --pr (vstack#528) ==="

# 1. Numeric id, no --pr -> local usage error, nonzero, and NO gh/API call.
set +e
out=$(run_post_reply 2633519824 "Fixed!" 2>&1)
rc=$?
set -e
assert_eq "$rc" "1" "numeric id without --pr exits nonzero"
assert_contains "$out" "requires --pr" "numeric id without --pr reports usage error"
assert_file_missing "$GH_CALLS" "numeric id without --pr makes no gh/API call"

# 2. Numeric id, no --pr, --dry-run -> same local error, no silent dry-run.
set +e
out=$(run_post_reply 2633519824 "Fixed!" --dry-run 2>&1)
rc=$?
set -e
assert_eq "$rc" "1" "numeric id without --pr (--dry-run) exits nonzero"
assert_contains "$out" "requires --pr" "numeric id without --pr (--dry-run) reports usage error"
assert_file_missing "$GH_CALLS" "numeric id without --pr (--dry-run) makes no gh/API call"

# 3a. Numeric id WITH --pr N, --dry-run -> reports method rest and pr N.
set +e
out=$(run_post_reply 2633519824 "Fixed!" --pr 23 --dry-run 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "numeric id with --pr (--dry-run) succeeds"
assert_eq "$(jq -r '.method' <<<"$out")" "rest" "numeric id with --pr (--dry-run) uses rest method"
assert_eq "$(jq -r '.pr' <<<"$out")" "23" "numeric id with --pr (--dry-run) reports pr 23"

# 3b. Numeric id WITH --pr N, real run -> hits the /replies reply endpoint.
set +e
out=$(run_post_reply 2633519824 "Fixed!" --pr 23 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "numeric id with --pr (real) succeeds"
assert_eq "$(jq -r '.success' <<<"$(printf '%s\n' "$out" | grep '"success"')")" "true" \
  "numeric id with --pr (real) returns success"
if grep -q 'api repos/owner/repo/pulls/23/comments/2633519824/replies' "$GH_CALLS"; then
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "numeric id with --pr (real) posts to /pulls/23/comments/<id>/replies"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        gh calls:\n%s\n' \
    "numeric id with --pr (real) posts to /pulls/23/comments/<id>/replies" "$(cat "$GH_CALLS")"
fi

# 4. Thread id PRRT_..., no --pr, --dry-run -> graphql path, no --pr error.
set +e
out=$(run_post_reply PRRT_kwDOexample123 "Thanks!" --dry-run 2>&1)
rc=$?
set -e
assert_eq "$rc" "0" "thread id without --pr (--dry-run) succeeds"
assert_eq "$(jq -r '.method' <<<"$out")" "graphql" "thread id without --pr (--dry-run) uses graphql method"
assert_file_missing "$GH_CALLS" "thread id without --pr (--dry-run) makes no gh/API call"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
