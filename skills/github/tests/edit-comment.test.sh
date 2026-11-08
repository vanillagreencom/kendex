#!/usr/bin/env bash
# edit-comment: a comment id carries no marker of which endpoint owns it, so
# the issue-comments endpoint answers first and a 404 there sends the id to
# the review-comments endpoint. Contract and endpoint order: `edit-comment
# --help`.
#
# A row is `label^argv^rc^out^err^calls`, separated by `^` because a field
# carries the refusal's `use=find-comment|comment-url` verbatim:
#   argv   edit-comment's arguments as written
#   rc     the exit status
#   out    stdout reduced: a dry run as `dry id=<id>`, an edit as
#          `success=<bool> url=<url>`; `-` when empty
#   err    stderr reduced: the JSON `.error` up to its first parenthesis
#          where it leads with a `name: key=` line a program reads, `error`
#          where it is prose, then `detail=<endpoint>=<response>` per carried
#          attempt with each response's whitespace squeezed to single spaces;
#          `-` when empty
#   calls  every gh call by kind, in order (`auth`, `user`, `repo`,
#          `api:<path>`); `-` for none
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
EDIT_COMMENT="$REPO_ROOT/skills/github/scripts/commands/edit-comment.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'edit-comment: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'edit-comment: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'edit-comment: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf "$TMP_ROOT"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# The lib derives PROJECT_ROOT through git at source time, so the working
# directory is a repository; gh is the staged fake.
mkdir -p "$TMP_ROOT/repo" "$TMP_ROOT/bin"
git -C "$TMP_ROOT/repo" init -q
# The EXIT trap removes this tree, so git's background writer is disabled at
# creation rather than left to race the removal.
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"

ISSUE_PATH='repos/owner/repo/issues/comments/2633519824'
PULLS_PATH='repos/owner/repo/pulls/comments/2633519824'
ISSUE_URL='https://github.com/owner/repo/pull/23#issuecomment-2633519824'
REVIEW_URL='https://github.com/owner/repo/pull/23#discussion_r2633519824'

# The three shapes a 404 reaches the caller by. edit-comment captures the call
# with 2>&1, so gh's stderr line and the API's JSON body arrive as one text;
# the stub's stderr channel carries whatever a scenario says that text is.
# BODY_404 is the API's own body, verbatim but for the elided doc URL.
STDERR_404='gh: Not Found (HTTP 404)'
BROKEN_422='gh: Validation Failed (HTTP 422)'
BODY_404='{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
PAIR_404="$BODY_404
$STDERR_404"

# SCENARIO is which pair of endpoint answers a row runs against; SUBJECT is
# the script under test, so a control can point at a mutated copy.
SCENARIO="issue-comment"
SUBJECT=""

