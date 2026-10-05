#!/usr/bin/env bash
# find-comment --self against the staged gh fake, read as a GitHub App
# installation token: the prior summary its own identity posted, found across
# every page of the PR's comments and matched by account id; no such summary
# on a first triage; and a comment list or identity it cannot read, which is
# an error and never an empty result. The review-summary picks are
# sticky-comment-cli.test.sh's.
#
# Each must-fail control runs a copy of the scripts tree with one whole line
# of find-comment.sh replaced, the rest kept (lib/mutant-copy.sh), and the
# case that line's rule decides flips.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
FIND_COMMENT="$REPO_ROOT/skills/github/scripts/commands/find-comment.sh"

TMP_ROOT="$(mktemp -d)" || { echo "find-comment.test: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "find-comment.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "find-comment.test: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"
  fi
}

# shellcheck source=lib/gh-stub.sh
. "$TEST_DIR/lib/gh-stub.sh"
# shellcheck source=lib/mutant-copy.sh
. "$TEST_DIR/lib/mutant-copy.sh"
GH_STUB_DIR="$TMP_ROOT/gh-stub" gh_stub_install "$TMP_ROOT/bin"
mkdir -p "$TMP_ROOT/work"

COMMENTS_PATH='api-repos/owner/repo/issues/7/comments?per_page=100'
VIEWER_QUERY='api-graphql:viewer { login databaseId }'

# One REST issue comment, as `id login account-id updated-at body`.
comment() { # ID LOGIN ACCOUNT_ID UPDATED_AT BODY
  jq -cn --argjson id "$1" --arg login "$2" --argjson uid "$3" --arg at "$4" --arg body "$5" \
    '{id: $id, user: {login: $login, id: $uid}, body: $body, created_at: $at, updated_at: $at, html_url: "https://github.com/owner/repo/pull/7#issuecomment-\($id)"}'
}
# The lane's app posts under its bot account, 2002. A maintainer quoting the
# summary later, and a person whose login is the app's slug, are other
# accounts whose bodies match the same pattern.
OWN_OLD=$(comment 11 'lanes-app[bot]' 2002 2026-10-01T01:00:00Z $'## Recommendations Processed\nfirst pass')
OTHER=$(comment 12 reviewer 1001 2026-10-01T02:00:00Z 'Please guard the empty list.')
OWN_NEW=$(comment 21 'lanes-app[bot]' 2002 2026-10-02T05:00:00Z $'## Recommendations Processed\nsecond pass')
QUOTE=$(comment 22 maintainer 4004 2026-10-02T06:00:00Z $'> ## Recommendations Processed\nAgreed.')
IMPOSTOR=$(comment 23 lanes-app 6006 2026-10-02T07:00:00Z $'## Recommendations Processed\nnot the app')

# A world read as the installation token: `gh api user` refuses it the way
# GitHub does, and the GraphQL viewer is the app's bot account. PAGES are the
# comment pages `gh api --paginate` prints, one array each.
world() { # PAGES...
  gh_stub_reset
  gh_stub_fail api-user 1 'gh: Resource not accessible by integration (HTTP 403)'
  gh_stub_answer "$VIEWER_QUERY" '{"data":{"viewer":{"login":"lanes-app[bot]","databaseId":2002}}}'
  gh_stub_answer "$COMMENTS_PATH" "$(printf '%s\n' "$@")"
}
PRESENT=("[$OWN_OLD,$OTHER]" "[$OWN_NEW,$QUOTE,$IMPOSTOR]")
ABSENT=("[$OTHER]" "[$QUOTE,$IMPOSTOR]")

