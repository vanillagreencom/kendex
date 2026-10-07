#!/usr/bin/env bash
# pr-data reads files, PR-level comments, review threads and each thread's
# comments to completeness. A caller reads its output as the whole PR, so a
# file, comment or reply past a page boundary that went missing would let a
# review read as done on partial evidence.
#
# The stub serves every connection from a count, in pages the size the query
# asks for, so a fixture just past each GitHub page (101 files, 51 PR
# comments, 11 comments on one thread, 101 threads) reaches the boundary the
# script must walk across.
set -euo pipefail
# The fixture repository must be the one git reads, whatever the caller exports.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
SCRIPTS="$REPO_ROOT/skills/github/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "pr-data-paging: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "pr-data-paging: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "pr-data-paging: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
eq()  { [[ "$1" == "$2" ]] && ok "$3" || bad "$3" "expected: $2  got: $1"; }

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q
# The EXIT trap removes this repository, so git's background writers stay off.
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
STUB_LOG="$TMP_ROOT/calls.log"
export STUB_LOG

# Counts: STUB_FILES, STUB_COMMENTS, STUB_THREADS, STUB_THREAD_COMMENTS (on
# the first thread; every other thread holds one). A case that plants a bad
# page sets STUB_BREAK_KIND, STUB_BREAK_CURSOR and STUB_BREAK_DATA: the first
# call of that kind after that cursor returns STUB_BREAK_DATA as its `data`,
# and a repeat of it gets the real page, so a walk that should have stopped
# ends with output instead of spinning to the page bound.
cat >"$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
    "auth status") echo "Logged in"; exit 0 ;;
    "repo view")   echo 'owner/repo'; exit 0 ;;
    "api graphql") ;;
    *) printf 'unexpected gh call: %s\n' "$*" >&2; exit 1 ;;
esac
query="" cursor=""
for a in "$@"; do
    case "$a" in
        query=*)  query="${a#query=}" ;;
        cursor=*) cursor="${a#cursor=}" ;;
    esac
done
case "$query" in
    *reviewThreads*) kind=threads ;;
    *"node(id"*)     kind=thread-comments ;;
    *"files("*)      kind=files ;;
    *"comments("*)   kind=comments ;;
    *)               kind=header ;;
esac
printf '%s %s\n' "$kind" "$cursor" >>"$STUB_LOG"
if [ "$kind" = "${STUB_BREAK_KIND:-}" ] && [ "$cursor" = "${STUB_BREAK_CURSOR:-}" ] \
    && [ "$(grep -cxF -- "$kind $cursor" "$STUB_LOG")" = 1 ]; then
    printf '{"data":%s}\n' "$STUB_BREAK_DATA"
    exit 0
fi
off=0
[ -z "$cursor" ] || off="${cursor#C}"
jq -cn --arg kind "$kind" --argjson off "$off" \
    --argjson files "${STUB_FILES:-0}" --argjson comments "${STUB_COMMENTS:-0}" \
    --argjson threads "${STUB_THREADS:-0}" --argjson tc "${STUB_THREAD_COMMENTS:-1}" '
    def conn($total; $size; $off; f):
        ([$off + $size, $total] | min) as $end
        | {pageInfo: {hasNextPage: ($end < $total),
                      endCursor: (if $end < $total then "C\($end)" else null end)},
           nodes: [range($off; $end) | f]};
    def tcomment: {author: {login: "rev"}, body: "t\(.)", url: "https://x/pull/7#discussion_r\(1000 + .)"};
    def thread: {id: "PRRT_\(.)", isResolved: false, isOutdated: false, path: "a.rs", line: 1,
                 comments: conn(if . == 0 then $tc else 1 end; 10; 0; tcomment)};
    {data: (
      if $kind == "header" then {repository: {pullRequest: {number: 7, title: "T", headRefName: "b"}}}
      elif $kind == "files" then {repository: {pullRequest: {files: conn($files; 100; $off; {path: "f\(.).rs"})}}}
      elif $kind == "comments" then {repository: {pullRequest: {comments: conn($comments; 100; $off;
            {id: "IC_\(.)", author: {login: "u"}, body: "c\(.)", url: "https://x/c\(.)", createdAt: "2025-01-01T00:00:00Z"})}}}
      elif $kind == "threads" then {repository: {pullRequest: {reviewThreads: conn($threads; 100; $off; thread)}}}
      else {node: {comments: conn($tc; 100; $off; tcomment)}}
      end)}'
EOF
chmod +x "$TMP_ROOT/bin/gh"