build() {
  gh_stub_reset
  case "$SCENARIO" in
  issue-comment)
    # The id is a PR-level comment: the first endpoint asked already has it.
    gh_stub_answer "api:$ISSUE_PATH" "{\"html_url\":\"$ISSUE_URL\"}"
    ;;
  review-comment)
    # The id is a comment inside a review thread, so only the pulls endpoint
    # holds it and the issue one answers 404 for it. gh's stderr line alone.
    gh_stub_fail "api:$ISSUE_PATH" 1 "$STDERR_404"
    gh_stub_answer "api:$PULLS_PATH" "{\"html_url\":\"$REVIEW_URL\"}"
    ;;
  review-comment-pair)
    # The same, with the capture a real `gh api` leaves: the API's JSON body
    # and gh's own stderr line together.
    gh_stub_fail "api:$ISSUE_PATH" 1 "$PAIR_404"
    gh_stub_answer "api:$PULLS_PATH" "{\"html_url\":\"$REVIEW_URL\"}"
    ;;
  review-comment-body-only)
    # The capture a caller gets when gh's stderr line is absent and only the
    # API's body says 404 — the shape the JSON alternative alone matches.
    gh_stub_fail "api:$ISSUE_PATH" 1 "$BODY_404"
    gh_stub_answer "api:$PULLS_PATH" "{\"html_url\":\"$REVIEW_URL\"}"
    ;;
  no-such-comment)
    gh_stub_fail "api:$ISSUE_PATH" 1 "$STDERR_404"
    gh_stub_fail "api:$PULLS_PATH" 1 "$STDERR_404"
    ;;
  issue-endpoint-broken)
    # A failure that is not a 404 is the issue endpoint's own answer about an
    # id it owns, so it is reported rather than retried elsewhere. The review
    # endpoint answers too, so the row asserting it is never asked holds on the
    # call list rather than on the stub refusing an unstaged call, and the
    # mutant that does ask it reads a real response.
    gh_stub_fail "api:$ISSUE_PATH" 1 "$BROKEN_422"
    gh_stub_fail "api:$PULLS_PATH" 1 "$BROKEN_422"
    ;;
  pulls-endpoint-broken)
    # The id is not at the issue endpoint, and the review one then fails some
    # other way: an oversized body, or a token that may not write review
    # comments. The first endpoint's 404 must not be lost behind that answer.
    gh_stub_fail "api:$ISSUE_PATH" 1 "$STDERR_404"
    gh_stub_fail "api:$PULLS_PATH" 1 "$BROKEN_422"
    ;;
  *)
    printf 'unknown scenario: %s\n' "$SCENARIO" >&2
    exit 1
    ;;
  esac
}

out_text() {
  local text
  text="$(cat "$TMP_ROOT/stdout")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  jq -r 'if .dry_run == true then "dry id=\(.comment_id)"
         else "success=\(.success) url=\(.url)" end' <<<"$text" 2>/dev/null ||
    printf '%s' "$text" | paste -s -d ';' -
}

err_text() {
  local text
  text="$(cat "$TMP_ROOT/stderr")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  jq -r '(.error | if test("^[a-z][a-z-]*: [a-z-]+=") then split(" (")[0] else "error" end)
         + (if .detail then
              " detail=" + ([.detail[]
                | .endpoint + "=" + (.response | gsub("\\s+"; " "))] | join(" "))
            else "" end)' <<<"$text" 2>/dev/null ||
    printf '%s' "$text" | paste -s -d ';' -
}

calls() {
  local line out=""
  while IFS= read -r line; do
    case "$line" in
    "auth status"*) out="$out,auth" ;;
    "api user"*) out="$out,user" ;;
    "repo view"*) out="$out,repo" ;;
    # `gh api -X PATCH <path> -f body=…`: the endpoint is the argument that
    # names it, not the first one, so the reducer reads past the flags to the
    # word starting `repos/`, and says so when the call carries none.
    "api "*" repos/"*)
      line="repos/${line#* repos/}"
      out="$out,api:${line%% *}"
      ;;
    "api "*) out="$out,api:?($line)" ;;
    *) out="$out,?($line)" ;;
    esac
  done < <(gh_stub_calls)
  [[ "$out" != "" ]] && printf '%s' "${out#,}" || printf -- '-'
}

run() {
  local rc=0
  local -a argv
  # shellcheck disable=SC2206
  argv=($1)
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO \
    "${SUBJECT:-$EDIT_COMMENT}" "${argv[@]}" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s calls=%s' "$rc" "$(out_text)" "$(err_text)" "$(calls)"
}

run_table() {
  local title="$1" rows="$2" label argv rc out err want got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='^' read -r label argv rc out err want <<<"$row"
    for field in "$label" "$argv" "$rc" "$out" "$err" "$want"; do
      [[ "$field" != "" ]] || {
        printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2
        exit 1
      }
    done
    build
    got="$(run "$argv")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "rc=$rc out=$out err=$err calls=$want" "$label"
  done <<<"$rows"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || {
    echo "no row was asserted (a probe run renders rows instead)" >&2
    exit 2
  }
}

