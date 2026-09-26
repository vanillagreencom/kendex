#!/usr/bin/env bash
# User-facing tests for sticky-comment.sh and find-comment.sh fallback
# behavior.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$TEST_DIR/fixtures"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
STICKY="$REPO_ROOT/skills/github/scripts/commands/sticky-comment.sh"
FIND_COMMENT="$REPO_ROOT/skills/github/scripts/commands/find-comment.sh"

PASS=0
FAIL=0
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

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

assert_fails_with() {
    local name="$1" needle="$2"
    shift 2
    local out status
    set +e
    out=$("$@" 2>&1)
    status=$?
    set -e
    if [[ $status -ne 0 && "$out" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
        printf '  ok    %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf '  FAIL  %s\n        expected failure containing: %s\n        status: %s\n        output: %s\n' "$name" "$needle" "$status" "$out"
    fi
}

# The shared `gh` fake. The comment endpoints are staged under both the
# templated and the expanded spelling, because the CLI reaches them both
# ways and neither spelling is what these tests are about. The stub ships
# beside this test in both the source package and its render.
# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMPDIR/gh-stub" gh_stub_install "$TMPDIR"

gh_stub_answer 'api-repos/{owner}/{repo}/issues/123/comments' \
  "$(cat "$FIXTURES/mixed_bot_comments.json")"
gh_stub_answer 'api-repos/owner/repo/issues/123/comments' \
  "$(cat "$FIXTURES/mixed_bot_comments.json")"
gh_stub_answer 'api-repos/owner/repo/issues/124/comments' \
  "$(cat "$FIXTURES/codex_own_comment.json")"

export PATH="$TMPDIR:$PATH"
unset GH_BOT_USERNAME || true

echo "=== sticky-comment.sh CLI fallback ==="
out=$("$STICKY" 123 --verdict)
assert_eq "$out" "approved" "default fallback selects known claude[bot] review summary"

out=$("$STICKY" 123 --legacy-extra ignored --verdict)
assert_eq "$out" "approved" \
    "legacy parser accepts unknown flags and ignores surplus positionals"

assert_fails_with \
    "explicit --bot disables known-bot fallback" \
    "No sticky comment found" \
    "$STICKY" 123 --verdict --bot 'review-bot[bot]'

echo
echo "=== sticky-comment.sh refusal carries a response excerpt ==="
# A refusal quotes the first 200 characters of the response, newlines read as
# spaces, and the rest is dropped. LONG_TEXT is 20-character lines holding a
# double quote, far past a pipe buffer, so an excerpt taken by piping the
# response into an early-closing reader fails its writer: with SIGPIPE ignored
# as below, that writer's error lands on stderr beside the refusal.
LINE='gh: "quoted" failed'
LONG_TEXT="$(for _ in $(seq 16384); do printf '%s\n' "$LINE"; done)"
EXCERPT=""
for _ in $(seq 10); do EXCERPT="$EXCERPT$LINE "; done
gh_stub_fail 'api-repos/{owner}/{repo}/issues/125/comments' 1 "$LONG_TEXT"
gh_stub_answer 'api-repos/{owner}/{repo}/issues/126/comments' "$LONG_TEXT"

# A row is `label^pr^want`: want is the refusal's whole `.error`.
ROWS="\
a failed fetch refuses with the response excerpt^125^API failed: $EXCERPT
a fetch answering non-JSON refuses with the bare excerpt^126^$EXCERPT"
before=$((PASS + FAIL))
while IFS='^' read -r label pr want; do
    rc=0
    (trap '' PIPE; "$STICKY" "$pr" --verdict) >/dev/null 2>"$TMPDIR/stderr" || rc=$?
    # Slurped, so a second line or a writer's error fails the row as surely as
    # a wrong excerpt.
    got="rc=$rc $(jq -sc '.' <"$TMPDIR/stderr" 2>/dev/null ||
        printf 'unparseable: %s' "$(head -c 300 "$TMPDIR/stderr")")"
    assert_eq "$got" "rc=1 $(jq -nc --arg e "$want" '[{error: $e}]')" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt "$before" ]] || {
    echo "no refusal row was asserted" >&2
    exit 2
}

echo
echo "=== find-comment.sh review-summary ==="
out=$("$FIND_COMMENT" 124 --author 'chatgpt-codex-connector[bot]' --review-summary)
assert_eq "$(jq -r .id <<<"$out")" "4001" "find-comment review-summary returns Codex earliest comment"
assert_eq "$(jq -r .author <<<"$out")" "chatgpt-codex-connector[bot]" "find-comment review-summary preserves Codex author"
out=$("$FIND_COMMENT" 124 --author 'missing-reviewer[bot]' --review-summary)
assert_eq "$out" "{}" "find-comment review-summary no-match returns empty object"

echo
echo "----"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