# `rc=<n> <id> <updated_at>` for a found comment, `rc=<n> {}` for none, and
# `rc=<n> error` for a refusal: empty stdout and one JSON object carrying a
# string `.error` on stderr, the shape json-error.sh writes.
run() { # [SUBJECT]
  local rc=0 out
  (cd "$TMP_ROOT/work" && env -u GITHUB_TOKEN -u GH_BOT_TOKEN -u GH_REPO -u GH_CONFIG_DIR -u KENDEX_ENV_FILE \
    GH_TOKEN=ghs_installation PATH="$TMP_ROOT/bin:$PATH" \
    "${1:-$FIND_COMMENT}" 7 --pattern 'Recommendations.*Processed' --self \
    >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  out=$(cat "$TMP_ROOT/stdout")
  if [ "$rc" -ne 0 ]; then
    if [ -z "$out" ] && jq -se 'length == 1 and (.[0].error | type) == "string"' "$TMP_ROOT/stderr" >/dev/null 2>&1; then
      out=error
    else
      out="unexpected stdout=[$out] stderr=[$(cat "$TMP_ROOT/stderr")]"
    fi
  elif [ "$out" != "{}" ]; then
    out=$(jq -r '"\(.id) \(.updated_at)"' <<<"$out" 2>/dev/null || printf 'unparseable: %s' "$out")
  fi
  printf 'rc=%s %s' "$rc" "$out"
}

FOUND='rc=0 21 2026-10-02T05:00:00Z'

echo "=== --self under an installation token ==="
# A row is `label|setup|want`.
ROWS="\
a repeat triage finds its own latest summary on the second page|world \"\${PRESENT[@]}\"|$FOUND
a first triage finds no prior summary|world \"\${ABSENT[@]}\"|rc=0 {}
a comment list that cannot be read is an error|world; gh_stub_fail \"\$COMMENTS_PATH\" 1 'gh: Not Found (HTTP 404)'|rc=1 error
a viewer read GitHub refuses is an error|world \"\${PRESENT[@]}\"; gh_stub_answer \"\$VIEWER_QUERY\" '{\"errors\":[{\"type\":\"FORBIDDEN\",\"message\":\"no\"}]}'|rc=1 error
a viewer read naming no account id is an error|world \"\${PRESENT[@]}\"; gh_stub_answer \"\$VIEWER_QUERY\" '{\"data\":{\"viewer\":{\"login\":\"lanes-app[bot]\"}}}'|rc=1 error"
before=$((PASS + FAIL))
while IFS='|' read -r label setup want; do
  eval "$setup"
  assert_eq "$(run)" "$want" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no --self row was asserted" >&2; exit 2; }

echo "=== must-fail controls ==="
# A row is `label|name|from line|to line|setup|want with the mutant`.
mutant_row() { # LABEL NAME FROM TO SETUP WANT
  local script
  script=$(mutant_copy_edit "$TMP_ROOT/$2" "$3" "$4" commands/find-comment.sh)
  eval "$5"
  assert_eq "$(run "$script")" "$6" "must-fail: $1"
}
mutant_row "with the id filter cut, a later quote by another account is picked" id-filter \
  "        comments=\$(jq -c --argjson id \"\$viewer_id\" '[.[] | select(.user.id == \$id)]' <<<\"\$comments\")" '        true' \
  'world "${PRESENT[@]}"' 'rc=0 23 2026-10-02T07:00:00Z'
mutant_row "with the page merge cut, each page answers apart" page-merge \
  "    comments=\$(jq -s 'if (length > 0) and all(type == \"array\") then add else error(\"pages are not arrays\") end' <<<\"\$comments\" 2>/dev/null) || {" '    true || {' \
  'world "${PRESENT[@]}"' $'rc=0 11 2026-10-01T01:00:00Z\n21 2026-10-02T05:00:00Z'
mutant_row "with the account id check cut, a viewer with no id finds nothing" id-check \
  "        viewer_id=\$(jq -er '.databaseId | numbers | select(. > 0 and . == floor)' <<<\"\$viewer\" 2>/dev/null) || {" '        viewer_id=0 || {' \
  "world \"\${PRESENT[@]}\"; gh_stub_answer \"\$VIEWER_QUERY\" '{\"data\":{\"viewer\":{\"login\":\"lanes-app[bot]\"}}}'" 'rc=0 {}'

echo
echo "----"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
