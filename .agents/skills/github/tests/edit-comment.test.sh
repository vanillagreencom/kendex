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
#   err    stderr reduced: the JSON `.error` up to its first parenthesis,
#          then `detail=<endpoint>=<response>` per carried attempt with each
#          response's whitespace squeezed to single spaces; `-` when empty
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
TMP_ROOT="$(mktemp -d)"
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
    # id it owns, so it is reported rather than retried elsewhere.
    gh_stub_fail "api:$ISSUE_PATH" 1 'gh: Validation Failed (HTTP 422)'
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
  jq -r '(.error | split(" (")[0])
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
a non-numeric id is refused before the repository is resolved^r2633519824 Fixed^1^-^Comment ID must be numeric: r2633519824^-
"

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
the issue endpoint's own error is reported and the pulls endpoint is not asked^2633519824 Fixed^1^-^Failed to edit comment: gh: Validation Failed^repo,api:$ISSUE_PATH
"

# mutate LABEL FROM TO — a copy of edit-comment.sh beside a copy of the lib,
# with every FROM replaced by TO. The replacement's occurrence count is
# asserted in both directions, so a call site that moved leaves the control
# refusing rather than silently testing an unmutated file.
MUTANT_DIR="$TMP_ROOT/mutant"
PREDICATE='gh_error_is_not_found "$result"'
mutate() {
  local label="$1" from="$2" to="$3" dir
  dir="$MUTANT_DIR/$label"
  rm -rf "$dir"
  mkdir -p "$dir/commands"
  cp -R "$REPO_ROOT/skills/github/scripts/lib" "$dir/lib"
  cp "$EDIT_COMMENT" "$dir/commands/edit-comment.sh"
  assert_eq "$(grep -Fc -- "$from" "$dir/commands/edit-comment.sh")" "2" \
    "control $label finds both live predicate call sites"
  sed -i.bak "s|$from|$to|g" "$dir/commands/edit-comment.sh"
  assert_eq "$(grep -Fc -- "$from" "$dir/commands/edit-comment.sh")" "0" \
    "control $label applied the mutation"
  SUBJECT="$dir/commands/edit-comment.sh"
}

echo "=== must-fail control: the predicate never fires ==="
# `false` where the predicate stood leaves the pulls call and the keyed
# refusal in the file and unreachable, which is the pre-fix behaviour: the
# issue endpoint's 404 is the final answer.
mutate never "$PREDICATE" 'false'
SCENARIO="review-comment"
build
GOT="$(run '2633519824 Fixed')"
assert_eq "$GOT" \
  "rc=1 out=- err=Failed to edit comment: gh: Not Found calls=repo,api:$ISSUE_PATH" \
  "must-fail control: without the fallback a review comment id answers a bare 404"
SCENARIO="no-such-comment"
build
GOT="$(run '2633519824 Fixed')"
SUBJECT=""
assert_eq "$GOT" \
  "rc=1 out=- err=Failed to edit comment: gh: Not Found calls=repo,api:$ISSUE_PATH" \
  "must-fail control: without the predicate an unknown id answers a bare 404, not the keyed line"

echo "=== must-fail control: the predicate always fires ==="
# `true` where the predicate stood makes every failure look like a 404, so the
# 422 the issue endpoint owns is retried at the pulls endpoint and then
# reported as an unknown id — a named cause replaced by a wrong one.
mutate always "$PREDICATE" 'true'
SCENARIO="issue-endpoint-broken"
build
GOT="$(run '2633519824 Fixed')"
SUBJECT=""
assert_eq "$GOT" \
  "rc=1 out=- err=$REFUSAL detail=issues=gh: Validation Failed (HTTP 422) pulls=gh-stub: nothing staged for api (argv: api -X PATCH $PULLS_PATH -f body=Fixed) calls=repo,api:$ISSUE_PATH,api:$PULLS_PATH" \
  "must-fail control: treating every failure as a 404 retries a 422 and renames its cause"

echo "=== the predicate's own reach ==="
# The lib is the one home for the judgment, and label-add's repository-label
# lookup asks it too; a second inline spelling of it is the defect the helper
# exists to prevent.
assert_eq "$(grep -rlF 'HTTP 404|"status"' "$REPO_ROOT/skills/github/scripts" | sed "s|$REPO_ROOT/||" | sort | paste -s -d ' ' -)" \
  "skills/github/scripts/commands/label-add.sh skills/github/scripts/lib/github-api.sh" \
  "the 404 pattern is written in the lib and in label-add's wider permission question, nowhere else"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