ERR="$TMP_ROOT/err"
run() { # $1 = scripts dir, rest = pr-data args
    local dir="$1"; shift
    : >"$STUB_LOG"
    ( cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" GH_TOKEN=stub bash "$dir/commands/pr-data.sh" 7 "$@" 2>"$ERR" )
}
counts() { # files, PR comments, threads, first thread's comments
    jq -r '"\(.files|length) \(.comments|length) \(.threads|length) \(.threads[0].comments|length)"' <<<"$1"
}

echo "=== inside the limits: the output keeps its shape ==="

export STUB_FILES=2 STUB_COMMENTS=1 STUB_THREADS=1 STUB_THREAD_COMMENTS=2
out="$(run "$SCRIPTS" --format=raw)"
eq "$(jq -c '.repository.pullRequest' <<<"$out")" \
'{"number":7,"title":"T","headRefName":"b","files":{"nodes":[{"path":"f0.rs"},{"path":"f1.rs"}]},"comments":{"nodes":[{"id":"IC_0","author":{"login":"u"},"body":"c0","url":"https://x/c0","createdAt":"2025-01-01T00:00:00Z"}]},"reviewThreads":{"nodes":[{"id":"PRRT_0","isResolved":false,"isOutdated":false,"path":"a.rs","line":1,"comments":{"nodes":[{"author":{"login":"rev"},"body":"t0","url":"https://x/pull/7#discussion_r1000"},{"author":{"login":"rev"},"body":"t1","url":"https://x/pull/7#discussion_r1001"}]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}' \
  "raw carries no pageInfo on files, comments or thread comments"
grep -q '^thread-comments' "$STUB_LOG" && bad "no thread comment follow-up inside the limits" "$(cat "$STUB_LOG")" \
  || ok "no thread comment follow-up inside the limits"

out="$(run "$SCRIPTS")"
eq "$(jq -c '.threads[0].comments[1]' <<<"$out")" \
  '{"author":"rev","body":"t1","url":"https://x/pull/7#discussion_r1001","reply_id":"1001"}' \
  "safe thread comments keep their shape"
eq "$(jq -c 'keys' <<<"$out")" '["branch","comments","files","number","threads","title"]' "safe keeps its keys"
out="$(run "$SCRIPTS" --actionable)"
eq "$(counts "$out")" "2 1 1 2" "actionable inside the limits"

echo
echo "=== past each limit: the output is complete ==="

# Each row sits one past a page: 101 files and 101 threads past GitHub's 100,
# 51 PR comments past the old fixed 50, 11 thread comments past the 10 the
# thread page carries, 230 to cross a follow-up page too.
while IFS='|' read -r name f c t tc want; do
    STUB_FILES=$f STUB_COMMENTS=$c STUB_THREADS=$t STUB_THREAD_COMMENTS=$tc
    rc=0; out="$(run "$SCRIPTS")" || rc=$?
    eq "$rc $(counts "$out")" "0 $want" "$name"
done <<'ROWS'
101 files|101|1|1|1|101 1 1 1
251 files|251|1|1|1|251 1 1 1
51 PR comments|2|51|1|1|2 51 1 1
11 comments on one thread|2|1|1|11|2 1 1 11
230 comments on one thread|2|1|1|230|2 1 1 230
101 threads|2|1|101|1|2 1 101 1
ROWS

STUB_FILES=101 STUB_COMMENTS=51 STUB_THREADS=1 STUB_THREAD_COMMENTS=11
out="$(run "$SCRIPTS")"
eq "$(jq -r '.files[100]' <<<"$out")" "f100.rs" "the 101st file is the one past the page"
eq "$(jq -r '[.threads[0].comments[].body] | join(",")' <<<"$out")" \
  "t0,t1,t2,t3,t4,t5,t6,t7,t8,t9,t10" "thread comments keep their order across pages"
eq "$(jq -r '.threads[0].comments[10].reply_id' <<<"$out")" "1010" "a follow-up comment carries its reply id"
out="$(run "$SCRIPTS" --format=raw)"
eq "$(jq -c '[.repository.pullRequest.reviewThreads.nodes[0].comments | keys]' <<<"$out")" '[["nodes"]]' \
  "raw thread comments past the limit carry no pageInfo"

echo
echo "--- must-fail controls: a walk cut short reads as incomplete ---"

# shellcheck source=lib/mutant-copy.sh
. "$TEST_DIR/lib/mutant-copy.sh"
mutant() { # NAME FROM TO FILE: prints the scripts dir of a copy with that one line replaced
    mutant_copy_edit "$TMP_ROOT/mut-$1" "$2" "$3" "$4" >/dev/null
    printf '%s\n' "$TMP_ROOT/mut-$1/skills/github/scripts"
}
STUB_FILES=101 STUB_COMMENTS=51 STUB_THREADS=1 STUB_THREAD_COMMENTS=11
dir="$(mutant one-page '        [ "$has_next" = "true" ] || break' '        break' lib/github-api.sh)"
out="$(run "$dir")" || true
eq "$(counts "$out")" "100 51 1 11" "control: a one-page connection walk loses the 101st file"
dir="$(mutant no-follow-up '        | select(.value.comments.pageInfo.hasNextPage)' '        | select(false)' commands/pr-data.sh)"
out="$(run "$dir")" || true
eq "$(counts "$out")" "101 51 1 10" "control: no thread follow-up loses the 11th comment"

echo
echo "--- fail-closed: an unverifiable page prints nothing ---"

# A refusal is judged by what a caller sees and where the walk stopped, never
# by its wording: a non-zero status, nothing on stdout, a JSON error object on
# stderr, and the planted page as the last call, made once. A walk that went
# on past the planted page, or asked for it again, did not refuse it.
closed_at() { # SCRIPTS KIND CURSOR DATA: status 0 when refused at the planted page
    local out rc=0 seen
    out="$(export STUB_BREAK_KIND="$2" STUB_BREAK_CURSOR="$3" STUB_BREAK_DATA="$4"; run "$1")" || rc=$?
    [[ "$rc" -ne 0 && -z "$out" ]] || return 1
    jq -e '(.error | type) == "string"' "$ERR" >/dev/null 2>&1 || return 1
    [[ "$(tail -n 1 -- "$STUB_LOG")" == "$2 $3" ]] || return 1
    seen="$(grep -cxF -- "$2 $3" "$STUB_LOG")" || return 1
    [[ "$seen" == 1 ]]
}

# Each guard's control is a copy with that guard's line disabled: the cases
# that guard owns must then stop reading as refused, so no neighbouring rule
# is what refuses them.
PAGE_CHECK="$(mutant page-check "        if ! jq -e \"\$path\"' as \$t" "        if false && ! jq -e \"\$path\"' as \$t" lib/github-api.sh)"
ADVANCE_CHECK="$(mutant advance-check '        if [ "$next_cursor" = "$cursor" ]; then' '        if false; then' lib/github-api.sh)"
THREAD_CHECK="$(mutant thread-check "    if ! jq -e 'all(.[];" "    if false && ! jq -e 'all(.[];" commands/pr-data.sh)"

THREAD_NO_CURSOR='{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_0","comments":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":null}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
THREAD_NO_PAGEINFO='{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"PRRT_0","comments":{"nodes":[]}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}'
COMMENTS_STALL='{"repository":{"pullRequest":{"comments":{"nodes":[],"pageInfo":{"hasNextPage":true,"endCursor":"C100"}}}}}'
FILES_NULL='{"repository":{"pullRequest":{"files":null}}}'
THREADS_NULL='{"repository":{"pullRequest":{"reviewThreads":null}}}'
NODE_NULL='{"node":null}'

# name | guard | files comments threads thread-comments | kind | cursor | page data variable
while IFS='|' read -r name guard sizes kind cursor data; do
    read -r STUB_FILES STUB_COMMENTS STUB_THREADS STUB_THREAD_COMMENTS <<<"$sizes"
    closed_at "$SCRIPTS" "$kind" "$cursor" "${!data}" && ok "$name" || bad "$name" "rc/out/log: $(cat "$STUB_LOG")"
    closed_at "${!guard}" "$kind" "$cursor" "${!data}" \
      && bad "control: without the $guard guard, $name is not refused" "still refused" \
      || ok "control: without the $guard guard, $name is not refused"
done <<'ROWS'
a malformed second files page|PAGE_CHECK|101 51 1 11|files|C100|FILES_NULL
a malformed second review thread page|PAGE_CHECK|2 1 101 1|threads|C100|THREADS_NULL
a thread comment follow-up page that is not a thread|PAGE_CHECK|2 1 1 11|thread-comments|C10|NODE_NULL
a PR comments cursor that does not advance|ADVANCE_CHECK|2 101 1 1|comments|C100|COMMENTS_STALL
a thread whose comment page says more follow without a cursor|THREAD_CHECK|2 1 1 1|threads||THREAD_NO_CURSOR
a thread with no comment pageInfo|THREAD_CHECK|2 1 1 1|threads||THREAD_NO_PAGEINFO
ROWS

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
