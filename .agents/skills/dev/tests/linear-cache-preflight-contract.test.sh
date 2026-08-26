#!/usr/bin/env bash
# Regression test for #602: a Linear work item must establish its local cache
# before mandatory reads, while GitHub-tracked work must not invoke Linear.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$TEST_DIR/../workflows/dev-implement.md"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

require_text() {
    needle="$1"
    description="$2"
    if ! grep -Fq -- "$needle" "$WORKFLOW"; then
        fail "$description"
    fi
    printf 'ok - %s\n' "$description"
}

line_of() {
    needle="$1"
    match="$(grep -nFm 1 -- "$needle" "$WORKFLOW")"
    if [ -z "$match" ]; then
        fail "missing workflow command: $needle"
    fi
    line="${match%%:*}"
    printf '%s\n' "$line"
}

assert_before() {
    first="$1"
    second="$2"
    description="$3"
    if [ "$first" -ge "$second" ]; then
        fail "$description"
    fi
    printf 'ok - %s\n' "$description"
}

SYNC_COMMAND='.agents/skills/linear/scripts/linear.sh sync --reconcile'
ACTIVATE_COMMAND='.agents/skills/linear/scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT_TYPE]'
ISSUE_READ_COMMAND='.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]'
COMMENT_READ_COMMAND='.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]'

sync_line="$(line_of "$SYNC_COMMAND")"
activate_line="$(line_of "$ACTIVATE_COMMAND")"
issue_read_line="$(line_of "$ISSUE_READ_COMMAND")"
comment_read_line="$(line_of "$COMMENT_READ_COMMAND")"

assert_before "$sync_line" "$activate_line" 'sync precedes activation'
assert_before "$sync_line" "$issue_read_line" 'sync precedes issue cache read'
assert_before "$sync_line" "$comment_read_line" 'sync precedes comment cache read'

require_text 'A missing cache before that command is expected in a fresh worktree.' \
    'fresh missing cache is an expected pre-sync state'
require_text 'that is a sync/auth/API/config' \
    'sync and authentication failures retain a distinct diagnosis'
require_text 'after sync succeeded' \
    'post-sync missing cache is diagnosed as initialization failure'
require_text 'Never run this Linear preflight for GitHub-tracked or ad-hoc work.' \
    'non-Linear trackers explicitly skip the preflight'

mkdir -p "$tmp/bin" "$tmp/project"
COMMAND_LOG="$tmp/commands.log"
CACHE_META="$tmp/project/meta.json"
export COMMAND_LOG CACHE_META

cat > "$tmp/bin/linear.sh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$COMMAND_LOG"

if [ "${1:-}" = 'sync' ]; then
    if [ "${LINEAR_STUB_MODE:-success}" = 'auth-failure' ]; then
        printf '%s\n' '{"error":"Authentication failed. Check your LINEAR_API_KEY."}' >&2
        exit 19
    fi
    printf '%s\n' '{"synced_at":"2026-07-15T00:00:00Z"}' > "$CACHE_META"
    exit 0
fi

if [ ! -f "$CACHE_META" ]; then
    printf '%s\n' '{"error":"No cache found. Run: linear.sh sync"}' >&2
    exit 1
fi

case "${1:-} ${2:-}" in
    'issues activate') printf '%s\n' '{"activated":true}' ;;
    'cache issues') printf '%s\n' '{"id":"TEST-1"}' ;;
    'cache comments') printf '%s\n' '[]' ;;
    *) printf 'unexpected command: %s\n' "$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$tmp/bin/linear.sh"

run_linear_sequence() {
    "$tmp/bin/linear.sh" sync --reconcile
    "$tmp/bin/linear.sh" issues activate TEST-1 --agent dev
    "$tmp/bin/linear.sh" cache issues get TEST-1
    "$tmp/bin/linear.sh" cache comments list TEST-1
}

assert_linear_log() {
    expected="$tmp/expected.log"
    cat > "$expected" <<'EXPECTED'
sync --reconcile
issues activate TEST-1 --agent dev
cache issues get TEST-1
cache comments list TEST-1
EXPECTED
    if ! cmp -s "$expected" "$COMMAND_LOG"; then
        diff -u "$expected" "$COMMAND_LOG" >&2 || true
        fail "$1"
    fi
    printf 'ok - %s\n' "$1"
}

# Fresh worktree: sync creates the absent cache before reads.
rm -f "$CACHE_META" "$COMMAND_LOG"
run_linear_sequence > "$tmp/fresh.out" 2> "$tmp/fresh.err"
assert_linear_log 'fresh missing cache syncs before successful reads'
if ! grep -Fq '"id":"TEST-1"' "$tmp/fresh.out"; then
    fail 'successful sync/read did not return issue context'
fi
printf 'ok - successful sync/read returns issue context\n'

# Existing verified cache: session-start reconcile still runs before reads.
printf '%s\n' '{"synced_at":"2026-07-14T00:00:00Z"}' > "$CACHE_META"
rm -f "$COMMAND_LOG"
run_linear_sequence > "$tmp/existing.out" 2> "$tmp/existing.err"
assert_linear_log 'existing cache is reconciled and then read'

# Auth/API failure: stop at sync and never fall through to cache reads.
rm -f "$CACHE_META" "$COMMAND_LOG"
set +e
(export LINEAR_STUB_MODE=auth-failure; set -e; run_linear_sequence) \
    > "$tmp/auth.out" 2> "$tmp/auth.err"
auth_rc=$?
set -e
if [ "$auth_rc" -ne 19 ]; then
    fail "auth failure returned $auth_rc instead of 19"
fi
if [ "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" -ne 1 ]; then
    fail 'auth failure continued beyond sync'
fi
if ! grep -Fq 'Authentication failed' "$tmp/auth.err"; then
    fail 'auth failure diagnostic was not preserved'
fi
if grep -Fq 'No cache found' "$tmp/auth.err"; then
    fail 'auth failure was misreported as a missing cache'
fi
printf 'ok - sync/auth failure stops before activation and cache reads\n'

# GitHub path: its documented block contains only the GitHub lookup.
github_section="$tmp/github-section.md"
sed -n '/^GitHub only:/,/^Ad-hoc:/p' "$WORKFLOW" > "$github_section"
if grep -Fq 'linear.sh' "$github_section"; then
    fail 'GitHub tracker path contains a Linear command'
fi
if ! grep -Fq 'gh issue view [N] --repo [OWNER/REPO]' "$github_section"; then
    fail 'GitHub tracker path lost its issue lookup'
fi
printf 'ok - GitHub tracker path performs no Linear work\n'

printf 'all pass\n'
