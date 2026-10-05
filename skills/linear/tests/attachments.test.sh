#!/usr/bin/env bash
# `attachments list` reads, live, every uploads.linear.app file an issue
# references: its attachment records first, then links in its description and
# comments that no record already names, a bare link without the prose
# punctuation after it. `attachments fetch` refuses a URL on any other host
# before it sends a credential, and sends a rate-limited, 5xx or unanswered
# download again as every Linear request is sent again. The download's
# credential and its renewal are oauth-auth.test.sh's.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
# One issue: a record for plan.md and one for a GitHub pull request, a
# description linking plan.md again and an image, a comment linking a log, and
# a comment of bare links each followed by prose punctuation, then two
# Markdown link destinations that end in punctuation of their own.
# Linear answers KEN-404 with no issue.
# The upload server gives the answers DOWNLOAD_RESPONSES lists in turn, `;`
# between them: a status, or `000` for no answer, and after an `@` the
# Retry-After value it carries. A 429 names the time its quota refills.
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
printf '%s\n' "$config" >>"$CALLS"
if [[ "$config" == *'url = "https://uploads.linear.app/'* ]]; then
    n=$(grep -c '^url = "https://uploads.linear.app/' "$CALLS")
    IFS=';' read -r -a answers <<<"$DOWNLOAD_RESPONSES"
    answer="${answers[n-1]}"
    code="${answer%%@*}"
    [[ "$code" != 000 ]] || exit 7
    format=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -o) printf 'body of answer %s\n' "$n" >"$2"; shift 2 ;;
        -w) format="$2"; shift 2 ;;
        *) shift ;;
        esac
    done
    printf 'HTTP/1.1 %s Fixture\r\n' "$code"
    [[ "$answer" != *@* ]] || printf 'Retry-After: %s\r\n' "${answer#*@}"
    [[ "$code" != 429 ]] || printf 'X-RateLimit-Requests-Reset: 1791217043000\r\n'
    printf '\r\n%s' "${format/\%\{http_code\}/$code}"
    exit 0
fi
if [[ "$(sed -n 's/^data = //p' <<<"$config" | jq -r 'fromjson | .variables.id // ""')" == KEN-404 ]]; then
    printf '{"data":{"issue":null}}___HTTP_CODE___200'
    exit 0
fi
conn() { printf '{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":%s}' "$1"; }
records=$(conn '[{"id":"a1","url":"https://uploads.linear.app/o/p/plan.md","title":"docs/plans/plan.md"},{"id":"a2","url":"https://github.com/o/r/pull/1","title":"PR"}]')
prose='Plan https://uploads.linear.app/o/t/a.txt. Then https://uploads.linear.app/o/t/b.txt, https://uploads.linear.app/o/t/c.txt: https://uploads.linear.app/o/t/d.txt; https://uploads.linear.app/o/t/e.txt! https://uploads.linear.app/o/t/f.txt? **https://uploads.linear.app/o/t/g.txt**. _https://uploads.linear.app/o/t/h.txt_ ~https://uploads.linear.app/o/t/i.txt~ [x](https://uploads.linear.app/o/w/draft.) [y](<https://uploads.linear.app/o/w/note!>)'
comments=$(conn "$(jq -cn --arg prose "$prose" '[{id: "c1", body: "log at https://uploads.linear.app/o/q/run.log?x=1"}, {id: "c2", body: $prose}]
    | map(. + {createdAt: "2026-10-01T00:00:00.000Z", updatedAt: "2026-10-01T00:00:00.000Z", user: {name: "Fixture Person"}})')")
description='See https://uploads.linear.app/o/p/plan.md. And ![s](<https://uploads.linear.app/o/i/shot.png>)'
jq -cjn --argjson records "$records" --argjson comments "$comments" --arg d "$description" \
    '{data: {issue: {id: "uuid-1", identifier: "KEN-1", description: $d, attachments: $records, comments: $comments}}}'
printf '___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

run_attachments() {
    : >"$TMP_ROOT/calls"
    RC=0
    OUT=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        SLEPT="$TMP_ROOT/slept" DOWNLOAD_RESPONSES="${DOWNLOAD_RESPONSES:-}" \
        LINEAR_API_KEY_OVERRIDE=test-key bash .agents/skills/linear/scripts/linear.sh attachments "$@" \
        2>"$TMP_ROOT/err") || RC=$?
}

run_attachments list KEN-1
assert_eq "list: succeeds" "$RC" 0
assert_jq "list: the record comes first with its repository path" "$OUT" \
    '.[0] == {url: "https://uploads.linear.app/o/p/plan.md", source: "KEN-1", context: "attachment", filename: "plan.md", repo_path: "docs/plans/plan.md"}'
assert_jq "list: a record and a link with one url list once" "$OUT" \
    '[.[] | select(.url == "https://uploads.linear.app/o/p/plan.md")] | length == 1'