SCENARIO="issue-comment"
run_table "an id the issue-comments endpoint holds" "\
the edit lands at the issue endpoint, and the pulls one is never asked^2633519824 Fixed^0^success=true url=$ISSUE_URL^-^repo,api:$ISSUE_PATH
a dry run edits nothing and asks no endpoint^2633519824 Fixed --dry-run^0^dry id=2633519824^-^repo
a non-numeric id is refused before the repository is resolved^12\"34 Fixed^1^-^error^-
--body as the last argument is refused, not left to the shell^2633519824 --body^1^-^error^-
--body-file as the last argument is refused, not left to the shell^2633519824 --body-file^1^-^error^-
"

echo "=== the shape of an argument refusal ==="
# The help says a refusal raised before any endpoint is asked carries {error}
# alone, while a refusal from an endpoint carries {error, detail}. The row
# above reads only .error, so the KEYS are pinned here: a wrapper iterating
# .detail[] on this output fails. The id also carries a double quote, so jq
# reading the stderr at all is the second thing this asserts — a refusal built
# by interpolating the value into the JSON text prints something jq refuses.
build
run '12"34 Fixed' >/dev/null
assert_eq "$(jq -c keys <"$TMP_ROOT/stderr" || printf 'stderr is not JSON')" \
  '["error"]' \
  "a refusal before any endpoint is {error} alone, and stays JSON with a quote in the value"

# One row per shape a 404 reaches the caller by, so the alternative that
# matches each is the only thing holding its row green.
SCENARIO="review-comment"
run_table "gh's stderr line alone sends the id on" "\
the 404 sends the id to the pulls endpoint and the edit lands^2633519824 Fixed^0^success=true url=$REVIEW_URL^-^repo,api:$ISSUE_PATH,api:$PULLS_PATH
"

SCENARIO="review-comment-pair"
run_table "the API body and gh's stderr line together send the id on" "\
the 404 sends the id to the pulls endpoint and the edit lands^2633519824 Fixed^0^success=true url=$REVIEW_URL^-^repo,api:$ISSUE_PATH,api:$PULLS_PATH
"

SCENARIO="review-comment-body-only"
run_table "the API body alone sends the id on" "\
the 404 sends the id to the pulls endpoint and the edit lands^2633519824 Fixed^0^success=true url=$REVIEW_URL^-^repo,api:$ISSUE_PATH,api:$PULLS_PATH
"

REFUSAL='github: comment-kind=unknown id=2633519824 use=find-comment|comment-url'
SCENARIO="no-such-comment"
run_table "an id neither endpoint holds" "\
both 404s are refused with the keyed line and both responses, not a bare 404^2633519824 Fixed^1^-^$REFUSAL detail=issues=$STDERR_404 pulls=$STDERR_404^repo,api:$ISSUE_PATH,api:$PULLS_PATH
"

SCENARIO="issue-endpoint-broken"
run_table "a failure that is not a 404" "\
the issue endpoint's own error is reported and the pulls endpoint is not asked^2633519824 Fixed^1^-^error detail=issues=$BROKEN_422^repo,api:$ISSUE_PATH
"

SCENARIO="pulls-endpoint-broken"
run_table "a 404 at the issue endpoint and another failure at the review one" "\
the review endpoint's own error is reported, and the issue endpoint's 404 is carried beside it^2633519824 Fixed^1^-^error detail=issues=$STDERR_404 pulls=$BROKEN_422^repo,api:$ISSUE_PATH,api:$PULLS_PATH
"

