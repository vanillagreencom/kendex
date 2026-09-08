#!/usr/bin/env bash
# post-reply: a numeric comment id takes the legacy REST path and needs an
# explicit --pr, refused locally before any gh call (auto-resolving the PR
# from the branch once hit a REST path that collided with the bot's pending
# review); a thread id needs none; a numeric id with --pr reaches the
# collision-safe /replies endpoint.
#
# A row is `label|argv|rc|out|err|calls`:
#   argv   post-reply's arguments as written
#   rc     the exit status
#   out    stdout reduced: a dry run as `dry method=<m> pr=<n|-> id=<id>`, a
#          posted reply as `success=<bool> url=<url>`; `-` when empty
#   err    stderr's error clause, the JSON `.error` up to its first
#          parenthesis; `-` when stderr is empty
#   calls  every gh call by kind, in order (`auth`, `user`, `repo`, `view`,
#          `api:<path>`); `-` for none
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C` and
# would configure the real repository.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
POST_REPLY="$REPO_ROOT/skills/github/scripts/commands/post-reply.sh"
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

build() {
  gh_stub_reset
  gh_stub_answer pr-view '{"number":77,"headRefName":"feature-branch"}'
  gh_stub_answer 'api:/replies' '{"html_url":"https://github.com/owner/repo/pull/23#discussion_r999"}'
}

out_text() {
  local text
  text="$(cat "$TMP_ROOT/stdout")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  jq -r 'if .dry_run == true then "dry method=\(.method) pr=\(.pr // "-") id=\(.thread_id // .comment_id)"
         else "success=\(.success) url=\(.url)" end' <<<"$text" 2>/dev/null || printf '%s' "$text" | paste -s -d ';' -
}

err_text() {
  local text
  text="$(cat "$TMP_ROOT/stderr")"
  [[ "$text" != "" ]] || { printf -- '-'; return; }
  jq -r '.error | split(" (")[0]' <<<"$text" 2>/dev/null || printf '%s' "$text" | paste -s -d ';' -
}

calls() {
  local line out=""
  while IFS= read -r line; do
    case "$line" in
      "auth status"*) out="$out,auth" ;;
      "api user"*) out="$out,user" ;;
      "repo view"*) out="$out,repo" ;;
      "pr view"*) out="$out,view" ;;
      "api "*) line="${line#api }"; out="$out,api:${line%% *}" ;;
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
    "$POST_REPLY" "${argv[@]}" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr") || rc=$?
  printf 'rc=%s out=%s err=%s calls=%s' "$rc" "$(out_text)" "$(err_text)" "$(calls)"
}

run_table() {
  local title="$1" rows="$2" label argv rc out err want got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label argv rc out err want <<<"$row"
    for field in "$label" "$argv" "$rc" "$out" "$err" "$want"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
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
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
}

run_table "the numeric id's --pr requirement" "\
a numeric id without --pr is refused before any call|2633519824 Fixed|1|-|Numeric comment ID requires --pr <N>|-
the same under --dry-run, no silent dry run|2633519824 Fixed --dry-run|1|-|Numeric comment ID requires --pr <N>|-
a numeric id with --pr dry-runs the rest method against that PR|2633519824 Fixed --pr 23 --dry-run|0|dry method=rest pr=23 id=2633519824|-|-
a numeric id with --pr posts to the PR's /replies endpoint|2633519824 Fixed --pr 23|0|success=true url=https://github.com/owner/repo/pull/23#discussion_r999|-|repo,auth,api:repos/owner/repo/pulls/23/comments/2633519824/replies
a thread id needs no --pr and dry-runs the graphql method|PRRT_kwDOexample123 Thanks --dry-run|0|dry method=graphql pr=- id=PRRT_kwDOexample123|-|-
"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