assert_jq "list: links name their context and file" "$OUT" \
    '[.[] | select(.url | test("/o/[iq]/")) | [.context, .filename, .repo_path]] == [["description", "shot.png", null], ["comment", "run.log", null]]'
assert_jq "list: a bare link drops trailing prose punctuation" "$OUT" \
    '[.[] | select(.url | contains("/o/t/")) | [.url, .filename]]
     == [range(0; 9) | [97 + .] | implode | ["https://uploads.linear.app/o/t/" + . + ".txt", . + ".txt"]]'
assert_jq "list: a Markdown link destination keeps its url as written" "$OUT" \
    '[.[] | select(.url | contains("/o/w/")) | .url] == ["https://uploads.linear.app/o/w/draft.", "https://uploads.linear.app/o/w/note!"]'
assert_jq "list: a record off the upload host is left out" "$OUT" 'all(.[]; .url | startswith("https://uploads.linear.app/"))'

run_attachments list KEN-404
assert_eq "list of a missing issue: refuses" "$RC" 1
assert_eq "list of a missing issue: prints nothing" "$OUT" ''
assert_file_contains "list of a missing issue: names the issue" "$TMP_ROOT/err" 'Issue not found: KEN-404'

run_attachments fetch https://example.invalid/file.txt --output "$TMP_ROOT/out.txt"
assert_eq "foreign host: refuses" "$RC" 1
assert_not "foreign host: sends no request" test -s "$TMP_ROOT/calls"
assert_not "foreign host: writes no file" test -e "$TMP_ROOT/out.txt"

run_attachments fetch https://uploads.linear.app/o/p/plan.md
assert_eq "fetch without --output: refuses" "$RC" 1
assert_not "fetch without --output: sends no request" test -s "$TMP_ROOT/calls"

# What the download waited is read off a sleep stub, at the default one-second
# base delay. Each row: label, the upload server's answers, the exit status,
# the downloads sent, the waits, and the requests_reset of the RATELIMITED
# line a final 429 prints, empty when no such line is due.
cat >"$TMP_ROOT/bin/sleep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$SLEPT"
STUB
chmod +x "$TMP_ROOT/bin/sleep"
for row in \
    'a 503 is retried|503;200|0|2|1|' \
    'a rate-limited download is retried|429;200|0|2|1|' \
    'an unanswered download is retried|000;200|0|2|1|' \
    'a download fails after two retries|503;503;503;200|1|3|1 2|' \
    'a download rate-limited past its retries reports the rate limit|429;429;429;200|1|3|1 2|2026-10-05T16:17:23Z' \
    'a 404 fails on its first answer|404;200|1|1||' \
    'a Retry-After within the bound is waited out|429@5;200|0|2|5|' \
    'a Retry-After at the bound is waited out|503@60;200|0|2|60|' \
    'a Retry-After past the bound fails at once|429@61;200|1|1||2026-10-05T16:17:23Z' \
    'a 503 Retry-After past the bound is no rate limit|503@61;200|1|1||' \
    'a Retry-After shorter than the backoff waits the backoff|503;503@1;200|0|3|1 2|' \
    'an HTTP-date Retry-After waits the backoff|503@Wed, 21 Oct 2026 07:28:00 GMT;200|0|2|1|'; do
    IFS='|' read -r label DOWNLOAD_RESPONSES expected_rc downloads waits reset <<<"$row"
    rm -f -- "${TMP_ROOT:?}/out.txt"
    : >"$TMP_ROOT/slept"
    run_attachments fetch https://uploads.linear.app/o/p/plan.md --output "$TMP_ROOT/out.txt"
    assert_eq "$label: result" "$RC" "$expected_rc"
    assert_eq "$label: attempts" "$(grep -c '^url = ' "$TMP_ROOT/calls")" "$downloads"
    assert_eq "$label: waits" "$(paste -sd ' ' "$TMP_ROOT/slept")" "$waits"
    # linear.sh's callers parse this line to hold a write until the reset.
    quota=$(jq -c 'select(type == "object" and .code == "RATELIMITED")' "$TMP_ROOT/err" 2>/dev/null || true)
    if [[ -n "$reset" ]]; then
        assert_jq "$label: rate limit" "$quota" ".requests_reset == \"$reset\""
    else
        assert_eq "$label: rate limit" "$quota" ''
    fi
    if [[ "$expected_rc" == 0 ]]; then
        assert_eq "$label: the file is the last answer's" "$(cat "$TMP_ROOT/out.txt")" "body of answer $downloads"
    else
        assert_not "$label: writes no file" test -e "$TMP_ROOT/out.txt"
    fi
    assert_eq "$label: leaves no partial file" \
        "$(find "$TMP_ROOT" -maxdepth 1 -name 'out.txt.*' | wc -l | tr -d ' ')" 0
done