echo "=== must-fail control: the predicate never fires ==="
# A copy of edit-comment.sh beside a copy of the lib, with every predicate
# call replaced by `false`, which leaves the pulls call and the keyed refusal
# in the file and unreachable: the pre-fix behaviour, where the issue
# endpoint's 404 is the final answer. The replacement's occurrence count is
# asserted in both directions, so a call site that moved leaves the control
# refusing rather than silently testing an unmutated file.
MUTANT_DIR="$TMP_ROOT/mutant"
PREDICATE='gh_error_is_not_found "$result"'
mkdir -p "$MUTANT_DIR/commands"
cp -R "$REPO_ROOT/skills/github/scripts/lib" "$MUTANT_DIR/lib"
cp "$EDIT_COMMENT" "$MUTANT_DIR/commands/edit-comment.sh"
assert_eq "$(grep -Fc -- "$PREDICATE" "$MUTANT_DIR/commands/edit-comment.sh")" "2" \
  "control never finds both live predicate call sites"
sed -i.bak "s|$PREDICATE|false|g" "$MUTANT_DIR/commands/edit-comment.sh"
assert_eq "$(grep -Fc -- "$PREDICATE" "$MUTANT_DIR/commands/edit-comment.sh")" "0" \
  "control never applied the mutation"
SUBJECT="$MUTANT_DIR/commands/edit-comment.sh"
SCENARIO="review-comment"
build
GOT="$(run '2633519824 Fixed')"
SUBJECT=""
assert_eq "$GOT" \
  "rc=1 out=- err=error detail=issues=$STDERR_404 calls=repo,api:$ISSUE_PATH" \
  "must-fail control: without the fallback a review comment id answers a bare 404"

echo '=== shared REST failures use received evidence and bounded retries ==='
# Real GitHub error forms: REST troubleshooting documents the two permission
# messages and the primary/secondary response signals. gh api writes page
# bodies to stdout and failure diagnostics to stderr, including after a page.
# https://docs.github.com/en/rest/using-the-rest-api/troubleshooting-the-rest-api
# https://github.com/cli/cli/blob/trunk/pkg/cmd/api/api.go
# Fields: name ^ gh exit ^ stderr (printf %b) ^ category ^ calls
# ^ injected waits ^ successful stdout ^ prior page stdout (optional).
# Category is the machine-readable key
# in .error. Error JSON must contain only that key, never raw response text.
REST_ROWS='integration^1^gh: Resource not accessible by integration (HTTP 403)^permission^1^-^-
personal-token^1^{"message":"Resource not accessible by personal access token","status":403}^permission^1^-^-
primary-body^1^{"message":"API rate limit exceeded for test.","status":"403"}^primary-rate-limit^3^1,2,^-
primary-header^1^HTTP/2.0 429 Too Many Requests\r\nX-RateLimit-Remaining: 0\r\n^primary-rate-limit^3^1,2,^-
secondary^1^gh: You have exceeded a secondary rate limit. (HTTP 403)^secondary-rate-limit^3^1,2,^-
unknown-forbidden^1^{"message":"private-response-marker", "status" : "403"}^unknown^1^-^-
unknown-quota-kind^1^gh: Too Many Requests (HTTP 429)^unknown^3^1,2,^-
incidental-number^1^{"message":"private-response-marker 403 rate limit", "status":"500"}^unknown^3^1,2,^-
authentication^1^gh: Bad credentials (HTTP 401)^authentication^1^-^-
not-found^1^gh: Not Found (HTTP 404)^not-found^1^-^-
page-status^1^gh: API rate limit exceeded for test. (HTTP 403)^primary-rate-limit^3^1,2,^-^[{"body":"gh: Not Found (HTTP 404)"}]
page-permission^1^gh: Too Many Requests (HTTP 429)^unknown^3^1,2,^-^[{"body":"Resource not accessible by integration"}]
page-quota^1^gh: Forbidden (HTTP 403)^unknown^1^-^-^[{"body":"API rate limit exceeded for test."}]
success^0^{"id":403,"message":"rate limit"}^-^1^-^{"id":403,"message":"rate limit"}'

