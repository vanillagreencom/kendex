#!/usr/bin/env bash
# edit-comment: a comment id carries no marker of which endpoint owns it, so
# the issue-comments endpoint answers first and its 404 sends the id to the
# review-comments endpoint. An id neither endpoint holds is refused with one
# keyed line, never the bare 404 that sent callers back to the same guess.
#
# A row is `label|argv|rc|out|err|calls`:
#   argv   edit-comment's arguments as written
#   rc     the exit status
#   out    stdout reduced: a dry run as `dry id=<id>`, an edit as
#          `success=<bool> url=<url>`; `-` when empty
#   err    stderr's error clause, the JSON `.error` up to its first
#          parenthesis; `-` when stderr is empty
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
NOT_FOUND='gh: Not Found (HTTP 404)'

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
    # holds it and the issue one answers 404 for it.
    gh_stub_fail "api:$ISSUE_PATH" 1 "$NOT_FOUND"
    gh_stub_answer "api:$PULLS_PATH" "{\"html_url\":\"$REVIEW_URL\"}"
    ;;
  no-such-comment)
    gh_stub_fail "api:$ISSUE_PATH" 1 "$NOT_FOUND"
    gh_stub_fail "api:$PULLS_PATH" 1 "$NOT_FOUND"
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
  jq -r '.error | split(" (")[0]' <<<"$text" 2>/dev/null ||
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
    IFS='|' read -r label argv rc out err want <<<"$row"
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
the edit lands at the issue endpoint, and the pulls one is never asked|2633519824 Fixed|0|success=true url=$ISSUE_URL|-|repo,api:$ISSUE_PATH
a dry run edits nothing and asks no endpoint|2633519824 Fixed --dry-run|0|dry id=2633519824|-|repo
a non-numeric id is refused before the repository is resolved|r2633519824 Fixed|1|-|Comment ID must be numeric: r2633519824|-
"

SCENARIO="review-comment"
run_table "an id only the review-comments endpoint holds" "\
the issue endpoint's 404 sends the id to the pulls endpoint and the edit lands|2633519824 Fixed|0|success=true url=$REVIEW_URL|-|repo,api:$ISSUE_PATH,api:$PULLS_PATH
"

SCENARIO="no-such-comment"
run_table "an id neither endpoint holds" "\
both 404s are refused with the keyed line, not a bare 404|2633519824 Fixed|1|-|github: comment-kind=unknown id=2633519824 use=find-comment|repo,api:$ISSUE_PATH,api:$PULLS_PATH
"

SCENARIO="issue-endpoint-broken"
run_table "a failure that is not a 404" "\
the issue endpoint's own error is reported and the pulls endpoint is not asked|2633519824 Fixed|1|-|Failed to edit comment: gh: Validation Failed|repo,api:$ISSUE_PATH
"

echo "=== must-fail control ==="
# Take the review-comments fallback back out, keeping the lines around it: the
# issue endpoint's 404 becomes the final answer again. The review-comment row
# above reddens, and it reddens the way the field did — a comment the caller
# can see on the PR page answers HTTP 404, so the caller either retries the
# same call or posts a duplicate reply instead of editing the line.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR/commands"
cp -R "$REPO_ROOT/skills/github/scripts/lib" "$MUTANT_DIR/lib"
MUTANT="$MUTANT_DIR/commands/edit-comment.sh"
cp "$EDIT_COMMENT" "$MUTANT"
assert_eq "$(grep -Fc 'gh_error_is_not_found "$result"; then' "$MUTANT")" "2" \
  "control finds both live not-found branches"
# `false` where the predicate stood leaves the retry and the keyed refusal in
# the file and unreachable, which is exactly the pre-fix behaviour.
sed -i.bak 's|gh_error_is_not_found "$result"; then|false; then|g' "$MUTANT"
assert_eq "$(grep -Fc 'gh_error_is_not_found "$result"; then' "$MUTANT")" "0" \
  "control applied the mutation"
SCENARIO="review-comment"
build
SUBJECT="$MUTANT"
GOT="$(run '2633519824 Fixed')"
SUBJECT=""
assert_eq "$GOT" \
  "rc=1 out=- err=Failed to edit comment: gh: Not Found calls=repo,api:$ISSUE_PATH" \
  "must-fail control: without the fallback a review comment id answers a bare 404"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