rest_run() {
  local lib="$1" code="$2" response="$3" page="${4:-}" rc=0 out err waits requests
  gh_stub_reset
  if [[ "$code" == 0 ]]; then
    gh_stub_answer api-rest-contract "$response"
  else
    gh_stub_fail api-rest-contract "$code" "$response" "$page"
  fi
  : >"$TMP_ROOT/rest.waits"
  (cd "$TMP_ROOT/repo" && PATH="$TMP_ROOT/bin:$PATH" env -u GITHUB_TOKEN -u GH_BOT_TOKEN \
    GH_TOKEN=dtn_REST "$BASH" -c '
      source "$1"
      sleep() { printf "%s," "$1" >>"$REST_WAITS"; }
      export REST_WAITS="$2"
      gh_rest rest-contract --paginate
    ' rest "$lib" "$TMP_ROOT/rest.waits" >"$TMP_ROOT/rest.out" 2>"$TMP_ROOT/rest.err") || rc=$?
  out="$(cat "$TMP_ROOT/rest.out")"
  err="$(cat "$TMP_ROOT/rest.err")"
  waits="$(cat "$TMP_ROOT/rest.waits")"
  requests="$(gh_stub_calls | wc -l | tr -d ' ')"
  if [[ -n "$err" ]]; then
    err="$(jq -er 'if keys == ["error"] and (.error | test("^github-rest: category=[a-z-]+$")) then .error | split("=")[1] else error("unsafe failure") end' <<<"$err" 2>/dev/null || printf invalid)"
  fi
  printf 'rc=%s category=%s calls=%s waits=%s out=%s' "$rc" "${err:--}" "$requests" "${waits:--}" "${out:--}"
}

REST_LIB="$REPO_ROOT/skills/github/scripts/lib/github-api.sh"
while IFS='^' read -r label code response category requests waits out page; do
  [[ -n "$label" ]] || continue
  response="$(printf '%b' "$response")"
  GOT="$(rest_run "$REST_LIB" "$code" "$response" "$page")"
  assert_eq "$GOT" "rc=$code category=$category calls=$requests waits=$waits out=$out" "REST $label"
done <<<"$REST_ROWS"

# Reuse the permission row and its expectation against the previous blanket
# decision, with the real retry loop and output writer still present.
. "$TEST_DIR/lib/mutant-copy.sh"
REST_MUTANT="$(mutant_copy_edit "$TMP_ROOT/rest-mutant" \
  '        if [ "$retry" = true ] && [ $attempt -lt $max_retries ]; then' \
  '        if [ "$status" = 403 ]; then category=primary-rate-limit; retry=true; fi; if [ "$retry" = true ] && [ $attempt -lt $max_retries ]; then' \
  lib/github-api.sh)"
while IFS='^' read -r label code response category requests waits out page; do
  [[ "$label" == integration ]] || continue
  GOT="$(rest_run "$REST_MUTANT" "$code" "$response")"
  WANT="rc=$code category=$category calls=$requests waits=$waits out=$out"
  [[ "$GOT" != "$WANT" ]] || { echo 'REST control accepted blanket 403' >&2; exit 1; }
  assert_eq "$GOT" 'rc=1 category=primary-rate-limit calls=3 waits=1,2, out=-' 'REST control reaches and rejects blanket 403'
done <<<"$REST_ROWS"

# Restore page evidence at the one classification boundary. The real prior
# payload, diagnostic, retries and output writer remain in this control.
REST_PAGE_MUTANT="$(mutant_copy_edit "$TMP_ROOT/rest-page-mutant" \
  '        response="$diagnostic"' \
  '        response="$response$diagnostic"' \
  lib/github-api.sh)"
while IFS='^' read -r label code response category requests waits out page; do
  [[ "$label" == page-status ]] || continue
  GOT="$(rest_run "$REST_PAGE_MUTANT" "$code" "$response" "$page")"
  WANT="rc=$code category=$category calls=$requests waits=$waits out=$out"
  [[ "$GOT" != "$WANT" ]] || { echo 'REST control accepted page evidence' >&2; exit 1; }
  assert_eq "$GOT" 'rc=1 category=not-found calls=1 waits=- out=-' 'REST control rejects successful-page evidence'
done <<<"$REST_ROWS"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
